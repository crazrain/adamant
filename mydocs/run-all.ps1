# run-all.ps1 - one window, everything: build -> full ctest on the patched build -> engine A/B load gates.
# Run D:\study\ai\adamant-exp\run-all.bat (after taking serving down yourself - the engine runs need the VRAM);
# everything logs under D:\study\ai\adamant-exp\measure\<ts>\ and progress prints with timestamps.
# --help prints usage and the resolved commands; --dry-run simulates the run: checks every precondition,
# prints each step it would take, and executes nothing.
$DryRun = $args -contains '--dry-run' -or $args -contains '-DryRun'
$Help   = $args -contains '--help' -or $args -contains '-h'
$ErrorActionPreference = 'Continue'
$root    = 'D:\study\ai\adamant-exp'
$repo    = 'D:\study\ai\adamant'
$vcvars  = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$base    = "$repo\bin\basalt.exe"                       # the running production build
$patched = "$root\bin\Release\basalt.exe"               # plan_reserve + unbuffered patches applied
$pack    = "$repo\models\Qwen3.8-FN-UD-IQ3_XXS.basalt"
# Production flags as the python server launches the engine (cwd = $repo: the profile paths are relative).
$flags = @('--serve','--model',$pack,'--max-context','262144','--vram-reserve-mib','1536','--prefill-cpu-share','0.5',
    '--expert-profile','data/profiles/my-iq3xxs.bin','--expert-profile-save','data/profiles/my-iq3xxs.bin',
    '--conversation-cache-mib','256','--conversation-cache-slots','8','--conversation-cache-min-tokens','16384',
    '--conversation-cache-disk-mib','65536','--conversation-cache-dir','T:/adamant/conversations','--vram-elastic',
    '--kv','int8','--kv-resident','32768','--vision','--gpu','0','--grammar','on')
# plan_reserve stress condition: a small guard with an aggressive resident tier (edit values here, then re-run).
$stress = @('--ram-reserve-mib','16384','--resident-budget-gib','70')
$ready  = 'MiB of VRAM free with everything loaded'     # protocol.cpp: the load-complete line
$loadTimeoutS = 1800

function Say([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

if ($Help) {
    Say 'usage: run-all.bat [--help | --dry-run]'
    Say '  (no args)  run everything: build, full ctest, 4 engine load runs. Take serving down first.'
    Say '  --help     this text plus the resolved commands'
    Say '  --dry-run  simulate: check every precondition, print each step, execute nothing'
    Say "build : cmake --build $root\build-ssh --config Release"
    Say "ctest : ctest --test-dir $root\build-ssh -C Release --output-on-failure"
    foreach ($v in @(@('A-base-normal',$base,@()), @('B-patch-normal',$patched,@()),
                    @('C-base-stress',$base,$stress), @('D-patch-stress',$patched,$stress))) {
        Say "engine: $repo> `"$($v[1])`" $($flags + $v[2] -join ' ')   [$($v[0]), stderr->log, stdin=empty file]"
    }
    Say "out  : $root\measure\<ts>\ (SUMMARY.md, ctest.log, per-run .log/-samples.csv/.csv/-tier.txt, transcript.txt)"
    return
}

if ($DryRun) {
    Say 'DRY RUN - precondition checks and the steps that would run; nothing is executed.'
    $fail = 0
    function Check([string]$what, [bool]$ok, [string]$detail) {
        if ($ok) { Say ("  OK   {0}: {1}" -f $what, $detail) }
        else     { Say ("  MISS {0}: {1}" -f $what, $detail); $script:fail++ }
    }
    Check 'vcvars'    (Test-Path $vcvars) $vcvars
    Check 'build dir' (Test-Path "$root\build-ssh\CMakeCache.txt") "$root\build-ssh (incremental build applies)"
    $ct = Get-Command ctest -EA SilentlyContinue
    Check 'ctest' ([bool]$ct) $(if ($ct) { $ct.Source } else { 'ctest not on PATH' })
    Check 'base exe'  (Test-Path $base) $base
    Check 'patched exe' (Test-Path $patched) $patched
    Check 'pack'      (Test-Path $pack) $pack
    Check 'expert profile dir' (Test-Path "$repo\data\profiles") "$repo\data\profiles (relative to cwd $repo)"
    Check 'venv python' (Test-Path "$repo\.venv\Scripts\python.exe") "$repo\.venv\Scripts\python.exe (migration tests import serve/)"
    $running = @(Get-Process basalt -EA SilentlyContinue)
    if ($running.Count -gt 0) { Say ("  WARN serving: {0} basalt.exe running - take serving down before the real run (engine runs need ~22 GiB VRAM)" -f $running.Count) }
    else { Say '  OK   serving: no basalt.exe running' }
    $free = [int](Get-Counter '\Memory\Available MBytes' -EA SilentlyContinue).CounterSamples.CookedValue
    Say ("  info RAM: {0} MB free (pack is 87.6 GiB; the tier needs the RAM headroom)" -f $free)
    Say 'steps that would run:'
    Say "  1. cmake --build $root\build-ssh --config Release"
    Say '  2. ctest --test-dir build-ssh -C Release --output-on-failure   (venv python first on PATH)'
    Say '  3-6. engine loads A/B/C/D, each: start -> poll stderr for the ready line (30s heartbeat) -> 10s settle -> kill -> per-run CSV'
    Say ("preconditions: {0} missing" -f $fail)
    return
}

$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = "$root\measure\$ts"; New-Item -ItemType Directory -Force $out | Out-Null
Start-Transcript "$out\transcript.txt" | Out-Null
Say "output dir: $out"

if (Get-Process basalt -EA SilentlyContinue) {
    Say 'WARNING: a basalt.exe is still running - the engine load runs will compete for VRAM.'
}

function Run-Step([string]$name, [string]$cmd, [string]$log) {
    Say "START $name"
    $t0 = Get-Date
    cmd /c "call `"$vcvars`" >nul 2>&1 && $cmd" 2>&1 | Tee-Object $log | Select-Object -Last 3
    Say ("DONE {0} ({1:N0}s, exit {2}) -> {3}" -f $name, ((Get-Date) - $t0).TotalSeconds, $LASTEXITCODE, (Split-Path $log -Leaf))
    return $LASTEXITCODE
}

function Run-Ctest {
    # The full suite on the patched build. The migration tests import serve/, which lives in the repo's venv.
    $env:PATH = "$repo\.venv\Scripts;$env:PATH"
    Run-Step 'ctest' "ctest --test-dir $root\build-ssh -C Release --output-on-failure" "$out\ctest.log" | Out-Null
    $script:ctestTail = (Get-Content "$out\ctest.log" | Select-String 'tests passed|tests failed' | Select-Object -Last 1).Line.Trim()
    Say "ctest: $script:ctestTail"
}

function Measure-Load([string]$name, [string]$exe, [string[]]$extra) {
    Say "START $name ($exe)"
    $log = "$out\$name.log"; $csv = "$out\$name-samples.csv"
    "t,nvidia_used_mib,avail_mb,basalt_ws_mb" | Set-Content $csv
    $empty = "$out\empty-stdin.txt"; '' | Set-Content $empty
    $job = Start-Job -ArgumentList $csv, $log {
        param($csv, $log)
        for ($i = 0; $i -lt 3600; $i++) {
            if (-not (Test-Path $log)) { Start-Sleep -Milliseconds 900; continue }
            if ((Get-Content $log -Raw -EA SilentlyContinue) -match 'everything loaded') { break }
            $g = (& 'C:\Windows\System32\nvidia-smi.exe' --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
            $a = [int](Get-Counter '\Memory\Available MBytes' -EA SilentlyContinue).CounterSamples.CookedValue
            $w = [int64]((Get-Process basalt -EA SilentlyContinue | Measure-Object WorkingSet64 -Sum).Sum / 1MB)
            "$i,$g,$a,$w" | Add-Content $csv
            Start-Sleep -Milliseconds 100
        }
    }
    $t0 = Get-Date
    $p  = Start-Process -FilePath $exe -ArgumentList ($flags + $extra) -WorkingDirectory $repo `
            -RedirectStandardError $log -RedirectStandardInput $empty -PassThru
    if (-not $p) { Say "FAILED to start $name"; return }
    $loadS = -1; $lastBeat = 0
    while ((Get-Date) -lt $t0.AddSeconds($loadTimeoutS)) {
        if ((Get-Content $log -Raw -EA SilentlyContinue) -match "(?m)^(.*?)$([regex]::Escape($ready))") { $loadS = [int]((Get-Date) - $t0).TotalSeconds; break }
        if ($p.HasExited) { Say "$name exited early (code $($p.ExitCode)) after $([int]((Get-Date)-$t0).TotalSeconds)s - see log"; break }
        $el = [int]((Get-Date) - $t0).TotalSeconds
        if ($el - $lastBeat -ge 30) { $lastBeat = $el
            Say ("  {0}: {1}s elapsed, log {2:N0} KiB, VRAM used {3} MiB" -f $name, $el,
                ((Get-Item $log -EA SilentlyContinue).Length / 1KB),
                (& 'C:\Windows\System32\nvidia-smi.exe' --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1)) }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 10                                   # let the last sampler rows land
    Stop-Job $job -EA SilentlyContinue; Remove-Job $job -Force -EA SilentlyContinue
    if ($p -and -not $p.HasExited) { taskkill /PID $p.ProcessId /T /F 2>&1 | Out-Null; Start-Sleep -Seconds 3 }
    $peakV = (Import-Csv $csv | Measure-Object nvidia_used_mib -Maximum).Maximum
    $minA  = (Import-Csv $csv | Measure-Object avail_mb -Minimum).Minimum
    $peakW = (Import-Csv $csv | Measure-Object basalt_ws_mb -Maximum).Maximum
    $tier  = (Get-Content $log -EA SilentlyContinue | Select-String 'RAM|VRAM|tier|guard|resident|reserve|unbuffered|direct' | Select-Object -First 40) -join "`n"
    [pscustomobject]@{ name = $name; exe = $exe; load_s = $loadS; peak_vram_mib = $peakV; min_free_ram_mb = $minA;
        peak_ws_mb = $peakW; ready_line = if ($loadS -ge 0) { 'yes' } else { 'NO - check log' } } |
        Export-Csv "$out\$name.csv" -NoTypeInformation
    "==== $name tier/guard log lines ====" | Set-Content "$out\$name-tier.txt"
    $tier | Add-Content "$out\$name-tier.txt"
    Say ("DONE {0}: load {1}s peakVRAM {2}MiB minFreeRAM {3}MB peakWS {4}MB" -f $name, $loadS, $peakV, $minA, $peakW)
}

try {
    Run-Step 'build' "cmake --build $root\build-ssh --config Release" "$out\build.log" | Out-Null
    Run-Ctest
    Measure-Load 'A-base-normal'  $base    @()
    Measure-Load 'B-patch-normal' $patched @()
    Measure-Load 'C-base-stress'  $base    $stress
    Measure-Load 'D-patch-stress' $patched $stress
} catch {
    Say "window failed: $_"
} finally {
    $sum = "ctest: $script:ctestTail`r`n`r`n"
    $sum += (Get-ChildItem $out -Filter '*.csv' | Where-Object Name -notmatch 'samples' |
        ForEach-Object { Import-Csv $_.FullName }) | Format-Table -AutoSize | Out-String -Width 200
    $sum | Set-Content "$out\SUMMARY.md"
    Stop-Transcript | Out-Null
    Say "results: $out"
}

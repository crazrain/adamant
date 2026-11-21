# measure-window.ps1 - unattended load-measurement window for the adamant A/B gates.
# Sequence: record+stop serving -> 4 load runs (baseline/patched x normal/stress) -> restart serving -> SUMMARY.md.
# Serving is down for the whole window (~20-40 min). Every path logs under $out; serving restarts even on failure.
$ErrorActionPreference = 'Continue'
$root    = 'D:\study\ai\adamant-exp'
$repo    = 'D:\study\ai\adamant'
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

$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = "$root\measure\$ts"; New-Item -ItemType Directory -Force $out | Out-Null
Start-Transcript "$out\transcript.txt" | Out-Null

function Stop-Serving {
    # Record what is running, then take it down; the restart uses the recorded command lines.
    $script:served = Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -eq 'basalt.exe') -or ($_.Name -eq 'python.exe' -and $_.CommandLine -match 'serve\.server') }
    foreach ($p in $script:served) {
        Write-Host ("stopping pid {0} ({1})" -f $p.ProcessId, $p.Name)
        taskkill /PID $p.ProcessId /T /F 2>&1 | Out-Null
    }
    Start-Sleep -Seconds 5
}

function Restart-Serving {
    # The python API server (it spawns its engine) and the console engine, as recorded.
    $py = $script:served | Where-Object { $_.Name -eq 'python.exe' } | Select-Object -First 1
    if ($py) {
        $argv = ($py.CommandLine -replace '^"[^"]+"\s*','') -split '\s+(?=(?:[^"]*"[^"]*")*[^"]*$)'
        Start-Process -FilePath $py.ExecutablePath -ArgumentList $argv -WorkingDirectory $repo | Out-Null
        Write-Host 'serving: python serve.server restarted'
    }
    $cb = $script:served | Where-Object { $_.Name -eq 'basalt.exe' -and $_.CommandLine -notmatch [regex]::Escape($pack) } | Select-Object -First 1
    if ($cb) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cb.CommandLine -WorkingDirectory $repo | Out-Null
        Write-Host 'serving: console basalt restarted'
    }
}

function Measure-Load([string]$name, [string]$exe, [string[]]$extra) {
    $log = "$out\$name.log"; $csv = "$out\$name-samples.csv"
    "t,nvidia_used_mib,avail_mb,basalt_ws_mb" | Set-Content $csv
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
            -RedirectStandardError $log -RedirectStandardInput NUL -PassThru
    $loadS = -1
    while ((Get-Date) -lt $t0.AddSeconds($loadTimeoutS)) {
        if ((Get-Content $log -Raw -EA SilentlyContinue) -match "(?m)^(.*?)$([regex]::Escape($ready))") { $loadS = [int]((Get-Date) - $t0).TotalSeconds; break }
        if ($p.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 10                                   # let the last sampler rows land
    Stop-Job $job -EA SilentlyContinue; Remove-Job $job -Force -EA SilentlyContinue
    if (-not $p.HasExited) { taskkill /PID $p.ProcessId /T /F 2>&1 | Out-Null; Start-Sleep -Seconds 3 }
    $peakV = (Import-Csv $csv | Measure-Object nvidia_used_mib -Maximum).Maximum
    $minA  = (Import-Csv $csv | Measure-Object avail_mb -Minimum).Minimum
    $peakW = (Import-Csv $csv | Measure-Object basalt_ws_mb -Maximum).Maximum
    $tier  = (Get-Content $log | Select-String 'RAM|VRAM|tier|guard|resident|reserve|unbuffered|direct' | Select-Object -First 40) -join "`n"
    [pscustomobject]@{ name = $name; exe = $exe; load_s = $loadS; peak_vram_mib = $peakV; min_free_ram_mb = $minA;
        peak_ws_mb = $peakW; ready_line = if ($loadS -ge 0) { 'yes' } else { 'NO - check log' } } |
        Export-Csv "$out\$name.csv" -NoTypeInformation
    "==== $name tier/guard log lines ====" | Set-Content "$out\$name-tier.txt"
    $tier | Add-Content "$out\$name-tier.txt"
    Write-Host ("{0}: load {1}s peakVRAM {2}MiB minFreeRAM {3}MB peakWS {4}MB" -f $name, $loadS, $peakV, $minA, $peakW)
}

try {
    Stop-Serving
    Measure-Load 'A-base-normal'  $base    @()
    Measure-Load 'B-patch-normal' $patched @()
    Measure-Load 'C-base-stress'  $base    $stress
    Measure-Load 'D-patch-stress' $patched $stress
} catch {
    Write-Host "window failed: $_"
} finally {
    Restart-Serving
    (Get-ChildItem $out -Filter '*.csv' | Where-Object Name -notmatch 'samples' |
        ForEach-Object { Import-Csv $_.FullName }) | Format-Table -AutoSize | Out-String -Width 200 |
        Set-Content "$out\SUMMARY.md"
    Stop-Transcript | Out-Null
    Write-Host "results: $out"
}

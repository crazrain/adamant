# ab-greedy.ps1 - one-shot A/B greedy identity: original vs patched engine, same prompt ids, diff the tokens.
# Take serving down first (the engine runs need the VRAM), then run D:\study\ai\adamant-exp\ab-greedy.bat.
# --help prints usage and the resolved commands; --dry-run checks every precondition, prints each step, executes nothing.
$DryRun = $args -contains '--dry-run' -or $args -contains '-DryRun'
$Help   = $args -contains '--help' -or $args -contains '-h'
$ErrorActionPreference = 'Continue'
$root  = 'D:\study\ai\adamant-exp'
$repo  = 'D:\study\ai\adamant'
$orig  = "$repo\bin\basalt.org.exe"                     # the pre-patch build (renamed from basalt.exe.org)
$patch = "$root\bin\Release\basalt.exe"                 # plan_reserve + unbuffered, committed on mem/plan-reserve-unbuffered
$pack  = "$repo\models\Qwen3.8-FN-UD-IQ3_XXS.basalt"
$ids   = "$repo\data\bench\conv.ids"                    # pre-tokenized chat prompt (the bench fixture)
$prof  = "$repo\data\profiles\my-iq3xxs.bin"            # same placement on both sides; read-only, no -save
$maxNew = 256
$flags = @('--model',$pack,'--tokens-file',$ids,'--max-new',"$maxNew",'--spec','0','--greedy',
          '--max-context','262144','--kv','int8','--kv-resident','32768','--expert-profile',$prof,'--gpu','0')
$ts    = Get-Date -Format 'yyyyMMdd-HHmmss'
$out   = "$root\measure\$ts-abgreedy"

function Say([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

if ($Help) {
    Say 'usage: ab-greedy.bat [--help | --dry-run]'
    Say '  (no args)  run both engines and diff. Take serving down first.'
    Say '  --help     this text plus the resolved commands'
    Say '  --dry-run  simulate: check every precondition, print each step, execute nothing'
    foreach ($v in @(@('orig',$orig), @('patch',$patch))) {
        Say "engine: $repo> `"$($v[1])`" $($flags -join ' ')   [$($v[0]), stdout->tokens-$($v[0]).txt, stderr->log]"
    }
    Say "diff : compare tokens-orig.txt tokens-patch.txt line by line"
    Say "out  : $out\ (tokens-*.txt, *.log, RESULT.txt)"
    return
}

# preconditions
$fail = @()
foreach ($f in @($orig,$patch,$pack,$ids)) { if (-not (Test-Path $f)) { $fail += "missing: $f" } }
if (-not (Test-Path $prof)) { Say "warn: expert profile $prof missing - both sides place from scratch (still identical inputs)" }
$running = @(Get-Process basalt -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if ($DryRun) { Say "warn: basalt.exe is running (PID $($running.Id -join ',')) - take serving down before the real run" }
    else { $fail += "basalt.exe is running (PID $($running.Id -join ',')) - take serving down first" }
}
if ($fail.Count -gt 0) { foreach ($f in $fail) { Say "FAIL $f" }; exit 1 }

if ($DryRun) {
    Say 'dry-run: preconditions OK'
    Say "would create $out"
    foreach ($v in @(@('orig',$orig), @('patch',$patch))) {
        Say "would run: cd $repo; `"$($v[1])`" $($flags -join ' ') > $out\tokens-$($v[0]).txt 2> $out\$($v[0]).log"
    }
    Say 'would diff the two token files and write RESULT.txt'
    exit 0
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
Say "output: $out"

$code = @{}
foreach ($v in @(@('orig',$orig), @('patch',$patch))) {
    $name = $v[0]; $bin = $v[1]
    Say "run $name : loading + generating $maxNew greedy tokens (a few minutes)"
    $t0 = Get-Date
    Push-Location $repo
    & $bin @flags 1> "$out\tokens-$name.txt" 2> "$out\$name.log"
    $code[$name] = $LASTEXITCODE
    Pop-Location
    $n = @(Get-Content "$out\tokens-$name.txt" -ErrorAction SilentlyContinue).Count
    Say ("run $name : exit {0}, {1} T-lines, {2:N0}s" -f $code[$name], $n, ((Get-Date) - $t0).TotalSeconds)
}

$verdict = 'FAIL'
$detail = ''
if ($code['orig'] -ne 0 -or $code['patch'] -ne 0) {
    $detail = "engine exit codes orig=$($code['orig']) patch=$($code['patch']) - see the .log files"
} else {
    $a = @(Get-Content "$out\tokens-orig.txt"); $b = @(Get-Content "$out\tokens-patch.txt")
    if ($a.Count -ne $b.Count) { $detail = "length differs: orig $($a.Count) vs patch $($b.Count)" }
    else {
        $bad = -1
        for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -ne $b[$i]) { $bad = $i; break } }
        if ($bad -lt 0) { $verdict = 'PASS'; $detail = "$($a.Count) tokens identical (greedy, --spec 0)" }
        else { $detail = "first mismatch at token $bad : orig '$($a[$bad])' vs patch '$($b[$bad])'" }
    }
}
Say "$verdict : $detail"
"$verdict : $detail" | Set-Content "$out\RESULT.txt"
if ($verdict -eq 'PASS') { exit 0 } else { exit 1 }

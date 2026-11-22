# ab-dp.ps1 - verify the draft-policy port: determinism (new twice identical) and invariance (new == original pre-port binary).
# Take serving down first (the engine runs need the VRAM), then run D:\study\ai\adamant-exp\ab-dp.bat.
$DryRun = $args -contains '--dry-run' -or $args -contains '-DryRun'
$ErrorActionPreference = 'Continue'
$root  = 'D:\study\ai\adamant-exp'
$repo  = 'D:\study\ai\adamant'
$orig  = "$repo\bin\basalt.org.exe"                     # pre-patch build: timed policy, no patches
$new   = "$root\bin\Release\basalt.exe"                 # port build: plan_reserve + unbuffered + timed=false policy
$pack  = "$repo\models\Qwen3.8-FN-UD-IQ3_XXS.basalt"
$ids   = "$repo\data\bench\conv.ids"
$prof  = "$repo\data\profiles\my-iq3xxs.bin"
$flags = @('--model',$pack,'--tokens-file',$ids,'--max-new','256','--spec','4','--prefill','32768','--greedy',
          '--max-context','262144','--kv','int8','--kv-resident','32768','--expert-profile',$prof,'--gpu','0')
$ts    = Get-Date -Format 'yyyyMMdd-HHmmss'
$out   = "$root\measure\$ts-abdp"

function Say([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

$fail = @()
foreach ($f in @($orig,$new,$pack,$ids)) { if (-not (Test-Path $f)) { $fail += "missing: $f" } }
$running = @(Get-Process basalt -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if ($DryRun) { Say "warn: basalt.exe is running (PID $($running.Id -join ',')) - take serving down before the real run" }
    else { $fail += "basalt.exe is running (PID $($running.Id -join ',')) - take serving down first" }
}
if ($fail.Count -gt 0) { foreach ($f in $fail) { Say "FAIL $f" }; exit 1 }
if ($DryRun) {
    Say 'dry-run: preconditions OK'
    Say "would run: orig x1, new x2 (same flags), then compare the output id lines and print the speculation lines"
    Say "out: $out"
    exit 0
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
Say "output: $out"
foreach ($v in @(@('orig',$orig), @('new1',$new), @('new2',$new))) {
    $name = $v[0]; $bin = $v[1]
    Say "run $name"
    Push-Location $repo
    & $bin @flags 1> "$out\out-$name.txt" 2> "$out\$name.log"
    $code = $LASTEXITCODE
    Pop-Location
    Say ("run $name : exit $code")
}

function Get-Out([string]$p) {
    $line = (Get-Content $p | Select-String -Pattern 'output\s*:' | Select-Object -First 1).Line
    if (-not $line) { return $null }
    return ($line.Substring($line.IndexOf(':') + 1).Trim() -split '\s+')
}
function Same([string]$a, [string]$b) {
    $x = Get-Out $a; $y = Get-Out $b
    if (-not $x -or -not $y) { return 'NO-OUTPUT' }
    if ($x.Count -ne $y.Count) { return "LEN $($x.Count) vs $($y.Count)" }
    for ($i = 0; $i -lt $x.Count; $i++) { if ($x[$i] -ne $y[$i]) { return "MISMATCH at $i : $($x[$i]) vs $($y[$i])" } }
    return "PASS ($($x.Count) tokens identical)"
}

$d1 = Same "$out\out-new1.txt" "$out\out-new2.txt"
$d2 = Same "$out\out-new1.txt" "$out\out-orig.txt"
Say "determinism (new run1 vs run2) : $d1"
Say "invariance  (new vs original)  : $d2"
Say "speculation lines (acceptance, tokens per round, window sizes):"
foreach ($n in @('orig','new1','new2')) {
    Get-Content "$out\out-$n.txt" | Select-String -Pattern 'speculation|window sizes' | ForEach-Object { Say ("  {0}: {1}" -f $n, $_.Line.Trim()) }
}
$verdict = if ($d1.StartsWith('PASS') -and $d2.StartsWith('PASS')) { 'PASS' } else { 'FAIL' }
"$verdict : determinism=$d1 invariance=$d2" | Set-Content "$out\RESULT.txt"
Say "$verdict (RESULT.txt written)"
if ($verdict -eq 'PASS') { exit 0 } else { exit 1 }

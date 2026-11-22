# spec-sweep.ps1 - basalt-bench speculation-window sweep: same fixtures, --spec 0/4/6/8, decode_tps + acceptance + window mix.
# Take serving down first (the bench needs the GPU), then run D:\study\ai\adamant-exp\spec-sweep.bat.
$DryRun = $args -contains '--dry-run' -or $args -contains '-DryRun'
$ErrorActionPreference = 'Continue'
$root   = 'D:\study\ai\adamant-exp'
$repo   = 'D:\study\ai\adamant'
$bench  = "$root\bin\Release\basalt-bench.exe"
$pack   = "$repo\models\Qwen3.8-FN-UD-IQ3_XXS.basalt"
$prof   = "$repo\data\profiles\my-iq3xxs.bin"
$specs  = @(0, 4, 6, 8)                       # 0 = plain-decode baseline (no speculation)
# engine flags mirroring the serving config (iq3_xxs_config.json); no expert-profile-save: the sweep must not rewrite the profile
$engine = @('--kv','int8','--kv-resident','32768','--expert-profile',$prof,
           '--vram-reserve-mib','1536','--prefill-cpu-share','0.5','--vram-elastic')
$ts     = Get-Date -Format 'yyyyMMdd-HHmmss'
$out    = "$root\measure\$ts-specsweep"

function Say([string]$m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

$fail = @()
foreach ($f in @($bench,$pack,$prof)) { if (-not (Test-Path $f)) { $fail += "missing: $f" } }
$running = @(Get-Process basalt -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if ($DryRun) { Say "warn: basalt.exe is running (PID $($running.Id -join ',')) - take serving down before the real run" }
    else { $fail += "basalt.exe is running (PID $($running.Id -join ',')) - take serving down first" }
}
if ($fail.Count -gt 0) { foreach ($f in $fail) { Say "FAIL $f" }; exit 1 }
if ($DryRun) {
    Say 'dry-run: preconditions OK'
    foreach ($s in $specs) { Say "would run: basalt-bench --model <pack> -t conv,struct,prose --seed 1 --spec $s -o json --logs <out> -- $engine" }
    Say "out: $out"
    exit 0
}

New-Item -ItemType Directory -Force -Path $out | Out-Null
Say "output: $out"
$rows = @()
foreach ($s in $specs) {
    Say "bench --spec $s (3 fixtures, fresh engine each; expect several minutes)"
    Push-Location $repo
    & $bench --model $pack -t conv,struct,prose --seed 1 --spec $s -o json --logs "$out" -- @engine 1> "$out\spec-$s.json" 2> "$out\spec-$s.err"
    $code = $LASTEXITCODE
    Pop-Location
    Say "bench --spec $s : exit $code"
    if ($code -ne 0) { Say "see $out\spec-$s.err"; continue }
    $j = Get-Content "$out\spec-$s.json" -Raw | ConvertFrom-Json
    foreach ($r in $j.results) {
        if ($r.test -notlike 'tg *') { continue }
        $rows += [pscustomobject]@{
            spec = $s; fixture = $r.test.Substring(3)
            tok_s = [math]::Round($r.tok_s, 2)
            accept_pct = if ($null -ne $r.acceptance_pct) { [math]::Round($r.acceptance_pct, 1) } else { $null }
            tok_per_win = if ($null -ne $r.tokens_per_window) { [math]::Round($r.tokens_per_window, 2) } else { $null }
            mean_t = if ($null -ne $r.mean_t) { [math]::Round($r.mean_t, 2) } else { $null }
        }
    }
}
Say ''
$rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$rows | ConvertTo-Json | Set-Content "$out\summary.json"
$rows | Format-Table -AutoSize | Out-File -Encoding utf8 "$out\summary.txt"
Say "summary written: $out\summary.txt"

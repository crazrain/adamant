# acceptance-snapshot.ps1 - one CSV line per run: the acceptance rate of the requests /metrics currently shows.
# /metrics keeps only the last REQUESTS_SHOWN requests, so this is the trend sampler; run it hourly via Task Scheduler.
$ErrorActionPreference = 'Continue'
$csv = 'D:\study\ai\adamant-exp\measure\acceptance-snapshots.csv'
try {
    $m = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 http://127.0.0.1:8080/metrics).Content | ConvertFrom-Json
} catch {
    "{0},down,,,,," -f (Get-Date -Format 's') | Add-Content $csv
    exit 0
}
$off = 0; $acc = 0; $n = 0
foreach ($r in @($m.requests)) {
    if ($null -ne $r.drafts_offered) { $off += [int]$r.drafts_offered; $acc += [int]$r.drafts_accepted; $n += 1 }
}
$rate = if ($off -gt 0) { [math]::Round(100.0 * $acc / $off, 1) } else { '' }
$toks = @($m.history.tok_s | Where-Object { $_ -gt 0 })
$tok = if ($toks.Count -gt 0) { [math]::Round(($toks | Measure-Object -Average).Average, 1) } else { '' }
$state = $m.live.state
$up = (Get-Process basalt -ErrorAction SilentlyContinue | Select-Object -First 1)
$since = if ($up) { $up.StartTime.ToString('s') } else { 'down' }
"{0},{1},{2},{3},{4},{5},{6},{7}" -f (Get-Date -Format 's'), $n, $off, $acc, $rate, $tok, $state, $since | Add-Content $csv

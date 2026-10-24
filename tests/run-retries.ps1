# run-retries.ps1 - milestone 4's dispatcher loop: retry a task until an attempt is accepted or a cap is reached.
#
# Why this exists (docs/target-setup.md milestone 4; docs/roadmap.md -> "After the trial" item 6): in real use the
# planner hands the executor a failing test, and the dispatcher keeps the first attempt that makes it pass. Milestone 3
# measured that a shown test works as that gate, and that failures are persistent per task, so the design is a
# sequential retry with a small cap, not N attempts at once (docs/adversarial-review-2026-10-23.md).
#
# What it does: for each task, run the real test-tasks.ps1 once per attempt (each attempt is a fresh sealed checkout,
# graded by every existing gate) and stop at the first ACCEPTED attempt or at -MaxAttempts. An attempt is accepted on
# what a dispatcher can see: the given tests pass (acceptance), they were left alone (scope; a tamper fails it) and the
# suite is green. Here the given tests and the hidden tests are the same files, so this selector is an oracle; with a
# planner's own tests it is not, and that gap is experiment 3's to measure.
#
# Each attempt's rejection reason is recorded: infrastructure (no run JSON: exit, timeout, CPU-only, overflow ...),
# tampered, acceptance, suite, scope. One row per task goes to retry-summary.tsv in -ResultsDir, and the end of the run
# reports the design's falsifier: more than 1.5 attempts per task, or the cap reached on more than 15% of tasks.
#
# Usage:
#   .\tests\run-retries.ps1 -Tasks wp-0a,wp-5a -Model llamacpp-server/qwen3.6:35b-a3b-coding -MaxAttempts 3 `
#       -TaskManifest <HomeLab-private>\tasks\manifest.json -ResultsDir <HomeLab-private>\results\<folder> `
#       -HarnessArgs @{ NudgeOnStop = $true; StopClassifier = 3; RunTimeout = 2700 }
#   -ShowAcceptance is passed to every attempt (the selector needs the given tests); -ReadOnlyAcceptance too if set.
#   -ScriptPath points at another test-tasks.ps1 (the guard's stand-in).
param(
    [Parameter(Mandatory)][string[]]$Tasks,
    [Parameter(Mandatory)][string]$Model,
    [ValidateRange(1, 10)][int]$MaxAttempts = 3,
    [Parameter(Mandatory)][string]$TaskManifest,
    [Parameter(Mandatory)][string]$ResultsDir,
    [hashtable]$HarnessArgs = @{},
    [switch]$ReadOnlyAcceptance,
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [double]$MaxMeanAttempts = 1.5,
    [double]$MaxCapHitShare = 0.15
)
$ErrorActionPreference = "Continue"
$Tasks = @($Tasks | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# The verdict of one attempt's run JSON, or "infrastructure" when the attempt left none.
function Get-AttemptVerdict {
    param($Json)
    if (-not $Json) { return [pscustomobject]@{ Accepted = $false; Reason = "infrastructure" } }
    $tampered = @($Json.acceptanceShown.tampered | Where-Object { $_ }).Count -gt 0
    if ($tampered) { return [pscustomobject]@{ Accepted = $false; Reason = "tampered" } }
    if ($Json.acceptance.status -ne "PASS") { return [pscustomobject]@{ Accepted = $false; Reason = "acceptance" } }
    if ($Json.gates.suite -ne "PASS") { return [pscustomobject]@{ Accepted = $false; Reason = "suite" } }
    if ($Json.gates.scope -ne "PASS") { return [pscustomobject]@{ Accepted = $false; Reason = "scope" } }
    return [pscustomobject]@{ Accepted = $true; Reason = "accepted" }
}

# The falsifier over the tasks run: mean attempts per task, and the share that reached the cap without acceptance.
function Get-RetryFalsifier {
    param([object[]]$Rows, [int]$Cap, [double]$MaxMean, [double]$MaxCapShare)
    $n = @($Rows).Count
    if ($n -eq 0) { return [pscustomobject]@{ Tasks = 0; MeanAttempts = $null; CapHitShare = $null; Falsified = $false; Detail = "no tasks" } }
    $mean = [math]::Round((($Rows | Measure-Object -Property Attempts -Sum).Sum) / $n, 3)
    $capHit = @($Rows | Where-Object { -not $_.Accepted -and $_.Attempts -ge $Cap }).Count
    $share = [math]::Round($capHit / $n, 3)
    $bad = @()
    if ($mean -gt $MaxMean) { $bad += "mean attempts $mean > $MaxMean" }
    if ($share -gt $MaxCapShare) { $bad += "cap reached on $capHit of $n tasks ($share) > $MaxCapShare" }
    return [pscustomobject]@{ Tasks = $n; MeanAttempts = $mean; CapHitShare = $share; CapHits = $capHit; Falsified = ($bad.Count -gt 0); Detail = $(if ($bad) { $bad -join "; " } else { "within the design's bounds (mean <= $MaxMean, cap share <= $MaxCapShare)" }) }
}

# Dot-sourced by the guard for the two functions above.
if ($MyInvocation.InvocationName -eq '.') { return }

if (-not (Test-Path -LiteralPath $ScriptPath)) { Write-Host "ERROR: no harness at $ScriptPath" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$summary = Join-Path $ResultsDir "retry-summary.tsv"
if (-not (Test-Path -LiteralPath $summary)) {
    Set-Content -LiteralPath $summary -Value ("timestamp`ttask`tmodel`tmaxAttempts`tattempts`taccepted`tacceptedAttempt`treasons`tseconds`toutputTokens`truns")
}
Write-Host ("retries: up to {0} attempt(s) per task, {1} task(s), model {2}; rows to {3}" -f $MaxAttempts, $Tasks.Count, $Model, $summary)

$rows = @()
foreach ($t in $Tasks) {
    $reasons = @(); $runs = @(); $seconds = 0.0; $out = 0; $accepted = $false; $acceptedAt = $null; $n = 0
    while ($n -lt $MaxAttempts -and -not $accepted) {
        $n++
        Write-Host ("##### retries {0} attempt {1} of {2} {3}" -f $t, $n, $MaxAttempts, (Get-Date -Format o))
        $before = @(Get-ChildItem -LiteralPath $ResultsDir -Filter "tasks-$t-*.json" -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $a = @{} + $HarnessArgs
        $a.Task = $t; $a.Model = $Model; $a.TaskManifest = $TaskManifest; $a.ResultsDir = $ResultsDir; $a.ShowAcceptance = $true
        if ($ReadOnlyAcceptance) { $a.ReadOnlyAcceptance = $true }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $ScriptPath @a *>&1 | Out-String -Width 400 | Write-Host
        $sw.Stop()
        $new = @(Get-ChildItem -LiteralPath $ResultsDir -Filter "tasks-$t-*.json" -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime)
        $json = if ($new) { Get-Content -Raw -LiteralPath $new[-1].FullName | ConvertFrom-Json } else { $null }
        $v = Get-AttemptVerdict $json
        $reasons += $v.Reason
        $runs += $(if ($new) { $new[-1].Name } else { "-" })
        $seconds += $(if ($json -and $json.elapsedSec) { [double]$json.elapsedSec } else { $sw.Elapsed.TotalSeconds })
        if ($json -and $json.usage -and $json.usage.output) { $out += [int]$json.usage.output }
        if ($v.Accepted) { $accepted = $true; $acceptedAt = $n }
        Write-Host ("    attempt {0}: {1}" -f $n, $v.Reason)
    }
    $row = [pscustomobject]@{ Task = $t; Attempts = $n; Accepted = $accepted; AcceptedAttempt = $acceptedAt; Reasons = ($reasons -join ";"); Seconds = [math]::Round($seconds, 1); OutputTokens = $out; Runs = ($runs -join ";") }
    $rows += $row
    Add-Content -LiteralPath $summary -Value (@((Get-Date -Format s), $t, $Model, $MaxAttempts, $n, $accepted, $(if ($acceptedAt) { $acceptedAt } else { "-" }), $row.Reasons, $row.Seconds, $out, $row.Runs) -join "`t")
    Write-Host ("  {0}: {1} after {2} attempt(s) [{3}]" -f $t, $(if ($accepted) { "ACCEPTED" } else { "NOT ACCEPTED (cap)" }), $n, $row.Reasons)
}

$f = Get-RetryFalsifier -Rows $rows -Cap $MaxAttempts -MaxMean $MaxMeanAttempts -MaxCapShare $MaxCapHitShare
Write-Host ""
Write-Host ("retries: {0} task(s), {1} accepted, mean {2} attempt(s) per task, cap reached on {3} ({4})" -f $f.Tasks, @($rows | Where-Object Accepted).Count, $f.MeanAttempts, $f.CapHits, $f.CapHitShare)
Write-Host ("falsifier: {0} - {1}" -f $(if ($f.Falsified) { "FALSIFIED" } else { "holds" }), $f.Detail) -ForegroundColor $(if ($f.Falsified) { "Red" } else { "Green" })
exit 0

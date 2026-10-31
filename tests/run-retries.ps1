# run-retries.ps1 - milestone 4's dispatcher loop: retry a task until an attempt is accepted or a cap is reached.
#
# Why this exists (docs/target-setup.md milestone 4; docs/roadmap.md -> "After the trial" item 6): in real use the
# planner hands the executor a failing test, and the dispatcher keeps the first attempt that makes it pass. Milestone 3
# measured that a shown test works as that gate, and that failures are persistent per task, so the design is a
# sequential retry with a small cap, not N attempts at once (docs/adversarial-review-2026-10-23.md).
#
# What it does: for each task, run the real test-tasks.ps1 once per attempt (each attempt is a fresh sealed checkout,
# graded by every existing gate) and stop at the first ACCEPTED attempt or at -MaxAttempts. An attempt is accepted on
# what a dispatcher can see: the given tests pass (the run JSON's `selector`; `acceptance` for a run JSON that has none),
# they were left alone (scope; a tamper fails it) and the suite is green. With the task's own tests shown the selector is
# an oracle (they are the hidden tests). With a planner's set (-HarnessArgs @{ AcceptanceDir = "planner/{task}/1" }, experiment 3,
# docs/planner-tests-experiment.md) it is not, and the hidden tests' verdict is only recorded: per attempt in the
# summary's `selectors` and `truths`, per task as `falsePositive` (the accepted attempt fails the hidden tests) and
# `falseNegatives` (attempts the selector rejected that the hidden tests pass). The truth never decides an attempt.
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

# The verdict of one attempt's run JSON, or "infrastructure" when the attempt left none. Selector is what the dispatcher
# decides on (the shown tests' verdict: the JSON's `selector`, else `acceptance`), Truth is the hidden tests' verdict
# (`acceptance`), kept for the analysis. A rejection on a planner's set is "selector"; on the task's own tests, as before,
# "acceptance".
function Get-AttemptVerdict {
    param($Json)
    if (-not $Json) { return [pscustomobject]@{ Accepted = $false; Reason = "infrastructure"; Selector = $null; Truth = $null } }
    $hasSel = [bool]($Json.PSObject.Properties['selector'] -and $Json.selector)
    $selector = if ($hasSel) { [string]$Json.selector.status } else { [string]$Json.acceptance.status }
    $selReason = if ($hasSel -and $Json.selector.source -eq "planner") { "selector" } else { "acceptance" }
    $truth = [string]$Json.acceptance.status
    $v = { param($accepted, $reason) [pscustomobject]@{ Accepted = $accepted; Reason = $reason; Selector = $selector; Truth = $truth } }
    $tampered = @($Json.acceptanceShown.tampered | Where-Object { $_ }).Count -gt 0
    if ($tampered) { return & $v $false "tampered" }
    if ($selector -ne "PASS") { return & $v $false $selReason }
    if ($Json.gates.suite -ne "PASS") { return & $v $false "suite" }
    if ($Json.gates.scope -ne "PASS") { return & $v $false "scope" }
    return & $v $true "accepted"
}

# Over the summary rows: how often the selector let wrong code through, and turned right code away. A task is a
# false positive when its accepted attempt failed the hidden tests; an attempt is a false negative when the selector
# failed it and the hidden tests passed it. Only rows that recorded a selector count.
function Get-SelectorSummary {
    param([object[]]$Rows)
    $withSel = @($Rows | Where-Object { $_.Selectors })
    $accepted = @($withSel | Where-Object { $_.Accepted })
    $fn = ($withSel | Measure-Object -Property FalseNegatives -Sum).Sum
    [pscustomobject]@{
        Tasks          = $withSel.Count
        Accepted       = $accepted.Count
        FalsePositives = @($accepted | Where-Object { $_.FalsePositive -eq $true }).Count
        FalseNegatives = $(if ($fn) { [int]$fn } else { 0 })
    }
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
    Set-Content -LiteralPath $summary -Value ("timestamp`ttask`tmodel`tmaxAttempts`tattempts`taccepted`tacceptedAttempt`treasons`tseconds`toutputTokens`truns`tselectors`ttruths`tfalsePositive`tfalseNegatives")
}
# A summary written before the selector columns existed keeps its 11 columns: a longer row would misalign it.
$summaryHasSelector = [bool]((Get-Content -LiteralPath $summary -TotalCount 1) -match "`tselectors`t")
$plannerSeen = $false
Write-Host ("retries: up to {0} attempt(s) per task, {1} task(s), model {2}; rows to {3}" -f $MaxAttempts, $Tasks.Count, $Model, $summary)

$rows = @()
foreach ($t in $Tasks) {
    $reasons = @(); $runs = @(); $selectors = @(); $truths = @(); $seconds = 0.0; $out = 0; $accepted = $false; $acceptedAt = $null; $n = 0
    while ($n -lt $MaxAttempts -and -not $accepted) {
        $n++
        Write-Host ("##### retries {0} attempt {1} of {2} {3}" -f $t, $n, $MaxAttempts, (Get-Date -Format o))
        $before = @(Get-ChildItem -LiteralPath $ResultsDir -Filter "tasks-$t-*.json" -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $a = @{} + $HarnessArgs
        # {task} in a string argument is the task being run: one AcceptanceDir for all, planner/{task}/1.
        foreach ($k in @($a.Keys)) { if ($a[$k] -is [string] -and $a[$k].Contains("{task}")) { $a[$k] = $a[$k].Replace("{task}", $t) } }
        $a.Task = $t; $a.Model = $Model; $a.TaskManifest = $TaskManifest; $a.ResultsDir = $ResultsDir; $a.ShowAcceptance = $true
        if ($ReadOnlyAcceptance) { $a.ReadOnlyAcceptance = $true }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # A harness that throws is an infrastructure attempt (no run JSON), not the end of the loop.
        try { & $ScriptPath @a *>&1 | Out-String -Width 400 | Write-Host } catch { Write-Host ("    harness threw: {0}" -f $_.Exception.Message) -ForegroundColor Red }
        $sw.Stop()
        # Only this model's JSON counts as this attempt's: another model's run in the same folder is not it.
        $new = @(Get-ChildItem -LiteralPath $ResultsDir -Filter "tasks-$t-*.json" -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime |
            Where-Object { try { $m = (Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json).model; (-not $m) -or ($m -eq $Model) } catch { $false } })
        $json = if ($new) { Get-Content -Raw -LiteralPath $new[-1].FullName | ConvertFrom-Json } else { $null }
        $v = Get-AttemptVerdict $json
        $reasons += $v.Reason
        $selectors += $(if ($v.Selector) { $v.Selector } else { "-" })
        $truths += $(if ($v.Truth) { $v.Truth } else { "-" })
        if ($json -and $json.PSObject.Properties['selector'] -and $json.selector -and $json.selector.source -eq "planner") { $plannerSeen = $true }
        $runs += $(if ($new) { $new[-1].Name } else { "-" })
        $seconds += $(if ($json -and $json.elapsedSec) { [double]$json.elapsedSec } else { $sw.Elapsed.TotalSeconds })
        if ($json -and $json.usage -and $json.usage.output) { $out += [int]$json.usage.output }
        if ($v.Accepted) { $accepted = $true; $acceptedAt = $n }
        Write-Host ("    attempt {0}: {1}" -f $n, $v.Reason)
    }
    # The hidden tests' verdict beside the selector's: wrong code accepted, right code turned away.
    $fp = if ($accepted) { $truths[$acceptedAt - 1] -ne "PASS" } else { $null }
    $fn = 0; for ($k = 0; $k -lt $selectors.Count; $k++) { if ($selectors[$k] -eq "FAIL" -and $truths[$k] -eq "PASS") { $fn++ } }
    $row = [pscustomobject]@{ Task = $t; Attempts = $n; Accepted = $accepted; AcceptedAttempt = $acceptedAt; Reasons = ($reasons -join ";"); Seconds = [math]::Round($seconds, 1); OutputTokens = $out; Runs = ($runs -join ";")
        Selectors = ($selectors -join ";"); Truths = ($truths -join ";"); FalsePositive = $fp; FalseNegatives = $fn }
    $rows += $row
    $fields = @((Get-Date -Format s), $t, $Model, $MaxAttempts, $n, $accepted, $(if ($acceptedAt) { $acceptedAt } else { "-" }), $row.Reasons, $row.Seconds, $out, $row.Runs)
    if ($summaryHasSelector) { $fields += @($row.Selectors, $row.Truths, $(if ($null -eq $fp) { "-" } else { $fp }), $fn) }
    Add-Content -LiteralPath $summary -Value ($fields -join "`t")
    Write-Host ("  {0}: {1} after {2} attempt(s) [{3}]" -f $t, $(if ($accepted) { "ACCEPTED" } else { "NOT ACCEPTED (cap)" }), $n, $row.Reasons)
}

$f = Get-RetryFalsifier -Rows $rows -Cap $MaxAttempts -MaxMean $MaxMeanAttempts -MaxCapShare $MaxCapHitShare
Write-Host ""
Write-Host ("retries: {0} task(s), {1} accepted, mean {2} attempt(s) per task, cap reached on {3} ({4})" -f $f.Tasks, @($rows | Where-Object Accepted).Count, $f.MeanAttempts, $f.CapHits, $f.CapHitShare)
Write-Host ("falsifier: {0} - {1}" -f $(if ($f.Falsified) { "FALSIFIED" } else { "holds" }), $f.Detail) -ForegroundColor $(if ($f.Falsified) { "Red" } else { "Green" })
if ($plannerSeen) {
    $sel = Get-SelectorSummary -Rows $rows
    Write-Host ("selector (the planner's tests) against the hidden tests: {0} task(s) accepted, {1} of them wrong by the hidden tests (false positives); {2} attempt(s) rejected that the hidden tests pass (false negatives)" -f $sel.Accepted, $sel.FalsePositives, $sel.FalseNegatives)
}
exit 0

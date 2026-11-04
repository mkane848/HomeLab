# summarize-rounds.ps1 - per-task pass counts, pass@k and pass^k over results folders.
#
# Why: a round's headline ("47 of 60") is the per-run pass rate. For work that is
# meant to run unattended once a plan is approved (docs/target-setup.md), the
# number that matters is how often a task passes every time, pass^k, beside how
# often it passes at least once, pass@k ("Demystifying evals for AI agents",
# Anthropic, 2026-01-09). The desktop's four plugin-on reps were 47 of 60 per
# run, 13 of 15 tasks at least once, but 9 of 15 every time.
#
# What it does: reads every run JSON (tasks-*.json) under -ResultsDir, recursively,
# and per model (and task) counts graded runs n and passes c. A run passes when
#   - a real task (`grading: acceptance`): the hidden tests, scope and suite all PASS;
#   - a public task (no grading field): scope, suite and failsOnOld all PASS
#     (tests/results/README.md -> "What counts as a pass");
#   - a checklist task is rated by the owner, so it is left out and counted.
# pass@k and pass^k use the unbiased estimators over the n runs held:
#   pass@k = 1 - C(n-c, k) / C(n, k)      pass^k = C(c, k) / C(n, k)
# k defaults to the smallest n among the tasks of ALL models shown (one k, so the
# models' means are comparable); a task with fewer than k runs is listed and left
# out of the means.
# Rows are grouped by model AND arm: a run in a folder (or under one) that holds an
# ASSISTED, ACCEPTANCE-SHOWN, ACCEPTANCE-READONLY or ACCEPTANCE-PLANNER marker is a
# different condition and is never pooled with unmarked runs. A group of planner-shown
# runs (experiment 3, docs/planner-tests-experiment.md) also gets the selector against
# the truth: how often the planner's tests passed code the hidden tests fail (false
# positives, the rate that decides milestone 5) and failed code they pass (false negatives). Run JSONs whose agent exit was not 0 (an
# infrastructure failure, no measurement) are skipped and counted. Runs of one
# group that differ in numCtx, engine, plugins or agent version are pooled but
# listed under "eras" so the mix is visible.
#
# Per group it also prints (2026-11-03) the output cap (runs that lost a step to limit.output, with the pass rate
# of runs with and without one), with -StepTokens N the same split for steps of N+ output tokens (a thinking
# budget reached), and the cost of the passes (passes per 100k output tokens, minutes per pass), after Mia and
# Amini, "Don't Overthink, Don't Underthink" (arXiv 2608.26442): hit against no-hit accuracy, accuracy per token.
# Timed-out runs leave no run JSON; their number is printed so the cost line is not read as complete.
#
# Usage:  .\tests\summarize-rounds.ps1 -ResultsDir <folder>[,<folder>...] [-K n] [-StepTokens n] [-Model <id>] [-AsJson]
param(
    [string[]]$ResultsDir,
    [int]$K = 0,
    # Split runs by whether any step reached this many output tokens (a thinking budget); 0 = off.
    [int]$StepTokens = 0,
    [string]$Model = "",
    [switch]$AsJson
)

function Get-Binomial {
    # C(n, r) as a double; 0 when r is out of range.
    param([int]$N, [int]$R)
    if ($R -lt 0 -or $R -gt $N) { return 0.0 }
    $v = 1.0
    for ($i = 1; $i -le $R; $i++) { $v = $v * ($N - $R + $i) / $i }
    return $v
}

function Get-PassAtK {
    param([int]$N, [int]$C, [int]$K)
    if ($K -lt 1 -or $N -lt $K) { return $null }
    return 1.0 - (Get-Binomial ($N - $C) $K) / (Get-Binomial $N $K)
}

function Get-PassHatK {
    param([int]$N, [int]$C, [int]$K)
    if ($K -lt 1 -or $N -lt $K) { return $null }
    return (Get-Binomial $C $K) / (Get-Binomial $N $K)
}

function Get-RunVerdict {
    # PASS, FAIL or MANUAL (checklist: the owner rates it) for one run JSON.
    param($Run)
    $g = $Run.gates
    if ($Run.grading -eq "checklist") { return "MANUAL" }
    if ($Run.grading -eq "acceptance") {
        $ok = $Run.acceptance -and $Run.acceptance.status -eq "PASS" -and $g.scope -eq "PASS" -and $g.suite -eq "PASS"
        return $(if ($ok) { "PASS" } else { "FAIL" })
    }
    $ok = $g.scope -eq "PASS" -and $g.suite -eq "PASS" -and $g.failsOnOld -eq "PASS"
    return $(if ($ok) { "PASS" } else { "FAIL" })
}

function Get-WilsonInterval {
    # The 95% Wilson score interval for k of n.
    param([int]$K, [int]$N, [double]$Z = 1.96)
    if ($N -le 0) { return $null }
    $p = $K / $N; $z2 = $Z * $Z; $den = 1 + $z2 / $N
    $center = ($p + $z2 / (2 * $N)) / $den
    $half = $Z * [math]::Sqrt($p * (1 - $p) / $N + $z2 / (4 * $N * $N)) / $den
    return [pscustomobject]@{ Low = [math]::Max(0.0, $center - $half); High = [math]::Min(1.0, $center + $half) }
}

function Get-SelectorConfusion {
    # Planner-shown runs only (selector.source "planner"): the verdict of the tests the model was shown against
    # the hidden tests' (`acceptance`). "Accepted" is what a dispatcher would keep: selector, scope and suite PASS,
    # nothing tampered, integrity not FAIL (run-retries.ps1's rule; rows before 2026-11-01 have no integrity gate).
    # $null when no run has a planner selector.
    param([object[]]$Runs)
    $pl = @($Runs | Where-Object { $_.PSObject.Properties['selector'] -and $_.selector -and $_.selector.source -eq "planner" })
    if ($pl.Count -eq 0) { return $null }
    $selPass = @($pl | Where-Object { $_.selector.status -eq "PASS" })
    $selFail = @($pl | Where-Object { $_.selector.status -eq "FAIL" })
    $accepted = @($selPass | Where-Object { $_.gates.scope -eq "PASS" -and $_.gates.suite -eq "PASS" -and @($_.acceptanceShown.tampered | Where-Object { $_ }).Count -eq 0 -and -not ($_.gates.PSObject.Properties['integrity'] -and $_.gates.integrity -eq "FAIL") })
    [pscustomobject]@{
        runs = $pl.Count
        selectorPass = $selPass.Count
        falsePositives = @($selPass | Where-Object { $_.acceptance.status -ne "PASS" }).Count
        selectorFail = $selFail.Count
        falseNegatives = @($selFail | Where-Object { $_.acceptance.status -eq "PASS" }).Count
        selectorOther = $pl.Count - $selPass.Count - $selFail.Count
        accepted = $accepted.Count
        acceptedWrong = @($accepted | Where-Object { $_.acceptance.status -ne "PASS" }).Count
    }
}

function Get-IdealSummary {
    # The owner's Ideal tier (2026-11-01): over the runs that recorded one (`ideal.total` > 0), how much of the best
    # answer the attempts did. Never a pass/fail input; the metric for comparing models and configurations. Also the
    # integrity gate's failures (the standing hard blocks), so a round shows how often it blocked. $null when no run
    # has either.
    param([object[]]$Runs)
    $withIdeal = @($Runs | Where-Object { $_.PSObject.Properties['ideal'] -and $_.ideal -and $_.ideal.total -gt 0 })
    $withIntegrity = @($Runs | Where-Object { $_.gates -and $_.gates.PSObject.Properties['integrity'] -and $_.gates.integrity -in "PASS", "FAIL" })
    if (-not $withIdeal.Count -and -not $withIntegrity.Count) { return $null }
    $done = ($withIdeal | ForEach-Object { [int]$_.ideal.done } | Measure-Object -Sum).Sum
    $total = ($withIdeal | ForEach-Object { [int]$_.ideal.total } | Measure-Object -Sum).Sum
    [pscustomobject]@{
        runs = $withIdeal.Count
        itemsDone = [int]$done
        itemsTotal = [int]$total
        share = $(if ($total) { [math]::Round($done / $total, 3) } else { $null })
        # Per run, then averaged: a task with many ideal items does not outweigh the rest.
        meanPerRun = $(if ($withIdeal.Count) { [math]::Round(($withIdeal | ForEach-Object { [double]$_.ideal.done / [double]$_.ideal.total } | Measure-Object -Average).Average, 3) } else { $null })
        integrityChecked = $withIntegrity.Count
        integrityFailed = @($withIntegrity | Where-Object { $_.gates.integrity -eq "FAIL" }).Count
    }
}

function Get-CapSummary {
    # The output cap (limit.output): over the graded runs whose capped steps are known (`capSteps`, set when the run
    # JSONs are read: the run's `cappedSteps`, else counted from its transcript against its `outputLimit`), how many
    # lost a step to the cap, how many of those still passed, and how many of all failures had one. The 2026-11-03
    # desk review found 11 of qwen3.6's 15 failures there by hand; this keeps that count in every round. $null when
    # no run's count is known.
    param([object[]]$Runs)
    $known = @($Runs | Where-Object { $_.PSObject.Properties['capSteps'] -and $null -ne $_.capSteps -and (Get-RunVerdict $_) -ne "MANUAL" })
    if ($known.Count -eq 0) { return $null }
    $capped = @($known | Where-Object { [int]$_.capSteps -gt 0 })
    $uncapped = @($known | Where-Object { [int]$_.capSteps -eq 0 })
    $failed = @($known | Where-Object { (Get-RunVerdict $_) -eq "FAIL" })
    [pscustomobject]@{
        runs = $known.Count
        withCap = $capped.Count
        withCapPassed = @($capped | Where-Object { (Get-RunVerdict $_) -eq "PASS" }).Count
        # The other side of the split ("hit" against "no-hit" accuracy, Mia and Amini 2026): if runs that hit the cap
        # pass about as often as the rest, the cap costs nothing; if they rarely pass, the extra room was not used.
        withoutCap = $uncapped.Count
        withoutCapPassed = @($uncapped | Where-Object { (Get-RunVerdict $_) -eq "PASS" }).Count
        failures = $failed.Count
        failuresWithCap = @($failed | Where-Object { [int]$_.capSteps -gt 0 }).Count
    }
}

function Get-LongStepSummary {
    # -StepTokens N: the same split for runs with a step of N or more output tokens (`longSteps`, counted from the
    # transcripts). Meant for a thinking budget (llama-server's --reasoning-budget): OpenCode does not record thinking
    # tokens, so a step at or over the budget is the visible sign the budget was reached. Approximate: a step's output
    # also holds its text and tool call, so a step just under the budget plus a long write counts too. $null without
    # -StepTokens or when no run's count is known.
    param([object[]]$Runs, [int]$Threshold)
    if ($Threshold -le 0) { return $null }
    $known = @($Runs | Where-Object { $_.PSObject.Properties['longSteps'] -and $null -ne $_.longSteps -and (Get-RunVerdict $_) -ne "MANUAL" })
    if ($known.Count -eq 0) { return $null }
    $hit = @($known | Where-Object { [int]$_.longSteps -gt 0 })
    $miss = @($known | Where-Object { [int]$_.longSteps -eq 0 })
    [pscustomobject]@{
        threshold = $Threshold
        runs = $known.Count
        withLong = $hit.Count
        withLongPassed = @($hit | Where-Object { (Get-RunVerdict $_) -eq "PASS" }).Count
        withoutLong = $miss.Count
        withoutLongPassed = @($miss | Where-Object { (Get-RunVerdict $_) -eq "PASS" }).Count
    }
}

function Get-CostSummary {
    # What the passes cost (Mia and Amini 2026 propose "accuracy per reasoning token"; OpenCode records no thinking
    # tokens, so output tokens, which include them, stand in): over graded runs that recorded `usage.output` and
    # `elapsedSec`, passes per 100,000 output tokens, minutes per pass, and the mean per run. Timeouts leave no run
    # JSON, so their time is not here; the script prints how many there were. $null when no run has both.
    param([object[]]$Runs)
    $known = @($Runs | Where-Object { $_.PSObject.Properties['usage'] -and $_.usage -and $null -ne $_.usage.output -and $_.PSObject.Properties['elapsedSec'] -and $null -ne $_.elapsedSec -and (Get-RunVerdict $_) -ne "MANUAL" })
    if ($known.Count -eq 0) { return $null }
    $passes = @($known | Where-Object { (Get-RunVerdict $_) -eq "PASS" }).Count
    $out = [double](($known | ForEach-Object { [double]$_.usage.output } | Measure-Object -Sum).Sum)
    $min = [double](($known | ForEach-Object { [double]$_.elapsedSec } | Measure-Object -Sum).Sum) / 60
    [pscustomobject]@{
        runs = $known.Count
        passes = $passes
        outputTokens = [int64]$out
        minutes = [math]::Round($min, 1)
        passesPer100kOutput = $(if ($out -gt 0) { [math]::Round($passes * 100000 / $out, 2) } else { $null })
        minutesPerPass = $(if ($passes) { [math]::Round($min / $passes, 1) } else { $null })
        outputPerRun = [math]::Round($out / $known.Count)
        minutesPerRun = [math]::Round($min / $known.Count, 1)
    }
}

function Get-TranscriptLongSteps {
    # Steps in a transcript whose output tokens are at least $Min (and, with -LengthOnly, that ended "length").
    # Needs Read-AgentEvents. $null when the transcript is missing.
    param([string]$Path, [int]$Min, [switch]$LengthOnly)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $n = 0
    foreach ($e in (Read-AgentEvents -Path $Path)) {
        if ($e.Kind -ne "step-end" -or $null -eq $e.Output -or [int]$e.Output -lt $Min) { continue }
        if ($LengthOnly -and $e.Finish -ne "length") { continue }
        $n++
    }
    return $n
}

function Get-RunCapSteps {
    # A run's capped-step count: the run JSON's `cappedSteps` when it has one (2026-11-03 on), else counted from the
    # transcript beside it (same name, .jsonl) against its `outputLimit`, so older rounds are summarized the same way.
    # $null when neither is available. Needs Read-AgentEvents (the agent adapter, dot-sourced by the caller).
    param($Run, [string]$JsonPath)
    if ($Run.PSObject.Properties['cappedSteps']) { return $Run.cappedSteps }
    $lim = if ($Run.PSObject.Properties['outputLimit']) { $Run.outputLimit } else { $null }
    if ($null -eq $lim -or "$lim" -notmatch '^\d+$') { return $null }
    return (Get-TranscriptLongSteps -Path ([IO.Path]::ChangeExtension($JsonPath, ".jsonl")) -Min ([int]$lim) -LengthOnly)
}

function Get-RoundSummary {
    # One summary per model over the run objects given.
    param([object[]]$Runs, [int]$K = 0, [int]$StepTokens = 0)
    $out = @()
    $groups = @()
    foreach ($mg in ($Runs | Group-Object { "$($_.model)|$(if ($_.PSObject.Properties['arm']) { $_.arm })" } | Sort-Object Name)) {
        $tasks = @()
        $manual = 0
        $zeroWritePasses = 0
        foreach ($tg in ($mg.Group | Group-Object taskId | Sort-Object Name)) {
            $verdicts = @($tg.Group | ForEach-Object { Get-RunVerdict $_ })
            $manual += @($verdicts | Where-Object { $_ -eq "MANUAL" }).Count
            $graded = @($verdicts | Where-Object { $_ -ne "MANUAL" })
            for ($i = 0; $i -lt $verdicts.Count; $i++) {
                $w = $tg.Group[$i].PSObject.Properties['writes']
                if ($verdicts[$i] -eq "PASS" -and $w -and $null -ne $w.Value -and [int]$w.Value -le 0) { $zeroWritePasses++ }
            }
            if ($graded.Count -eq 0) { continue }
            $tasks += [pscustomobject]@{ task = $tg.Name; n = $graded.Count; c = @($graded | Where-Object { $_ -eq "PASS" }).Count }
        }
        # Era fields that differ inside the group: pooled, but the mix is shown.
        $eras = [ordered]@{}
        $probe = @{
            numCtx        = { param($r) $r.numCtx }
            engine        = { param($r) if ($r.engine) { "$($r.engine.name) $($r.engine.version)".Trim() } }
            plugins       = { param($r) if ($r.PSObject.Properties['opencodePlugins']) { (@($r.opencodePlugins) | ForEach-Object { Split-Path -Leaf "$_" } | Sort-Object) -join "+" } }
            agentVersion  = { param($r) if ($r.agent) { $r.agent.version } }
        }
        foreach ($name in ($probe.Keys | Sort-Object)) {
            $vals = @($mg.Group | ForEach-Object { & $probe[$name] $_ } | Where-Object { $null -ne $_ -and "$_" -ne "" } | ForEach-Object { "$_" } | Sort-Object -Unique)
            if ($vals.Count -gt 1) { $eras[$name] = $vals }
        }
        $first = $mg.Group[0]
        $groups += [pscustomobject]@{ model = $first.model; arm = $(if ($first.PSObject.Properties['arm']) { $first.arm } else { "" }); tasks = $tasks; manual = $manual; eras = $eras; zeroWritePasses = $zeroWritePasses; selector = (Get-SelectorConfusion $mg.Group); ideal = (Get-IdealSummary $mg.Group); cap = (Get-CapSummary $mg.Group); longSteps = (Get-LongStepSummary $mg.Group $StepTokens); cost = (Get-CostSummary $mg.Group) }
    }
    # One k for every model shown, so the means can be compared across models.
    $allN = @($groups | ForEach-Object { $_.tasks } | ForEach-Object { $_.n })
    $k = if ($K -gt 0) { $K } elseif ($allN.Count) { ($allN | Measure-Object -Minimum).Minimum } else { 0 }
    foreach ($grp in $groups) {
        $tasks = $grp.tasks
        $manual = $grp.manual
        foreach ($t in $tasks) {
            $t | Add-Member -NotePropertyName passAtK -NotePropertyValue (Get-PassAtK $t.n $t.c $k)
            $t | Add-Member -NotePropertyName passHatK -NotePropertyValue (Get-PassHatK $t.n $t.c $k)
        }
        $scored = @($tasks | Where-Object { $null -ne $_.passAtK })
        $runCount = ($tasks | Measure-Object n -Sum).Sum
        $passCount = ($tasks | Measure-Object c -Sum).Sum
        $out += [pscustomobject]@{
            model = $grp.model; arm = $grp.arm; k = $k; tasks = $tasks
            eras = $grp.eras; zeroWritePasses = $grp.zeroWritePasses; selector = $grp.selector; ideal = $grp.ideal; cap = $grp.cap; longSteps = $grp.longSteps; cost = $grp.cost
            runs = [int]$runCount; passes = [int]$passCount
            perRun = $(if ($runCount) { [math]::Round($passCount / $runCount, 3) } else { $null })
            passAtK = $(if ($scored.Count) { [math]::Round(($scored | Measure-Object passAtK -Average).Average, 3) } else { $null })
            passHatK = $(if ($scored.Count) { [math]::Round(($scored | Measure-Object passHatK -Average).Average, 3) } else { $null })
            tasksAlwaysPassed = @($tasks | Where-Object { $_.c -eq $_.n }).Count
            tasksNeverPassed = @($tasks | Where-Object { $_.c -eq 0 }).Count
            tasksBelowK = @($tasks | Where-Object { $null -eq $_.passAtK } | ForEach-Object task)
            manualRuns = $manual
        }
    }
    return , $out
}

if ($MyInvocation.InvocationName -ne '.' -and $ResultsDir) {
    $runs = @()
    $skippedExit = 0
    $markerNames = @("ASSISTED", "ACCEPTANCE-SHOWN", "ACCEPTANCE-READONLY", "ACCEPTANCE-PLANNER")
    # Read-AgentEvents, for counting capped steps in transcripts older than the run JSON's `cappedSteps`.
    . (Join-Path (Join-Path $PSScriptRoot "agents") "opencode.ps1")
    foreach ($d in $ResultsDir) {
        if (-not (Test-Path -LiteralPath $d)) { Write-Host "ERROR: no folder $d" -ForegroundColor Red; exit 1 }
        $root = (Resolve-Path -LiteralPath $d).Path.TrimEnd('\', '/')
        foreach ($f in Get-ChildItem -LiteralPath $d -Recurse -Filter "tasks-*.json") {
            try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (-not $j -or -not $j.taskId -or -not $j.gates) { continue }
            if ($Model -and $j.model -ne $Model) { continue }
            # A non-zero agent exit never reached the model (or was not lifted): no measurement.
            $ex = $j.PSObject.Properties['opencodeExit']
            if ($ex -and $null -ne $ex.Value -and "$($ex.Value)" -match '^-?\d+$' -and [int]$ex.Value -ne 0) { $skippedExit++; continue }
            # The arm: markers in the run's folder or any folder above it, up to the one given.
            $arm = @()
            $dir = $f.DirectoryName
            while ($dir -and $dir.Length -ge $root.Length) {
                foreach ($m in $markerNames) { if ((Test-Path -LiteralPath (Join-Path $dir $m)) -and $arm -notcontains $m) { $arm += $m } }
                if ($dir.TrimEnd('\', '/') -eq $root) { break }
                $dir = Split-Path -Parent $dir
            }
            $j | Add-Member -NotePropertyName arm -NotePropertyValue (($arm | Sort-Object) -join "+") -Force
            $j | Add-Member -NotePropertyName capSteps -NotePropertyValue (Get-RunCapSteps $j $f.FullName) -Force
            if ($StepTokens -gt 0) { $j | Add-Member -NotePropertyName longSteps -NotePropertyValue (Get-TranscriptLongSteps -Path ([IO.Path]::ChangeExtension($f.FullName, ".jsonl")) -Min $StepTokens) -Force }
            $runs += $j
        }
    }
    if ($runs.Count -eq 0) { Write-Host "ERROR: no run JSONs under $($ResultsDir -join ', ')" -ForegroundColor Red; exit 1 }
    $summary = Get-RoundSummary -Runs $runs -K $K -StepTokens $StepTokens
    if ($AsJson) { $summary | ConvertTo-Json -Depth 6; exit 0 }
    $timeouts = @($ResultsDir | ForEach-Object { Get-ChildItem -LiteralPath $_ -Recurse -Filter "tasks-*_TIMEOUT_*.jsonl" -ErrorAction SilentlyContinue }).Count
    if ($timeouts) { Write-Host ("{0} run(s) timed out: not graded, and not in the numbers below (their time is not in the cost line either)" -f $timeouts) -ForegroundColor Yellow }
    if ($skippedExit) { Write-Host ("{0} run JSON(s) with a non-zero agent exit skipped (infrastructure: no measurement)" -f $skippedExit) -ForegroundColor Yellow }
    foreach ($s in $summary) {
        Write-Host ""
        $label = if ($s.arm) { "$($s.model) [$($s.arm)]" } else { $s.model }
        Write-Host ("{0}: {1} graded runs, {2} passed ({3:P0} per run); k = {4}" -f $label, $s.runs, $s.passes, $s.perRun, $s.k)
        foreach ($name in $s.eras.Keys) { Write-Host ("  WARN pooled across different {0}: {1}" -f $name, ($s.eras[$name] -join " | ")) -ForegroundColor Yellow }
        if ($s.zeroWritePasses) { Write-Host ("  note: {0} passing run(s) recorded no write/edit tool call (edits made through the shell?); the harness counts those as liar mode" -f $s.zeroWritePasses) -ForegroundColor Yellow }
        Write-Host ("  pass@{0} {1:N3}  pass^{0} {2:N3}  (means over tasks); passed every run: {3} of {4} tasks; never: {5}" -f $s.k, $s.passAtK, $s.passHatK, $s.tasksAlwaysPassed, $s.tasks.Count, $s.tasksNeverPassed)
        if ($s.tasksBelowK.Count) { Write-Host ("  fewer than {0} runs, left out of the means: {1}" -f $s.k, ($s.tasksBelowK -join ", ")) }
        if ($s.manualRuns) { Write-Host ("  {0} checklist run(s) left out: the owner rates them" -f $s.manualRuns) }
        if ($s.selector) {
            $c = $s.selector
            $fmt = { param($k, $n) $w = Get-WilsonInterval $k $n; if ($w) { "{0} of {1} ({2:P0}, 95% CI {3:P0} to {4:P0})" -f $k, $n, ($k / $n), $w.Low, $w.High } else { "none" } }
            Write-Host ("  selector (the planner's tests) against the hidden tests, {0} run(s):" -f $c.runs)
            Write-Host ("    false positives (selector PASS, hidden tests FAIL): {0}" -f (& $fmt $c.falsePositives $c.selectorPass))
            Write-Host ("    false negatives (selector FAIL, hidden tests PASS): {0}" -f (& $fmt $c.falseNegatives $c.selectorFail))
            Write-Host ("    kept by a dispatcher (selector, scope and suite PASS, nothing tampered) but wrong by the hidden tests: {0}" -f (& $fmt $c.acceptedWrong $c.accepted))
            if ($c.selectorOther) { Write-Host ("    {0} run(s) whose selector neither passed nor failed (could not run)" -f $c.selectorOther) -ForegroundColor Yellow }
        }
        if ($s.ideal) {
            $i = $s.ideal
            if ($i.runs) { Write-Host ("  ideal tier (measured, never a gate): {0} of {1} item(s) done over {2} run(s) ({3:P0}; mean per run {4:P0})" -f $i.itemsDone, $i.itemsTotal, $i.runs, $i.share, $i.meanPerRun) }
            if ($i.integrityChecked) { Write-Host ("  integrity gate (nothing lost, nothing wrong): {0} of {1} run(s) that changed Markdown blocked" -f $i.integrityFailed, $i.integrityChecked) }
        }
        if ($s.cap) {
            $cp = $s.cap
            Write-Host ("  output cap (limit.output): {0} of {1} run(s) lost a step to it, {2} of those passed; {3} of {4} failure(s) had one; runs without one: {5} of {6} passed" -f $cp.withCap, $cp.runs, $cp.withCapPassed, $cp.failuresWithCap, $cp.failures, $cp.withoutCapPassed, $cp.withoutCap)
        }
        if ($s.longSteps) {
            $ls = $s.longSteps
            Write-Host ("  steps of {0}+ output tokens (a thinking budget reached, approximately): {1} of {2} run(s) had one, {3} of those passed; runs without one: {4} of {5} passed" -f $ls.threshold, $ls.withLong, $ls.runs, $ls.withLongPassed, $ls.withoutLongPassed, $ls.withoutLong)
        }
        if ($s.cost) {
            $co = $s.cost
            Write-Host ("  cost: {0:N0} output tokens and {1} min over {2} graded run(s); {3} pass(es) per 100k output tokens, {4} min per pass ({5:N0} tokens, {6} min per run)" -f $co.outputTokens, $co.minutes, $co.runs, $co.passesPer100kOutput, $(if ($null -ne $co.minutesPerPass) { $co.minutesPerPass } else { "-" }), $co.outputPerRun, $co.minutesPerRun)
        }
        $s.tasks | ForEach-Object { [pscustomobject]@{ task = $_.task; runs = $_.n; passed = $_.c; "pass@$($s.k)" = $(if ($null -ne $_.passAtK) { [math]::Round($_.passAtK, 3) } else { "-" }); "pass^$($s.k)" = $(if ($null -ne $_.passHatK) { [math]::Round($_.passHatK, 3) } else { "-" }) } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
}

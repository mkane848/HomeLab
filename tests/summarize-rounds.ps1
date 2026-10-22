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
# k defaults to the smallest n among the tasks; a task with fewer than k runs is
# listed and left out of the means.
#
# Usage:  .\tests\summarize-rounds.ps1 -ResultsDir <folder>[,<folder>...] [-K n] [-Model <id>] [-AsJson]
param(
    [string[]]$ResultsDir,
    [int]$K = 0,
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

function Get-RoundSummary {
    # One summary per model over the run objects given.
    param([object[]]$Runs, [int]$K = 0)
    $out = @()
    foreach ($mg in ($Runs | Group-Object model | Sort-Object Name)) {
        $tasks = @()
        $manual = 0
        foreach ($tg in ($mg.Group | Group-Object taskId | Sort-Object Name)) {
            $verdicts = @($tg.Group | ForEach-Object { Get-RunVerdict $_ })
            $manual += @($verdicts | Where-Object { $_ -eq "MANUAL" }).Count
            $graded = @($verdicts | Where-Object { $_ -ne "MANUAL" })
            if ($graded.Count -eq 0) { continue }
            $tasks += [pscustomobject]@{ task = $tg.Name; n = $graded.Count; c = @($graded | Where-Object { $_ -eq "PASS" }).Count }
        }
        $k = if ($K -gt 0) { $K } elseif ($tasks.Count) { ($tasks | Measure-Object n -Minimum).Minimum } else { 0 }
        foreach ($t in $tasks) {
            $t | Add-Member -NotePropertyName passAtK -NotePropertyValue (Get-PassAtK $t.n $t.c $k)
            $t | Add-Member -NotePropertyName passHatK -NotePropertyValue (Get-PassHatK $t.n $t.c $k)
        }
        $scored = @($tasks | Where-Object { $null -ne $_.passAtK })
        $runCount = ($tasks | Measure-Object n -Sum).Sum
        $passCount = ($tasks | Measure-Object c -Sum).Sum
        $out += [pscustomobject]@{
            model = $mg.Name; k = $k; tasks = $tasks
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
    foreach ($d in $ResultsDir) {
        if (-not (Test-Path -LiteralPath $d)) { Write-Host "ERROR: no folder $d" -ForegroundColor Red; exit 1 }
        foreach ($f in Get-ChildItem -LiteralPath $d -Recurse -Filter "tasks-*.json") {
            try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (-not $j -or -not $j.taskId -or -not $j.gates) { continue }
            if ($Model -and $j.model -ne $Model) { continue }
            $runs += $j
        }
    }
    if ($runs.Count -eq 0) { Write-Host "ERROR: no run JSONs under $($ResultsDir -join ', ')" -ForegroundColor Red; exit 1 }
    $summary = Get-RoundSummary -Runs $runs -K $K
    if ($AsJson) { $summary | ConvertTo-Json -Depth 6; exit 0 }
    foreach ($s in $summary) {
        Write-Host ""
        Write-Host ("{0}: {1} graded runs, {2} passed ({3:P0} per run); k = {4}" -f $s.model, $s.runs, $s.passes, $s.perRun, $s.k)
        Write-Host ("  pass@{0} {1:N3}  pass^{0} {2:N3}  (means over tasks); passed every run: {3} of {4} tasks; never: {5}" -f $s.k, $s.passAtK, $s.passHatK, $s.tasksAlwaysPassed, $s.tasks.Count, $s.tasksNeverPassed)
        if ($s.tasksBelowK.Count) { Write-Host ("  fewer than {0} runs, left out of the means: {1}" -f $s.k, ($s.tasksBelowK -join ", ")) }
        if ($s.manualRuns) { Write-Host ("  {0} checklist run(s) left out: the owner rates them" -f $s.manualRuns) }
        $s.tasks | ForEach-Object { [pscustomobject]@{ task = $_.task; runs = $_.n; passed = $_.c; "pass@$($s.k)" = $(if ($null -ne $_.passAtK) { [math]::Round($_.passAtK, 3) } else { "-" }); "pass^$($s.k)" = $(if ($null -ne $_.passHatK) { [math]::Round($_.passHatK, 3) } else { "-" }) } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
}

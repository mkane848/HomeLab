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
# ASSISTED, ACCEPTANCE-SHOWN or ACCEPTANCE-READONLY marker is a different condition
# and is never pooled with unmarked runs. Run JSONs whose agent exit was not 0 (an
# infrastructure failure, no measurement) are skipped and counted. Runs of one
# group that differ in numCtx, engine, plugins or agent version are pooled but
# listed under "eras" so the mix is visible.
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
        $groups += [pscustomobject]@{ model = $first.model; arm = $(if ($first.PSObject.Properties['arm']) { $first.arm } else { "" }); tasks = $tasks; manual = $manual; eras = $eras; zeroWritePasses = $zeroWritePasses }
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
            eras = $grp.eras; zeroWritePasses = $grp.zeroWritePasses
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
    $markerNames = @("ASSISTED", "ACCEPTANCE-SHOWN", "ACCEPTANCE-READONLY")
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
            $runs += $j
        }
    }
    if ($runs.Count -eq 0) { Write-Host "ERROR: no run JSONs under $($ResultsDir -join ', ')" -ForegroundColor Red; exit 1 }
    $summary = Get-RoundSummary -Runs $runs -K $K
    if ($AsJson) { $summary | ConvertTo-Json -Depth 6; exit 0 }
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
        $s.tasks | ForEach-Object { [pscustomobject]@{ task = $_.task; runs = $_.n; passed = $_.c; "pass@$($s.k)" = $(if ($null -ne $_.passAtK) { [math]::Round($_.passAtK, 3) } else { "-" }); "pass^$($s.k)" = $(if ($null -ne $_.passHatK) { [math]::Round($_.passHatK, 3) } else { "-" }) } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
}

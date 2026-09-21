# run-tasks-batch.ps1 - one-stop entry point for the task-veracity benchmark:
# (1) ensures every task's local `bench/*` branch exists in its repo, then
# (2) interactively picks tasks + models + a repeat count and runs the batch
# through test-tasks.ps1, one (task, model) pair per invocation.
#
# See docs/roadmap.md "Task-veracity benchmark: task set expansion (2026-09-21)"
# for why these 6 branches/commits exist and where the numbers below came from.
#
# Usage:
#   .\tests\run-tasks-batch.ps1                # ensure branches, then prompt
#   .\tests\run-tasks-batch.ps1 -SetupOnly     # just create missing branches, no prompts
#   .\tests\run-tasks-batch.ps1 -SkipSetup     # skip the branch check, go straight to prompts

param(
    [switch]$SetupOnly,
    [switch]$SkipSetup
)

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptDir "tasks\manifest.json"
$testTasksPs1 = Join-Path $scriptDir "test-tasks.ps1"

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "ERROR: manifest not found at $manifestPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $testTasksPs1)) {
    Write-Host "ERROR: test-tasks.ps1 not found next to this script" -ForegroundColor Red
    exit 1
}

$manifest  = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$tasksById = @{}
foreach ($t in $manifest.tasks) { $tasksById[$t.id] = $t }

# --- 1. bench branches: task id -> (branch name, exact pre-fix commit) -----
# Mirrors docs/roadmap.md exactly - each commit is the one immediately BEFORE
# the real merged fix that task grades, independently verified (baseline
# green, failsOnOld red) when the task was authored. Repo path for each is
# read from the manifest, not hardcoded here, so it stays in sync if that
# ever changes.
$benchBranches = @(
    [pscustomobject]@{ TaskId = "kane-02-multiword-creature-type";  Branch = "bench/multi-word-creature-types"; Commit = "0e9b703047d37e31abbccbda2c9de175ae3e33cb" }
    [pscustomobject]@{ TaskId = "kane-03-saga-chapter-triggers";    Branch = "bench/saga-chapter-triggers";     Commit = "4029a94a8bd5a22df1f3dcf819719c0e448270b4" }
    [pscustomobject]@{ TaskId = "kane-04-singleton-up-to-n";        Branch = "bench/singleton-up-to-n";         Commit = "420372615ef8b95566dc8ab24039c1532830fdbf" }
    [pscustomobject]@{ TaskId = "asohav-01-library-write-reporting"; Branch = "bench/library-write-reporting";  Commit = "c6bc1fdf9205daeebb46c469630d3cc61d6aaaa5" }
    [pscustomobject]@{ TaskId = "asohav-02-changelog-uuid-id";      Branch = "bench/changelog-uuid-id";         Commit = "d83381ad650b3474a50310e0dd3441a03cd89706" }
    [pscustomobject]@{ TaskId = "lfc-02-scryfall-headers";          Branch = "bench/scryfall-required-headers"; Commit = "170b395baf8ad4205f6fb6d409b29c25635e7363" }
)

if (-not $SkipSetup) {
    Write-Host "=== Ensuring bench branches exist ===" -ForegroundColor Cyan
    foreach ($b in $benchBranches) {
        $task = $tasksById[$b.TaskId]
        if (-not $task) {
            Write-Host "  [SKIP] $($b.TaskId) - not in manifest (was it renamed?)" -ForegroundColor Yellow
            continue
        }
        $repo = $task.repo
        if (-not (Test-Path -LiteralPath $repo)) {
            Write-Host "  [WARN] $($b.TaskId): repo not found at $repo - skipping" -ForegroundColor Yellow
            continue
        }

        & git -C $repo rev-parse --verify --quiet "refs/heads/$($b.Branch)" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK]   $($b.Branch) already exists in $repo" -ForegroundColor DarkGray
            continue
        }

        & git -C $repo cat-file -e "$($b.Commit)^{commit}" *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  fetching $repo ..." -ForegroundColor DarkGray
            & git -C $repo fetch origin --quiet *> $null
        }

        & git -C $repo branch $b.Branch $b.Commit *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [PASS] created $($b.Branch) @ $($b.Commit.Substring(0,10)) in $repo" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] could not create $($b.Branch) in $repo - commit not reachable even after fetch. Run 'git -C `"$repo`" fetch origin' by hand and re-run this script." -ForegroundColor Red
        }
    }
    Write-Host ""
}

if ($SetupOnly) { exit 0 }

# --- 2. interactive pick: tasks, models, repeat count -----------------------

function Select-FromList {
    param(
        [string]$Prompt,
        [string[]]$Options
    )
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i])
    }
    Write-Host ""
    $raw = Read-Host "$Prompt (comma-separated numbers, or 'all')"
    if ($raw.Trim().ToLower() -eq "all") {
        return 0..($Options.Count - 1)
    }
    $picked = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($raw -split ",")) {
        $p = $part.Trim()
        if ($p -match '^\d+$') {
            $n = [int]$p
            if ($n -ge 1 -and $n -le $Options.Count -and -not $picked.Contains($n - 1)) {
                $picked.Add($n - 1)
            }
        }
    }
    return $picked
}

Write-Host "=== Select tasks ===" -ForegroundColor Cyan
$taskOptions = $manifest.tasks | ForEach-Object { "$($_.id)  -  $($_.title)" }
$taskIdx = Select-FromList -Prompt "Tasks to run" -Options $taskOptions
if ($taskIdx.Count -eq 0) {
    Write-Host "No tasks selected - nothing to do." -ForegroundColor Yellow
    exit 0
}
$selectedTasks = $taskIdx | ForEach-Object { $manifest.tasks[$_].id }

Write-Host ""
Write-Host "=== Select models ===" -ForegroundColor Cyan
# Curated to the seats AGENTS.md's own toolcalls probe has actually measured
# PASS on (Gotchas: "Only the qwen3 family can reliably call tools..."). Pick
# "custom" to type any other opencode model id - nothing stops you, but an
# un-probed model may silently no-op (liar mode) instead of failing loudly.
$modelOptions = @(
    "ollama-desktop/qwen3:14b"
    "ollama-desktop/qwen3:8b"
    "ollama-desktop/devstral:24b"
    "ollama-node3/qwen3:8b"
    "(custom model id - type your own)"
)
$modelIdx = Select-FromList -Prompt "Models to run" -Options $modelOptions
if ($modelIdx.Count -eq 0) {
    Write-Host "No models selected - nothing to do." -ForegroundColor Yellow
    exit 0
}
$selectedModels = New-Object System.Collections.Generic.List[string]
foreach ($i in $modelIdx) {
    if ($i -eq $modelOptions.Count - 1) {
        $custom = Read-Host "Enter custom model id(s), comma-separated"
        foreach ($c in ($custom -split ",")) {
            $c2 = $c.Trim()
            if ($c2 -and -not $selectedModels.Contains($c2)) { $selectedModels.Add($c2) }
        }
    } else {
        $m = $modelOptions[$i]
        if (-not $selectedModels.Contains($m)) { $selectedModels.Add($m) }
    }
}
if ($selectedModels.Count -eq 0) {
    Write-Host "No models selected - nothing to do." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
$repsRaw = Read-Host "How many times to run EACH task x model combination? (default 1)"
$reps = 1
if ($repsRaw.Trim() -match '^\d+$' -and [int]$repsRaw -gt 0) { $reps = [int]$repsRaw }

$total = $selectedTasks.Count * $selectedModels.Count * $reps

Write-Host ""
Write-Host "=== Plan ===" -ForegroundColor Cyan
Write-Host "  Tasks:  $($selectedTasks -join ', ')"
Write-Host "  Models: $($selectedModels -join ', ')"
Write-Host "  Reps:   $reps each  ->  $total total run(s)"
Write-Host ""

# lfc-02's baseline gate is flaky with a real Manapool key in the shell -
# see docs/roadmap.md's caveat on this task.
if (($selectedTasks -contains "lfc-02-scryfall-headers") -and $env:MANAPOOL_API_KEY) {
    Write-Host "WARNING: MANAPOOL_API_KEY is set in this shell. lfc-02-scryfall-headers's" -ForegroundColor Yellow
    Write-Host "baseline gate is flaky with a real key present (docs/roadmap.md). Unset it" -ForegroundColor Yellow
    Write-Host "first if you want a reliable run: `$env:MANAPOOL_API_KEY = `$null" -ForegroundColor Yellow
    Write-Host ""
}

$go = Read-Host "Proceed? (y/N)"
if ($go.Trim().ToLower() -ne "y") {
    Write-Host "Cancelled."
    exit 0
}

# --- 3. run the batch ---------------------------------------------------

$results = New-Object System.Collections.Generic.List[pscustomobject]
$runNum = 0
foreach ($model in $selectedModels) {
    foreach ($taskId in $selectedTasks) {
        for ($r = 1; $r -le $reps; $r++) {
            $runNum++
            Write-Host ""
            Write-Host ">>> [$runNum/$total] $taskId  x  $model  (rep $r of $reps)" -ForegroundColor Cyan
            & $testTasksPs1 -Task $taskId -Model $model -ModelLabel $model
            $results.Add([pscustomobject]@{
                Task     = $taskId
                Model    = $model
                Rep      = $r
                ExitCode = $LASTEXITCODE
            })
        }
    }
}

Write-Host ""
Write-Host "=== Batch complete ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$fails = $results | Where-Object { $_.ExitCode -ne 0 }
if ($fails.Count -gt 0) {
    Write-Host "$($fails.Count) of $total run(s) exited non-zero (test-tasks.ps1 exits 1 on any FAIL grade)." -ForegroundColor Yellow
    Write-Host "Per-run detail is in tests/results/ and the appended rows in tests/results/tasks-summary.tsv." -ForegroundColor Yellow
} else {
    Write-Host "All $total run(s) completed with exit 0 (no FAIL grade - a run can still carry a WARN)." -ForegroundColor Green
}

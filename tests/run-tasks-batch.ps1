# run-tasks-batch.ps1 - one-stop entry point for the task-veracity benchmark:
# (1) ensures every task's local `bench/*` branch exists in its repo, then
# (2) interactively picks tasks + models + a repeat count and runs the batch
# through test-tasks.ps1, one (task, model) pair per invocation.
#
# Both pickers are data-driven, so adding a task or a model is NOT a script
# edit:
#   - Tasks come from tests/tasks/manifest.json. Each task that needs a bench
#     branch contributes it via its own `branch` + `benchBaseCommit` fields
#     (see docs/roadmap.md "Task-veracity benchmark: task set expansion
#     (2026-09-21)" for the branch<->commit table).
#   - Model seats come from tests/run-tasks-models.tsv - the tags the toolcalls
#     probe (tests/test-toolcalls.ps1) actually measured PASS on - intersected
#     with live /api/tags, so a new tool-capable model is one TSV row and a
#     down host/unpulled model quietly stops being offered on its own.
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
# Driven by the manifest, not a hardcoded table: each task that needs a bench
# branch carries `branch` and `benchBaseCommit`; tasks without one (kane-01,
# lfc-01) are simply skipped. Mirrors docs/roadmap.md exactly - each commit is
# the one immediately BEFORE the real merged fix that task grades,
# independently verified (baseline green, failsOnOld red) when the task was
# authored.
$benchBranches = @($manifest.tasks | Where-Object { $_.benchBaseCommit } | ForEach-Object {
    [pscustomobject]@{ TaskId = $_.id; Branch = $_.branch; Commit = $_.benchBaseCommit }
})

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

function Get-ProviderEndpoint {
    # "ollama-node3/qwen3:8b" -> $env:OLLAMA_NODE3_BASE_URL, the same variable
    # the profile exports and opencode.jsonc resolves through {env:...}.
    # Non-ollama providers (opencode-go and friends) return $null: they are not
    # host-scoped and there is no local endpoint to probe.
    param([string]$ModelId)

    $provider = ($ModelId -split "/")[0]
    if ($provider -notmatch '^ollama-(.+)$') { return $null }
    $varName = "OLLAMA_{0}_BASE_URL" -f $Matches[1].ToUpper().Replace("-", "_")
    return [pscustomobject]@{
        Provider = $provider
        VarName  = $varName
        BaseUrl  = [Environment]::GetEnvironmentVariable($varName)
    }
}

function Get-AvailableModelSeats {
    # Reads tests/run-tasks-models.tsv - the (tag, hosts) pairings the toolcalls
    # probe has actually measured PASS on (AGENTS.md Gotchas: "Only the qwen3
    # family can reliably call tools..."). Each candidate becomes an option ONLY
    # if OLLAMA_<HOST>_BASE_URL is set AND that host answers /api/tags AND lists
    # the tag - so a down host or an unpulled model silently disappears from the
    # picker instead of failing the preflight later. Adding a model = one TSV row.
    param([string]$RegistryPath)

    $seats = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        Write-Host "  [WARN] no model registry at $RegistryPath - only the custom option is available" -ForegroundColor Yellow
        return ,@()
    }
    foreach ($line in Get-Content -LiteralPath $RegistryPath) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $cols = $t -split "`t"
        if ($cols.Count -lt 2) { continue }
        $tag = $cols[0].Trim()
        if (-not $tag -or $tag -eq "tag") { continue }   # header row
        foreach ($hostName in (($cols[1] -split '\s+') | Where-Object { $_ })) {
            $modelId = "ollama-$hostName/$tag"
            $ep = Get-ProviderEndpoint -ModelId $modelId
            if (-not $ep -or -not $ep.BaseUrl) {
                Write-Host ("  [skip] {0} - OLLAMA_{1}_BASE_URL is not set in this shell (source a profile first)" -f "ollama-$hostName", $hostName.ToUpper()) -ForegroundColor DarkGray
                continue
            }
            $root = $ep.BaseUrl -replace '/v1/?$', ''
            try {
                $resp = Invoke-RestMethod -Uri "$root/api/tags" -TimeoutSec 5 -ErrorAction Stop
            } catch {
                Write-Host ("  [skip] {0} - host not answering /api/tags" -f "ollama-$hostName") -ForegroundColor DarkGray
                continue
            }
            $installed = @($resp.models | ForEach-Object { $_.name })
            if ($installed -contains $tag) {
                if (-not $seats.Contains($modelId)) { $seats.Add($modelId) }
            } else {
                Write-Host ("  [skip] {0} - tag '{1}' not pulled there yet" -f "ollama-$hostName", $tag) -ForegroundColor DarkGray
            }
        }
    }
    return ,@($seats | Sort-Object)
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
# Seats come from tests/run-tasks-models.tsv - the tags the toolcalls probe has
# actually measured PASS on (Gotchas: "Only the qwen3 family can reliably call
# tools...") - intersected with each live host's /api/tags, so a new model is
# one TSV row and a down host / an unpulled tag drops out by itself. Pick
# "custom" to type any other opencode model id - nothing stops you, but an
# un-probed model may silently no-op (liar mode) instead of failing loudly.
$modelOptions = @(Get-AvailableModelSeats -RegistryPath (Join-Path $scriptDir "run-tasks-models.tsv"))
$modelOptions += "(custom model id - type your own)"
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

# --- 2b. endpoint preflight -------------------------------------------------
# Six node3 runs on 2026-09-20/21 produced 307-byte transcripts holding one
# "Cannot connect to API" error each, and the harness graded all six as model
# behaviour ("6/6 liar mode") - a reading that reached a config change, the
# CHANGELOG and docs/roadmap.md before anyone re-read the transcripts. A run
# against a host that is not answering measures nothing, so every host this
# batch would touch gets checked BEFORE the hours are spent. Costs ~1s per host.
# (Get-ProviderEndpoint is defined above with the seat picker.)

function Test-OllamaEndpoint {
    # /api/tags is the cheapest check that proves Ollama itself is answering
    # rather than just that something holds the port. The tag count comes back
    # too, so a host serving zero models still reads as suspicious.
    param([string]$BaseUrl)

    # Profiles export the .../v1 OpenAI-compatible surface; /api/tags is on the
    # native root.
    $root = $BaseUrl -replace '/v1/?$', ''
    try {
        $tags = Invoke-RestMethod -Uri "$root/api/tags" -TimeoutSec 5 -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Detail = "{0} model tag(s)" -f @($tags.models).Count }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    }
}

Write-Host "=== Endpoint preflight ===" -ForegroundColor Cyan

# The seats this batch drives, plus the small model opencode uses for titles and
# summaries - dev-node3.sh points that at ollama-server, down since 2026-09-16,
# so a node3 batch can still be reaching for a dead box on every run.
$endpointIds = New-Object System.Collections.Generic.List[string]
foreach ($m in $selectedModels) { $endpointIds.Add($m) }
if ($env:OPENCODE_SMALL_MODEL) { $endpointIds.Add($env:OPENCODE_SMALL_MODEL) }

$seen      = @{}
$preflight = New-Object System.Collections.Generic.List[pscustomobject]
foreach ($id in $endpointIds) {
    $p = Get-ProviderEndpoint -ModelId $id
    if (-not $p) { continue }
    if ($seen.ContainsKey($p.Provider)) { continue }
    $seen[$p.Provider] = $true

    if (-not $p.BaseUrl) {
        $preflight.Add([pscustomobject]@{
            Provider = $p.Provider
            Ok       = $false
            Detail   = "$($p.VarName) is not set - source the profile that exports it first"
        })
        continue
    }
    $probe = Test-OllamaEndpoint -BaseUrl $p.BaseUrl
    $preflight.Add([pscustomobject]@{
        Provider = $p.Provider
        Ok       = $probe.Ok
        Detail   = "$($p.BaseUrl) - $($probe.Detail)"
    })
}

foreach ($e in $preflight) {
    if ($e.Ok) {
        Write-Host ("  [PASS] {0}  {1}" -f $e.Provider, $e.Detail) -ForegroundColor Green
    } else {
        Write-Host ("  [FAIL] {0}  {1}" -f $e.Provider, $e.Detail) -ForegroundColor Red
    }
}
Write-Host ""

$deadEndpoints = @($preflight | Where-Object { -not $_.Ok })
if ($deadEndpoints.Count -gt 0) {
    Write-Host "$($deadEndpoints.Count) endpoint(s) not answering - not starting the batch." -ForegroundColor Red
    Write-Host "A run against an unreachable host yields a transcript with one APIError" -ForegroundColor Red
    Write-Host "and nothing gradable. Bring the host up, or drop that seat from the" -ForegroundColor Red
    Write-Host "selection, and re-run." -ForegroundColor Red
    exit 1
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

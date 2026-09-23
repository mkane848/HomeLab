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
#
# Modes (asked first, or -Mode):
#   Tasks - the task batch through test-tasks.ps1.
#   Probe - tests/test-toolcalls.ps1 on every host that is up. Every result is
#           logged to tests/results/toolcalls-summary.tsv with host + Ollama
#           version, and a PASS adds the seat to run-tasks-models.tsv (that
#           file's definition: "a row per tag the probe measured PASS on").
#   Both  - probe, then the task batch on every available seat whose probe
#           PASSes on its host's CURRENT Ollama version.
# Menus show each seat's last probe result. Seats the live opencode config
# does not know are dropped before they can burn a run as _INFRA_.
#
# Non-interactive: each parameter given skips its prompt, -Yes skips the
# confirmations. -Tasks/-Models take ids or 'all'; in Probe/Both mode -Models
# picks what to probe and also takes 'new' (no result on the host's current
# Ollama version). -OnlyMissing skips task x model pairs that already have a
# graded row in tests/results/tasks-summary.tsv. -RunTimeout/-CommandTimeout
# override the per-run caps for every invocation (0 = test-tasks.ps1
# defaults, 900/300). "One run of everything that
# has no data yet":
#   .\tests\run-tasks-batch.ps1 -SkipSetup -Mode Both -Models new -Tasks all -Reps 1 -OnlyMissing -Yes

param(
    [switch]$SetupOnly,
    [switch]$SkipSetup,
    [ValidateSet("Tasks", "Probe", "Both")]
    [string]$Mode,
    [string[]]$Tasks,
    [string[]]$Models,
    [int]$Reps = 0,
    [switch]$OnlyMissing,
    [switch]$Yes,
    # Seconds per opencode run / per grading command, forwarded to every
    # test-tasks.ps1 invocation. 0 (default) leaves test-tasks.ps1's own
    # defaults in place (900 / 300). Pass 1800 for the 18-25 GB offloading
    # seats, whose runs otherwise die at the default cap with no transcript
    # (see docs/implementation-tasks.md → "Gap-fill batch review").
    [int]$RunTimeout = 0,
    [int]$CommandTimeout = 0
)

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptDir "tasks\manifest.json"
$testTasksPs1 = Join-Path $scriptDir "test-tasks.ps1"
$toolcallsPs1 = Join-Path $scriptDir "test-toolcalls.ps1"
$registryPath = Join-Path $scriptDir "run-tasks-models.tsv"
$probeLogPath = Join-Path $scriptDir "results\toolcalls-summary.tsv"
$summaryPath  = Join-Path $scriptDir "results\tasks-summary.tsv"

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

# --- 2. pick: mode, tasks, models, repeat count ------------------------------

function Select-FromList {
    param(
        [string]$Prompt,
        [string[]]$Options,
        # Indices the keyword 'new' selects. Empty = 'new' is not offered.
        [int[]]$NewIdx = @()
    )
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Options[$i])
    }
    Write-Host ""
    $hint = if ($NewIdx.Count -gt 0) { "comma-separated numbers, 'all', or 'new'" } else { "comma-separated numbers, or 'all'" }
    $raw = Read-Host "$Prompt ($hint)"
    $kw = $raw.Trim().ToLower()
    if ($kw -eq "all") { return 0..($Options.Count - 1) }
    if ($kw -eq "new" -and $NewIdx.Count -gt 0) { return $NewIdx }
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

function Split-IdList {
    # -Tasks/-Models accept "a,b" or a,b (array) - flatten both.
    param([string[]]$Values)
    return @($Values | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
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

function Split-ModelId {
    # "ollama-node3/qwen3:8b" -> Host node3, Tag qwen3:8b. ":latest" is dropped
    # so "laguna-xs-2.1" (config/registry) and "laguna-xs-2.1:latest"
    # (/api/tags) are the same model.
    param([string]$ModelId)
    $provider, $tag = $ModelId -split "/", 2
    $hostLabel = if ($provider -match '^ollama-(.+)$') { $Matches[1] } else { $null }
    return [pscustomobject]@{ Provider = $provider; Host = $hostLabel; Tag = ($tag -replace ':latest$', '') }
}

function Get-OllamaHosts {
    # Every host with OLLAMA_<HOST>_BASE_URL set: is it up, which Ollama
    # version, which tags. One /api/tags + /api/version call per host.
    $hosts = foreach ($label in "desktop", "node3", "server") {
        $url = [Environment]::GetEnvironmentVariable("OLLAMA_$($label.ToUpper())_BASE_URL")
        if (-not $url) { continue }
        $root = $url -replace '/v1/?$', '' -replace '/$', ''
        try {
            $tags = Invoke-RestMethod -Uri "$root/api/tags" -TimeoutSec 5 -ErrorAction Stop
            $ver  = (Invoke-RestMethod -Uri "$root/api/version" -TimeoutSec 5 -ErrorAction Stop).version
            [pscustomobject]@{ Label = $label; Root = $root; Up = $true; Version = $ver
                               Tags = @($tags.models | ForEach-Object { $_.name -replace ':latest$', '' }) }
        } catch {
            [pscustomobject]@{ Label = $label; Root = $root; Up = $false; Version = $null; Tags = @() }
        }
    }
    return @($hosts)
}

function Get-ProbeLog {
    # Latest tests/test-toolcalls.ps1 result per "host/tag". Empty if none.
    $last = @{}
    if (Test-Path -LiteralPath $probeLogPath) {
        foreach ($row in (Import-Csv -LiteralPath $probeLogPath -Delimiter "`t")) {
            $last["$($row.host)/$($row.model -replace ':latest$', '')"] = $row
        }
    }
    return $last
}

function Get-ProbeState {
    # PASS / FAIL / ... on the host's CURRENT Ollama version, else "STALE"
    # (probed on an older version) or "NONE" (never probed). A probe result is
    # only evidence for the version it ran against.
    param([string]$ModelId)
    $m   = Split-ModelId $ModelId
    $row = $probeLog["$($m.Host)/$($m.Tag)"]
    if (-not $row) { return "NONE" }
    $cur = $hostVersions[$m.Host]
    if ($cur -and $row.ollamaVersion -ne $cur) { return "STALE" }
    return $row.status
}

function Format-ProbeNote {
    param([string]$ModelId)
    $m   = Split-ModelId $ModelId
    $row = $probeLog["$($m.Host)/$($m.Tag)"]
    if (-not $row) { return "[probe: none logged]" }
    $note = "[probe: $($row.status) on $($row.ollamaVersion), $($row.timestamp.Substring(0,10))"
    $cur = $hostVersions[$m.Host]
    if ($cur -and $cur -ne $row.ollamaVersion) { $note += "; host now $cur" }
    return "$note]"
}

function Get-RegistryRows {
    # tests/run-tasks-models.tsv -> list of @{ Tag; Hosts; Desc }. Comment and
    # header lines are skipped, as in the #36 reader.
    $rows = New-Object System.Collections.Generic.List[pscustomobject]
    if (-not (Test-Path -LiteralPath $registryPath)) { return $rows }
    foreach ($line in Get-Content -LiteralPath $registryPath) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $cols = $t -split "`t"
        if ($cols.Count -lt 2) { continue }
        $tag = $cols[0].Trim()
        if (-not $tag -or $tag -eq "tag") { continue }
        $rows.Add([pscustomobject]@{
            Tag   = $tag
            Hosts = @(($cols[1] -split '\s+') | Where-Object { $_ })
            Desc  = $(if ($cols.Count -ge 3) { $cols[2] } else { "" })
        })
    }
    return $rows
}

function Add-RegistrySeat {
    # A probe PASS is exactly what a registry row asserts, so Probe/Both mode
    # records it: add the host to an existing row, or append a new row.
    # Rewrites the file LF-only with a trailing newline (it is committed LF and
    # had no final newline, so a plain Add-Content glued rows together).
    param([string]$Tag, [string]$HostLabel, [string]$Version)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ([IO.File]::ReadAllText($registryPath) -split '\r?\n')) { $lines.Add($l) }
    while ($lines.Count -gt 0 -and -not $lines[$lines.Count - 1].Trim()) { $lines.RemoveAt($lines.Count - 1) }
    $changed = $false
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if (-not $l.Trim() -or $l.TrimStart().StartsWith('#')) { continue }
        $cols = $l -split "`t"
        if (($cols[0].Trim() -replace ':latest$', '') -ne $Tag) { continue }
        $found = $true
        $hostsNow = @(($cols[1] -split '\s+') | Where-Object { $_ })
        if ($hostsNow -contains $HostLabel) { break }
        $cols[1] = (@($hostsNow) + $HostLabel) -join " "
        if ($cols.Count -ge 3) { $cols[2] = "$($cols[2]); measured PASS on $HostLabel ($Version)" }
        $lines[$i] = $cols -join "`t"
        $changed = $true
        Write-Host "  registry: added $HostLabel to $Tag" -ForegroundColor DarkGray
        break
    }
    if (-not $found) {
        $lines.Add(("{0}`t{1}`tmeasured PASS on {1} ({2}), added by run-tasks-batch probe {3}" -f $Tag, $HostLabel, $Version, (Get-Date -Format "yyyy-MM-dd")))
        $changed = $true
        Write-Host "  registry: added $Tag ($HostLabel)" -ForegroundColor DarkGray
    }
    if ($changed) {
        [IO.File]::WriteAllText($registryPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    }
}

function Get-RegisteredModelIds {
    # Model ids the RESOLVED live opencode config knows. `opencode run` cannot
    # drive anything else - it would exit non-zero and burn a run as _INFRA_.
    # $null when `opencode debug config` fails, and then nothing is filtered.
    try {
        $cfg = (& opencode debug config 2>$null | Out-String) | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
    $ids = @{}
    foreach ($prov in $cfg.provider.PSObject.Properties) {
        foreach ($mod in $prov.Value.models.PSObject.Properties) { $ids["$($prov.Name)/$($mod.Name)"] = $true }
    }
    return $ids
}

function Get-AvailableModelSeats {
    # Registry rows intersected with live hosts: an option only if the host is
    # up and lists the tag. A down host or an unpulled model silently drops out.
    $seats = [System.Collections.Generic.List[string]]::new()
    $rows = Get-RegistryRows
    if ($rows.Count -eq 0) {
        Write-Host "  [WARN] no model registry at $registryPath - only the custom option is available" -ForegroundColor Yellow
        return @()
    }
    foreach ($r in $rows) {
        foreach ($hostName in $r.Hosts) {
            $h = $ollamaHosts | Where-Object { $_.Label -eq $hostName }
            if (-not $h) {
                Write-Host ("  [skip] ollama-{0} - OLLAMA_{1}_BASE_URL is not set in this shell (source a profile first)" -f $hostName, $hostName.ToUpper()) -ForegroundColor DarkGray
                continue
            }
            if (-not $h.Up) {
                Write-Host ("  [skip] ollama-{0} - host not answering /api/tags" -f $hostName) -ForegroundColor DarkGray
                continue
            }
            $id = "ollama-$hostName/$($r.Tag -replace ':latest$', '')"
            if ($h.Tags -contains ($r.Tag -replace ':latest$', '')) {
                if (-not $seats.Contains($id)) { $seats.Add($id) }
            } else {
                Write-Host ("  [skip] ollama-{0} - tag '{1}' not pulled there yet" -f $hostName, $r.Tag) -ForegroundColor DarkGray
            }
        }
    }
    return @($seats | Sort-Object)
}

function Get-GradedPairs {
    # "taskId|model" for every GRADED row of tasks-summary.tsv (opencodeExit 0;
    # a non-zero exit never reached the model and is not data - AGENTS.md).
    $done = @{}
    if (Test-Path -LiteralPath $summaryPath) {
        foreach ($row in (Import-Csv -LiteralPath $summaryPath -Delimiter "`t")) {
            if ($row.opencodeExit -eq "0") { $done["$($row.taskId)|$($row.model)"] = [int]$done["$($row.taskId)|$($row.model)"] + 1 }
        }
    }
    return $done
}

# Chat models only - embedding models have no chat endpoint to probe.
$EMBED_PATTERN = 'embed|bge-|nomic|mxbai'

if (-not $Mode) {
    Write-Host "=== What to run ===" -ForegroundColor Cyan
    Write-Host "  [1] Task batch       - test-tasks.ps1, the real opencode tool loop (~5-20 min per run)"
    Write-Host "  [2] Tool-call probe  - test-toolcalls.ps1 on every host that is up (~1 min per model)"
    Write-Host "  [3] Probe, then task batch on every seat whose probe PASSes"
    Write-Host ""
    $modeRaw = Read-Host "Mode (1/2/3, default 1)"
    $Mode = switch ($modeRaw.Trim()) { "2" { "Probe" } "3" { "Both" } default { "Tasks" } }
    Write-Host ""
}

$ollamaHosts  = Get-OllamaHosts
$hostVersions = @{}
foreach ($h in $ollamaHosts) { if ($h.Up) { $hostVersions[$h.Label] = $h.Version } }
$probeLog = Get-ProbeLog

# --- 2a. tool-call probe (Probe / Both) --------------------------------------
if ($Mode -ne "Tasks") {
    Write-Host "=== Tool-call probe: hosts ===" -ForegroundColor Cyan
    foreach ($h in $ollamaHosts) {
        if ($h.Up) { Write-Host ("  [UP]   {0,-8} {1}  Ollama {2}" -f $h.Label, $h.Root, $h.Version) -ForegroundColor Green }
        else       { Write-Host ("  [DOWN] {0,-8} {1}  - its models are left out" -f $h.Label, $h.Root) -ForegroundColor Yellow }
    }
    Write-Host ""

    $probeOptions = New-Object System.Collections.Generic.List[string]
    $newIdx       = New-Object System.Collections.Generic.List[int]
    foreach ($h in ($ollamaHosts | Where-Object Up)) {
        foreach ($t in ($h.Tags | Where-Object { $_ -notmatch $EMBED_PATTERN } | Sort-Object)) {
            $id = "ollama-$($h.Label)/$t"
            if ((Get-ProbeState $id) -in "NONE", "STALE") { $newIdx.Add($probeOptions.Count) }
            $probeOptions.Add($id)
        }
    }
    if ($probeOptions.Count -eq 0) {
        Write-Host "No chat models on any reachable host - nothing to probe." -ForegroundColor Yellow
        exit 1
    }

    # In Probe and Both mode, -Models picks what to PROBE; the Both-mode batch
    # then takes every available seat whose probe PASSes.
    $probeModels = $Models
    if ($probeModels) {
        $kw = ((Split-IdList $probeModels) -join ",").ToLower()
        $probeIds = if ($kw -eq "all") { @($probeOptions) }
                    elseif ($kw -eq "new") { @($newIdx | ForEach-Object { $probeOptions[$_] }) }
                    else { Split-IdList $probeModels }
    } else {
        Write-Host "=== Select models to probe ===" -ForegroundColor Cyan
        Write-Host "  ('new' = the $($newIdx.Count) with no probe result on their host's current Ollama version)" -ForegroundColor DarkGray
        $labels = @($probeOptions | ForEach-Object { "{0,-46} {1}" -f $_, (Format-ProbeNote $_) })
        $idx = Select-FromList -Prompt "Models to probe" -Options $labels -NewIdx @($newIdx)
        $probeIds = @($idx | ForEach-Object { $probeOptions[$_] })
    }

    if ($probeIds.Count -eq 0) {
        Write-Host "  Nothing to probe - every installed model already has a result on its host's current version." -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "  Probing $($probeIds.Count) model(s): $($probeIds -join ', ')"
        if (-not $Yes) {
            $go = Read-Host "Proceed with the probe? (y/N)"
            if ($go.Trim().ToLower() -ne "y") { Write-Host "Cancelled."; exit 0 }
        }
        foreach ($grp in ($probeIds | ForEach-Object { Split-ModelId $_ } | Group-Object Host)) {
            $h = $ollamaHosts | Where-Object { $_.Label -eq $grp.Name -and $_.Up }
            if (-not $h) { Write-Host "  [SKIP] $($grp.Name): host not up or not configured" -ForegroundColor Yellow; continue }
            & $toolcallsPs1 -OllamaHost $h.Root -HostLabel $h.Label -Model @($grp.Group | ForEach-Object Tag) -LogFile $probeLogPath
        }

        # Read results back from the log, not from console output.
        $probeLog = Get-ProbeLog
        Write-Host "=== Probe summary ===" -ForegroundColor Cyan
        foreach ($id in $probeIds) {
            $state = Get-ProbeState $id
            $color = switch ($state) { "PASS" { "Green" } "FAIL" { "Red" } default { "Yellow" } }
            Write-Host ("  [{0,-5}] {1}" -f $state, $id) -ForegroundColor $color
        }
        Write-Host ""
    }

    # Every installed model with a current-version PASS belongs in the
    # registry - including ones probed in an earlier run - so the batch below
    # can offer it. Idempotent.
    foreach ($id in $probeOptions) {
        if ((Get-ProbeState $id) -eq "PASS") {
            $m = Split-ModelId $id
            Add-RegistrySeat -Tag $m.Tag -HostLabel $m.Host -Version $hostVersions[$m.Host]
        }
    }
    if ($Mode -eq "Probe") { exit 0 }
}

# --- 2b. tasks -----------------------------------------------------------------
if ($Tasks) {
    $ids = Split-IdList $Tasks
    $selectedTasks = if (($ids -join ",").ToLower() -eq "all") { @($manifest.tasks | ForEach-Object id) } else { $ids }
    $unknown = @($selectedTasks | Where-Object { -not $tasksById.ContainsKey($_) })
    if ($unknown.Count -gt 0) {
        Write-Host "ERROR: unknown task id(s): $($unknown -join ', ')" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "=== Select tasks ===" -ForegroundColor Cyan
    $taskOptions = $manifest.tasks | ForEach-Object { "$($_.id)  -  $($_.title)" }
    $taskIdx = Select-FromList -Prompt "Tasks to run" -Options $taskOptions
    $selectedTasks = @($taskIdx | ForEach-Object { $manifest.tasks[$_].id })
}
if ($selectedTasks.Count -eq 0) {
    Write-Host "No tasks selected - nothing to do." -ForegroundColor Yellow
    exit 0
}

# --- 2c. models ----------------------------------------------------------------
# Seats come from tests/run-tasks-models.tsv - the tags the toolcalls probe has
# actually measured PASS on (Gotchas: "Only the qwen3 family can reliably call
# tools...") - intersected with each live host's /api/tags, so a new model is
# one TSV row and a down host / an unpulled tag drops out by itself. Pick
# "custom" to type any other opencode model id - nothing stops you, but an
# un-probed model may silently no-op (liar mode) instead of failing loudly.
Write-Host ""
Write-Host "=== Select models ===" -ForegroundColor Cyan
$available = @(Get-AvailableModelSeats)
$selectedModels = New-Object System.Collections.Generic.List[string]
if ($Mode -eq "Both" -or (((Split-IdList $Models) -join ",").ToLower() -eq "all")) {
    # Every available seat; the probe filter below keeps only current-version PASSes.
    foreach ($m in $available) { $selectedModels.Add($m) }
} elseif ($Models) {
    foreach ($m in (Split-IdList $Models)) { if (-not $selectedModels.Contains($m)) { $selectedModels.Add($m) } }
} else {
    $modelOptions = @($available) + "(custom model id - type your own)"
    $labels = @($available | ForEach-Object { "{0,-46} {1}" -f $_, (Format-ProbeNote $_) }) + $modelOptions[-1]
    $modelIdx = Select-FromList -Prompt "Models to run" -Options $labels
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
}

# Drop seats that cannot produce data: a current-version probe FAIL (Both mode
# also drops never/stale-probed seats), or a model id the live opencode config
# does not know (opencode run would exit non-zero -> an _INFRA_ run).
$registeredIds = Get-RegisteredModelIds
$kept = New-Object System.Collections.Generic.List[string]
foreach ($m in $selectedModels) {
    $state = Get-ProbeState $m
    if ($state -eq "FAIL" -or ($Mode -eq "Both" -and $state -ne "PASS")) {
        Write-Host "  [drop] $m - probe $state on this host's current Ollama version" -ForegroundColor Yellow
        continue
    }
    if ($null -ne $registeredIds -and $m -match '^ollama-' -and -not $registeredIds.ContainsKey($m)) {
        Write-Host "  [drop] $m - not registered in the live opencode config. Add it to opencode/global/opencode.jsonc and run .\desktop\scripts\sync-opencode.ps1 -Template" -ForegroundColor Yellow
        continue
    }
    if ($state -ne "PASS") {
        Write-Host "  WARN: $m - probe $state on this host's current version. Consider mode 2 first." -ForegroundColor Yellow
    }
    $kept.Add($m)
}
$selectedModels = $kept
if ($selectedModels.Count -eq 0) {
    Write-Host "No models selected - nothing to do." -ForegroundColor Yellow
    exit 0
}

if ($Reps -gt 0) {
    $repCount = $Reps
} else {
    Write-Host ""
    $repsRaw = Read-Host "How many times to run EACH task x model combination? (default 1)"
    $repCount = 1
    if ($repsRaw.Trim() -match '^\d+$' -and [int]$repsRaw -gt 0) { $repCount = [int]$repsRaw }
}

if (-not $PSBoundParameters.ContainsKey('OnlyMissing') -and -not $Yes) {
    $om = Read-Host "Skip task x model pairs that already have a graded result? (y/N)"
    $OnlyMissing = [switch]($om.Trim().ToLower() -eq "y")
}

# Build the run list. Models with the fewest graded runs go first, so an
# interrupted batch has still covered the models with no data at all.
$graded = Get-GradedPairs
$runList = New-Object System.Collections.Generic.List[pscustomobject]
$skipped = 0
$ordered = $selectedModels | Sort-Object { $mm = $_; @($selectedTasks | Where-Object { $graded["$_|$mm"] }).Count }, { $_ }
foreach ($model in $ordered) {
    foreach ($taskId in $selectedTasks) {
        if ($OnlyMissing -and $graded["$taskId|$model"]) { $skipped++; continue }
        for ($r = 1; $r -le $repCount; $r++) {
            $runList.Add([pscustomobject]@{ Task = $taskId; Model = $model; Rep = $r })
        }
    }
}
$total = $runList.Count

Write-Host ""
Write-Host "=== Plan ===" -ForegroundColor Cyan
Write-Host "  Tasks:  $($selectedTasks -join ', ')"
Write-Host "  Models: $($ordered -join ', ')"
Write-Host "  Reps:   $repCount each  ->  $total total run(s)"
if ($OnlyMissing) { Write-Host "  Skipped $skipped task x model pair(s) that already have a graded result" }
Write-Host ""
if ($total -eq 0) {
    Write-Host "Nothing to run." -ForegroundColor Yellow
    exit 0
}

# lfc-02's baseline gate is flaky with a real Manapool key in the shell -
# see docs/roadmap.md's caveat on this task.
if (($selectedTasks -contains "lfc-02-scryfall-headers") -and $env:MANAPOOL_API_KEY) {
    Write-Host "WARNING: MANAPOOL_API_KEY is set in this shell. lfc-02-scryfall-headers's" -ForegroundColor Yellow
    Write-Host "baseline gate is flaky with a real key present (docs/roadmap.md). Unset it" -ForegroundColor Yellow
    Write-Host "first if you want a reliable run: `$env:MANAPOOL_API_KEY = `$null" -ForegroundColor Yellow
    Write-Host ""
}

# --- 2d. endpoint preflight -------------------------------------------------
# Six node3 runs on 2026-09-20/21 produced 307-byte transcripts holding one
# "Cannot connect to API" error each, and the harness graded all six as model
# behaviour ("6/6 liar mode") - a reading that reached a config change, the
# CHANGELOG and docs/roadmap.md before anyone re-read the transcripts. A run
# against a host that is not answering measures nothing, so every host this
# batch would touch gets checked BEFORE the hours are spent. Costs ~1s per host.

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

if (-not $Yes) {
    $go = Read-Host "Proceed? (y/N)"
    if ($go.Trim().ToLower() -ne "y") {
        Write-Host "Cancelled."
        exit 0
    }
}

# --- 3. run the batch ---------------------------------------------------

$results = New-Object System.Collections.Generic.List[pscustomobject]
$runNum = 0
foreach ($run in $runList) {
    $runNum++
    Write-Host ""
    Write-Host ">>> [$runNum/$total] $($run.Task)  x  $($run.Model)  (rep $($run.Rep) of $repCount)" -ForegroundColor Cyan
    $taskArgs = @{ Task = $run.Task; Model = $run.Model; ModelLabel = $run.Model }
    if ($RunTimeout -gt 0) { $taskArgs['RunTimeout'] = $RunTimeout }
    if ($CommandTimeout -gt 0) { $taskArgs['CommandTimeout'] = $CommandTimeout }
    & $testTasksPs1 @taskArgs
    $results.Add([pscustomobject]@{
        Task     = $run.Task
        Model    = $run.Model
        Rep      = $run.Rep
        ExitCode = $LASTEXITCODE
    })
}

Write-Host ""
Write-Host "=== Batch complete ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$fails = @($results | Where-Object { $_.ExitCode -ne 0 })
if ($fails.Count -gt 0) {
    Write-Host "$($fails.Count) of $total run(s) exited non-zero (test-tasks.ps1 exits 1 on any FAIL grade)." -ForegroundColor Yellow
    Write-Host "Per-run detail is in tests/results/ and the appended rows in tests/results/tasks-summary.tsv." -ForegroundColor Yellow
} else {
    Write-Host "All $total run(s) completed with exit 0 (no FAIL grade - a run can still carry a WARN)." -ForegroundColor Green
}

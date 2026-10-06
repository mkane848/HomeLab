# run-tasks-batch.ps1 - one-stop entry point for the task-veracity benchmark:
# (1) ensures every task's local `bench/*` branch exists in its repo (a label:
#     test-tasks.ps1 runs each task's pinned `benchBaseCommit`) and warns when
#     a pinned base or acceptance commit is not on origin, then
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
#
# Replicates (-Reps N > 1) and the opencode version - docs/adversarial-review-2026-09-29.md:
#   - Run order is REP-OUTER within each model: every task's rep 1, then every
#     task's rep 2, so one cell's replicates are a whole pass apart instead of
#     adjacent. Replicates run back to back agreed in 11 of 11 pairs, so they may
#     be sharing session state and are not independent evidence. Models stay
#     grouped (a model switch is a reload). -BackToBack restores the old order.
#   - A batch runs on ONE opencode version. The version is read at the start and
#     checked before every run; if it changes (a TUI launched on this machine
#     upgraded the binary - opencode installs patch releases on its own when
#     "autoupdate" is on) the batch stops rather than mix versions in a cell.
#     The preflight says whether autoupdate is pinned (false / "notify" in
#     opencode.jsonc, or OPENCODE_DISABLE_AUTOUPDATE=1).
#
# Hosted seats (OpenCode Go) - rows in run-tasks-models.tsv whose host is
# `opencode-go`, run as `opencode-go/<tag>`. They cost the owner money per token:
#   - Offered only when `opencode models opencode-go` lists the model, the API key
#     file exists (~/.config/opencode/.secrets/opencode-go-api-key; checked, never
#     read) and the live `opencode debug config` resolves. No /api/tags or Ollama
#     version check, and no probe: test-toolcalls.ps1 is Ollama-only, so these
#     seats were smoke-tested (`opencode run --auto` wrote a file, 2026-10-06),
#     not probed. Probe mode never touches them and Both mode leaves them out.
#   - Never picked by 'all'. Name them (-Models opencode-go/<tag>) or use the
#     keyword 'hosted' (every hosted seat on offer): -Models all,hosted for both.
#   - Spend cap: a batch may spend at most -SpendCapShare (default 0.2) of a
#     model's monthly allowance (costs/go-rates.tsv monthlyLimitUsd). Go itself
#     allows 20% per 5 hours, so 0.2 can never lock a model out for longer than
#     one window. Each run's spend is the run JSON's costEstimate.usd, or, for a
#     run with no JSON (_INFRA_/_TIMEOUT_/_TRUNCATED_), its transcript's tokens at
#     the same rates: every run counts, graded or not. Before each run, a model
#     whose spend has reached its cap is skipped for the rest of the batch; other
#     models carry on. The check is before a run, so one run can overshoot the
#     cap by that run's own cost. A model with no rate row is refused, since its
#     spend cannot be estimated; -NoSpendCap runs it (and every hosted seat)
#     uncapped. Local seats are untouched by all of this.
#   One hosted batch, private real-prompt tasks:
#     .\tests\run-tasks-batch.ps1 -SkipSetup -Mode Tasks -Models hosted -Tasks <ids> -Reps 1 -Yes `
#         -TaskManifest M:\Projects\HomeLab-private\tasks\manifest.json -ResultsDir M:\Projects\HomeLab-private\results

param(
    [switch]$SetupOnly,
    [switch]$SkipSetup,
    [ValidateSet("Tasks", "Probe", "Both")]
    [string]$Mode,
    [string[]]$Tasks,
    [string[]]$Models,
    [int]$Reps = 0,
    [switch]$OnlyMissing,
    # Keep a cell's replicates adjacent (task outer, rep inner). The default is
    # rep-outer; see the header.
    [switch]$BackToBack,
    [switch]$Yes,
    # Seconds per opencode run / per grading command, forwarded to every
    # test-tasks.ps1 invocation. 0 (default) leaves test-tasks.ps1's own
    # defaults in place (900 / 300). Pass 1800 for the 18-25 GB offloading
    # seats, whose runs otherwise die at the default cap with no transcript
    # (see docs/implementation-tasks.md → "Gap-fill batch review").
    [int]$RunTimeout = 0,
    [int]$CommandTimeout = 0,
    # Offer and run tasks the manifest marks `retired` (left out of 'all' and
    # the picker otherwise; naming one is an error). Forwarded to test-tasks.ps1.
    [switch]$IncludeRetired,
    # Another task manifest and results folder (the private real-prompt set);
    # forwarded to test-tasks.ps1, which refuses a private manifest without a
    # private -ResultsDir. -OnlyMissing then reads that folder's summaries.
    [string]$TaskManifest = "",
    [string]$ResultsDir = "",
    # Hosted seats: the share of a model's monthly allowance one batch may spend
    # (see the header). Must be > 0 and <= 1.
    [double]$SpendCapShare = 0.2,
    # Hosted seats run with no spend cap, and one with no rate row is allowed
    # (its spend is then not estimated at all).
    [switch]$NoSpendCap,
    # Where the OpenCode Go API key file is expected. Its existence is checked;
    # it is never read. Default ~/.config/opencode/.secrets/opencode-go-api-key.
    [string]$GoKeyFile = ""
)

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = if ($TaskManifest) { [System.IO.Path]::GetFullPath($TaskManifest) } else { Join-Path $scriptDir "tasks\manifest.json" }
$testTasksPs1 = Join-Path $scriptDir "test-tasks.ps1"
$toolcallsPs1 = Join-Path $scriptDir "test-toolcalls.ps1"
$registryPath = Join-Path $scriptDir "run-tasks-models.tsv"
$probeLogPath = Join-Path $scriptDir "results\toolcalls-summary.tsv"
$taskResultsDir = if ($ResultsDir) { [System.IO.Path]::GetFullPath($ResultsDir) } else { Join-Path $scriptDir "results" }
$summaryPath  = Join-Path $taskResultsDir "tasks-summary.tsv"
$realSummaryPath = Join-Path $taskResultsDir "real-tasks-summary.tsv"
$goRatesPath  = Join-Path (Split-Path -Parent $scriptDir) "costs\go-rates.tsv"
$goKeyPath    = if ($GoKeyFile) { $GoKeyFile } else { Join-Path $HOME ".config\opencode\.secrets\opencode-go-api-key" }

if ($SpendCapShare -le 0 -or $SpendCapShare -gt 1) {
    Write-Host "ERROR: -SpendCapShare must be > 0 and <= 1 (got $SpendCapShare). It is the share of a hosted model's monthly allowance one batch may spend." -ForegroundColor Red
    exit 1
}

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

function Get-PublishState {
    # Whether anyone but this machine can get a commit:
    #   "published"   - origin has it
    #   "unpublished" - it is here and origin does not have it
    #   "unknown"     - it is here, no remote-tracking branch of this clone contains it,
    #                   and origin could not be reached to ask
    #   "missing"     - it is not in this clone at all
    # Two questions, cheapest first. (1) Does a remote-tracking branch of this clone
    # contain it? No network. (2) Otherwise ask origin itself, from an EMPTY scratch
    # repo: `git fetch origin <sha>` inside a clone that already has the commit exits 0
    # without asking anyone (checked), which would call every local-only commit
    # published. (2) also finds a commit that only a pull-request ref reaches, which (1)
    # cannot see: kane-01's base is both a branch tip and refs/pull/82/head. A
    # single-branch clone shows (1) one branch only - that is how a published commit was
    # once reported as local-only.
    param([string]$Repo, [string]$Commit)
    # Every probe below can write to stderr (a commit origin lacks is "not our ref"; a
    # local origin warns that it ignores --filter). Under a caller's "Stop", Windows
    # PowerShell 5.1 turns that into a terminating error, so set it here, function-local.
    $ErrorActionPreference = "Continue"

    & git -C $Repo cat-file -e "$Commit^{commit}" *> $null
    if ($LASTEXITCODE -ne 0) { return "missing" }
    $on = @(& git -C $Repo branch -r --contains $Commit 2>$null | Where-Object { $_ -and $_ -notmatch '->' })
    if ($on.Count -gt 0) { return "published" }

    $url = (& git -C $Repo remote get-url origin 2>$null | Select-Object -First 1)
    if (-not $url) { return "unpublished" }   # no origin at all: nowhere it could be published
    if ($url -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://|^git@|^[A-Za-z]:[\\/]|^/') {
        $abs = Join-Path $Repo $url           # a relative path is relative to the repo, not to the scratch repo
        if (Test-Path -LiteralPath $abs) { $url = (Resolve-Path -LiteralPath $abs).Path }
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("publish-check-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    try {
        & git init -q --bare $tmp *> $null
        & git -C $tmp remote add o $url *> $null
        & git -C $tmp fetch -q --depth=1 --filter=blob:none o $Commit *> $null
        if ($LASTEXITCODE -eq 0) { return "published" }
        & git -C $tmp ls-remote o HEAD *> $null
        if ($LASTEXITCODE -ne 0) { return "unknown" }
        return "unpublished"
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 1. bench branches: task id -> (branch name, exact pre-fix commit) -----
# Driven by the manifest, not a hardcoded table: every task carries `branch` and
# `benchBaseCommit`. Since 2026-09-30 test-tasks.ps1 runs the PINNED commit
# itself (Resolve-TaskBase), so these local branches are labels and no longer
# something a run depends on; this step still creates them, and now also says
# whether each pinned commit (and lfc-03's acceptance branch) is on a remote -
# a commit only this machine has cannot be reproduced by anyone else. Mirrors
# docs/roadmap.md: each commit is the one immediately BEFORE the real merged
# fix that task grades, independently verified (baseline green, failsOnOld red)
# when the task was authored.
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
        } else {
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
                continue
            }
        }

        # Can anyone else get the pinned base? A commit that exists only on this
        # machine cannot be reproduced. (Today all 27 can: 26 are on main and
        # kane-01's is a branch tip and refs/pull/82/head.)
        if ((Get-PublishState -Repo $repo -Commit $b.Commit) -eq "unpublished") {
            Write-Host "  [WARN] $($b.TaskId): base $($b.Commit.Substring(0,10)) is not on origin, so nobody else can reproduce this task." -ForegroundColor Yellow
            Write-Host "         Publish it: git -C `"$repo`" push origin $($b.Commit):refs/heads/$($b.Branch)" -ForegroundColor Yellow
        }
        # Same question for the owner's acceptance tests (lfc-03's own branch; the other tasks'
        # are an upstream fix commit's test file), pinned by `acceptance.commit` (a task without
        # the pin follows the local branch `acceptance.ref`).
        $accRef = if ($task.acceptance) { $task.acceptance.ref } else { $null }
        if ($accRef) {
            $accSha = if ($task.acceptance.commit) { $task.acceptance.commit } else { (& git -C $repo rev-parse --verify --quiet "refs/heads/$accRef" 2>$null | Select-Object -First 1) }
            if (-not $accSha) {
                Write-Host "  [WARN] $($b.TaskId): acceptance branch $accRef is not in $repo - the acceptance run will report ERROR." -ForegroundColor Yellow
            } else {
                & git -C $repo cat-file -e "$accSha^{commit}" *> $null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  fetching $repo for the acceptance commit ..." -ForegroundColor DarkGray
                    & git -C $repo fetch origin --quiet *> $null
                }
                switch (Get-PublishState -Repo $repo -Commit $accSha) {
                    "missing"     { Write-Host "  [WARN] $($b.TaskId): acceptance commit $($accSha.Substring(0,10)) is not in $repo - the acceptance run will report ERROR." -ForegroundColor Yellow }
                    "unpublished" {
                        Write-Host "  [WARN] $($b.TaskId): acceptance commit $($accSha.Substring(0,10)) (branch $accRef) is not on origin, so nobody else can re-run the owner's tests." -ForegroundColor Yellow
                        Write-Host "         Publish it: git -C `"$repo`" push origin ${accSha}:refs/heads/$accRef" -ForegroundColor Yellow
                    }
                }
            }
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

function Get-OfferedTasks {
    # The manifest tasks this batch offers: every task, minus the `retired` ones
    # unless -IncludeRetired. 'all' and the picker both draw from this list, so
    # a retired task is never run by accident (test-tasks.ps1 refuses it too).
    param($ManifestTasks, [bool]$IncludeRetired)
    return @($ManifestTasks | Where-Object { $IncludeRetired -or -not $_.retired })
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
    if (Test-HostedModelId $ModelId) { return "[hosted: smoke-tested, not probed; billed per token, spend-capped]" }
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
    # A hosted row (host `opencode-go`) is offered when Get-HostedSeatGate
    # passes against $hostedState instead: no Ollama host is involved.
    $seats = [System.Collections.Generic.List[string]]::new()
    $rows = Get-RegistryRows
    if ($rows.Count -eq 0) {
        Write-Host "  [WARN] no model registry at $registryPath - only the custom option is available" -ForegroundColor Yellow
        return @()
    }
    foreach ($r in $rows) {
        foreach ($hostName in $r.Hosts) {
            if ($hostName -eq "opencode-go") {
                $id = "opencode-go/$($r.Tag)"
                $why = Get-HostedSeatGate -ModelId $id -State $hostedState
                if ($why) {
                    Write-Host ("  [skip] {0} - {1}" -f $id, $why) -ForegroundColor DarkGray
                } elseif (-not $seats.Contains($id)) {
                    $seats.Add($id)
                }
                continue
            }
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
    # Real-prompt rows live in real-tasks-summary.tsv beside it, same columns
    # for taskId/model/opencodeExit.
    $done = @{}
    foreach ($path in @($summaryPath, $realSummaryPath)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($row in (Import-Csv -LiteralPath $path -Delimiter "`t")) {
            if ($row.opencodeExit -eq "0") { $done["$($row.taskId)|$($row.model)"] = [int]$done["$($row.taskId)|$($row.model)"] + 1 }
        }
    }
    return $done
}

function New-RunList {
    # The (task, model, rep) run order. Models stay grouped in the order given.
    # Within a model reps are the OUTER loop by default (every task's rep 1, then
    # every task's rep 2), so one cell's replicates are a whole pass apart;
    # -BackToBack keeps a cell's reps adjacent (task outer, rep inner).
    # -OnlyMissing drops a task x model pair that already has a graded row, for
    # every rep. Returns { Runs; Skipped } (Skipped counts pairs).
    param([string[]]$Models, [string[]]$Tasks, [int]$Reps, [hashtable]$Graded = @{}, [switch]$OnlyMissing, [switch]$BackToBack)

    $runs = New-Object System.Collections.Generic.List[pscustomobject]
    $skipped = 0
    foreach ($model in $Models) {
        $todo = New-Object System.Collections.Generic.List[string]
        foreach ($taskId in $Tasks) {
            if ($OnlyMissing -and $Graded["$taskId|$model"]) { $skipped++; continue }
            $todo.Add($taskId)
        }
        if ($BackToBack) {
            foreach ($taskId in $todo) {
                for ($r = 1; $r -le $Reps; $r++) { $runs.Add([pscustomobject]@{ Task = $taskId; Model = $model; Rep = $r }) }
            }
        } else {
            for ($r = 1; $r -le $Reps; $r++) {
                foreach ($taskId in $todo) { $runs.Add([pscustomobject]@{ Task = $taskId; Model = $model; Rep = $r }) }
            }
        }
    }
    return [pscustomobject]@{ Runs = $runs; Skipped = $skipped }
}

function Get-OpencodeVersion {
    # `opencode --version`, trimmed - the string test-tasks.ps1 stamps into every
    # run JSON as opencodeVersion. $null when opencode is missing or prints
    # something that is not a version.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = (& opencode --version 2>$null | Out-String).Trim()
        if ($out -match '^\d+\.\d+\.\d+') { return $out }
    } catch {
        # fall through to $null
    } finally {
        $ErrorActionPreference = $prev
    }
    return $null
}

function Get-OpencodeVersionDrift {
    # $null while opencode still reports $Expected, or when it cannot be asked
    # (no claim is better than a false one); otherwise the message that stops the
    # batch. A batch that straddles two versions cannot compare its own replicates.
    param([string]$Expected)

    if (-not $Expected) { return $null }
    $now = Get-OpencodeVersion
    if (-not $now -or $now -eq $Expected) { return $null }
    return "opencode changed from $Expected to $now during the batch"
}

function Get-OpencodeConfig {
    # The RESOLVED opencode config (`opencode debug config`) as an object, or $null.
    try {
        return ((& opencode debug config 2>$null | Out-String) | ConvertFrom-Json -ErrorAction Stop)
    } catch { return $null }
}

function Test-OpencodeAutoupdatePinned {
    # True when opencode will not upgrade itself: the global config sets
    # autoupdate to false or "notify", or OPENCODE_DISABLE_AUTOUPDATE is "1" or
    # "true" (opencode's own rule for boolean flags, case-insensitive). Unset
    # means ON - patch releases install themselves when a TUI starts (never from
    # `opencode run`), which is how the corpus went 1.18.31 -> .32 -> .33 in ten days.
    param($Config, [string]$EnvValue = $env:OPENCODE_DISABLE_AUTOUPDATE)

    if ($EnvValue -and @("true", "1") -contains $EnvValue.ToLower()) { return $true }
    if ($null -ne $Config) {
        $a = $Config.autoupdate
        if ($a -is [bool] -and -not $a) { return $true }
        if ($a -is [string] -and $a -eq "notify") { return $true }
    }
    return $false
}

# --- hosted seats (OpenCode Go) and the spend cap -----------------------------
# See the header. None of these functions calls a model: listing models, testing
# that the key file exists and resolving the config are all free.

function Test-HostedModelId {
    # A hosted seat: the OpenCode Go provider, billed per token, not host-scoped,
    # never probed (test-toolcalls.ps1 drives Ollama's /api/chat only).
    param([string]$ModelId)
    return ($ModelId -match '^opencode-go/')
}

function Get-HostedModelList {
    # `opencode models opencode-go` -> hashtable of the full ids it lists
    # ("opencode-go/qwen3.8-max"), or $null when the command fails, and then no
    # hosted seat is offered. It lists; it does not call a model.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = @(& opencode models opencode-go 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prev
    }
    $ids = @{}
    foreach ($l in $out) {
        $t = "$l".Trim()
        if ($t -match '^opencode-go/\S+$') { $ids[$t] = $true }
    }
    return $ids
}

function Get-HostedState {
    # The three facts a hosted seat is offered on, read once per batch.
    # KeyExists only tests the path: the key file is never opened.
    param([string]$KeyFile, [bool]$ConfigOk)
    return [pscustomobject]@{
        Listed    = Get-HostedModelList
        KeyFile   = $KeyFile
        KeyExists = [bool]($KeyFile -and (Test-Path -LiteralPath $KeyFile -PathType Leaf))
        ConfigOk  = $ConfigOk
    }
}

function Get-HostedSeatGate {
    # Why a hosted seat cannot run, or $null when it can: opencode lists the
    # model, the API key file exists, and the live config resolves.
    param([string]$ModelId, $State)
    if (-not $State) { return "hosted seats were not checked in this mode" }
    if (-not $State.KeyExists) { return "no OpenCode Go API key file at $($State.KeyFile)" }
    if ($null -eq $State.Listed) { return "``opencode models opencode-go`` failed, so it is unknown which Go models exist" }
    if (-not $State.Listed.ContainsKey($ModelId)) { return "not listed by ``opencode models opencode-go``" }
    if (-not $State.ConfigOk) { return "the live ``opencode debug config`` does not resolve" }
    return $null
}

function ConvertTo-RateValue {
    # A costs/go-rates.tsv number, read invariantly. Blank -> $Blank; not a number -> $null.
    param($Value, $Blank = 0.0)
    $s = "$Value".Trim()
    if (-not $s) { return $Blank }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Get-GoRates {
    # costs/go-rates.tsv -> hashtable: full model id -> its row. Empty when the
    # file is missing.
    param([string]$Path)
    $rates = @{}
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        foreach ($row in (Import-Csv -LiteralPath $Path -Delimiter "`t")) {
            if ($row.model) { $rates[$row.model.Trim()] = $row }
        }
    }
    return $rates
}

function Get-SpendCap {
    # One hosted model's cap for this batch: $Share x monthlyLimitUsd.
    # { Usd; Monthly; Share; Refusal }. Refusal is set when the model cannot be
    # held to a cap: no rate row, no input/output rate (its spend would read as
    # $0 and never reach the cap), or no monthly allowance.
    param([string]$ModelId, [hashtable]$Rates, [double]$Share)
    $row = $Rates[$ModelId]
    $refuse = { param($why) [pscustomobject]@{ Usd = $null; Monthly = $null; Share = $Share; Refusal = $why } }
    if (-not $row) { return (& $refuse "no row in costs/go-rates.tsv, so its spend cannot be estimated or capped") }
    foreach ($col in "inputPerM", "outputPerM") {
        $v = ConvertTo-RateValue $row.$col -Blank $null
        if ($null -eq $v) { return (& $refuse "its costs/go-rates.tsv row has no $col, so its spend cannot be estimated") }
    }
    $monthly = ConvertTo-RateValue $row.monthlyLimitUsd -Blank $null
    if ($null -eq $monthly -or $monthly -le 0) { return (& $refuse "its costs/go-rates.tsv row has no monthlyLimitUsd, so there is no allowance to take a share of") }
    return [pscustomobject]@{ Usd = [math]::Round($Share * $monthly, 6); Monthly = $monthly; Share = $Share; Refusal = $null }
}

function Get-TranscriptTokenUsage {
    # Token totals over a transcript's step_finish events (part.tokens: input,
    # output, reasoning, cache.read, cache.write), across every turn. The same
    # sum test-tasks.ps1 records as a run JSON's `usage`; used here for a run
    # that left no JSON, which may still have been billed.
    param([string]$Path)
    $u = [ordered]@{ input = 0.0; output = 0.0; reasoning = 0.0; cacheRead = 0.0; cacheWrite = 0.0; steps = 0 }
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        foreach ($line in [System.IO.File]::ReadLines($Path)) {
            if ($line -notmatch '"step_finish"') { continue }
            try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $t = $e.part.tokens
            if (-not $t) { continue }
            $u.steps++
            $u.input     += [double]$t.input
            $u.output    += [double]$t.output
            $u.reasoning += [double]$t.reasoning
            if ($t.cache) { $u.cacheRead += [double]$t.cache.read; $u.cacheWrite += [double]$t.cache.write }
        }
    }
    return [pscustomobject]$u
}

function Get-UsageCostUsd {
    # Dollars for a usage block at one costs/go-rates.tsv row. The same formula
    # as test-tasks.ps1's Get-RunCostEstimate: a blank rate counts as 0, and
    # reasoning tokens are not added again (opencode already counts them in
    # `output`). tests/test-hosted-seats.ps1 checks the two agree.
    param($Usage, $Rate)
    if (-not $Usage -or -not $Rate) { return 0.0 }
    $usd = ($Usage.input * (ConvertTo-RateValue $Rate.inputPerM) + $Usage.output * (ConvertTo-RateValue $Rate.outputPerM) +
            $Usage.cacheRead * (ConvertTo-RateValue $Rate.cacheReadPerM) + $Usage.cacheWrite * (ConvertTo-RateValue $Rate.cacheWritePerM)) / 1e6
    return [math]::Round($usd, 6)
}

function Get-ResultFileNames {
    # Names of the files in a results folder now, as a set (before a run, to
    # tell the files that run leaves behind from everything else).
    param([string]$Dir)
    $set = @{}
    if (Test-Path -LiteralPath $Dir) {
        foreach ($f in (Get-ChildItem -LiteralPath $Dir -File)) { $set[$f.Name] = $true }
    }
    return $set
}

function Measure-RunSpend {
    # What one test-tasks.ps1 invocation spent, from the files it left in the
    # results folder: tasks-<task>-<label>_<stamp>.json + .jsonl for a graded
    # run, tasks-<task>-<label>_<INFRA|TIMEOUT|TRUNCATED>_<stamp>.jsonl for one
    # that was not. A transcript paired with a JSON that carries
    # costEstimate.usd counts that number; any other transcript (no JSON, or a
    # JSON with no estimate) counts its tokens at $Rate. Every run counts,
    # graded or not: an infrastructure failure may still have been billed.
    # Returns { Usd; Sources }.
    param([string]$ResultsDir, [hashtable]$Before, [string]$TaskId, [string]$ModelLabel, $Rate)
    $prefix = "tasks-{0}-{1}_" -f $TaskId, ($ModelLabel -replace '[^a-zA-Z0-9._-]', '_')
    $new = @()
    if (Test-Path -LiteralPath $ResultsDir) {
        $new = @(Get-ChildItem -LiteralPath $ResultsDir -File | Where-Object { $_.Name.StartsWith($prefix) -and -not $Before.ContainsKey($_.Name) })
    }
    $jsonCost = @{}   # base name -> usd or $null
    foreach ($f in ($new | Where-Object { $_.Extension -eq ".json" })) {
        $usd = $null
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($j.costEstimate -and $null -ne $j.costEstimate.usd) { $usd = [double]$j.costEstimate.usd }
        } catch { $usd = $null }
        $jsonCost[$f.BaseName] = $usd
    }
    $total = 0.0
    $sources = New-Object System.Collections.Generic.List[string]
    $paired = @{}
    foreach ($f in ($new | Where-Object { $_.Extension -eq ".jsonl" })) {
        if ($jsonCost.ContainsKey($f.BaseName)) { $paired[$f.BaseName] = $true }
        if ($jsonCost.ContainsKey($f.BaseName) -and $null -ne $jsonCost[$f.BaseName]) {
            $total += $jsonCost[$f.BaseName]
            $sources.Add("run JSON costEstimate")
            continue
        }
        $total += Get-UsageCostUsd -Usage (Get-TranscriptTokenUsage -Path $f.FullName) -Rate $Rate
        $sources.Add($(if ($f.Name -match '_(INFRA|TIMEOUT|TRUNCATED)_') { "$($Matches[1]) transcript tokens" }
                       elseif ($jsonCost.ContainsKey($f.BaseName)) { "transcript tokens (its run JSON has no costEstimate)" }
                       else { "transcript tokens (no run JSON)" }))
    }
    foreach ($base in $jsonCost.Keys) {
        if ($paired.ContainsKey($base)) { continue }
        if ($null -ne $jsonCost[$base]) { $total += $jsonCost[$base]; $sources.Add("run JSON costEstimate") }
        else { $sources.Add("run JSON with no costEstimate and no transcript - not counted") }
    }
    if ($sources.Count -eq 0) { $sources.Add("no result files - nothing counted") }
    return [pscustomobject]@{ Usd = [math]::Round($total, 6); Sources = @($sources) }
}

function Get-CapStatus {
    # Before a run: $null when the model may run, else the message that skips
    # it. Only hosted models with a cap are ever stopped.
    param([string]$ModelId, [hashtable]$Caps, [hashtable]$Spend)
    if (-not $Caps.ContainsKey($ModelId)) { return $null }
    $cap = $Caps[$ModelId]
    $spent = [double]$Spend[$ModelId]
    if ($spent -lt $cap.Usd) { return $null }
    return ("spent about {0} of its {1}" -f (Format-Usd $spent), (Format-SpendCap $cap))
}

function Format-Usd {
    # "$1.2345" whatever the machine's culture, so logs and guards read the same.
    param([double]$Usd, [int]$Digits = 4)
    return '$' + $Usd.ToString("N$Digits", [Globalization.CultureInfo]::InvariantCulture)
}

function Format-SpendCap {
    # "$3.00 cap (20% of $15.00 monthly)"
    param($Cap)
    return ("{0} cap ({1}% of {2} monthly)" -f (Format-Usd $Cap.Usd 2), [math]::Round($Cap.Share * 100, 1).ToString([Globalization.CultureInfo]::InvariantCulture), (Format-Usd $Cap.Monthly 2))
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
$offeredTasks = Get-OfferedTasks -ManifestTasks $manifest.tasks -IncludeRetired ([bool]$IncludeRetired)
$retiredTasks = @($manifest.tasks | Where-Object { $_.retired })
if ($retiredTasks.Count -gt 0 -and -not $IncludeRetired) {
    Write-Host "  ($($retiredTasks.Count) retired task(s) not offered: $(@($retiredTasks | ForEach-Object id) -join ', '); -IncludeRetired to include)" -ForegroundColor DarkGray
}
if ($Tasks) {
    $ids = Split-IdList $Tasks
    $selectedTasks = if (($ids -join ",").ToLower() -eq "all") { @($offeredTasks | ForEach-Object id) } else { $ids }
    $unknown = @($selectedTasks | Where-Object { -not $tasksById.ContainsKey($_) })
    if ($unknown.Count -gt 0) {
        Write-Host "ERROR: unknown task id(s): $($unknown -join ', ')" -ForegroundColor Red
        exit 1
    }
    $namedRetired = @($selectedTasks | Where-Object { $tasksById[$_].retired -and -not $IncludeRetired })
    if ($namedRetired.Count -gt 0) {
        foreach ($id in $namedRetired) {
            Write-Host "ERROR: $id is retired ($($tasksById[$id].retired.date)): $($tasksById[$id].retired.reason)" -ForegroundColor Red
        }
        Write-Host "Drop it from -Tasks, or pass -IncludeRetired to run it anyway." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "=== Select tasks ===" -ForegroundColor Cyan
    $taskOptions = $offeredTasks | ForEach-Object { "$($_.id)  -  $($_.title)" }
    $taskIdx = Select-FromList -Prompt "Tasks to run" -Options $taskOptions
    $selectedTasks = @($taskIdx | ForEach-Object { $offeredTasks[$_].id })
}
if ($selectedTasks.Count -eq 0) {
    Write-Host "No tasks selected - nothing to do." -ForegroundColor Yellow
    exit 0
}

# --- 2c. models ----------------------------------------------------------------
# Seats come from tests/run-tasks-models.tsv - the tags the toolcalls probe has
# actually measured PASS on (AGENTS.md Gotchas: a probe PASS is necessary, not
# sufficient) - intersected with each live host's /api/tags, so a new model is
# one TSV row and a down host / an unpulled tag drops out by itself. Pick
# "custom" to type any other opencode model id - nothing stops you, but an
# un-probed model may silently no-op (liar mode) instead of failing loudly.
Write-Host ""
Write-Host "=== Select models ===" -ForegroundColor Cyan
# Hosted seats (opencode-go): listed by opencode, key file present, config
# resolves. Read once; Get-AvailableModelSeats and the filter below both use it.
$hostedState = Get-HostedState -KeyFile $goKeyPath -ConfigOk ($null -ne (Get-OpencodeConfig))
$goRates = Get-GoRates -Path $goRatesPath
$available = @(Get-AvailableModelSeats)
$availableLocal  = @($available | Where-Object { -not (Test-HostedModelId $_) })
$availableHosted = @($available | Where-Object { Test-HostedModelId $_ })
$selectedModels = New-Object System.Collections.Generic.List[string]
if ($Mode -eq "Both") {
    # Every available local seat; the probe filter below keeps only
    # current-version PASSes. Hosted seats have no probe, so Both leaves them out.
    foreach ($m in $availableLocal) { $selectedModels.Add($m) }
    if ($availableHosted.Count -gt 0) {
        Write-Host "  ($($availableHosted.Count) hosted seat(s) left out: Both mode runs probed seats only. Run them with -Mode Tasks -Models hosted.)" -ForegroundColor DarkGray
    }
} elseif ($Models) {
    # 'all' = every available LOCAL seat; 'hosted' = every available hosted
    # seat. A paid seat is never picked up by 'all'.
    foreach ($tok in (Split-IdList $Models)) {
        $pick = switch ($tok.ToLower()) { "all" { $availableLocal } "hosted" { $availableHosted } default { @($tok) } }
        foreach ($m in $pick) { if (-not $selectedModels.Contains($m)) { $selectedModels.Add($m) } }
    }
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
$hostedCaps = @{}   # hosted model id -> Get-SpendCap result; absent = uncapped
foreach ($m in $selectedModels) {
    if (Test-HostedModelId $m) {
        # Hosted: none of the Ollama checks apply (no host, no probe). The gate
        # and the spend cap do.
        if ($Mode -eq "Both") {
            Write-Host "  [drop] $m - hosted seats have no probe; Both mode runs probed seats only" -ForegroundColor Yellow
            continue
        }
        $why = Get-HostedSeatGate -ModelId $m -State $hostedState
        if ($why) {
            Write-Host "  [drop] $m - $why" -ForegroundColor Yellow
            continue
        }
        if (-not $NoSpendCap) {
            $cap = Get-SpendCap -ModelId $m -Rates $goRates -Share $SpendCapShare
            if ($cap.Refusal) {
                Write-Host "  [drop] $m - $($cap.Refusal). No rate, no runs: add the row to costs/go-rates.tsv (rates and monthly allowance from the Go docs), or pass -NoSpendCap to run it uncapped." -ForegroundColor Yellow
                continue
            }
            $hostedCaps[$m] = $cap
        }
        Write-Host "  note: $m is hosted - smoke-tested (opencode run --auto wrote a file, 2026-10-06), not probed: test-toolcalls.ps1 is Ollama-only." -ForegroundColor DarkGray
        $kept.Add($m)
        continue
    }
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
$ordered = $selectedModels | Sort-Object { $mm = $_; @($selectedTasks | Where-Object { $graded["$_|$mm"] }).Count }, { $_ }
$plan = New-RunList -Models @($ordered) -Tasks @($selectedTasks) -Reps $repCount -Graded $graded -OnlyMissing:$OnlyMissing -BackToBack:$BackToBack
$runList = $plan.Runs
$skipped = $plan.Skipped
$total = $runList.Count

# One batch, one opencode version: read now, checked before every run.
$batchOpencode = Get-OpencodeVersion

Write-Host ""
Write-Host "=== Plan ===" -ForegroundColor Cyan
Write-Host "  Tasks:  $($selectedTasks -join ', ')"
Write-Host "  Models: $($ordered -join ', ')"
Write-Host "  Reps:   $repCount each  ->  $total total run(s)"
if ($repCount -gt 1) {
    Write-Host ("  Order:  {0}" -f $(if ($BackToBack) { "back-to-back (a cell's reps adjacent)" } else { "rep-outer (a cell's reps a full pass apart)" }))
}
Write-Host ("  opencode: {0}" -f $(if ($batchOpencode) { $batchOpencode } else { "unknown - a version change mid-batch cannot be detected" }))
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
# Hosted seats were gated when selected (listed, key file present, config
# resolves); here each one's spend cap in dollars.
$hostedSelected = @($selectedModels | Where-Object { Test-HostedModelId $_ })
if ($hostedSelected.Count -gt 0) {
    Write-Host "  [PASS] opencode-go  key file present at $goKeyPath (not read); $($hostedSelected.Count) hosted seat(s) listed by opencode" -ForegroundColor Green
    foreach ($m in $hostedSelected) {
        if ($hostedCaps.ContainsKey($m)) {
            $rate = $goRates[$m]
            Write-Host ("  [CAP]  {0}  {1}; rates checked {2}" -f $m, (Format-SpendCap $hostedCaps[$m]), $rate.checked) -ForegroundColor Green
        } elseif ($goRates.ContainsKey($m)) {
            Write-Host "  [WARN] $m  -NoSpendCap: NO cap. Spend is still estimated and reported." -ForegroundColor Yellow
        } else {
            Write-Host "  [WARN] $m  -NoSpendCap and no rate row: NO cap, and its spend cannot be estimated." -ForegroundColor Yellow
        }
    }
}
# opencode installs patch releases by itself when a TUI starts, so opening
# OpenCode on this machine mid-batch can swap the binary under it. Not a FAIL:
# the drift check below stops the batch if it happens.
if (Test-OpencodeAutoupdatePinned -Config (Get-OpencodeConfig)) {
    Write-Host "  [PASS] opencode autoupdate is pinned" -ForegroundColor Green
} else {
    Write-Host '  [WARN] opencode autoupdate is ON - starting the OpenCode TUI on this machine can upgrade the binary under a running batch.' -ForegroundColor Yellow
    Write-Host '         The batch stops if the version changes. Pin it: "autoupdate": "notify" in opencode.jsonc, or OPENCODE_DISABLE_AUTOUPDATE=1.' -ForegroundColor Yellow
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
$stopped = $null
$hostedSpend  = @{}   # hosted model id -> estimated USD this batch
$hostedRan    = @{}   # hosted model id -> runs started
$hostedCapped = @{}   # hosted model id -> runs skipped at the cap
foreach ($run in $runList) {
    $runNum++
    $drift = Get-OpencodeVersionDrift -Expected $batchOpencode
    if ($drift) {
        $stopped = "$drift, before run $runNum of $total; $($total - $runNum + 1) run(s) not started. A cell must not straddle versions: pin autoupdate, then re-run the rest on one version."
        break
    }
    $isHosted = Test-HostedModelId $run.Model
    if ($isHosted) {
        $capMsg = Get-CapStatus -ModelId $run.Model -Caps $hostedCaps -Spend $hostedSpend
        if ($capMsg) {
            if (-not $hostedCapped.ContainsKey($run.Model)) {
                $left = @($runList | Select-Object -Skip ($runNum - 1) | Where-Object { $_.Model -eq $run.Model }).Count
                Write-Host ""
                Write-Host "  [CAP] $($run.Model): $capMsg - skipping its remaining $left run(s). Other models carry on." -ForegroundColor Yellow
                $hostedCapped[$run.Model] = 0
            }
            $hostedCapped[$run.Model]++
            continue
        }
        $filesBefore = Get-ResultFileNames -Dir $taskResultsDir
        $hostedRan[$run.Model] = [int]$hostedRan[$run.Model] + 1
    }
    Write-Host ""
    Write-Host ">>> [$runNum/$total] $($run.Task)  x  $($run.Model)  (rep $($run.Rep) of $repCount)" -ForegroundColor Cyan
    $taskArgs = @{ Task = $run.Task; Model = $run.Model; ModelLabel = $run.Model }
    if ($RunTimeout -gt 0) { $taskArgs['RunTimeout'] = $RunTimeout }
    if ($CommandTimeout -gt 0) { $taskArgs['CommandTimeout'] = $CommandTimeout }
    if ($IncludeRetired) { $taskArgs['IncludeRetired'] = $true }
    if ($TaskManifest) { $taskArgs['TaskManifest'] = $manifestPath }
    if ($ResultsDir) { $taskArgs['ResultsDir'] = $taskResultsDir }
    # One run's uncaught exception must not end an unattended batch: on
    # 2026-10-02 a dead job host in run 1 of 16 threw out of test-tasks.ps1 and
    # the other 15 never started. Record the run as crashed and move on.
    # test-tasks.ps1 restores a task's test env and source files in finally
    # blocks, and the next run of a task rebuilds its worktree from the pin.
    $crash = $null
    try {
        & $testTasksPs1 @taskArgs
        $code = $LASTEXITCODE
    } catch {
        $crash = "$($_.Exception.Message) [$($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)]"
        $code = "crash"
        Write-Host "  CRASH: $crash - continuing with the next run" -ForegroundColor Red
    }
    # Hosted: count what this run spent, graded or not (a crashed or
    # infrastructure run may still have been billed).
    if ($isHosted) {
        $rate = $goRates[$run.Model]
        if ($rate) {
            $spend = Measure-RunSpend -ResultsDir $taskResultsDir -Before $filesBefore -TaskId $run.Task -ModelLabel $run.Model -Rate $rate
            $hostedSpend[$run.Model] = [double]$hostedSpend[$run.Model] + $spend.Usd
            $ofCap = if ($hostedCaps.ContainsKey($run.Model)) { " of its " + (Format-SpendCap $hostedCaps[$run.Model]) } else { " (no cap)" }
            Write-Host ("  spend: about {0} this run ({1}); {2} so far {3}{4}" -f (Format-Usd $spend.Usd), ($spend.Sources -join ", "), $run.Model, (Format-Usd $hostedSpend[$run.Model]), $ofCap) -ForegroundColor DarkGray
        } else {
            Write-Host "  spend: not estimated - $($run.Model) has no row in costs/go-rates.tsv (-NoSpendCap)" -ForegroundColor Yellow
        }
    }
    $results.Add([pscustomobject]@{
        Task     = $run.Task
        Model    = $run.Model
        Rep      = $run.Rep
        ExitCode = $code
    })
}

Write-Host ""
Write-Host $(if ($stopped) { "=== Batch STOPPED ===" } else { "=== Batch complete ===" }) -ForegroundColor $(if ($stopped) { "Red" } else { "Cyan" })
$results | Format-Table -AutoSize
$hostedInBatch = @($selectedModels | Where-Object { Test-HostedModelId $_ })
if ($hostedInBatch.Count -gt 0) {
    Write-Host "=== Hosted spend (estimated, this batch) ===" -ForegroundColor Cyan
    foreach ($m in $hostedInBatch) {
        $spentTxt = if ($goRates.ContainsKey($m)) { Format-Usd ([double]$hostedSpend[$m]) } else { "not estimated (no rate row)" }
        $capTxt   = if ($hostedCaps.ContainsKey($m)) { "of its " + (Format-SpendCap $hostedCaps[$m]) } else { "no cap (-NoSpendCap)" }
        $skipTxt  = if ($hostedCapped.ContainsKey($m)) { "; $($hostedCapped[$m]) skipped at the cap" } else { "" }
        Write-Host ("  {0,-34} {1} {2}  - {3} run(s){4}" -f $m, $spentTxt, $capTxt, [int]$hostedRan[$m], $skipTxt)
    }
    Write-Host "  Estimates from costs/go-rates.tsv; the Go console is the bill." -ForegroundColor DarkGray
    Write-Host ""
}
if ($stopped) {
    Write-Host $stopped -ForegroundColor Red
    exit 1
}

$cappedRuns = 0
foreach ($n in $hostedCapped.Values) { $cappedRuns += $n }
if ($cappedRuns -gt 0) {
    Write-Host "$cappedRuns run(s) not started: their hosted model reached its spend cap (see above)." -ForegroundColor Yellow
}
$ranCount = $results.Count
$fails = @($results | Where-Object { $_.ExitCode -ne 0 })
if ($fails.Count -gt 0) {
    Write-Host "$($fails.Count) of $ranCount run(s) exited non-zero (test-tasks.ps1 exits 1 on any FAIL grade)." -ForegroundColor Yellow
    Write-Host "Per-run detail is in $taskResultsDir and the appended rows in its tasks-summary.tsv / real-tasks-summary.tsv." -ForegroundColor Yellow
} else {
    Write-Host "All $ranCount run(s) completed with exit 0 (no FAIL grade - a run can still carry a WARN)." -ForegroundColor Green
}

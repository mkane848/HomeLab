# test-tasks.ps1 - Task-veracity benchmark: real tasks through the real OpenCode
# tool loop, graded mechanically.
#
# Why this exists (see docs/roadmap.md "review-gate run 2 follow-ups" and the
# benchmark plan agreed 2026-09-19): the fleet harness (test-profiles.ps1,
# test-toolcalls.ps1) proves a model CAN call tools and WHAT it measures about
# latency/limits. It says nothing about whether what a model PRODUCES is
# correct. This script runs each task's fixed prompt through `opencode run`
# against a THROWAWAY WORKTREE (never the live checkout - an open PR sits on
# the target branch), then grades the result the way the fix-and-reverify gate
# says grading must work:
#
#   scope      - the diff touches ONLY the manifest's allowFiles.
#   suite      - the repo's own unit suite passes after the change.
#   failsOnOld - revert ONLY the source files (checked out of the pinned base,
#                the model's test kept), the suite must now FAIL. This is the PR #82
#                "green test that never enters its claimed branch" trap made
#                mechanical: a test that passes on broken code = FAIL here.
#                SKIP when the suite is already red with the model's change: a
#                suite that fails either way says nothing about the test.
#   typecheck  - scoped to the touched module graph (informational, never FAIL:
#                the full project needs every workspace package built first).
#                PASS/WARN only when the task defines a `typecheck` block;
#                SKIP when it does not, because a task that compiled nothing
#                must not read as one that compiled cleanly.
#   acceptance - informational, never a gate: when the task defines an
#                `acceptance` block ({ ref, commit, files }), the owner's (or, for
#                tasks mined from a real fix, the upstream fix commit's own) test
#                files at that pinned commit are swapped in over the model's, testCmd runs
#                against the model's source, and the model's files are restored.
#                Recorded in the per-run JSON only (PASS/FAIL/ERROR/SKIP + the
#                exact commit used); the TSV schema is unchanged. Under -DryRun
#                the same tests run on the untouched base and must FAIL.
#
# What is NOT graded, and why that distinction is load-bearing: a run only
# reaches those gates if `opencode run` exited 0. opencode exits 0 even when
# the model answers in prose and writes nothing, so `writes = 0` on an exit-0
# run is liar mode - unless the last step ended on the output cap (finish reason
# "length" at limit.output, no text or tool call in that step). That seat ran
# out of room to act and never answered at all; the writes gate says so and the
# run JSON records `outputCapHit`. Both are FAILs, but they are not the same
# finding. ANY non-zero exit is infrastructure -
# unreachable provider, bad model id, crash - and is reported as a FAILed run
# with an `_INFRA_`/`_TIMEOUT_` transcript and NO summary row, because it
# measured nothing about the model. This used to fall through to the writes
# gate, which is how six unreachable-endpoint transcripts ("Cannot connect to
# API", 307 bytes each) were recorded as a "6/6 liar mode" capability finding
# for node3 and then cited in a config change. A missing row is the correct
# record of a run that never happened.
#
# Which model/setting combos to compare is the whole point - run the same task
# on each seat and the pass/fail table is the tuning signal. No config or
# seat change until ~3 graded runs across >=2 tasks (the agreed gate).
#
# Reproducibility, and its current limit: every run records `ollamaVersion`/
# `opencodeVersion` (the serving host's /api/version - "n/a" for a hosted
# provider - and `opencode --version`) and the
# raw JSONL transcript is now KEPT (moved into tests/results/, not deleted) -
# see `samplingControl` in each result JSON. What this harness does NOT do is
# pin a seed or temperature: `opencode run` has no known per-invocation flag
# for either, and opencode.jsonc's model schema only supports
# limit/modalities/tool_call (see AGENTS.md), not sampling params. Contrast
# docs/review-gate/r3-runner.ps1, which calls the Ollama API directly to pin
# seed/temperature/num_ctx/num_predict - at the cost of not exercising the
# real opencode tool loop this harness exists to test. If the retained
# transcripts turn out to carry usable request-parameter fields once
# inspected, extracting them is a follow-up; this harness does not assume a
# shape it hasn't verified.
#
# Test environment: a task's manifest `testEnv` (name -> value; null or "" =
# unset) is applied to the test command AND to the `opencode run` process, so
# the model's own shell and every gate see the same variables whatever the
# harness process happens to hold, and is restored afterwards. It is recorded
# in each run JSON as `testEnv` (absent on earlier rows, which ran under the
# ambient environment). asohav-02 needs it: see that task's `testEnvNote`.
#
# Usage (PowerShell, from anywhere; source a profile first so OPENCODE_MODEL/
# OLLAMA_*_BASE_URL are set, or pass -Model):
#   .\tests\test-tasks.ps1 -Task kane-01-background-pair -Model ollama-desktop/qwen3:14b
#   .\tests\test-tasks.ps1 -Task kane-01-background-pair -Model ollama-desktop/qwen3:8b
#   .\tests\test-tasks.ps1 -Task kane-01-background-pair -Model ollama-desktop/devstral:24b
#   .\tests\test-tasks.ps1                                  # every manifest task (default model = $env:OPENCODE_MODEL)
#   .\tests\test-tasks.ps1 -Task kane-01-background-pair -NoReset   # debug: keep worktree as the model left it
#   .\tests\test-tasks.ps1 -Task kane-01-background-pair -Cleanup   # remove the worktree after grading
#
# Options:
#   -Task <id[,id]>     tasks from tests/tasks/manifest.json (default: all).
#   -Model <id>         opencode model id, e.g. ollama-desktop/qwen3:14b.
#   -ModelLabel <text>  short label for the results table/filenames (default: model id).
#   -RunTimeout         seconds per opencode run before it is killed (default 900).
#   -CommandTimeout     seconds per grading command (tests/typecheck, default 300).
#   -NoReset            start from the worktree's current state instead of resetting to the branch tip.
#   -SkipInstall        skip pnpm install/setup even if the marker is missing.
#   -DryRun             create/reset the worktree, install, run the baseline, then stop before the model run.
#   -Cleanup            remove the task worktree after grading.
#   -EditFormat write|edit  append a prompt directive forcing whole-file writes
#                       (write) or substring search-replace edits (edit). The
#                       directive is part of the hashed prompt, so each arm
#                       records a distinct sha. Used for the edit-format A/B
#                       (methodology-research.md Accelerator B).
#
# Exit code: 0 if no FAIL grade across all runs, 1 otherwise.
# Results: tests/results/tasks-<taskId>-<label>_<timestamp>.json AND the
# matching .jsonl raw transcript per run, plus one row appended to
# tests/results/tasks-summary.tsv (unchanged 12-column schema - the richer
# new fields live in the per-run JSON, not the summary row).

param(
    [string[]]$Task = @(),
    [string]$Model = "",
    [string]$ModelLabel = "",
    [int]$RunTimeout = 900,
    [int]$CommandTimeout = 300,
    [switch]$NoReset,
    [switch]$SkipInstall,
    [switch]$DryRun,
    [switch]$Cleanup,
    # Where the serving Ollama writes server.log, for the prompt-truncation
    # check. Default: %LOCALAPPDATA%\Ollama when the model's provider points at
    # localhost; any other host is not checked (its log is on that machine).
    [string]$OllamaLogDir = "",
    # Run a task the manifest marks `retired` (see Resolve-TaskSelection).
    [switch]$IncludeRetired,
    [ValidateSet("write", "edit", "")]
    [string]$EditFormat = ""
)

$ErrorActionPreference = "Stop"

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $scriptDir
$manifestPath = Join-Path $scriptDir "tasks\manifest.json"
$wtRoot     = Join-Path $scriptDir ".worktrees"
$resultsDir = Join-Path $scriptDir "results"
$summaryTsv = Join-Path $resultsDir "tasks-summary.tsv"

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "ERROR: manifest not found at $manifestPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $wtRoot)) {
    New-Item -ItemType Directory -Path $wtRoot -Force | Out-Null
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$allTasks = @($manifest.tasks)

function Resolve-TaskSelection {
    # Which manifest tasks to run. A task with a `retired` object ({date,
    # reason, see}) stays in the manifest - its id, pin and rows are history -
    # but is not run: left out of a no-argument run, and an error when named,
    # unless -IncludeRetired. First retired 2026-10-03: asohav-05/06, which no
    # 64k seat can see as pinned (tests/results/README.md -> "Prompt truncated
    # by Ollama").
    param($AllTasks, [string[]]$Requested, [bool]$IncludeRetired)
    $named = @($Requested | Where-Object { $_ } | ForEach-Object { $_.Trim() })
    $picked = if ($named.Count -gt 0) { @($AllTasks | Where-Object { $named -contains $_.id }) } else { @($AllTasks) }
    $retired = @($picked | Where-Object { $_.retired })
    $refused = @()
    if (-not $IncludeRetired -and $retired.Count -gt 0) {
        if ($named.Count -gt 0) { $refused = $retired }
        $picked = @($picked | Where-Object { -not $_.retired })
    }
    return [pscustomobject]@{ Run = $picked; Refused = $refused; Skipped = $(if ($named.Count -eq 0 -and -not $IncludeRetired) { $retired } else { @() }) }
}

$selection = Resolve-TaskSelection -AllTasks $allTasks -Requested $Task -IncludeRetired ([bool]$IncludeRetired)
if ($selection.Refused.Count -gt 0) {
    foreach ($r in $selection.Refused) {
        Write-Host "ERROR: $($r.id) is retired ($($r.retired.date)): $($r.retired.reason)" -ForegroundColor Red
        Write-Host "       see $($r.retired.see); pass -IncludeRetired to run it anyway" -ForegroundColor Red
    }
    exit 1
}
if ($selection.Skipped.Count -gt 0) {
    Write-Host "skipping $($selection.Skipped.Count) retired task(s): $(@($selection.Skipped | ForEach-Object id) -join ', ')" -ForegroundColor DarkGray
}
$tasksToRun = @($selection.Run)
if ($tasksToRun.Count -eq 0) {
    Write-Host "ERROR: no tasks matched. Manifest has: $($allTasks.id -join ', ')" -ForegroundColor Red
    exit 1
}

if (-not $Model) { $Model = $env:OPENCODE_MODEL }
if (-not $Model) {
    Write-Host "ERROR: no -Model given and OPENCODE_MODEL is unset - source a profile first (e.g. profiles/dev-workflow-quality.sh)" -ForegroundColor Red
    exit 1
}
if (-not $ModelLabel) { $ModelLabel = $Model }

$statusCounts = @{ PASS = 0; FAIL = 0; WARN = 0; SKIP = 0 }
$lines = [System.Collections.Generic.List[string]]::new()

function Write-Result {
    param([string]$Task, [string]$Check, [string]$Status, [string]$Detail = "")
    $statusCounts[$Status]++
    $color = switch ($Status) { "PASS" { "Green" } "FAIL" { "Red" } "WARN" { "Yellow" } "SKIP" { "Gray" } }
    Write-Host ("  [{0,-4}] {1}" -f $Status, $Check) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host ("  -> {0}" -f $Detail) -ForegroundColor Gray }
    else { Write-Host "" }
    $lines.Add("  [$Status] $Check -> $Detail")
}

# A native command's stderr becomes a terminating error under $ErrorActionPreference
# = "Stop" (AGENTS.md Gotchas). Every native invocation goes through here.
function Run-Native {
    param([string]$FilePath, [string[]]$Arguments = @(), [string]$WorkingDir = "")
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $cwd = (Get-Location).Path
    try {
        if ($WorkingDir) { Set-Location -LiteralPath $WorkingDir }
        $out = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        if ($WorkingDir) { Set-Location -LiteralPath $cwd }
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ ExitCode = $code; Output = @($out | ForEach-Object { "$_" }) }
}

function Get-HeadCommit {
    param([string]$Repo, [string]$Branch)
    $r = Run-Native "git" @("-C", $Repo, "rev-parse", "refs/heads/$Branch")
    if ($r.ExitCode -ne 0) { return $null }
    return ($r.Output | Where-Object { $_ } | Select-Object -First 1).Trim()
}

function Resolve-TaskBase {
    # The commit a task runs from. A task with `benchBaseCommit` is PINNED: the
    # worktree is made from that exact SHA, never from whatever a branch points at
    # today. lfc-01 and lfc-03 used to run from the tip of the local `main` and
    # kane-01 from a work branch, so one merge or rebase would have changed the
    # base under a corpus of rows meant to be comparable (every recorded row so
    # far did share one commit per task, which is what the pins now record). With a
    # pin the branch is only a label; a local branch of that name sitting
    # elsewhere is reported, not followed. A task without a pin falls back to the
    # branch tip, as before. Returns { Head; Ref; Source; Warning; Error }.
    param($Task)

    $tip = Get-HeadCommit $Task.repo $Task.branch
    $pin = $Task.benchBaseCommit
    if (-not $pin) {
        if (-not $tip) {
            return [pscustomobject]@{ Head = $null; Ref = $null; Source = "branch"; Warning = $null; Error = "cannot resolve refs/heads/$($Task.branch) in $($Task.repo)" }
        }
        return [pscustomobject]@{ Head = $tip; Ref = "refs/heads/$($Task.branch)"; Source = "branch"; Warning = $null; Error = $null }
    }

    $full = $null
    foreach ($attempt in 1, 2) {
        $r = Run-Native "git" @("-C", $Task.repo, "rev-parse", "--verify", "--quiet", "$pin^{commit}")
        if ($r.ExitCode -eq 0) { $full = ($r.Output | Where-Object { $_ } | Select-Object -First 1).Trim(); break }
        # A commit that is upstream but not yet local: one fetch, then look again.
        if ($attempt -eq 1) { Run-Native "git" @("-C", $Task.repo, "fetch", "origin", "--quiet") | Out-Null }
    }
    if (-not $full) {
        return [pscustomobject]@{ Head = $null; Ref = $null; Source = "pin"; Warning = $null
            Error = "pinned base $pin is not in $($Task.repo), even after git fetch origin. If it only ever lived on a local branch it was never pushed: git -C `"$($Task.repo)`" push origin ${pin}:refs/heads/$($Task.branch)" }
    }
    $warning = $null
    if ($tip -and $tip -ne $full) {
        $warning = "local branch $($Task.branch) is at $($tip.Substring(0, 10)), not the pinned $($full.Substring(0, 10)); running the pin"
    }
    return [pscustomobject]@{ Head = $full; Ref = $full; Source = "pin"; Warning = $warning; Error = $null }
}

function Resolve-AcceptanceCommit {
    # The commit the owner's acceptance tests are read from. `acceptance.commit` pins
    # it, for the reason the base is pinned: `acceptance.ref` is a local branch, and a
    # moved branch would change what "meets the owner's contract" means between runs
    # (all 18 recorded lfc-03 runs used one commit, which is the pin). A local branch
    # that has moved off the pin is reported, not followed; without a pin the branch
    # tip is used, as before. A pinned commit this clone does not have yet is fetched
    # from origin once before it is called missing. Returns { Commit; Warning; Error }.
    param($Task)

    $acc = $Task.acceptance
    $tip = Get-HeadCommit $Task.repo $acc.ref
    if (-not $acc.commit) {
        if (-not $tip) {
            return [pscustomobject]@{ Commit = $null; Warning = $null; Error = "cannot resolve refs/heads/$($acc.ref) in $($Task.repo)" }
        }
        return [pscustomobject]@{ Commit = $tip; Warning = $null; Error = $null }
    }
    $r = $null
    foreach ($attempt in 1, 2) {
        $r = Run-Native "git" @("-C", $Task.repo, "rev-parse", "--verify", "--quiet", "$($acc.commit)^{commit}")
        if ($r.ExitCode -eq 0) { break }
        # A commit that is upstream but not yet local (a task whose acceptance tests are an
        # upstream fix commit's own test file): one fetch, then look again, as Resolve-TaskBase does.
        if ($attempt -eq 1) { Run-Native "git" @("-C", $Task.repo, "fetch", "origin", "--quiet") | Out-Null }
    }
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Commit = $null; Warning = $null
            Error = "pinned acceptance commit $($acc.commit) is not in $($Task.repo), even after git fetch origin. If it only ever lived on the local branch $($acc.ref) and that branch was deleted or rewritten, restore the commit or re-pin it" }
    }
    $full = ($r.Output | Where-Object { $_ } | Select-Object -First 1).Trim()
    $warning = $null
    if ($tip -and $tip -ne $full) {
        $warning = "local branch $($acc.ref) is at $($tip.Substring(0, 10)), not the pinned acceptance commit $($full.Substring(0, 10)); running the pin"
    }
    return [pscustomobject]@{ Commit = $full; Warning = $warning; Error = $null }
}

function Get-WorktreeState {
    param([string]$Repo, [string]$WtPath)
    $r = Run-Native "git" @("-C", $Repo, "worktree", "list", "--porcelain")
    $norm = ($WtPath -replace '\\', '/').ToLowerInvariant()
    foreach ($line in $r.Output) {
        if ($line.StartsWith("worktree ") -and ($line.Substring(9).Trim().Replace('\', '/').ToLowerInvariant() -eq $norm)) { return $true }
    }
    return $false
}

# Snapshot the whole working-tree state (tracked mods + untracked files) as
# normalized forward-slash paths relative to the repo root. Uses `git status
# --porcelain` because `git diff --name-only` does not show untracked files.
function Get-TreeChanges {
    param([string]$WtPath)
    $r = Run-Native "git" @("-C", $WtPath, "status", "--porcelain")
    $files = @()
    foreach ($line in $r.Output) {
        if ($line.Length -lt 4) { continue }
        $p = $line.Substring(3).Trim()
        if ($p) { $files += ($p -replace '\\', '/') }
    }
    return @($files | Where-Object { $_ })
}

function Ensure-Worktree {
    param($Task, [string]$WtPath)

    $repo = $Task.repo
    # Install state lives OUTSIDE the worktree: an in-tree marker file shows up
    # in `git status --porcelain`, gets deleted by `git clean -fd` (forcing a
    # reinstall every other run), and is visible to the model while it works.
    $marker = Join-Path $wtRoot ("." + $Task.id + ".installed")
    $base = Resolve-TaskBase $Task
    if (-not $base.Head) {
        Write-Result $Task.id "worktree" "FAIL" $base.Error
        return $null
    }
    if ($base.Warning) { Write-Result $Task.id "base" "WARN" $base.Warning }
    $head = $base.Head
    $registered = Get-WorktreeState $repo $WtPath

    if (-not (Test-Path -LiteralPath $WtPath) -or -not $registered) {
        if (Test-Path -LiteralPath $WtPath) {
            # present-but-not-registered (e.g. leftover dir) - clear it; avoid
            # deleting a registered worktree (git tracks it by path, so a bare
            # Remove-Item leaves a stale "missing" registration that blocks add).
            Remove-Item -Recurse -Force -LiteralPath $WtPath
        } elseif ($registered) {
            # registered but directory already gone (earlier failed run) - clear
            # the stale record so `worktree add` can recreate the directory.
            Run-Native "git" @("-C", $repo, "worktree", "prune") | Out-Null
        }
        Write-Host "    adding throwaway worktree at $head (detached)..." -ForegroundColor DarkGray
        $r = Run-Native "git" @("-C", $repo, "worktree", "add", "--detach", $WtPath, $base.Ref)
        if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $WtPath)) {
            Write-Result $Task.id "worktree" "FAIL" "git worktree add failed: $($r.Output -join ' ')"
            return $null
        }
        $installed = ""
    } else {
        $installed = if (Test-Path -LiteralPath $marker) {
            (Get-Content -LiteralPath $marker -Raw).Trim()
        } else { "" }
    }

    if ($NoReset) {
        Write-Host "    -NoReset: starting from the worktree's current state" -ForegroundColor DarkGray
    } else {
        $r = Run-Native "git" @("-C", $WtPath, "reset", "--hard", $head)
        if ($r.ExitCode -ne 0) {
            Write-Result $Task.id "worktree" "FAIL" "git reset --hard failed"
            return $null
        }
        $r = Run-Native "git" @("-C", $WtPath, "clean", "-fd")
    }

    if ($installed -ne $head -and -not $SkipInstall) {
        # packageManager is optional per-task (manifest field); default "pnpm"
        # keeps kane-01 (no such field) running exactly as before. npm uses
        # `ci`, not `install`, as the lockfile-respecting equivalent of
        # pnpm's --frozen-lockfile - `npm install <flags>` would NOT enforce
        # the lockfile the way `ci` does.
        $pm = if ($Task.packageManager) { $Task.packageManager } else { "pnpm" }
        $pmVerb = if ($pm -eq "npm") { "ci" } else { "install" }
        Write-Host "    $pm $pmVerb $($Task.installFlags -join ' ') (first run on this worktree)..." -ForegroundColor DarkGray
        $installArgs = @($pmVerb) + @($Task.installFlags)
        $r = Run-Native $pm $installArgs $WtPath
        if ($r.ExitCode -ne 0) {
            Write-Result $Task.id "install" "FAIL" "$pm $pmVerb failed: $($r.Output | Select-Object -Last 3) - see AGENTS.md re native deps; the task may need --ignore-scripts"
            return $null
        }
        foreach ($step in @($Task.setup | Where-Object { $_ })) {
            $stepDir = if ($step.cwd) { Join-Path $WtPath $step.cwd } else { $WtPath }
            Write-Host "    setup: $($step.cmd -join ' ') (in $($step.cwd))" -ForegroundColor DarkGray
            $r = Run-Native $step.cmd[0] @($step.cmd[1..($step.cmd.Count - 1)]) $stepDir
            if ($r.ExitCode -ne 0) {
                Write-Result $Task.id "setup ($($step.cwd))" "FAIL" "setup command failed: $($r.Output | Select-Object -Last 3)"
                return $null
            }
            if ($step.copy) {
                $src = Join-Path $stepDir $step.copy[0]
                $dst = Join-Path $stepDir $step.copy[1]
                if (Test-Path -LiteralPath $src) {
                    $dstParent = Split-Path -Parent $dst
                    if (-not (Test-Path -LiteralPath $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
                    Copy-Item -LiteralPath $src -Destination $dst -Force
                } else {
                    Write-Result $Task.id "setup ($($step.cwd))" "WARN" "copy source missing: $src"
                }
            }
        }
        Set-Content -LiteralPath $marker -Value $head -Encoding ascii
    }
    return [pscustomobject]@{ Wt = $WtPath; Head = $head }
}

# A task's `testEnv` pins the environment its test command and the model's own
# shell run under. Without it a gate result depends on whatever the harness
# process happens to hold: asohav-02's model-written test imports the real
# repo.ts, which imports pgPool.ts, which throws at import time unless
# DATABASE_URL is set - so that kind of test file could not load on 2026-09-27
# (variable absent: the models' own vitest runs show the error) and passed on
# 2026-09-29 (present), with nothing in the result saying which. Set-TaskTestEnv
# applies the pins and returns what Restore-TaskTestEnv needs to put the process
# back, so one task's pins never leak into the next task of the same batch.
function Set-TaskTestEnv {
    param($Task)
    $saved = [ordered]@{}
    if ($Task -and $Task.PSObject.Properties["testEnv"] -and $Task.testEnv) {
        foreach ($p in $Task.testEnv.PSObject.Properties) {
            $saved[$p.Name] = [Environment]::GetEnvironmentVariable($p.Name)
            $value = if ($null -eq $p.Value) { "" } else { [string]$p.Value }
            [Environment]::SetEnvironmentVariable($p.Name, $value)   # "" removes the variable
        }
    }
    return , $saved
}

function Restore-TaskTestEnv {
    param($Saved)
    if (-not $Saved) { return }
    foreach ($name in @($Saved.Keys)) { [Environment]::SetEnvironmentVariable($name, $Saved[$name]) }
}

function Invoke-Test {
    param($Task, [string]$WtPath)
    $testDir = Join-Path $WtPath $Task.testDir
    $savedEnv = Set-TaskTestEnv $Task
    try {
        return Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir
    } finally {
        Restore-TaskTestEnv $savedEnv
    }
}

function Get-FailedTestNames {
    param([string[]]$Output)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Output) {
        foreach ($m in [regex]::Matches($line, '(?m)\s*FAIL\s+.*>\s*(.+?)\s*$')) {
            $names.Add($m.Groups[1].Value.Trim())
        }
        foreach ($m in [regex]::Matches($line, 'Tests\s+(\d+)\s+failed')) {
            $names.Add("($($m.Groups[1].Value) failed)")
        }
    }
    # Suite-level failures are a different animal from per-test failures: vitest
    # reports a file that fails to LOAD (module-level parse/transform error) as
    # "Failed Suites N" / "Test Files N failed" / "Tests no tests", with the file
    # on a bare "FAIL <file> [ <file> ]" line (no "> test name"), and produces no
    # "Tests N failed" line. The old matchers missed all of it, so a model that
    # broke a file's compilation read as an unexplained empty FAIL (confirmed on
    # lfc-01 2026-09-19: qwen3:8b left top-level `await` + an unbound `db` in
    # listings.ts; the suite FAIL printed no names). Capture it explicitly so the
    # distinction shows up in the grade detail instead of vanishing.
    $suiteCount = 0
    $suiteFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Output) {
        # "Failed Suites N" is THE suite-level signal: vitest emits it only for
        # load/parse failures, while ordinary per-test failures ("Failed Tests N")
        # still raise the "Test Files N failed" summary counter. Gate on it so a
        # normal failing suite never gets misclassified (confirmed against real
        # vitest v5 output on 2026-09-19).
        $m = [regex]::Match($line, 'Failed Suites\s+(\d+)')
        if ($m.Success) { $suiteCount = [int]$m.Groups[1].Value }
        foreach ($f in [regex]::Matches($line, 'FAIL\s+(\S+\.test\.\S+)\s+\[')) {
            $suiteFiles.Add($f.Groups[1].Value)
        }
    }
    if ($suiteCount -gt 0) {
        $files = @($suiteFiles | Select-Object -Unique)
        $detail = if ($files) { ": $($files -join ', ')" } else { " (file not detected)" }
        $names.Add("($suiteCount failed suite(s) - load/parse error, per-test list skipped$detail)")
    }
    return @($names | Select-Object -Unique)
}

# Archive a transcript into tests/results/ with retry. The source lives in
# %TEMP% and was written by a just-finished/killed background job; a cross-volume
# move (C:\Temp -> M:\results is a copy+delete) fails with a sharing violation if
# any handle (opencode teardown, AV/indexer scan) still holds the file. The old
# code ran Move-Item -ErrorAction SilentlyContinue and still printed "kept",
# which is how 15 transcripts stranded on 2026-09-21 and 12 more on 2026-09-22.
# This retries the move, falls back to copy+delete (copy succeeds when the lock
# only blocks the delete step), and reports loudly if the source is truly stuck.
function Move-Transcript {
    param([string]$Source, [string]$Destination)

    for ($i = 1; $i -le 5; $i++) {
        try {
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return $true
        } catch {
            Start-Sleep -Milliseconds (250 * $i)
        }
    }
    try {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

# failsOnOld reverts the task's source files and puts the model's versions back afterwards.
# It used to do that with `git stash push` / `git stash pop`, but refs/stash belongs to the
# REPOSITORY, not to a worktree: two tasks of one repo graded at the same time (two terminals,
# the documented way to run seats concurrently) pushed and popped each other's
# stashes. A pop could apply the other task's source into this worktree, or fail and leave this
# task's source reverted for the acceptance run that follows, and a collision on the stash lock
# would read as "git stash push failed - cannot grade". Saving the model's bytes and checking the
# files out of the pinned base touches nothing outside this worktree.
function Save-SourceFiles {
    param([string]$WtPath, [string[]]$Files)
    $saved = [ordered]@{}
    foreach ($f in $Files) {
        $full = Join-Path $WtPath $f
        $saved[$f] = if (Test-Path -LiteralPath $full) { [System.IO.File]::ReadAllBytes($full) } else { $null }
    }
    return , $saved
}

# Puts Save-SourceFiles' bytes back (a file that did not exist is removed again). Returns $true
# when every file is byte for byte what it was.
function Restore-SourceFiles {
    param([string]$WtPath, $Saved)
    $same = $true
    foreach ($f in @($Saved.Keys)) {
        $full = Join-Path $WtPath $f
        if ($null -eq $Saved[$f]) {
            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $full) { $same = $false }
        } else {
            [System.IO.File]::WriteAllBytes($full, $Saved[$f])
            if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($full)) -ne [Convert]::ToBase64String($Saved[$f])) { $same = $false }
        }
    }
    return $same
}

# Runs the task's tests with its source files checked out of $BaseCommit (the model's tests and
# every other file untouched), then puts the model's source back whatever happened. Returns
# { Result = the Invoke-Test result, or $null; Error = why it could not run, or $null;
# Restored = $true when the model's files are back byte for byte }.
function Invoke-WithSourceReverted {
    param($Task, [string]$WtPath, [string]$BaseCommit)
    $saved = Save-SourceFiles $WtPath @($Task.srcRevertFiles)
    $result = $null
    $err = $null
    try {
        # Concatenate, never nest: a nested @($Task.srcRevertFiles) reaches Run-Native's
        # [string[]] parameter as ONE space-joined element ("a.ts b.ts"), which git
        # rejects as a pathspec, so any task listing 2+ files could not be graded.
        $r = Run-Native "git" (@("-C", $WtPath, "checkout", $BaseCommit, "--") + @($Task.srcRevertFiles))
        if ($r.ExitCode -ne 0) { $err = "git checkout of the source files failed: $($r.Output -join ' ')" }
        else { $result = Invoke-Test $Task $WtPath }
    } finally {
        $restored = Restore-SourceFiles $WtPath $saved
    }
    return [pscustomobject]@{ Result = $result; Error = $err; Restored = $restored }
}

# Owner-authored acceptance tests, run against whatever source is in the
# worktree. Informational only - never a gate: the four gates ask "did the
# model prove its own fix", this asks "does the result meet the owner's
# contract", and folding the second into the first would change the protocol
# mid-trial. The task's `acceptance.files` are checked out from `acceptance.ref`
# (a local branch in the task repo) over the worktree's copies, `testCmd` runs,
# and the worktree's own copies - the model's tests - are put back byte for byte.
# Status: PASS/FAIL = the owner's tests passed/failed; ERROR = could not run or
# could not restore (the worktree then needs inspecting).
function Invoke-Acceptance {
    param($Task, [string]$WtPath)

    $acc = $Task.acceptance
    $accBase = Resolve-AcceptanceCommit $Task
    if (-not $accBase.Commit) {
        return [pscustomobject]@{ Status = "ERROR"; Ref = $acc.ref; Commit = $null; Detail = $accBase.Error }
    }
    if ($accBase.Warning) { Write-Host "    acceptance: $($accBase.Warning)" -ForegroundColor Yellow }
    $sha = $accBase.Commit
    $files = @($acc.files)
    $saved = @{}
    foreach ($f in $files) {
        $full = Join-Path $WtPath $f
        $saved[$f] = if (Test-Path -LiteralPath $full) { [System.IO.File]::ReadAllBytes($full) } else { $null }
    }
    $statusBefore = (Get-TreeChanges $WtPath) -join "|"

    $result = $null
    $co = Run-Native "git" (@("-C", $WtPath, "checkout", $sha, "--") + $files)
    if ($co.ExitCode -ne 0) {
        $result = [pscustomobject]@{ Status = "ERROR"; Ref = $acc.ref; Commit = $sha; Detail = "git checkout of acceptance files failed: $($co.Output -join ' ')" }
    } else {
        $t = Invoke-Test $Task $WtPath
        $summary = ($t.Output | Select-String -Pattern "Tests\s+.*\((\d+)\)" | Select-Object -Last 1)
        $summaryText = if ($summary) { $summary.Line.Trim() } else { "no test summary line" }
        if ($t.ExitCode -eq 0) {
            $result = [pscustomobject]@{ Status = "PASS"; Ref = $acc.ref; Commit = $sha; Detail = $summaryText }
        } else {
            $failed = Get-FailedTestNames -Output $t.Output
            $result = [pscustomobject]@{ Status = "FAIL"; Ref = $acc.ref; Commit = $sha; Detail = "$summaryText - $($failed -join '; ')" }
        }
    }

    # Restore: unstage (checkout <sha> -- stages the files), then put the saved
    # bytes back, or remove a file the worktree did not have before.
    Run-Native "git" (@("-C", $WtPath, "reset", "-q", "--") + $files) | Out-Null
    foreach ($f in $files) {
        $full = Join-Path $WtPath $f
        if ($null -eq $saved[$f]) {
            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::WriteAllBytes($full, $saved[$f])
        }
    }
    $restored = ((Get-TreeChanges $WtPath) -join "|") -eq $statusBefore
    foreach ($f in $files) {
        $full = Join-Path $WtPath $f
        $now = if (Test-Path -LiteralPath $full) { [System.IO.File]::ReadAllBytes($full) } else { $null }
        if (($null -eq $now) -ne ($null -eq $saved[$f])) { $restored = $false }
        elseif ($null -ne $now -and [Convert]::ToBase64String($now) -ne [Convert]::ToBase64String($saved[$f])) { $restored = $false }
    }
    if (-not $restored) {
        $result.Status = "ERROR"
        $result.Detail = "worktree NOT restored after the acceptance run - inspect $WtPath before trusting it ($($result.Detail))"
    }
    return $result
}

function Get-FirstTranscriptError {
    # opencode writes a JSONL event stream; a provider-level failure shows up as
    # a single {"type":"error",...} line and nothing else (the six node3 runs of
    # 2026-09-20/21 were 307-byte transcripts holding exactly that). Surface its
    # message so the console says "Cannot connect to API" instead of "exit 1".
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if ($e.type -ne "error") { continue }
        $text = (@($e.error.name, $e.error.data.message) | Where-Object { $_ }) -join ": "
        $url  = $e.error.data.metadata.url
        if ($url) { $text = "$text [$url]" }
        if ($text) { return $text }
    }
    return $null
}

function Get-TranscriptEnding {
    # How the run's LAST step ended, from the raw opencode JSONL: the finish
    # reason and output-token count of the final step_finish, and whether that
    # step put any text or tool call in the transcript. Everything resets at each
    # step_start, so an earlier step that hit the cap and was followed by a
    # normal one does not count.
    param([string]$Path)

    $end = [pscustomobject]@{ FinishReason = $null; OutputTokens = $null; LastStepHadContent = $false }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $end }
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if ($e.type -eq "step_start") {
            $end.FinishReason = $null; $end.OutputTokens = $null; $end.LastStepHadContent = $false
        } elseif ($e.type -eq "text" -or $e.type -eq "tool_use") {
            $end.LastStepHadContent = $true
        } elseif ($e.type -eq "step_finish") {
            $end.FinishReason = $e.part.reason
            $end.OutputTokens = $e.part.tokens.output
        }
    }
    return $end
}

function Test-OutputCapHit {
    # True when the last step was cut off by the output cap: reason "length" with
    # output tokens at limit.output and no text or tool call in that step (the
    # whole budget went to reasoning the transcript does not show). That seat ran
    # out of room to act; it did not describe a change instead of making it.
    # Without the resolved limit a cap cannot be told from a context stop, so an
    # unknown $Limit says no.
    param($Ending, $Limit)

    if ($null -eq $Limit -or $null -eq $Ending.OutputTokens) { return $false }
    return ($Ending.FinishReason -eq "length" -and -not $Ending.LastStepHadContent -and [int]$Ending.OutputTokens -ge [int]$Limit)
}

function Get-ModelOutputLimit {
    # limit.output for -ModelId in the RESOLVED opencode config (`opencode debug
    # config`, the same source test-profiles.ps1 checks). $null when it cannot be
    # read - opencode missing, config invalid, model not registered - so the gate
    # degrades to "cannot confirm a cap" instead of failing the run.
    param([string]$ModelId)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $cfg = (& opencode debug config 2>$null | Out-String) | ConvertFrom-Json -ErrorAction Stop
        $provider, $name = $ModelId -split '/', 2
        $lim = $cfg.provider.PSObject.Properties[$provider].Value.models.PSObject.Properties[$name].Value.limit
        if ($lim -and $lim.output) { return [int]$lim.output }
    } catch {
        # fall through to $null
    } finally {
        $ErrorActionPreference = $prev
    }
    return $null
}

function Get-OllamaPromptTruncation {
    # Ollama's "truncating input prompt" warnings logged between $Since and
    # $Until. When a request is longer than the served num_ctx, Ollama keeps
    # the first `keep` tokens (4) and the tail of the window and drops the
    # rest - the system prompt, the tool schemas and the task go first. The
    # model then answers whatever is left, usually in prose, and the writes
    # gate used to file that as liar mode. On 2026-10-03 asohav-05/06 did this
    # on all four runs: the repo's 280 KB CLAUDE.md at their pins made the
    # first request ~83k tokens against qwen3.6's 65,536.
    # The log has no request id, so a second run against the same Ollama at
    # the same time would be blamed too; the harness runs one at a time.
    param([string]$LogDir, [DateTimeOffset]$Since, [DateTimeOffset]$Until)
    $hits = @()
    if (-not $LogDir -or -not (Test-Path -LiteralPath $LogDir)) { return $hits }
    # server.log is current; Ollama renames it to server-1.log (and so on) when
    # it restarts, so a restart mid-run leaves part of the run in a rotated file.
    # server.log is always read: Windows does not keep LastWriteTime current on
    # a file another process holds open (it read 14:37 at 17:30 on 2026-10-03).
    # Rotated files are closed, so their timestamp is trustworthy.
    $files = @(Get-ChildItem -LiteralPath $LogDir -Filter "server*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "server.log" -or $_.LastWriteTime -ge $Since.LocalDateTime })
    foreach ($f in $files) {
        # Ollama is still writing server.log: share ReadWrite or the open fails.
        try {
            $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        } catch { continue }
        $reader = New-Object System.IO.StreamReader($fs)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line -notmatch 'truncating input prompt') { continue }
                if ($line -notmatch '^time=(\S+)') { continue }
                $t = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse($Matches[1], [ref]$t)) { continue }
                if ($t -ge $Since -and $t -le $Until) { $hits += $line }
            }
        } finally {
            $reader.Dispose()
        }
    }
    return $hits
}

function Stop-OrphanOpencode {
    # Stop-Job does not take the native `opencode run` child with it, and a job
    # whose PowerShell died leaves it running too - it orphans and keeps driving
    # the model (and, on a hosted provider, spending the key). Kill every
    # opencode process pointed at this worktree, whole tree, so the run really
    # ends and the transcript file is released for archiving.
    param([string]$WtPath)
    $orphans = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'opencode%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($WtPath) })
    foreach ($o in $orphans) {
        Run-Native "taskkill" @("/PID", "$($o.ProcessId)", "/T", "/F") | Out-Null
    }
    if ($orphans.Count -gt 0) {
        Write-Host "    killed $($orphans.Count) orphaned opencode process(es) still running against $WtPath" -ForegroundColor Yellow
    }
}

function Invoke-OpencodeRun {
    param([string]$WtPath, [string]$ModelId, [string]$Prompt, [string]$PromptHash, [int]$TimeoutSec)

    $promptFile = Join-Path $env:TEMP ("task-prompt-{0}.md" -f ([guid]::NewGuid().ToString("N")))
    [System.IO.File]::WriteAllText($promptFile, $Prompt, (New-Object System.Text.UTF8Encoding($false)))
    $out = Join-Path $env:TEMP ("task-run-{0}.jsonl" -f ([guid]::NewGuid().ToString("N")))
    # Create the transcript up front: the job only appends per event, so a run
    # that emits nothing before the timeout (north-mini on 2026-09-26, stuck
    # re-prefilling) otherwise leaves no file and vanishes without a trace. An
    # empty _TIMEOUT_ transcript is the evidence that it never got a step out.
    [System.IO.File]::WriteAllText($out, "")

    $job = Start-Job -ScriptBlock {
        param($Dir, $ModelId, $PromptFile, $Out)
        # The canary pattern: run through the real opencode tool layer, JSONL
        # events on stdout, and let the (inherited) process env resolve the
        # provider baseURLs from the sourced profile.
        # Each event is appended to $Out as it arrives, not buffered until exit:
        # a run killed at the timeout used to leave no transcript at all (the
        # whole stream sat in a variable), so a timeout was a pure unknown.
        # The job's own PID first, so the caller can tell a dead job host from a
        # slow run (PowerShell 7 leaves such a job "Running" forever).
        [pscustomobject]@{ JobPid = $PID }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $msg = Get-Content -LiteralPath $PromptFile -Raw
            $enc = New-Object System.Text.UTF8Encoding($false)
            # opencode writes UTF-8; without this the job decodes its stdout
            # with the OEM codepage and every non-ASCII char in the transcript
            # is mojibake (an em dash became "ΓÇö" in the 2026-09-26 runs).
            [Console]::OutputEncoding = $enc
            & opencode run --dir $Dir --model $ModelId --format json --auto $msg 2>$null |
                ForEach-Object { [System.IO.File]::AppendAllText($Out, "$_`n", $enc) }
        } finally {
            $ErrorActionPreference = $prev
        }
        return $LASTEXITCODE
    } -ArgumentList $WtPath, $ModelId, $promptFile, $out

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Wait in slices of up to 5 s, checking between them that the job's
    # PowerShell process is still alive. Windows PowerShell 5.1 marks a job
    # whose process died as Failed and Wait-Job returns; PowerShell 7 leaves it
    # "Running" forever, so without this a dead host sat out the whole timeout
    # and was recorded as a TIMEOUT.
    $finished = $false
    $jobPid = $null
    $hostGone = $false
    while ($true) {
        $left = $TimeoutSec - $sw.Elapsed.TotalSeconds
        if ($left -le 0) { break }
        if (Wait-Job $job -Timeout ([int][math]::Max(1, [math]::Min(5, [math]::Ceiling($left))))) { $finished = $true; break }
        if (-not $jobPid) {
            try {
                $marker = @(Receive-Job $job -Keep -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.PSObject.Properties.Name -contains "JobPid" }) | Select-Object -First 1
                if ($marker) { $jobPid = [int]$marker.JobPid }
            } catch { }
        }
        if ($jobPid -and -not (Get-Process -Id $jobPid -ErrorAction SilentlyContinue)) { $hostGone = $true; break }
    }
    if (-not $finished -and -not $hostGone) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Stop-OrphanOpencode -WtPath $WtPath
        Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        # $out is NOT deleted here - whatever the model did before being killed
        # is evidence, not noise. The caller rescues it into tests/results/.
        return [pscustomobject]@{ ExitCode = -1; Writes = -1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "opencode run timed out after $TimeoutSec s (prompt sha $PromptHash)"; TranscriptPath = $out }
    }
    # The job's own PowerShell process can die under the run (2026-10-02, the
    # first run of a batch: "The background process closed or ended abnormally",
    # PSSessionStateBroken). Receive-Job then raises an error that the script's
    # "Stop" made terminating, and it took the whole batch down. A dead job is
    # infrastructure: report it as such (ExitCode -2; -1 means timeout to the
    # caller) and let the batch move on.
    $jobErrs = @()
    $jobBroken = $null
    if ($hostGone) {
        $jobBroken = "its PowerShell process (PID $jobPid) exited before the job finished"
        $jobResult = @()
        # Remove-Job below takes ~57 s on such a job in PowerShell 7 (a fixed
        # transport timeout, measured 2026-10-03; Stop-Job costs the same). Paid
        # once, only on a dead host, and far short of the run timeout.
    } else {
        try {
            $jobResult = @(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrs |
                Where-Object { -not ($_ -and $_.PSObject.Properties.Name -contains "JobPid") })
        } catch {
            $jobResult = @()
            $jobBroken = $_.Exception.Message
        }
    }
    if (-not $jobBroken) {
        $transport = @($jobErrs | Where-Object { $_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] })
        if ($transport.Count -gt 0) {
            $jobBroken = $transport[0].Exception.Message
        } elseif ($job.State -eq "Failed") {
            $jobBroken = if ($job.JobStateInfo.Reason) { $job.JobStateInfo.Reason.Message } else { "job state Failed" }
        }
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
    $sw.Stop()
    if ($jobBroken) {
        Stop-OrphanOpencode -WtPath $WtPath
        return [pscustomobject]@{ ExitCode = -2; Writes = -1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "the background job running opencode ended abnormally ($jobBroken) (prompt sha $PromptHash). Infrastructure failure, NOT model behaviour: not graded, no summary row."; TranscriptPath = $out }
    }

    $code = -1
    if ($jobResult.Count -ge 1) {
        $first = $jobResult[0]
        if ($first -is [psobject] -and $first.PSObject.Properties.Name -contains "value") {
            $code = [int]$first.value
        } else {
            $code = [int]$first
        }
    }

    $writes = 0
    if (Test-Path -LiteralPath $out) {
        foreach ($line in [System.IO.File]::ReadLines($out)) {
            if (-not $line.Trim()) { continue }
            try { $e = $line | ConvertFrom-Json } catch { continue }
            if ($e.type -ne "tool_use") { continue }
            if ($e.part.tool -in @("write", "edit", "Patch", "NotebookEdit")) { $writes++ }
        }
        # $out is NOT deleted here - the caller moves the raw transcript into
        # tests/results/ next to the graded JSON, so a run's "why" is auditable
        # later instead of stranded in %TEMP% (the round-2 mistake this repo's
        # own review-gate work already learned from - see r3-protocol.md).
    }
    return [pscustomobject]@{ ExitCode = $code; Writes = $writes; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); TranscriptPath = $out; Ending = (Get-TranscriptEnding -Path $out) }
}

# --- main loop ---------------------------------------------------------------

Write-Host "tasks manifest: $manifestPath" -ForegroundColor DarkGray
Write-Host ("model: {0} (label {1})" -f $Model, $ModelLabel) -ForegroundColor DarkGray

# Captured once per script run, not per task - neither changes mid-run.
# Tolerant of either being absent/erroring: a failed probe degrades to a
# labeled "unknown" rather than aborting the whole benchmark.
#
# The Ollama version is the one serving -Model, not the local binary's: the
# model id's provider picks the host (ollama-desktop/-server/-node3 -> that
# provider's *_BASE_URL) and its /api/version is asked. Stamping
# `ollama --version` put the desktop's 0.34.3 on every node3 run (node3 was
# 0.34.2) and would put it on hosted-provider runs that touch no Ollama at all.
# The "ollama version is X" shape is kept so existing result files compare.
#
# numCtx is the context window baked into the served model (/api/show
# parameters). It is not part of the prompt hash, so without this stamp a
# 32k run and a 64k run of the same task are indistinguishable afterwards
# (the 64k context trial, docs/roadmap.md -> "Context budget").
$providerId = ($Model -split '/', 2)[0]
$numCtx = $null
$ollamaRoot = $null
$ollamaBaseVar = switch ($providerId) {
    "ollama-desktop" { "OLLAMA_DESKTOP_BASE_URL" }
    "ollama-server"  { "OLLAMA_SERVER_BASE_URL" }
    "ollama-node3"   { "OLLAMA_NODE3_BASE_URL" }
    default          { $null }
}
if (-not $ollamaBaseVar) {
    $ollamaVersion = "n/a ($providerId is not an Ollama provider)"
} else {
    $ollamaBase = [Environment]::GetEnvironmentVariable($ollamaBaseVar)
    if (-not $ollamaBase) {
        $ollamaVersion = "unknown ($ollamaBaseVar is unset)"
    } else {
        $ollamaRoot = $ollamaBase.TrimEnd('/') -replace '/v1$', ''
        try {
            $ollamaVersion = "ollama version is $((Invoke-RestMethod -Uri "$ollamaRoot/api/version" -TimeoutSec 10).version)"
        } catch {
            $ollamaVersion = "unknown ($ollamaRoot/api/version unreachable)"
        }
        try {
            $showBody = @{ model = ($Model -split '/', 2)[1] } | ConvertTo-Json
            $show = Invoke-RestMethod -Uri "$ollamaRoot/api/show" -Method Post -ContentType "application/json" -Body $showBody -TimeoutSec 10
            $ctxLine = @($show.parameters -split "`n" | Where-Object { $_ -match '^\s*num_ctx\s+(\d+)' })
            $numCtx = if ($ctxLine.Count -gt 0 -and $ctxLine[0] -match '(\d+)\s*$') { [int]$Matches[1] } else { "unset (server default)" }
        } catch {
            $numCtx = "unknown (/api/show failed)"
        }
    }
}
# What served the model, engine-neutral: Ollama is expected to be replaced
# (owner, 2026-10-03), and a run under a different engine is a new era, so the
# engine is recorded by name, not only through the Ollama-shaped
# `ollamaVersion` (kept, so older result files still compare). An engine this
# script does not know yet records "unknown" rather than borrowing Ollama's.
$servingEngine = [ordered]@{
    name     = $(if ($ollamaBaseVar) { "ollama" } else { "unknown" })
    version  = $(if ("$ollamaVersion" -match '^ollama version is (\S+)') { $Matches[1] } else { $null })
    endpoint = $ollamaRoot
    provider = $providerId
}

# Prompt-truncation check (Get-OllamaPromptTruncation): Ollama-specific, and
# only a local Ollama's server.log is readable from here. Every graded run
# records which it was, so another engine records "not checked", not a clean.
$truncLogDir = $null
if ($OllamaLogDir) {
    $truncLogDir = $OllamaLogDir
} elseif ($ollamaRoot -and @("localhost", "127.0.0.1", "::1") -contains ([uri]$ollamaRoot).Host) {
    $truncLogDir = Join-Path $env:LOCALAPPDATA "Ollama"
}
$truncCheck = if ($truncLogDir -and (Test-Path -LiteralPath $truncLogDir)) {
    "checked Ollama server.log in $truncLogDir"
} elseif ($truncLogDir) {
    $truncLogDir = $null; "not checked (no Ollama log directory at $truncLogDir)"
} elseif ($ollamaRoot) {
    "not checked ($ollamaRoot is not local; its server.log is on that host)"
} else {
    "not checked (no truncation detector for engine '$($servingEngine.name)', provider $providerId)"
}
$ovOpencode = Run-Native "opencode" @("--version")
$opencodeVersion = if ($ovOpencode.ExitCode -eq 0 -and $ovOpencode.Output) { ($ovOpencode.Output -join ' ').Trim() } else { "unknown (opencode --version exit $($ovOpencode.ExitCode))" }
# limit.output of the seat, from the resolved opencode config: what the writes
# gate compares the last step's output tokens against to call an output-cap hit.
$outputLimit = Get-ModelOutputLimit -ModelId $Model
Write-Host ("ollama: {0} | opencode: {1} | num_ctx: {2} | limit.output: {3}" -f $ollamaVersion, $opencodeVersion, $(if ($null -ne $numCtx) { $numCtx } else { "n/a" }), $(if ($null -ne $outputLimit) { $outputLimit } else { "unknown" })) -ForegroundColor DarkGray

$promptHashes = @{}
$summaryRows = [System.Collections.Generic.List[string]]::new()
$overallPass = $true

foreach ($tk in $tasksToRun) {
    Write-Host ("=== {0} - {1} ===" -f $tk.id, $tk.title) -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $tk.repo)) {
        Write-Result $tk.id "repo" "FAIL" "checkout not found at $($tk.repo) - clone it first"
        $overallPass = $false
        continue
    }

    $wtPath = Join-Path $wtRoot $tk.id
    $wt = Ensure-Worktree $tk $wtPath
    if (-not $wt) { $overallPass = $false; continue }

    # Baseline: the untouched branch-tip suite must pass. The bug is meant to
    # be UNEXERCISED at baseline (that is the PR #82 trap), so green here is
    # the expected state - and a red baseline means the base is broken and the
    # run tells us nothing.
    $base = Invoke-Test $tk $wt.Wt
    $baselineOk = $base.ExitCode -eq 0
    $baselineLine = ($base.Output | Select-String -Pattern "Tests\s+.*\((\d+)\)|Tests\s+(\d+)\s+(passed|failed)" | Select-Object -Last 1)
    if ($baselineOk) {
        Write-Result $tk.id "baseline" "PASS" "suite green on untouched branch tip ($($baselineLine.Line.Trim()))"
    } else {
        Write-Result $tk.id "baseline" "FAIL" "base is already broken - this run is not meaningful: $(($base.Output | Select-Object -Last 4) -join ' ')"
        $overallPass = $false
        continue
    }

    $prompt = $tk.prompt
    if ($EditFormat -eq "write") {
        $prompt += "`n`nMake all your source changes with whole-file writes to the target files (the write tool), not substring search-replace edits."
    } elseif ($EditFormat -eq "edit") {
        $prompt += "`n`nMake all your source changes with targeted substring search-replace edits (the edit tool), not whole-file rewrites."
    }
    if (-not $promptHashes.ContainsKey($tk.id)) {
        # SHA256.HashData / Convert.ToHexString are .NET 5+ only - not present under
        # Windows PowerShell 5.1 (.NET Framework). Create()+ComputeHash()+BitConverter
        # works on both PS 5.1 and PS 7.
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($prompt))
        } finally {
            $sha256.Dispose()
        }
        $promptHashes[$tk.id] = ([BitConverter]::ToString($hashBytes) -replace '-', '').Substring(0, 12)
    }
    Write-Host ("  prompt: {0} chars (sha256 {1})" -f $prompt.Length, $promptHashes[$tk.id]) -ForegroundColor DarkGray

    if ($DryRun) {
        # The owner's acceptance tests must FAIL on the untouched base - the
        # failing-first property the order was docketed on, re-checked here
        # instead of by hand.
        if ($tk.acceptance) {
            $acc = Invoke-Acceptance $tk $wt.Wt
            switch ($acc.Status) {
                "FAIL"  { Write-Result $tk.id "acceptance (fails on base)" "PASS" "owner tests @ $($acc.Ref) $($acc.Commit.Substring(0,7)) fail on the untouched source: $($acc.Detail)" }
                "PASS"  { Write-Result $tk.id "acceptance (fails on base)" "WARN" "owner tests @ $($acc.Ref) PASS on the untouched source - they do not exercise the defect: $($acc.Detail)" }
                default { Write-Result $tk.id "acceptance (fails on base)" "WARN" $acc.Detail }
            }
        }
        Write-Result $tk.id "dry-run" "PASS" "worktree + install + baseline validated; model run skipped (add -DryRun removed)"
        continue
    }

    # The model's own shell gets the pinned environment too: a test it sees pass
    # has to be one the gates can run (opencode inherits this process's env).
    $savedEnv = Set-TaskTestEnv $tk
    $runStart = [DateTimeOffset]::Now
    try {
        $run = Invoke-OpencodeRun -WtPath $wt.Wt -ModelId $Model -Prompt $prompt -PromptHash $promptHashes[$tk.id] -TimeoutSec $RunTimeout
    } finally {
        Restore-TaskTestEnv $savedEnv
    }
    # A run whose prompt Ollama truncated never showed the model the whole
    # system prompt, tool list and task, so whatever it did measures the task's
    # fit, not the model. Same treatment as any infrastructure failure: kept
    # transcript (_TRUNCATED_), no summary row. Exit -3 is this harness's code
    # for it (-1 timeout, -2 dead job host).
    if ($truncLogDir -and $run.ExitCode -eq 0) {
        $truncation = @(Get-OllamaPromptTruncation -LogDir $truncLogDir -Since $runStart -Until ([DateTimeOffset]::Now))
        if ($truncation.Count -gt 0) {
            $truncWhat = ($truncation[0] -replace '^.*msg="truncating input prompt"\s*', '').Trim()
            $run.ExitCode = -3
            $run | Add-Member -NotePropertyName Detail -Force -NotePropertyValue ("Ollama truncated the prompt {0} time(s) during the run ({1}): the model did not see the whole system prompt, tool list and task. A task-fit failure, NOT model behaviour: not graded, no summary row (prompt sha {2})." -f $truncation.Count, $truncWhat, $promptHashes[$tk.id])
        }
    }
    # A run that never reached the model is not a result. opencode exits 0 even
    # when the model refuses to write (real liar mode), so ANY non-zero exit is
    # infrastructure: unreachable provider, bad model id, crash. Grading those as
    # behaviour is exactly how six "Cannot connect to API" transcripts became a
    # "6/6 liar mode" capability finding - see docs/roadmap.md. Bail out BEFORE
    # the writes gate and append no summary row, the same way a timeout and a
    # failed baseline already do.
    if ($run.ExitCode -ne 0) {
        $isTimeout = ($run.ExitCode -eq -1)
        $kind      = if ($isTimeout) { "TIMEOUT" } elseif ($run.ExitCode -eq -3) { "TRUNCATED" } else { "INFRA" }
        if ($run.Detail) {
            $runDetail = $run.Detail
        } else {
            $firstErr  = Get-FirstTranscriptError -Path $run.TranscriptPath
            $errSuffix = if ($firstErr) { " - $firstErr" } else { "" }
            $runDetail = "opencode exited $($run.ExitCode) without a gradable run$errSuffix (prompt sha $($promptHashes[$tk.id])). Infrastructure failure, NOT model behaviour: not graded, no summary row."
        }
        Write-Result $tk.id "opencode run" "FAIL" $runDetail
        $overallPass = $false
        if ($run.TranscriptPath -and (Test-Path -LiteralPath $run.TranscriptPath)) {
            $failStamp      = Get-Date -Format "yyyyMMdd-HHmmss"
            $failTranscript = Join-Path $resultsDir ("tasks-{0}-{1}_{2}_{3}.jsonl" -f $tk.id, ($ModelLabel -replace '[^a-zA-Z0-9._-]', '_'), $kind, $failStamp)
            if (Move-Transcript -Source $run.TranscriptPath -Destination $failTranscript) {
                Write-Host "    partial transcript kept: $failTranscript" -ForegroundColor DarkGray
            } else {
                Write-Host "    WARN: transcript could not be archived - still at $($run.TranscriptPath); move it manually to preserve evidence" -ForegroundColor Yellow
            }
        }
        if (-not $NoReset) { Run-Native "git" @("-C", $wt.Wt, "reset", "--hard", $wt.Head) | Out-Null; Run-Native "git" @("-C", $wt.Wt, "clean", "-fd") | Out-Null }
        continue
    }

    Write-Result $tk.id "opencode run" "PASS" ("exit {0}, {1} write/edit tool calls" -f $run.ExitCode, $run.Writes)
    $capHit = Test-OutputCapHit -Ending $run.Ending -Limit $outputLimit
    if ($run.Writes -eq 0) {
        if ($capHit) {
            Write-Result $tk.id "writes gate" "FAIL" ("0 write/edit calls - NOT liar mode: the last step used all {0} output tokens (limit.output) without a text or tool call, so the seat ran out of room to act. Recorded as a FAIL, and as a cap hit rather than liar mode." -f $run.Ending.OutputTokens)
        } elseif ($run.Ending.FinishReason -eq "length" -and -not $run.Ending.LastStepHadContent) {
            # Cut off, but not confirmed as the cap (limit.output unreadable, or the
            # stop came below it - a full context, say). Still not a described change.
            Write-Result $tk.id "writes gate" "FAIL" ("0 write/edit calls - the last step was cut off by a length stop ({0} output tokens, limit.output {1}) with no text or tool call. Truncated, not a described change, and not confirmed as an output-cap hit either. Recorded as a FAIL." -f $run.Ending.OutputTokens, $(if ($null -ne $outputLimit) { $outputLimit } else { "unknown" }))
        } else {
            Write-Result $tk.id "writes gate" "FAIL" "0 write/edit calls - the model described the change instead of making it (the old liar mode). This run does not count."
        }
        $overallPass = $false
    } else {
        $writeNote = if ($run.Writes -gt 5) { " (repeated-call look: $($run.Writes) writes for a 2-file task - see docs/troubleshooting.md)" } else { "" }
        if ($capHit) { $writeNote += " (the last step then hit the output cap at $($run.Ending.OutputTokens) tokens)" }
        Write-Result $tk.id "writes gate" "PASS" "$($run.Writes) write/edit calls$writeNote"
    }

    # --- grade 1: diff scope -------------------------------------------------
    $changed = Get-TreeChanges $wt.Wt
    $allowed = @($tk.allowFiles)
    $bad = @($changed | Where-Object { $_ -and ($allowed -notcontains $_) })
    if ($changed.Count -eq 0) {
        Write-Result $tk.id "scope" "FAIL" "no changes at all - the model did not touch the worktree"
        $overallPass = $false
    } elseif ($bad.Count -gt 0) {
        Write-Result $tk.id "scope" "FAIL" "changed files outside allowFiles: $($bad -join ', ') (allowed: $($allowed -join ', '))"
        $overallPass = $false
    } elseif (@($changed | Where-Object { $_ -and ($tk.srcRevertFiles -contains $_) }).Count -eq 0) {
        Write-Result $tk.id "scope" "FAIL" "no change to any source file ($($tk.srcRevertFiles -join ', ')) - a test-only change passes a buggy source"
        $overallPass = $false
    } else {
        Write-Result $tk.id "scope" "PASS" "diff limited to: $($changed -join ', ')"
    }

    # --- grade 2: suite green on the model's change ---------------------------
    $suite = Invoke-Test $tk $wt.Wt
    if ($suite.ExitCode -eq 0) {
        $suiteLine = ($suite.Output | Select-String -Pattern "Tests\s+.*\((\d+)\)" | Select-Object -Last 1)
        Write-Result $tk.id "suite" "PASS" "green after change ($($suiteLine.Line.Trim()))"
    } else {
        $failed = Get-FailedTestNames -Output $suite.Output
        Write-Result $tk.id "suite" "FAIL" "suite fails after change: $($failed -join '; ')"
        $overallPass = $false
    }

    # --- grade 3: fails-on-old-code --------------------------------------------
    # Revert ONLY the source files (the model's tests stay), rerun. The
    # fix-and-reverify DoD: a test that passes on the broken code is a
    # false-positive test and FAILs here. The model's source is put back
    # byte for byte afterwards (Invoke-WithSourceReverted).
    # Only measurable on a green suite. A suite that is already red with the
    # model's source in place fails with it reverted too, whatever the test
    # checks: asohav-07 (2026-10-03) left a test file that does not parse, and
    # the revert "failed" it, recording failsOnOld=PASS for a test that never
    # ran (29 earlier rows have suite=FAIL failsOnOld=PASS the same way). SKIP,
    # like typecheck's "did not run"; the row is already a FAIL on the suite.
    $failsOnOldOk = $false
    $failsOnOldSkipped = $false
    $srcChanged = @($changed | Where-Object { $_ -and ($tk.srcRevertFiles -contains $_) })
    if ($suite.ExitCode -ne 0) {
        Write-Result $tk.id "fails-on-old" "SKIP" "not measured - the suite is already red with the model's change, so it would fail with the source reverted whatever the test checks"
        $failsOnOldSkipped = $true
    } elseif ($srcChanged.Count -eq 0) {
        Write-Result $tk.id "fails-on-old" "FAIL" "no source changes to revert - the pairing test would pass on broken code (test never enters its claimed branch)"
        $overallPass = $false
    } else {
        $failsOnOldOk = $false
        $rv = Invoke-WithSourceReverted $tk $wt.Wt $wt.Head
        if ($rv.Error) {
            Write-Result $tk.id "fails-on-old" "FAIL" "$($rv.Error) - cannot grade"
            $overallPass = $false
        } else {
            $reverted = $rv.Result
            if ($reverted.ExitCode -ne 0) {
                $failed = Get-FailedTestNames -Output $reverted.Output
                Write-Result $tk.id "fails-on-old" "PASS" "suite fails with source reverted, test kept: $($failed -join '; ')"
                $failsOnOldOk = $true
            } else {
                $testChanged = @($changed | Where-Object { $_ -match '\.test\.' }).Count -gt 0
                if (-not $testChanged) {
                    Write-Result $tk.id "fails-on-old" "FAIL" "the test file was never modified - the pre-existing tests are green on the buggy source (the claimed branch is never exercised)"
                } else {
                    Write-Result $tk.id "fails-on-old" "FAIL" "suite STILL passes with the eligibility fix reverted - the added test is green on broken code (the PR #82 trap at full size)"
                }
                $overallPass = $false
            }
        }
        if (-not $rv.Restored) {
            Write-Result $tk.id "fails-on-old" "WARN" "the model's source files were NOT restored byte for byte after the revert - inspect $($wt.Wt) before trusting the later steps"
        }
    }

    # --- grade 4 (informational): scoped typecheck ----------------------------
    # Tri-state, because "did not run" and "compiled cleanly" are not the same
    # claim. This was previously a boolean initialised to $true BEFORE the guard
    # below, so every task without a `typecheck` block recorded typecheck=PASS
    # having compiled nothing - 6 of the 8 manifest tasks, among them all three
    # kane-02 rows that never reached the model at all. Only kane-01 and lfc-01
    # define the block, so the other six now read SKIP.
    $typecheckStatus = "SKIP"
    if (-not $tk.typecheck) {
        Write-Result $tk.id "typecheck (scoped)" "SKIP" "task defines no typecheck block - nothing compiled, nothing claimed"
    } else {
        $tcDir = Join-Path $wt.Wt $tk.testDir
        $tcFile = Join-Path $tcDir "_bench-typecheck.json"
        $tcCfg = [ordered]@{
            extends = "./$($tk.typecheck.baseConfig)"
            include = @($tk.typecheck.include)
            compilerOptions = @{}
        }
        if ($tk.typecheck.compilerOptions) {
            $tk.typecheck.compilerOptions.PSObject.Properties | ForEach-Object { $tcCfg.compilerOptions[$_.Name] = $_.Value }
        }
        Set-Content -LiteralPath $tcFile -Value ($tcCfg | ConvertTo-Json -Depth 5) -Encoding utf8
        try {
            $tc = Run-Native "pnpm" @("exec", "tsc", "--noEmit", "-p", "_bench-typecheck.json") $tcDir
            if ($tc.ExitCode -eq 0) {
                $typecheckStatus = "PASS"
                Write-Result $tk.id "typecheck (scoped)" "PASS" "touched module graph compiles"
            } else {
                $typecheckStatus = "WARN"
                Write-Result $tk.id "typecheck (scoped)" "WARN" ("tsc errors: {0}" -f (($tc.Output | Select-Object -First 4) -join ' '))
            }
        } finally {
            Remove-Item -LiteralPath $tcFile -Force -ErrorAction SilentlyContinue
        }
    }

    # --- informational: owner acceptance tests ---------------------------------
    # Never a gate (see Invoke-Acceptance). Recorded in the per-run JSON only;
    # the summary TSV keeps its 12 columns.
    $acceptanceRecord = [pscustomobject]@{ status = "SKIP"; ref = $null; commit = $null; detail = "task defines no acceptance block" }
    if (-not $tk.acceptance) {
        Write-Result $tk.id "acceptance (informational)" "SKIP" "task defines no acceptance block"
    } else {
        $acc = Invoke-Acceptance $tk $wt.Wt
        $acceptanceRecord = [pscustomobject]@{ status = $acc.Status; ref = $acc.Ref; commit = $acc.Commit; detail = $acc.Detail }
        $shortSha = if ($acc.Commit) { $acc.Commit.Substring(0, 7) } else { "?" }
        if ($acc.Status -eq "PASS") {
            Write-Result $tk.id "acceptance (informational)" "PASS" "owner tests @ $($acc.Ref) $shortSha pass on the model's source: $($acc.Detail)"
        } else {
            Write-Result $tk.id "acceptance (informational)" "WARN" "$($acc.Status): owner tests @ $($acc.Ref) $shortSha - $($acc.Detail)"
        }
    }

    # --- record ----------------------------------------------------------------
    $scopeOk = ($changed.Count -gt 0 -and $bad.Count -eq 0 -and @($changed | Where-Object { $_ -and ($tk.srcRevertFiles -contains $_) }).Count -gt 0)
    $suiteOk = $suite.ExitCode -eq 0
    $gateSummary = [pscustomobject]@{
        scope = $(if ($scopeOk) { "PASS" } else { "FAIL" })
        suite = $(if ($suiteOk) { "PASS" } else { "FAIL" })
        failsOnOld = $(if ($failsOnOldSkipped) { "SKIP" } elseif ($failsOnOldOk) { "PASS" } else { "FAIL" })
    }
    # One stamp shared by the JSON result and its .jsonl transcript, so the two
    # files that describe the same run are trivially pairable by filename.
    $runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $runBaseName = "tasks-{0}-{1}_{2}" -f $tk.id, ($ModelLabel -replace '[^a-zA-Z0-9._-]', '_'), $runStamp
    $runFile = Join-Path $resultsDir ($runBaseName + ".json")
    $transcriptDest = Join-Path $resultsDir ($runBaseName + ".jsonl")
    if ($run.TranscriptPath -and (Test-Path -LiteralPath $run.TranscriptPath)) {
        if (Move-Transcript -Source $run.TranscriptPath -Destination $transcriptDest) {
            $transcriptFileField = Split-Path -Leaf $transcriptDest
        } else {
            $transcriptFileField = $null
            Write-Host "    WARN: transcript could not be archived - still at $($run.TranscriptPath); move it manually to preserve evidence" -ForegroundColor Yellow
        }
    } else {
        $transcriptFileField = $null
        Write-Host "    (no transcript captured for this run)" -ForegroundColor DarkGray
    }

    $result = [pscustomobject]@{
        timestamp       = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        taskId          = $tk.id
        taskTitle       = $tk.title
        model           = $Model
        modelLabel      = $ModelLabel
        baseCommit      = $wt.Head
        promptSha256    = $promptHashes[$tk.id]
        opencodeExit    = $run.ExitCode
        writes          = $run.Writes
        finishReason    = $run.Ending.FinishReason
        lastStepOutput  = $run.Ending.OutputTokens
        outputLimit     = $outputLimit
        outputCapHit    = $capHit
        gates           = $gateSummary
        typecheck       = $typecheckStatus
        acceptance      = $acceptanceRecord
        elapsedSec      = $run.ElapsedSec
        ollamaVersion   = $ollamaVersion
        servingEngine   = $servingEngine
        opencodeVersion = $opencodeVersion
        numCtx          = $numCtx
        promptTruncation = $(if ($truncLogDir) { "$truncCheck - none during the run" } else { $truncCheck })
        testEnv        = $(if ($tk.PSObject.Properties["testEnv"]) { $tk.testEnv } else { $null })
        samplingControl = "opencode run has no known per-invocation seed/temperature flag, and opencode.jsonc's model schema only supports limit/modalities/tool_call (AGENTS.md) - not pinned, not independently reproducible across runs. See the header comment and docs/review-gate/r3-runner.ps1 (which pins these by calling the Ollama API directly, outside the real opencode tool loop)."
        transcriptFile  = $transcriptFileField
    }
    Set-Content -LiteralPath $runFile -Value ($result | ConvertTo-Json -Depth 6) -Encoding utf8

    $row = @($result.timestamp, $tk.id, $Model, $ModelLabel, $wt.Head, $run.ExitCode, $run.Writes,
             $gateSummary.scope, $gateSummary.suite, $gateSummary.failsOnOld, $result.typecheck, $result.elapsedSec) -join "`t"
    $summaryRows.Add($row)

    if ($Cleanup -and -not $NoReset) {
        Run-Native "git" @("-C", $wt.Wt, "reset", "--hard", $wt.Head) | Out-Null
        Run-Native "git" @("-C", $wt.Wt, "clean", "-fd") | Out-Null
        Run-Native "git" @("-C", $tk.repo, "worktree", "remove", "--force", $wtPath) | Out-Null
        Run-Native "git" @("-C", $tk.repo, "worktree", "prune") | Out-Null
        Write-Host "    worktree removed (cleanup)" -ForegroundColor DarkGray
    }
}

$summaryHeader = @("timestamp", "taskId", "model", "modelLabel", "baseCommit", "opencodeExit", "writes", "scope", "suite", "failsOnOld", "typecheck", "elapsedSec") -join "`t"
if ($summaryRows.Count -gt 0) {
    $summaryLines = @()
    if (-not (Test-Path -LiteralPath $summaryTsv)) { $summaryLines += $summaryHeader }
    $summaryLines += $summaryRows
    Add-Content -LiteralPath $summaryTsv -Value $summaryLines -Encoding utf8
}

Write-Host ""
Write-Host ("Results: {0} PASS, {1} FAIL, {2} WARN, {3} SKIP" -f $statusCounts.PASS, $statusCounts.FAIL, $statusCounts.WARN, $statusCounts.SKIP) -ForegroundColor Cyan
# Only claim an append that happened - timeouts, infra failures, dry runs and
# red baselines produce no graded row, and this line used to say otherwise.
if ($summaryRows.Count -gt 0) {
    Write-Host "Summary: $($summaryRows.Count) row(s) appended to $summaryTsv" -ForegroundColor DarkGray
} else {
    Write-Host "Summary: no graded runs - nothing appended to $summaryTsv" -ForegroundColor DarkGray
}

if ($overallPass) { exit 0 }
exit 1

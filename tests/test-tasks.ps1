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
#   failsOnOld - revert ONLY the source files (git stash push - keeping the
#                model's test), the suite must now FAIL. This is the PR #82
#                "green test that never enters its claimed branch" trap made
#                mechanical: a test that passes on broken code = FAIL here.
#   typecheck  - scoped to the touched module graph (informational, never FAIL:
#                the full project needs every workspace package built first).
#                PASS/WARN only when the task defines a `typecheck` block;
#                SKIP when it does not, because a task that compiled nothing
#                must not read as one that compiled cleanly.
#
# What is NOT graded, and why that distinction is load-bearing: a run only
# reaches those gates if `opencode run` exited 0. opencode exits 0 even when
# the model answers in prose and writes nothing, so `writes = 0` on an exit-0
# run means liar mode and nothing else. ANY non-zero exit is infrastructure -
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

if (@($Task).Count -gt 0) {
    $wanted = @($Task | ForEach-Object { $_.Trim() })
    $tasksToRun = @($allTasks | Where-Object { $wanted -contains $_.id })
} else {
    $tasksToRun = @($allTasks)
}
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
    $branch = $Task.branch
    # Install state lives OUTSIDE the worktree: an in-tree marker file shows up
    # in `git status --porcelain`, gets deleted by `git clean -fd` (forcing a
    # reinstall every other run), and is visible to the model while it works.
    $marker = Join-Path $wtRoot ("." + $Task.id + ".installed")
    $head = Get-HeadCommit $repo $branch
    if (-not $head) {
        Write-Result $Task.id "worktree" "FAIL" "cannot resolve refs/heads/$branch in $repo"
        return $null
    }
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
        $r = Run-Native "git" @("-C", $repo, "worktree", "add", "--detach", $WtPath, "refs/heads/$branch")
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

function Invoke-Test {
    param($Task, [string]$WtPath)
    $testDir = Join-Path $WtPath $Task.testDir
    return Run-Native $Task.testCmd[0] @($Task.testCmd[1..($Task.testCmd.Count - 1)]) $testDir
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

function Invoke-OpencodeRun {
    param([string]$WtPath, [string]$ModelId, [string]$Prompt, [string]$PromptHash, [int]$TimeoutSec)

    $promptFile = Join-Path $env:TEMP ("task-prompt-{0}.md" -f ([guid]::NewGuid().ToString("N")))
    [System.IO.File]::WriteAllText($promptFile, $Prompt, (New-Object System.Text.UTF8Encoding($false)))
    $out = Join-Path $env:TEMP ("task-run-{0}.jsonl" -f ([guid]::NewGuid().ToString("N")))

    $job = Start-Job -ScriptBlock {
        param($Dir, $ModelId, $PromptFile, $Out)
        # The canary pattern: run through the real opencode tool layer, JSONL
        # events on stdout, and let the (inherited) process env resolve the
        # provider baseURLs from the sourced profile.
        # Each event is appended to $Out as it arrives, not buffered until exit:
        # a run killed at the timeout used to leave no transcript at all (the
        # whole stream sat in a variable), so a timeout was a pure unknown.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $msg = Get-Content -LiteralPath $PromptFile -Raw
            $enc = New-Object System.Text.UTF8Encoding($false)
            & opencode run --dir $Dir --model $ModelId --format json --auto $msg 2>$null |
                ForEach-Object { [System.IO.File]::AppendAllText($Out, "$_`n", $enc) }
        } finally {
            $ErrorActionPreference = $prev
        }
        return $LASTEXITCODE
    } -ArgumentList $WtPath, $ModelId, $promptFile, $out

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        # Stop-Job does not take the native `opencode run` child with it - it
        # orphans and keeps driving the model (and, on a hosted provider,
        # spending the key). Kill every opencode process pointed at this
        # worktree, whole tree, so the run really ends and the transcript
        # file is released for archiving.
        $orphans = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'opencode%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($WtPath) })
        foreach ($o in $orphans) {
            Run-Native "taskkill" @("/PID", "$($o.ProcessId)", "/T", "/F") | Out-Null
        }
        if ($orphans.Count -gt 0) {
            Write-Host "    killed $($orphans.Count) orphaned opencode process(es) still running against $WtPath" -ForegroundColor Yellow
        }
        Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        # $out is NOT deleted here - whatever the model did before being killed
        # is evidence, not noise. The caller rescues it into tests/results/.
        return [pscustomobject]@{ ExitCode = -1; Writes = -1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "opencode run timed out after $TimeoutSec s (prompt sha $PromptHash)"; TranscriptPath = $out }
    }
    $jobResult = @(Receive-Job $job)
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
    $sw.Stop()

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
    return [pscustomobject]@{ ExitCode = $code; Writes = $writes; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); TranscriptPath = $out }
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
$providerId = ($Model -split '/', 2)[0]
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
    }
}
$ovOpencode = Run-Native "opencode" @("--version")
$opencodeVersion = if ($ovOpencode.ExitCode -eq 0 -and $ovOpencode.Output) { ($ovOpencode.Output -join ' ').Trim() } else { "unknown (opencode --version exit $($ovOpencode.ExitCode))" }
Write-Host ("ollama: {0} | opencode: {1}" -f $ollamaVersion, $opencodeVersion) -ForegroundColor DarkGray

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
        Write-Result $tk.id "dry-run" "PASS" "worktree + install + baseline validated; model run skipped (add -DryRun removed)"
        continue
    }

    $run = Invoke-OpencodeRun -WtPath $wt.Wt -ModelId $Model -Prompt $prompt -PromptHash $promptHashes[$tk.id] -TimeoutSec $RunTimeout
    # A run that never reached the model is not a result. opencode exits 0 even
    # when the model refuses to write (real liar mode), so ANY non-zero exit is
    # infrastructure: unreachable provider, bad model id, crash. Grading those as
    # behaviour is exactly how six "Cannot connect to API" transcripts became a
    # "6/6 liar mode" capability finding - see docs/roadmap.md. Bail out BEFORE
    # the writes gate and append no summary row, the same way a timeout and a
    # failed baseline already do.
    if ($run.ExitCode -ne 0) {
        $isTimeout = ($run.ExitCode -eq -1)
        $kind      = if ($isTimeout) { "TIMEOUT" } else { "INFRA" }
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
    if ($run.Writes -eq 0) {
        Write-Result $tk.id "writes gate" "FAIL" "0 write/edit calls - the model described the change instead of making it (the old liar mode). This run does not count."
        $overallPass = $false
    } else {
        $writeNote = if ($run.Writes -gt 5) { " (repeated-call look: $($run.Writes) writes for a 2-file task - see docs/troubleshooting.md)" } else { "" }
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
    # Revert ONLY the source files (stash keeps the model's tests), rerun. The
    # fix-and-reverify DoD: a test that passes on the broken code is a
    # false-positive test and FAILs here. Restore unconditionally afterwards.
    $failsOnOldOk = $false
    $srcChanged = @($changed | Where-Object { $_ -and ($tk.srcRevertFiles -contains $_) })
    if ($srcChanged.Count -eq 0) {
        Write-Result $tk.id "fails-on-old" "FAIL" "no source changes to revert - the pairing test would pass on broken code (test never enters its claimed branch)"
        $overallPass = $false
    } else {
        $failsOnOldOk = $false
        $r = Run-Native "git" @("-C", $wt.Wt, "stash", "push", "--", @($tk.srcRevertFiles))
        if ($r.ExitCode -ne 0) {
            Write-Result $tk.id "fails-on-old" "FAIL" "git stash push failed - cannot grade"
            $overallPass = $false
        } else {
            $reverted = Invoke-Test $tk $wt.Wt
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
            $p = Run-Native "git" @("-C", $wt.Wt, "stash", "pop")
            if ($p.ExitCode -ne 0) {
                Write-Result $tk.id "fails-on-old" "WARN" "stash pop failed - worktree may hold stashed changes; inspecting recommended"
            }
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

    # --- record ----------------------------------------------------------------
    $scopeOk = ($changed.Count -gt 0 -and $bad.Count -eq 0 -and @($changed | Where-Object { $_ -and ($tk.srcRevertFiles -contains $_) }).Count -gt 0)
    $suiteOk = $suite.ExitCode -eq 0
    $gateSummary = [pscustomobject]@{
        scope = $(if ($scopeOk) { "PASS" } else { "FAIL" })
        suite = $(if ($suiteOk) { "PASS" } else { "FAIL" })
        failsOnOld = $(if ($failsOnOldOk) { "PASS" } else { "FAIL" })
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
        gates           = $gateSummary
        typecheck       = $typecheckStatus
        elapsedSec      = $run.ElapsedSec
        ollamaVersion   = $ollamaVersion
        opencodeVersion = $opencodeVersion
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

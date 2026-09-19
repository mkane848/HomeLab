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
#   typecheck  - scoped to the touched module graph (informational/WARN, the
#                full project needs every workspace package built first).
#
# Which model/setting combos to compare is the whole point - run the same task
# on each seat and the pass/fail table is the tuning signal. No config or
# seat change until ~3 graded runs across >=2 tasks (the agreed gate).
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
#
# Exit code: 0 if no FAIL grade across all runs, 1 otherwise.
# Results: tests/results/tasks-<taskId>-<label>_<timestamp>.json per run, plus
# one row appended to tests/results/tasks-summary.tsv.

param(
    [string[]]$Task = @(),
    [string]$Model = "",
    [string]$ModelLabel = "",
    [int]$RunTimeout = 900,
    [int]$CommandTimeout = 300,
    [switch]$NoReset,
    [switch]$SkipInstall,
    [switch]$DryRun,
    [switch]$Cleanup
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
        Write-Host "    pnpm install $($Task.installFlags -join ' ') (first run on this worktree)..." -ForegroundColor DarkGray
        $installArgs = @("install") + @($Task.installFlags)
        $r = Run-Native "pnpm" $installArgs $WtPath
        if ($r.ExitCode -ne 0) {
            Write-Result $Task.id "install" "FAIL" "pnpm install failed: $($r.Output | Select-Object -Last 3) - see AGENTS.md re native deps; the task may need --ignore-scripts (already default for kane-01)"
            return $null
        }
        foreach ($step in @($Task.setup)) {
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
    $names = @()
    foreach ($line in $Output) {
        foreach ($m in [regex]::Matches($line, '(?m)\s*FAIL\s+.*>\s*(.+?)\s*$')) {
            $names += $m.Groups[1].Value.Trim()
        }
        foreach ($m in [regex]::Matches($line, 'Tests\s+(\d+) failed')) {
            $names += "($($m.Groups[1].Value) failed)"
        }
    }
    return ($names | Select-Object -Unique)
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
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $msg = Get-Content -LiteralPath $PromptFile -Raw
            $events = & opencode run --dir $Dir --model $ModelId --format json --auto $msg 2>$null
            $events | Out-File -LiteralPath $Out -Encoding utf8
        } finally {
            $ErrorActionPreference = $prev
        }
        return $LASTEXITCODE
    } -ArgumentList $WtPath, $ModelId, $promptFile, $out

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $promptFile, $out -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ ExitCode = -1; Writes = -1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "opencode run timed out after $TimeoutSec s (prompt sha $PromptHash)" }
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
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ ExitCode = $code; Writes = $writes; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

# --- main loop ---------------------------------------------------------------

Write-Host "tasks manifest: $manifestPath" -ForegroundColor DarkGray
Write-Host ("model: {0} (label {1})" -f $Model, $ModelLabel) -ForegroundColor DarkGray
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
    if (-not $promptHashes.ContainsKey($tk.id)) {
        $promptHashes[$tk.id] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($prompt))).Substring(0, 12)
    }
    Write-Host ("  prompt: {0} chars (sha256 {1})" -f $prompt.Length, $promptHashes[$tk.id]) -ForegroundColor DarkGray

    if ($DryRun) {
        Write-Result $tk.id "dry-run" "PASS" "worktree + install + baseline validated; model run skipped (add -DryRun removed)"
        continue
    }

    $run = Invoke-OpencodeRun -WtPath $wt.Wt -ModelId $Model -Prompt $prompt -PromptHash $promptHashes[$tk.id] -TimeoutSec $RunTimeout
    if ($run.ExitCode -eq -1) {
        Write-Result $tk.id "opencode run" "FAIL" $run.Detail
        $overallPass = $false
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
    $typecheckOk = $true
    if ($tk.typecheck) {
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
                Write-Result $tk.id "typecheck (scoped)" "PASS" "touched module graph compiles"
            } else {
                $typecheckOk = $false
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
    $result = [pscustomobject]@{
        timestamp    = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        taskId       = $tk.id
        taskTitle    = $tk.title
        model        = $Model
        modelLabel   = $ModelLabel
        baseCommit   = $wt.Head
        promptSha256 = $promptHashes[$tk.id]
        opencodeExit = $run.ExitCode
        writes       = $run.Writes
        gates        = $gateSummary
        typecheck    = $(if ($typecheckOk) { "PASS" } else { "WARN" })
        elapsedSec   = $run.ElapsedSec
    }
    $runFile = Join-Path $resultsDir ("tasks-{0}-{1}_{2}.json" -f $tk.id, ($ModelLabel -replace '[^a-zA-Z0-9._-]', '_'), (Get-Date -Format "yyyyMMdd-HHmmss"))
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
$summaryLines = @()
if (-not (Test-Path -LiteralPath $summaryTsv)) { $summaryLines += $summaryHeader }
$summaryLines += $summaryRows
Add-Content -LiteralPath $summaryTsv -Value $summaryLines -Encoding utf8

Write-Host ""
Write-Host ("Results: {0} PASS, {1} FAIL, {2} WARN, {3} SKIP" -f $statusCounts.PASS, $statusCounts.FAIL, $statusCounts.WARN, $statusCounts.SKIP) -ForegroundColor Cyan
Write-Host "Summary appended to $summaryTsv" -ForegroundColor DarkGray

if ($overallPass) { exit 0 }
exit 1

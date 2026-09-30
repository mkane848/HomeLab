# test-task-pins.ps1 - regression guard for how a benchmark task's base commit is chosen.
#
# Why this exists: three of the nine tasks (kane-01, lfc-01, lfc-03) ran from the TIP of a
# local branch (a work branch, and `main`), and the harness resolved every task through
# `refs/heads/<branch>` in the owner's own checkout. One merge or rebase would have moved
# a task's base under a corpus of rows meant to be comparable, silently; and kane-01's
# base commit is on no remote at all, so nobody else could reproduce the task with the
# most rows in the corpus. Every recorded row did share one commit per task, which is
# what the manifest now pins as `benchBaseCommit`, and test-tasks.ps1's Resolve-TaskBase
# runs that exact commit (the branch is only a label; a moved branch is a WARN).
#
# What it does:
#   1. manifest: every task carries a full 40-hex `benchBaseCommit`.
#   2. corpus:   every row in tests/results/tasks-summary.tsv ran from its task's pin, so
#                pinning changed no comparison. (A future re-base must be a NEW task id, or
#                this fails: two bases under one id make the rows incomparable.)
#   3. Resolve-TaskBase, the REAL function from test-tasks.ps1, on throwaway git repos:
#                pin followed over a moved branch, a label-only branch, a pin missing from
#                the repo, and the unpinned fallback.
#   4. Get-PublishState, the REAL function from run-tasks-batch.ps1, against a throwaway
#                bare origin: published / unpublished / unknown / missing.
#   5. the real checkouts, when this machine has them: each pin must resolve in its repo.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-task-pins.ps1 [-ScriptPath <test-tasks.ps1>] [-BatchPath <run-tasks-batch.ps1>]
#                                    [-ManifestPath <manifest.json>] [-SummaryPath <tasks-summary.tsv>]
param(
    [string]$ScriptPath   = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$BatchPath    = (Join-Path $PSScriptRoot "run-tasks-batch.ps1"),
    [string]$ManifestPath = (Join-Path $PSScriptRoot "tasks/manifest.json"),
    [string]$SummaryPath  = (Join-Path $PSScriptRoot "results/tasks-summary.tsv")
)

$ErrorActionPreference = "Stop"

function Import-Functions([string]$Path, [string[]]$Names) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs.Count) { $errs; exit 2 }
    $fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($name in $Names) {
        $fn = $fns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $fn) { Write-Host "FAIL: $name not found in $Path"; exit 2 }
        # script: scope, so the function outlives this helper
        Invoke-Expression ($fn.Extent.Text -replace '^function\s+', 'function script:')
    }
}
Import-Functions $ScriptPath @("Run-Native", "Get-HeadCommit", "Resolve-TaskBase")
Import-Functions $BatchPath @("Get-PublishState")

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("task-pins-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

function New-Repo {
    $repo = Join-Path $tmpRoot ([guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    git -C $repo init -q
    git -C $repo symbolic-ref HEAD refs/heads/main
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    return $repo
}
function New-Commit([string]$repo, [string]$name) {
    Set-Content -LiteralPath (Join-Path $repo "f.txt") -Value $name
    git -C $repo add -A
    git -C $repo commit -q -m $name
    return (git -C $repo rev-parse HEAD).Trim()
}

try {
    Write-Host "-- manifest"
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $byId = @{}
    foreach ($t in $manifest.tasks) { $byId[$t.id] = $t }
    foreach ($t in $manifest.tasks) {
        $ok = [bool]($t.benchBaseCommit -match '^[0-9a-f]{40}$') -and [bool]$t.branch
        Check ("{0}: pinned to a full commit, with a branch label" -f $t.id) $ok $true
    }

    Write-Host "-- corpus (every recorded row ran from its task's pin)"
    $rows = @(Import-Csv -LiteralPath $SummaryPath -Delimiter "`t")
    $unknownTasks = 0
    foreach ($t in $manifest.tasks) {
        $mine = @($rows | Where-Object { $_.taskId -eq $t.id })
        $off = @($mine | Where-Object { $_.baseCommit -ne $t.benchBaseCommit })
        Check ("{0}: {1} row(s), {2} from another base" -f $t.id, $mine.Count, $off.Count) ($off.Count -eq 0) $true
    }
    $unknownTasks = @($rows | Where-Object { -not $byId.ContainsKey($_.taskId) }).Count
    if ($unknownTasks) { Write-Host "     note: $unknownTasks row(s) belong to a task id that is not in the manifest (not checked)" }

    Write-Host "-- Resolve-TaskBase (real function, throwaway repos)"
    $repo = New-Repo
    $c1 = New-Commit $repo "one"
    $c2 = New-Commit $repo "two"      # main is now at c2; the pin will be c1
    $task = [pscustomobject]@{ id = "t"; repo = $repo; branch = "main"; benchBaseCommit = $c1 }
    $b = Resolve-TaskBase $task
    Check "a pin behind the branch tip runs the pin, not the tip"      ($b.Head -eq $c1 -and $b.Source -eq "pin") $true
    Check "...and says the branch is somewhere else"                   ([bool]($b.Warning -match "main is at .* not the pinned")) $true
    $wtPath = Join-Path $tmpRoot "wt"
    git -C $repo worktree add -q --detach $wtPath $b.Ref
    Check "...and a worktree made from its Ref sits on the pin"        ((git -C $wtPath rev-parse HEAD).Trim() -eq $c1) $true

    $atTip = Resolve-TaskBase ([pscustomobject]@{ id = "t"; repo = $repo; branch = "main"; benchBaseCommit = $c2 })
    Check "a pin equal to the branch tip: no warning"                  ($atTip.Head -eq $c2 -and -not $atTip.Warning) $true
    $noLabel = Resolve-TaskBase ([pscustomobject]@{ id = "t"; repo = $repo; branch = "bench/gone"; benchBaseCommit = $c1 })
    Check "a pin needs no local branch at all"                         ($noLabel.Head -eq $c1 -and -not $noLabel.Error) $true

    $gone = "0123456789abcdef0123456789abcdef01234567"
    $missing = Resolve-TaskBase ([pscustomobject]@{ id = "t"; repo = $repo; branch = "bench/x"; benchBaseCommit = $gone })
    Check "a pin missing from the repo is an error, with the push command" ([bool](-not $missing.Head -and $missing.Error -match "not in" -and $missing.Error -match "push origin $gone`:refs/heads/bench/x")) $true

    $legacy = Resolve-TaskBase ([pscustomobject]@{ id = "t"; repo = $repo; branch = "main" })
    Check "no pin: the branch tip, as before"                          ($legacy.Head -eq $c2 -and $legacy.Source -eq "branch") $true
    $legacyMissing = Resolve-TaskBase ([pscustomobject]@{ id = "t"; repo = $repo; branch = "bench/none" })
    Check "no pin and no branch: cannot resolve"                       ([bool](-not $legacyMissing.Head -and $legacyMissing.Error -match "cannot resolve refs/heads/bench/none")) $true

    Write-Host "-- Get-PublishState (real function, throwaway bare origin)"
    $origin = Join-Path $tmpRoot "origin.git"
    git init -q --bare $origin
    $work = New-Repo
    git -C $work remote add origin $origin
    $p1 = New-Commit $work "pushed"
    git -C $work push -q origin main 2>$null
    $p2 = New-Commit $work "local only"
    Check "a commit that was pushed"                                   (Get-PublishState -Repo $work -Commit $p1) "published"
    Check "a commit only on a local branch"                            (Get-PublishState -Repo $work -Commit $p2) "unpublished"
    Check "a commit that is not in the clone"                          (Get-PublishState -Repo $work -Commit $gone) "missing"
    $lone = New-Repo
    $l1 = New-Commit $lone "no remote"
    git -C $lone remote add origin (Join-Path $tmpRoot "does-not-exist.git")
    Check "origin unreachable: unknown, not a false alarm"             (Get-PublishState -Repo $lone -Commit $l1) "unknown"
    git -C $work push -q origin main 2>$null
    Check "after it is pushed, the same commit reads as published"     (Get-PublishState -Repo $work -Commit $p2) "published"

    Write-Host "-- real checkouts (only where this machine has them)"
    $present = 0
    foreach ($t in $manifest.tasks) {
        if (-not (Test-Path -LiteralPath $t.repo)) { continue }
        $present++
        $r = Run-Native "git" @("-C", $t.repo, "cat-file", "-e", "$($t.benchBaseCommit)^{commit}")
        Check ("{0}: the pin resolves in {1}" -f $t.id, $t.repo) ($r.ExitCode -eq 0) $true
    }
    if (-not $present) { Write-Host "SKIP none of the task repos are checked out on this machine" }
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 } else { Write-Host "RESULT: all checks passed" }

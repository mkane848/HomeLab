# test-task-pins.ps1 - regression guard for how a benchmark task's base commit (and its
# acceptance commit) is chosen and checked.
#
# Why this exists: three of the nine tasks (kane-01, lfc-01, lfc-03) ran from the TIP of a
# local branch (a work branch, and `main`), and the harness resolved every task through
# `refs/heads/<branch>` in the owner's own checkout. One merge or rebase would have moved
# a task's base under a corpus of rows meant to be comparable, silently. Every recorded
# row did share one commit per task, which is what the manifest now pins as
# `benchBaseCommit` (and `acceptance.commit`, for lfc-03's owner tests); test-tasks.ps1's
# Resolve-TaskBase / Resolve-AcceptanceCommit run those exact commits, and the branch is
# only a label (a moved branch is a WARN).
#
# What it does:
#   1. manifest: every task carries a full 40-hex `benchBaseCommit`; a task with an
#                `acceptance` block carries a full `acceptance.commit`.
#   2. corpus:   every row in tests/results/tasks-summary.tsv ran from its task's pin, and
#                every recorded acceptance run used the acceptance pin, so pinning changed
#                no comparison. (A future re-base must be a NEW task id, or this fails:
#                two bases under one id make the rows incomparable.)
#   3. Resolve-TaskBase and Resolve-AcceptanceCommit, the REAL functions from test-tasks.ps1,
#                on throwaway git repos, including a commit that is upstream but not yet in the
#                clone (fetched from origin once before it is called missing).
#   4. Get-PublishState, the REAL function from run-tasks-batch.ps1, against a throwaway
#                bare origin: published / unpublished / unknown / missing, including the
#                two shapes that once produced a wrong answer - a commit only a pull-request
#                ref reaches, and a single-branch clone that cannot see the branch holding it.
#   5. the real checkouts, when this machine has them: each pin (and acceptance commit) resolves
#                in its repo - through the harness's own resolvers, so a commit the clone lacks
#                is fetched from origin first, exactly as a run would do.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-task-pins.ps1 [-ScriptPath <test-tasks.ps1>] [-BatchPath <run-tasks-batch.ps1>]
#                                    [-ManifestPath <manifest.json>] [-SummaryPath <tasks-summary.tsv>]
#                                    [-ResultsDir <tests/results>]
param(
    [string]$ScriptPath   = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$BatchPath    = (Join-Path $PSScriptRoot "run-tasks-batch.ps1"),
    [string]$ManifestPath = (Join-Path $PSScriptRoot "tasks/manifest.json"),
    [string]$SummaryPath  = (Join-Path $PSScriptRoot "results/tasks-summary.tsv"),
    [string]$ResultsDir   = (Join-Path $PSScriptRoot "results")
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
Import-Functions $ScriptPath @("Run-Native", "Get-HeadCommit", "Resolve-TaskBase", "Resolve-AcceptanceCommit")
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
        if ($t.acceptance) {
            Check ("{0}: acceptance pinned to a full commit" -f $t.id) ([bool]($t.acceptance.commit -match '^[0-9a-f]{40}$')) $true
        }
    }

    Write-Host "-- corpus (every recorded row ran from its task's pin)"
    $rows = @(Import-Csv -LiteralPath $SummaryPath -Delimiter "`t")
    foreach ($t in $manifest.tasks) {
        $mine = @($rows | Where-Object { $_.taskId -eq $t.id })
        $off = @($mine | Where-Object { $_.baseCommit -ne $t.benchBaseCommit })
        Check ("{0}: {1} row(s), {2} from another base" -f $t.id, $mine.Count, $off.Count) ($off.Count -eq 0) $true
    }
    $unknownTasks = @($rows | Where-Object { -not $byId.ContainsKey($_.taskId) }).Count
    if ($unknownTasks) { Write-Host "     note: $unknownTasks row(s) belong to a task id that is not in the manifest (not checked)" }
    foreach ($t in @($manifest.tasks | Where-Object { $_.acceptance })) {
        $used = @()
        foreach ($f in Get-ChildItem -LiteralPath $ResultsDir -Filter "tasks-$($t.id)-*.json") {
            $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            if ($j.acceptance -and $j.acceptance.commit) { $used += $j.acceptance.commit }
        }
        $off = @($used | Where-Object { $_ -ne $t.acceptance.commit })
        Check ("{0}: {1} recorded acceptance run(s), {2} from another commit" -f $t.id, $used.Count, $off.Count) ($off.Count -eq 0) $true
    }

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

    Write-Host "-- Resolve-AcceptanceCommit (real function, throwaway repos)"
    git -C $repo branch bench/acc $c1
    $acc = { param($ref, $commit) [pscustomobject]@{ id = "t"; repo = $repo; acceptance = [pscustomobject]@{ ref = $ref; commit = $commit; files = @("f.txt") } } }
    $a = Resolve-AcceptanceCommit (& $acc "bench/acc" $c1)
    Check "a pin equal to the branch tip: that commit, no warning"     ($a.Commit -eq $c1 -and -not $a.Warning -and -not $a.Error) $true
    git -C $repo branch -f bench/acc $c2
    $a = Resolve-AcceptanceCommit (& $acc "bench/acc" $c1)
    Check "the branch moved on: the pin is run, and the move is a warning" ($a.Commit -eq $c1 -and [bool]($a.Warning -match "bench/acc is at .* not the pinned")) $true
    $a = Resolve-AcceptanceCommit (& $acc "bench/deleted" $c1)
    Check "the branch is gone: the pin still resolves"                 ($a.Commit -eq $c1 -and -not $a.Error) $true
    $a = Resolve-AcceptanceCommit (& $acc "bench/acc" $gone)
    Check "a pin missing from the repo is an error"                    ([bool](-not $a.Commit -and $a.Error -match "pinned acceptance commit $gone is not in")) $true
    $a = Resolve-AcceptanceCommit (& $acc "bench/acc" $null)
    Check "no pin: the branch tip, as before"                          ($a.Commit -eq $c2 -and -not $a.Error) $true
    $a = Resolve-AcceptanceCommit (& $acc "bench/deleted" $null)
    Check "no pin and no branch: cannot resolve"                       ([bool](-not $a.Commit -and $a.Error -match "cannot resolve refs/heads/bench/deleted")) $true

    Write-Host "-- fetch on a miss (a commit that is upstream but not yet in this clone)"
    $up = Join-Path $tmpRoot "up.git"
    git init -q --bare --initial-branch=main $up
    $seed = New-Repo
    git -C $seed remote add origin $up
    $null = New-Commit $seed "u1"
    git -C $seed push -q origin main 2>$null
    $clone = Join-Path $tmpRoot "clone"
    git clone -q $up $clone
    $u2 = New-Commit $seed "u2"
    git -C $seed push -q origin main 2>$null
    Check "the clone starts without the later commit"                  ((Run-Native "git" @("-C", $clone, "cat-file", "-e", "$u2^{commit}")).ExitCode -ne 0) $true
    $b = Resolve-TaskBase ([pscustomobject]@{ id = "t"; repo = $clone; branch = "bench/x"; benchBaseCommit = $u2 })
    Check "a base pin that is upstream but not yet local is fetched, then run" ($b.Head -eq $u2 -and -not $b.Error) $true
    $u3 = New-Commit $seed "u3"
    git -C $seed push -q origin main 2>$null
    Check "the clone is still without the next one"                    ((Run-Native "git" @("-C", $clone, "cat-file", "-e", "$u3^{commit}")).ExitCode -ne 0) $true
    $a = Resolve-AcceptanceCommit ([pscustomobject]@{ id = "t"; repo = $clone; acceptance = [pscustomobject]@{ ref = "upstream-fix"; commit = $u3; files = @("f.txt") } })
    Check "an acceptance pin that is upstream but not yet local is fetched, then run (no branch warning for a label)" ($a.Commit -eq $u3 -and -not $a.Error -and -not $a.Warning) $true
    $a = Resolve-AcceptanceCommit ([pscustomobject]@{ id = "t"; repo = $clone; acceptance = [pscustomobject]@{ ref = "upstream-fix"; commit = $gone; files = @("f.txt") } })
    Check "an acceptance pin that exists nowhere is an error that says a fetch was tried" ([bool](-not $a.Commit -and $a.Error -match "even after git fetch origin")) $true

    Write-Host "-- Get-PublishState (real function, throwaway bare origin)"
    $origin = Join-Path $tmpRoot "origin.git"
    git init -q --bare $origin
    $work = New-Repo
    git -C $work remote add origin $origin
    $p1 = New-Commit $work "pushed"
    git -C $work push -q origin main 2>$null
    $p2 = New-Commit $work "local only"
    Check "a commit that was pushed"                                   (Get-PublishState -Repo $work -Commit $p1) "published"
    # p2 is in this clone. `git fetch origin <p2>` HERE would exit 0 without asking origin,
    # so the answer must come from asking origin from an empty repo.
    Check "a commit only in this clone (not fooled by having it)"      (Get-PublishState -Repo $work -Commit $p2) "unpublished"
    Check "a commit that is not in the clone"                          (Get-PublishState -Repo $work -Commit $gone) "missing"

    git -C $work checkout -q -b topic
    $t1 = New-Commit $work "only a pull-request ref reaches this"
    git -C $work push -q origin topic:refs/pull/1/head 2>$null
    Check "reachable only via refs/pull/1/head (kane-01's shape)"      (Get-PublishState -Repo $work -Commit $t1) "published"

    git -C $work checkout -q main
    git -C $work checkout -q -b feature
    $f1 = New-Commit $work "on a branch a single-branch clone cannot see"
    git -C $work push -q origin feature 2>$null
    $single = Join-Path $tmpRoot "single"
    git clone -q --single-branch --branch main $origin $single
    git -C $single fetch -q origin $f1                       # the commit is here, but no remote-tracking branch shows it
    Check "a single-branch clone that holds a commit from another branch" (Get-PublishState -Repo $single -Commit $f1) "published"

    $lone = New-Repo
    $l1 = New-Commit $lone "no reachable remote"
    git -C $lone remote add origin (Join-Path $tmpRoot "does-not-exist.git")
    Check "origin unreachable: unknown, not a false alarm"             (Get-PublishState -Repo $lone -Commit $l1) "unknown"
    $nor = New-Repo
    $n1 = New-Commit $nor "no origin at all"
    Check "no origin remote: nowhere it could be published"            (Get-PublishState -Repo $nor -Commit $n1) "unpublished"
    git -C $work push -q origin main 2>$null
    Check "after it is pushed, the same commit reads as published"     (Get-PublishState -Repo $work -Commit $p2) "published"

    Write-Host "-- real checkouts (only where this machine has them)"
    $present = 0
    foreach ($t in $manifest.tasks) {
        if (-not (Test-Path -LiteralPath $t.repo)) { continue }
        $present++
        $b = Resolve-TaskBase $t
        Check ("{0}: the pin resolves in {1}" -f $t.id, $t.repo) ([bool]$b.Head) $true
        if ($t.acceptance) {
            $a = Resolve-AcceptanceCommit $t
            Check ("{0}: the acceptance commit resolves in {1}" -f $t.id, $t.repo) ([bool]$a.Commit) $true
        }
    }
    if (-not $present) { Write-Host "SKIP none of the task repos are checked out on this machine" }
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 } else { Write-Host "RESULT: all checks passed" }

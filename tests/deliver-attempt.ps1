# deliver-attempt.ps1 - hand a task's best attempt to the owner as a branch in their repository (Step 2 of "from
# experiments to real work", 2026-11-02; docs/planner-tests-experiment.md, "Delivery").
#
# Why this exists: an attempt's change used to die with its sealed checkout. Now test-tasks.ps1 keeps it as a patch
# beside the run JSON (`patchFile`), and this script turns the best one into a branch the owner reviews and merges.
#
# Which attempt (the owner's bar, 2026-11-01):
#   accepted     what run-retries.ps1 keeps (Get-AttemptVerdict, read from that script): the selector, suite and scope
#                passed, the integrity gate did not fail, nothing tampered. The latest accepted attempt is delivered.
#   near miss    when none was accepted: the attempt that failed the fewest selector tests, but ONLY among attempts that
#                broke none of the owner's hard blocks (integrity, suite, scope, tampering). A near miss is labelled as
#                one; the owner decides in a minute whether the test was picky or the gap real.
#   nothing      only hard-block failures, or no patch at all: exit 2, no branch.
#
# How: a temporary worktree at the attempt's base commit on a new branch `fleet/<task>` (`-2`, `-3` ... if taken),
# `git apply --index` of the patch, one commit whose message carries every gate's verdict, the worktree removed. The
# owner's working copy, current branch and `main` are never touched, and nothing is pushed: there is no push in this
# script, and tests/test-deliver-attempt.ps1 checks that. Every delivery appends a row to deliveries.tsv in -ResultsDir.
#
#   pwsh -File tests\deliver-attempt.ps1 -ResultsDir <run folder> -Task <id> [-Repo <path>] [-Branch fleet/x] [-DryRun]
# Exit 0 delivered (or would, with -DryRun), 2 nothing deliverable, 3 bad arguments or a git failure.
param(
    [Parameter(Mandatory)][string]$ResultsDir,
    [Parameter(Mandatory)][string]$Task,
    [string]$Repo = "",
    [string]$Branch = "",
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"

# The dispatcher's own rule, read from run-retries.ps1 so the two can never disagree.
$rr = Join-Path $PSScriptRoot "run-retries.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile($rr, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-AttemptVerdict" }, $true) | Select-Object -First 1
if (-not $fn) { Write-Host "ERROR: Get-AttemptVerdict not found in $rr" -ForegroundColor Red; exit 3 }
. ([scriptblock]::Create($fn.Extent.Text))

function Invoke-Git([string[]]$GitArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $out = & git @GitArgs 2>&1 | ForEach-Object { "$_" }; [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out) } }
    finally { $ErrorActionPreference = $prev }
}

if (-not (Test-Path -LiteralPath $ResultsDir)) { Write-Host "ERROR: no folder $ResultsDir" -ForegroundColor Red; exit 3 }
$runs = @(Get-ChildItem -LiteralPath $ResultsDir -Recurse -Filter "tasks-$Task-*.json" | Sort-Object Name | ForEach-Object {
        $j = Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json
        $patch = if ($j.PSObject.Properties['patchFile'] -and $j.patchFile) { Join-Path $_.DirectoryName $j.patchFile } else { $null }
        $failed = if ($j.selector -and "$($j.selector.detail)" -match '(\d+)\s+failed') { [int]$Matches[1] } else { 0 }
        [pscustomobject]@{ File = $_; Json = $j; Verdict = (Get-AttemptVerdict $j); Patch = $patch; Failed = $failed }
    } | Where-Object { $_.Patch -and (Test-Path -LiteralPath $_.Patch) })
if (-not $runs.Count) { Write-Host "nothing deliverable: no run of $Task in $ResultsDir has a patch" -ForegroundColor Yellow; exit 2 }

# From the gates themselves, not the verdict's reason: Get-AttemptVerdict names only the FIRST rejection, and it checks
# the selector before suite, scope and integrity, so an attempt that failed the planner's tests AND broke a hard block
# reads as plain "selector" (the guard caught exactly that delivering an integrity-blocked attempt).
$hardBlock = { param($r)
    $j = $r.Json
    (@($j.acceptanceShown.tampered | Where-Object { $_ }).Count -gt 0) -or ($j.gates.suite -ne "PASS") -or ($j.gates.scope -ne "PASS") -or
        ($j.gates.PSObject.Properties['integrity'] -and $j.gates.integrity -eq "FAIL") }
$accepted = @($runs | Where-Object { $_.Verdict.Accepted })
$pick = $null; $kind = $null
if ($accepted.Count) { $pick = $accepted[-1]; $kind = "accepted" }
else {
    $near = @($runs | Where-Object { -not (& $hardBlock $_) } | Sort-Object Failed, @{ e = { $_.File.Name }; Descending = $true })
    if ($near.Count) { $pick = $near[0]; $kind = "near miss" }
}
if (-not $pick) {
    Write-Host ("nothing deliverable: every attempt of {0} broke a hard block ({1})" -f $Task, (($runs | ForEach-Object { $_.Verdict.Reason }) -join ", ")) -ForegroundColor Yellow
    exit 2
}

$j = $pick.Json
if (-not $Repo) { $Repo = [string]$j.repoPath }
if (-not $Repo -or -not (Test-Path -LiteralPath $Repo)) { Write-Host "ERROR: no repository (-Repo, or the run's repoPath '$($j.repoPath)')" -ForegroundColor Red; exit 3 }
$base = [string]$j.baseCommit
if ((Invoke-Git @("-C", $Repo, "cat-file", "-e", "$base^{commit}")).Code -ne 0) { Write-Host "ERROR: the base commit $base is not in $Repo" -ForegroundColor Red; exit 3 }

if (-not $Branch) { $Branch = "fleet/$Task" }
if ($Branch -match '^(main|master|HEAD)$' -or $Branch -notmatch '^[\w./-]+$') { Write-Host "ERROR: refusing branch name '$Branch'" -ForegroundColor Red; exit 3 }
$name = $Branch; $n = 1
while ((Invoke-Git @("-C", $Repo, "rev-parse", "--verify", "--quiet", "refs/heads/$name")).Code -eq 0) { $n++; $name = "$Branch-$n" }

$ideal = if ($j.PSObject.Properties['ideal'] -and $j.ideal -and $null -ne $j.ideal.total) { "{0} of {1} done{2}" -f $j.ideal.done, $j.ideal.total, $(if (@($j.ideal.missedIds).Count) { "; missed " + (@($j.ideal.missedIds) -join ", ") } else { "" }) } else { "not measured" }
$integrity = if ($j.gates.PSObject.Properties['integrity']) { $j.gates.integrity } else { "not checked" }
$subject = if ($kind -eq "accepted") { "fleet: $Task (accepted)" } else { "fleet: $Task (NEAR MISS, not accepted: $($pick.Failed) planner test(s) failed)" }
$body = @(
    "Task: $Task - $($j.taskTitle)"
    "Planner's tests (the gate): $($j.selector.status) - $($j.selector.detail)"
    "Integrity (nothing lost, nothing wrong): $integrity"
    "Suite: $($j.gates.suite); scope: $($j.gates.scope)"
    "Ideal tier: $ideal"
    $(if ($j.acceptance -and $j.acceptance.status) { "Hidden tests (benchmark tasks only): $($j.acceptance.status)" })
    "Run: $($pick.File.Name), model $($j.model), $($j.elapsedSec) s"
    "Delivered by tests/deliver-attempt.ps1; review, then record a verdict with tests/record-verdict.ps1."
) | Where-Object { $_ }

Write-Host ("{0}: {1} -> branch {2} at {3} in {4}" -f $Task, $kind, $name, $base.Substring(0, 7), $Repo)
if ($DryRun) { Write-Host "dry run: nothing created"; $body | ForEach-Object { Write-Host "  $_" }; exit 0 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("fleet-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$ok = $false
try {
    $r = Invoke-Git @("-C", $Repo, "worktree", "add", "-q", "-b", $name, $tmp, $base)
    if ($r.Code -ne 0) { throw "worktree add: $($r.Out -join ' ')" }
    $r = Invoke-Git @("-C", $tmp, "apply", "--index", "--whitespace=nowarn", $pick.Patch)
    if ($r.Code -ne 0) { throw "the patch does not apply at $($base.Substring(0, 7)): $($r.Out -join ' ')" }
    $who = @()
    if (-not (Invoke-Git @("-C", $tmp, "config", "user.email")).Out) { $who = @("-c", "user.name=HomeLab fleet", "-c", "user.email=fleet@homelab.invalid") }
    $msgFile = Join-Path ([IO.Path]::GetTempPath()) ("fleet-msg-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".txt")
    [IO.File]::WriteAllText($msgFile, ($subject + "`n`n" + ($body -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-Git (@("-C", $tmp) + $who + @("commit", "-q", "--no-verify", "-F", $msgFile))
    Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
    if ($r.Code -ne 0) { throw "commit: $($r.Out -join ' ')" }
    $ok = $true
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    Invoke-Git @("-C", $Repo, "worktree", "remove", "--force", $tmp) | Out-Null
    Invoke-Git @("-C", $Repo, "worktree", "prune") | Out-Null
    if (-not $ok) { Invoke-Git @("-C", $Repo, "branch", "-D", $name) | Out-Null }
}
if (-not $ok) { exit 3 }

$commit = ((Invoke-Git @("-C", $Repo, "rev-parse", "refs/heads/$name")).Out | Select-Object -First 1)
$ledger = Join-Path $ResultsDir "deliveries.tsv"
if (-not (Test-Path -LiteralPath $ledger)) { Set-Content -LiteralPath $ledger -Value ("timestamp`ttask`tbranch`tcommit`tkind`trun`tselector`tintegrity`tideal") -Encoding utf8 }
Add-Content -LiteralPath $ledger -Value (@((Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Task, $name, $commit, $kind, $pick.File.Name, $j.selector.status, $integrity, $ideal) -join "`t") -Encoding utf8
Write-Host ("delivered: {0} ({1}), commit {2}; nothing pushed. Review it, then: pwsh -File tests\record-verdict.ps1 -ResultsDir '{3}' -Task {4} -Verdict merged|fixed|rejected -Note '...'" -f $name, $kind, $commit.Substring(0, 7), $ResultsDir, $Task) -ForegroundColor Green
exit 0

# test-sealed-checkout.ps1 - regression guard for the sealed task checkout
# (Initialize-SealedCheckout / Add-CommitToCheckout in test-tasks.ps1).
#
# Why this exists: a task's checkout was a `git worktree` of the owner's real
# repo, so the model could reach every later commit (the task's real fix among
# them), the owner's other branches and stashes, and its own commits from earlier
# trials, with one `git log --all` or `git show <sha>`. A 2026-10-21 scan found a
# hosted run listing future commits that way. The checkout's `.git` is now
# rebuilt before every run from the base commit alone.
#
# What it does: the REAL test-tasks.ps1 end to end against a fixture repo whose
# history runs A (older) -> B (the pinned base) -> C (the "solution", holding the
# hidden test), with a side branch, a tag and a stash, and an old-style worktree
# already registered at the task's path. A fixture agent probes, from inside the
# checkout, what it can reach, and commits on its first run. Checked:
#   - the old worktree is replaced and its registration pruned;
#   - inside the checkout: history is exactly A and B; C, the side branch, the
#     tag, the stash and any remote are absent; HEAD is detached at B;
#   - the hidden test (in C) still grades the run: the acceptance commit is
#     fetched after the model's run, and the run passes;
#   - a second run cannot reach the first run's commit (no reflog survives), an
#     ignored file (node_modules) survives, and the install marker is honoured;
#   - core.autocrlf is copied from the task repo; the run JSON records
#     `checkout` (sealed, 2 commits);
#   - the commits travel as cached git bundles (Get-CommitBundle), and the task
#     repo is left with no refs/homelab-seal ref.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-sealed-checkout.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sealed-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$psExe = (Get-Process -Id $PID).Path
try {
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "tests/agents", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $e2e "tests") -Recurse -Force
    $repo = Join-Path $e2e "repo"
    function G { git -C $repo @args 2>&1 | Out-Null }
    G init -q; G config user.email "t@example.invalid"; G config user.name "t"; G config core.autocrlf false
    Set-Content -LiteralPath (Join-Path $repo ".gitignore") -Value "node_modules/"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "older"
    'if ((Test-Path hidden.txt) -and (Get-Content src.txt -Raw).Trim() -ne "fixed") { Write-Host "Tests  1 failed (2)"; exit 1 }; Write-Host "Tests  2 passed (2)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    G add -A; G commit -q -m "A older"
    $shaA = (git -C $repo rev-parse HEAD).Trim()
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    G commit -q -am "B base"
    $shaB = (git -C $repo rev-parse HEAD).Trim()
    Set-Content -LiteralPath (Join-Path $repo "hidden.txt") -Value "hidden test"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "fixed"
    G add -A; G commit -q -m "C the real fix"
    $shaC = (git -C $repo rev-parse HEAD).Trim()
    G branch bench/fx-acc $shaC
    G tag v9 $shaC
    G checkout -q -b side $shaB
    Set-Content -LiteralPath (Join-Path $repo "side.txt") -Value "side"; G add -A; G commit -q -m "D side branch"
    Set-Content -LiteralPath (Join-Path $repo "side.txt") -Value "stashed"; G stash
    G checkout -q $shaC
    G remote add origin "https://example.invalid/owner/repo.git"
    # An old-style worktree already registered at the task's path.
    $wtPath = Join-Path $e2e "tests/.worktrees/fx-seal"
    G worktree add --detach $wtPath $shaB
    $registeredBefore = [bool]((git -C $repo worktree list --porcelain) -match [regex]::Escape(($wtPath -replace '\\', '/')))

    @{ tasks = @([ordered]@{ id = "fx-seal"; title = "fx"; repo = $repo; branch = "bench/fx-seal"; benchBaseCommit = $shaB
        grading = "acceptance"; scope = "guardrails"; acceptance = [ordered]@{ ref = "bench/fx-acc"; commit = $shaC; files = @("hidden.txt") }
        testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @(); prompt = "fix src.txt" }) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")

    # The fixture agent probes the checkout and writes what it found to FX_PROBE.
    @'
$script:AgentName = "fixture"
$script:AgentSamplingNote = "fixture agent: nothing to pin"
function Get-AgentVersion { "0.1.0" }
function Get-AgentConfig { $null }
function Get-AgentModelIds { param($Config) $null }
function Test-AgentAutoupdatePinned { param($Config, [string]$EnvValue) $true }
function Get-AgentModelSettings { param([string]$ModelId) [pscustomobject]@{ OutputLimit = 4096; Compaction = $null; Plugins = @() } }
function Start-AgentRunEnv { param([string[]]$Plugins) [pscustomobject]@{} }
function Stop-AgentRunEnv { param($State) $null }
function Stop-OrphanAgent { param([string]$WtPath) }
function Test-AgentTools { param([string]$Version) [pscustomobject]@{ checked = $true; ok = $true; detail = "fixture tools work"; seconds = 0 } }
function Invoke-AgentRun {
    param([string]$WtPath, [string]$ModelId, [string]$Prompt, [string]$PromptHash, [int]$TimeoutSec, [string]$SessionId = "", [string]$Transcript = "")
    $q = { param($a) $o = & git -C $WtPath @a 2>$null; if ($LASTEXITCODE -ne 0) { "<none>" } else { ($o | Where-Object { $_ }) -join ";" } }
    $p = [ordered]@{
        commits    = & $q @("rev-list", "--all", "--count")
        refs       = & $q @("for-each-ref", "--format=%(refname)")
        stash      = & $q @("stash", "list")
        remotes    = & $q @("remote")
        head       = & $q @("rev-parse", "HEAD")
        detached   = & $q @("symbolic-ref", "-q", "HEAD")
        solution   = & $q @("cat-file", "-t", $env:FX_SHA_C)
        prevTrial  = $(if ($env:FX_PREV) { & $q @("cat-file", "-t", $env:FX_PREV) } else { "" })
        reflog     = & $q @("reflog", "--all")
        ignoredKept = (Test-Path (Join-Path $WtPath "node_modules\kept.txt"))
        autocrlf   = & $q @("config", "--local", "--get", "core.autocrlf")
    }
    # Leave something for the next run to (not) find: an ignored file and a commit.
    New-Item -ItemType Directory -Force (Join-Path $WtPath "node_modules") | Out-Null
    Set-Content -LiteralPath (Join-Path $WtPath "node_modules\kept.txt") -Value "x"
    Set-Content -LiteralPath (Join-Path $WtPath "src.txt") -Value "fixed"
    & git -C $WtPath commit -q -am "trial commit" 2>$null | Out-Null
    $p.trialCommit = (& git -C $WtPath rev-parse HEAD).Trim()
    & git -C $WtPath reset -q --soft HEAD~1 2>$null
    $p | ConvertTo-Json | Set-Content -LiteralPath $env:FX_PROBE
    $out = Join-Path $env:TEMP ("fixture-run-" + [guid]::NewGuid().ToString("N") + ".log")
    Add-Content -LiteralPath $out -Value @("start|s1", "tool|s1|edit|src.txt", "say|s1|done", "end|s1|stop|100|5")
    return [pscustomobject]@{ ExitCode = 0; Writes = (Get-WriteCount -Path $out); ElapsedSec = 0.1; TranscriptPath = $out; Ending = (Get-TranscriptEnding -Path $out) }
}
function Read-AgentEvents {
    param([string]$Path)
    $events = New-Object System.Collections.Generic.List[object]
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return , $events }
    foreach ($l in [IO.File]::ReadAllLines($Path)) {
        $f = $l -split '\|'
        switch ($f[0]) {
            "start" { $events.Add([pscustomobject]@{ Kind = "step-start"; SessionId = $f[1] }) }
            "tool"  { $events.Add([pscustomobject]@{ Kind = "tool"; SessionId = $f[1]; Tool = $f[2]; Status = "completed"; Input = $null; Paths = @($f[3]); OutputChars = 0 }) }
            "say"   { $events.Add([pscustomobject]@{ Kind = "text"; SessionId = $f[1]; Text = $f[2]; CompactionContinue = $false }) }
            "end"   { $events.Add([pscustomobject]@{ Kind = "step-end"; SessionId = $f[1]; Finish = $f[2]; HasTokens = $true; Input = [int]$f[3]; Output = [int]$f[4]; Reasoning = 0; CacheRead = 0; CacheWrite = 0 }) }
        }
    }
    return , $events
}
'@ | Set-Content -LiteralPath (Join-Path $e2e "tests/agents/fixture.ps1")

    $harness = Join-Path $e2e "tests/test-tasks.ps1"
    $env:FX_SHA_C = $shaC
    function Invoke-Run([string]$Prev) {
        $env:FX_PROBE = Join-Path $tmp ("probe-" + [guid]::NewGuid().ToString("N") + ".json")
        $env:FX_PREV = $Prev
        $log = & $harness -Agent fixture -Task fx-seal -Model fixture/m -SkipInstall -RunTimeout 60 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
        $probe = if (Test-Path -LiteralPath $env:FX_PROBE) { Get-Content -Raw -LiteralPath $env:FX_PROBE | ConvertFrom-Json } else { $null }
        $json = Get-ChildItem (Join-Path $e2e "tests/results") -Filter "tasks-fx-seal-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        $j = if ($json) { Get-Content -Raw -LiteralPath $json.FullName | ConvertFrom-Json } else { $null }
        if ($json) { Remove-Item -LiteralPath $json.FullName }
        if (-not $probe -or -not $j) { Write-Host (($log -split "`n" | Select-Object -Last 25) -join "`n") }
        return [pscustomobject]@{ Log = $log; Probe = $probe; Json = $j }
    }

    Write-Host "-- first run (an old-style worktree was registered at the task's path: $registeredBefore)"
    $r1 = Invoke-Run ""
    $registeredAfter = [bool]((git -C $repo worktree list --porcelain) -match [regex]::Escape(($wtPath -replace '\\', '/')))
    Check "the old worktree registration is gone" $registeredAfter "False"
    Check "...and the checkout's .git is a directory of its own" (Test-Path -LiteralPath (Join-Path $wtPath ".git") -PathType Container) "True"
    Check "inside: exactly the base's history (A and B)" $r1.Probe.commits 2
    Check "...no branch, tag or other ref" $r1.Probe.refs ""
    Check "...no stash" $r1.Probe.stash ""
    Check "...no remote" $r1.Probe.remotes ""
    Check "...the solution commit is not there" $r1.Probe.solution "<none>"
    Check "...HEAD is detached at the base" ("{0}|{1}" -f $r1.Probe.head, $r1.Probe.detached) "$shaB|<none>"
    Check "...core.autocrlf copied from the task repo" $r1.Probe.autocrlf "false"
    Check "the hidden test (in the solution commit) still grades the run" ("{0}|{1}" -f $r1.Json.acceptance.status, $r1.Json.gates.suite) "PASS|PASS"
    Check "the run JSON records the sealed checkout" ("{0}|{1}" -f $r1.Json.checkout.kind, $r1.Json.checkout.commits) "sealed|2"
    Check "the console says so" ([bool]($r1.Log -match 'sealed checkout at .{10}: 2 commits of history, nothing after the base')) "True"
    Check "the task repo keeps no refs/homelab-seal ref" @(git -C $repo for-each-ref refs/homelab-seal).Count 0
    Check "...and the base's bundle is cached for the next run" (Test-Path -LiteralPath (Join-Path $e2e "tests/.worktrees/.bundles/$shaB.bundle")) "True"

    Write-Host "-- second run"
    $r2 = Invoke-Run $r1.Probe.trialCommit
    Check "the first run's commit is unreachable" $r2.Probe.prevTrial "<none>"
    Check "...and the solution commit fetched for grading is gone again" $r2.Probe.solution "<none>"
    Check "...history is the base's again" $r2.Probe.commits 2
    Check "an ignored file (node_modules) survives the rebuild" $r2.Probe.ignoredKept "True"
    Check "the second run grades too" $r2.Json.acceptance.status "PASS"
} finally {
    Remove-Item Env:FX_SHA_C, Env:FX_PROBE, Env:FX_PREV -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

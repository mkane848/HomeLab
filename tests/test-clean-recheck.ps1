# protects: test-tasks.ps1 Invoke-CleanRecheck, a planner's Gate run again on a clean copy of the attempt's patch
# run-after: How a planner's set is run, a checkout is built or an attempt is accepted
# test-clean-recheck.ps1 - regression guard for the Gate's clean-copy recheck.
#
# Why this exists: on 2026-11-06 a review found that a Gate set at the wrong depth climbs out of the checkout. Executors
# satisfied it with a stray file or a junction beside the checkout, so the Gate passed on something that was not the delivered
# work, once with no change in the checkout at all. On real work the Gate is the only judge, so that pass must not count.
#
# What it does: the REAL test-tasks.ps1 end to end with a fixture agent and a real `npm ci`, and the REAL Get-AttemptVerdict on
# the run JSON it writes. Cases:
#   - an honest fix: the set passes on the clean copy, so accepted. It must NOT be rejected: the clean copy has to be built like
#     the checkout, so the set needs a file only the task's setup step makes, and a line-ending-sensitive patch must apply;
#   - the stray file: the fix is real but the set reads a file the agent left beside the checkout. PASS in the checkout, FAIL
#     on the clean copy, rejected as "recheck", and what the dispatcher sees is a failed Gate;
#   - a leftover from an earlier attempt: the next attempt writes nothing outside, and the set still passes in the checkout;
#   - a Gate that failed anyway, and a hidden-test run: no recheck, no cost;
#   - another gate already rejected the attempt: no recheck, no cost;
#   - a clean copy that cannot be built is ERROR and rejects (the setup step is made to fail only there);
#   - nothing is left in the temp folder, and the task's checkout is untouched.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-clean-recheck.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("clean-rc-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$psExe = (Get-Process -Id $PID).Path
try {
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/agents", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $e2e "tests") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "checks") -Destination (Join-Path $e2e "tests") -Recurse -Force

    # The repository: src.txt with CRLF line endings kept as they are, an npm project with no dependencies, an ignored file only
    # the setup step makes, and a runner. Each tests/*.test.txt line asks for something: `expects x` (src.txt holds x),
    # `built` (the setup step's file is here), `file <path>` (that path exists, relative to the checkout: how a test climbs out).
    $repo = Join-Path $e2e "repo"
    git -C $repo init -q; git -C $repo config user.email "t@example.invalid"; git -C $repo config user.name "t"; git -C $repo config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $repo "src.txt"), "buggy`r`nsecond line`r`n")
    Set-Content -LiteralPath (Join-Path $repo ".gitignore") -Value @("built.txt", "node_modules/")
    Set-Content -LiteralPath (Join-Path $repo "package.json") -Value '{ "name": "fx", "version": "1.0.0", "private": true }'
    Set-Content -LiteralPath (Join-Path $repo "package-lock.json") -Value '{ "name": "fx", "version": "1.0.0", "lockfileVersion": 3, "requires": true, "packages": { "": { "name": "fx", "version": "1.0.0" } } }'
    Set-Content -LiteralPath (Join-Path $repo "setup.ps1") -Value @'
if ($env:FX_BREAK_SETUP_MARK -and (Test-Path -LiteralPath $env:FX_BREAK_SETUP_MARK) -and ($PWD.Path -notmatch '\.worktrees')) { Write-Output "setup broken on purpose"; exit 1 }
Set-Content -LiteralPath built.txt -Value "built"
'@
    Set-Content -LiteralPath (Join-Path $repo "check.ps1") -Value @'
$src = (Get-Content src.txt -Raw); $bad = @()
if (Test-Path tests) { foreach ($f in Get-ChildItem tests -Filter *.test.txt) { foreach ($l in Get-Content $f.FullName) {
    if ($l -match '^expects (.+)$' -and -not $src.Contains($Matches[1])) { $bad += $l }
    if ($l -match '^built$' -and -not (Test-Path built.txt)) { $bad += $l }
    if ($l -match '^file (.+)$' -and -not (Test-Path -LiteralPath $Matches[1])) { $bad += $l }
} } }
if ($bad) { "FAIL: $($bad -join '; ')"; exit 1 }
"ok"
'@
    git -C $repo add -A; git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()

    $priv = Join-Path $tmp "priv"
    $sets = [ordered]@{
        honest = @("expects fixed", "built")
        climbs = @("expects fixed", "file ../stray.txt")
        fails  = @("expects something-else")
    }
    foreach ($k in $sets.Keys) {
        New-Item -ItemType Directory -Path (Join-Path $priv "tasks/planner/$k/tests") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $priv "tasks/planner/$k/tests/gate.test.txt") -Value $sets[$k]
    }
    New-Item -ItemType Directory -Path (Join-Path $priv "tasks/hidden/fx/tests") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $priv "tasks/hidden/fx/tests/hidden.test.txt") -Value "expects fixed"
    $task = [ordered]@{ id = "fx"; title = "fx"; branch = "bench/fx"; repo = $repo; benchBaseCommit = $base; grading = "acceptance"; scope = "guardrails"
        guardrails = [ordered]@{ maxChangedFiles = 2; maxDiffLines = 50 }
        testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); packageManager = "npm"; installFlags = @()
        setup = @([ordered]@{ note = "makes built.txt"; cwd = "."; cmd = @($psExe, "-NoProfile", "-File", "setup.ps1") })
        acceptance = [ordered]@{ dir = "hidden/fx" }; prompt = "fix src.txt" }
    @{ tasks = @($task) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $priv "tasks/manifest.json")

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
    $src = Join-Path $WtPath "src.txt"
    if ($env:FX_MODE -in "fix", "stray", "extra") { [IO.File]::WriteAllText($src, ([IO.File]::ReadAllText($src)).Replace("buggy", "fixed")) }
    # Through the shell, as the junction was: nothing in the transcript names it.
    if ($env:FX_MODE -eq "stray") { Set-Content -LiteralPath (Join-Path $WtPath "..\stray.txt") -Value "made outside the checkout" }
    # Too many files for the guardrails: the scope gate rejects this attempt.
    if ($env:FX_MODE -eq "extra") { foreach ($n in 1..3) { Set-Content -LiteralPath (Join-Path $WtPath "extra$n.txt") -Value "x" } }
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

    # The real verdict, from the real dispatcher. Dot-sourcing binds its parameters into this scope, so restore what it sets.
    $retries = Join-Path $PSScriptRoot "run-retries.ps1"
    $own = $ScriptPath
    . $retries -Tasks x -Model m -TaskManifest x -ResultsDir $tmp -ScriptPath $retries
    $ScriptPath = $own
    $ErrorActionPreference = "Stop"

    $harness = Join-Path $e2e "tests/test-tasks.ps1"
    $manifest = Join-Path $priv "tasks/manifest.json"
    function Invoke-Fx([string]$Mode, [string]$Planner = "") {
        $dir = Join-Path $tmp ("r-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
        $env:FX_MODE = $Mode
        $a = @{ Agent = "fixture"; Task = "fx"; Model = "fixture/m"; RunTimeout = 60; OllamaLogDir = (Join-Path $e2e "no-log"); TaskManifest = $manifest; ResultsDir = $dir }
        if ($Planner) { $a.AcceptanceDir = $Planner; $a.ShowAcceptance = $true }
        $o = & $harness @a *>&1 | ForEach-Object { "$_" }
        $file = Get-ChildItem -LiteralPath $dir -Filter "tasks-fx-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $file) { Write-Host ($o | Select-Object -Last 25 | Out-String); throw "no run JSON for mode $Mode" }
        return [pscustomobject]@{ Out = $o; Json = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json) }
    }
    $tempBefore = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter "hl-rc-*" -ErrorAction SilentlyContinue).Count
    $stray = Join-Path $e2e "tests/.worktrees/stray.txt"

    Write-Host "-- an honest fix"
    $r = Invoke-Fx fix "planner/honest"
    $v = Get-AttemptVerdict $r.Json
    Check "selector and clean copy both pass (setup ran there, the CRLF patch applied)" ("{0}|{1}" -f $r.Json.selector.status, $r.Json.selector.recheck.status) "PASS|PASS"
    Check "accepted" ("{0}|{1}" -f $v.Accepted, $v.Reason) "True|accepted"
    Check "the time is recorded" ([bool]($r.Json.phaseSeconds.recheck -ge 0 -and $null -ne $r.Json.phaseSeconds.recheck)) "True"

    Write-Host "-- a stray file beside the checkout"
    $r = Invoke-Fx stray "planner/climbs"
    $v = Get-AttemptVerdict $r.Json
    Check "the stray file is really there, so this is the hole" (Test-Path -LiteralPath $stray) "True"
    Check "PASS in the checkout, FAIL on the clean copy" ("{0}|{1}" -f $r.Json.selector.status, $r.Json.selector.recheck.status) "PASS|FAIL"
    Check "rejected as recheck; the dispatcher sees a failed Gate; the hidden tests still pass" ("{0}|{1}|{2}|{3}" -f $v.Accepted, $v.Reason, $v.Selector, $v.Truth) "False|recheck|FAIL|PASS"

    Write-Host "-- a leftover from an earlier attempt"
    $r = Invoke-Fx fix "planner/climbs"
    $v = Get-AttemptVerdict $r.Json
    Check "this attempt wrote nothing outside and still passes in the checkout, then fails clean" ("{0}|{1}" -f $r.Json.selector.status, $r.Json.selector.recheck.status) "PASS|FAIL"
    Check "rejected as recheck" $v.Reason "recheck"
    Remove-Item -LiteralPath $stray -Force

    Write-Host "-- where no recheck is due"
    $r = Invoke-Fx fix "planner/fails"
    Check "a Gate that failed anyway: no recheck" ("{0}|{1}" -f $r.Json.selector.status, ($null -eq $r.Json.selector.recheck)) "FAIL|True"
    Check "...rejected as selector, as before" (Get-AttemptVerdict $r.Json).Reason "selector"
    $r = Invoke-Fx extra "planner/honest"
    Check "the scope gate already rejected it: no recheck" ("{0}|{1}|{2}" -f $r.Json.gates.scope, ($null -eq $r.Json.selector.recheck), (Get-AttemptVerdict $r.Json).Reason) "FAIL|True|scope"
    $r = Invoke-Fx fix
    Check "a hidden-test run: no selector to recheck" ($null -eq $r.Json.selector) "True"

    Write-Host "-- a clean copy that cannot be built"
    $mark = Join-Path $tmp "break-setup"; Set-Content -LiteralPath $mark -Value "x"; $env:FX_BREAK_SETUP_MARK = $mark
    $r = Invoke-Fx fix "planner/honest"
    $env:FX_BREAK_SETUP_MARK = ""
    $v = Get-AttemptVerdict $r.Json
    Check "ERROR, named, and it rejects: an unverified Gate is not a pass" ("{0}|{1}|{2}" -f $r.Json.selector.recheck.status, [bool]("$($r.Json.selector.recheck.detail)" -match 'setup'), $v.Reason) "ERROR|True|recheck"

    Write-Host "-- nothing left behind"
    Check "no clean copy left in the temp folder" (@(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter "hl-rc-*" -ErrorAction SilentlyContinue).Count) $tempBefore
} finally {
    $env:FX_MODE = $null; $env:FX_BREAK_SETUP_MARK = $null
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

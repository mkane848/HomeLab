# protects: -ShowAcceptance / -ReadOnlyAcceptance / -ShownPrompt / -AcceptanceDir (planner's tests) modes
# run-after: How acceptance tests are placed, a run is prompted or scope is graded
# test-show-acceptance.ps1 - regression guard for test-tasks.ps1 -ShowAcceptance (milestone 3).
#
# Why this exists: in real use there are no hidden tests. A planner writes the
# failing test and the executor makes it pass, so the given test is the only gate
# a dispatcher could select on (docs/target-setup.md -> "Milestones" 3 and 4).
# -ShowAcceptance gives the model the task's acceptance.dir tests before its run,
# names them in the prompt, fails the run if it edits them, and then grades exactly
# as a hidden-test run does. Its rows must never mix with hidden-test rows.
#
# What it does: the REAL test-tasks.ps1 end to end, with a private manifest whose
# task has hidden tests in a folder outside the fixture repo, and a fixture agent
# that records what it sees (the test file present? the prompt naming it?). Cases:
#   - shown, the agent fixes the source: the test is there before the run and
#     named in the prompt; graded PASS; the scope sees only the source change;
#     the run JSON records acceptanceShown (files, hash, nothing tampered); the
#     test is gone from the checkout afterwards; no row in the public mirror;
#   - shown, the agent edits the test instead: scope FAIL naming the file;
#     `tampered` records it;
#   - shown, the given test replaces one the base had, which asserts the old
#     behaviour: the suite runs with the given test in its place and passes, and
#     the base's copy is back afterwards (wp-0a and wp-5a, 2026-10-22: a correct
#     fix failed the suite on the stale copy);
#   - -ReadOnlyAcceptance (the tamper control): the given test is read-only
#     during the run; a fix passes and is recorded as read-only; a plain write to
#     the test is refused (nothing tampered); clearing the attribute and editing
#     is tampered and named in readOnlyCleared; the stale-base case still passes;
#     the switch alone, and mixing read-only and writable shown rows, are refused;
#   - -ShownPrompt: the default wording (2) tells the model the given files are the finished tests
#     the task asks for; 1 is milestone 3's; each is recorded and hashed;
#   - hidden (no switch), the same agent: the test is absent and not named;
#   - a task with no acceptance.dir: refused with a FAIL, the agent never called;
#   - the folders: a shown run into tests/results, or into a folder that holds
#     hidden-test rows, is refused; a hidden run into a marked folder is refused;
#     the ACCEPTANCE-SHOWN marker is written.
#   - -AcceptanceDir (experiment 3, docs/planner-tests-experiment.md): a planner's tests are shown instead of the
#     task's own, the hidden tests still grade. The run JSON records `selector` (the planner set's verdict, source
#     "planner") beside `acceptance` (the hidden tests', the truth) and `plannerSet` (folder, hash); a wrong fix
#     the set lets through is a false positive, a right fix it turns away a false negative; editing the planner's
#     file is tampered; with the task's own tests shown the selector is those tests (source "hidden"); a hidden
#     run has none; the folder rules (own folder, ACCEPTANCE-PLANNER marker, needs -ShowAcceptance); a missing or
#     empty set is refused; -DryRun checks the set (fails on base, passes on acceptance.solution) into
#     planner-sets.tsv: valid, invalid (two ways), unchecked (no solution named).
# Exit 1 on any failure.
#
# Usage:  .\tests\test-show-acceptance.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("show-acc-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$psExe = (Get-Process -Id $PID).Path
try {
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/agents", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $e2e "tests") -Recurse -Force
    $repo = Join-Path $e2e "repo"
    git -C $repo init -q; git -C $repo config user.email "t@example.invalid"; git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    'if ((Test-Path tests/hidden.test.txt) -and (Get-Content tests/hidden.test.txt -Raw).Contains("expects fixed") -and (Get-Content src.txt -Raw).Trim() -ne "fixed") { Write-Host "Tests  1 failed (2)"; exit 1 }; Write-Host "Tests  2 passed (2)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A; git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    # A second repo whose base already has the test file the task's acceptance
    # folder replaces, asserting the old behaviour (wp-0a, wp-5a): every test file
    # reads "expects <x>" and needs src.txt to be <x>.
    $repo2 = Join-Path $e2e "repo2"
    New-Item -ItemType Directory -Path (Join-Path $repo2 "tests") -Force | Out-Null
    git -C $repo2 init -q; git -C $repo2 config user.email "t@example.invalid"; git -C $repo2 config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo2 "src.txt") -Value "buggy"
    Set-Content -LiteralPath (Join-Path $repo2 "tests/hidden.test.txt") -Value "expects buggy"
    '$src = (Get-Content src.txt -Raw).Trim(); $bad = @(Get-ChildItem tests -Filter *.test.txt | Where-Object { (Get-Content $_.FullName -Raw).Trim() -ne "expects $src" }); if ($bad) { Write-Host "Tests  $($bad.Count) failed ($($bad.Name -join ","))"; exit 1 }; Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo2 "check.ps1")
    git -C $repo2 add -A; git -C $repo2 commit -q -m base
    $base2 = (git -C $repo2 rev-parse HEAD).Trim()

    # A third repo for -AcceptanceDir: every tests/*.test.txt line is "expects <x>" (src.txt must be <x>) or
    # "expects-not <x>"; a solution commit sets src.txt to "fixed".
    $repo3 = Join-Path $e2e "repo3"
    New-Item -ItemType Directory -Path $repo3 -Force | Out-Null
    git -C $repo3 init -q; git -C $repo3 config user.email "t@example.invalid"; git -C $repo3 config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo3 "src.txt") -Value "buggy"
    '$src = (Get-Content src.txt -Raw).Trim(); $bad = @(); if (Test-Path tests) { foreach ($f in Get-ChildItem tests -Filter *.test.txt) { $l = (Get-Content $f.FullName -Raw).Trim(); $ok = if ($l -match "^expects-not (.+)$") { $src -ne $Matches[1] } elseif ($l -match "^expects (.+)$") { $src -eq $Matches[1] } else { $false }; if (-not $ok) { $bad += $f.Name } } }; if ($bad) { Write-Host "Tests  $($bad.Count) failed ($($bad -join ","))"; exit 1 }; Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo3 "check.ps1")
    git -C $repo3 add -A; git -C $repo3 commit -q -m base
    $base3 = (git -C $repo3 rev-parse HEAD).Trim()
    Set-Content -LiteralPath (Join-Path $repo3 "src.txt") -Value "fixed"
    git -C $repo3 commit -q -am solution
    $sol3 = (git -C $repo3 rev-parse HEAD).Trim()

    # The private side: a manifest outside the repo and the hidden tests beside it.
    $priv = Join-Path $tmp "priv"
    New-Item -ItemType Directory -Path (Join-Path $priv "tasks/hidden/fx/tests") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $priv "tasks/hidden/fx/tests/hidden.test.txt") -Value "expects fixed"
    $common = [ordered]@{ repo = $repo; benchBaseCommit = $base; grading = "acceptance"; scope = "guardrails"
        testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @(); prompt = "fix src.txt" }
    $t1 = [ordered]@{ id = "fx-shown"; title = "fx"; branch = "bench/fx-shown"; acceptance = [ordered]@{ dir = "hidden/fx" } } + $common
    $t2 = [ordered]@{ id = "fx-noacc"; title = "fx"; branch = "bench/fx-noacc" } + $common
    New-Item -ItemType Directory -Path (Join-Path $priv "tasks/hidden/fx2/tests") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $priv "tasks/hidden/fx2/tests/hidden.test.txt") -Value "expects fixed"
    $t3 = [ordered]@{ id = "fx-stale"; title = "fx"; branch = "bench/fx-stale"; acceptance = [ordered]@{ dir = "hidden/fx2" } } + $common
    $t3.repo = $repo2; $t3.benchBaseCommit = $base2
    # Experiment 3: the hidden tests want "fixed"; the planner's sets are beside them (relative to the manifest folder).
    New-Item -ItemType Directory -Path (Join-Path $priv "tasks/hidden/fx3/tests") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $priv "tasks/hidden/fx3/tests/hidden.test.txt") -Value "expects fixed"
    $plannerSets = [ordered]@{ good = "expects fixed"; lax = "expects-not nothing"; strict = "expects fixedplus" }
    foreach ($k in $plannerSets.Keys) {
        New-Item -ItemType Directory -Path (Join-Path $priv "tasks/planner/fx-plan/$k/tests") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $priv "tasks/planner/fx-plan/$k/tests/planner.test.txt") -Value $plannerSets[$k]
    }
    New-Item -ItemType Directory -Path (Join-Path $priv "tasks/planner/fx-plan/nothing") -Force | Out-Null
    $t4 = [ordered]@{ id = "fx-plan"; title = "fx"; branch = "bench/fx-plan"; acceptance = [ordered]@{ dir = "hidden/fx3"; solution = $sol3 } } + $common
    $t4.repo = $repo3; $t4.benchBaseCommit = $base3
    $t5 = [ordered]@{ id = "fx-plan-nosol"; title = "fx"; branch = "bench/fx-plan-nosol"; acceptance = [ordered]@{ dir = "hidden/fx3" } } + $common
    $t5.repo = $repo3; $t5.benchBaseCommit = $base3
    @{ tasks = @($t1, $t2, $t3, $t4, $t5) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $priv "tasks/manifest.json")

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
    $test = Join-Path $WtPath "tests\hidden.test.txt"
    [ordered]@{ testPresent = (Test-Path -LiteralPath $test); promptNamesIt = $Prompt.Contains("tests/hidden.test.txt"); testReadOnly = ((Test-Path -LiteralPath $test) -and (Get-Item -LiteralPath $test).IsReadOnly); promptReconciles = $Prompt.Contains("They are the finished tests for this task"); plannerPresent = (Test-Path -LiteralPath (Join-Path $WtPath "tests\planner.test.txt")); promptNamesPlanner = $Prompt.Contains("tests/planner.test.txt") } | ConvertTo-Json | Set-Content -LiteralPath $env:FX_PROBE
    # tamper: a plain write to the given test (fails when it is read-only); unlock: clear the attribute first, then write.
    if ($env:FX_MODE -eq "tamper") { try { Set-Content -LiteralPath $test -Value "expects nothing" -ErrorAction Stop } catch { } }
    elseif ($env:FX_MODE -eq "wrong") { Set-Content -LiteralPath (Join-Path $WtPath "src.txt") -Value "wrong" }
    elseif ($env:FX_MODE -eq "tamper-planner") { Set-Content -LiteralPath (Join-Path $WtPath "tests\planner.test.txt") -Value "expects-not nothing" }
    elseif ($env:FX_MODE -eq "unlock") { (Get-Item -LiteralPath $test).IsReadOnly = $false; Set-Content -LiteralPath $test -Value "expects nothing" }
    else { Set-Content -LiteralPath (Join-Path $WtPath "src.txt") -Value "fixed" }
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
    $manifest = Join-Path $priv "tasks/manifest.json"
    function Invoke-Fx([string]$TaskId, [string]$Dir, [string]$Mode, [switch]$Show, [switch]$ReadOnly, [int]$PromptVersion = 0, [string]$Planner = "", [switch]$Dry) {
        $env:FX_PROBE = Join-Path $tmp ("probe-" + [guid]::NewGuid().ToString("N") + ".json"); $env:FX_MODE = $Mode
        $a = @{ Agent = "fixture"; Task = $TaskId; Model = "fixture/m"; SkipInstall = $true; RunTimeout = 60; OllamaLogDir = (Join-Path $e2e "no-log"); TaskManifest = $manifest; ResultsDir = $Dir }
        if ($Show) { $a.ShowAcceptance = $true }
        if ($ReadOnly) { $a.ReadOnlyAcceptance = $true }
        if ($PromptVersion) { $a.ShownPrompt = $PromptVersion }
        if ($Planner) { $a.AcceptanceDir = $Planner }
        if ($Dry) { $a.DryRun = $true }
        $log = & $harness @a *>&1 | Out-String
        $exit = $LASTEXITCODE
        $probe = if (Test-Path -LiteralPath $env:FX_PROBE) { Get-Content -Raw -LiteralPath $env:FX_PROBE | ConvertFrom-Json } else { $null }
        $json = Get-ChildItem -LiteralPath $Dir -Filter "tasks-$TaskId-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        $j = if ($json) { Get-Content -Raw -LiteralPath $json.FullName | ConvertFrom-Json } else { $null }
        if ($json) { Remove-Item -LiteralPath $json.FullName }
        return [pscustomobject]@{ Log = $log; Exit = $exit; Probe = $probe; Json = $j }
    }
    $shownDir = Join-Path $priv "results/shown"
    $wt = Join-Path $e2e "tests/.worktrees/fx-shown"

    Write-Host "-- shown, the agent fixes the source"
    $r = Invoke-Fx fx-shown $shownDir fix -Show
    if (-not $r.Json) { Write-Host (($r.Log -split "`n" | Select-Object -Last 25) -join "`n") }
    Check "the test is in the checkout before the run, and the prompt names it" ("{0}|{1}" -f $r.Probe.testPresent, $r.Probe.promptNamesIt) "True|True"
    Check "graded on the hidden-test path: acceptance PASS" $r.Json.acceptance.status "PASS"
    Check "...the scope sees only the source change" ("{0}|{1}" -f $r.Json.gates.scope, ($r.Json.scopeDetail.files -join ",")) "PASS|src.txt"
    Check "the run JSON records what was shown, nothing tampered" ("{0}|{1}|{2}" -f ($r.Json.acceptanceShown.files -join ","), ($r.Json.acceptanceShown.hash.Length), @($r.Json.acceptanceShown.tampered).Count) "tests/hidden.test.txt|12|0"
    Check "the given test is not left in the checkout" (Test-Path -LiteralPath (Join-Path $wt "tests/hidden.test.txt")) "False"
    Check "the folder is marked ACCEPTANCE-SHOWN" (Test-Path -LiteralPath (Join-Path $shownDir "ACCEPTANCE-SHOWN")) "True"
    $pub = Join-Path $e2e "tests/results/real-tasks-public.tsv"
    Check "no row in the public mirror" $(if (Test-Path -LiteralPath $pub) { @(Get-Content -LiteralPath $pub | Select-Object -Skip 1).Count } else { 0 }) 0

    Write-Host "-- shown, the agent edits the test instead"
    $r = Invoke-Fx fx-shown $shownDir tamper -Show
    Check "scope FAIL naming the test" ([bool]($r.Log -match 'FAIL\] scope \(acceptance tests left alone\)' -and $r.Log -match 'tests/hidden\.test\.txt \(edited\)')) "True"
    Check "...recorded as tampered, and the gate fails" ("{0}|{1}" -f ($r.Json.acceptanceShown.tampered -join ","), $r.Json.gates.scope) "tests/hidden.test.txt (edited)|FAIL"
    Check "...and the real hidden test still grades the unfixed source FAIL" $r.Json.acceptance.status "FAIL"

    Write-Host "-- shown, replacing a test the base had (stale there), the agent fixes the source"
    $r = Invoke-Fx fx-stale $shownDir fix -Show
    if (-not $r.Json) { Write-Host (($r.Log -split "`n" | Select-Object -Last 25) -join "`n") }
    Check "the suite runs with the given test in place of the base's stale copy: PASS" $r.Json.gates.suite "PASS"
    Check "...acceptance PASS, the scope sees only the source change" ("{0}|{1}|{2}" -f $r.Json.acceptance.status, $r.Json.gates.scope, ($r.Json.scopeDetail.files -join ",")) "PASS|PASS|src.txt"
    Check "...and the base's copy is back in the checkout afterwards" ((Get-Content -Raw -LiteralPath (Join-Path $e2e "tests/.worktrees/fx-stale/tests/hidden.test.txt")).Trim()) "expects buggy"

    Write-Host "-- hidden (no switch), the same agent"
    $hiddenDir = Join-Path $priv "results/hidden"
    $r = Invoke-Fx fx-shown $hiddenDir fix
    Check "the test is absent and not named" ("{0}|{1}" -f $r.Probe.testPresent, $r.Probe.promptNamesIt) "False|False"
    Check "...graded PASS, nothing recorded as shown" ("{0}|{1}" -f $r.Json.acceptance.status, ($null -eq $r.Json.acceptanceShown)) "PASS|True"

    Write-Host "-- a task with no acceptance.dir"
    $r = Invoke-Fx fx-noacc (Join-Path $priv "results/shown2") fix -Show
    Check "refused with a FAIL, the agent never called" ("{0}|{1}" -f [bool]($r.Log -match '-ShowAcceptance needs a task whose acceptance tests are an acceptance.dir folder'), ($null -eq $r.Probe)) "True|True"

    Write-Host "-- the folders"
    $r = Invoke-Fx fx-shown (Join-Path $e2e "tests/results") fix -Show
    Check "a shown run into tests/results is refused before any work (the private-manifest rule or its own)" ("{0}|{1}|{2}" -f $r.Exit, [bool]($r.Log -match 'must not join|outside this repo'), ($null -eq $r.Probe)) "1|True|True"
    $r = Invoke-Fx fx-shown $hiddenDir fix -Show
    Check "a shown run into a folder of hidden-test rows is refused" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'need a results folder of their own')) "1|True"
    $r = Invoke-Fx fx-shown $shownDir fix
    Check "a hidden run into a marked folder is refused" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'were shown their acceptance tests')) "1|True"

    Write-Host "-- read-only given tests (-ReadOnlyAcceptance), the agent fixes the source"
    $roDir = Join-Path $priv "results/readonly"
    $r = Invoke-Fx fx-shown $roDir fix -Show -ReadOnly
    if (-not $r.Json) { Write-Host (($r.Log -split "`n" | Select-Object -Last 25) -join "`n") }
    Check "the test is there and read-only during the run" ("{0}|{1}" -f $r.Probe.testPresent, $r.Probe.testReadOnly) "True|True"
    Check "...graded PASS, recorded as read-only, nothing cleared or tampered" ("{0}|{1}|{2}|{3}" -f $r.Json.acceptance.status, $r.Json.acceptanceShown.readOnly, @($r.Json.acceptanceShown.readOnlyCleared).Count, @($r.Json.acceptanceShown.tampered).Count) "PASS|True|0|0"
    Check "...the test is gone afterwards, the folder marked ACCEPTANCE-READONLY" ("{0}|{1}" -f (Test-Path -LiteralPath (Join-Path $wt "tests/hidden.test.txt")), (Test-Path -LiteralPath (Join-Path $roDir "ACCEPTANCE-READONLY"))) "False|True"
    Write-Host "-- read-only, the agent tries a plain write to the test"
    $r = Invoke-Fx fx-shown $roDir tamper -Show -ReadOnly
    Check "the write is refused: nothing tampered, no tamper FAIL, the unfixed source FAILs acceptance" ("{0}|{1}|{2}" -f @($r.Json.acceptanceShown.tampered).Count, [bool]($r.Log -match 'acceptance tests left alone'), $r.Json.acceptance.status) "0|False|FAIL"
    Write-Host "-- read-only, the agent clears the attribute and edits the test"
    $r = Invoke-Fx fx-shown $roDir unlock -Show -ReadOnly
    Check "tampered, readOnlyCleared names the file, scope FAIL, a WARN" ("{0}|{1}|{2}|{3}" -f ($r.Json.acceptanceShown.tampered -join ","), ($r.Json.acceptanceShown.readOnlyCleared -join ","), $r.Json.gates.scope, [bool]($r.Log -match 'WARN\] acceptance read-only')) "tests/hidden.test.txt (edited)|tests/hidden.test.txt|FAIL|True"
    Write-Host "-- read-only, replacing a test the base had"
    $r = Invoke-Fx fx-stale $roDir fix -Show -ReadOnly
    Check "the suite still runs on the given test: PASS, the base's copy back afterwards" ("{0}|{1}|{2}" -f $r.Json.gates.suite, $r.Json.acceptance.status, (Get-Content -Raw -LiteralPath (Join-Path $e2e "tests/.worktrees/fx-stale/tests/hidden.test.txt")).Trim()) "PASS|PASS|expects buggy"
    Write-Host "-- read-only refusals"
    $r = Invoke-Fx fx-shown (Join-Path $priv "results/ro-alone") fix -ReadOnly
    Check "-ReadOnlyAcceptance without -ShowAcceptance is refused" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'it needs -ShowAcceptance')) "1|True"
    $r = Invoke-Fx fx-shown $shownDir fix -Show -ReadOnly
    Check "a read-only run into a folder of writable shown rows is refused" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'rows whose given tests were writable')) "1|True"
    $r = Invoke-Fx fx-shown $roDir fix -Show
    Check "a writable shown run into a read-only folder is refused" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'given tests were read-only')) "1|True"

    Write-Host "-- the shown prompt's wording (-ShownPrompt)"
    $pDir = Join-Path $priv "results/shown-prompt"
    $r = Invoke-Fx fx-shown $pDir fix -Show
    Check "default (2): the prompt says the given files are the finished tests, recorded as 2" ("{0}|{1}" -f $r.Probe.promptReconciles, $r.Json.acceptanceShown.prompt) "True|2"
    $h2 = $r.Json.promptSha256
    $r = Invoke-Fx fx-shown $pDir fix -Show -PromptVersion 1
    Check "-ShownPrompt 1: milestone 3's wording, recorded as 1, a different prompt hash" ("{0}|{1}|{2}" -f $r.Probe.promptReconciles, $r.Json.acceptanceShown.prompt, ($r.Json.promptSha256 -ne $h2)) "False|1|True"
    Write-Host "-- a planner's tests shown (-AcceptanceDir): the selector decides, the hidden tests are the truth"
    $plDir = Join-Path $priv "results/planner"
    $r = Invoke-Fx fx-plan $plDir fix -Show -Planner "planner/fx-plan/good"
    $wt3 = Join-Path $e2e "tests/.worktrees/fx-plan"
    Check "a right fix against a good set: selector and hidden tests PASS, source planner" ("{0}|{1}|{2}|{3}" -f $r.Json.selector.status, $r.Json.selector.source, $r.Json.acceptance.status, $r.Json.selector.set) "PASS|planner|PASS|planner/fx-plan/good"
    Check "the model saw the planner's test, named in the prompt, and not the hidden one" ("{0}|{1}|{2}" -f $r.Probe.plannerPresent, $r.Probe.promptNamesPlanner, $r.Probe.testPresent) "True|True|False"
    Check "plannerSet records the folder and the set's hash, the same hash as the selector's" ("{0}|{1}" -f $r.Json.plannerSet.folder, ($r.Json.plannerSet.hash -and $r.Json.plannerSet.hash -eq $r.Json.selector.hash)) "planner/fx-plan/good|True"
    Check "scope sees only the source change; nothing tampered" ("{0}|{1}" -f $r.Json.gates.scope, @($r.Json.acceptanceShown.tampered).Count) "PASS|0"
    Check "the planner's test is gone from the checkout afterwards" (Test-Path -LiteralPath (Join-Path $wt3 "tests/planner.test.txt")) "False"
    Check "the folder is marked ACCEPTANCE-PLANNER (and ACCEPTANCE-SHOWN)" ("{0}|{1}" -f (Test-Path -LiteralPath (Join-Path $plDir "ACCEPTANCE-PLANNER")), (Test-Path -LiteralPath (Join-Path $plDir "ACCEPTANCE-SHOWN"))) "True|True"

    Write-Host "-- a lax set lets wrong code through (false positive); a strict one turns right code away (false negative)"
    $r = Invoke-Fx fx-plan $plDir wrong -Show -Planner "planner/fx-plan/lax"
    Check "wrong code, lax set: selector PASS, hidden tests FAIL" ("{0}|{1}" -f $r.Json.selector.status, $r.Json.acceptance.status) "PASS|FAIL"
    $r = Invoke-Fx fx-plan $plDir fix -Show -Planner "planner/fx-plan/strict"
    Check "right code, strict set: selector FAIL, hidden tests PASS" ("{0}|{1}" -f $r.Json.selector.status, $r.Json.acceptance.status) "FAIL|PASS"
    Check "a selector that does not pass is a warning in the log, not a failure of the harness" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'selector.*WARN|WARN.*selector')) "0|True"

    Write-Host "-- editing the planner's file is tampering"
    $r = Invoke-Fx fx-plan $plDir tamper-planner -Show -Planner "planner/fx-plan/good"
    Check "scope FAIL naming the file, recorded in tampered" ("{0}|{1}" -f $r.Json.gates.scope, (@($r.Json.acceptanceShown.tampered) -join ",")) "FAIL|tests/planner.test.txt (edited)"

    Write-Host "-- the task's own tests shown, and a hidden run"
    $orDir = Join-Path $priv "results/oracle3"
    $r = Invoke-Fx fx-plan $orDir fix -Show
    Check "oracle-shown: the selector is the hidden tests' verdict, source hidden, no plannerSet" ("{0}|{1}|{2}" -f $r.Json.selector.status, $r.Json.selector.source, ($null -eq $r.Json.plannerSet)) "PASS|hidden|True"
    $hdDir = Join-Path $priv "results/hidden3"
    $r = Invoke-Fx fx-plan $hdDir fix
    Check "a hidden-test run has no selector and no plannerSet" ("{0}|{1}" -f ($null -eq $r.Json.selector), ($null -eq $r.Json.plannerSet)) "True|True"

    Write-Host "-- the folder rules"
    $r = Invoke-Fx fx-plan (Join-Path $priv "results/planner-alone") fix -Planner "planner/fx-plan/good"
    Check "-AcceptanceDir without -ShowAcceptance is refused, the agent never called" ("{0}|{1}|{2}" -f $r.Exit, [bool]($r.Log -match 'needs -ShowAcceptance'), ($null -eq $r.Probe)) "1|True|True"
    $r = Invoke-Fx fx-plan $orDir fix -Show -Planner "planner/fx-plan/good"
    Check "a planner run into a folder of the task's own shown rows is refused" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'not a planner')) "1|True"
    $r = Invoke-Fx fx-plan $plDir fix -Show
    Check "a non-planner shown run into a planner folder is refused" ("{0}|{1}" -f $r.Exit, [bool]($r.Log -match 'were a planner')) "1|True"
    $r = Invoke-Fx fx-plan (Join-Path $priv "results/planner-missing") fix -Show -Planner "planner/fx-plan/absent"
    Check "a set whose folder is missing is refused before the model runs" ("{0}|{1}" -f $r.Exit, ($null -eq $r.Probe)) "1|True"
    $r = Invoke-Fx fx-plan (Join-Path $priv "results/planner-empty") fix -Show -Planner "planner/fx-plan/nothing"
    Check "a set with no files is refused naming the folder" ("{0}|{1}|{2}" -f $r.Exit, [bool]($r.Log -match 'holds no files'), ($null -eq $r.Probe)) "1|True|True"

    Write-Host "-- -DryRun checks the set: fails on the base, passes on the solution"
    $dryDir = Join-Path $priv "results/dry"
    $null = Invoke-Fx fx-plan $dryDir fix -Dry -Planner "planner/fx-plan/good"
    $null = Invoke-Fx fx-plan $dryDir fix -Dry -Planner "planner/fx-plan/lax"
    $null = Invoke-Fx fx-plan $dryDir fix -Dry -Planner "planner/fx-plan/strict"
    $null = Invoke-Fx fx-plan-nosol $dryDir fix -Dry -Planner "planner/fx-plan/good"
    $rows = @(Import-Csv -Delimiter "`t" -LiteralPath (Join-Path $dryDir "planner-sets.tsv"))
    Check "four rows, one per check" $rows.Count 4
    Check "good: fails on base, passes on the solution: valid" ("{0}|{1}|{2}" -f $rows[0].base, $rows[0].solution, $rows[0].valid) "FAIL|PASS|valid"
    Check "lax: passes on the base: invalid" ("{0}|{1}" -f $rows[1].base, $rows[1].valid) "PASS|invalid"
    Check "strict: fails on the solution too: invalid" ("{0}|{1}|{2}" -f $rows[2].base, $rows[2].solution, $rows[2].valid) "FAIL|FAIL|invalid"
    Check "no acceptance.solution named: unchecked" ("{0}|{1}|{2}" -f $rows[3].task, $rows[3].solution, $rows[3].valid) "fx-plan-nosol|unchecked|unchecked"
    Check "the rows name the set and its hash" ("{0}|{1}" -f $rows[0].set, [bool]$rows[0].hash) "planner/fx-plan/good|True"
    Check "a dry run writes no marker of an arm it did not run" (Test-Path -LiteralPath (Join-Path $dryDir "ACCEPTANCE-PLANNER")) "False"
} finally {
    Remove-Item Env:FX_PROBE, Env:FX_MODE -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

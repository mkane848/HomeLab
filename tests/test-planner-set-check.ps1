# protects: the check of a planner's set BEFORE USE, with no solution: test-tasks.ps1's Get-PlannerSetUsability on real vitest 2.1.9 and 5.0.1 output, -DryRun -SetCheckOnly (no hidden tests, no solution), and run-planner-local.ps1's one follow-up for a set that is not usable
# run-after: tests/test-tasks.ps1 (Get-PlannerSetUsability, Get-VitestFilters, -SetCheckOnly), desktop/scripts/run-planner-local.ps1 (-CheckManifest), a new vitest version in a task repo
# mutation: tests/test-tasks.ps1
# mutation-from: $notLoaded = @($relOf.Keys | Where-Object { (& $lineFor $relOf[$_] $loadPattern) -ge 0 })
# mutation-to: $notLoaded = @()
# mutation-expect: FAIL\s+vitest 5\.0\.1, a missing import: not-loaded
# mutation: tests/test-tasks.ps1
# mutation-from: if ($null -ne $filters -and $filters.Count) {
# mutation-to: if ($false) {
# mutation-expect: FAIL\s+vitest 5\.0\.1, a test file the command does not run: not-found
# mutation: tests/test-tasks.ps1
# mutation-from:             if ($SetCheckOnly) {
# mutation-to:             if ($false) {
# mutation-expect: FAIL\s+-SetCheckOnly: no solution is checked
# mutation: desktop/scripts/run-planner-local.ps1
# mutation-from: for ($n = 1; $n -le $Retries -and $c.Verdict -ne "ok"; $n++) {
# mutation-to: for ($n = 1; $n -le 0; $n++) {
# mutation-expect: FAIL\s+a set that does not load gets one follow-up
# test-planner-set-check.ps1 - regression guard for checking a planner's test set before an executor uses it.
#
# Why this exists: a planner's set that does not load, or that the task's test command never runs, reached the executor
# and blocked good work, or let wrong work through on a Gate that checked nothing (docs/planner-tests-experiment.md,
# "What to change", item 3: 3 of 9 sets in the fix-1 live run did not load). A dispatcher in real use has no solution to
# check a set against, so this check uses none: the set goes on the untouched base once, and that one run must show
# every test file loaded, run by the command, and failing.
# What it does:
#   - Get-PlannerSetUsability on the REAL output of vitest 2.1.9 and 5.0.1 (tests/fixtures/vitest-planner-sets, made by
#     the recipe in its README): a set that fails on the base is ok; one that passes, or fails only outside its own files,
#     is not; a missing import and a syntax error are not-loaded; a file the command's path filter skips is not-found.
#     Also: no test file, a file outside testDir, an ERROR, a non-vitest command (not judged by filter), colour codes.
#   - Get-VitestFilters on the task manifest's command shapes.
#   - test-tasks.ps1 -DryRun -SetCheckOnly end to end, on a throwaway repo whose stand-in test command prints vitest's
#     lines: the verdict JSON for an ok, a not-loaded and a not-found set; no hidden test and no solution is run, and no
#     planner-sets.tsv row; -SetCheckOnly without -DryRun is refused; a plain -DryRun -AcceptanceDir still checks the
#     solution and now also prints the verdict.
#   - run-planner-local.ps1: Invoke-PlannerSetGate (an ok set: one check, no follow-up; a set that does not load: one
#     follow-up carrying the check's words, then a second check; still not usable: two attempts, not usable; -SetRetries
#     0: no follow-up), Get-SetCheckFeedback (says what to fix, names no hidden test or solution), and
#     Invoke-PlannerSetCheck against a stand-in harness (the arguments it passes; a harness that writes no verdict).
#
# Usage:  pwsh -NoProfile -File tests/test-planner-set-check.ps1
$ErrorActionPreference = "Stop"
$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")

$repoRoot = Split-Path $PSScriptRoot -Parent
$harnessPath = Join-Path $PSScriptRoot "test-tasks.ps1"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref]$null, [ref]$errs)
if ($errs.Count) { Write-Host "FAIL test-tasks.ps1 does not parse: $($errs[0].Message)"; exit 2 }
foreach ($w in @("Remove-AnsiCodes", "Get-VitestFilters", "Get-PlannerSetUsability")) {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $w }, $true) | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL $w not found in test-tasks.ps1"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}

Write-Host "-- Get-VitestFilters"
Check "npx vitest run <file>" ((Get-VitestFilters @("npx", "vitest", "run", "src/routes/combat.test.ts")) -join "|") "src/routes/combat.test.ts"
Check "pnpm exec vitest run <file>" ((Get-VitestFilters @("pnpm", "exec", "vitest", "run", "src/a.test.ts")) -join "|") "src/a.test.ts"
Check "several files" ((Get-VitestFilters @("npx", "vitest", "run", "tests/a.test.ts", "tests/b.test.ts")) -join "|") "tests/a.test.ts|tests/b.test.ts"
$none = Get-VitestFilters @("npx", "vitest", "run")
Check "no file: every file it includes (empty, not null)" ("{0}|{1}" -f ($null -eq $none), $none.Count) "False|0"
Check "a flag's value is not a filter" ((Get-VitestFilters @("npx", "vitest", "run", "--project", "server", "--reporter=dot", "./src/x.test.ts")) -join "|") "src/x.test.ts"
Check "not a vitest command: null (cannot judge)" ($null -eq (Get-VitestFilters @("npm", "test"))) "True"

Write-Host "-- Get-PlannerSetUsability on real vitest output"
$fx = Join-Path $PSScriptRoot "fixtures/vitest-planner-sets"
$filtered = @("npx", "vitest", "run", "src/sum.test.js"); $all = @("npx", "vitest", "run")
$cases = @(
    @{ Name = "ok"; File = "src/sum.test.js"; Cmd = $filtered; Label = "a set that fails on the base"; Want = "ok" },
    @{ Name = "passes"; File = "src/sum.test.js"; Cmd = $filtered; Label = "a set that passes on the base"; Want = "passes-on-base" },
    @{ Name = "missing-import"; File = "src/sum.test.js"; Cmd = $filtered; Label = "a missing import"; Want = "not-loaded" },
    @{ Name = "syntax"; File = "src/sum.test.js"; Cmd = $filtered; Label = "a syntax error"; Want = "not-loaded" },
    @{ Name = "not-run"; File = "src/sum-three.test.js"; Cmd = $filtered; Label = "a test file the command does not run"; Want = "not-found" },
    @{ Name = "all-ok"; File = "src/sum-three.test.js"; Cmd = $all; Label = "a new file, no filter, failing"; Want = "ok" },
    @{ Name = "all-missing"; File = "src/mul.test.js"; Cmd = $all; Label = "a new file, no filter, a missing import"; Want = "not-loaded" },
    @{ Name = "elsewhere"; File = "src/sum-two.test.js"; Cmd = $all; Label = "the base fails, but not in the set"; Want = "fails-elsewhere" }
)
foreach ($v in @("2.1.9", "5.0.1")) {
    foreach ($c in $cases) {
        $out = @(Get-Content -LiteralPath (Join-Path $fx "v$v-$($c.Name).txt"))
        $st = if (($out[-1] -replace '^exit=', '') -eq "0") { "PASS" } else { "FAIL" }
        $r = Get-PlannerSetUsability -Status $st -Detail "Tests ..." -Output $out -SetFiles @("apps/x/$($c.File)", "apps/x/src/helper.js") -TestCmd $c.Cmd -TestDir "apps/x"
        Check "vitest $v, $($c.Label): $($c.Want)" $r.Verdict $c.Want
    }
}
$r = Get-PlannerSetUsability -Status FAIL -Output @(Get-Content (Join-Path $fx "v5.0.1-missing-import.txt")) -SetFiles @("apps/x/src/sum.test.js") -TestCmd $filtered -TestDir "apps/x"
Check "not-loaded quotes vitest's error" ([bool]($r.Detail -match "apps/x/src/sum\.test\.js: Error: Cannot find module '\./mul\.js'")) "True"
$r = Get-PlannerSetUsability -Status PASS -Output @(Get-Content (Join-Path $fx "v5.0.1-not-run.txt")) -SetFiles @("apps/x/src/sum-three.test.js") -TestCmd $filtered -TestDir "apps/x"
Check "not-found names the command and its filter" ([bool]($r.Detail -match "'npx vitest run src/sum\.test\.js', run from apps/x, runs only the files whose path contains 'src/sum\.test\.js'")) "True"
$ansi = @(Get-Content (Join-Path $fx "v5.0.1-missing-import.txt") | ForEach-Object { if ($_ -match '^ FAIL ') { "$([char]27)[31m$_$([char]27)[39m" } else { $_ } })
Check "colour codes do not hide a load failure" (Get-PlannerSetUsability -Status FAIL -Output $ansi -SetFiles @("apps/x/src/sum.test.js") -TestCmd $filtered -TestDir "apps/x").Verdict "not-loaded"

Write-Host "-- Get-PlannerSetUsability, the cases the fixtures do not cover"
$ok5 = @(Get-Content (Join-Path $fx "v5.0.1-ok.txt"))
Check "an ERROR (the set could not be placed) is error, with its detail" ("{0}|{1}" -f ($r = Get-PlannerSetUsability -Status ERROR -Detail "the planner's folder x is missing or empty" -SetFiles @()).Verdict, $r.Detail) "error|the planner's folder x is missing or empty"
Check "a set with no test file is not-found" (Get-PlannerSetUsability -Status FAIL -Output $ok5 -SetFiles @("apps/x/src/helper.js", "apps/x/NOTES.md") -TestCmd $filtered -TestDir "apps/x").Verdict "not-found"
Check "a test file outside testDir is not-found" (Get-PlannerSetUsability -Status FAIL -Output $ok5 -SetFiles @("apps/x/src/sum.test.js", "packages/y/src/sum.test.js") -TestCmd $filtered -TestDir "apps/x").Verdict "not-found"
Check "testDir '.': repository paths are the runner's" (Get-PlannerSetUsability -Status FAIL -Output $ok5 -SetFiles @("src/sum.test.js") -TestCmd $filtered -TestDir ".").Verdict "ok"
Check "a non-vitest command is not judged by filter" (Get-PlannerSetUsability -Status FAIL -Output $ok5 -SetFiles @("apps/x/src/sum.test.js") -TestCmd @("npm", "test") -TestDir "apps/x").Verdict "ok"
Check "one of two test files skipped by the filter is enough to be not-found" (Get-PlannerSetUsability -Status FAIL -Output $ok5 -SetFiles @("apps/x/src/sum.test.js", "apps/x/src/extra.test.js") -TestCmd $filtered -TestDir "apps/x").Verdict "not-found"
Check "a .spec.tsx file counts as a test file" (Get-PlannerSetUsability -Status FAIL -Output @(" FAIL  src/a.spec.tsx > G1 x") -SetFiles @("apps/x/src/a.spec.tsx") -TestCmd $all -TestDir "apps/x").Verdict "ok"

# --- test-tasks.ps1 -DryRun -SetCheckOnly, end to end ---
$psExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("set-check-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
try {
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/agents", "repo/app/src")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $harnessPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $e2e "tests") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "checks") -Destination (Join-Path $e2e "tests") -Recurse -Force
    $repo = Join-Path $e2e "repo"
    git -C $repo init -q; git -C $repo config core.autocrlf false; git -C $repo config user.email "t@example.invalid"; git -C $repo config user.name "t"
    # A stand-in for `vitest run <filters>`, run from app/: each src/*.test.js the filters let through is a failed suite when
    # it says LOADERROR, a failing test when it says FAILS, else a pass. It prints vitest's own lines for each.
    $fakeVitest = @'
$filters = @($args | Select-Object -Skip 2)
$files = @(Get-ChildItem -LiteralPath src -Filter *.test.js | ForEach-Object { "src/" + $_.Name })
if ($filters.Count) { $files = @($files | Where-Object { $f = $_; [bool]($filters | Where-Object { $f.Contains($_) }) }) }
$failed = 0; $passed = 0; $suites = 0
foreach ($f in $files) {
    $t = Get-Content -Raw -LiteralPath $f
    if ($t -match 'LOADERROR') { " FAIL  $f [ $f ]"; "Error: Cannot find module './mul.js' imported from $f"; $suites++ }
    elseif ($t -match 'FAILS') { " FAIL  $f > G1 adds three"; "AssertionError: expected 3 to be 6"; $failed++ }
    else { $passed++ }
}
if ($suites) { " Failed Suites $suites" }
if ($failed + $passed) { "      Tests  $failed failed | $passed passed ($($failed + $passed))" } else { "      Tests  no tests" }
if ($failed -or $suites) { exit 1 }
exit 0
'@
    $fakeVitest | Set-Content -LiteralPath (Join-Path $repo "app/fake.ps1")
    "export function sum(a, b) { return a + b }" | Set-Content -LiteralPath (Join-Path $repo "app/src/sum.js")
    "it('adds') // passes" | Set-Content -LiteralPath (Join-Path $repo "app/src/sum.test.js")
    git -C $repo add -A; git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    "// fixed" | Add-Content -LiteralPath (Join-Path $repo "app/src/sum.js")
    git -C $repo commit -q -am solution
    $sol = (git -C $repo rev-parse HEAD).Trim()

    $priv = Join-Path $tmp "priv"
    $sets = [ordered]@{ good = @{ "app/src/sum.test.js" = "it('G1') FAILS" }; broken = @{ "app/src/sum.test.js" = "import LOADERROR" }; elsewhere = @{ "app/src/sum-three.test.js" = "it('G1') FAILS" } }
    foreach ($k in $sets.Keys) { foreach ($f in $sets[$k].Keys) { $p = Join-Path $priv "tasks/planner/fx/$k/$f"; New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null; Set-Content -LiteralPath $p -Value $sets[$k][$f] } }
    New-Item -ItemType Directory -Path (Join-Path $priv "tasks/hidden/fx/app/src") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $priv "tasks/hidden/fx/app/src/sum.test.js") -Value "it('hidden') FAILS"
    $task = [ordered]@{ id = "fx"; title = "fx"; branch = "bench/fx"; repo = $repo; benchBaseCommit = $base; grading = "acceptance"; scope = "guardrails"
        testDir = "app"; testCmd = @($psExe, "-NoProfile", "-File", "fake.ps1", "vitest", "run", "src/sum.test.js"); installFlags = @(); prompt = "fix it"
        acceptance = [ordered]@{ dir = "hidden/fx"; solution = $sol } }
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
function Invoke-AgentRun { throw "a dry run must not call the agent" }
function Read-AgentEvents { param([string]$Path) , (New-Object System.Collections.Generic.List[object]) }
'@ | Set-Content -LiteralPath (Join-Path $e2e "tests/agents/fixture.ps1")

    $harness = Join-Path $e2e "tests/test-tasks.ps1"
    $manifest = Join-Path $priv "tasks/manifest.json"
    function Invoke-Check([string]$Set, [string]$Dir, [switch]$Only, [switch]$NoDry) {
        $out = Join-Path $tmp ("check-" + [guid]::NewGuid().ToString("N") + ".json")
        $a = @{ Agent = "fixture"; Task = "fx"; Model = "fixture/m"; SkipInstall = $true; TaskManifest = $manifest; ResultsDir = $Dir; AcceptanceDir = $Set; SetCheckOut = $out }
        if (-not $NoDry) { $a.DryRun = $true }
        if ($Only) { $a.SetCheckOnly = $true }
        $log = & $harness @a *>&1 | Out-String
        $exit = $LASTEXITCODE
        $j = if (Test-Path -LiteralPath $out) { Get-Content -Raw -LiteralPath $out | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ Log = $log; Exit = $exit; Json = $j }
    }

    Write-Host "-- test-tasks.ps1 -DryRun -SetCheckOnly, end to end"
    $dir = Join-Path $priv "results/check"
    $r = Invoke-Check "planner/fx/good" $dir -Only
    if (-not $r.Json) { Write-Host (($r.Log -split "`n" | Select-Object -Last 25) -join "`n") }
    Check "-SetCheckOnly: an ok set's verdict JSON" ("{0}|{1}|{2}|{3}" -f $r.Exit, $r.Json.task, $r.Json.verdict, ($r.Json.testFiles -join ",")) "0|fx|ok|app/src/sum.test.js"
    Check "-SetCheckOnly: the set's hash is recorded" ([bool]($r.Json.hash -match '^[0-9a-f]{12}$')) "True"
    Check "-SetCheckOnly: the hidden tests are not run" ([bool]($r.Log -match 'acceptance \(fails on base\)')) "False"
    Check "-SetCheckOnly: no solution is checked" ([bool]($r.Log -match 'passes on solution')) "False"
    Check "-SetCheckOnly: no planner-sets.tsv row (the two-point check's table)" (Test-Path -LiteralPath (Join-Path $dir "planner-sets.tsv")) "False"
    $r = Invoke-Check "planner/fx/broken" $dir -Only
    Check "-SetCheckOnly: a set that does not load" ("{0}|{1}" -f $r.Json.verdict, [bool]($r.Json.detail -match "Cannot find module")) "not-loaded|True"
    $r = Invoke-Check "planner/fx/elsewhere" $dir -Only
    Check "-SetCheckOnly: a set the command does not run" $r.Json.verdict "not-found"
    $r = Invoke-Check "planner/fx/good" $dir -Only -NoDry
    Check "-SetCheckOnly without -DryRun is refused" ("{0}|{1}|{2}" -f $r.Exit, [bool]($r.Log -match 'needs -DryRun and -AcceptanceDir'), ($null -eq $r.Json)) "1|True|True"
    $dir2 = Join-Path $priv "results/dry"
    $r = Invoke-Check "planner/fx/good" $dir2
    Check "a plain -DryRun -AcceptanceDir still checks the solution" ([bool]($r.Log -match 'planner set \(passes on solution\)')) "True"
    Check "...and prints the check before use" ([bool]($r.Log -match '(?s)planner set \(usable before use\)\s*->\s*ok: fails on the base in app/src/sum\.test\.js')) "True"
    Check "...and keeps its planner-sets.tsv row" (@(Import-Csv -Delimiter "`t" -LiteralPath (Join-Path $dir2 "planner-sets.tsv")).Count) 1

    Write-Host "-- run-planner-local.ps1: the follow-up for a set that is not usable"
    . (Join-Path $repoRoot "desktop/scripts/run-planner-local.ps1")
    $seq = { param([string[]]$Verdicts) $script:calls = 0; $script:feedbacks = @(); { param($attempt) $v = $Verdicts[[Math]::Min($attempt - 1, $Verdicts.Count - 1)]; $script:calls++; [pscustomobject]@{ Verdict = $v; Detail = "detail of $v"; TestFiles = @() } }.GetNewClosure() }
    $retry = { param($feedback) $script:feedbacks += $feedback }
    $g = Invoke-PlannerSetGate -Check (& $seq @("ok")) -Retry $retry -Retries 1 -Task "t1"
    Check "an ok set: one check, no follow-up, usable" ("{0}|{1}|{2}" -f $g.Attempts.Count, $script:feedbacks.Count, $g.Usable) "1|0|True"
    $g = Invoke-PlannerSetGate -Check (& $seq @("not-loaded", "ok")) -Retry $retry -Retries 1 -Task "t1"
    Check "a set that does not load gets one follow-up" ("{0}|{1}|{2}" -f $g.Attempts.Count, $script:feedbacks.Count, (($g.Attempts | ForEach-Object verdict) -join ",")) "2|1|not-loaded,ok"
    Check "...it carries the check's words, and the set is then usable" ("{0}|{1}" -f [bool]($script:feedbacks[0] -match 'could not load your test file\. detail of not-loaded'), $g.Usable) "True|True"
    Check "...the feedback is recorded on the attempt it answers" ([bool]($g.Attempts[0].feedback -and -not $g.Attempts[1].feedback)) "True"
    $g = Invoke-PlannerSetGate -Check (& $seq @("passes-on-base", "passes-on-base")) -Retry $retry -Retries 1 -Task "t1"
    Check "still not usable after the follow-up: two attempts, not usable" ("{0}|{1}" -f $g.Attempts.Count, $g.Usable) "2|False"
    $script:feedbacks = @()
    $g = Invoke-PlannerSetGate -Check (& $seq @("not-found")) -Retry $retry -Retries 0 -Task "t1"
    Check "-SetRetries 0: no follow-up" ("{0}|{1}|{2}" -f $g.Attempts.Count, $script:feedbacks.Count, $g.Usable) "1|0|False"

    $kinds = @("not-loaded", "not-found", "passes-on-base", "fails-elsewhere", "error")
    $fbs = @($kinds | ForEach-Object { Get-SetCheckFeedback -Check ([pscustomobject]@{ Verdict = $_; Detail = "D-$_" }) -Task "real-02" })
    Check "every feedback names the task and the clone, and asks for the tests only" (@($fbs | Where-Object { $_ -match "task 'real-02'" -and $_ -match 'work/real-02' -and $_ -match 'Change only the tests\.' }).Count) 5
    Check "...and names no hidden test or solution" (@($fbs | Where-Object { $_ -match '(?i)hidden|solution|acceptance' }).Count) 0
    Check "passes-on-base asks for tests that fail now" ([bool]($fbs[2] -match 'fail on the code as it is now')) "True"

    Write-Host "-- Invoke-PlannerSetCheck against a stand-in harness"
    $stand = Join-Path $tmp "stand-in-harness.ps1"
    '$m = @{}; for ($i = 0; $i -lt $args.Count; $i++) { if ("$($args[$i])".StartsWith("-")) { $m[$args[$i].TrimStart("-")] = if ($i + 1 -lt $args.Count -and -not "$($args[$i + 1])".StartsWith("-")) { $args[$i + 1] } else { $true } } }; $args -join " " | Set-Content -LiteralPath (Join-Path $m.ResultsDir "args.txt"); if ($env:FX_NOVERDICT) { "boom: the manifest is missing"; exit 3 }; @{ verdict = "not-found"; detail = "d"; testFiles = @("a.test.ts") } | ConvertTo-Json | Set-Content -LiteralPath $m.SetCheckOut' | Set-Content -LiteralPath $stand
    $od = Join-Path $tmp "chk1"
    $c = Invoke-PlannerSetCheck -HarnessScript $stand -Manifest "M.json" -Task "real-02" -Model "p/m" -SetDir "S" -OutDir $od -Pwsh $psExe
    Check "the verdict is read back" ("{0}|{1}" -f $c.Verdict, ($c.TestFiles -join ",")) "not-found|a.test.ts"
    $argsSeen = Get-Content -Raw -LiteralPath (Join-Path $od "args.txt")
    Check "it asks for the check before use only" ([bool]($argsSeen -match '-DryRun' -and $argsSeen -match '-SetCheckOnly' -and $argsSeen -match '-AcceptanceDir S' -and $argsSeen -match '-TaskManifest M\.json' -and $argsSeen -match '-Task real-02')) "True"
    $env:FX_NOVERDICT = "1"
    $c = Invoke-PlannerSetCheck -HarnessScript $stand -Manifest "M.json" -Task "real-02" -Model "p/m" -SetDir "S" -OutDir (Join-Path $tmp "chk2") -Pwsh $psExe
    Check "a harness that writes no verdict: error, with its last words" ("{0}|{1}" -f $c.Verdict, [bool]($c.Detail -match 'exit 3.*boom: the manifest is missing')) "error|True"
} finally {
    Remove-Item Env:FX_NOVERDICT -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

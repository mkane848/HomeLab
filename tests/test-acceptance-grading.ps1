# test-acceptance-grading.ps1 - regression guard for real-prompt task grading
#
# Why this exists: real-prompt tasks (docs/roadmap.md -> "Real-use tasks") are
# graded on scope + suite + hidden acceptance tests, not on the model's own
# test, and they come from a PRIVATE manifest whose prompts and transcripts must
# never land in this public repo. test-tasks.ps1 gained -TaskManifest/-ResultsDir,
# `grading: "acceptance"`, `scope: "guardrails"` and `acceptance.dir`.
#
# What it does: pulls the REAL Test-Guardrails / ConvertTo-GlobRegex out of
# test-tasks.ps1 and checks them directly; then runs the real test-tasks.ps1
# end to end against a fixture repo with a stand-in opencode on PATH and a
# private manifest + hidden tests in a folder outside the fixture "repo":
#   - a correct fix passes; a wrong one fails on the hidden tests;
#   - the hidden tests are absent while the model runs and gone afterwards;
#   - a lockfile edit and a too-large change fail the guard rails;
#   - failsOnOld is SKIP ("not asked") unless requireTest;
#   - a private manifest without a private -ResultsDir is refused;
#   - private results hold the detail, tests/results/ only the verdict mirror;
#   - -DryRun: hidden tests FAIL on the base and PASS on acceptance.solution.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-acceptance-grading.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

Write-Host "-- Test-Guardrails (real function)"
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$wanted = @("ConvertTo-GlobRegex", "Test-Guardrails")
foreach ($w in $wanted) {
    $fn = $fns | Where-Object { $_.Name -eq $w } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $w not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}
$denyAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:DefaultGuardrailDeny' }, $true) | Select-Object -First 1
if (-not $denyAst) { Write-Host "FAIL: DefaultGuardrailDeny not found"; exit 2 }
Invoke-Expression $denyAst.Extent.Text
$g = Test-Guardrails -Files @("src/a.ts", "src/a.test.ts") -Lines 40 -Guardrails $null
Check "an ordinary fix passes"                     $g.Ok "True"
Check "...and the detail lists the files"          ($g.Detail -match 'src/a\.ts, src/a\.test\.ts') "True"
foreach ($bad in @("pnpm-lock.yaml", "apps/web/package-lock.json", ".env", "apps/server/.env.local", ".github/workflows/ci.yml", "node_modules/x/index.js")) {
    Check "denied by default: $bad"                (Test-Guardrails -Files @("src/a.ts", $bad) -Lines 10 -Guardrails $null).Ok "False"
}
Check "a nested path is not mistaken for .github"  (Test-Guardrails -Files @("docs/.github-notes.md") -Lines 1 -Guardrails $null).Ok "True"
$gr = [pscustomobject]@{ packageRoots = @("apps/server") }
Check "outside packageRoots fails"                 (Test-Guardrails -Files @("apps/server/x.ts", "apps/web/y.ts") -Lines 5 -Guardrails $gr).Ok "False"
Check "inside packageRoots passes"                 (Test-Guardrails -Files @("apps/server/x.ts") -Lines 5 -Guardrails $gr).Ok "True"
Check "allow exempts a default deny"               (Test-Guardrails -Files @("pnpm-lock.yaml") -Lines 5 -Guardrails ([pscustomobject]@{ allow = @("**/pnpm-lock.yaml") })).Ok "True"
Check "extra deny is applied"                      (Test-Guardrails -Files @("db/migrations/1.sql") -Lines 5 -Guardrails ([pscustomobject]@{ deny = @("db/migrations/**") })).Ok "False"
Check "file ceiling (default 15)"                  (Test-Guardrails -Files @(1..16 | ForEach-Object { "src/f$_.ts" }) -Lines 16 -Guardrails $null).Ok "False"
Check "line ceiling (default 600)"                 (Test-Guardrails -Files @("src/a.ts") -Lines 601 -Guardrails $null).Ok "False"
Check "no change at all fails"                     (Test-Guardrails -Files @() -Lines 0 -Guardrails $null).Ok "False"

Write-Host "-- end to end: real test-tasks.ps1, fixture repo, private manifest outside it"
$tmp  = Join-Path ([IO.Path]::GetTempPath()) ("accgrade-repo-" + [guid]::NewGuid().ToString("N"))
$priv = Join-Path ([IO.Path]::GetTempPath()) ("accgrade-priv-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
try {
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $tmp "tests/test-tasks.ps1")
    '{"tasks":[]}' | Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/manifest.json")
    $repo = Join-Path $tmp "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    # The suite: the hidden test (hidden.txt) and a model-written test (model.test.txt) need src.txt fixed.
    @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
if (((Test-Path hidden.txt) -or (Test-Path model.test.txt)) -and $src -ne 'fixed') { Write-Host "Tests  1 failed (2)"; exit 1 }
Write-Host "Tests  2 passed (2)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "fixed"
    git -C $repo commit -q -am "the owner's real fix"
    $solution = (git -C $repo rev-parse HEAD).Trim()

    $ids = @("fx-pass", "fx-wrong", "fx-lockfile", "fx-big", "fx-reqtest", "fx-dry")
    foreach ($id in $ids) {
        New-Item -ItemType Directory -Path (Join-Path $priv "hidden/$id") -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $priv "hidden/$id/hidden.txt") -Value "hidden test"
    }
    function New-RealTask([string]$id, $extra = @{}) {
        $t = [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            baselineExpect = @{ testsTotal = 2; testsPass = 2 }
            grading = "acceptance"; scope = "guardrails"
            acceptance = [ordered]@{ dir = "hidden/$id" }
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1")
            installFlags = @(); prompt = "PRIVATE-PROMPT-TEXT the digest is broken, sort it out"
        }
        foreach ($k in $extra.Keys) { $t[$k] = $extra[$k] }
        return $t
    }
    $dry = New-RealTask "fx-dry"
    $dry.acceptance.solution = $solution
    @{ tasks = @((New-RealTask "fx-pass"), (New-RealTask "fx-wrong"), (New-RealTask "fx-lockfile"),
                 (New-RealTask "fx-big" @{ guardrails = @{ maxChangedFiles = 2 } }), (New-RealTask "fx-reqtest" @{ requireTest = $true }), $dry) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $priv "manifest.json")

    # Stand-in opencode: records whether the hidden test was visible, then acts per task.
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    if (Test-Path (Join-Path $dir 'hidden.txt')) { Add-Content -LiteralPath $env:FIXTURE_SEEN -Value (Split-Path -Leaf $dir) }
    $id = Split-Path -Leaf $dir
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value $(if ($id -eq 'fx-wrong') { 'half' } else { 'fixed' })
    if ($id -eq 'fx-lockfile') { Set-Content -LiteralPath (Join-Path $dir 'pnpm-lock.yaml') -Value 'lockfileVersion: 9' }
    if ($id -eq 'fx-reqtest') { Set-Content -LiteralPath (Join-Path $dir 'model.test.txt') -Value 'a real test' }
    if ($id -eq 'fx-big') { 1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $dir "extra$_.txt") -Value 'x' } }
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $tmp "bin/standin.ps1")
    $bin = Join-Path $tmp "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $tt = Join-Path $tmp "tests/test-tasks.ps1"
    $privResults = Join-Path $priv "results"
    $publicResults = Join-Path $tmp "tests/results"
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $env:FIXTURE_SEEN = Join-Path $priv "seen.txt"
    try {
        Write-Host "   (refusal)"
        $refused = & $tt -TaskManifest (Join-Path $priv "manifest.json") -Task fx-pass -Model fixture/m -SkipInstall *>&1 | Out-String
        $refusedExit = $LASTEXITCODE
        $worktreeAfterRefusal = Test-Path (Join-Path $tmp "tests/.worktrees/fx-pass")
        Write-Host "   (graded runs)"
        $out = & $tt -TaskManifest (Join-Path $priv "manifest.json") -ResultsDir $privResults -Task fx-pass, fx-wrong, fx-lockfile, fx-big, fx-reqtest -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $priv "no-log") *>&1 | Out-String
        Write-Host "   (dry run)"
        $dryOut = & $tt -TaskManifest (Join-Path $priv "manifest.json") -ResultsDir $privResults -Task fx-dry -Model fixture/m -SkipInstall -DryRun *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_SEEN -ErrorAction SilentlyContinue
    }

    Check "a private manifest without -ResultsDir is refused (exit 1)" $refusedExit 1
    Check "...saying why"                               ($refused -match 'private manifest\), so its results must be too') "True"
    Check "...before any run (no worktree made)"        $worktreeAfterRefusal "False"

    if (-not (Test-Path (Join-Path $privResults "real-tasks-summary.tsv"))) {
        Write-Host "FAIL no real-tasks-summary.tsv - harness output follows"; Write-Host (($out -split "`n" | Select-Object -Last 40) -join "`n"); exit 1
    }
    $rows = @(Import-Csv (Join-Path $privResults "real-tasks-summary.tsv") -Delimiter "`t")
    function Row([string]$id) { @($rows | Where-Object taskId -eq $id)[0] }
    Check "five private real-prompt rows"               $rows.Count 5
    Check "fx-pass: scope/suite/acceptance/failsOnOld"  ("{0}/{1}/{2}/{3}" -f (Row fx-pass).scope, (Row fx-pass).suite, (Row fx-pass).acceptance, (Row fx-pass).failsOnOld) "PASS/PASS/PASS/SKIP"
    Check "fx-wrong: the hidden test fails it"          (Row fx-wrong).acceptance "FAIL"
    Check "fx-lockfile: guard rails fail it"            (Row fx-lockfile).scope "FAIL"
    Check "fx-lockfile: ...but its fix passed hidden tests" (Row fx-lockfile).acceptance "PASS"
    Check "fx-big: file ceiling fails it"               (Row fx-big).scope "FAIL"
    Check "fx-reqtest: requireTest measures failsOnOld"   (Row fx-reqtest).failsOnOld "PASS"
    Check "the output names the lockfile hit"           ($out -match 'pnpm-lock\.yaml \(denied: \*\*/pnpm-lock\.yaml\)') "True"
    Check "failsOnOld says why it was skipped"          ($out -match 'not asked - the prompt did not ask for a test') "True"
    Check "the hidden test was never visible to the model" (Test-Path (Join-Path $priv "seen.txt")) "False"
    Check "the hidden test is gone from the worktree afterwards" (Test-Path (Join-Path $tmp "tests/.worktrees/fx-pass/hidden.txt")) "False"
    $j = Get-ChildItem $privResults -Filter "tasks-fx-pass-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "run JSON: grading acceptance"                $j.grading "acceptance"
    Check "run JSON: scopeDetail mode guardrails"       $j.scopeDetail.mode "guardrails"
    Check "run JSON: acceptance fingerprint recorded"   ($j.acceptance.hash -match '^[0-9a-f]{12}$') "True"
    Check "private results hold the transcripts"        @(Get-ChildItem $privResults -Filter "*.jsonl").Count 5

    Check "no guided summary row anywhere"              ((Test-Path (Join-Path $privResults "tasks-summary.tsv")) -or (Test-Path (Join-Path $publicResults "tasks-summary.tsv"))) "False"
    $pub = Join-Path $publicResults "real-tasks-public.tsv"
    Check "the public mirror exists"                    (Test-Path $pub) "True"
    $pubText = Get-Content -LiteralPath $pub -Raw
    $pubRows = @(Import-Csv $pub -Delimiter "`t")
    Check "...with five rows"                           $pubRows.Count 5
    Check "...and only the verdict columns"             (($pubRows[0].PSObject.Properties.Name) -join ",") "timestamp,taskId,model,opencodeVersion,engine,engineVersion,scope,suite,acceptance,acceptanceHash,elapsedSec"
    Check "...with the hidden tests' fingerprint per row" ($pubRows[0].acceptanceHash -match '^[0-9a-f]{12}$') "True"
    Check "...no prompt text in it"                     ($pubText -match 'PRIVATE-PROMPT-TEXT') "False"
    Check "...no commit in it"                          ($pubText -match $base.Substring(0, 10)) "False"
    Check "nothing else written under tests/results/"   (@(Get-ChildItem $publicResults -File | Where-Object Name -ne "real-tasks-public.tsv").Count) 0

    Check "dry run: hidden tests fail on the base"      ($dryOut -match '\[PASS\] acceptance \(fails on base\)') "True"
    Check "dry run: ...and pass on the real solution"   ($dryOut -match '\[PASS\] acceptance \(passes on solution\)') "True"
    Check "dry run: the worktree is back on the base"   ((git -C (Join-Path $tmp "tests/.worktrees/fx-dry") rev-parse HEAD).Trim()) $base
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp, $priv -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

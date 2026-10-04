# test-fails-on-old.ps1 - regression guard for when failsOnOld is measured
#
# Why this exists: failsOnOld reverts the model's source and expects the suite
# to go red. That only says something when the suite was green with the change.
# On 2026-10-03 qwen3.6's asohav-07 test file did not parse (a note written as
# code, not as a comment); the suite was red with the fix and red with it
# reverted, and the row recorded failsOnOld=PASS for a test that never ran.
# 29 earlier rows have suite=FAIL failsOnOld=PASS the same way. test-tasks.ps1
# now records failsOnOld=SKIP whenever the suite is red after the change.
#
# What it does: runs the REAL test-tasks.ps1 against a fixture repo with a
# stand-in opencode on PATH, for three tasks: a good test (PASS), a test that
# passes on the old source (FAIL), and a test file that does not load (SKIP).
# Exit 1 on any failure.
#
# Usage:  .\tests\test-fails-on-old.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("foo-test-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
try {
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $tmp "tests/test-tasks.ps1")
    $repo = Join-Path $tmp "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    # The "suite": a test.txt saying 'broken' does not load (vitest's suite-level
    # shape); 'weak' passes whatever the source; any other test needs the fix.
    @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
$test = if (Test-Path test.txt) { (Get-Content -LiteralPath test.txt -Raw).Trim() } else { "" }
if ($test -eq 'broken') { Write-Host " FAIL  test.test.ts [ test.test.ts ]"; Write-Host "Failed Suites 1"; exit 1 }
if ($test -and $test -ne 'weak' -and $src -ne 'fixed') { Write-Host "Tests  1 failed (1)"; exit 1 }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    function New-FixtureTask([string]$id) {
        [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            baselineExpect = @{ testsTotal = 1; testsPass = 1 }
            allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1")
            installFlags = @(); prompt = "fix it"
        }
    }
    @{ tasks = @((New-FixtureTask "fx-good"), (New-FixtureTask "fx-weak"), (New-FixtureTask "fx-broken")) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/manifest.json")
    # Stand-in opencode: fixes the source in every task; the test it writes
    # depends on the task (fx-good: a real test, fx-weak: 'weak', fx-broken: 'broken').
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    $test = switch (Split-Path -Leaf $dir) { 'fx-weak' { 'weak' } 'fx-broken' { 'broken' } default { 'a real test' } }
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value $test
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $tmp "bin/standin.ps1")
    $bin = Join-Path $tmp "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    try {
        $output = & (Join-Path $tmp "tests/test-tasks.ps1") -Task fx-good, fx-weak, fx-broken -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
    }
    $results = Join-Path $tmp "tests/results"
    $rows = @(if (Test-Path (Join-Path $results "tasks-summary.tsv")) { Import-Csv (Join-Path $results "tasks-summary.tsv") -Delimiter "`t" })
    function Row([string]$id) { @($rows | Where-Object taskId -eq $id)[0] }
    function Json([string]$id) { Get-ChildItem $results -Filter "tasks-$id-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json }

    Write-Host "-- a test that needs the fix"
    Check "suite PASS"                          (Row "fx-good").suite "PASS"
    Check "failsOnOld PASS"                     (Row "fx-good").failsOnOld "PASS"
    Write-Host "-- a test that passes on the old source"
    Check "suite PASS"                          (Row "fx-weak").suite "PASS"
    Check "failsOnOld FAIL"                     (Row "fx-weak").failsOnOld "FAIL"
    Write-Host "-- a test file that does not load (asohav-07, 2026-10-03)"
    Check "suite FAIL"                          (Row "fx-broken").suite "FAIL"
    Check "failsOnOld SKIP in the summary row"  (Row "fx-broken").failsOnOld "SKIP"
    Check "failsOnOld SKIP in the run JSON"     (Json "fx-broken").gates.failsOnOld "SKIP"
    Check "the output says why it was not measured" ($output -match '\[SKIP\] fails-on-old\s+-> not measured - the suite is already red') "True"
    Check "the source was never reverted for it (no revert verdict printed)" ($output -match 'suite fails with source reverted, test kept: \(1 failed suite') "False"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

# protects: What a failing test command's FAIL line says (Get-FailureDetail, Get-TestSummaryText, Remove-AnsiCodes)
# run-after: How the harness summarises or quotes a test command's output
# test-failure-detail.ps1 - regression guard for what a failing test command's
# FAIL line says (Get-TestSummaryText, Get-FailureDetail, Remove-AnsiCodes in
# test-tasks.ps1; 2026-10-26).
#
# Why this exists: a task's test command can run several projects in turn
# (wp-5b: build the shared package, run its tests, then the server's). The suite
# and acceptance FAIL lines quoted only the last "Tests ... (N)" line and the
# failed tests' names, so when an earlier step failed without naming a test (a
# build that did not compile) they read "Tests 247 passed (247) - " with nothing
# after the dash: 5 genuine failures of 2026-10-25's read-only arm looked like a
# grading bug until their transcripts were read.
#
# What it does: loads the REAL functions from test-tasks.ps1 and runs them on
# synthetic output (two projects with a build error first, a normal vitest
# failure, a suite that does not load, colour codes, a long error line, no
# output); then the real test-tasks.ps1 end to end with a fixture repo whose
# test command runs a "build" step and a "tests" step, and a stand-in opencode
# whose change breaks the build: the suite FAIL line must name the build error,
# not stop at the passing step's summary. Exit 1 on any failure.
#
# Usage:  .\tests\test-failure-detail.ps1 [-ScriptPath <a test-tasks.ps1>]
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
$have = $true
foreach ($name in "Get-FailedTestNames", "Remove-AnsiCodes", "Get-TestSummaryText", "Get-FailureDetail") {
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($fn) { Invoke-Expression $fn.Extent.Text } else { Check "test-tasks.ps1 defines $name" "missing" "defined"; $have = $false }
}

$e = [char]27
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("faildetail-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    if ($have) {
        Write-Host "-- the functions, on synthetic output"
        # wp-5b's shape: the shared build fails, the server's tests still run and pass.
        $twoProjects = @(
            "> @asohav/shared@0.6.0 build",
            "> tsc -p tsconfig.json",
            "src/logic.ts(466,7): error TS2322: Type 'number' is not assignable to type 'Bond'.",
            "npm error Lifecycle script ``build`` failed with error:",
            "$e[2m      Tests $e[22m $e[1m$e[32m19 passed$e[39m$e[22m$e[90m (19)$e[39m",
            "$e[2m      Tests $e[22m $e[1m$e[32m247 passed$e[39m$e[22m$e[90m (247)$e[39m"
        )
        Check "every project's summary line, in order, colour codes stripped" (Get-TestSummaryText -Output $twoProjects) "Tests  19 passed (19) | Tests  247 passed (247)"
        $d = Get-FailureDetail -Output $twoProjects -ExitCode 1
        Check "no test named: says so, with the exit"                    ([bool]($d -like "no failing test named (exit 1): *")) "True"
        Check "...and quotes the build error"                            ([bool]($d -match "error TS2322: Type 'number'")) "True"
        Check "...and npm's failed-script line"                          ([bool]($d -match "Lifecycle script ``build`` failed")) "True"

        $vitestFail = @(
            " FAIL  src/routes/bond.test.ts > Spending Bond (revised) > refuses to Spend Bond with 0 Bond, with a 409",
            "      Tests  1 failed | 246 passed (247)"
        )
        # Get-FailedTestNames (unchanged) keeps the part after the last ">".
        Check "a failing test is still named, as before"                 (Get-FailureDetail -Output $vitestFail -ExitCode 1) "refuses to Spend Bond with 0 Bond, with a 409; (1 failed)"
        Check "...and its summary line kept"                             (Get-TestSummaryText -Output $vitestFail) "Tests  1 failed | 246 passed (247)"

        $loadFail = @(" FAIL  src/x.test.ts [ src/x.test.ts ]", " Failed Suites 1", "      Tests  no tests")
        Check "a suite that does not load is still reported as one"      ([bool]((Get-FailureDetail -Output $loadFail -ExitCode 1) -match 'failed suite\(s\) - load/parse error')) "True"

        $long = @("Error: " + ("x" * 400))
        $d = Get-FailureDetail -Output $long -ExitCode 2
        Check "a long error line is cut to 200 characters"               ([bool]($d.Length -lt 260 -and $d.EndsWith("..."))) "True"
        Check "no output at all: the exit alone"                         (Get-FailureDetail -Output @() -ExitCode 3) "no failing test named (exit 3)"
        Check "no summary line: says so"                                 (Get-TestSummaryText -Output @("hello")) "no test summary line"
        Check "no error words: the last two lines"                       (Get-FailureDetail -Output @("a", "b", "c") -ExitCode 1) "no failing test named (exit 1): b | c"
    }

    Write-Host "-- end to end: the real test-tasks.ps1, a two-step test command, a change that breaks the first step"
    $psExe = (Get-Process -Id $PID).Path
    $fx = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $fx $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $fx "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $fx "tests") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $fx "tests") -Recurse -Force
    $repo = Join-Path $fx "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "ok"
    # Step 1 "builds" (fails when src.txt says broken), step 2 "tests" (always passes),
    # and the command's exit is the worse of the two, as wp-5b's node wrapper does.
    @'
$f = 0
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
Write-Host "> shared build"
if ($src -eq 'broken') { Write-Host "src/logic.ts(466,7): error TS2322: Type 'number' is not assignable to type 'Bond'."; $f = 1 }
Write-Host "      Tests  247 passed (247)"
exit $f
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-twostep"; title = "fx"; repo = $repo; branch = "bench/fx-twostep"; benchBaseCommit = $base
        baselineExpect = @{ testsTotal = 247; testsPass = 247 }
        allowFiles = @("src.txt"); srcRevertFiles = @("src.txt")
        testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @(); prompt = "change it" }) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fx "tests/tasks/manifest.json")
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'broken'
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $fx "bin/standin.ps1")
    $bin = Join-Path $fx "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    try {
        $output = & (Join-Path $fx "tests/test-tasks.ps1") -Task fx-twostep -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $fx "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
    }
    $line = @($output -split "`r?`n" | Where-Object { $_ -match '\[FAIL\] suite' -or $_ -match 'suite fails after change' })
    Check "the suite FAILs"                                          ([bool]($output -match '\[FAIL\] suite')) "True"
    Check "...and its line names the build error"                    ([bool]($output -match "suite fails after change: no failing test named \(exit 1\): src/logic\.ts\(466,7\): error TS2322")) "True"
    Check "...and shows the passing step's summary as context, not as the reason" ([bool]($output -match "error TS2322[^\r\n]*\(Tests  247 passed \(247\)\)")) "True"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

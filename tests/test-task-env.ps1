# test-task-env.ps1 - regression guard for a benchmark task's pinned test environment
# (`testEnv` in tests/tasks/manifest.json, applied by test-tasks.ps1).
#
# Why this exists: a gate result used to depend on whatever environment the harness process
# happened to hold. asohav-02's model-written test imports the real repo.ts, which imports
# pgPool.ts, which throws at import time unless DATABASE_URL is set. On 2026-09-27 the variable
# was absent (the models' own vitest runs show the error) and on 2026-09-29 it was present, so
# the two qwen3.6 passes of 09-29 only load where it is set: replayed on a clean machine their
# test file does not load and the suite gate fails. Nothing in the result recorded which
# environment a row ran under. A task's `testEnv` now pins it for the test command AND for the
# model's own `opencode run` process, is restored afterwards, and is written to the run JSON.
#
# What it does:
#   1. manifest:  every `testEnv` is an object of valid variable names -> string or null (null =
#                 unset) with a `testEnvNote` saying why; asohav-02 pins DATABASE_URL and lfc-02
#                 pins MANAPOOL_API_KEY (the two documented hazards), and every ASoHaV
#                 apps/server task pins DATABASE_URL (asohav-02's finding, applied to the family).
#   2. Set-TaskTestEnv / Restore-TaskTestEnv, the REAL functions from test-tasks.ps1: a pin over
#                 an ambient value, null and "" unsetting, a variable that was absent, an
#                 unrelated variable left alone, no-op for a task without `testEnv`, restore
#                 putting back exactly what was there.
#   3. Invoke-Test, the REAL function: the test command (a child process) sees the pins, and the
#                 process is restored afterwards - also when the command fails or cannot start.
#   4. end to end: the real test-tasks.ps1, copied beside a fixture manifest and run against a
#                 throwaway repo with a stand-in `opencode` on PATH. Three tasks in one run: one
#                 pinning DATABASE_URL to unset, one with no pin (must see the ambient value, so
#                 nothing leaks from the first), one pinning it to a value. The stand-in records
#                 what the MODEL's process saw; each task's check script fails the baseline if the
#                 environment is wrong, so the gates are covered too. The run JSON must record
#                 `testEnv`, and the process must come out with its original environment.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-task-env.ps1 [-ScriptPath <test-tasks.ps1>] [-ManifestPath <manifest.json>]
param(
    [string]$ScriptPath   = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$ManifestPath = (Join-Path $PSScriptRoot "tasks/manifest.json")
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
Import-Functions $ScriptPath @("Run-Native", "Set-TaskTestEnv", "Restore-TaskTestEnv", "Invoke-Test")

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Env([string]$name) { return [Environment]::GetEnvironmentVariable($name) }
function Show($v) { if ($null -eq $v) { return "<unset>" } return "'$v'" }

$psExe = (Get-Process -Id $PID).Path
$A = "HL_ENV_TEST_A"
$B = "HL_ENV_TEST_B"
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("task-env-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$origPath = $env:PATH
$origTemp = $env:TEMP
$origFixtureOut = $env:FIXTURE_OUT
$origDb = Env "DATABASE_URL"

try {
    # ---- 1. manifest ---------------------------------------------------------------------------
    Write-Host "-- manifest"
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $withEnv = @($manifest.tasks | Where-Object { $_.PSObject.Properties["testEnv"] })
    Check "at least one task pins an environment" ($withEnv.Count -ge 1) "True"
    foreach ($t in $withEnv) {
        $props = @($t.testEnv.PSObject.Properties)
        $namesOk = ($props.Count -ge 1) -and (@($props | Where-Object { $_.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' }).Count -eq 0)
        $valuesOk = @($props | Where-Object { $null -ne $_.Value -and $_.Value -isnot [string] }).Count -eq 0
        Check "$($t.id): testEnv names are valid variable names" $namesOk "True"
        Check "$($t.id): testEnv values are strings or null" $valuesOk "True"
        Check "$($t.id): testEnvNote says why" (-not [string]::IsNullOrWhiteSpace($t.testEnvNote)) "True"
    }
    $asohav = $manifest.tasks | Where-Object { $_.id -eq "asohav-02-changelog-uuid-id" }
    $lfc = $manifest.tasks | Where-Object { $_.id -eq "lfc-02-scryfall-headers" }
    Check "asohav-02 pins DATABASE_URL" ($null -ne $asohav -and $null -ne $asohav.testEnv -and [bool]$asohav.testEnv.PSObject.Properties["DATABASE_URL"]) "True"
    Check "lfc-02 pins MANAPOOL_API_KEY" ($null -ne $lfc -and $null -ne $lfc.testEnv -and [bool]$lfc.testEnv.PSObject.Properties["MANAPOOL_API_KEY"]) "True"
    # The standing rule behind asohav-02's pin: any ASoHaV apps/server task's model-written test can
    # import the real repo.ts (-> pgPool.ts), which throws without DATABASE_URL, so each one pins it.
    # asohav-01 pre-dates the rule: its 17 recorded rows ran under the ambient environment and
    # nothing in them depends on it (its project test mocks the repo module), so it is not
    # re-pinned - a pin would only split its same-config key without evidence.
    $serverTasks = @($manifest.tasks | Where-Object { $_.id -like "asohav-*" -and $_.testDir -eq "apps/server" -and $_.id -ne "asohav-01-library-write-reporting" })
    $unpinned = @($serverTasks | Where-Object { -not ($_.PSObject.Properties["testEnv"] -and $_.testEnv -and $_.testEnv.PSObject.Properties["DATABASE_URL"]) })
    Check ("every ASoHaV apps/server task pins DATABASE_URL ({0} task(s))" -f $serverTasks.Count) ($serverTasks.Count -ge 1 -and $unpinned.Count -eq 0) "True"

    # ---- 2. Set-TaskTestEnv / Restore-TaskTestEnv ------------------------------------------------
    Write-Host "-- Set-TaskTestEnv / Restore-TaskTestEnv (real functions)"
    function Task-With($obj) { return [pscustomobject]@{ id = "t"; testEnv = ([pscustomobject]$obj) } }
    $childCmd = { param($n) (& $psExe -NoProfile -Command "[Environment]::GetEnvironmentVariable('$n')" | Out-String).Trim() }

    [Environment]::SetEnvironmentVariable($A, "ambient"); [Environment]::SetEnvironmentVariable($B, "keep")
    $s = Set-TaskTestEnv (Task-With @{ $A = "pinned" })
    Check "a pin overrides an ambient value (this process)"        (Env $A) "pinned"
    Check "a pin overrides an ambient value (a child process sees it)" (& $childCmd $A) "pinned"
    Check "an unrelated variable is untouched"                    (Env $B) "keep"
    Restore-TaskTestEnv $s
    Check "restore puts the ambient value back"                   (Env $A) "ambient"

    $s = Set-TaskTestEnv (Task-With @{ $A = $null })
    Check "null unsets an ambient value (this process)"           (Show (Env $A)) "<unset>"
    Check "null unsets an ambient value (a child process sees nothing)" (& $childCmd $A) ""
    Restore-TaskTestEnv $s
    Check "restore after an unset puts the ambient value back"    (Env $A) "ambient"

    $s = Set-TaskTestEnv (Task-With @{ $A = "" })
    Check "an empty string unsets too"                            (Show (Env $A)) "<unset>"
    Restore-TaskTestEnv $s
    Check "restore after an empty-string unset"                   (Env $A) "ambient"

    [Environment]::SetEnvironmentVariable($A, $null)
    $s = Set-TaskTestEnv (Task-With @{ $A = "pinned" })
    Check "a pin sets a variable that was absent"                 (Env $A) "pinned"
    Restore-TaskTestEnv $s
    Check "restore removes a variable that was absent (not left as empty)" (Show (Env $A)) "<unset>"

    [Environment]::SetEnvironmentVariable($A, "ambient"); [Environment]::SetEnvironmentVariable($B, "ambient-b")
    $s = Set-TaskTestEnv (Task-With ([ordered]@{ $A = "p1"; $B = $null }))
    Check "two pins: first set"                                   (Env $A) "p1"
    Check "two pins: second unset"                                (Show (Env $B)) "<unset>"
    Restore-TaskTestEnv $s
    Check "two pins: both restored (first)"                       (Env $A) "ambient"
    Check "two pins: both restored (second)"                      (Env $B) "ambient-b"

    $s = Set-TaskTestEnv ([pscustomobject]@{ id = "plain" })
    Check "a task without testEnv changes nothing"                (Env $A) "ambient"
    Check "a task without testEnv returns nothing to restore"     @($s.Keys).Count 0
    Restore-TaskTestEnv $s
    $threwNull = $false
    try { $s = Set-TaskTestEnv $null; Restore-TaskTestEnv $s; Restore-TaskTestEnv $null } catch { $threwNull = $true }
    Check "a null task and a null restore are harmless (no throw)" $threwNull "False"
    Check "a null task changes nothing"                           (Env $A) "ambient"

    # ---- 3. Invoke-Test ------------------------------------------------------------------------
    Write-Host "-- Invoke-Test (real function)"
    $wt = Join-Path $tmpRoot "wt"
    New-Item -ItemType Directory -Path $wt -Force | Out-Null
    $print = @($psExe, "-NoProfile", "-Command", "[Environment]::GetEnvironmentVariable('$A')")
    [Environment]::SetEnvironmentVariable($A, "ambient")

    $r = Invoke-Test ([pscustomobject]@{ id = "t"; testDir = "."; testCmd = $print; testEnv = [pscustomobject]@{ $A = "pinned" } }) $wt
    Check "the test command sees a pinned value"                  (($r.Output -join "").Trim()) "pinned"
    Check "the process is restored after the command"             (Env $A) "ambient"

    $r = Invoke-Test ([pscustomobject]@{ id = "t"; testDir = "."; testCmd = $print; testEnv = [pscustomobject]@{ $A = $null } }) $wt
    Check "the test command sees an unset variable"               (($r.Output -join "").Trim()) ""
    Check "the process is restored after an unset"                (Env $A) "ambient"

    $r = Invoke-Test ([pscustomobject]@{ id = "t"; testDir = "."; testCmd = $print }) $wt
    Check "no testEnv: the test command sees the ambient value"   (($r.Output -join "").Trim()) "ambient"

    $failing = @($psExe, "-NoProfile", "-Command", "exit 7")
    $r = Invoke-Test ([pscustomobject]@{ id = "t"; testDir = "."; testCmd = $failing; testEnv = [pscustomobject]@{ $A = "pinned" } }) $wt
    Check "a failing command still reports its exit code"         $r.ExitCode 7
    Check "the process is restored after a failing command"       (Env $A) "ambient"

    # Run-Native runs under "Continue", so a missing command or directory does not throw out of it.
    # To prove the restore sits in a `finally`, swap in a runner that does, call the real
    # Invoke-Test, and put the real runner back.
    function script:Run-Native { throw "boom" }
    $threw = $false
    try {
        Invoke-Test ([pscustomobject]@{ id = "t"; testDir = "."; testCmd = $print; testEnv = [pscustomobject]@{ $A = "pinned" } }) $wt | Out-Null
    } catch { $threw = $true }
    Import-Functions $ScriptPath @("Run-Native")
    Check "an exception in the command runner propagates (the premise of the next check)" $threw "True"
    Check "the process is restored even when the runner throws"   (Env $A) "ambient"

    [Environment]::SetEnvironmentVariable($A, $null); [Environment]::SetEnvironmentVariable($B, $null)

    # ---- 4. end to end ---------------------------------------------------------------------------
    Write-Host "-- end to end: the real test-tasks.ps1, a fixture repo, a stand-in opencode"
    $fx = Join-Path $tmpRoot "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $fx $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $fx "tests/test-tasks.ps1")

    $repo = Join-Path $fx "repo"
    git -C $repo init -q
    git -C $repo symbolic-ref HEAD refs/heads/main
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    # The task's "suite": fails the baseline if DATABASE_URL is not what the task's mode says, so a
    # gate that ran under the wrong environment cannot go green. Once the model's test.txt exists it
    # also needs src.txt fixed - which is what makes failsOnOld (src reverted, test kept) fail.
    @'
param([ValidateSet('unset','ambient','pinned')][string]$Mode)
$v = [Environment]::GetEnvironmentVariable('DATABASE_URL')
if ($Mode -eq 'unset'   -and $v)                      { Write-Host "ENV WRONG: DATABASE_URL=$v (wanted unset)"; exit 3 }
if ($Mode -eq 'ambient' -and $v -ne 'ambient-value')  { Write-Host "ENV WRONG: DATABASE_URL=$v (wanted ambient-value)"; exit 4 }
if ($Mode -eq 'pinned'  -and $v -ne 'pinned-value')   { Write-Host "ENV WRONG: DATABASE_URL=$v (wanted pinned-value)"; exit 5 }
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
if ((Test-Path test.txt) -and $src -ne 'fixed') { Write-Host "Tests  1 failed (1)"; exit 1 }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()

    function New-FixtureTask([string]$id, [string]$mode, $testEnv) {
        $t = [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            baselineExpect = @{ testsTotal = 1; testsPass = 1 }
            allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1", "-Mode", $mode)
            installFlags = @(); prompt = "fix it"
        }
        if ($null -ne $testEnv) { $t.testEnv = $testEnv }
        return $t
    }
    @{ tasks = @(
        (New-FixtureTask "fx-unset"   "unset"   ([ordered]@{ DATABASE_URL = $null })),
        (New-FixtureTask "fx-ambient" "ambient" $null),
        (New-FixtureTask "fx-pinned"  "pinned"  ([ordered]@{ DATABASE_URL = "pinned-value" }))
    ) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fx "tests/tasks/manifest.json")

    # Stand-in opencode: answers --version and `debug config`, and for `run` records the environment
    # the MODEL's process was started with, makes the "model's" change, and prints a minimal event stream.
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    $v = [Environment]::GetEnvironmentVariable('DATABASE_URL')
    Add-Content -LiteralPath $env:FIXTURE_OUT -Value ("{0} DATABASE_URL={1}" -f (Split-Path -Leaf $dir), $(if ($v) { $v } else { '<unset>' }))
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value 'a test'
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $fx "bin/standin.ps1")
    $bin = Join-Path $fx "bin"
    if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    } else {
        "#!/bin/sh`nexec `"$psExe`" -NoProfile -File `"$bin/standin.ps1`" `"`$@`"`n" | Set-Content -LiteralPath (Join-Path $bin "opencode") -NoNewline
        chmod +x (Join-Path $bin "opencode")
    }

    $env:FIXTURE_OUT = Join-Path $fx "saw.txt"
    $env:DATABASE_URL = "ambient-value"
    if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath() }
    $env:PATH = "$bin$([System.IO.Path]::PathSeparator)$env:PATH"
    $output = & (Join-Path $fx "tests/test-tasks.ps1") -Task fx-unset, fx-ambient, fx-pinned -Model fixture/m -SkipInstall -RunTimeout 120 *>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $env:PATH = $origPath
    if ($exitCode -ne 0) { Write-Host $output }

    Check "the harness run exits 0 (every gate green in every environment)" $exitCode 0
    $saw = @{}
    foreach ($line in @(Get-Content -LiteralPath $env:FIXTURE_OUT)) { $p = $line -split ' DATABASE_URL=', 2; $saw[$p[0]] = $p[1] }
    Check "the model's process: pinned to unset sees nothing"     $saw["fx-unset"] "<unset>"
    Check "the model's process: no pin sees the ambient value (no leak from the previous task)" $saw["fx-ambient"] "ambient-value"
    Check "the model's process: a pinned value is what it sees"   $saw["fx-pinned"] "pinned-value"
    Check "the harness process has its original environment back" (Env "DATABASE_URL") "ambient-value"

    $results = Join-Path $fx "tests/results"
    $json = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $results -Filter "tasks-fx-*.json")) { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; $json[$j.taskId] = $j }
    Check "three graded runs were recorded"                       $json.Count 3
    foreach ($id in @("fx-unset", "fx-ambient", "fx-pinned")) {
        $g = $json[$id].gates
        Check "$id gates (scope/suite/failsOnOld)"                ("$($g.scope)/$($g.suite)/$($g.failsOnOld)") "PASS/PASS/PASS"
    }
    Check "run JSON records testEnv: unset"                       (Show $json["fx-unset"].testEnv.DATABASE_URL) "<unset>"
    $recorded = $json["fx-unset"].testEnv
    Check "run JSON records the pin's name (null is recorded, not dropped)" ([bool]($null -ne $recorded -and $recorded.PSObject.Properties["DATABASE_URL"])) "True"
    Check "run JSON records testEnv: a pinned value"              $json["fx-pinned"].testEnv.DATABASE_URL "pinned-value"
    Check "run JSON records no testEnv for an unpinned task"      ($null -eq $json["fx-ambient"].testEnv) "True"
}
finally {
    $env:PATH = $origPath
    $env:TEMP = $origTemp
    $env:FIXTURE_OUT = $origFixtureOut
    [Environment]::SetEnvironmentVariable("DATABASE_URL", $origDb)
    [Environment]::SetEnvironmentVariable($A, $null)
    [Environment]::SetEnvironmentVariable($B, $null)
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail -gt 0) { Write-Host "RESULT: $($script:fail) check(s) FAILED"; exit 1 }
Write-Host "RESULT: all checks passed"
exit 0

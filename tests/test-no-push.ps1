# test-no-push.ps1 - regression guard for the harness's no-push guard (Set-NoPushEnv)
#
# Why this exists: a task worktree is a checkout of the owner's real repo with
# `origin` set, and the desktop is signed in to git and gh. The stretch-v06 task
# replays the owner's "if there's anything worth PRing, do it" (2026-10-06), so
# a model could push a branch or open a pull request on the real repo. For the
# opencode runs, test-tasks.ps1 rewrites every network push URL to an
# unreachable host (git's GIT_CONFIG_* environment, no config file touched) and
# hands gh a token GitHub rejects.
#
# What it does: pulls the REAL Set-NoPushEnv and Restore-TaskTestEnv out of
# test-tasks.ps1 and checks them against throwaway repos (https, git@ and ssh://
# remotes rewritten for push only, fetch URLs untouched, a local file push still
# works, an existing GIT_CONFIG_* entry kept, everything restored afterwards);
# then runs the real test-tasks.ps1 end to end with a stand-in opencode that
# reports the push URL and token it sees. No network is contacted: the rewritten
# host is under .invalid. Exit 1 on any failure.
#
# Usage:  .\tests\test-no-push.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$hostAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:NoPushHost' }, $true)) | Select-Object -First 1
if (-not $hostAst) { Write-Host "FAIL: `$script:NoPushHost not found in $ScriptPath"; exit 2 }
Invoke-Expression $hostAst.Extent.Text
foreach ($name in "Set-NoPushEnv", "Restore-TaskTestEnv") {
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function GitOut([string]$repo) { $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; $o = & git -C $repo @args 2>&1; $ErrorActionPreference = $prev; return ($o | Out-String).Trim() }

$guardVars = @("GIT_CONFIG_COUNT", "GH_TOKEN", "GITHUB_TOKEN") + @(0..7 | ForEach-Object { "GIT_CONFIG_KEY_$_"; "GIT_CONFIG_VALUE_$_" })
$before = @{}; foreach ($v in $guardVars) { $before[$v] = [Environment]::GetEnvironmentVariable($v) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nopush-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
try {
    Write-Host "-- Set-NoPushEnv (real function)"
    $repo = Join-Path $tmp "repo"; $bare = Join-Path $tmp "local.git"
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    git -C $repo commit -q --allow-empty -m base
    git init -q --bare $bare
    git -C $repo remote add origin "https://github.com/example/real.git"
    git -C $repo remote add scp "git@github.com:example/real.git"
    git -C $repo remote add sshurl "ssh://git@github.com/example/real.git"
    git -C $repo remote add local $bare
    # A GIT_CONFIG_* entry the process already had must survive.
    $env:GIT_CONFIG_COUNT = "1"; $env:GIT_CONFIG_KEY_0 = "test.marker"; $env:GIT_CONFIG_VALUE_0 = "kept"
    Remove-Item Env:GH_TOKEN, Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    Check "before: origin pushes to GitHub"                      (GitOut $repo remote get-url --push origin) "https://github.com/example/real.git"

    $saved = Set-NoPushEnv
    Check "https remote: push URL rewritten"                     ((GitOut $repo remote get-url --push origin).StartsWith($script:NoPushHost)) "True"
    Check "...its fetch URL untouched"                           (GitOut $repo remote get-url origin) "https://github.com/example/real.git"
    Check "git@ remote: push URL rewritten"                      ((GitOut $repo remote get-url --push scp).StartsWith($script:NoPushHost)) "True"
    Check "ssh:// remote: push URL rewritten"                    ((GitOut $repo remote get-url --push sshurl).StartsWith($script:NoPushHost)) "True"
    $env:GIT_TERMINAL_PROMPT = "0"
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $pushOut = (& git -C $repo push origin HEAD:refs/heads/x 2>&1 | Out-String); $pushExit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    Remove-Item Env:GIT_TERMINAL_PROMPT
    Check "a real push to origin fails"                          ($pushExit -ne 0) "True"
    Check "...at the unreachable host, never GitHub"             ($pushOut -match 'push-disabled-by-test-tasks\.invalid') "True"
    Check "a local file remote still pushes"                     ((& git -C $repo push -q local HEAD:refs/heads/ok 2>&1 | Out-String).Trim() + "exit$LASTEXITCODE") "exit0"
    Check "the existing GIT_CONFIG entry still applies"          (GitOut $repo config --get test.marker) "kept"
    Check "gh gets a token GitHub rejects"                       $env:GH_TOKEN "push-disabled-by-test-tasks"
    Restore-TaskTestEnv $saved
    Check "restored: GIT_CONFIG_COUNT back to 1"                 $env:GIT_CONFIG_COUNT "1"
    Check "...no extra GIT_CONFIG_KEY left"                      ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable("GIT_CONFIG_KEY_1"))) "True"
    Check "...GH_TOKEN gone again"                               ([string]::IsNullOrEmpty($env:GH_TOKEN)) "True"
    Check "...origin pushes to GitHub again"                     (GitOut $repo remote get-url --push origin) "https://github.com/example/real.git"
    foreach ($v in "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0") { [Environment]::SetEnvironmentVariable($v, $before[$v]) }

    Write-Host "-- end to end: the real test-tasks.ps1, a stand-in opencode that reports what it sees"
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $e2e "tests") -Recurse -Force
    $frepo = Join-Path $e2e "repo"
    git -C $frepo init -q
    git -C $frepo config user.email "t@example.invalid"
    git -C $frepo config user.name "t"
    git -C $frepo remote add origin "https://example.invalid/owner/real.git"
    Set-Content -LiteralPath (Join-Path $frepo "src.txt") -Value "buggy"
    'Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $frepo "check.ps1")
    git -C $frepo add -A
    git -C $frepo commit -q -m base
    $fbase = (git -C $frepo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-nopush"; title = "fx"; repo = $frepo; branch = "bench/fx"; benchBaseCommit = $fbase
        allowFiles = @("src.txt"); srcRevertFiles = @("src.txt"); testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt, and if there's anything worth PRing, do it" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
Add-Content -LiteralPath $env:FIXTURE_SEEN -Value ("push=" + (git -C $dir remote get-url --push origin))
Add-Content -LiteralPath $env:FIXTURE_SEEN -Value ("gh=" + $env:GH_TOKEN)
Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
'{"type":"tool_use","sessionID":"s","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
'{"type":"step_finish","sessionID":"s","part":{"reason":"stop","tokens":{"input":100,"output":5,"cache":{"read":0,"write":0}}}}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $e2e "bin/standin.ps1")
    $bin = Join-Path $e2e "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $env:FIXTURE_SEEN = Join-Path $e2e "seen.txt"
    try {
        $null = & (Join-Path $e2e "tests/test-tasks.ps1") -Task fx-nopush -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_SEEN -ErrorAction SilentlyContinue
    }
    $seen = @(Get-Content -LiteralPath (Join-Path $e2e "seen.txt"))
    $j = Get-ChildItem (Join-Path $e2e "tests/results") -Filter "tasks-fx-nopush-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "the model's process sees origin pushing nowhere"     (($seen | Where-Object { $_ -like 'push=*' }) -replace '^push=', '').StartsWith($script:NoPushHost) "True"
    Check "...and a rejected gh token"                          ($seen | Where-Object { $_ -like 'gh=*' }) "gh=push-disabled-by-test-tasks"
    Check "the run JSON records the guard"                      ("$($j.pushGuard)" -like 'on *') "True"
    Check "the harness process gets its environment back"       ([string]::IsNullOrEmpty($env:GH_TOKEN) -and [string]::IsNullOrEmpty($env:GIT_CONFIG_COUNT)) "True"
} finally {
    foreach ($v in $guardVars) { [Environment]::SetEnvironmentVariable($v, $before[$v]) }
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

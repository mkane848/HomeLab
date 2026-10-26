# test-agent-shell.ps1 - regression guard for the agent's shell (Get-AgentShellPath,
# Start-AgentRunEnv / Stop-AgentRunEnv and Test-AgentTools in
# tests/agents/opencode.ps1; `agentShell` in test-tasks.ps1).
#
# Why this exists: opencode 1.18.34 runs the model's shell commands in the
# config's `shell`, else $env:SHELL, else the first of pwsh, powershell, Git
# Bash and cmd it finds on PATH (packages/core/src/shell.ts), and it does not
# accept a 0-byte Store app alias. node3's PowerShell 7 is the Store install,
# whose only pwsh.exe on PATH is such an alias, so every node3 run's commands
# went to Windows PowerShell 5.1 ("Desktop 5.1.26100", checked live on
# 2026-10-26), where scripts are Restricted: 139 of 140 transcripts of
# 2026-10-24/25 hit "npm.ps1 cannot be loaded" at least once. The adapter now
# hands opencode this process's own pwsh.exe by full path for every run
# (OPENCODE_CONFIG_CONTENT, merged after every config file), and the pre-run
# check refuses a shell that is not PowerShell 7.
#
# What it does:
#   1. Get-AgentShellPath is $PSHOME's pwsh.exe, a real file.
#   2. The REAL Start-AgentRunEnv / Stop-AgentRunEnv: with no
#      OPENCODE_CONFIG_CONTENT, one holding a JSON object (kept, the shell
#      added, restored after), and one that is not an object (left alone, no
#      shell recorded).
#   3. The REAL Test-AgentTools against a stand-in opencode: ok records the
#      shell and "Core 7.x"; a shell path that does not exist, and (on
#      Windows) Windows PowerShell 5.1 as the shell, are not ok and opencode is
#      never asked.
#   4. The REAL test-tasks.ps1 end to end with the opencode adapter and a
#      stand-in opencode that records the OPENCODE_CONFIG_CONTENT it was run
#      with: it saw {"shell": <that pwsh.exe>}, the run JSON records
#      agentShell, and the variable is gone afterwards.
#   5. Live, the real opencode (must be 1.18.34): `opencode debug config`
#      resolves `shell` to that path inside the run environment only.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-agent-shell.ps1 [-ScriptPath <a test-tasks.ps1>] [-AdapterPath <an opencode.ps1>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$AdapterPath = (Join-Path $PSScriptRoot "agents\opencode.ps1")
)

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
foreach ($name in "ConvertTo-WindowsArgument", "Run-Native", "Run-NativeTimed") {
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}
. $AdapterPath

$script:fail = 0
# The `shell` in a JSON config string, or "" (null or not JSON: a control's adapter).
function ShellOf([string]$json) { if (-not $json) { return "" }; try { return [string]($json | ConvertFrom-Json -ErrorAction Stop).shell } catch { return "" } }
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$realVersion = Get-AgentVersion
$psExe = (Get-Process -Id $PID).Path
$want = Join-Path $PSHOME $(if ($IsWindows) { "pwsh.exe" } else { "pwsh" })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agent-shell-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$savedPath = $env:PATH
$savedContent = [Environment]::GetEnvironmentVariable("OPENCODE_CONFIG_CONTENT")
try {
    Write-Host "-- Get-AgentShellPath"
    # An adapter without it (main before 2026-10-26) fails here, not with an error.
    Check "the adapter defines Get-AgentShellPath"       ([bool](Get-Command Get-AgentShellPath -ErrorAction SilentlyContinue)) "True"
    if (-not (Get-Command Get-AgentShellPath -ErrorAction SilentlyContinue)) { function Get-AgentShellPath { "" } }
    Check "it is this process's own pwsh, in `$PSHOME"   (Get-AgentShellPath) $want
    Check "...a real file"                               (Test-Path -LiteralPath (Get-AgentShellPath) -PathType Leaf) "True"

    Write-Host "-- Start-AgentRunEnv / Stop-AgentRunEnv"
    Remove-Item Env:OPENCODE_CONFIG_CONTENT -ErrorAction SilentlyContinue
    $s = Start-AgentRunEnv -Plugins @()
    Check "no OPENCODE_CONFIG_CONTENT before: the shell is set"  (ShellOf $env:OPENCODE_CONFIG_CONTENT) $want
    Check "...and the state names it"                            $s.Shell $want
    $null = Stop-AgentRunEnv -State $s
    Check "...and afterwards the variable is gone"               (Test-Path Env:OPENCODE_CONFIG_CONTENT) "False"

    $env:OPENCODE_CONFIG_CONTENT = '{"username":"fx","tool_output":{"max_bytes":1}}'
    $s = Start-AgentRunEnv -Plugins @()
    $c = $env:OPENCODE_CONFIG_CONTENT | ConvertFrom-Json
    Check "a caller's JSON object is kept, the shell added"      ("{0}|{1}|{2}" -f $c.username, $c.tool_output.max_bytes, $c.shell) "fx|1|$want"
    $null = Stop-AgentRunEnv -State $s
    Check "...and restored exactly afterwards"                   $env:OPENCODE_CONFIG_CONTENT '{"username":"fx","tool_output":{"max_bytes":1}}'

    $env:OPENCODE_CONFIG_CONTENT = 'not json'
    $s = Start-AgentRunEnv -Plugins @()
    Check "a value that is not a JSON object is left alone"      $env:OPENCODE_CONFIG_CONTENT "not json"
    Check "...and no shell is recorded"                          ($null -eq $s.Shell) "True"
    $null = Stop-AgentRunEnv -State $s
    Check "...nor changed afterwards"                            $env:OPENCODE_CONFIG_CONTENT "not json"
    Remove-Item Env:OPENCODE_CONFIG_CONTENT -ErrorAction SilentlyContinue

    Write-Host "-- Test-AgentTools: the shell (a stand-in opencode)"
    $bin = Join-Path $tmp "bin"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    @'
@echo off
echo %*>>"%FX_SH_LOG%"
if "%~1"=="--version" (echo 1.18.34& exit /b 0)
echo [{"entry":{"path":"probe.txt"},"line":1,"text":"x %~4 y"}]
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $env:PATH = "$bin;$savedPath"
    $env:FX_SH_LOG = Join-Path $tmp "calls.txt"
    $r = Test-AgentTools -Version "1.18.34"
    Check "ok: checked and ok"                                   ("{0}|{1}" -f $r.checked, $r.ok) "True|True"
    Check "...the shell is recorded"                             $r.shell $want
    Check "...as PowerShell 7 (Core)"                            ([bool]($r.shellVersion -match '^Core 7\.\d+\.\d+')) "True"
    Check "...and the detail names it"                           ([bool]($r.detail -match '; shell Core 7\.')) "True"

    $before = @(Get-Content -LiteralPath $env:FX_SH_LOG -ErrorAction SilentlyContinue).Count
    $missing = Join-Path $tmp "no\pwsh.exe"
    function Get-AgentShellPath { $missing }
    $r = Test-AgentTools -Version "1.18.34"
    Check "a shell that does not exist: not ok"                  ("{0}|{1}" -f $r.checked, $r.ok) "True|False"
    Check "...and the detail says so"                            ([bool]($r.detail -match "not PowerShell 7: .* does not exist")) "True"
    Check "...and opencode is never asked"                       (@(Get-Content -LiteralPath $env:FX_SH_LOG -ErrorAction SilentlyContinue).Count) $before
    $winps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if ($IsWindows -and (Test-Path -LiteralPath $winps)) {
        function Get-AgentShellPath { $winps }
        $r = Test-AgentTools -Version "1.18.34"
        Check "Windows PowerShell 5.1 as the shell: not ok"     ("{0}|{1}" -f $r.checked, $r.ok) "True|False"
        Check "...and the detail names the edition"            ([bool]($r.detail -match "reports 'Desktop 5\.1")) "True"
    } else {
        Write-Host "SKIP no Windows PowerShell here"
    }
    . $AdapterPath
    $env:PATH = $savedPath
    Remove-Item Env:FX_SH_LOG -ErrorAction SilentlyContinue

    Write-Host "-- test-tasks.ps1 end to end (the opencode adapter, a stand-in opencode)"
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    New-Item -ItemType Directory -Path (Join-Path $e2e "tests/agents") -Force | Out-Null
    Copy-Item -LiteralPath $AdapterPath -Destination (Join-Path $e2e "tests/agents/opencode.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $e2e "tests") -Recurse -Force
    $repo = Join-Path $e2e "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    'Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-shell"; title = "fx"; repo = $repo; branch = "bench/fx-shell"; benchBaseCommit = $base
        scope = "guardrails"; testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    # Stand-in opencode: 1.18.34, a working ripgrep probe, an empty config; its
    # run records the OPENCODE_CONFIG_CONTENT it inherited, then edits src.txt.
    @'
$a = @($args)
if ($a[0] -eq '--version') { '1.18.34'; exit 0 }
if ($a[0] -eq 'debug' -and $a[1] -eq 'rg') { '[{"entry":{"path":"probe.txt"},"line":1,"text":"x ' + $a[3] + ' y"}]'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    Set-Content -LiteralPath $env:FX_SEEN -Value ([string]$env:OPENCODE_CONFIG_CONTENT)
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $e2e "bin/standin.ps1")
    $ebin = Join-Path $e2e "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$ebin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $ebin "opencode.cmd") -Encoding ascii
    $env:FX_SEEN = Join-Path $tmp "seen.txt"
    $env:PATH = "$ebin;$savedPath"
    Remove-Item Env:OPENCODE_CONFIG_CONTENT -ErrorAction SilentlyContinue
    try {
        $log = & (Join-Path $e2e "tests/test-tasks.ps1") -Task fx-shell -Model fixture/m -SkipInstall -RunTimeout 60 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
    }
    $seen = if (Test-Path -LiteralPath $env:FX_SEEN) { (Get-Content -Raw -LiteralPath $env:FX_SEEN).Trim() } else { "" }
    Remove-Item Env:FX_SEEN -ErrorAction SilentlyContinue
    $jf = Get-ChildItem (Join-Path $e2e "tests/results") -Filter "tasks-fx-shell-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
    $j = if ($jf) { Get-Content -Raw -LiteralPath $jf.FullName | ConvertFrom-Json } else { $null }
    # The exit is not asserted: the fixture writes no test, so another gate may fail.
    Check "the run is graded (a run JSON, suite PASS)"           ("{0}|{1}" -f ($null -ne $j), $j.gates.suite) "True|PASS"
    Check "opencode ran with the shell set to that pwsh"         (ShellOf $seen) $want
    Check "the run JSON records agentShell"                      $j.agentShell $want
    Check "...and agentTools the shell's version"               ([bool]($j.agentTools.shellVersion -match '^Core 7\.')) "True"
    Check "the variable is gone after the harness"               (Test-Path Env:OPENCODE_CONFIG_CONTENT) "False"

    Write-Host "-- live: the real opencode"
    if ($realVersion -ne "1.18.34") {
        Check "installed opencode is 1.18.34 (else re-read packages/core/src/shell.ts and config.ts)" $realVersion "1.18.34"
    } else {
        $s = Start-AgentRunEnv -Plugins @()
        try { $cfg = (opencode debug config 2>$null | Out-String) | ConvertFrom-Json } finally { $null = Stop-AgentRunEnv -State $s }
        Check "opencode resolves shell to that pwsh in the run environment" $cfg.shell $want
        $cfg = (opencode debug config 2>$null | Out-String) | ConvertFrom-Json
        Check "...and not outside it"                            ($cfg.shell -ne $want) "True"
    }
} finally {
    $env:PATH = $savedPath
    if ($null -ne $savedContent) { $env:OPENCODE_CONFIG_CONTENT = $savedContent } else { Remove-Item Env:OPENCODE_CONFIG_CONTENT -ErrorAction SilentlyContinue }
    Remove-Item Env:FX_SH_LOG, Env:FX_SEEN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

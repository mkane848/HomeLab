# protects: Pre-run check that the agent's own tools (ripgrep search) work
# run-after: The check, how a run is launched, or any opencode upgrade
# test-agent-tools.ps1 - regression guard for the pre-run check of the agent's
# own tools (Test-AgentTools in tests/agents/opencode.ps1, its call in
# test-tasks.ps1).
#
# Why this exists: on 2026-10-21 node3 ran a 15-task round as a scheduled task.
# opencode's grep and glob run ripgrep, which opencode 1.18.34 finds on PATH,
# else in ~/.cache/opencode/bin, else downloads and unpacks with Windows
# PowerShell's Expand-Archive; inside the task that unpacking failed ("module
# could not be loaded"), so every grep and glob call errored (83 calls in 12 of
# 15 runs). Nothing failed as infrastructure: the model searched blind and the
# round read 10 of 15 against the desktop's 47 of 60. The harness now runs
# `opencode debug rg search` (the same lookup, no model) in a throwaway folder
# before any task and refuses to run when it does not find the probe file.
#
# What it does:
#   1. The REAL Test-AgentTools (with the REAL Run-NativeTimed, Run-Native and
#      ConvertTo-WindowsArgument from test-tasks.ps1) against a stand-in
#      `opencode` first on PATH: a search that finds the probe (ok), one that
#      fails like node3's (exit 1), one that exits 0 without finding it, one
#      that hangs (timed out, ended), and another opencode version (not checked,
#      opencode never called). It runs in its own folder, which is removed.
#   2. The REAL test-tasks.ps1 end to end with a fixture adapter whose
#      Test-AgentTools says broken, not checked or ok: broken is exit 1 with
#      nothing run (no agent call, no run JSON); not checked is a WARN and the
#      run is graded; the run JSON records `agentTools`; -DryRun never checks.
#   3. Live, the real opencode (which must be 1.19.5): the search works, and
#      with ripgrep unreachable (not on PATH, an empty cache, downloads through
#      a dead proxy) it does not.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-agent-tools.ps1 [-ScriptPath <a test-tasks.ps1>] [-AdapterPath <an opencode.ps1>]
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
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

# The real opencode, before any stand-in goes on PATH.
$realVersion = Get-AgentVersion
$psExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agent-tools-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$savedPath = $env:PATH
try {
    Write-Host "-- Test-AgentTools (the real function, a stand-in opencode)"
    $bin = Join-Path $tmp "bin"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    # Logs its folder and arguments, then answers per FX_RG_MODE. %~4 is the nonce
    # (`debug rg search <nonce>`).
    @'
@echo off
echo %CD%^|%*>>"%FX_RG_LOG%"
if "%~1"=="--version" (echo 1.19.5& exit /b 0)
if "%FX_RG_MODE%"=="ok" (echo [{"entry":{"path":"probe.txt"},"line":1,"text":"x %~4 y"}]& exit /b 0)
if "%FX_RG_MODE%"=="fail" (echo Error: Unexpected error& echo ripgrep execution failed& exit /b 1)
if "%FX_RG_MODE%"=="nomatch" (echo {}& exit /b 0)
if "%FX_RG_MODE%"=="hang" (ping -n 60 127.0.0.1 >nul& exit /b 0)
exit /b 9
'@ | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $env:PATH = "$bin;$savedPath"
    $env:FX_RG_LOG = Join-Path $tmp "rg-calls.txt"

    $env:FX_RG_MODE = "ok"
    $r = Test-AgentTools -Version "1.19.5"
    Check "a search that finds the probe: checked and ok" ("{0}|{1}" -f $r.checked, $r.ok) "True|True"
    $call = @(Get-Content -LiteralPath $env:FX_RG_LOG)[-1]
    Check "...asked 'opencode debug rg search <nonce>'"([bool]($call -match '\|debug rg search toolprobe[0-9a-f]{16}$')) "True"
    $probeDir = ($call -split '\|')[0]
    Check "...from its own throwaway folder" ([bool]((Split-Path $probeDir -Leaf) -match '^agenttools-')) "True"
    Check "...which is removed afterwards" (Test-Path -LiteralPath $probeDir) "False"
    Check "...and the seconds it took are recorded" ($null -ne $r.seconds) "True"

    $env:FX_RG_MODE = "fail"
    $r = Test-AgentTools -Version "1.19.5"
    Check "node3's failure (exit 1): checked, not ok" ("{0}|{1}" -f $r.checked, $r.ok) "True|False"
    Check "...and the detail carries the exit and opencode's error" ([bool]($r.detail -match 'exit 1' -and $r.detail -match 'ripgrep execution failed')) "True"

    $env:FX_RG_MODE = "nomatch"
    $r = Test-AgentTools -Version "1.19.5"
    Check "exit 0 without the probe file: not ok" ("{0}|{1}" -f $r.ok, [bool]($r.detail -match 'was not found')) "False|True"

    $env:FX_RG_MODE = "hang"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Test-AgentTools -Version "1.19.5" -TimeoutSec 3
    Check "a hang: not ok, timed out" ("{0}|{1}" -f $r.ok, [bool]($r.detail -match 'timed out after 3 s')) "False|True"
    Check "...and ended within the limit" ([bool]($sw.Elapsed.TotalSeconds -lt 30)) "True"
    $left = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '-n 60 127\.0\.0\.1' })
    Check "...with nothing left running" $left.Count 0

    $env:FX_RG_MODE = "ok"
    $before = @(Get-Content -LiteralPath $env:FX_RG_LOG).Count
    $r = Test-AgentTools -Version "1.18.35"
    Check "another opencode version: not checked" ("{0}|{1}" -f $r.checked, [bool]($r.detail -match '1\.18\.35 is not 1\.19\.5')) "False|True"
    Check "...and opencode is not asked" (@(Get-Content -LiteralPath $env:FX_RG_LOG).Count) $before
    $r = Test-AgentTools
    Check "the version defaults to Get-AgentVersion (the stand-in says 1.19.5)" ("{0}|{1}" -f $r.checked, $r.ok) "True|True"
    $env:PATH = $savedPath
    Remove-Item Env:FX_RG_MODE, Env:FX_RG_LOG -ErrorAction SilentlyContinue

    Write-Host "-- test-tasks.ps1 end to end (a fixture adapter)"
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "tests/agents", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $e2e "tests") -Recurse -Force
    $frepo = Join-Path $e2e "repo"
    git -C $frepo init -q
    git -C $frepo config user.email "t@example.invalid"
    git -C $frepo config user.name "t"
    Set-Content -LiteralPath (Join-Path $frepo "src.txt") -Value "buggy"
    'Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $frepo "check.ps1")
    git -C $frepo add -A
    git -C $frepo commit -q -m base
    $fbase = (git -C $frepo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-tools"; title = "fx"; repo = $frepo; branch = "bench/fx-tools"; benchBaseCommit = $fbase
        scope = "guardrails"; testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    # The fixture agent: its tools check answers per FX_TOOLS and logs the call;
    # its run logs itself and edits src.txt.
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
function Test-AgentTools {
    param([string]$Version)
    Add-Content -LiteralPath $env:FX_CALLS -Value "tools|$Version"
    switch ($env:FX_TOOLS) {
        "broken" { [pscustomobject]@{ checked = $true; ok = $false; detail = "ripgrep search does not work (exit 1): ripgrep execution failed"; seconds = 1.5 } }
        "unchecked" { [pscustomobject]@{ checked = $false; ok = $null; detail = "not checked: fixture 0.1.0 is not 9.9.9"; seconds = $null } }
        default { [pscustomobject]@{ checked = $true; ok = $true; detail = "ripgrep search works"; seconds = 1.5 } }
    }
}
function Invoke-AgentRun {
    param([string]$WtPath, [string]$ModelId, [string]$Prompt, [string]$PromptHash, [int]$TimeoutSec, [string]$SessionId = "", [string]$Transcript = "")
    $out = Join-Path $env:TEMP ("fixture-run-" + [guid]::NewGuid().ToString("N") + ".log")
    Add-Content -LiteralPath $env:FX_CALLS -Value "run"
    Set-Content -LiteralPath (Join-Path $WtPath "src.txt") -Value "fixed"
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
    $resultsDir = Join-Path $e2e "tests/results"
    function Invoke-Fixture([string]$Tools, [hashtable]$Extra = @{}) {
        $env:FX_TOOLS = $Tools
        $env:FX_CALLS = Join-Path $tmp ("calls-" + [guid]::NewGuid().ToString("N") + ".txt")
        try {
            $log = & $harness -Agent fixture -Task fx-tools -Model fixture/m -SkipInstall -RunTimeout 60 -OllamaLogDir (Join-Path $e2e "no-log") @Extra *>&1 | Out-String
            $exit = $LASTEXITCODE
        } finally {
            Remove-Item Env:FX_TOOLS -ErrorAction SilentlyContinue
        }
        $calls = @(Get-Content -LiteralPath $env:FX_CALLS -ErrorAction SilentlyContinue)
        Remove-Item Env:FX_CALLS -ErrorAction SilentlyContinue
        $json = Get-ChildItem $resultsDir -Filter "tasks-fx-tools-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        $j = if ($json) { Get-Content -Raw -LiteralPath $json.FullName | ConvertFrom-Json } else { $null }
        if ($json) { Remove-Item -LiteralPath $json.FullName }
        return [pscustomobject]@{ Log = $log; Exit = $exit; Calls = $calls; Json = $j }
    }

    $b = Invoke-Fixture "broken"
    Check "broken tools: exit 1" $b.Exit 1
    Check "...says so, with the detail and the machine" ([bool]($b.Log -match "fixture's tools do not work on $([regex]::Escape([Environment]::MachineName)): ripgrep search does not work \(exit 1\)" -and $b.Log -match 'Nothing was run')) "True"
    Check "...the check got the agent's version" ($b.Calls -join ",") "tools|0.1.0"
    Check "...and nothing was run: no run JSON" ($null -eq $b.Json) "True"
    Check "...no worktree" (Test-Path -LiteralPath (Join-Path $e2e "tests/.worktrees/fx-tools")) "False"

    $u = Invoke-Fixture "unchecked"
    Check "not checked: a WARN naming why" ([bool]($u.Log -match 'WARN: fixture tools not checked: fixture 0\.1\.0 is not 9\.9\.9')) "True"
    Check "...and the run is graded" ("{0}|{1}" -f ($u.Calls -join ","), $u.Json.gates.suite) "tools|0.1.0,run|PASS"
    Check "...the run JSON records the check" ("{0}|{1}" -f $u.Json.agentTools.checked, ($null -eq $u.Json.agentTools.ok)) "False|True"

    $o = Invoke-Fixture "ok"
    Check "ok: the console says so" ([bool]($o.Log -match 'fixture tools: ripgrep search works \(1\.5 s\)')) "True"
    Check "...the run is graded" ("{0}|{1}" -f ($o.Calls -join ","), $o.Json.gates.suite) "tools|0.1.0,run|PASS"
    Check "...and the run JSON records agentTools" ("{0}|{1}|{2}|{3}" -f $o.Json.agentTools.checked, $o.Json.agentTools.ok, $o.Json.agentTools.detail, $o.Json.agentTools.seconds) "True|True|ripgrep search works|1.5"

    $d = Invoke-Fixture "broken" @{ DryRun = $true }
    Check "-DryRun (no agent runs) never checks, so broken tools do not stop it" ("{0}|{1}" -f $d.Exit, ($d.Calls -join ",")) "0|"

    Write-Host "-- live: the real opencode"
    Check "installed opencode is $script:AgentToolsCheckedVersion (else re-read packages/core/src/ripgrep/binary.ts, then move `$script:AgentToolsCheckedVersion)" $realVersion $script:AgentToolsCheckedVersion
    if ($realVersion -eq $script:AgentToolsCheckedVersion) {
        $r = Test-AgentTools
        Check "the search works here" ("{0}|{1}|{2}" -f $r.checked, $r.ok, [bool]($r.detail -match '^ripgrep search works \(opencode debug rg search found the probe file\); shell Core 7\.')) "True|True|True"
        # node3's case without breaking Windows PowerShell: ripgrep nowhere opencode
        # looks (no rg.exe on PATH, an empty cache) and its download unreachable.
        $saved = @{}
        foreach ($n in "PATH", "XDG_CACHE_HOME", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY") { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
        try {
            $env:PATH = (@($savedPath -split ';' | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $_ "rg.exe")) }) -join ';')
            $env:XDG_CACHE_HOME = Join-Path $tmp "empty-cache"
            $env:HTTPS_PROXY = "http://127.0.0.1:9"; $env:HTTP_PROXY = $env:HTTPS_PROXY
            Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
            $r = Test-AgentTools -TimeoutSec 120
            Check "ripgrep unreachable: not ok" ("{0}|{1}" -f $r.checked, $r.ok) "True|False"
            Check "...and the detail says why" ([bool]($r.detail -match '^ripgrep search does not work \(exit \d+\)')) "True"
        } finally {
            foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $(if ($null -ne $saved[$n]) { $saved[$n] } else { [NullString]::Value })) }
        }
    }
} finally {
    $env:PATH = $savedPath
    Remove-Item Env:FX_RG_MODE, Env:FX_RG_LOG, Env:FX_TOOLS, Env:FX_CALLS -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

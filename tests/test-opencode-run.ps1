# test-opencode-run.ps1 - regression guard for how test-tasks.ps1 runs opencode
#
# Why this exists: Invoke-AgentRun (tests/agents/opencode.ps1, the OpenCode
# adapter) runs `opencode run` in a background job.
# On 2026-10-02 the job's own PowerShell process died under the first run of a
# 16-run batch ("The background process closed or ended abnormally",
# PSSessionStateBroken). Receive-Job raised it, the script's "Stop" made it
# terminating, and the whole batch ended with 15 runs never started. Had
# Receive-Job not thrown, the empty result would have defaulted to exit -1,
# which the caller reads as a TIMEOUT - the wrong kind of failure either way.
#
# What it does: pulls the REAL functions out of test-tasks.ps1 and loads the
# REAL adapter (so it tests the scripts as written, not a copy) and drives
# Invoke-AgentRun against a
# stand-in `opencode` first on PATH, in four modes:
#   ok    - two events, one write tool call, exit 0  -> ExitCode 0, Writes 1
#   exit3 - exit 3                                   -> ExitCode 3 (INFRA to the caller)
#   die   - kills the job's PowerShell process        -> ExitCode -2, Detail says so, no throw
#   hang  - outlives the timeout                      -> ExitCode -1 (TIMEOUT)
# Exit 1 on any failure.
#
# Usage:  .\tests\test-opencode-run.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($name in "Run-Native", "Get-TranscriptEnding", "Get-WriteCount") {
    $fn = $fns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}
# The OpenCode adapter: Invoke-AgentRun, Stop-OrphanAgent, Read-AgentEvents.
. (Join-Path $PSScriptRoot "agents\opencode.ps1")

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ocr-test-" + [guid]::NewGuid().ToString("N"))
$bin = Join-Path $tmp "bin"
$wt = Join-Path $tmp "wt"
New-Item -ItemType Directory -Force $bin, $wt | Out-Null
# Stand-in opencode. It runs inside the job's PowerShell process (an
# ExternalScript runs in-process), so "die" can kill that process for real.
Set-Content (Join-Path $bin "opencode.ps1") @'
switch ($env:OCR_TEST_MODE) {
    "ok" {
        '{"type":"step_start"}'
        '{"type":"tool_use","part":{"tool":"write"}}'
        '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":12}}}'
        exit 0
    }
    "exit3" { '{"type":"error","error":{"name":"APIError"}}'; exit 3 }
    "die"   { '{"type":"step_start"}'; Stop-Process -Id $PID -Force }
    "hang"  { Start-Sleep -Seconds 60; exit 0 }
}
'@

$savedPath = $env:PATH
$env:PATH = "$bin;$savedPath"
try {
    function Run([string]$mode, [int]$timeout = 60) {
        $env:OCR_TEST_MODE = $mode
        $r = Invoke-AgentRun -WtPath $wt -ModelId "ollama-desktop/stand-in" -Prompt "p" -PromptHash "abc123" -TimeoutSec $timeout
        if ($r.TranscriptPath) { Remove-Item -LiteralPath $r.TranscriptPath -Force -ErrorAction SilentlyContinue }
        return $r
    }

    Write-Host "-- a normal run"
    $r = Run "ok"
    Check "exit 0"                       $r.ExitCode 0
    Check "one write tool call counted"  $r.Writes 1
    Check "last step's finish reason"    $r.Ending.FinishReason "stop"

    Write-Host "-- opencode exits non-zero"
    $r = Run "exit3"
    Check "exit code passed through (INFRA to the caller)" $r.ExitCode 3

    Write-Host "-- the job's PowerShell process dies (2026-10-02)"
    $threw = $null
    $dieSw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $r = Run "die" 300 } catch { $threw = $_.Exception.Message }
    $dieSw.Stop()
    Check "no exception escapes"         $threw ""
    Check "ExitCode -2, not -1 (which means TIMEOUT)" $r.ExitCode -2
    Check "Detail names an abnormal end" ($r.Detail -like "*ended abnormally*") "True"
    Check "Detail says not graded"       ($r.Detail -like "*NOT model behaviour*") "True"
    Check "Detail carries the prompt sha" ($r.Detail -like "*abc123*") "True"
    # Detected within one 5 s slice, not by waiting out the 300 s timeout.
    # PowerShell 7 then spends ~57 s in Remove-Job on the dead job (5.1: none).
    Check "detected, not waited out (< 120 s of a 300 s timeout)" ($dieSw.Elapsed.TotalSeconds -lt 120) "True"

    Write-Host "-- timeout"
    $r = Run "hang" 3
    Check "ExitCode -1 (TIMEOUT)"        $r.ExitCode -1
    Check "Detail says timed out"        ($r.Detail -like "*timed out after 3 s*") "True"

    Write-Host "-- a run after a dead job still works"
    $r = Run "ok"
    Check "exit 0 again"                 $r.ExitCode 0
} finally {
    $env:PATH = $savedPath
    Remove-Item Env:OCR_TEST_MODE -ErrorAction SilentlyContinue
    Get-Job | Where-Object { $_.State -ne "Running" } | Remove-Job -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"

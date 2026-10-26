# protects: toolErrors recording (tools failing on every call)
# run-after: How a transcript is read or a run JSON is built
# test-tool-errors.ps1 - regression guard for `toolErrors` (Get-ToolErrors in test-tasks.ps1).
#
# Why this exists: a tool that errors on every call does not fail a run. The
# model gets the error back and works on without it, and the row reads as a
# weaker seat. On 2026-10-21 node3 had no ripgrep, so every grep and glob call of
# a 15-task round errored (83 calls in 12 runs) and the round read 10 of 15
# against 12 once fixed; no gate saw it. Every run JSON now records the errored
# calls per tool, and the console warns when a tool failed every one of at
# least 3 calls (`allFailing`).
#
# What it does:
#   1. The REAL Get-ToolErrors, with the REAL opencode Read-AgentEvents, on
#      synthetic opencode transcripts: no file, no tool calls, a mix, a tool
#      that failed 3 of 3 (listed) or 2 of 2 (too few, not listed) or 2 of 3
#      (not listed), a call with no tool name, and -MinCalls.
#   2. A replay, when this machine has the private results: over the three
#      node3 and desktop folders of 2026-10-21, `allFailing` is non-empty in
#      exactly the 9 runs of node3's broken round and in none of the 75 others.
#   3. The REAL test-tasks.ps1 end to end with a fixture adapter: a run whose
#      grep failed 3 of 3 warns and records it; a clean run records the counts
#      and no warning.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-tool-errors.ps1 [-ScriptPath <a test-tasks.ps1>] [-PrivateResults <folder>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$PrivateResults = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "HomeLab-private\results")
)

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq "Get-ToolErrors" } | Select-Object -First 1
if (-not $fn) { Write-Host "FAIL: Get-ToolErrors not found in $ScriptPath"; exit 1 }
Invoke-Expression $fn.Extent.Text
. (Join-Path $PSScriptRoot "agents\opencode.ps1")

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Tool([string]$name, [string]$status) {
    '{"type":"tool_use","sessionID":"s","part":{"tool":"' + $name + '","state":{"status":"' + $status + '","input":{}}}}'
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("tool-errors-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$psExe = (Get-Process -Id $PID).Path
try {
    Write-Host "-- Get-ToolErrors (the real function, opencode transcripts)"
    $r = Get-ToolErrors -Path (Join-Path $tmp "missing.jsonl")
    Check "no file: no calls, rate null, nothing failing" ("{0}|{1}|{2}" -f $r.calls, ($null -eq $r.rate), $r.allFailing.Count) "0|True|0"

    $f = Join-Path $tmp "none.jsonl"
    Set-Content -LiteralPath $f -Value @('{"type":"step_start","sessionID":"s"}', '{"type":"text","part":{"text":"hi"}}')
    $r = Get-ToolErrors -Path $f
    Check "no tool calls: zero counts" ("{0}|{1}|{2}" -f $r.calls, $r.errors, $r.allFailing.Count) "0|0|0"

    $f = Join-Path $tmp "mix.jsonl"
    Set-Content -LiteralPath $f -Value @(
        (Tool read completed), (Tool read completed), (Tool read error),
        (Tool grep error), (Tool grep error), (Tool grep error),
        (Tool glob error), (Tool glob error),
        (Tool edit completed), (Tool edit error), (Tool edit error),
        '{"type":"tool_use","part":{"state":{"status":"error"}}}',
        'not json')
    $r = Get-ToolErrors -Path $f
    Check "a mix: calls, errors, rate" ("{0}|{1}|{2}" -f $r.calls, $r.errors, $r.rate) "12|9|0.75"
    Check "...per tool" (($r.byTool.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.errors)/$($_.Value.calls)" }) -join ",") "read=1/3,grep=3/3,glob=2/2,edit=2/3,(unnamed)=1/1"
    Check "...only the tool that failed all of at least 3 calls is listed" ($r.allFailing -join ",") "grep"
    $r = Get-ToolErrors -Path $f -MinCalls 2
    Check "-MinCalls 2 lists glob too" ($r.allFailing -join ",") "grep,glob"
    $r = Get-ToolErrors -Path $f -MinCalls 4
    Check "-MinCalls 4 lists nothing" $r.allFailing.Count 0

    Write-Host "-- replay: the real runs of 2026-10-21"
    $folders = "ollama-read-budget-node3", "ollama-read-budget-node3-rg", "ollama-read-budget"
    if (@($folders | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PrivateResults $_)) }).Count -gt 0) {
        Write-Host "SKIP the private results are not on this machine ($PrivateResults)"
    } else {
        $hits = @{}; $total = @{}
        foreach ($d in $folders) {
            $hits[$d] = 0; $total[$d] = 0
            foreach ($t in Get-ChildItem -LiteralPath (Join-Path $PrivateResults $d) -Recurse -Filter "tasks-*.jsonl") {
                $total[$d]++
                if ((Get-ToolErrors -Path $t.FullName).allFailing.Count -gt 0) { $hits[$d]++ }
            }
        }
        Check "node3's broken round: 9 of its 15 runs have a tool that failed every call" ("{0}/{1}" -f $hits[$folders[0]], $total[$folders[0]]) "9/15"
        Check "...node3 with ripgrep: none of 15" ("{0}/{1}" -f $hits[$folders[1]], $total[$folders[1]]) "0/15"
        Check "...the desktop's four reps: none of 60" ("{0}/{1}" -f $hits[$folders[2]], $total[$folders[2]]) "0/60"
    }

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
    @{ tasks = @([ordered]@{ id = "fx-toolerr"; title = "fx"; repo = $frepo; branch = "bench/fx-toolerr"; benchBaseCommit = $fbase
        scope = "guardrails"; testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    # The fixture agent writes "tool|session|name|status" lines; FX_GREP says
    # whether its three grep calls error.
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
    $out = Join-Path $env:TEMP ("fixture-run-" + [guid]::NewGuid().ToString("N") + ".log")
    Set-Content -LiteralPath (Join-Path $WtPath "src.txt") -Value "fixed"
    $g = if ($env:FX_GREP -eq "broken") { "error" } else { "completed" }
    Add-Content -LiteralPath $out -Value @("start|s1", "tool|s1|grep|$g", "tool|s1|grep|$g", "tool|s1|grep|$g", "tool|s1|edit|completed", "say|s1|done", "end|s1|stop|100|5")
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
            "tool"  { $events.Add([pscustomobject]@{ Kind = "tool"; SessionId = $f[1]; Tool = $f[2]; Status = $f[3]; Input = $null; Paths = @("src.txt"); OutputChars = 0 }) }
            "say"   { $events.Add([pscustomobject]@{ Kind = "text"; SessionId = $f[1]; Text = $f[2]; CompactionContinue = $false }) }
            "end"   { $events.Add([pscustomobject]@{ Kind = "step-end"; SessionId = $f[1]; Finish = $f[2]; HasTokens = $true; Input = [int]$f[3]; Output = [int]$f[4]; Reasoning = 0; CacheRead = 0; CacheWrite = 0 }) }
        }
    }
    return , $events
}
'@ | Set-Content -LiteralPath (Join-Path $e2e "tests/agents/fixture.ps1")
    $harness = Join-Path $e2e "tests/test-tasks.ps1"
    function Invoke-Fixture([string]$Grep) {
        $env:FX_GREP = $Grep
        try { $log = & $harness -Agent fixture -Task fx-toolerr -Model fixture/m -SkipInstall -RunTimeout 60 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String }
        finally { Remove-Item Env:FX_GREP -ErrorAction SilentlyContinue }
        $json = Get-ChildItem (Join-Path $e2e "tests/results") -Filter "tasks-fx-toolerr-*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
        $j = if ($json) { Get-Content -Raw -LiteralPath $json.FullName | ConvertFrom-Json } else { $null }
        if ($json) { Remove-Item -LiteralPath $json.FullName }
        return [pscustomobject]@{ Log = $log; Json = $j }
    }
    $b = Invoke-Fixture "broken"
    if (-not $b.Json) { Write-Host (($b.Log -split "`n" | Select-Object -Last 25) -join "`n") }
    Check "grep failed 3 of 3: the console warns, naming it" ([bool]($b.Log -match 'WARN: every call of grep \(3\) errored')) "True"
    Check "...the run JSON records it" ("{0}|{1}|{2}|{3}" -f $b.Json.toolErrors.calls, $b.Json.toolErrors.errors, ($b.Json.toolErrors.allFailing -join ","), $b.Json.toolErrors.byTool.grep.errors) "4|3|grep|3"
    Check "...and the run is still graded (not graded on this)" $b.Json.gates.suite "PASS"
    $c = Invoke-Fixture "ok"
    Check "a clean run: no warning" ([bool]($c.Log -match 'WARN: every call of')) "False"
    Check "...counts recorded, nothing failing" ("{0}|{1}|{2}|{3}" -f $c.Json.toolErrors.calls, $c.Json.toolErrors.errors, $c.Json.toolErrors.allFailing.Count, $c.Json.toolErrors.rate) "4|0|0|0"
} finally {
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

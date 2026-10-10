# test-agent-adapter.ps1 - regression guard for the agent adapter boundary.
#
# Why this exists: the owner may move the daily client off OpenCode (2026-10-10),
# so the harness keeps everything OpenCode-specific in one adapter file,
# tests/agents/opencode.ps1, and reads runs only through the neutral events its
# Read-AgentEvents returns. This guard keeps that boundary from eroding.
#
# What it does:
#   1. The interface: tests/agents/opencode.ps1 defines every function the
#      harness and the batch call, and $script:AgentName.
#   2. The boundary: outside comments, test-tasks.ps1 never calls `opencode` or
#      reads its transcript format (step_finish, tool_use, part.*, sessionID),
#      and run-tasks-batch.ps1 calls `opencode` only for the OpenCode Go
#      provider (`opencode models opencode-go`, `opencode db`).
#   3. The mapping: the REAL Read-AgentEvents on a synthetic opencode transcript
#      with one line of each kind (step start and end, with and without
#      tokens; text and opencode's compaction continue message; tool calls with
#      a file path, a patch, no state; an error with a status code and URL; an
#      unknown type; a line that is not JSON) and on a missing file.
#   4. A second agent: the REAL test-tasks.ps1 end to end with -Agent fixture,
#      an adapter written here whose transcript format is not opencode's. The
#      run is graded, its writes and tokens counted, a follow-up turn reaches
#      the same session, and the run JSON records agent "fixture" with
#      opencodeVersion null.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-agent-adapter.ps1 [-ScriptPath <a test-tasks.ps1>] [-BatchPath <a run-tasks-batch.ps1>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$BatchPath = (Join-Path $PSScriptRoot "run-tasks-batch.ps1")
)

$ErrorActionPreference = "Stop"
$adapterPath = Join-Path $PSScriptRoot "agents\opencode.ps1"

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Get-CodeLines([string]$Path) {
    # Lines outside comments: tokens that are not Comment, grouped by line.
    $tokens = $null; $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
    $byLine = @{}
    foreach ($t in $tokens) {
        if ($t.Kind -eq "Comment" -or $t.Kind -eq "NewLine" -or $t.Kind -eq "EndOfInput") { continue }
        $n = $t.Extent.StartLineNumber
        $byLine[$n] = "$($byLine[$n]) $($t.Text)"
    }
    return $byLine
}

Write-Host "-- the interface (tests/agents/opencode.ps1)"
$errs = $null
$adapterAst = [System.Management.Automation.Language.Parser]::ParseFile($adapterPath, [ref]$null, [ref]$errs)
Check "the adapter parses" $errs.Count 0
$defined = @($adapterAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
$required = "Read-AgentEvents", "Get-AgentVersion", "Get-AgentConfig", "Get-AgentModelIds", "Test-AgentAutoupdatePinned",
            "Get-AgentModelSettings", "Start-AgentRunEnv", "Stop-AgentRunEnv", "Invoke-AgentRun", "Stop-OrphanAgent"
Check "every interface function is defined" (@($required | Where-Object { $defined -notcontains $_ }) -join ", ") ""
. $adapterPath
Check "AgentName" $script:AgentName "opencode"

Write-Host "-- the boundary"
$tt = Get-CodeLines $ScriptPath
$ttHits = @($tt.GetEnumerator() | Where-Object { $_.Value -cmatch '&\s+opencode\b|\bopencode\s+(run|debug|models|db|--version)\b|step_finish|tool_use|\.part\b|\bsessionID\b' } | ForEach-Object { "line $($_.Key)" })
Check "test-tasks.ps1: no opencode call or transcript-format read outside comments" ($ttHits -join ", ") ""
Check "...and it loads the adapter by -Agent" ([bool]($tt.Values -match 'agents\\\{0\}\.ps1')) "True"
$bt = Get-CodeLines $BatchPath
$btHits = @($bt.GetEnumerator() | Where-Object { $_.Value -cmatch '&\s+opencode\b|step_finish|tool_use|\.part\b|\bsessionID\b' } |
    Where-Object { $_.Value -notmatch '&\s+opencode\s+(models\s+opencode-go|db)\b' } | ForEach-Object { "line $($_.Key)" })
Check "run-tasks-batch.ps1: opencode called only for OpenCode Go (models, db)" ($btHits -join ", ") ""

Write-Host "-- Read-AgentEvents (the real adapter)"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agent-adapter-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$psExe = (Get-Process -Id $PID).Path
try {
    $lines = @(
        '{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}',
        '{"type":"tool_use","sessionID":"ses_1","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"a.ts","content":"x"},"output":"12345"}}}',
        '{"type":"tool_use","sessionID":"ses_1","part":{"tool":"patch","state":{"status":"error","input":{"patchText":"*** Begin Patch\n*** Update File: b.ts\n*** Add File: c.ts\n*** End Patch"}}}}',
        '{"type":"tool_use","part":{"tool":"read"}}',
        '{"type":"step_finish","sessionID":"ses_1","part":{"reason":"tool-calls","tokens":{"input":100,"output":20,"reasoning":5,"cache":{"read":300,"write":7}}}}',
        '{"type":"text","part":{"text":"Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed."}}',
        '{"type":"text","part":{"text":"Done."}}',
        '{"type":"step_finish","part":{"reason":"stop"}}',
        '{"type":"error","error":{"name":"APIError","data":{"message":"Insufficient funds","statusCode":402,"metadata":{"url":"https://x.invalid/v1"}}}}',
        '{"type":"something_new","sessionID":"ses_1"}',
        'not json'
    )
    $tf = Join-Path $tmp "t.jsonl"
    [IO.File]::WriteAllText($tf, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
    $ev = Read-AgentEvents -Path $tf
    Check "one event per JSON line, the bad line skipped" $ev.Count 10
    Check "kinds in order" (($ev | ForEach-Object Kind) -join ",") "step-start,tool,tool,tool,step-end,text,text,step-end,error,other"
    Check "session ids carried" (($ev | ForEach-Object { if ($_.SessionId) { $_.SessionId } else { "-" } }) -join ",") "ses_1,ses_1,ses_1,-,ses_1,-,-,-,-,ses_1"
    Check "tool: name, status, path, output size" ("{0}|{1}|{2}|{3}" -f $ev[1].Tool, $ev[1].Status, ($ev[1].Paths -join ";"), $ev[1].OutputChars) "write|completed|a.ts|5"
    Check "tool: a patch's file headers are its paths" ("{0}|{1}" -f $ev[2].Status, ($ev[2].Paths -join ";")) "error|b.ts;c.ts"
    Check "tool: no state is an empty call" ("{0}|{1}|{2}" -f $ev[3].Tool, $ev[3].Status, @($ev[3].Paths).Count) "read||0"
    Check "step end: reason and every token count" ("{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f $ev[4].Finish, $ev[4].HasTokens, $ev[4].Input, $ev[4].Output, $ev[4].Reasoning, $ev[4].CacheRead, $ev[4].CacheWrite) "tool-calls|True|100|20|5|300|7"
    Check "step end without tokens" ("{0}|{1}|{2}" -f $ev[7].Finish, $ev[7].HasTokens, ($null -eq $ev[7].Output)) "stop|False|True"
    Check "opencode's continue message is marked, the model's text is not" ("{0}|{1}" -f $ev[5].CompactionContinue, $ev[6].CompactionContinue) "True|False"
    Check "error: name, message, status, url" ("{0}|{1}|{2}|{3}" -f $ev[8].Name, $ev[8].Message, $ev[8].StatusCode, $ev[8].Url) "APIError|Insufficient funds|402|https://x.invalid/v1"
    Check "a missing file: no events" (Read-AgentEvents -Path (Join-Path $tmp "nope.jsonl")).Count 0

    Write-Host "-- a second agent: test-tasks.ps1 -Agent fixture, end to end"
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks/hidden/fx", "tests/agents", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/hidden/fx/hidden.txt") -Value "hidden test"
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    $frepo = Join-Path $e2e "repo"
    git -C $frepo init -q
    git -C $frepo config user.email "t@example.invalid"
    git -C $frepo config user.name "t"
    Set-Content -LiteralPath (Join-Path $frepo "src.txt") -Value "buggy"
    'if ((Test-Path hidden.txt) -and (Get-Content src.txt -Raw).Trim() -ne "fixed") { Write-Host "Tests  1 failed (2)"; exit 1 }; Write-Host "Tests  2 passed (2)"; exit 0' | Set-Content -LiteralPath (Join-Path $frepo "check.ps1")
    git -C $frepo add -A
    git -C $frepo commit -q -m base
    $fbase = (git -C $frepo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-agent"; title = "fx"; repo = $frepo; branch = "bench/fx-agent"; benchBaseCommit = $fbase
        grading = "acceptance"; scope = "guardrails"; acceptance = [ordered]@{ dir = "hidden/fx" }; testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt"; followUps = @("check it") }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    # The fixture agent: works in-process, writes its own transcript format
    # (one "kind|session|..." line per event), and fixes the file on turn 2.
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
function Invoke-AgentRun {
    param([string]$WtPath, [string]$ModelId, [string]$Prompt, [string]$PromptHash, [int]$TimeoutSec, [string]$SessionId = "", [string]$Transcript = "")
    $out = if ($Transcript) { $Transcript } else { Join-Path $env:TEMP ("fixture-run-" + [guid]::NewGuid().ToString("N") + ".log") }
    $sid = if ($SessionId) { $SessionId } else { "fx-session-1" }
    Add-Content -LiteralPath $env:FIXTURE_AGENT_CALLS -Value ("{0}|{1}" -f $SessionId, $Prompt)
    $lines = @("start|$sid")
    if ($SessionId) {
        Set-Content -LiteralPath (Join-Path $WtPath "src.txt") -Value "fixed"
        $lines += "tool|$sid|edit|src.txt"
    } else {
        $lines += "tool|$sid|read|src.txt"
    }
    $lines += "say|$sid|turn done"
    $lines += "end|$sid|stop|1000|50"
    Add-Content -LiteralPath $out -Value $lines
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
    $env:FIXTURE_AGENT_CALLS = Join-Path $tmp "calls.txt"
    try {
        $log = & (Join-Path $e2e "tests/test-tasks.ps1") -Agent fixture -Task fx-agent -Model fixture/m -SkipInstall -RunTimeout 60 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
        $missing = & (Join-Path $e2e "tests/test-tasks.ps1") -Agent nosuch -Task fx-agent -Model fixture/m -SkipInstall *>&1 | Out-String
        $missingExit = $LASTEXITCODE
    } finally {
        $calls = @(Get-Content -LiteralPath $env:FIXTURE_AGENT_CALLS -ErrorAction SilentlyContinue)
        Remove-Item Env:FIXTURE_AGENT_CALLS -ErrorAction SilentlyContinue
    }
    $j = Get-ChildItem (Join-Path $e2e "tests/results") -Filter "tasks-fx-agent-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    if (-not $j) { Write-Host "     no run JSON; the harness said:"; Write-Host (($log -split "`n" | Select-Object -Last 30) -join "`n") }
    Check "graded: scope, suite and hidden tests pass" ("{0}/{1}/{2}" -f $j.gates.scope, $j.gates.suite, $j.acceptance.status) "PASS/PASS/PASS"
    Check "the run JSON names the agent and its version" ("{0} {1}" -f $j.agent.name, $j.agent.version) "fixture 0.1.0"
    Check "...and opencodeVersion is null under another agent" ($null -eq $j.opencodeVersion) "True"
    Check "writes counted from the agent's own format" $j.writes 1
    Check "tokens counted from it (two turns)" ("{0}/{1}/{2}" -f $j.usage.input, $j.usage.output, $j.usage.steps) "2000/100/2"
    Check "the follow-up reached the same session" ($calls -join " || ") "|fix src.txt || fx-session-1|check it"
    Check "the sampling note is the agent's" $j.samplingControl "fixture agent: nothing to pin"
    Check "the console names the agent" ([bool]($log -match 'fixture run')) "True"
    Check "an agent with no adapter: exit 1, says so" ("{0}|{1}" -f $missingExit, [bool]($missing -match "no adapter for agent 'nosuch'")) "1|True"
} finally {
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

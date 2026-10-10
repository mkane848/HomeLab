# test-cap-hit.ps1 - regression guard for the writes gate's output-cap classification.
#
# Why this exists: opencode exits 0 when a model writes nothing, and the writes
# gate used to call every such run "liar mode". 8 of the 31 exit-0 zero-write rows
# from 2026-09-22 to 2026-09-29 were not: the last step spent its whole output
# budget (finish reason "length" at limit.output) on reasoning the transcript does
# not show, with no text and no tool call. That seat never got to answer, let alone
# describe a change. test-tasks.ps1 now tells the two apart (Get-TranscriptEnding,
# Test-OutputCapHit, Get-ModelOutputLimit) and records `outputCapHit` in the run JSON.
#
# What it does: pulls the REAL functions out of test-tasks.ps1 (so it tests the
# harness as written, not a copy) and runs them on
#   - synthetic transcripts for each edge (below the limit, text or tool call in the
#     step, an earlier cap followed by a normal step, a killed run, limit unknown),
#   - real transcripts committed under tests/results/ whose class the audit settled
#     (cap hit before and after edits, a mid-run cap that recovered, real liar mode),
#   - Get-ModelOutputLimit against a stand-in `opencode debug config`.
# Exit 1 on any failure; a missing fixture is a failure, not a skip.
#
# Usage:  .\tests\test-cap-hit.ps1 [-ScriptPath <a test-tasks.ps1>] [-ResultsDir <tests/results>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$ResultsDir = (Join-Path $PSScriptRoot "results")
)

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($name in "Get-TranscriptEnding", "Test-OutputCapHit") {
    $fn = $fns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}
# The OpenCode adapter: Read-AgentEvents, which Get-TranscriptEnding reads, and
# Get-ModelOutputLimit.
. (Join-Path $PSScriptRoot "agents\opencode.ps1")

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cap-hit-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Ev-Start { '{"type":"step_start","part":{"type":"step-start"}}' }
function Ev-Text  { '{"type":"text","part":{"type":"text","text":"done"}}' }
function Ev-Tool  { '{"type":"tool_use","part":{"type":"tool","tool":"read"}}' }
function Ev-Fin([string]$reason, [int]$out) { '{"type":"step_finish","part":{"type":"step-finish","reason":"' + $reason + '","tokens":{"output":' + $out + '}}}' }
function New-Transcript([string[]]$events) {
    $p = Join-Path $tmpRoot ([guid]::NewGuid().ToString("N").Substring(0, 8) + ".jsonl")
    [System.IO.File]::WriteAllText($p, (($events -join "`n") + "`n"), $utf8)
    return $p
}

$script:fail = 0
function Check([string]$name, [bool]$actual, [bool]$expected) {
    $ok = ($actual -eq $expected)
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected cap hit = $expected, got $actual"; $script:fail++ }
}
function CheckValue([string]$name, $actual, $expected) {
    $ok = ($actual -eq $expected)
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected '$expected', got '$actual'"; $script:fail++ }
}
function CapHit($path, $limit) { Test-OutputCapHit -Ending (Get-TranscriptEnding -Path $path) -Limit $limit }

try {
    Write-Host "-- synthetic transcripts"
    Check "empty step cut at the cap"                                  (CapHit (New-Transcript @((Ev-Start), (Ev-Fin "length" 4096))) 4096) $true
    Check "same run, limit 8192: a length stop below the cap is not it" (CapHit (New-Transcript @((Ev-Start), (Ev-Fin "length" 4096))) 8192) $false
    Check "length stop after a text answer"                            (CapHit (New-Transcript @((Ev-Start), (Ev-Text), (Ev-Fin "length" 4096))) 4096) $false
    Check "length stop after a tool call"                              (CapHit (New-Transcript @((Ev-Start), (Ev-Tool), (Ev-Fin "length" 4096))) 4096) $false
    Check "normal stop"                                                (CapHit (New-Transcript @((Ev-Start), (Ev-Text), (Ev-Fin "stop" 200))) 4096) $false
    Check "earlier step hit the cap, last step finished normally"      (CapHit (New-Transcript @((Ev-Start), (Ev-Fin "length" 4096), (Ev-Start), (Ev-Text), (Ev-Fin "stop" 300))) 4096) $false
    Check "earlier step had content, last step is an empty cap hit"    (CapHit (New-Transcript @((Ev-Start), (Ev-Tool), (Ev-Fin "tool-calls" 100), (Ev-Start), (Ev-Fin "length" 4096))) 4096) $true
    Check "limit unresolved: cannot confirm a cap"                     (CapHit (New-Transcript @((Ev-Start), (Ev-Fin "length" 4096))) $null) $false
    Check "killed run, no step_finish for the last step"               (CapHit (New-Transcript @((Ev-Start), (Ev-Fin "length" 4096), (Ev-Start), (Ev-Tool))) 4096) $false
    Check "transcript file missing"                                    (CapHit (Join-Path $tmpRoot "no-such.jsonl") 4096) $false

    Write-Host "-- real transcripts (tests/results, classified by the 2026-09-29 audit)"
    $real = @(
        @{ n = "qwen3:8b, kane-02, whole run is one capped step";        f = "tasks-kane-02-multiword-creature-type-ollama-desktop_qwen3_8b_20260926-232227.jsonl";                   lim = 4096; cap = $true  },
        @{ n = "nemotron, lfc-02, capped after two tool steps";          f = "tasks-lfc-02-scryfall-headers-ollama-desktop_nemotron-3.5-lightning_20260928-161529.jsonl";             lim = 4096; cap = $true  },
        @{ n = "ornith, kane-01 (node3), capped after two tool steps";   f = "tasks-kane-01-background-pair-ollama-node3_ornith_9b_20260923-082703.jsonl";                             lim = 4096; cap = $true  },
        @{ n = "qwen3.6, kane-02, capped AFTER four edits (8192)";       f = "tasks-kane-02-multiword-creature-type-ollama-desktop_qwen3.6_35b-a3b-coding_20260929-220020.jsonl";     lim = 8192; cap = $true  },
        @{ n = "nemotron, asohav-02, mid-run cap that recovered";        f = "tasks-asohav-02-changelog-uuid-id-ollama-desktop_nemotron-3.5-lightning_20260927-092355.jsonl";         lim = 4096; cap = $false },
        @{ n = "lfm2.5, asohav-01, answered in prose (liar mode)";       f = "tasks-asohav-01-library-write-reporting-ollama-node3_lfm2.5_8b_20260923-071539.jsonl";                  lim = 4096; cap = $false },
        @{ n = "lfm2.5, asohav-02, stopped with nothing (liar mode)";    f = "tasks-asohav-02-changelog-uuid-id-ollama-node3_lfm2.5_8b_20260923-071620.jsonl";                        lim = 4096; cap = $false },
        @{ n = "devstral:24b, kane-02, stopped after 159 tokens";        f = "tasks-kane-02-multiword-creature-type-ollama-desktop_devstral_24b_20260926-220232.jsonl";               lim = 4096; cap = $false }
    )
    foreach ($c in $real) {
        $p = Join-Path $ResultsDir $c.f
        if (-not (Test-Path -LiteralPath $p)) { Write-Host "FAIL $($c.n)"; Write-Host "     fixture missing: $p"; $script:fail++; continue }
        Check $c.n (CapHit $p $c.lim) $c.cap
    }

    Write-Host '-- Get-ModelOutputLimit against a stand-in for opencode debug config'
    function opencode { '{"provider":{"p":{"models":{"m:1":{"limit":{"context":32768,"output":8192}},"nolimit":{}}}}}' }
    CheckValue "registered model with a limit"        (Get-ModelOutputLimit -ModelId "p/m:1")        8192
    CheckValue "registered model without a limit"     ((Get-ModelOutputLimit -ModelId "p/nolimit") -eq $null) $true
    CheckValue "model not registered"                 ((Get-ModelOutputLimit -ModelId "p/other") -eq $null) $true
    CheckValue "provider not registered"              ((Get-ModelOutputLimit -ModelId "q/m:1") -eq $null) $true
    function opencode { throw "opencode is not available" }
    CheckValue "opencode failing degrades to unknown" ((Get-ModelOutputLimit -ModelId "p/m:1") -eq $null) $true

    Write-Host '-- the writes-gate block as wired in the main loop'
    # Runs the REAL block (from the $capHit line to the diff-scope marker) with a
    # stub Write-Result, so a typo'd variable there cannot silently fall back to
    # the liar-mode message.
    $src = @(Get-Content -LiteralPath $ScriptPath)
    $from = 0; $to = 0
    for ($i = 0; $i -lt $src.Count; $i++) {
        if (-not $from -and $src[$i].Contains('$capHit = Test-OutputCapHit')) { $from = $i + 1 }
        elseif ($from -and -not $to -and $src[$i].Contains('# --- grade 1: diff scope')) { $to = $i + 1 }
    }
    if (-not $from -or -not $to -or $to -le $from) { Write-Host "FAIL: writes-gate block not found in $ScriptPath"; exit 2 }
    $gateBlock = ($src[($from - 1)..($to - 2)]) -join "`n"
    function Write-Result([string]$Task, [string]$Check, [string]$Status, [string]$Detail = "") { $script:gateRows += [pscustomobject]@{ Status = $Status; Detail = $Detail } }
    function RunGate([int]$writes, [string]$reason, $tokens, [bool]$content, $limit) {
        $script:gateRows = @()
        $tk = [pscustomobject]@{ id = "t" }
        $run = [pscustomobject]@{ ExitCode = 0; Writes = $writes; Ending = [pscustomobject]@{ FinishReason = $reason; OutputTokens = $tokens; LastStepHadContent = $content } }
        $outputLimit = $limit
        $overallPass = $true
        Invoke-Expression $gateBlock
        return [pscustomobject]@{ Row = $script:gateRows[-1]; Pass = $overallPass }
    }
    function CheckGate([string]$name, $g, [string]$status, [string]$detailPattern, [bool]$pass) {
        $ok = ($g.Row.Status -eq $status -and $g.Row.Detail -match $detailPattern -and $g.Pass -eq $pass)
        Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
        if (-not $ok) { Write-Host "     got [$($g.Row.Status)] pass=$($g.Pass): $($g.Row.Detail)"; $script:fail++ }
    }
    CheckGate "0 writes, capped last step -> FAIL, named a cap hit"    (RunGate 0 "length" 4096 $false 4096)   "FAIL" "NOT liar mode.*4096"          $false
    CheckGate "0 writes, stop after prose -> FAIL, liar mode"          (RunGate 0 "stop" 300 $true 4096)       "FAIL" "the old liar mode"             $false
    CheckGate "0 writes, empty stop -> FAIL, liar mode"                (RunGate 0 "stop" 20 $false 4096)       "FAIL" "the old liar mode"             $false
    CheckGate "0 writes, length stop, limit unreadable -> truncated"   (RunGate 0 "length" 4096 $false $null)  "FAIL" "not confirmed as an output-cap" $false
    CheckGate "0 writes, length stop below the limit -> truncated"     (RunGate 0 "length" 100 $false 4096)    "FAIL" "not confirmed as an output-cap" $false
    CheckGate "3 writes, then a capped step -> PASS with a cap note"   (RunGate 3 "length" 8192 $false 8192)   "PASS" "hit the output cap at 8192"    $true
    CheckGate "3 writes, normal stop -> PASS, no cap note"             (RunGate 3 "stop" 300 $true 8192)       "PASS" "^3 write/edit calls$"          $true
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 } else { Write-Host "RESULT: all checks passed" }

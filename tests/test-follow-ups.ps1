# test-follow-ups.ps1 - regression guard for multi-turn tasks (`followUps`)
#
# Why this exists: the owner's real sessions open with a plan or a question and
# ask for the code afterwards ("approved", "go ahead"), so a real-prompt task is
# the real opener plus fixed follow-up turns (docs/roadmap.md -> "Real-use
# tasks"). test-tasks.ps1 sends each follow-up with `opencode run --session
# <id>` into the same session and transcript, and grades the end state.
#
# What it does: pulls the REAL Get-TranscriptSessionId out of test-tasks.ps1 and
# checks it; then runs the real test-tasks.ps1 end to end against a fixture repo
# with a stand-in opencode that plans in turn 1 (no edit) and makes the fix only
# when continued with --session. Checks: the follow-up reaches the same session
# with the fixed message; the run passes on the end state; edits from every
# turn count; the transcript holds both turns; the run JSON records turns = 2;
# the prompt hash covers the follow-ups; a session id that cannot be found, and
# a follow-up that fails, are infrastructure (no row, _INFRA_ transcript); a
# task without followUps is unchanged (one turn).
# Exit 1 on any failure.
#
# Usage:  .\tests\test-follow-ups.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) |
    Where-Object { $_.Name -eq "Get-TranscriptSessionId" } | Select-Object -First 1
if (-not $fn) { Write-Host "FAIL: Get-TranscriptSessionId not found in $ScriptPath"; exit 2 }
Invoke-Expression $fn.Extent.Text

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("followups-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
try {
    Write-Host "-- Get-TranscriptSessionId (real function)"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $tf = Join-Path $tmp "t.jsonl"
    Set-Content -LiteralPath $tf -Value @('', 'not json', '{"type":"step_start","sessionID":"ses_abc","part":{}}', '{"type":"text","sessionID":"ses_other"}')
    Check "the first event's sessionID"           (Get-TranscriptSessionId -Path $tf) "ses_abc"
    Set-Content -LiteralPath $tf -Value '{"type":"step_start","part":{}}'
    Check "no sessionID: null"                    ($null -eq (Get-TranscriptSessionId -Path $tf)) "True"
    Check "a missing file: null"                  ($null -eq (Get-TranscriptSessionId -Path (Join-Path $tmp "nope.jsonl"))) "True"

    Write-Host "-- end to end: the real test-tasks.ps1, a fixture repo, a stand-in opencode"
    foreach ($d in @("tests/tasks/hidden/fx-twoturn", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $tmp "tests/test-tasks.ps1")
    Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/hidden/fx-twoturn/hidden.txt") -Value "hidden test"
    $repo = Join-Path $tmp "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
if ((Test-Path hidden.txt) -and $src -ne 'fixed') { Write-Host "Tests  1 failed (2)"; exit 1 }
Write-Host "Tests  2 passed (2)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    function New-Task([string]$id, $followUps) {
        $t = [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            grading = "acceptance"; scope = "guardrails"; acceptance = [ordered]@{ dir = "hidden/fx-twoturn" }
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
            prompt = "plan how to fix the digest, then wait for my go-ahead"
        }
        if ($followUps) { $t.followUps = @($followUps) }
        return $t
    }
    @{ tasks = @((New-Task "fx-twoturn" "approved, go ahead"), (New-Task "fx-single" $null),
                 (New-Task "fx-nosession" "approved, go ahead"), (New-Task "fx-turn2fails" "approved, go ahead")) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/manifest.json")

    # Stand-in opencode. Turn 1 (no --session): a plan, no edit. A continued
    # turn (--session <id>): the fix. Every call is logged for the checks.
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    $id = Split-Path -Leaf $dir
    $si = [array]::IndexOf($a, '--session')
    $session = if ($si -ge 0) { $a[$si + 1] } else { '' }
    Add-Content -LiteralPath $env:FIXTURE_CALLS -Value ("{0}|{1}|{2}" -f $id, $session, $a[-1])
    $sid = if ($id -eq 'fx-nosession') { '' } else { ',"sessionID":"ses_' + $id + '"' }
    if (-not $session) {
        '{"type":"step_start"' + $sid + ',"part":{"type":"step-start"}}'
        '{"type":"text"' + $sid + ',"part":{"text":"Plan: set src.txt to fixed. Say go ahead."}}'
        '{"type":"step_finish"' + $sid + ',"part":{"reason":"stop","tokens":{"output":5}}}'
        exit 0
    }
    if ($id -eq 'fx-turn2fails') { exit 1 }
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    '{"type":"step_start","sessionID":"' + $session + '","part":{"type":"step-start"}}'
    '{"type":"tool_use","sessionID":"' + $session + '","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"step_finish","sessionID":"' + $session + '","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $tmp "bin/standin.ps1")
    $bin = Join-Path $tmp "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $env:FIXTURE_CALLS = Join-Path $tmp "calls.txt"
    try {
        $out = & (Join-Path $tmp "tests/test-tasks.ps1") -Task fx-twoturn, fx-single, fx-nosession, fx-turn2fails -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_CALLS -ErrorAction SilentlyContinue
    }
    $calls = @(Get-Content -LiteralPath (Join-Path $tmp "calls.txt"))
    $results = Join-Path $tmp "tests/results"
    $rows = @(if (Test-Path (Join-Path $results "real-tasks-summary.tsv")) { Import-Csv (Join-Path $results "real-tasks-summary.tsv") -Delimiter "`t" })
    function Row([string]$id) { @($rows | Where-Object taskId -eq $id)[0] }
    function Json([string]$id) { Get-ChildItem $results -Filter "tasks-$id-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json }

    Check "fx-twoturn: two calls"                        @($calls | Where-Object { $_ -like 'fx-twoturn|*' }).Count 2
    Check "...the second continues the first's session"  (@($calls | Where-Object { $_ -like 'fx-twoturn|*' })[1] -split '\|')[1] "ses_fx-twoturn"
    Check "...with the fixed follow-up message"          (@($calls | Where-Object { $_ -like 'fx-twoturn|*' })[1] -split '\|')[2] "approved, go ahead"
    Check "...passes on the end state"                   ("{0}/{1}/{2}" -f (Row fx-twoturn).scope, (Row fx-twoturn).suite, (Row fx-twoturn).acceptance) "PASS/PASS/PASS"
    Check "...the turn-2 edit counts"                    (Row fx-twoturn).writes 1
    $j = Json fx-twoturn
    Check "...run JSON records two turns"                $j.turns 2
    $tr = Get-Content -LiteralPath (Join-Path $results $j.transcriptFile)
    Check "...one transcript holds both turns"           ((($tr -join "`n") -match 'Plan: set src.txt') -and (($tr -join "`n") -match '"tool":"edit"')) "True"
    Check "fx-single: one call, no session"              (@($calls | Where-Object { $_ -like 'fx-single|*' }) -join ';') "fx-single||plan how to fix the digest, then wait for my go-ahead"
    Check "...one turn in its JSON"                      (Json fx-single).turns 1
    Check "...planned but never fixed: acceptance FAIL"  (Row fx-single).acceptance "FAIL"
    Check "the follow-ups are part of the prompt hash"   ((Json fx-single).promptSha256 -ne $j.promptSha256) "True"
    Check "fx-nosession: no follow-up attempted"         @($calls | Where-Object { $_ -like 'fx-nosession|*' }).Count 1
    Check "...infrastructure: no row"                    @($rows | Where-Object taskId -eq "fx-nosession").Count 0
    Check "...the output says why"                       ($out -match 'follow-up turn 2 could not start: no sessionID') "True"
    Check "...transcript kept as _INFRA_"                @(Get-ChildItem $results -Filter "tasks-fx-nosession-*_INFRA_*.jsonl").Count 1
    Check "fx-turn2fails: infrastructure, no row"        @($rows | Where-Object taskId -eq "fx-turn2fails").Count 0
    Check "...transcript kept as _INFRA_"                @(Get-ChildItem $results -Filter "tasks-fx-turn2fails-*_INFRA_*.jsonl").Count 1
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

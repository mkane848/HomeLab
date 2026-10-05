# test-compaction-nudge.ps1 - regression guard for -NudgeAfterCompaction
#
# Why this exists: under `opencode run`, a model that answers opencode's
# post-compaction "Continue if you have next steps, or stop and ask for
# clarification" in prose ends the run (docs/roadmap.md -> "Context overflow").
# The owner wants one chat window where machinery never needs them, so the
# question is whether an automatic continue would rescue those runs. The
# diagnostic sends $script:CompactionNudgeText into the same session when a run
# ends right after a compaction (Get-ContextEvents.EndedAfterCompaction).
#
# What it does: the real test-tasks.ps1 end to end against a fixture repo with a
# stand-in opencode whose turn 1 compacts and stops. Checks: a run that stops
# right after compacting is nudged once, with the exact nudge text, in the same
# session, and passes on the end state; a second compaction earns a second
# nudge, up to -MaxNudges; stopping again without a new compaction earns none;
# a run with no compaction is never nudged; the run JSON records `nudges`
# (sent, max, text hash) and `turns`; without the switch nothing is nudged and
# `nudges` is null; and the switch is refused before any run when the rows
# would land in tests/results/ (assisted runs never join the unassisted summary).
# Exit 1 on any failure.
#
# Usage:  .\tests\test-compaction-nudge.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$nudgeAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:CompactionNudgeText' }, $true)) | Select-Object -First 1
if (-not $nudgeAst) { Write-Host "FAIL: `$script:CompactionNudgeText not found in $ScriptPath"; exit 2 }
Invoke-Expression $nudgeAst.Extent.Text
$nudgeText = $script:CompactionNudgeText

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("nudge-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
try {
    foreach ($d in @("tests/tasks/hidden/fx", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $tmp "tests/test-tasks.ps1")
    Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/hidden/fx/hidden.txt") -Value "hidden test"
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
    function New-Task([string]$id) {
        [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            grading = "acceptance"; scope = "guardrails"; acceptance = [ordered]@{ dir = "hidden/fx" }
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
            prompt = "fix src.txt"
        }
    }
    @{ tasks = @((New-Task "fx-stop"), (New-Task "fx-twice"), (New-Task "fx-again"), (New-Task "fx-plain"), (New-Task "fx-late")) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/manifest.json")

    # Stand-in opencode. Per task, the Nth call (1 = the opener) does:
    #   fx-stop : 1 compact+stop, 2 fix
    #   fx-twice: 1 compact+stop, 2 compact+stop, 3 fix
    #   fx-again: 1 compact+stop, 2 prose stop (no new compaction)
    #   fx-plain: 1 prose stop, no compaction
    #   fx-late : 1 compact, three steps of reading, then a recap stop (the
    #             qwen3.6 kane-07 stall), 2 fix
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
$id = Split-Path -Leaf $dir
$si = [array]::IndexOf($a, '--session')
$session = if ($si -ge 0) { $a[$si + 1] } else { '' }
Add-Content -LiteralPath $env:FIXTURE_CALLS -Value ("{0}|{1}|{2}" -f $id, $session, $a[-1])
$n = @(Get-Content -LiteralPath $env:FIXTURE_CALLS | Where-Object { $_ -like "$id|*" }).Count
$sid = ',"sessionID":"ses_' + $id + '"'
function Fin([int]$in, [int]$cr) { '{"type":"step_finish"' + $sid + ',"part":{"reason":"stop","tokens":{"input":' + $in + ',"output":20,"cache":{"read":' + $cr + ',"write":0}}}}' }
function CompactStop {
    '{"type":"step_start"' + $sid + ',"part":{"type":"step-start"}}'
    '{"type":"tool_use"' + $sid + ',"part":{"tool":"read","state":{"status":"completed","output":"lots of code"}}}'
    Fin 30000 0
    '{"type":"text"' + $sid + ',"part":{"text":"## Objective - fix src.txt"}}'
    Fin 3000 0
    '{"type":"text"' + $sid + ',"part":{"text":"Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed."}}'
    '{"type":"text"' + $sid + ',"part":{"text":"Next steps: set src.txt to fixed."}}'
    Fin 9000 0
}
function Fix {
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    '{"type":"tool_use"' + $sid + ',"part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
    Fin 300 9000
}
function Prose { '{"type":"text"' + $sid + ',"part":{"text":"I would set src.txt to fixed."}}'; Fin 9500 0 }
function CompactReadRecap {
    CompactStop | Select-Object -SkipLast 2
    '{"type":"tool_use"' + $sid + ',"part":{"tool":"read","state":{"status":"completed","output":"code"}}}'
    Fin 9000 0
    foreach ($i in 1..3) { '{"type":"tool_use"' + $sid + ',"part":{"tool":"grep","state":{"status":"completed","output":"hit"}}}'; Fin 300 (9000 + 100 * $i) }
    '{"type":"text"' + $sid + ',"part":{"text":"So far I have been working on fixing src.txt."}}'
    Fin 300 9500
}
switch ("$id/$n") {
    "fx-stop/1"  { CompactStop }  "fx-stop/2"  { Fix }
    "fx-twice/1" { CompactStop }  "fx-twice/2" { CompactStop }  "fx-twice/3" { Fix }
    "fx-again/1" { CompactStop }  "fx-again/2" { Prose }
    "fx-late/1"  { CompactReadRecap }  "fx-late/2" { Fix }
    default      { Prose }
}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $tmp "bin/standin.ps1")
    $bin = Join-Path $tmp "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $env:FIXTURE_CALLS = Join-Path $tmp "calls.txt"
    $tt = Join-Path $tmp "tests/test-tasks.ps1"
    $common = @{ Model = "fixture/m"; SkipInstall = $true; RunTimeout = 120; OllamaLogDir = (Join-Path $tmp "no-log") }
    try {
        Write-Host "-- refused into tests/results/"
        $refused = & $tt -Task fx-stop @common -NudgeAfterCompaction *>&1 | Out-String
        Check "exit 1 without -ResultsDir"             $LASTEXITCODE 1
        Check "...says why"                            ($refused -match 'assisted runs') "True"
        Check "...no model call made"                  (Test-Path $env:FIXTURE_CALLS) "False"

        Write-Host "-- nudged runs"
        $nr = Join-Path $tmp "nudge-results"
        $null = & $tt -Task fx-stop, fx-twice, fx-again, fx-plain, fx-late @common -NudgeAfterCompaction -MaxNudges 2 -ResultsDir $nr *>&1 | Out-String
        $calls = @(Get-Content -LiteralPath $env:FIXTURE_CALLS)
        Remove-Item -LiteralPath $env:FIXTURE_CALLS

        Write-Host "-- the same task without the switch"
        $pr = Join-Path $tmp "plain-results"
        $null = & $tt -Task fx-stop @common -ResultsDir $pr *>&1 | Out-String
        $plainCalls = @(Get-Content -LiteralPath $env:FIXTURE_CALLS)
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_CALLS -ErrorAction SilentlyContinue
    }
    $rows = @(Import-Csv (Join-Path $nr "real-tasks-summary.tsv") -Delimiter "`t")
    function Row([string]$id) { @($rows | Where-Object taskId -eq $id)[0] }
    function Json([string]$dir, [string]$id) { Get-ChildItem $dir -Filter "tasks-$id-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json }
    function Calls([string]$id) { @($calls | Where-Object { $_ -like "$id|*" }) }

    Check "fx-stop: two calls"                         (Calls fx-stop).Count 2
    Check "...the nudge continues the same session"    ((Calls fx-stop)[1] -split '\|')[1] "ses_fx-stop"
    Check "...with the exact nudge text"               ((Calls fx-stop)[1] -split '\|', 3)[2] $nudgeText
    Check "...passes on the end state"                 ("{0}/{1}/{2}" -f (Row fx-stop).scope, (Row fx-stop).suite, (Row fx-stop).acceptance) "PASS/PASS/PASS"
    $j = Json $nr fx-stop
    Check "...JSON: nudges.sent 1"                     $j.nudges.sent 1
    Check "...JSON: nudges.max 2"                      $j.nudges.max 2
    Check "...JSON: the text's hash"                   ($j.nudges.textSha256 -match '^[0-9A-F]{12}$') "True"
    Check "...JSON: turns 2"                           $j.turns 2
    Check "fx-twice: three calls (two nudges)"         (Calls fx-twice).Count 3
    Check "...passes after the second"                 (Row fx-twice).acceptance "PASS"
    Check "...JSON: nudges.sent 2"                     (Json $nr fx-twice).nudges.sent 2
    Check "fx-again: no second nudge without a new compaction" (Calls fx-again).Count 2
    Check "...JSON: nudges.sent 1"                     (Json $nr fx-again).nudges.sent 1
    Check "...never fixed: acceptance FAIL"            (Row fx-again).acceptance "FAIL"
    Check "fx-plain: no compaction, never nudged"      (Calls fx-plain).Count 1
    Check "...JSON: nudges.sent 0"                     (Json $nr fx-plain).nudges.sent 0
    Check "fx-late: a recap stop steps after compacting is nudged" (Calls fx-late).Count 2
    Check "...and the fix after it passes"            (Row fx-late).acceptance "PASS"
    Check "...JSON: it was not 'right after' the compaction" (Json $nr fx-late).contextEvents.endedAfterCompaction "False"
    Check "without the switch: one call"               $plainCalls.Count 1
    Check "...JSON: nudges null"                       ($null -eq (Json $pr fx-stop).nudges) "True"
    Check "...stopped after compacting: FAIL"          (@(Import-Csv (Join-Path $pr "real-tasks-summary.tsv") -Delimiter "`t")[0]).acceptance "FAIL"
    Check "...and its contextEvents say so"            (Json $pr fx-stop).contextEvents.endedAfterCompaction "True"
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

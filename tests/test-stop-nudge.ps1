# test-stop-nudge.ps1 - regression guard for test-tasks.ps1 -NudgeOnStop
#
# Why this exists: the local seats often stop with work undone. qwen3.6 said
# "Now I have everything. Let me implement all changes:" and stopped (wp-6f,
# 2026-10-09); twice it lost its brief and asked "You've shared two files but
# haven't specified a task" (wp-2b). In one window the owner would say "keep
# going", or paste the request again. -NudgeOnStop does that and measures it
# (docs/roadmap.md -> "Follow-up runs (2026-10-09)"). Nudged runs are assisted,
# so their rows must stay apart from the model's own.
#
# What it does:
#   1. Pulls the REAL Get-StopKind and its patterns out of test-tasks.ps1 and
#      runs it on synthetic transcripts (each kind of ending, a sign-off that
#      isn't a step, opencode's continue text, a last step that calls a tool)
#      and on committed real ones.
#   2. Runs the REAL test-tasks.ps1 end to end with a private manifest and a
#      stand-in opencode (a .ps1, so a multi-line message arrives whole):
#      an announced stop is nudged with the exact stop text and then fixes; a
#      lost task gets the lost-task text plus the original prompt; a silent
#      finish is nudged once and confirms; a closing summary is never nudged;
#      -MaxStopNudges caps a model that keeps announcing. The run JSON records
#      `stopNudges` (sent, max, kinds, both hashes) and `turns`.
#   3. Keeps assisted rows apart: the results folder gets an ASSISTED marker;
#      nothing is mirrored to tests/results/real-tasks-public.tsv (an unassisted
#      run of the same manifest is); an assisted run is refused in a folder of
#      unassisted rows and in tests/results/; an unassisted run is refused in a
#      folder marked ASSISTED. Refusals happen before any model call.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-stop-nudge.ps1 [-ScriptPath <a test-tasks.ps1>] [-ResultsDir <tests/results>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$ResultsDir = (Join-Path $PSScriptRoot "results")
)

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-StopKind" }, $true)) | Select-Object -First 1
if (-not $fn) { Write-Host "FAIL: Get-StopKind not found in $ScriptPath"; exit 1 }
Invoke-Expression $fn.Extent.Text
# The OpenCode adapter: Read-AgentEvents, which Get-StopKind reads, and
# $script:CompactionContinueText.
. (Join-Path $PSScriptRoot "agents\opencode.ps1")
foreach ($var in '$script:AskedForTaskPattern', '$script:AnnouncedStepPattern', '$script:StopNudgeText', '$script:LostTaskNudgeText') {
    $assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var }, $true)) | Select-Object -First 1
    if (-not $assign) { Write-Host "FAIL: $var not found in $ScriptPath"; exit 1 }
    Invoke-Expression $assign.Extent.Text
}

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("stop-nudge-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$psExe = (Get-Process -Id $PID).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Write-Host "-- Get-StopKind (real function)"
    function Ev-Text([string]$t) { (@{ type = "text"; part = @{ text = $t } } | ConvertTo-Json -Compress -Depth 4) }
    function Ev-Tool { '{"type":"tool_use","part":{"tool":"read","state":{"status":"completed","output":"x"}}}' }
    function Ev-Fin { '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":10,"output":5,"cache":{"read":0,"write":0}}}}' }
    function Kind([string[]]$events) {
        $p = Join-Path $tmp ([guid]::NewGuid().ToString("N").Substring(0, 8) + ".jsonl")
        [IO.File]::WriteAllText($p, (($events -join "`n") + "`n"), $utf8)
        $k = Get-StopKind -Path $p
        if ($null -eq $k) { "none" } else { $k }
    }
    Check "asked for its task"                    (Kind @((Ev-Tool), (Ev-Fin), (Ev-Text "You've shared two files but haven't specified a task. What would you like me to do?"), (Ev-Fin))) "ask"
    Check "announced a step with a colon"         (Kind @((Ev-Tool), (Ev-Fin), (Ev-Text "Now I have everything. Let me implement all changes:"), (Ev-Fin))) "announce"
    Check "announced a step in words"             (Kind @((Ev-Text "The test expects 0. I'll fix guardedStrain next."), (Ev-Fin))) "announce"
    Check "an empty last step"                    (Kind @((Ev-Tool), (Ev-Fin), (Ev-Fin))) "empty"
    Check "a closing summary: none"               (Kind @((Ev-Tool), (Ev-Fin), (Ev-Text "Done. All 12 tests pass and the change is in combat.ts."), (Ev-Fin))) "none"
    Check "a sign-off, not a step: none"          (Kind @((Ev-Text "Fixed. Let me know if you need anything else."), (Ev-Fin))) "none"
    Check "an earlier announcement, then a summary: none" (Kind @((Ev-Text "Let me check the tests:"), (Ev-Tool), (Ev-Fin), (Ev-Text "All tests pass."), (Ev-Fin))) "none"
    Check "a last step that calls a tool: none"   (Kind @((Ev-Text "Let me run the tests:"), (Ev-Tool), (Ev-Fin))) "none"
    Check "opencode's continue text is not the model's" (Kind @((Ev-Text "$script:CompactionContinueText if you are unsure how to proceed."), (Ev-Fin))) "empty"
    Check "a step cut off before it finished counts the last finished one" (Kind @((Ev-Text "All tests pass."), (Ev-Fin), (Ev-Text "Let me"))) "none"
    Check "no transcript: none"                   (Kind @()) "none"
    Check "no transcript file: null"              ($null -eq (Get-StopKind -Path (Join-Path $tmp "nope.jsonl"))) "True"

    Write-Host "-- real transcripts (tests/results)"
    foreach ($r in @(
            @{ f = "tasks-kane-08-aristocrats-false-positives-ollama-desktop_qwen3.6_35b-a3b-coding_20261003-172716.jsonl"; kind = "ask" },
            @{ f = "tasks-kane-10-combo-permalink-scheme-ollama-desktop_qwen3.5_9b_20261004-162332.jsonl"; kind = "empty" })) {
        $p = Get-ChildItem -LiteralPath $ResultsDir -Recurse -Filter $r.f | Select-Object -First 1
        if (-not $p) { Write-Host "FAIL missing fixture $($r.f)"; $script:fail++; continue }
        $k = Get-StopKind -Path $p.FullName
        Check ("{0}: {1}" -f ($r.f -replace '^tasks-', '' -replace '-ollama-desktop_', ' / ' -replace '\.jsonl$', ''), $r.kind) $(if ($null -eq $k) { "none" } else { $k }) $r.kind
    }

    Write-Host "-- end to end: the real test-tasks.ps1, a private manifest, a stand-in opencode"
    $h = Join-Path $tmp "h"
    $priv = Join-Path $tmp "priv"
    foreach ($d in @("$h/tests/tasks", "$h/bin", "$priv/hidden/fx", "$tmp/repo")) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $h "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $h "tests") -Recurse -Force
    # A public manifest, so the tests/results/ refusal is reached (a missing
    # manifest exits 1 earlier, for another reason).
    '{"tasks":[]}' | Set-Content -LiteralPath (Join-Path $h "tests/tasks/manifest.json")
    Set-Content -LiteralPath (Join-Path $priv "hidden/fx/hidden.txt") -Value "hidden test"
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
    $taskPrompt = "fix src.txt`nso that it reads fixed"
    function New-Task([string]$id) {
        [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            grading = "acceptance"; scope = "guardrails"; acceptance = [ordered]@{ dir = "hidden/fx" }
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
            prompt = $taskPrompt
        }
    }
    $ids = "fx-announce", "fx-ask", "fx-silent", "fx-done", "fx-max"
    @{ tasks = @($ids | ForEach-Object { New-Task $_ }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $priv "manifest.json")

    # Stand-in opencode. Per task, the Nth call (1 = the opener) does:
    #   fx-announce: 1 reads, then "Let me implement all changes:"; 2 fixes, sums up
    #   fx-ask     : 1 "You've shared a file but haven't specified a task"; 2 fixes
    #                if the message holds the original prompt, else asks again
    #   fx-silent  : 1 fixes and ends on an empty step; 2 confirms in one line
    #   fx-done    : 1 fixes and sums up
    #   fx-max     : always announces and never fixes
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
$id = Split-Path -Leaf $dir
$si = [array]::IndexOf($a, '--session')
$session = if ($si -ge 0) { $a[$si + 1] } else { '' }
$msg = [string]$a[-1]
Add-Content -LiteralPath $env:FIXTURE_CALLS -Value (@{ id = $id; session = $session; msg = $msg } | ConvertTo-Json -Compress)
$n = @(Get-Content -LiteralPath $env:FIXTURE_CALLS | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.id -eq $id }).Count
$sid = ',"sessionID":"ses_' + $id + '"'
function Fin { '{"type":"step_finish"' + $sid + ',"part":{"reason":"stop","tokens":{"input":900,"output":20,"cache":{"read":0,"write":0}}}}' }
function Say([string]$t) { '{"type":"text"' + $sid + ',"part":' + (@{ text = $t } | ConvertTo-Json -Compress) + '}'; Fin }
function Read { '{"type":"tool_use"' + $sid + ',"part":{"tool":"read","state":{"status":"completed","output":"code"}}}'; Fin }
function Fix {
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    '{"type":"tool_use"' + $sid + ',"part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
    Fin
}
switch ("$id/$n") {
    "fx-announce/1" { Read; Say "Now I have everything. Let me implement all changes:" }
    "fx-announce/2" { Fix; Say "Done: src.txt reads fixed and the tests pass." }
    "fx-ask/1"      { Say "You've shared a file but haven't specified a task. What would you like me to do?" }
    "fx-ask/2"      { if ($msg -like '*fix src.txt*so that it reads fixed*') { Fix; Say "Done: src.txt is fixed." } else { Say "You haven't provided a request." } }
    "fx-silent/1"   { Fix; Fin }
    "fx-silent/2"   { Say "It is finished and checked." }
    "fx-done/1"     { Fix; Say "Done: src.txt reads fixed and the tests pass." }
    default         { Read; Say "Let me make the change next:" }
}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $h "bin/opencode.ps1")
    $origPath = $env:PATH
    $env:PATH = "$(Join-Path $h 'bin');$env:PATH"
    $env:FIXTURE_CALLS = Join-Path $tmp "calls.jsonl"
    $tt = Join-Path $h "tests/test-tasks.ps1"
    $manifest = Join-Path $priv "manifest.json"
    $common = @{ Model = "fixture/m"; SkipInstall = $true; RunTimeout = 120; OllamaLogDir = (Join-Path $tmp "no-log"); TaskManifest = $manifest }
    $publicTsv = Join-Path $h "tests/results/real-tasks-public.tsv"
    $nudged = Join-Path $priv "results-nudged"
    $plain = Join-Path $priv "results-plain"
    try {
        $log = & $tt -Task $ids @common -ResultsDir $nudged -NudgeOnStop -MaxStopNudges 2 *>&1 | Out-String
        $calls = @(Get-Content -LiteralPath $env:FIXTURE_CALLS | ForEach-Object { $_ | ConvertFrom-Json })
        Remove-Item -LiteralPath $env:FIXTURE_CALLS
        $publicAfterNudged = Test-Path -LiteralPath $publicTsv

        Write-Host "-- refusals (before any model call)"
        $r1 = & $tt -Task fx-done @common -ResultsDir $nudged *>&1 | Out-String
        Check "unassisted into an ASSISTED folder: exit 1"   $LASTEXITCODE 1
        Check "...says why"                                  ($r1 -match 'holds assisted') "True"
        $null = & $tt -Task fx-done @common -ResultsDir $plain *>&1 | Out-String
        $plainCalls = @(Get-Content -LiteralPath $env:FIXTURE_CALLS).Count
        Remove-Item -LiteralPath $env:FIXTURE_CALLS
        $r2 = & $tt -Task fx-done @common -ResultsDir $plain -NudgeOnStop *>&1 | Out-String
        Check "assisted into a folder of unassisted rows: exit 1" $LASTEXITCODE 1
        Check "...says why"                                  ($r2 -match 'already holds unassisted rows') "True"
        $c = @{} + $common; $c.Remove('TaskManifest')
        $r3 = & $tt -Task nothing @c -NudgeOnStop *>&1 | Out-String
        Check "assisted into tests/results/: exit 1"         $LASTEXITCODE 1
        Check "...says why"                                  ($r3 -match 'assisted runs') "True"
        Check "...none of the three called the model"        (Test-Path -LiteralPath $env:FIXTURE_CALLS) "False"
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_CALLS -ErrorAction SilentlyContinue
    }

    Write-Host "-- nudged runs"
    $rows = @(Import-Csv (Join-Path $nudged "real-tasks-summary.tsv") -Delimiter "`t")
    function Row([string]$id) { @($rows | Where-Object taskId -eq $id)[0] }
    function Json([string]$id) { Get-ChildItem $nudged -Filter "tasks-$id-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json }
    function Calls([string]$id) { @($calls | Where-Object { $_.id -eq $id }) }
    function Verdict([string]$id) { "{0}/{1}/{2}" -f (Row $id).scope, (Row $id).suite, (Row $id).acceptance }

    Check "fx-announce: two calls"                           @(Calls fx-announce).Count 2
    Check "...the nudge continues the same session"          (Calls fx-announce)[1].session "ses_fx-announce"
    Check "...with the exact stop text"                      (Calls fx-announce)[1].msg $script:StopNudgeText
    Check "...passes on the end state"                       (Verdict fx-announce) "PASS/PASS/PASS"
    $j = Json fx-announce
    Check "...JSON: stopNudges sent 1, kinds announce"       ("{0} {1}" -f $j.stopNudges.sent, (@($j.stopNudges.kinds) -join ',')) "1 announce"
    Check "...JSON: max 2"                                   $j.stopNudges.max 2
    Check "...JSON: both text hashes"                        (($j.stopNudges.stopTextSha256 -match '^[0-9A-F]{12}$') -and ($j.stopNudges.lostTaskTextSha256 -match '^[0-9A-F]{12}$')) "True"
    Check "...JSON: turns 2"                                 $j.turns 2
    Check "fx-ask: two calls"                                @(Calls fx-ask).Count 2
    Check "...the lost-task text, then the original prompt"  (Calls fx-ask)[1].msg ($script:LostTaskNudgeText + "`n`n" + $taskPrompt)
    Check "...passes"                                        (Verdict fx-ask) "PASS/PASS/PASS"
    Check "...JSON: kinds ask"                               (@((Json fx-ask).stopNudges.kinds) -join ',') "ask"
    Check "fx-silent: nudged once after an empty ending"     @(Calls fx-silent).Count 2
    Check "...confirms and is not nudged again"              (@((Json fx-silent).stopNudges.kinds) -join ',') "empty"
    Check "...passes"                                        (Verdict fx-silent) "PASS/PASS/PASS"
    Check "fx-done: a closing summary is never nudged"       @(Calls fx-done).Count 1
    Check "...JSON: stopNudges sent 0"                       (Json fx-done).stopNudges.sent 0
    Check "fx-max: capped at -MaxStopNudges (three calls)"   @(Calls fx-max).Count 3
    Check "...JSON: kinds announce,announce"                 (@((Json fx-max).stopNudges.kinds) -join ',') "announce,announce"
    Check "...never fixed: acceptance FAIL"                  (Row fx-max).acceptance "FAIL"
    Check "the console names each nudge"                     ([regex]::Matches($log, 'stop nudge \d: the run stopped').Count) 5

    Write-Host "-- assisted rows stay apart"
    Check "the folder is marked ASSISTED"                    (Test-Path -LiteralPath (Join-Path $nudged "ASSISTED")) "True"
    Check "nothing mirrored to real-tasks-public.tsv"        $publicAfterNudged "False"
    Check "an unassisted run of the same manifest is mirrored" (@(Get-Content -LiteralPath $publicTsv -ErrorAction SilentlyContinue | Select-Object -Skip 1).Count) 1
    Check "...made one call"                                 $plainCalls 1
    $pj = Get-ChildItem $plain -Filter "tasks-fx-done-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "...JSON: stopNudges null without the switch"      ($null -eq $pj.stopNudges) "True"
    Check "...and its folder is not marked"                  (Test-Path -LiteralPath (Join-Path $plain "ASSISTED")) "False"
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

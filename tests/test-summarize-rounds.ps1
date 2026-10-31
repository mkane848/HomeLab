# protects: summarize-rounds.ps1 pass@k / pass^k arithmetic, pass rule and the planner arm's selector counts
# run-after: summarize-rounds.ps1
# test-summarize-rounds.ps1 - regression guard for tests/summarize-rounds.ps1 (pass@k and pass^k).
#
# Why this exists: a round's headline is its per-run pass rate, but work meant to
# run unattended needs to pass every time (pass^k), and the script that reports it
# must count a pass the way tests/results/README.md defines one. A wrong count here
# would misstate which tasks are safe to hand off.
#
# What it does:
#   1. The REAL functions: C(n, r); pass@k and pass^k at known values (the
#      unbiased estimators, including k = n, which is the plain all-of / any-of);
#      the pass rule for a real task (hidden tests + scope + suite; failsOnOld
#      SKIP is normal), a public task (scope + suite + failsOnOld) and a
#      checklist task (left out).
#   2. Get-RoundSummary on synthetic runs: two models kept apart, k defaulting
#      to the smallest n, a task with fewer than k runs left out of the means.
#      Experiment 3 (a planner's tests shown, docs/planner-tests-experiment.md): the selector against the
#      hidden tests' verdict: false positives, false negatives, what a dispatcher would keep and was wrong,
#      the Wilson interval, planner-shown arms apart (ACCEPTANCE-PLANNER), oracle-shown rows not counted.
#   3. The REAL script end to end on a throwaway folder (-AsJson and the table),
#      a missing folder and an empty one (exit 1), and, when this machine has
#      the private results, the desktop's four reps: 47 of 60, 9 of 15 tasks
#      passed every time, pass^4 0.6.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-summarize-rounds.ps1 [-ScriptPath <a summarize-rounds.ps1>] [-PrivateResults <folder>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "summarize-rounds.ps1"),
    [string]$PrivateResults = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "HomeLab-private\results")
)

$ErrorActionPreference = "Stop"
. $ScriptPath

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function R3($x) { if ($null -eq $x) { "null" } else { [math]::Round($x, 3) } }
function Run([string]$Model, [string]$Task, [string]$Grading, [string]$Acc, [string]$Scope = "PASS", [string]$Suite = "PASS", [string]$Fo = "SKIP") {
    $j = [ordered]@{ model = $Model; taskId = $Task; gates = [ordered]@{ scope = $Scope; suite = $Suite; failsOnOld = $Fo } }
    if ($Grading) { $j.grading = $Grading }
    if ($Acc) { $j.acceptance = [ordered]@{ status = $Acc } }
    return [pscustomobject]$j
}

Write-Host "-- the arithmetic"
Check "C(5,2), C(4,0), C(3,4)" ("{0}|{1}|{2}" -f (Get-Binomial 5 2), (Get-Binomial 4 0), (Get-Binomial 3 4)) "10|1|0"
Check "n=4 c=3 k=2: pass@2 1, pass^2 0.5" ("{0}|{1}" -f (R3 (Get-PassAtK 4 3 2)), (R3 (Get-PassHatK 4 3 2))) "1|0.5"
Check "n=4 c=2 k=2: pass@2 0.833, pass^2 0.167" ("{0}|{1}" -f (R3 (Get-PassAtK 4 2 2)), (R3 (Get-PassHatK 4 2 2))) "0.833|0.167"
Check "k = n is any-of / all-of: n=4 c=3 -> 1, 0" ("{0}|{1}" -f (R3 (Get-PassAtK 4 3 4)), (R3 (Get-PassHatK 4 3 4))) "1|0"
Check "k = 1 is the pass rate: n=4 c=3 -> 0.75, 0.75" ("{0}|{1}" -f (R3 (Get-PassAtK 4 3 1)), (R3 (Get-PassHatK 4 3 1))) "0.75|0.75"
Check "fewer runs than k: null" ("{0}|{1}" -f (R3 (Get-PassAtK 2 1 3)), (R3 (Get-PassHatK 2 1 3))) "null|null"
Check "never passed: 0, 0" ("{0}|{1}" -f (R3 (Get-PassAtK 4 0 2)), (R3 (Get-PassHatK 4 0 2))) "0|0"

Write-Host "-- the pass rule"
Check "real task: hidden tests, scope and suite PASS (failsOnOld SKIP) -> PASS" (Get-RunVerdict (Run m t acceptance PASS)) "PASS"
Check "real task: hidden tests FAIL -> FAIL" (Get-RunVerdict (Run m t acceptance FAIL)) "FAIL"
Check "real task: hidden tests PASS but suite FAIL -> FAIL" (Get-RunVerdict (Run m t acceptance PASS PASS FAIL)) "FAIL"
Check "real task: hidden tests PASS but a guard rail hit -> FAIL" (Get-RunVerdict (Run m t acceptance PASS FAIL)) "FAIL"
Check "public task: scope, suite, failsOnOld PASS -> PASS" (Get-RunVerdict (Run m t "" "" PASS PASS PASS)) "PASS"
Check "public task: failsOnOld SKIP -> FAIL" (Get-RunVerdict (Run m t "" "" PASS PASS SKIP)) "FAIL"
Check "public task: failsOnOld FAIL -> FAIL" (Get-RunVerdict (Run m t "" "" PASS PASS FAIL)) "FAIL"
Check "checklist task -> MANUAL" (Get-RunVerdict (Run m t checklist "")) "MANUAL"

Write-Host "-- Get-RoundSummary"
$runs = @(
    (Run a t1 acceptance PASS), (Run a t1 acceptance PASS), (Run a t1 acceptance PASS),
    (Run a t2 acceptance PASS), (Run a t2 acceptance FAIL), (Run a t2 acceptance FAIL),
    (Run a t3 acceptance FAIL), (Run a t3 acceptance FAIL), (Run a t3 acceptance FAIL), (Run a t3 acceptance FAIL),
    (Run a t4 checklist ""),
    (Run b t1 acceptance PASS), (Run b t1 acceptance FAIL))
$s = Get-RoundSummary -Runs $runs
Check "two models, kept apart" (($s | ForEach-Object model) -join ",") "a,b"
Check "one k for both models: the smallest n of any task of either (b's t1 has 2)" (($s | ForEach-Object k) -join ",") "2,2"
$a = (Get-RoundSummary -Runs @($runs | Where-Object model -eq a))[0]
Check "model a: runs, passes, per run (the checklist run left out)" ("{0}|{1}|{2}|{3}" -f $a.runs, $a.passes, $a.perRun, $a.manualRuns) "10|4|0.4|1"
Check "...k is the smallest n" $a.k 3
Check "...per task c/n" (($a.tasks | ForEach-Object { "$($_.task)=$($_.c)/$($_.n)" }) -join ",") "t1=3/3,t2=1/3,t3=0/4"
Check "...pass@3 and pass^3 means: (1+1+0)/3, (1+0+0)/3" ("{0}|{1}" -f $a.passAtK, $a.passHatK) "0.667|0.333"
Check "...always and never passed" ("{0}|{1}" -f $a.tasksAlwaysPassed, $a.tasksNeverPassed) "1|1"
Write-Host "-- eras and arms inside one summary"
$mixed = @((Run a t1 acceptance PASS), (Run a t1 acceptance PASS))
$mixed[0] | Add-Member -NotePropertyName numCtx -NotePropertyValue 32768
$mixed[1] | Add-Member -NotePropertyName numCtx -NotePropertyValue 65536
Check "runs that differ in numCtx are pooled but the mix is listed" ((Get-RoundSummary -Runs $mixed)[0].eras["numCtx"] -join "|") "32768|65536"
$armed = @((Run a t1 acceptance PASS), (Run a t1 acceptance FAIL))
$armed[0] | Add-Member -NotePropertyName arm -NotePropertyValue "ASSISTED"
$armed[1] | Add-Member -NotePropertyName arm -NotePropertyValue ""
$sa = Get-RoundSummary -Runs $armed
Check "an ASSISTED arm is its own group, not pooled with the same model" (($sa | ForEach-Object { "$($_.model)[$($_.arm)]=$($_.passes)/$($_.runs)" }) -join ",") "a[]=0/1,a[ASSISTED]=1/1"
$zw = Run a t1 acceptance PASS
$zw | Add-Member -NotePropertyName writes -NotePropertyValue 0
Check "a passing run with writes = 0 is counted and noted, not silently dropped" ((Get-RoundSummary -Runs @($zw))[0].zeroWritePasses) 1
$s = Get-RoundSummary -Runs $runs -K 4
Check "-K 4: tasks with fewer runs are listed and left out of the means" ("{0}|{1}|{2}" -f ($s[0].tasksBelowK -join ","), $s[0].passAtK, $s[0].passHatK) "t1,t2|0|0"

Write-Host "-- the selector against the truth (a planner's tests shown)"
function PR([string]$Sel, [string]$Truth, [string]$Scope = "PASS", [string]$Suite = "PASS", [string[]]$Tampered = @(), [string]$Source = "planner") {
    [pscustomobject]@{ model = "m"; taskId = "t"; grading = "acceptance"; gates = [ordered]@{ scope = $Scope; suite = $Suite; failsOnOld = "SKIP" }
        acceptance = [ordered]@{ status = $Truth }; selector = [ordered]@{ status = $Sel; source = $Source }; acceptanceShown = [ordered]@{ tampered = $Tampered } }
}
$pruns = @(
    (PR PASS PASS), (PR PASS PASS), (PR PASS PASS), (PR PASS PASS),         # 4 true positives
    (PR PASS FAIL), (PR PASS FAIL PASS FAIL),                              # 2 false positives, the second also fails the suite (not kept)
    (PR FAIL PASS), (PR FAIL FAIL), (PR FAIL FAIL),                        # 1 false negative, 2 true negatives
    (PR ERROR PASS))                                                       # the selector could not run
$c = Get-SelectorConfusion $pruns
Check "runs and selector PASS / FAIL / other" ("{0}|{1}|{2}|{3}" -f $c.runs, $c.selectorPass, $c.selectorFail, $c.selectorOther) "10|6|3|1"
Check "false positives (selector PASS, hidden FAIL) and false negatives (selector FAIL, hidden PASS)" ("{0}|{1}" -f $c.falsePositives, $c.falseNegatives) "2|1"
Check "kept by a dispatcher (selector, scope, suite PASS): 5, one of them wrong by the hidden tests" ("{0}|{1}" -f $c.accepted, $c.acceptedWrong) "5|1"
$tp = @($pruns[0..3]) + @(PR PASS PASS PASS PASS @("p.test.ts (edited)"))
Check "a tampered run is not kept by a dispatcher" (Get-SelectorConfusion $tp).accepted 4
Check "oracle-shown runs (selector source hidden) are not counted; no planner runs: null" ($null -eq (Get-SelectorConfusion @((PR PASS PASS PASS PASS @() hidden)))) "True"
Check "a hidden-test run with no selector field: null" ($null -eq (Get-SelectorConfusion @((Run m t acceptance PASS)))) "True"
$w = Get-WilsonInterval 1 10
Check "Wilson 95% interval for 1 of 10: 0.018 to 0.404" ("{0:N3}|{1:N3}" -f $w.Low, $w.High) "0.018|0.404"
$w = Get-WilsonInterval 0 5
Check "...0 of 5 starts at 0, not below" ("{0:N3}|{1:N3}" -f $w.Low, $w.High) "0.000|0.434"
Check "...no runs: null" ($null -eq (Get-WilsonInterval 0 0)) "True"
$gs = Get-RoundSummary -Runs $pruns
Check "the summary carries it, and the group's pass rule is still the hidden tests (scope, suite, acceptance): 6 of 10" ("{0}|{1}|{2}" -f $gs[0].selector.falsePositives, $gs[0].passes, $gs[0].runs) "2|6|10"
Check "a summary of runs with no planner selector has none" ($null -eq (Get-RoundSummary -Runs @((Run a t acceptance PASS)))[0].selector) "True"

Write-Host "-- the script end to end"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("summarize-rounds-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path (Join-Path $tmp "r\sub") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmp "empty") -Force | Out-Null
try {
    $i = 0
    foreach ($x in $runs) { $i++; $x | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $tmp ("r\{0}tasks-{1}-{2}.json" -f $(if ($i % 2) { "sub\" } else { "" }), $x.taskId, $i)) }
    '{"not":"a run"}' | Set-Content -LiteralPath (Join-Path $tmp "r\tasks-summary.json")
    'x' | Set-Content -LiteralPath (Join-Path $tmp "r\tasks-junk.json")
    $psExe = (Get-Process -Id $PID).Path
    # Marker folders and infrastructure exits, read by the real script.
    $arms = Join-Path $tmp "arms"
    New-Item -ItemType Directory -Path (Join-Path $arms "nudged/deep") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $arms "nudged/ASSISTED") -Value "x"
    $plain = Run m t1 acceptance PASS
    $deep = Run m t1 acceptance PASS
    $infra = Run m t1 acceptance FAIL
    $infra | Add-Member -NotePropertyName opencodeExit -NotePropertyValue 1
    $plain | Add-Member -NotePropertyName opencodeExit -NotePropertyValue 0
    $plain | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $arms "tasks-t1-plain.json")
    $deep | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $arms "nudged/deep/tasks-t1-deep.json")
    $infra | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $arms "tasks-t1-infra.json")
    $aj = & $psExe -NoProfile -File $ScriptPath -ResultsDir $arms -AsJson 2>&1 | Out-String | ConvertFrom-Json
    Check "a marker in a parent folder splits the arm; an exit-1 run JSON is skipped" (($aj | ForEach-Object { "$($_.arm)=$($_.runs)" } | Sort-Object) -join ",") "=1,ASSISTED=1"
    $out = & $psExe -NoProfile -File $ScriptPath -ResultsDir (Join-Path $tmp "r") -Model a -AsJson 2>&1 | Out-String
    $j = $out | ConvertFrom-Json
    Check "-AsJson, -Model a, subfolders read, other JSON skipped" ("{0}|{1}|{2}|{3}" -f $j.model, $j.runs, $j.passes, $j.k) "a|10|4|3"
    $out = & $psExe -NoProfile -File $ScriptPath -ResultsDir (Join-Path $tmp "r") -K 3 2>&1 | Out-String
    Check "the table names both models and pass^k" ([bool]($out -match 'a: 10 graded runs, 4 passed' -and $out -match 'b: 2 graded runs' -and $out -match 'pass\^3 0\.333')) "True"
    # A planner-shown folder: the arm is named, the selector section printed with counts and intervals.
    $pl = Join-Path $tmp "planner"; New-Item -ItemType Directory -Path $pl -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pl "ACCEPTANCE-PLANNER") -Value "x"
    $i = 0; foreach ($x in $pruns) { $i++; $x | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $pl ("tasks-t-{0}.json" -f $i)) }
    $out = & $psExe -NoProfile -File $ScriptPath -ResultsDir $pl 2>&1 | Out-String
    Check "the arm is named" ([bool]($out -match 'm \[ACCEPTANCE-PLANNER\]: 10 graded runs, 6 passed')) "True"
    Check "false positives: 2 of 6 selector-PASS runs, with an interval" ([bool]($out -match 'false positives \(selector PASS, hidden tests FAIL\): 2 of 6 \(33 ?%, 95% CI 10 ?% to 70 ?%\)')) "True"
    Check "false negatives: 1 of 3 selector-FAIL runs" ([bool]($out -match 'false negatives \(selector FAIL, hidden tests PASS\): 1 of 3')) "True"
    Check "kept by a dispatcher but wrong: 1 of 5" ([bool]($out -match 'kept by a dispatcher .*: 1 of 5 \(20 ?%')) "True"
    Check "the run whose selector could not run is flagged" ([bool]($out -match '1 run\(s\) whose selector neither passed nor failed')) "True"
    $aj = & $psExe -NoProfile -File $ScriptPath -ResultsDir $pl -AsJson 2>&1 | Out-String | ConvertFrom-Json
    Check "-AsJson has the selector counts" ("{0}|{1}|{2}" -f $aj[0].selector.falsePositives, $aj[0].selector.falseNegatives, $aj[0].selector.acceptedWrong) "2|1|1"
    & $psExe -NoProfile -File $ScriptPath -ResultsDir (Join-Path $tmp "nope") *> $null
    Check "a missing folder: exit 1" $LASTEXITCODE 1
    & $psExe -NoProfile -File $ScriptPath -ResultsDir (Join-Path $tmp "empty") *> $null
    Check "a folder with no runs: exit 1" $LASTEXITCODE 1

    $real = Join-Path $PrivateResults "ollama-read-budget"
    if (Test-Path -LiteralPath $real) {
        $j = & $psExe -NoProfile -File $ScriptPath -ResultsDir $real -AsJson 2>&1 | Out-String | ConvertFrom-Json
        Check "the desktop's four plugin-on reps: 47 of 60, 9 of 15 every time, pass^4 0.6, pass@4 0.867" ("{0}/{1}|{2}|{3}|{4}" -f $j.passes, $j.runs, $j.tasksAlwaysPassed, $j.passHatK, $j.passAtK) "47/60|9|0.6|0.867"
    } else {
        Write-Host "SKIP the private results are not on this machine ($PrivateResults)"
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

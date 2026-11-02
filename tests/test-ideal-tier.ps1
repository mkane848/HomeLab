# protects: experiment 3's Ideal tier: scored per item id, never a gate (test-tasks.ps1 -IdealDir)
# run-after: Get-IdealScore or the ideal block in test-tasks.ps1, run-retries.ps1 or summarize-rounds.ps1
# test-ideal-tier.ps1 - regression guard for the owner's Ideal tier (2026-11-01).
#
# Why this exists: the owner accepts small gaps but wants to SEE improvement across models and configurations. So
# DONE.md's Ideal lines get their own tests, run on every attempt and recorded as `ideal` (done of total, which ids),
# and nothing reads them to decide merge or retry. Two ways this goes wrong quietly: the score miscounts (an id read
# as done when its test failed, or a file that never loaded counted as all done), or the tier leaks into a gate (a
# missed ideal item rejecting good work, which is exactly what the owner said not to do).
#
# What it does: feeds Get-IdealScore (extracted from test-tasks.ps1) runner output in vitest's shapes, then checks
# statically that the ideal block sets no gate and that the dispatcher and the summary's "accepted" never read it.
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$tt = Get-Content -Raw -LiteralPath (Join-Path $repo "tests/test-tasks.ps1")
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "PASS $name" }
    else { Write-Host "FAIL $name (got '$actual', expected '$expected')"; $script:fail++ }
}
$fn = [regex]::Match($tt, '(?s)function Get-IdealScore \{.*?\r?\n\}').Value
if (-not $fn) { Write-Host "FAIL: Get-IdealScore not found in test-tasks.ps1"; exit 1 }
Invoke-Expression $fn

$files = @(@"
describe('AGENTS.md ideal', () => {
  it('I1: the CI description mentions npm audit', () => {});
  it("I2: mentions the Pages workflow", () => {});
  test('I3.1: names listing-expiry', () => {});
  it('helper without an id', () => {});
});
"@)
$esc = [char]27

Write-Host "-- scoring"
$r = Get-IdealScore -FileTexts $files -Output @(" ✓ tests/docs/ideal.test.ts (3 tests)", " Tests  4 passed (4)") -Status "PASS"
Check "all pass: 3 of 3 done"                      "$($r.done)/$($r.total)" "3/3"
Check "...the ids, in file order"                  ($r.doneIds -join ",") "I1,I2,I3.1"
Check "...a test with no id is not an item"        $r.total 3

$out = @(" ✓ tests/docs/ideal.test.ts > AGENTS.md ideal > I1: the CI description mentions npm audit",
         " × tests/docs/ideal.test.ts > AGENTS.md ideal > I2: mentions the Pages workflow 3ms",
         " ✓ tests/docs/ideal.test.ts > AGENTS.md ideal > I3.1: names listing-expiry",
         " FAIL  tests/docs/ideal.test.ts > AGENTS.md ideal > I2: mentions the Pages workflow",
         " Tests  1 failed | 3 passed (4)")
$r = Get-IdealScore -FileTexts $files -Output $out -Status "FAIL"
Check "one fails: 2 of 3 done"                     "$($r.done)/$($r.total)" "2/3"
Check "...the missed id, once"                     ($r.missedIds -join ",") "I2"

$r = Get-IdealScore -FileTexts $files -Output @("$esc[31m × $esc[0mtests/docs/ideal.test.ts > $esc[1mI3.1: names listing-expiry$esc[22m$esc[0m") -Status "FAIL"
Check "colour codes in the output are read through" ($r.missedIds -join ",") "I3.1"

$r = Get-IdealScore -FileTexts $files -Output @(" ✓ ... > I1: x", " ✓ ... > I2: y", " FAIL  tests/docs/ideal.test.ts [ tests/docs/ideal.test.ts ]", " SyntaxError: Unexpected token") -Status "FAIL"
Check "a file that did not load: nothing done"     "$($r.done)/$($r.total)" "0/3"

$r = Get-IdealScore -FileTexts $files -Output @(" × ... > GI1: not an ideal id", " × ... > XI2: nor this") -Status "FAIL"
Check "an id inside another word is not read"      "$($r.done)/$($r.total)" "0/3"

Check "ERROR (the set could not run): no score"    ($null -eq (Get-IdealScore -FileTexts $files -Output @() -Status "ERROR")) "True"
Check "a set that names no ids: no score"          ($null -eq (Get-IdealScore -FileTexts @("it('plain', () => {})") -Output @() -Status "PASS")) "True"

Write-Host "-- the round summary (summarize-rounds.ps1 Get-IdealSummary)"
. (Join-Path $repo "tests/summarize-rounds.ps1")
$mk = { param($done, $total, $integrity) $g = [ordered]@{ suite = "PASS"; scope = "PASS" }; if ($integrity) { $g.integrity = $integrity }
    [pscustomobject]@{ gates = [pscustomobject]$g; ideal = $(if ($null -ne $total) { [pscustomobject]@{ done = $done; total = $total } } else { $null }) } }
$sum = Get-IdealSummary @((& $mk 2 3 "PASS"), (& $mk 1 1 "FAIL"), (& $mk $null $null "SKIP"), (& $mk $null $null $null))
Check "items done over the runs that have a tier"  "$($sum.itemsDone)/$($sum.itemsTotal) in $($sum.runs)" "3/4 in 2"
Check "...mean per run, not pooled"                $sum.meanPerRun 0.833
Check "integrity: runs that changed Markdown"      "$($sum.integrityFailed) of $($sum.integrityChecked)" "1 of 2"
Check "no tier and no integrity anywhere: null"    ($null -eq (Get-IdealSummary @((& $mk $null $null $null)))) "True"

Write-Host "-- never a gate (static)"
$block = [regex]::Match($tt, '(?s)# --- the Ideal tier: measured, never a gate -+.*?# --- record -+').Value
Check "test-tasks.ps1 has the ideal block"         ([bool]$block) "True"
Check "...which never sets overallPass"            ($block -match 'overallPass') "False"
Check "...and never touches the gates"             ($block -match 'gateSummary|\$integrity|\$suite|\$scope') "False"
Check "...and writes INFO, not PASS/FAIL"          ($block -match 'Write-Result \$tk\.id "ideal \(measured, not a gate\)" "INFO"') "True"
Check "the run JSON records it"                    ($tt -match 'ideal\s+= \$idealRecord') "True"
$rr = Get-Content -Raw -LiteralPath (Join-Path $repo "tests/run-retries.ps1")
$verdict = [regex]::Match($rr, '(?s)function Get-AttemptVerdict \{.*?\r?\n\}').Value
Check "the dispatcher's verdict never reads it"    ($verdict -match '\.ideal\b') "False"
$sr = Get-Content -Raw -LiteralPath (Join-Path $repo "tests/summarize-rounds.ps1")
$acc = ($sr -split "`n" | Where-Object { $_ -match '\$accepted = ' }) -join "`n"
Check "the summary's 'accepted' never reads it"    ($acc -match '\.ideal\b') "False"

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host "all passed"
exit 0

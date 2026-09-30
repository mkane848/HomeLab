# test-batch-plan.ps1 - regression guard for how run-tasks-batch.ps1 orders replicates
# and holds a batch to one opencode version.
#
# Why this exists: the N>1 protocol (docs/adversarial-review-2026-09-29.md, section 7)
# needs replicates that are evidence about variance. Two things undermined them:
#   1. The run list put a cell's reps back to back (task outer, rep inner). Pairs run
#      that way agreed in 11 of 11; a cell's reps a session apart did not, and the two
#      cannot be told apart from the version below. New-RunList now runs rep-outer
#      within each model (every task's rep 1, then every task's rep 2) unless
#      -BackToBack.
#   2. opencode installs patch releases by itself when a TUI starts, so the corpus went
#      1.18.31 -> .32 -> .33 in ten days and every mixed cell straddles two versions.
#      The batch now reads the version once and stops if it changes
#      (Get-OpencodeVersionDrift), and the preflight reports whether autoupdate is
#      pinned (Test-OpencodeAutoupdatePinned).
#
# What it does: pulls the REAL functions out of run-tasks-batch.ps1 (so it tests the
# script as written, not a copy) and checks the run order, the version reading and
# drift message (against a stand-in `opencode`), and the pin rule. Exit 1 on any
# failure.
#
# Usage:  .\tests\test-batch-plan.ps1 [-ScriptPath <a run-tasks-batch.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "run-tasks-batch.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($name in "New-RunList", "Get-OpencodeVersion", "Get-OpencodeVersionDrift", "Test-OpencodeAutoupdatePinned") {
    $fn = $fns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Seq($plan) { (@($plan.Runs | ForEach-Object { "{0}:{1}/r{2}" -f $_.Model, $_.Task, $_.Rep })) -join " " }

Write-Host "-- run order"
$p = New-RunList -Models @("m1") -Tasks @("a", "b", "c") -Reps 2
Check "rep-outer by default"                         (Seq $p) "m1:a/r1 m1:b/r1 m1:c/r1 m1:a/r2 m1:b/r2 m1:c/r2"
$p = New-RunList -Models @("m1") -Tasks @("a", "b", "c") -Reps 2 -BackToBack
Check "-BackToBack keeps a cell's reps adjacent"     (Seq $p) "m1:a/r1 m1:a/r2 m1:b/r1 m1:b/r2 m1:c/r1 m1:c/r2"
$p = New-RunList -Models @("m1", "m2") -Tasks @("a", "b") -Reps 2
Check "models stay grouped (no reload thrash)"       (Seq $p) "m1:a/r1 m1:b/r1 m1:a/r2 m1:b/r2 m2:a/r1 m2:b/r1 m2:a/r2 m2:b/r2"
$one = Seq (New-RunList -Models @("m1", "m2") -Tasks @("a", "b", "c") -Reps 1)
Check "one rep: both orders are the same"            (Seq (New-RunList -Models @("m1", "m2") -Tasks @("a", "b", "c") -Reps 1 -BackToBack)) $one

$p = New-RunList -Models @("m1", "m2") -Tasks @("a", "b", "c", "d") -Reps 3
$seen = @{}; foreach ($r in $p.Runs) { $seen["$($r.Model)|$($r.Task)|$($r.Rep)"] = 1 }
Check "every model x task x rep exactly once"        ("{0}/{1}" -f $p.Runs.Count, $seen.Count) "24/24"
$idx = @{}; for ($i = 0; $i -lt $p.Runs.Count; $i++) { $r = $p.Runs[$i]; $idx["$($r.Model)|$($r.Task)|$($r.Rep)"] = $i }
Check "a cell's reps are one whole pass (4 tasks) apart" ($idx["m1|b|2"] - $idx["m1|b|1"]) 4
$p = New-RunList -Models @("m1", "m2") -Tasks @("a", "b", "c", "d") -Reps 3 -BackToBack
$idx = @{}; for ($i = 0; $i -lt $p.Runs.Count; $i++) { $r = $p.Runs[$i]; $idx["$($r.Model)|$($r.Task)|$($r.Rep)"] = $i }
Check "back-to-back: a cell's reps are adjacent"     ($idx["m1|b|2"] - $idx["m1|b|1"]) 1

Write-Host "-- -OnlyMissing"
$graded = @{ "b|m1" = 2 }
$p = New-RunList -Models @("m1", "m2") -Tasks @("a", "b") -Reps 2 -Graded $graded -OnlyMissing
Check "a graded pair is dropped for every rep"       (Seq $p) "m1:a/r1 m1:a/r2 m2:a/r1 m2:b/r1 m2:a/r2 m2:b/r2"
Check "skipped counts pairs, not runs"               $p.Skipped 1
$p = New-RunList -Models @("m1") -Tasks @("a", "b") -Reps 2 -Graded $graded
Check "without -OnlyMissing nothing is dropped"      ("{0} runs, skipped {1}" -f $p.Runs.Count, $p.Skipped) "4 runs, skipped 0"

Write-Host "-- opencode version reading and drift (stand-in opencode)"
function opencode { "1.18.33" }
Check "reads the version"                            (Get-OpencodeVersion) "1.18.33"
Check "no drift while it still reports the same"     ($null -eq (Get-OpencodeVersionDrift -Expected "1.18.33")) "True"
Check "drift message names both versions"            (Get-OpencodeVersionDrift -Expected "1.18.32") "opencode changed from 1.18.32 to 1.18.33 during the batch"
Check "no expected version: no claim"                ($null -eq (Get-OpencodeVersionDrift -Expected "")) "True"
function opencode { "error: something went wrong" }
Check "output that is not a version reads as unknown" ($null -eq (Get-OpencodeVersion)) "True"
Check "cannot ask: no drift claim"                   ($null -eq (Get-OpencodeVersionDrift -Expected "1.18.33")) "True"
function opencode { throw "opencode is not available" }
Check "opencode failing reads as unknown"            ($null -eq (Get-OpencodeVersion)) "True"
Check "opencode failing: no drift claim"             ($null -eq (Get-OpencodeVersionDrift -Expected "1.18.33")) "True"

Write-Host "-- autoupdate pin rule (opencode's own: false or 'notify' in config, or the flag is 1/true)"
function Cfg($v) { [pscustomobject]@{ autoupdate = $v } }
Check "autoupdate false is pinned"                   (Test-OpencodeAutoupdatePinned -Config (Cfg $false) -EnvValue "") "True"
Check "autoupdate 'notify' is pinned"                (Test-OpencodeAutoupdatePinned -Config (Cfg "notify") -EnvValue "") "True"
Check "autoupdate true is NOT pinned"                (Test-OpencodeAutoupdatePinned -Config (Cfg $true) -EnvValue "") "False"
Check "autoupdate unset is NOT pinned (default on)"  (Test-OpencodeAutoupdatePinned -Config ([pscustomobject]@{ model = "x" }) -EnvValue "") "False"
Check "no readable config is NOT pinned"            (Test-OpencodeAutoupdatePinned -Config $null -EnvValue "") "False"
Check "OPENCODE_DISABLE_AUTOUPDATE=1 pins"           (Test-OpencodeAutoupdatePinned -Config (Cfg $true) -EnvValue "1") "True"
Check "OPENCODE_DISABLE_AUTOUPDATE=TRUE pins"        (Test-OpencodeAutoupdatePinned -Config (Cfg $true) -EnvValue "TRUE") "True"
Check "OPENCODE_DISABLE_AUTOUPDATE=0 does not"       (Test-OpencodeAutoupdatePinned -Config (Cfg $true) -EnvValue "0") "False"
Check "OPENCODE_DISABLE_AUTOUPDATE=yes does not (not a truthy value to opencode)" (Test-OpencodeAutoupdatePinned -Config (Cfg $true) -EnvValue "yes") "False"

if ($script:fail) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 } else { Write-Host "RESULT: all checks passed" }

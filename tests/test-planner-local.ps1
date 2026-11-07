# protects: run-planner-local.ps1 prompt path rewrite, the audit of tool calls outside the scratch folder, and collecting files from the clone
# run-after: run-planner-local.ps1
# test-planner-local.ps1 - regression guard for desktop/scripts/run-planner-local.ps1, experiment 3's planner on a local
# model.
#
# Why this exists: the local planner runs without the frontier planner's container, so the audit of its transcript is the
# only thing that says whether a set is clean evidence, and an audit that misses an outside path would pass hidden tests
# off as the model's own reading. The prompt rewrite decides whether it gets the same instructions at all.
#
# What it does: the REAL functions on the real prompts (mount points moved, nothing else changed) and on stand-in tool
# events (outside paths caught in either slash style and any case; the scratch folder and a sibling with the same prefix
# told apart; the private repository named without a drive letter; text events ignored), the collection from a real git clone
# (lost paths restored, tiers kept apart, helpers, the repository's own tests, tests tidied out of the clone, impossible paths,
# edits, scratch), plus
# the script's refusals.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-planner-local.ps1 [-ScriptPath <a run-planner-local.ps1>]
param([string]$ScriptPath = (Join-Path (Split-Path $PSScriptRoot) "desktop\scripts\run-planner-local.ps1"))

$ErrorActionPreference = "Stop"
. $ScriptPath
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Tool($input1, [string[]]$Paths = @()) { [pscustomobject]@{ Kind = "tool"; Tool = "x"; Paths = $Paths; Input = $input1 } }

Write-Host "-- ConvertTo-LocalPrompt"
$t = "Clone: git clone /pack/tasks/<id>/base.bundle /workspace/work/<id>`nWrite /workspace/planner/<id>/<run>/DONE.md. Keep src/pack/x and a/workspace/y and /packages/z. Your folder is /pack/."
$c = ConvertTo-LocalPrompt -Text $t -PackDir 'C:\s\pack' -WorkDir 'C:\s\workspace\'
Check "the clone line's two mount points move" ([bool]($c -match 'git clone C:/s/pack/tasks/<id>/base\.bundle C:/s/workspace/work/<id>')) "True"
Check "the output path moves" ([bool]($c -match 'Write C:/s/workspace/planner/<id>/<run>/DONE\.md')) "True"
Check "a path that only contains the word stays" ([bool]($c -match 'Keep src/pack/x and a/workspace/y')) "True"
Check "a longer name starting the same stays" ([bool]($c -match '/packages/z')) "True"
Check "a mount point at the end of a sentence moves" ([bool]($c -match 'Your folder is C:/s/pack/\.')) "True"

Write-Host "-- Get-OutsideReferences"
$root = 'C:\s\run1'
Check "a clean run: nothing" (@(Get-OutsideReferences -Events @((Tool @{ filePath = 'C:\s\run1\workspace\a.ts' } @('C:\s\run1\workspace\a.ts'))) -Root $root).Count) 0
Check "the scratch folder itself is not outside" (@(Get-OutsideReferences -Events @((Tool @{ command = 'ls C:/s/run1' })) -Root $root).Count) 0
Check "case does not hide the scratch folder" (@(Get-OutsideReferences -Events @((Tool @{ command = 'ls c:\S\RUN1\pack' })) -Root $root).Count) 0
Check "a read outside, by a path field" (@(Get-OutsideReferences -Events @((Tool @{ filePath = 'M:\Projects\LFCbot\src\a.ts' } @('M:\Projects\LFCbot\src\a.ts'))) -Root $root) -join "|") "M:/Projects/LFCbot/src/a.ts"
Check "a read outside, in a shell command with forward slashes" (@(Get-OutsideReferences -Events @((Tool @{ command = 'cat M:/Projects/LFCbot/README.md' })) -Root $root) -join "|") "M:/Projects/LFCbot/README.md"
Check "a sibling with the same prefix is outside" (@(Get-OutsideReferences -Events @((Tool @{ command = 'ls C:\s\run10\x' })) -Root $root) -join "|") "C:/s/run10/x"
Check "the private repository named without a drive letter" (@(Get-OutsideReferences -Events @((Tool @{ command = 'cd ../../HomeLab-private/tasks' })) -Root $root) -join "|") "(names HomeLab-private)"
Check "text events are not tool calls" (@(Get-OutsideReferences -Events @([pscustomobject]@{ Kind = "text"; Text = 'see M:\Projects\x' }) -Root $root).Count) 0
Check "a findstr switch is not a drive" (@(Get-OutsideReferences -Events @((Tool @{ command = 'npm test | findstr /C:"FAIL" /C:"PASS"' })) -Root $root).Count) 0
Check "a bare drive root is outside" (@(Get-OutsideReferences -Events @((Tool @{ command = 'ls C:/' })) -Root $root) -join "|") "C:/"
Check "repeats count once" (@(Get-OutsideReferences -Events @((Tool @{ command = 'cat D:\a' }), (Tool @{ command = 'cat D:\a' })) -Root $root).Count) 1

Write-Host "-- Get-PlannerCollection"
$g = Join-Path ([IO.Path]::GetTempPath()) ("planner-collect-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
function Write-File([string]$Root, [string]$Rel, [string]$Text = "x") {
    $full = Join-Path $Root $Rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $full) | Out-Null
    [IO.File]::WriteAllText($full, $Text)
}
function New-Clone([string]$Name) {
    $c = Join-Path $g "$Name\clone"
    New-Item -ItemType Directory -Force $c | Out-Null
    git -C $c init -q; git -C $c config core.autocrlf false; git -C $c config user.email "t@example.invalid"; git -C $c config user.name "t"
    Write-File $c "packages/shared/src/existing.test.ts" "it('old', () => {})"
    Write-File $c "packages/shared/src/logic.ts" "export const a = 1"
    git -C $c add -A; git -C $c commit -q -m base
    return $c
}
function Names($list) { (@($list) | Sort-Object) -join "," }
try {
    $c = New-Clone a; $gd = Join-Path $g "a\gate"; $id = Join-Path $g "a\ideal"
    Write-File $c "packages/shared/src/new.test.ts" "import { h } from './helper'; it('G1: a', () => {})"
    Write-File $c "packages/shared/src/helper.ts" "export const h = 1"
    Write-File $c "scratch.js" "console.log(1)"
    Write-File $c "node_modules/x/y.test.ts" "not mine"
    Write-File $c "dist/built.test.ts" "build output, and this fixture does not ignore dist"
    Write-File $c "coverage/x.test.ts" "not mine"
    Write-File $gd "new.test.ts" "an older copy"
    Write-File $gd "NOTES.md" "notes"
    $r = Get-PlannerCollection -CloneDir $c -GateDir $gd -IdealDir $id -Tiers
    Check "a lost path comes back from the clone" (Names ($r.Collected | ForEach-Object Rel)) "packages/shared/src/helper.ts,packages/shared/src/new.test.ts"
    Check "...and is recorded as moved" (Names $r.Moved) "packages/shared/src/new.test.ts"
    Check "scratch that no test imports is left out, and recorded" (Names $r.Ignored) "scratch.js"
    Set-PlannerCollection -Collection $r -CloneDir $c -GateDir $gd -IdealDir $id
    Check "the output has the clone's bytes at the real path" ([IO.File]::ReadAllText((Join-Path $gd "packages/shared/src/new.test.ts"))) "import { h } from './helper'; it('G1: a', () => {})"
    Check "the imported helper travels with it" (Test-Path -LiteralPath (Join-Path $gd "packages/shared/src/helper.ts")) "True"
    Check "the misplaced copy is gone" (Test-Path -LiteralPath (Join-Path $gd "new.test.ts")) "False"
    Check "NOTES.md stays" (Test-Path -LiteralPath (Join-Path $gd "NOTES.md")) "True"

    $c = New-Clone b; $gd = Join-Path $g "b\gate"; $id = Join-Path $g "b\ideal"
    Write-File $c "tests/gate.test.ts" "import { s } from './shared'; it('G1: a', () => {})"
    Write-File $c "tests/ideal.test.ts" "import { s } from './shared'; it('I1: b', () => {})"
    Write-File $c "tests/unhanded-ideal.test.ts" "it('I2: c', () => {})"
    Write-File $c "tests/unhanded-gate.test.ts" "it('G2: d', () => {})"
    Write-File $c "tests/shared.ts" "export const s = 1"
    Write-File $c "tests/moved-to-ideal.test.ts" "it('G9: named like the Gate', () => {})"
    Write-File $id "moved-to-ideal.test.ts"
    Write-File $gd "gate.test.ts"; Write-File $id "ideal.test.ts"
    $r = Get-PlannerCollection -CloneDir $c -GateDir $gd -IdealDir $id -Tiers
    $tier = { param($n) (@($r.Collected | Where-Object { (Split-Path -Leaf $_.Rel) -eq $n } | ForEach-Object Tiers) | Sort-Object) -join "+" }
    Check "the folder it was handed into decides the tier" ("{0}|{1}" -f (& $tier "gate.test.ts"), (& $tier "ideal.test.ts")) "gate|ideal"
    Check "...even over the ids in its names: the model's choice of folder stands" (& $tier "moved-to-ideal.test.ts") "ideal"
    Check "not handed in: its test ids decide" ("{0}|{1}" -f (& $tier "unhanded-ideal.test.ts"), (& $tier "unhanded-gate.test.ts")) "ideal|gate"
    Check "a helper both tiers import goes to both" (& $tier "shared.ts") "gate+ideal"
    Set-PlannerCollection -Collection $r -CloneDir $c -GateDir $gd -IdealDir $id
    Check "an Ideal test never lands in the Gate folder" (Test-Path -LiteralPath (Join-Path $gd "tests/ideal.test.ts")) "False"
    Check "...and the Gate's not in the Ideal folder" (Test-Path -LiteralPath (Join-Path $id "tests/gate.test.ts")) "False"
    Check "the plan phase has one tier, whatever the names say" (@((Get-PlannerCollection -CloneDir $c -GateDir (Join-Path $g "b\none")).Collected | Where-Object { (Split-Path -Leaf $_.Rel) -eq "unhanded-ideal.test.ts" } | ForEach-Object Tiers) -join "+") "gate"

    $c = New-Clone c; $gd = Join-Path $g "c\gate"
    Write-File $gd "packages/shared/src/existing.test.ts" "it('old', () => {})"
    $r = Get-PlannerCollection -CloneDir $c -GateDir $gd
    Check "the repository's own tests handed in untouched are not the planner's work" ("{0}|{1}" -f $r.Collected.Count, (Names $r.ExistingUnchanged)) "0|packages/shared/src/existing.test.ts"

    $c = New-Clone d; $gd = Join-Path $g "d\gate"
    Write-File $gd "wrote-it-out-here.test.ts" "it('G1: a', () => {})"
    $r = Get-PlannerCollection -CloneDir $c -GateDir $gd
    Check "a test written only in the output folder is not collected, and recorded" ("{0}|{1}" -f $r.Collected.Count, (Names $r.NotInClone)) "0|wrote-it-out-here.test.ts"
    Set-PlannerCollection -Collection $r -CloneDir $c -GateDir $gd
    Check "...and it does not stand as a set" (Test-Path -LiteralPath (Join-Path $gd "wrote-it-out-here.test.ts")) "False"

    # wp-0a, 2026-11-06: written in the output folder at the right path, copied into the clone to run it, removed again. Good work.
    $c = New-Clone k; $gd = Join-Path $g "k\gate"; $id = Join-Path $g "k\ideal"
    Write-File $gd "packages/shared/src/tidied.test.ts" "it('G1: a', () => {})"
    Write-File $id "packages/shared/src/tidied-ideal.test.ts" "it('I1: b', () => {})"
    Write-File $gd "packages/brand-new/x.test.ts" "it('G2: c', () => {})"
    Write-File $gd "src/routes/no-package-folder.test.ts" "it('G3: d', () => {})"
    Write-File $gd "tests/no-such-top-folder.test.ts" "it('G4: e', () => {})"
    $r = Get-PlannerCollection -CloneDir $c -GateDir $gd -IdealDir $id -Tiers
    Check "a test tidied out of the clone at a real path is kept" (Names ($r.Kept | ForEach-Object Rel)) "packages/brand-new/x.test.ts,packages/shared/src/tidied-ideal.test.ts,packages/shared/src/tidied.test.ts"
    Check "...a path the repository cannot have is not" (Names $r.NotInClone) "src/routes/no-package-folder.test.ts,tests/no-such-top-folder.test.ts"
    Set-PlannerCollection -Collection $r -CloneDir $c -GateDir $gd -IdealDir $id
    Check "...kept byte for byte, in its own tier" ("{0}|{1}" -f [IO.File]::ReadAllText((Join-Path $gd "packages/shared/src/tidied.test.ts")), [IO.File]::ReadAllText((Join-Path $id "packages/shared/src/tidied-ideal.test.ts"))) "it('G1: a', () => {})|it('I1: b', () => {})"
    Check "...and the Ideal one is not in the Gate folder" (Test-Path -LiteralPath (Join-Path $gd "packages/shared/src/tidied-ideal.test.ts")) "False"
    Check "...the impossible path is gone from the set" (Test-Path -LiteralPath (Join-Path $gd "src/routes/no-package-folder.test.ts")) "False"

    $c = New-Clone e; $gd = Join-Path $g "e\gate"
    Add-Content -LiteralPath (Join-Path $c "packages/shared/src/existing.test.ts") -Value "it('G1: new', () => {})"
    Write-File $gd "existing.test.ts" "copied flat"
    $r = Get-PlannerCollection -CloneDir $c -GateDir $gd
    Check "an existing test it edited and handed in is collected, at its real path" (Names ($r.Collected | ForEach-Object Rel)) "packages/shared/src/existing.test.ts"
    $c2 = New-Clone f
    Add-Content -LiteralPath (Join-Path $c2 "packages/shared/src/existing.test.ts") -Value "it('tried', () => {})"
    Add-Content -LiteralPath (Join-Path $c2 "packages/shared/src/logic.ts") -Value "export const b = 2"
    $r = Get-PlannerCollection -CloneDir $c2 -GateDir (Join-Path $g "f\gate")
    Check "edited and not handed in: left out, recorded" ("{0}|{1}" -f $r.Collected.Count, (Names $r.EditedNotHandedIn)) "0|packages/shared/src/existing.test.ts"
    Check "a source change is never collected, and recorded" (Names $r.OtherChanges) "packages/shared/src/logic.ts"

    $c3 = New-Clone h
    Write-File $c3 "tests/with space `u{e9}.test.ts" "it('G1: a', () => {})"
    $r = Get-PlannerCollection -CloneDir $c3 -GateDir (Join-Path $g "h\gate")
    Check "a path with a space and an accent survives" (Names ($r.Collected | ForEach-Object Rel)) "tests/with space `u{e9}.test.ts"

    $r = Get-PlannerCollection -CloneDir (Join-Path $g "no-such-clone") -GateDir (Join-Path $g "a\gate")
    Check "no clone at all: nothing collected, and it says so" ("{0}|{1}" -f $r.CloneFound, $r.Collected.Count) "False|0"
} finally { Remove-Item -Recurse -Force $g -ErrorAction SilentlyContinue }

Write-Host "-- the script's refusals"
$psExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("planner-local-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force (Join-Path $tmp "pack\tasks\t1") | Out-Null
try {
    $o = & $psExe -NoProfile -File $ScriptPath -Pack (Join-Path $tmp "pack") -Out (Join-Path $tmp "o") -Run 1 -Model "p/m" 2>&1 | Out-String
    Check "no -ServerUrl: exit 3, before anything runs" ("{0}|{1}" -f $LASTEXITCODE, [bool]($o -match 'ServerUrl is required')) "3|True"
    $o = & $psExe -NoProfile -File $ScriptPath -Pack (Join-Path $tmp "pack") -Out (Join-Path $tmp "o") -Run 1 -Model "p/m" -ServerUrl "http://x/v1" 2>&1 | Out-String
    Check "a pack without the phase's prompt: exit 1, named" ("{0}|{1}" -f $LASTEXITCODE, [bool]($o -match 'PROMPT\.md is missing')) "1|True"
    Set-Content -LiteralPath (Join-Path $tmp "pack\PROMPT.md") -Value "x"
    $o = & $psExe -NoProfile -File $ScriptPath -Pack (Join-Path $tmp "pack") -Out (Join-Path $tmp "o") -Run 1 -Model "p/m" -ServerUrl "http://x/v1" -Tasks t1 2>&1 | Out-String
    Check "a task with no bundle: exit 1, named" ("{0}|{1}" -f $LASTEXITCODE, [bool]($o -match 'no pack for task t1')) "1|True"
    Set-Content -LiteralPath (Join-Path $tmp "pack\TESTS-PROMPT.md") -Value "x"
    Set-Content -LiteralPath (Join-Path $tmp "pack\tasks\t1\base.bundle") -Value "x"
    $o = & $psExe -NoProfile -File $ScriptPath -Pack (Join-Path $tmp "pack") -Out (Join-Path $tmp "o") -Run 1 -Phase tests -Model "p/m" -ServerUrl "http://x/v1" -Tasks t1 2>&1 | Out-String
    Check "tests phase without a confirmed list: exit 1, named, no output folder" ("{0}|{1}|{2}" -f $LASTEXITCODE, [bool]($o -match 'DONE\.md'), (Test-Path (Join-Path $tmp "o"))) "1|True|False"
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

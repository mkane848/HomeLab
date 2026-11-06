# protects: run-planner-local.ps1 prompt path rewrite and the audit of tool calls outside the scratch folder
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
# told apart; the private repository named without a drive letter; text events ignored), plus the script's refusals.
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

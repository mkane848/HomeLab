# test-retired-tasks.ps1 - regression guard for retired benchmark tasks
#
# Why this exists: a task the manifest marks `retired` ({date, reason, see})
# keeps its id, pin and recorded rows as history but must not be run by
# accident: not by a no-argument test-tasks.ps1, not by `-Tasks all` or the
# batch picker, and naming it is an error unless -IncludeRetired. First
# retired 2026-10-03: asohav-05/06, whose ~280 KB CLAUDE.md at the pin makes the
# first request ~83k tokens, so no 64k seat can see the task
# (tests/results/README.md -> "Prompt truncated by Ollama").
#
# What it does: checks the real manifest's retired entries are well formed;
# pulls the REAL Resolve-TaskSelection (test-tasks.ps1) and Get-OfferedTasks
# (run-tasks-batch.ps1) and runs them on fixtures; then runs both real scripts
# naming a retired task and expects a refusal before any work starts.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-retired-tasks.ps1

$ErrorActionPreference = "Stop"
$tt = Join-Path $PSScriptRoot "test-tasks.ps1"
$rb = Join-Path $PSScriptRoot "run-tasks-batch.ps1"
foreach ($pair in @(@($tt, "Resolve-TaskSelection"), @($rb, "Get-OfferedTasks"))) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($pair[0], [ref]$null, [ref]$errs)
    if ($errs.Count) { $errs; exit 2 }
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) |
        Where-Object { $_.Name -eq $pair[1] } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $($pair[1]) not found in $($pair[0])"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Ids($list) { (@($list | ForEach-Object id) | Sort-Object) -join "," }

Write-Host "-- the manifest"
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot "tasks\manifest.json") -Raw | ConvertFrom-Json
$retired = @($manifest.tasks | Where-Object { $_.retired })
Check "asohav-05 and asohav-06 are retired" (Ids ($retired | Where-Object { $_.id -like "asohav-0[56]-*" })) "asohav-05-library-write-validation,asohav-06-bond-cap-setting"
foreach ($t in $retired) {
    Check "$($t.id): retired.date is a date"   ($t.retired.date -match '^\d{4}-\d{2}-\d{2}$') "True"
    Check "$($t.id): retired.reason says why"  (-not [string]::IsNullOrWhiteSpace($t.retired.reason)) "True"
    Check "$($t.id): retired.see points at the evidence" (-not [string]::IsNullOrWhiteSpace($t.retired.see)) "True"
    Check "$($t.id): still pinned (history kept)" ($t.benchBaseCommit -match '^[0-9a-f]{40}$') "True"
}

Write-Host "-- Resolve-TaskSelection (test-tasks.ps1)"
$fx = @(
    [pscustomobject]@{ id = "a" },
    [pscustomobject]@{ id = "b"; retired = [pscustomobject]@{ date = "2026-10-03"; reason = "r"; see = "s" } },
    [pscustomobject]@{ id = "c" }
)
$s = Resolve-TaskSelection -AllTasks $fx -Requested @() -IncludeRetired $false
Check "no -Task: runs the active ones"            (Ids $s.Run) "a,c"
Check "no -Task: reports the retired as skipped"  (Ids $s.Skipped) "b"
Check "no -Task: refuses nothing"                 (Ids $s.Refused) ""
$s = Resolve-TaskSelection -AllTasks $fx -Requested @("a") -IncludeRetired $false
Check "naming an active task runs it"             (Ids $s.Run) "a"
$s = Resolve-TaskSelection -AllTasks $fx -Requested @("a", "b") -IncludeRetired $false
Check "naming a retired task refuses it"          (Ids $s.Refused) "b"
Check "...and does not run it"                    (Ids $s.Run) "a"
$s = Resolve-TaskSelection -AllTasks $fx -Requested @() -IncludeRetired $true
Check "-IncludeRetired with no -Task: all three"  (Ids $s.Run) "a,b,c"
$s = Resolve-TaskSelection -AllTasks $fx -Requested @(" b ") -IncludeRetired $true
Check "-IncludeRetired naming it: runs it (ids trimmed)" (Ids $s.Run) "b"
Check "-IncludeRetired: refuses nothing"          (Ids $s.Refused) ""

Write-Host "-- Get-OfferedTasks (run-tasks-batch.ps1)"
Check "the batch offers only active tasks"        (Ids (Get-OfferedTasks -ManifestTasks $fx -IncludeRetired $false)) "a,c"
Check "-IncludeRetired offers all"                (Ids (Get-OfferedTasks -ManifestTasks $fx -IncludeRetired $true)) "a,b,c"
Check "the real manifest: 'all' leaves out every retired task" @(Get-OfferedTasks -ManifestTasks $manifest.tasks -IncludeRetired $false | Where-Object { $_.retired }).Count 0

Write-Host "-- end to end: both scripts refuse a named retired task before doing any work"
$psExe = (Get-Process -Id $PID).Path
$out = & $psExe -NoProfile -File $tt -Task asohav-05-library-write-validation -DryRun 2>&1 | Out-String
Check "test-tasks.ps1 exits 1"                    $LASTEXITCODE 1
Check "...saying the task is retired and why"     ($out -match 'asohav-05-library-write-validation is retired \(2026-10-03\)') "True"
Check "...and how to override"                    ($out -match '-IncludeRetired') "True"
$out = & $psExe -NoProfile -File $rb -SkipSetup -Mode Tasks -Tasks asohav-06-bond-cap-setting -Models ollama-desktop/none -Reps 1 -Yes 2>&1 | Out-String
Check "run-tasks-batch.ps1 exits 1"               $LASTEXITCODE 1
Check "...saying the task is retired"             ($out -match 'asohav-06-bond-cap-setting is retired') "True"
Check "...before starting any run"                ($out -match '>>> \[') "False"

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"

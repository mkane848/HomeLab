# test-checklist-grading.ps1 - regression guard for `grading: "checklist"`
#
# Why this exists: some real tasks have no hidden tests to decide them. The
# owner's large features (LFCbot's multi-card input and exact printings) and
# the stretch-v06 task (the owner's real V0.6 opener plus replayed go-aheads)
# are rated by a person against a written checklist (docs/roadmap.md ->
# "Real-use tasks"). test-tasks.ps1 runs them like an acceptance task - guard
# rails, the suite, follow-up turns, no test owed - and records the verdict as
# pending: acceptance "MANUAL" plus the checklist's path.
#
# What it does: the real test-tasks.ps1 end to end against a fixture repo with a
# stand-in opencode, for a two-turn checklist task with no acceptance block.
# Checks: both turns run; scope and suite are graded; failsOnOld is SKIP; the
# row goes to real-tasks-summary.tsv (never tasks-summary.tsv) with acceptance
# MANUAL; the run JSON records grading "checklist" and the checklist path; and
# a guard-rail breach is still a FAIL. Exit 1 on any failure.
#
# Usage:  .\tests\test-checklist-grading.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("checklist-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
try {
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $tmp "tests/test-tasks.ps1")
    $repo = Join-Path $tmp "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "notes.md") -Value "rules v0.5"
    'Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    function New-Task([string]$id) {
        [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            grading = "checklist"; checklist = "reports/$id-checklist.md"; scope = "guardrails"
            guardrails = [ordered]@{ maxChangedFiles = 2 }
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
            prompt = "review the new rules and plan the changes"; followUps = @("the plan is good, go ahead")
        }
    }
    @{ tasks = @((New-Task "fx-checklist"), (New-Task "fx-checklist-wide")) } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/manifest.json")
    # Turn 1 writes a plan; the go-ahead turn edits notes.md. fx-checklist-wide
    # also touches three more files, past maxChangedFiles 2.
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
$id = Split-Path -Leaf $dir
$si = [array]::IndexOf($a, '--session')
Add-Content -LiteralPath $env:FIXTURE_CALLS -Value ("{0}|{1}" -f $id, $(if ($si -ge 0) { $a[$si + 1] } else { '' }))
if ($si -lt 0) {
    Set-Content -LiteralPath (Join-Path $dir 'PLAN.md') -Value 'plan'
    '{"type":"tool_use","sessionID":"ses_' + $id + '","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"PLAN.md"},"output":"ok"}}}'
    '{"type":"step_finish","sessionID":"ses_' + $id + '","part":{"reason":"stop","tokens":{"input":100,"output":5,"cache":{"read":0,"write":0}}}}'
    exit 0
}
Set-Content -LiteralPath (Join-Path $dir 'notes.md') -Value 'rules v0.6'
if ($id -eq 'fx-checklist-wide') { foreach ($n in 1..3) { Set-Content -LiteralPath (Join-Path $dir "extra$n.md") -Value 'x' } }
'{"type":"tool_use","sessionID":"ses_' + $id + '","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"notes.md"},"output":"ok"}}}'
'{"type":"step_finish","sessionID":"ses_' + $id + '","part":{"reason":"stop","tokens":{"input":100,"output":5,"cache":{"read":0,"write":0}}}}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $tmp "bin/standin.ps1")
    $bin = Join-Path $tmp "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $env:FIXTURE_CALLS = Join-Path $tmp "calls.txt"
    try {
        $out = & (Join-Path $tmp "tests/test-tasks.ps1") -Task fx-checklist, fx-checklist-wide -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_CALLS -ErrorAction SilentlyContinue
    }
    $results = Join-Path $tmp "tests/results"
    $calls = @(Get-Content -LiteralPath (Join-Path $tmp "calls.txt"))
    $rows = @(if (Test-Path (Join-Path $results "real-tasks-summary.tsv")) { Import-Csv (Join-Path $results "real-tasks-summary.tsv") -Delimiter "`t" })
    function Row([string]$id) { @($rows | Where-Object taskId -eq $id)[0] }
    $j = Get-ChildItem $results -Filter "tasks-fx-checklist-fixture*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "both turns ran, the second in the first's session"  (@($calls | Where-Object { $_ -like 'fx-checklist|*' }) -join ';') "fx-checklist|;fx-checklist|ses_fx-checklist"
    Check "scope and suite graded"                             ("{0}/{1}" -f (Row fx-checklist).scope, (Row fx-checklist).suite) "PASS/PASS"
    Check "acceptance is MANUAL, pending a rating"             (Row fx-checklist).acceptance "MANUAL"
    Check "failsOnOld SKIP: no test owed"                      (Row fx-checklist).failsOnOld "SKIP"
    Check "the output names the checklist"                     (($out -replace '\s+', ' ') -match 'checklist \(manual\).*reports/fx-checklist-checklist\.md') "True"
    Check "run JSON: grading checklist"                        $j.grading "checklist"
    Check "run JSON: the checklist path"                       $j.checklist "reports/fx-checklist-checklist.md"
    Check "run JSON: acceptance MANUAL"                        $j.acceptance.status "MANUAL"
    Check "edits from both turns count"                        (Row fx-checklist).writes 2
    Check "never in tasks-summary.tsv"                         (Test-Path (Join-Path $results "tasks-summary.tsv")) "False"
    Check "a guard-rail breach is still a FAIL"                (Row fx-checklist-wide).scope "FAIL"
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

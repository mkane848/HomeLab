# test-outside-writes.ps1 - regression guard for Get-OutsideWrites in test-tasks.ps1.
#
# Why this exists: the scope gate and the guard rails see only the repo's own
# diff, so a model that writes outside its worktree goes unnoticed. On
# 2026-10-07 a GLM-5.2 run wrote a vitest config to %TEMP%\opencode while
# fighting the test setup. test-tasks.ps1 now reads the transcript's file-tool
# calls and records every write outside the worktree in the run JSON
# (`outsideWrites`), with a WARN. It is not graded.
#
# What it does:
#   1. Pulls the REAL Get-OutsideWrites out of test-tasks.ps1 and runs it on
#      synthetic transcripts: inside and outside paths, absolute and relative,
#      `..` escapes, other casing and slashes, a patch tool's file headers, an
#      errored write, reads and shell commands (never counted), duplicates.
#   2. Runs the REAL test-tasks.ps1 end to end against a fixture repo with a
#      stand-in opencode whose transcript writes once inside and once outside:
#      the run JSON records only the outside one, the console warns, and a
#      clean run records an empty list.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-outside-writes.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq "Get-OutsideWrites" } | Select-Object -First 1
if (-not $fn) { Write-Host "FAIL: Get-OutsideWrites not found in $ScriptPath"; exit 1 }
Invoke-Expression $fn.Extent.Text

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function ToolUse([string]$Tool, $ToolInput, [string]$Status = "completed") {
    return ([pscustomobject]@{ type = "tool_use"; sessionID = "s"; part = [pscustomobject]@{ tool = $Tool; state = [pscustomobject]@{ status = $Status; input = $ToolInput; output = "ok" } } } | ConvertTo-Json -Depth 6 -Compress)
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("outside-writes-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$psExe = (Get-Process -Id $PID).Path
try {
    Write-Host "-- Get-OutsideWrites (real function)"
    $wt = Join-Path $tmp "wt\task-1"
    New-Item -ItemType Directory -Path $wt -Force | Out-Null
    $outside = Join-Path $tmp "elsewhere\vitest.config.ts"
    $sibling = Join-Path $tmp "wt\task-10\x.ts"      # shares the prefix "task-1"
    $patch = "*** Begin Patch`n*** Update File: src/a.ts`n@@`n-x`n+y`n*** Add File: $(Join-Path $tmp 'patched-outside.md')`n+hi`n*** End Patch"
    $lines = @(
        (ToolUse "write" @{ filePath = (Join-Path $wt "src\in.ts"); content = "x" }),
        (ToolUse "edit" @{ filePath = "src/relative.ts"; oldString = "a"; newString = "b" }),
        (ToolUse "edit" @{ filePath = ($wt.ToUpper() + "\SRC\CASE.ts"); oldString = "a"; newString = "b" }),
        (ToolUse "write" @{ filePath = ($wt -replace '\\', '/') + "/fwd.ts"; content = "x" }),
        (ToolUse "write" @{ filePath = $outside; content = "x" }),
        (ToolUse "write" @{ filePath = $outside; content = "again" }),
        (ToolUse "edit" @{ filePath = "..\..\escape.txt"; oldString = "a"; newString = "b" }),
        (ToolUse "write" @{ filePath = $sibling; content = "x" }),
        (ToolUse "patch" @{ patchText = $patch }),
        (ToolUse "write" @{ filePath = (Join-Path $tmp "errored.txt"); content = "x" } "error"),
        (ToolUse "read" @{ filePath = (Join-Path $tmp "read-only.txt") }),
        (ToolUse "bash" @{ command = "echo x > C:\outside-by-shell.txt" }),
        'not json',
        '{"type":"text","part":{"text":"\"tool_use\" mentioned in prose"}}'
    )
    $tf = Join-Path $tmp "t.jsonl"
    [IO.File]::WriteAllText($tf, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding $false))
    $hits = Get-OutsideWrites -Path $tf -Worktree $wt
    $got = @($hits | ForEach-Object { "$($_.tool) " + ($_.path.Substring($tmp.Length).TrimStart('\', '/') -replace '\\', '/') })
    Check "exactly the writes outside the worktree, once each" ($got -join " | ") "write elsewhere/vitest.config.ts | edit escape.txt | write wt/task-10/x.ts | patch patched-outside.md"
    Check "a worktree path with a trailing slash reads the same" ((Get-OutsideWrites -Path $tf -Worktree ($wt + "\")).Count) 4
    Check "no transcript: an empty list, not null"           ((Get-OutsideWrites -Path (Join-Path $tmp "none.jsonl") -Worktree $wt).Count) 0
    $clean = Join-Path $tmp "clean.jsonl"
    [IO.File]::WriteAllText($clean, (ToolUse "edit" @{ filePath = "src/a.ts"; oldString = "a"; newString = "b" }))
    Check "a run that stays inside: empty"                   ((Get-OutsideWrites -Path $clean -Worktree $wt).Count) 0

    Write-Host "-- end to end: the real test-tasks.ps1 with a stand-in opencode"
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    $frepo = Join-Path $e2e "repo"
    git -C $frepo init -q
    git -C $frepo config user.email "t@example.invalid"
    git -C $frepo config user.name "t"
    Set-Content -LiteralPath (Join-Path $frepo "src.txt") -Value "buggy"
    'Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $frepo "check.ps1")
    git -C $frepo add -A
    git -C $frepo commit -q -m base
    $fbase = (git -C $frepo rev-parse HEAD).Trim()
    $task = { param($id) [ordered]@{ id = $id; title = "fx"; repo = $frepo; branch = "bench/$id"; benchBaseCommit = $fbase
        allowFiles = @("src.txt"); srcRevertFiles = @("src.txt"); testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt" } }
    @{ tasks = @((& $task "fx-outside"), (& $task "fx-inside")) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
'{"type":"tool_use","sessionID":"s","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
if ($dir -match 'fx-outside') {
    $p = Join-Path $env:FIXTURE_OUTSIDE 'stray.config.ts'
    Set-Content -LiteralPath $p -Value 'x'
    ([pscustomobject]@{ type = 'tool_use'; sessionID = 's'; part = [pscustomobject]@{ tool = 'write'; state = [pscustomobject]@{ status = 'completed'; input = [pscustomobject]@{ filePath = $p }; output = 'ok' } } } | ConvertTo-Json -Depth 6 -Compress)
}
'{"type":"step_finish","sessionID":"s","part":{"reason":"stop","tokens":{"input":100,"output":5,"cache":{"read":0,"write":0}}}}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $e2e "bin/standin.ps1")
    $bin = Join-Path $e2e "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $outDir = Join-Path $tmp "stray"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $env:FIXTURE_OUTSIDE = $outDir
    try {
        $log = & (Join-Path $e2e "tests/test-tasks.ps1") -Task fx-outside, fx-inside -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_OUTSIDE -ErrorAction SilentlyContinue
    }
    $jo = Get-ChildItem (Join-Path $e2e "tests/results") -Filter "tasks-fx-outside-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    $ji = Get-ChildItem (Join-Path $e2e "tests/results") -Filter "tasks-fx-inside-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "the run JSON records the outside write, and only it" ((@($jo.outsideWrites) | ForEach-Object { "$($_.tool) $(Split-Path -Leaf $_.path)" }) -join " | ") "write stray.config.ts"
    Check "...with its full path"                            (@($jo.outsideWrites)[0].path) (Join-Path $outDir "stray.config.ts")
    Check "the console warns"                                ($log -match 'WARN: 1 write\(s\) outside the worktree') "True"
    Check "it is not graded: the scope gate still passes"    $jo.gates.scope "PASS"
    Check "a clean run records an empty list"                ("{0}|{1}" -f ($null -ne $ji.PSObject.Properties["outsideWrites"]), @($ji.outsideWrites).Count) "True|0"
} finally {
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

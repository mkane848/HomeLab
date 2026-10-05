# test-command-timeout.ps1 - regression guard for -CommandTimeout (Run-NativeTimed)
#
# Why this exists: -CommandTimeout was documented ("seconds per grading command")
# but never enforced. On 2026-10-05 a model's edit put an infinite loop in
# KaneEnabler's signals.ts (`while (re.exec(...))` on a regex without the g
# flag); vitest spun for 2 h 20 min and the batch behind it stood still until a
# person killed it. Grading commands (tests, typecheck) now run through
# Run-NativeTimed, which ends the whole process tree at the limit.
#
# What it does: pulls the REAL ConvertTo-WindowsArgument, Run-Native and
# Run-NativeTimed out of test-tasks.ps1 and checks argument quoting (direct and
# through a .cmd shim), exit codes, stderr, a large output (no pipe deadlock),
# and a hang with a grandchild (both ended, within the limit); then runs the real
# test-tasks.ps1 end to end with a stand-in opencode whose edit makes the
# fixture's tests loop forever: the suite must FAIL as timed out, the run must
# finish and write its row, and nothing may be left running. Needs node on PATH.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-command-timeout.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
foreach ($name in "ConvertTo-WindowsArgument", "Run-Native", "Run-NativeTimed") {
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host "FAIL: node is not on PATH"; exit 1 }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("cmdtimeout-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$psExe = (Get-Process -Id $PID).Path
try {
    Write-Host "-- arguments arrive as sent"
    $argv = Join-Path $tmp "argv.js"
    Set-Content -LiteralPath $argv -Value 'console.log(JSON.stringify(process.argv.slice(2)))'
    $sent = @("plain", "with space", 'quote"inside', 'trail\', 'dir\\"q', "", "a&b", "C:\Program Files\x")
    $r = Run-NativeTimed "node" (@($argv) + $sent) $tmp 30
    Check "direct: every argument intact" (@(($r.Output -join '') | ConvertFrom-Json | ForEach-Object { $_ }) -join '|') ($sent -join '|')
    Set-Content -LiteralPath (Join-Path $tmp "argv.cmd") -Value "@node `"%~dp0argv.js`" %*" -Encoding ascii
    $env:PATH = "$tmp;$env:PATH"
    $r = Run-NativeTimed "argv" @("with space", "a&b", "plain") $tmp 30
    Check "through a .cmd shim (cmd /s /c)" (@(($r.Output -join '') | ConvertFrom-Json | ForEach-Object { $_ }) -join '|') "with space|a&b|plain"

    Write-Host "-- exit codes, stderr, large output"
    $r = Run-NativeTimed $psExe @("-NoProfile", "-Command", "Write-Output out; [Console]::Error.WriteLine('err'); exit 7") $tmp 60
    Check "exit code passes through" $r.ExitCode 7
    Check "...not a timeout" $r.TimedOut $false
    Check "stdout and stderr both kept" ((@($r.Output) -contains "out") -and (@($r.Output) -contains "err")) "True"
    $r = Run-NativeTimed "node" @("-e", "for (let i = 0; i < 40000; i++) { console.log('x'.repeat(60)); console.error('y'.repeat(60)) }") $tmp 60
    Check "large stdout+stderr (~5 MB) completes" @($r.Output).Count 80000

    Write-Host "-- stdin is empty and closed (inherited, a job's channel hung a pwsh -File child)"
    $r = Run-NativeTimed $psExe @("-NoProfile", "-Command", "`$x = [Console]::In.ReadToEnd(); 'read ' + `$x.Length") $tmp 20
    # PS 7: nothing. 5.1: a 3-byte UTF-8 byte-order mark its .NET writes on creation. Never a wait.
    Check "a child reading stdin to the end reaches its end at once" ((($r.Output -join ' ').Trim()) -match $(if ($PSVersionTable.PSVersion.Major -ge 6) { '^read 0$' } else { '^read [03]$' })) "True"
    Check "...not a timeout" $r.TimedOut $false

    Write-Host "-- a hang with a grandchild"
    $pidFile = Join-Path $tmp "grandchild.pid"
    $hang = "`$g = Start-Process -PassThru -WindowStyle Hidden '$psExe' -ArgumentList '-NoProfile','-Command','Start-Sleep 120'; Set-Content '$pidFile' `$g.Id; Start-Sleep 120"
    $t0 = Get-Date
    $r = Run-NativeTimed $psExe @("-NoProfile", "-Command", $hang) $tmp 4
    $took = ((Get-Date) - $t0).TotalSeconds
    Check "timed out" $r.TimedOut $true
    Check "...exit 124" $r.ExitCode 124
    Check "...says so in the output" (($r.Output -join "`n") -match 'timed out after 4 s \(-CommandTimeout\)') "True"
    Check "...returned soon after the limit (< 30 s)" ($took -lt 30) "True"
    $g = if (Test-Path $pidFile) { [int](Get-Content $pidFile) } else { 0 }
    Check "...the grandchild was started" ($g -gt 0) "True"
    Check "...and ended with the tree" ([bool](Get-Process -Id $g -ErrorAction SilentlyContinue)) "False"

    Write-Host "-- end to end: a model edit that makes the tests loop forever"
    foreach ($d in @("e2e/tests/tasks", "e2e/bin", "e2e/repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    $e2e = Join-Path $tmp "e2e"
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    $repo = Join-Path $e2e "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "fine"
    @'
if ((Get-Content -LiteralPath src.txt -Raw).Trim() -eq 'loop') { while ($true) { } }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-hang"; title = "fx"; repo = $repo; branch = "bench/fx"; benchBaseCommit = $base
        allowFiles = @("src.txt"); srcRevertFiles = @("src.txt"); testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "change src.txt" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'loop'
'{"type":"tool_use","sessionID":"s","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
'{"type":"step_finish","sessionID":"s","part":{"reason":"stop","tokens":{"input":100,"output":5,"cache":{"read":0,"write":0}}}}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $e2e "bin/standin.ps1")
    $bin = Join-Path $e2e "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $t0 = Get-Date
    try {
        $out = & (Join-Path $e2e "tests/test-tasks.ps1") -Task fx-hang -Model fixture/m -SkipInstall -RunTimeout 120 -CommandTimeout 5 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
    }
    $took = ((Get-Date) - $t0).TotalSeconds
    $rows = @(Import-Csv (Join-Path $e2e "tests/results/tasks-summary.tsv") -Delimiter "`t")
    Check "the run finished (< 120 s)" ($took -lt 120) "True"
    Check "...suite FAIL" $rows[0].suite "FAIL"
    Check "...reported as a timeout" ($out -match 'suite timed out after 5 s \(-CommandTimeout\)') "True"
    Check "...failsOnOld not measured" $rows[0].failsOnOld "SKIP"
    $left = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains("check.ps1") -and $_.CommandLine.Contains("fx-hang") -or ($_.CommandLine -and $_.CommandLine.Contains($e2e) -and $_.CommandLine -match 'check\.ps1') })
    Check "...nothing left running" $left.Count 0
} finally {
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

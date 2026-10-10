# test-prompt-truncation.ps1 - regression guard for the prompt-truncation check
#
# Why this exists: when a request is longer than the served num_ctx, Ollama
# logs "truncating input prompt" and drops everything but the first 4 tokens
# and the tail of the window - the system prompt, tool schemas and task first.
# The model answers what is left in prose and the writes gate filed that as
# liar mode. On 2026-10-03 asohav-05/06 did this on all four runs (a 280 KB
# CLAUDE.md at their pins; prompt=83886 against qwen3.6's 65,536). test-tasks.ps1
# now reads the local Ollama log for the run's time window
# (Get-OllamaPromptTruncation) and turns a hit into a _TRUNCATED_ infra FAIL.
#
# What it does: pulls the REAL function out of test-tasks.ps1 and runs it on
# synthetic logs (window edges, other warnings, a rotated file, a file held
# open for writing, a missing directory). Then, on a machine whose Ollama log
# still has 2026-10-03, replays the batch's real windows: the asohav-05 run
# must hit, the kane-09 run must not. Exit 1 on any failure.
#
# Usage:  .\tests\test-prompt-truncation.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) |
    Where-Object { $_.Name -eq "Get-OllamaPromptTruncation" } | Select-Object -First 1
if (-not $fn) { Write-Host "FAIL: Get-OllamaPromptTruncation not found in $ScriptPath"; exit 2 }
Invoke-Expression $fn.Extent.Text

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function T([string]$s) { [DateTimeOffset]::Parse($s) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("trunc-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmp | Out-Null
$hit1 = 'time=2026-10-03T16:41:00.123-04:00 level=WARN source=llama_server.go:318 msg="truncating input prompt" limit=32770 prompt=83886 keep=4 new=32770'
$hit2 = 'time=2026-10-03T17:29:43.500-04:00 level=WARN source=llama_server.go:318 msg="truncating input prompt" limit=32770 prompt=83122 keep=4 new=32770'
Set-Content (Join-Path $tmp "server.log") @(
    'time=2026-10-03T16:40:00.000-04:00 level=INFO source=sched.go:556 msg="loading model"',
    $hit1,
    'time=2026-10-03T16:42:00.000-04:00 level=WARN source=server.go:1 msg="something else entirely"',
    $hit2
)
try {
    Write-Host "-- synthetic logs"
    $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since (T "2026-10-03T16:40:30-04:00") -Until (T "2026-10-03T16:45:00-04:00"))
    Check "one hit inside the window"            $r.Count 1
    Check "it is the truncation line"            ($r[0] -eq $hit1) "True"
    $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since (T "2026-10-03T16:41:01-04:00") -Until (T "2026-10-03T17:29:00-04:00"))
    Check "none between the two hits"            $r.Count 0
    $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since (T "2026-10-03T16:00:00-04:00") -Until (T "2026-10-03T18:00:00-04:00"))
    Check "both in a wide window"                $r.Count 2
    $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since (T "2026-10-03T20:41:00Z") -Until (T "2026-10-03T20:41:01Z"))
    Check "time zones compare as instants (UTC window)" $r.Count 1

    # A restart mid-run: the earlier part of the run sits in server-1.log.
    Set-Content (Join-Path $tmp "server-1.log") 'time=2026-10-03T18:10:00.000-04:00 level=WARN source=llama_server.go:318 msg="truncating input prompt" limit=8194 prompt=20000 keep=4 new=8194'
    $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since (T "2026-10-03T18:00:00-04:00") -Until (T "2026-10-03T18:20:00-04:00"))
    Check "a rotated log written during the run is read" $r.Count 1
    (Get-Item (Join-Path $tmp "server-1.log")).LastWriteTime = (Get-Date "2026-10-01")
    $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since ([DateTimeOffset]::Now.AddMinutes(-5)) -Until ([DateTimeOffset]::Now))
    Check "a rotated log last written before the run is skipped" $r.Count 0

    # server.log's LastWriteTime goes stale while Ollama holds it open: it must be read anyway.
    (Get-Item (Join-Path $tmp "server.log")).LastWriteTime = (Get-Date "2026-09-01")
    $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since (T "2026-10-03T16:40:30-04:00") -Until (T "2026-10-03T16:45:00-04:00"))
    Check "server.log is read even with a stale timestamp" $r.Count 1

    # Ollama writing at the same time: the file is open for write by another handle.
    $writer = New-Object System.IO.FileStream((Join-Path $tmp "server.log"), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        $r = @(Get-OllamaPromptTruncation -LogDir $tmp -Since (T "2026-10-03T16:40:30-04:00") -Until (T "2026-10-03T16:45:00-04:00"))
        Check "readable while another process is writing it" $r.Count 1
    } finally { $writer.Dispose() }

    $r = @(Get-OllamaPromptTruncation -LogDir (Join-Path $tmp "nope") -Since (T "2026-10-03T00:00:00Z") -Until (T "2026-10-04T00:00:00Z"))
    Check "a missing log directory is no hits, not an error" $r.Count 0

    Write-Host "-- end to end: the real test-tasks.ps1, a fixture repo, a stand-in opencode that logs a truncation"
    $psExe = (Get-Process -Id $PID).Path
    $fx = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo", "ollama")) { New-Item -ItemType Directory -Path (Join-Path $fx $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $fx "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $fx "tests") -Recurse -Force
    $repo = Join-Path $fx "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
if ((Test-Path test.txt) -and $src -ne 'fixed') { Write-Host "Tests  1 failed (1)"; exit 1 }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    function New-FixtureTask([string]$id) {
        [ordered]@{
            id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
            baselineExpect = @{ testsTotal = 1; testsPass = 1 }
            allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1")
            installFlags = @(); prompt = "fix it"
        }
    }
    @{ tasks = @((New-FixtureTask "fx-truncated"), (New-FixtureTask "fx-clean")) } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $fx "tests/tasks/manifest.json")
    # Stand-in opencode: makes the change; for fx-truncated it also appends an
    # Ollama truncation warning stamped "now" to the fixture log, as Ollama would.
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    if ((Split-Path -Leaf $dir) -eq 'fx-truncated') {
        $now = [DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz")
        Add-Content -LiteralPath (Join-Path $env:FIXTURE_LOGDIR 'server.log') -Value "time=$now level=WARN source=llama_server.go:318 msg=`"truncating input prompt`" limit=32770 prompt=83886 keep=4 new=32770"
    }
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value 'a test'
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $fx "bin/standin.ps1")
    $bin = Join-Path $fx "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    Set-Content -LiteralPath (Join-Path $fx "ollama/server.log") -Value 'time=2026-10-03T16:41:00.123-04:00 level=WARN source=llama_server.go:318 msg="truncating input prompt" limit=32770 prompt=83886 keep=4 new=32770'
    $origPath = $env:PATH
    $env:FIXTURE_LOGDIR = Join-Path $fx "ollama"
    $env:PATH = "$bin;$env:PATH"
    try {
        $output = & (Join-Path $fx "tests/test-tasks.ps1") -Task fx-truncated, fx-clean -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir $env:FIXTURE_LOGDIR *>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_LOGDIR -ErrorAction SilentlyContinue
    }
    $results = Join-Path $fx "tests/results"
    Check "the harness exits 1 (a truncated run is a FAIL)"        $exitCode 1
    Check "the output says Ollama truncated the prompt"           ($output -match 'Ollama truncated the prompt 1 time\(s\)') "True"
    Check "the truncated run's transcript is kept as _TRUNCATED_" @(Get-ChildItem $results -Filter "tasks-fx-truncated-*_TRUNCATED_*.jsonl").Count 1
    Check "the truncated run has no graded JSON"                  @(Get-ChildItem $results -Filter "tasks-fx-truncated-*.json").Count 0
    $rows = @(if (Test-Path (Join-Path $results "tasks-summary.tsv")) { Import-Csv (Join-Path $results "tasks-summary.tsv") -Delimiter "`t" })
    Check "no summary row for the truncated run"                  @($rows | Where-Object taskId -eq "fx-truncated").Count 0
    Check "the clean run is graded (one summary row)"             @($rows | Where-Object taskId -eq "fx-clean").Count 1
    Check "an old truncation in the log is not blamed on the clean run" (@($rows | Where-Object taskId -eq "fx-clean")[0].failsOnOld) "PASS"
    $cleanJson = Get-ChildItem $results -Filter "tasks-fx-clean-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "the clean run's JSON records the check"                ($cleanJson.promptTruncation -like "checked Ollama server.log in *- none during the run") "True"
    Check "a non-Ollama provider records engine 'unknown', not ollama" $cleanJson.servingEngine.name "unknown"
    Check "...and no borrowed Ollama version"                     ($null -eq $cleanJson.servingEngine.version) "True"
    Check "...and the provider it ran through"                    $cleanJson.servingEngine.provider "fixture"

    Write-Host "-- the real 2026-10-03 batch (this machine's Ollama log, if it still has that day)"
    $real = Join-Path $env:LOCALAPPDATA "Ollama"
    $has = (Test-Path $real) -and (@(Get-ChildItem $real -Filter "server*.log" -File | Select-String -Pattern '^time=2026-10-03T16:4' -List).Count -gt 0)
    if (-not $has) {
        Write-Host "SKIP no 2026-10-03 lines in $real"
    } else {
        $r = @(Get-OllamaPromptTruncation -LogDir $real -Since (T "2026-10-03T16:40:45-04:00") -Until (T "2026-10-03T16:45:34-04:00"))
        Check "asohav-05 run (16:40:45-16:45:34) hits" ($r.Count -ge 1) "True"
        Check "with the 83886-token prompt" ($r[0] -match 'prompt=83886') "True"
        $r = @(Get-OllamaPromptTruncation -LogDir $real -Since (T "2026-10-03T15:56:08-04:00") -Until (T "2026-10-03T16:00:03-04:00"))
        Check "kane-09 run (15:56:08-16:00:03) does not" $r.Count 0
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"

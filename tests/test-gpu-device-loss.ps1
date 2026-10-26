# protects: GPU device-loss detection from the Ollama log (gpuResets)
# run-after: How a run's outcome is classified or an engine log is read
# test-gpu-device-loss.ps1 - regression guard for the GPU device-loss check
#
# Why this exists: on 2026-10-24 at 20:53 the desktop's AMD driver reset in the
# middle of a sweep run. Ollama's runner logged "ggml_vulkan: device lost on
# Vulkan0" and crashed, the request got a 500, Ollama reloaded the model in
# 39 s, opencode retried and the run passed in 1,968 s. Nothing in the
# transcript or the run JSON showed it. test-tasks.ps1 now reads the local
# Ollama log for the run's window (Get-OllamaDeviceLoss, through the adapter's
# Get-EngineDeviceLoss), records `gpuResets` in the run JSON and warns. It
# never grades: the outcome stands, the run's time does not compare.
#
# What it does: loads the REAL function from tests/engines/ollama.ps1 and runs
# it on synthetic logs shaped like the 2026-10-24 excerpt (the runner's line
# has no timestamp; the failed request's [GIN] 500 line after it dates it),
# window edges, a time= line as the next stamp, an event at the end of a file
# still being written, a file with no stamp, a rotated file, a missing
# directory. Then the real test-tasks.ps1 end to end with a stand-in opencode
# that appends a device loss to a fixture log: a WARN, the run still graded
# with a summary row, `gpuResets` recorded; a clean run records the check and
# no event. Then the llama.cpp adapter's "not checked". Finally, on a machine
# whose Ollama log still has 2026-10-24, the real event: the devstral real-01
# window hits, the next run's does not. Exit 1 on any failure.
#
# Usage:  .\tests\test-gpu-device-loss.ps1 [-ScriptPath <a test-tasks.ps1>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$EnginePath = (Join-Path $PSScriptRoot "engines\ollama.ps1")
)

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($EnginePath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) |
    Where-Object { $_.Name -eq "Get-OllamaDeviceLoss" } | Select-Object -First 1
if (-not $fn) { Write-Host "FAIL: Get-OllamaDeviceLoss not found in $EnginePath"; exit 2 }
Invoke-Expression $fn.Extent.Text

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
# [GIN] lines are local time, so the synthetic windows are local too.
function L([string]$s) { [DateTimeOffset][datetime]::ParseExact($s, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("devlost-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmp | Out-Null
# The 2026-10-24 shape: a 200 before, runner lines with no stamp, the loss, the 500.
Set-Content (Join-Path $tmp "server.log") @(
    '[GIN] 2026/10/24 - 20:53:31 | 200 |   20.6127087s |             ::1 | POST     "/v1/chat/completions"',
    'slot   operator(): id  0 | task 79 | new prompt, n_ctx_slot = 32768, n_keep = 4, task.n_tokens = 13169',
    'ggml_vulkan: device fault on Vulkan0: No fault detected',
    'ggml_vulkan: device lost on Vulkan0',
    '[GIN] 2026/10/24 - 20:53:40 | 500 |    8.6882714s |             ::1 | POST     "/v1/chat/completions"',
    'time=2026-10-24T20:53:44.069-04:00 level=INFO source=sched.go:1341 msg="updated VRAM based on existing loaded models"',
    '[GIN] 2026/10/24 - 21:10:00 | 200 |    1.0s |             ::1 | POST     "/v1/chat/completions"'
)
try {
    Write-Host "-- synthetic logs"
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 20:30:00") -Until (L "2026-10-24 21:00:00"))
    Check "one event inside the window"                      $r.Count 1
    Check "it is the device-lost line, not the fault line"   ($r[0] -like "*ggml_vulkan: device lost on Vulkan0") "True"
    Check "dated by the 500 after it (20:53:40)"             ($r[0] -like "2026-10-24T20:53:40*") "True"
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 20:53:35") -Until (L "2026-10-24 20:55:00"))
    Check "a run that began after the 200 before it still sees it" $r.Count 1
    # [GIN] stamps are whole seconds: a run that began at 20:53:40.6 still sees a loss stamped 20:53:40.
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since ((L "2026-10-24 20:53:40").AddMilliseconds(600)) -Until (L "2026-10-24 20:55:00"))
    Check "a loss in the run's first second is not lost to rounding" $r.Count 1
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 20:53:41") -Until (L "2026-10-24 21:20:00"))
    Check "a run that began after it does not"               $r.Count 0
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 20:00:00") -Until (L "2026-10-24 20:53:39"))
    Check "a run that ended before it does not"              $r.Count 0

    # The next stamp is a time= line (Ollama's own logger), in another offset.
    Set-Content (Join-Path $tmp "server.log") @(
        'ggml_vulkan: device lost on Vulkan0',
        'time=2026-10-25T00:53:44.000Z level=INFO source=sched.go:556 msg="evicting"'
    )
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since ([DateTimeOffset]::Parse("2026-10-25T00:50:00Z")) -Until ([DateTimeOffset]::Parse("2026-10-25T00:55:00Z")))
    Check "a time= line after it dates it (as an instant)"   $r.Count 1
    Check "...with that line's time"                         ($r[0] -like "2026-10-25T00:53:44*") "True"

    # Ollama still writing: the loss is the last line; the stamp before it dates it.
    Set-Content (Join-Path $tmp "server.log") @(
        '[GIN] 2026/10/24 - 22:00:00 | 200 |    1.0s |             ::1 | POST     "/v1/chat/completions"',
        'ggml_vulkan: device lost on Vulkan0'
    )
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 21:59:00") -Until (L "2026-10-24 22:05:00"))
    Check "a loss on the last line is dated by the stamp before it" $r.Count 1

    Set-Content (Join-Path $tmp "server.log") 'ggml_vulkan: device lost on Vulkan0'
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since ([DateTimeOffset]::MinValue) -Until ([DateTimeOffset]::MaxValue))
    Check "a file with no stamp at all is skipped, not an error" $r.Count 0

    # A restart mid-run: the earlier part of the run sits in server-1.log.
    Set-Content (Join-Path $tmp "server.log") '[GIN] 2026/10/24 - 23:00:00 | 200 |    1.0s |             ::1 | POST     "/v1/chat/completions"'
    Set-Content (Join-Path $tmp "server-1.log") @('ggml_vulkan: device lost on Vulkan0', '[GIN] 2026/10/24 - 22:30:00 | 500 |    1.0s |             ::1 | POST     "/v1/chat/completions"')
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 22:00:00") -Until (L "2026-10-24 23:30:00"))
    Check "a rotated log written during the run is read"     $r.Count 1
    (Get-Item (Join-Path $tmp "server-1.log")).LastWriteTime = (Get-Date "2026-10-01")
    $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 22:00:00") -Until (L "2026-10-24 23:30:00"))
    Check "a rotated log last written before the run is skipped" $r.Count 0

    $writer = New-Object System.IO.FileStream((Join-Path $tmp "server-1.log"), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try {
        (Get-Item (Join-Path $tmp "server-1.log")).LastWriteTime = (Get-Date)
        $r = @(Get-OllamaDeviceLoss -LogDir $tmp -Since (L "2026-10-24 22:00:00") -Until (L "2026-10-24 23:30:00"))
        Check "readable while another process is writing it" $r.Count 1
    } finally { $writer.Dispose() }

    $r = @(Get-OllamaDeviceLoss -LogDir (Join-Path $tmp "nope") -Since ([DateTimeOffset]::MinValue) -Until ([DateTimeOffset]::MaxValue))
    Check "a missing log directory is no events, not an error" $r.Count 0

    Write-Host "-- end to end: the real test-tasks.ps1, a fixture repo, a stand-in opencode that logs a device loss"
    $psExe = (Get-Process -Id $PID).Path
    $fx = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo", "ollama")) { New-Item -ItemType Directory -Path (Join-Path $fx $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $fx "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $fx "tests") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $fx "tests") -Recurse -Force
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
    @{ tasks = @((New-FixtureTask "fx-reset"), (New-FixtureTask "fx-clean")) } | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $fx "tests/tasks/manifest.json")
    # Stand-in opencode: makes the change; for fx-reset it also appends the
    # runner's device-lost line and the failed request's 500, stamped "now".
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    if ((Split-Path -Leaf $dir) -eq 'fx-reset') {
        $now = (Get-Date).ToString("yyyy/MM/dd - HH:mm:ss")
        Add-Content -LiteralPath (Join-Path $env:FIXTURE_LOGDIR 'server.log') -Value @('ggml_vulkan: device lost on Vulkan0', "[GIN] $now | 500 |    8.6s |             ::1 | POST     `"/v1/chat/completions`"")
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
    # An old loss in the log must not be blamed on either run.
    Set-Content -LiteralPath (Join-Path $fx "ollama/server.log") -Value @('ggml_vulkan: device lost on Vulkan0', '[GIN] 2026/10/24 - 20:53:40 | 500 |    8.6s |             ::1 | POST     "/v1/chat/completions"')
    $origPath = $env:PATH
    $env:FIXTURE_LOGDIR = Join-Path $fx "ollama"
    $env:PATH = "$bin;$env:PATH"
    try {
        $output = & (Join-Path $fx "tests/test-tasks.ps1") -Task fx-reset, fx-clean -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir $env:FIXTURE_LOGDIR *>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_LOGDIR -ErrorAction SilentlyContinue
    }
    $results = Join-Path $fx "tests/results"
    Check "the harness exits 0 (a reset is a WARN, not a FAIL)"  $exitCode 0
    Check "the output warns that the GPU device was lost"        ($output -match '\[WARN\] gpu device') "True"
    Check "...naming one loss"                                   ($output -match 'the GPU device was lost 1 time\(s\) during the run') "True"
    $rows = @(if (Test-Path (Join-Path $results "tasks-summary.tsv")) { Import-Csv (Join-Path $results "tasks-summary.tsv") -Delimiter "`t" })
    Check "the reset run is still graded (one summary row)"     @($rows | Where-Object taskId -eq "fx-reset").Count 1
    Check "the clean run is graded (one summary row)"           @($rows | Where-Object taskId -eq "fx-clean").Count 1
    $resetJson = Get-ChildItem $results -Filter "tasks-fx-reset-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    $cleanJson = Get-ChildItem $results -Filter "tasks-fx-clean-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    # Where-Object: @($null).Count is 1, so a JSON without the field would pass.
    Check "the reset run's JSON records the loss"               @($resetJson.gpuResets.events | Where-Object { $_ -like "*device lost*" }).Count 1
    Check "...as checked"                                        $resetJson.gpuResets.checked "True"
    Check "the clean run records the check and no event"         ("{0} {1}" -f $cleanJson.gpuResets.checked, @($cleanJson.gpuResets.events).Count) "True 0"
    Check "...with a note naming the log it read"               ($cleanJson.gpuResets.note -like "checked Ollama server.log in *") "True"

    Write-Host "-- the llama.cpp adapter: its log is on the server"
    $lr = & { . (Join-Path $PSScriptRoot "engines\llamacpp.ps1"); Get-EngineDeviceLoss -Setup $null -Since ([DateTimeOffset]::Now) -Until ([DateTimeOffset]::Now) }
    Check "llama.cpp records not checked"                        ("{0} {1}" -f $lr.Checked, ($lr.Note -like "not checked*")) "False True"

    Write-Host "-- the real 2026-10-24 event (this machine's Ollama log, if it still has that day)"
    $real = Join-Path $env:LOCALAPPDATA "Ollama"
    $has = (Test-Path $real) -and (@(Get-ChildItem $real -Filter "server*.log" -File | Select-String -Pattern '^\[GIN\] 2026/10/24 - 20:53:40' -List).Count -gt 0)
    if (-not $has) {
        Write-Host "SKIP no 2026-10-24 20:53 lines in $real"
    } else {
        $r = @(Get-OllamaDeviceLoss -LogDir $real -Since (L "2026-10-24 20:30:04") -Until (L "2026-10-24 21:03:44"))
        Check "devstral real-01 (20:30:04-21:03:44) hits" $r.Count 1
        $r = @(Get-OllamaDeviceLoss -LogDir $real -Since (L "2026-10-24 21:03:44") -Until (L "2026-10-24 21:07:44"))
        Check "devstral real-02 (21:03:44-21:07:44) does not" $r.Count 0
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"

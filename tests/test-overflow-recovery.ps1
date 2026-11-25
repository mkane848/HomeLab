# protects: Get-OverflowRecovery: recovered llama.cpp context overflows; adapter-reported prompt loss (_TRUNCATED_) and GPU device loss (gpuResets)
# run-after: How a run's exit is classified or an engine adapter's log check changes
# test-overflow-recovery.ps1 - regression guard for runs that recovered from an
# explicit context overflow (Get-OverflowRecovery, Resolve-RecoveredOverflow in
# test-tasks.ps1)
#
# Why this exists: llama-server refuses a request longer than its context with
# HTTP 400 ("exceeds the available context size"). opencode 1.18.34 classifies it
# as ContextOverflowError, compacts and carries on, but `opencode run` still exits 1
# at the end. In the llama.cpp trial's step 6 C2 run (2026-10-13, wp-2b) that was 14
# overflows, then an edit, green tests and a closing summary, and the harness filed
# it as _INFRA_ with no row, because any non-zero exit was infrastructure. Such a run
# reached the model and finished; test-tasks.ps1 now grades it and records
# `overflowRecovery` in the run JSON. Every other non-zero exit stays infrastructure.
#
# What it does:
#   1. the REAL functions on synthetic transcripts, one per edge;
#   2. the real C2 transcript, when this machine has the private results;
#   3. the REAL test-tasks.ps1 end to end against a fixture repo with a stand-in
#      opencode: a recovered run (graded, row, overflowRecovery, a context WARN
#      that names the explicit refusals and no silent drop), an overflow the
#      session never finished after (_CTXEXCEEDED_, says so; tests/test-context-exceeded.ps1), another error (_INFRA_), and a
#      clean run (no overflowRecovery);
#   4. a control: the same run with the hook removed must leave the recovered run
#      ungraded, or this guard is not testing the hook;
#   5. the outcomes an engine adapter reports from its own log (moved here from
#      test-prompt-truncation.ps1 and test-gpu-device-loss.ps1 when Ollama, whose
#      server.log fed both, was removed on 2026-11-21). llama.cpp's adapter has
#      neither (prompt loss "not applicable", device loss "not checked"), and the
#      clean run in 3 records that. The harness paths stay engine-neutral, so a
#      fixture adapter (the real llamacpp.ps1 with three functions overridden to
#      read a fixture log) drives them: a silently cut prompt is a _TRUNCATED_
#      FAIL with no row; a GPU device loss is a WARN, the run still graded and
#      `gpuResets` recorded; an old event in the log is blamed on no run.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-overflow-recovery.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }

$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")   # Check <name> <actual> <expected>: a PASS/FAIL line, failures counted in $script:fail

# --- 1. the real functions ------------------------------------------------------
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($name in "Get-OverflowRecovery", "Resolve-RecoveredOverflow") {
    $fn = $fns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL $name not found in $ScriptPath"; exit 1 }
    Invoke-Expression $fn.Extent.Text
}
. (Join-Path $PSScriptRoot "agents\opencode.ps1")

$Start    = '{"type":"step_start","part":{"type":"step-start"}}'
$Stop     = '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":50}}}'
$ToolStep = '{"type":"step_finish","part":{"reason":"tool-calls","tokens":{"output":50}}}'
$Read     = '{"type":"tool_use","part":{"tool":"read","state":{"status":"completed","input":{"filePath":"a.ts"}}}}'
$Text     = '{"type":"text","part":{"text":"Done: implemented it, tests pass."}}'
$Overflow = '{"type":"error","sessionID":"s1","error":{"name":"ContextOverflowError","data":{"message":"request (69574 tokens) exceeds the available context size (65536 tokens), try increasing it"}}}'
$ApiError = '{"type":"error","sessionID":"s1","error":{"name":"APIError","data":{"message":"Cannot connect to API"}}}'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("overflow-rec-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
function Transcript([string]$name, [string[]]$lines) { $p = Join-Path $tmp "$name.jsonl"; Set-Content -LiteralPath $p -Value $lines; $p }

try {
    Write-Host "-- Get-OverflowRecovery"
    $r = Get-OverflowRecovery -Path (Transcript "recovered" @($Start, $Read, $ToolStep, $Overflow, $Start, $Text, $Stop, $Overflow, $Start, $Read, $ToolStep, $Start, $Text, $Stop))
    Check "two overflows, then a step that stops: recovered"            $r.Recovered "True"
    Check "...counts both overflows"                                   $r.OverflowErrors 2
    $r = Get-OverflowRecovery -Path (Transcript "dead" @($Start, $Read, $ToolStep, $Overflow))
    Check "an overflow as the last event: not recovered"               $r.Recovered "False"
    $r = Get-OverflowRecovery -Path (Transcript "stop-before" @($Start, $Text, $Stop, $Overflow))
    Check "a stop BEFORE the overflow only: not recovered"             $r.Recovered "False"
    $r = Get-OverflowRecovery -Path (Transcript "toolcalls-last" @($Overflow, $Start, $Read, $ToolStep))
    Check "last step after it ended on tool-calls: not recovered"      $r.Recovered "False"
    $r = Get-OverflowRecovery -Path (Transcript "mixed" @($Overflow, $Start, $Text, $Stop, $ApiError, $Start, $Text, $Stop))
    Check "an overflow plus another error: not recovered"              $r.Recovered "False"
    Check "...counts the other error"                                  $r.OtherErrors 1
    $r = Get-OverflowRecovery -Path (Transcript "apierror" @($ApiError))
    Check "an unreachable provider: not recovered"                     $r.Recovered "False"
    $r = Get-OverflowRecovery -Path (Transcript "clean" @($Start, $Text, $Stop))
    Check "no errors at all: not recovered (nothing to recover from)"  $r.Recovered "False"
    Check "...and no overflows counted"                                $r.OverflowErrors 0

    Write-Host "-- Resolve-RecoveredOverflow"
    $rec = Transcript "rec2" @($Overflow, $Start, $Text, $Stop)
    $script:OverflowExitsLifted = 0
    $run = Resolve-RecoveredOverflow ([pscustomobject]@{ ExitCode = 1; TranscriptPath = $rec }) 6>$null
    Check "exit 1 after a recovered overflow becomes 0"                $run.ExitCode 0
    Check "...and is counted"                                          $script:OverflowExitsLifted 1
    $run = Resolve-RecoveredOverflow ([pscustomobject]@{ ExitCode = -1; TranscriptPath = $rec }) 6>$null
    Check "a timeout (-1) is left alone, recovered or not"             $run.ExitCode -1
    $run = Resolve-RecoveredOverflow ([pscustomobject]@{ ExitCode = 1; TranscriptPath = (Join-Path $tmp "dead.jsonl") }) 6>$null
    Check "exit 1 that did not recover stays 1"                        $run.ExitCode 1
    $run = Resolve-RecoveredOverflow ([pscustomobject]@{ ExitCode = 0; TranscriptPath = $rec }) 6>$null
    Check "exit 0 is left alone"                                       $run.ExitCode 0
    Check "...and only the lifted exit was counted"                    $script:OverflowExitsLifted 1

    # --- 2. the real C2 transcript (private results; skipped elsewhere) -----------
    $c2 = Get-ChildItem -Path "M:\Projects\HomeLab-private\results\llamacpp-c2" -Filter "tasks-wp-2b-llamacpp-server_*_INFRA_20261013-181119.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c2) {
        Write-Host "-- the real C2 run (wp-2b on llama-server, 2026-10-13)"
        $r = Get-OverflowRecovery -Path $c2.FullName
        Check "recovered"                                              $r.Recovered "True"
        Check "14 overflows"                                           $r.OverflowErrors 14
        Check "no other errors"                                        $r.OtherErrors 0
    } else {
        Write-Host "SKIP the real C2 transcript (not on this machine)"
    }

    # --- 3. and 4. the real harness, end to end -----------------------------------
    function Invoke-Harness([string]$harnessPath, [string]$root, [string[]]$TaskIds = @("fx-recovered", "fx-dead", "fx-other", "fx-clean"), [string]$EngineOverride = "") {
        foreach ($d in @("tests/tasks", "bin", "repo", "engine-log")) { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
        Copy-Item -LiteralPath $harnessPath -Destination (Join-Path $root "tests/test-tasks.ps1")
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $root "tests") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $root "tests") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "checks") -Destination (Join-Path $root "tests") -Recurse -Force
        # The fixture's copy of the adapter only: later definitions win when it is dot-sourced.
        if ($EngineOverride) { Add-Content -LiteralPath (Join-Path $root "tests/engines/llamacpp.ps1") -Value $EngineOverride }
        # Events from before the run, which no run may be blamed for.
        Set-Content -LiteralPath (Join-Path $root "engine-log/engine.log") -Value @("2026-10-03T16:41:00.0000000-04:00 truncated prompt=83886 limit=32770", "2026-10-24T20:53:40.0000000-04:00 device lost on Vulkan0")
        $repo = Join-Path $root "repo"
        git -C $repo init -q
        git -C $repo config user.email "t@example.invalid"
        git -C $repo config user.name "t"
        Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
        @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
$test = if (Test-Path test.txt) { (Get-Content -LiteralPath test.txt -Raw).Trim() } else { "" }
if ($test -and $src -ne 'fixed') { Write-Host "Tests  1 failed (1)"; exit 1 }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
        git -C $repo add -A
        git -C $repo commit -q -m base
        $base = (git -C $repo rev-parse HEAD).Trim()
        $psExe = (Get-Process -Id $PID).Path
        $tasks = foreach ($id in $TaskIds) {
            [ordered]@{
                id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
                baselineExpect = @{ testsTotal = 1; testsPass = 1 }
                allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
                testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1")
                installFlags = @(); prompt = "fix it"
            }
        }
        @{ tasks = @($tasks) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root "tests/tasks/manifest.json")
        # Stand-in opencode: fixes the source and writes a test in every task; what
        # else it prints, and its exit code, depend on the task.
        @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    $id = Split-Path -Leaf $dir
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value 'a real test'
    $start = '{"type":"step_start","part":{"type":"step-start"}}'
    $edits = '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}', '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    $stop = '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    $over = '{"type":"error","sessionID":"s1","error":{"name":"ContextOverflowError","data":{"message":"request (70000 tokens) exceeds the available context size (65536 tokens), try increasing it"}}}'
    $api  = '{"type":"error","sessionID":"s1","error":{"name":"APIError","data":{"message":"Cannot connect to API"}}}'
    # What the fixture engine logs during the run, stamped now (section 5).
    $log = Join-Path $env:FIXTURE_ENGINELOG 'engine.log'
    if ($id -eq 'fx-truncated') { Add-Content -LiteralPath $log -Value "$([DateTimeOffset]::Now.ToString('o')) truncated prompt=83886 limit=32770" }
    if ($id -eq 'fx-reset')     { Add-Content -LiteralPath $log -Value "$([DateTimeOffset]::Now.ToString('o')) device lost on Vulkan0" }
    switch ($id) {
        'fx-recovered' { $over; $over; $start; $edits; $stop; exit 1 }
        'fx-dead'      { $start; $edits; $over; exit 1 }
        'fx-other'     { $over; $start; $edits; $stop; $api; $start; $stop; exit 1 }
        default        { $start; $edits; $stop; exit 0 }
    }
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $root "bin/standin.ps1")
        $bin = Join-Path $root "bin"
        "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
        $origPath = $env:PATH
        $env:PATH = "$bin;$env:PATH"
        $env:FIXTURE_ENGINELOG = Join-Path $root "engine-log"
        try {
            $out = & (Join-Path $root "tests/test-tasks.ps1") -Task $TaskIds -Model fixture/m -SkipInstall -RunTimeout 120 *>&1 | Out-String
        } finally {
            $env:PATH = $origPath
            Remove-Item Env:FIXTURE_ENGINELOG -ErrorAction SilentlyContinue
        }
        $results = Join-Path $root "tests/results"
        [pscustomobject]@{
            Output  = $out
            Results = $results
            Rows    = @(if (Test-Path (Join-Path $results "tasks-summary.tsv")) { Import-Csv (Join-Path $results "tasks-summary.tsv") -Delimiter "`t" })
        }
    }
    function Row($h, [string]$id) { @($h.Rows | Where-Object taskId -eq $id)[0] }
    function Json($h, [string]$id) { Get-ChildItem $h.Results -Filter "tasks-$id-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json }
    function Infra($h, [string]$id) { @(Get-ChildItem $h.Results -Filter "tasks-$id-*_INFRA_*.jsonl").Count }

    $h = Invoke-Harness $ScriptPath (Join-Path $tmp "e2e")
    Write-Host "-- end to end: recovered from two overflows, exit 1"
    Check "graded: a summary row"                                      ([bool](Row $h "fx-recovered")) "True"
    Check "...suite PASS"                                              (Row $h "fx-recovered").suite "PASS"
    Check "...failsOnOld PASS"                                         (Row $h "fx-recovered").failsOnOld "PASS"
    Check "run JSON overflowRecovery.overflowErrors"                   (Json $h "fx-recovered").overflowRecovery.overflowErrors 2
    Check "run JSON overflowRecovery.exitsLifted"                      (Json $h "fx-recovered").overflowRecovery.exitsLifted 1
    Check "the console says it was graded as exit 0"                   ($h.Output -match 'exited 1 after 2 context-overflow error\(s\) it recovered from') "True"
    Check "a context WARN names the 2 explicit refusals"               ($h.Output -match '(?s)\[WARN\]\s+context\s+->\s*the engine refused 2 over-long request\(s\) explicitly') "True"
    Check "...and no line says Ollama dropped messages"                ($h.Output -match 'Ollama dropped') "False"
    Write-Host "-- end to end: an overflow the session never finished after"
    Check "no summary row"                                             ([bool](Row $h "fx-dead")) "False"
    Check "no _INFRA_ transcript: it is its own outcome (_CTXEXCEEDED_)" (Infra $h "fx-dead") 0
    Check "a _CTXEXCEEDED_ transcript"                                 @(Get-ChildItem $h.Results -Filter "tasks-fx-dead-*_CTXEXCEEDED_*.jsonl").Count 1
    Check "the detail says overflow killed the run"                    ($h.Output -match 'refused 1 over-long request\(s\) explicitly .*overflow killed the run') "True"
    Write-Host "-- end to end: an overflow plus another error"
    Check "no summary row"                                             ([bool](Row $h "fx-other")) "False"
    Check "an _INFRA_ transcript"                                      (Infra $h "fx-other") 1
    Write-Host "-- end to end: a clean run"
    Check "graded"                                                     ([bool](Row $h "fx-clean")) "True"
    Check "overflowRecovery is null"                                   ($null -eq (Json $h "fx-clean").overflowRecovery) "True"
    # The real llama.cpp adapter: no engine log to read, and a run says so rather than "none".
    $cj = Json $h "fx-clean"
    Check "the llama.cpp adapter: promptTruncation not applicable"     ($cj.promptTruncation -like "not applicable: refused explicitly*") "True"
    Check "...gpuResets not checked, no events"                        ("{0} {1} {2}" -f $cj.gpuResets.checked, @($cj.gpuResets.events | Where-Object { $_ }).Count, ($cj.gpuResets.note -like "not checked*")) "False 0 True"
    Check "...a fixture provider's engine record is 'unknown', nothing borrowed" ("{0} {1} {2}" -f $cj.engine.name, ($null -eq $cj.engine.version), $cj.servingEngine.provider) "unknown True fixture"
    Check "...and ollamaVersion is null (kept so older files compare)" ($null -eq $cj.ollamaVersion) "True"

    Write-Host "-- control: the same harness with the hook removed"
    $noHook = Join-Path $tmp "no-hook.ps1"
    $src = [IO.File]::ReadAllText($ScriptPath)
    $stripped = [regex]::Replace($src, '(?m)^\s*\$(run|next) = Resolve-RecoveredOverflow \$(run|next)\r?\n', '')
    Check "the hook calls were found and removed"                      ($stripped.Length -lt $src.Length) "True"
    [IO.File]::WriteAllText($noHook, $stripped)
    $c = Invoke-Harness $noHook (Join-Path $tmp "control")
    Check "without the hook the recovered run gets no row (guard bites)" ([bool](Row $c "fx-recovered")) "False"

    # --- 5. outcomes an engine adapter reports from its own log ------------------
    $override = @'

# --- fixture override (tests/test-overflow-recovery.ps1): an engine whose log shows a
# silently cut prompt and a lost GPU device, as Ollama's server.log did until 2026-11-21.
function Read-FixtureEngineLog([string]$Dir, [string]$What, [DateTimeOffset]$Since, [DateTimeOffset]$Until) {
    @(Get-Content -LiteralPath (Join-Path $Dir 'engine.log') -ErrorAction SilentlyContinue | Where-Object {
        $_ -match "^(\S+) $What" -and [DateTimeOffset]::Parse($Matches[1]) -ge $Since -and [DateTimeOffset]::Parse($Matches[1]) -le $Until })
}
function Get-EnginePromptLossSetup {
    param([string]$Root, [string]$ProviderId)
    [pscustomobject]@{ Enabled = $true; LogDir = $env:FIXTURE_ENGINELOG; Description = "checked the fixture engine log" }
}
function Get-EnginePromptLoss {
    param($Setup, [DateTimeOffset]$Since, [DateTimeOffset]$Until)
    Read-FixtureEngineLog $Setup.LogDir 'truncated' $Since $Until
}
function Get-EnginePromptLossText {
    param($Hits)
    "the fixture engine cut {0} prompt(s) silently" -f @($Hits).Count
}
function Get-EngineDeviceLoss {
    param($Setup, [DateTimeOffset]$Since, [DateTimeOffset]$Until)
    $e = Read-FixtureEngineLog $Setup.LogDir 'device lost' $Since $Until
    [pscustomobject]@{ Checked = $true; Events = @($e); Note = "checked the fixture engine log" }
}
'@
    $a = Invoke-Harness $ScriptPath (Join-Path $tmp "adapter-log") -TaskIds @("fx-truncated", "fx-reset", "fx-clean") -EngineOverride $override
    Write-Host "-- adapter log: a prompt the engine cut silently"
    Check "no summary row"                                             ([bool](Row $a "fx-truncated")) "False"
    Check "a _TRUNCATED_ transcript, not _INFRA_"                      ("{0} {1}" -f @(Get-ChildItem $a.Results -Filter "tasks-fx-truncated-*_TRUNCATED_*.jsonl").Count, (Infra $a "fx-truncated")) "1 0"
    Check "no graded run JSON"                                         @(Get-ChildItem $a.Results -Filter "tasks-fx-truncated-*.json").Count 0
    Check "the FAIL names the adapter's text and says it is not graded" ($a.Output -match 'the fixture engine cut 1 prompt\(s\) silently: the model did not see the whole system prompt.*not graded, no summary row') "True"
    Write-Host "-- adapter log: a GPU device lost during the run"
    Check "still graded (one summary row)"                             ([bool](Row $a "fx-reset")) "True"
    Check "a gpu device WARN naming one loss"                          ($a.Output -match '(?s)\[WARN\]\s+gpu device\s+->\s*the GPU device was lost 1 time\(s\) during the run') "True"
    $rj = Json $a "fx-reset"
    Check "gpuResets records it, as checked"                           ("{0} {1}" -f $rj.gpuResets.checked, @($rj.gpuResets.events | Where-Object { $_ -like "*device lost*" }).Count) "True 1"
    Write-Host "-- adapter log: a clean run beside an old event of each kind"
    Check "graded (one summary row)"                                   ([bool](Row $a "fx-clean")) "True"
    $cj = Json $a "fx-clean"
    Check "gpuResets checked, no event (the old one is not blamed)"     ("{0} {1}" -f $cj.gpuResets.checked, @($cj.gpuResets.events | Where-Object { $_ }).Count) "True 0"
    Check "promptTruncation records the check and none during the run" $cj.promptTruncation "checked the fixture engine log - none during the run"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

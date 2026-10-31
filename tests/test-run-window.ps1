# protects: run-window.ps1 unattended window (gate, smoke go/no-go, deadline, STOP, server watch, report)
# run-after: run-window.ps1, run-retries.ps1 or run-tasks-batch.ps1 (their command lines), or the llama.cpp engine adapter
# test-run-window.ps1 - regression guard for tests/run-window.ps1, the unattended testing window.
#
# Why this exists: the script runs for hours with no one to read its output, so every decision it makes alone - stop
# at the gate, skip milestone 4 because the retries smoke only met infrastructure failures, end a phase when the
# server has been down for too long, cut a phase at the deadline, honour a STOP file - has to be right the first
# time and the report has to say what it decided. Nothing here needs a model, a GPU or the network: the real script
# runs in-process against stand-ins for run-retries.ps1, run-tasks-batch.ps1, summarize-rounds.ps1 and `opencode`
# (they log their arguments and play a scripted outcome), a synthetic private manifest, and a local HTTP server that
# plays llama-server's /health, /models and /props (through the real tests/engines/llamacpp.ps1).
# What it checks:
#   - the functions: Resolve-WindowTasks (retired tasks left out, a prefix names one task, -Last moves tasks to the
#     end, unknown names are reported, a regex narrows), New-TaskArgumentString (spaces, trailing backslashes,
#     arrays, switches), the generated phase commands;
#   - a full window: the four phases in order, the exact arguments each got (cap 2 for the smoke and 3 for milestone 4,
#     real-02 and wp-5b last, the shown prompt and the nudge, six reps of the 16 live mined tasks, retired ones left
#     out, opencode's auto-update off), the report's phases, falsifier lines and summarizer output;
#   - the gate: a down server, a seat the server does not serve, a seat opencode does not list, an unknown smoke task
#     each end the window with exit 2 before any phase runs;
#   - go/no-go: a retries smoke that met only infrastructure failures skips milestone 4 but not the baseline; one
#     infrastructure attempt followed by an accepted task, or plain model rejections, are GO; a batch smoke that
#     exits 1 or leaves no graded row skips the baseline but not milestone 4;
#   - the clock and the world: a phase still running at the deadline is cut and the report is written; a STOP file ends
#     the window; a server down past -ServerDownMinutes ends the phase, and the window stops if it does not return
#     and carries on if it does; a second window is refused; -Plan runs nothing and leaves no files.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-run-window.ps1
param([string]$ScriptPath = (Join-Path $PSScriptRoot "run-window.ps1"))

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$runner = $ScriptPath
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ([bool]($text -match $pattern)) "True" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("run-window-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$fxDir = Join-Path $tmp "fx"; New-Item -ItemType Directory -Force -Path $fxDir | Out-Null
$priv = Join-Path $tmp "priv"; New-Item -ItemType Directory -Force -Path (Join-Path $priv "tasks") | Out-Null
$lock = Join-Path $tmp "window.lock"
$server = $null; $helpers = @()

try {
    # --- fixtures ----------------------------------------------------------------------------------------
    $realIds = "real-01", "real-02", "real-03", "wp-0a", "wp-1a", "wp-2b", "wp-3a", "wp-3b", "wp-4a", "wp-5a", "wp-5b", "wp-6a", "wp-6f", "wp-7a", "wp-9a"
    $manifest = @{ tasks = @($realIds | ForEach-Object { @{ id = $_ } }) + @(@{ id = "wp-old"; retired = $true }) }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $priv "tasks/manifest.json")

    $fxRetries = Join-Path $tmp "fx-run-retries.ps1"
    @'
param([string[]]$Tasks, [string]$Model, [int]$MaxAttempts, [string]$TaskManifest, [string]$ResultsDir, [hashtable]$HarnessArgs = @{})
$leaf = Split-Path -Leaf $ResultsDir
$plan = if ($env:FX_PLAN) { $env:FX_PLAN | ConvertFrom-Json } else { $null }
$h = ($HarnessArgs.Keys | Sort-Object | ForEach-Object { "$_=$($HarnessArgs[$_])" }) -join ";"
Add-Content -LiteralPath (Join-Path $env:FX_DIR "calls.log") ("retries|{0}|max={1}|tasks={2}|harness={3}|autoupdate={4}|manifest={5}|gitprompt={6}" -f $leaf, $MaxAttempts, ($Tasks -join ","), $h, $env:OPENCODE_DISABLE_AUTOUPDATE, (Split-Path -Leaf (Split-Path -Parent $TaskManifest)), $env:GIT_TERMINAL_PROMPT)
$sleep = if ($plan -and $plan.$leaf -and $plan.$leaf.sleep) { [int]$plan.$leaf.sleep } else { 0 }
if ($sleep) { Start-Sleep -Seconds $sleep }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
$tsv = Join-Path $ResultsDir "retry-summary.tsv"
if (-not (Test-Path -LiteralPath $tsv)) { Set-Content -LiteralPath $tsv -Value "timestamp`ttask`tmodel`tmaxAttempts`tattempts`taccepted`tacceptedAttempt`treasons`tseconds`toutputTokens`truns" }
foreach ($t in $Tasks) {
    $spec = if ($plan -and $plan.$leaf -and $plan.$leaf.tasks -and $plan.$leaf.tasks.$t) { [string]$plan.$leaf.tasks.$t } else { "accepted" }
    $list = @($spec -split ",")
    $acc = ($list[-1] -eq "accepted")
    Add-Content -LiteralPath $tsv -Value ((@("2026-01-01T00:00:00", $t, $Model, $MaxAttempts, $list.Count, $acc, $(if ($acc) { $list.Count } else { "-" }), ($list -join ";"), 10, 100, "-")) -join "`t")
    # the harness's own graded row (a private results folder gets real-tasks-summary.tsv)
    $real = Join-Path $ResultsDir "real-tasks-summary.tsv"
    if (-not (Test-Path -LiteralPath $real)) { Set-Content -LiteralPath $real -Value "timestamp`ttaskId`tmodel" }
    Add-Content -LiteralPath $real -Value "2026-01-01T00:00:00`t$t`t$Model"
}
Write-Host ("retries: {0} task(s), mean 1.1 attempt(s) per task, cap reached on 0 (0)" -f $Tasks.Count)
$fals = [bool]($plan -and $plan.$leaf -and $plan.$leaf.falsified)
Write-Host $(if ($fals) { "falsifier: FALSIFIED - mean attempts 1.6 > 1.5" } else { "falsifier: holds - within the design's bounds" })
exit 0
'@ | Set-Content -LiteralPath $fxRetries

    $fxBatch = Join-Path $tmp "fx-run-tasks-batch.ps1"
    @'
param([switch]$SkipSetup, [string]$Mode, [string[]]$Models, [string[]]$Tasks, [int]$Reps = 0, [switch]$Yes, [int]$RunTimeout = 0, [string]$ResultsDir = "")
$leaf = Split-Path -Leaf $ResultsDir
$plan = if ($env:FX_PLAN) { $env:FX_PLAN | ConvertFrom-Json } else { $null }
Add-Content -LiteralPath (Join-Path $env:FX_DIR "calls.log") ("batch|{0}|skip={1}|mode={2}|yes={3}|reps={4}|timeout={5}|tasks={6}|autoupdate={7}|gitprompt={8}" -f $leaf, [bool]$SkipSetup, $Mode, [bool]$Yes, $Reps, $RunTimeout, ($Tasks -join ","), $env:OPENCODE_DISABLE_AUTOUPDATE, $env:GIT_TERMINAL_PROMPT)
$spec = if ($plan -and $plan.$leaf) { $plan.$leaf } else { $null }
if ($spec -and $spec.sleep) { Start-Sleep -Seconds ([int]$spec.sleep) }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
$rows = if ($spec -and $null -ne $spec.rows) { [int]$spec.rows } else { $Tasks.Count * [math]::Max(1, $Reps) }
$tsv = Join-Path $ResultsDir "tasks-summary.tsv"
Set-Content -LiteralPath $tsv -Value "timestamp`ttaskId`tmodel"
for ($i = 0; $i -lt $rows; $i++) { Add-Content -LiteralPath $tsv -Value "2026-01-01T00:00:00`tt$i`tm" }
exit $(if ($spec -and $null -ne $spec.exit) { [int]$spec.exit } else { 0 })
'@ | Set-Content -LiteralPath $fxBatch

    $fxSummarize = Join-Path $tmp "fx-summarize-rounds.ps1"
    'param([string[]]$ResultsDir)' + "`n" + 'Write-Host ("SUMMARY of " + (Split-Path -Leaf $ResultsDir[0]))' | Set-Content -LiteralPath $fxSummarize

    # `opencode models llamacpp-server`: the seat on one line, or nothing.
    $seatLine = "llamacpp-server/qwen3.6:35b-a3b-coding"
    $ocGood = Join-Path $tmp $(if ($IsWindows) { "opencode-good.cmd" } else { "opencode-good" })
    $ocNone = Join-Path $tmp $(if ($IsWindows) { "opencode-none.cmd" } else { "opencode-none" })
    if ($IsWindows) {
        Set-Content -LiteralPath $ocGood -Value "@echo $seatLine"
        Set-Content -LiteralPath $ocNone -Value "@echo off"
    } else {
        [IO.File]::WriteAllText($ocGood, "#!/usr/bin/env bash`necho '$seatLine'`n"); & chmod +x $ocGood
        [IO.File]::WriteAllText($ocNone, "#!/usr/bin/env bash`nexit 0`n"); & chmod +x $ocNone
    }

    # llama-server, as far as the runner asks: /health, /models (router mode), /props. A bare TcpListener answering HTTP/1.1
    # with Connection: close, so it needs no URL reservation on Windows.
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $server = [hashtable]::Synchronized(@{ Up = $true; Models = @("qwen3.6:35b-a3b-coding"); Stop = $false })
    $serverJob = Start-ThreadJob -ArgumentList $listener, $server -ScriptBlock {
        param($tcp, $st)
        try {
            while (-not $st.Stop) {
                if (-not $tcp.Pending()) { Start-Sleep -Milliseconds 25; continue }
                $client = $tcp.AcceptTcpClient()
                try {
                    $stream = $client.GetStream(); $reader = [IO.StreamReader]::new($stream)
                    $request = $reader.ReadLine()
                    while (($h = $reader.ReadLine()) -and $h -ne "") { }
                    $path = (($request -split " ")[1] -split "\?")[0]
                    $code = 200; $body = "{}"
                    switch ($path) {
                        "/health" { if ($st.Up) { $body = '{"status":"ok"}' } else { $code = 503; $body = '{"error":{"message":"down"}}' } }
                        "/models" { $body = (@{ data = @($st.Models | ForEach-Object { @{ id = $_; aliases = @(); status = @{ value = "loaded" } } }) } | ConvertTo-Json -Depth 6 -Compress) }
                        "/props" { $body = '{"build_info":"b11561-stand-in"}' }
                        default { $code = 404 }
                    }
                    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                    $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code X`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
                    $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
                } catch { } finally { $client.Close() }
            }
        } finally { $tcp.Stop() }
    }
    $url = "http://127.0.0.1:$port/v1"

    # A helper that waits for the runner to start a phase (its command file appears), then acts after a short delay: the
    # scenarios no longer depend on how long the runner took to get there.
    function Start-AfterPhase([string]$Phase, [double]$DelaySec, [scriptblock]$Action, $Arg) {
        $cmdFile = Join-Path $tmp ("out-" + ($script:n + 1) + "/commands/$Phase.ps1")
        Start-ThreadJob -ArgumentList $cmdFile, $DelaySec, $Action, $Arg -ScriptBlock {
            param($file, $delay, $action, $arg)
            $until = (Get-Date).AddSeconds(120)
            while (-not (Test-Path -LiteralPath $file) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 50 }
            Start-Sleep -Milliseconds ([int]($delay * 1000))
            & $action $arg
        }
    }
    $script:n = 0
    function Invoke-Window([hashtable]$Extra = @{}, [string]$Plan = "", [switch]$KeepFx) {
        $script:n++
        $out = Join-Path $tmp ("out-" + $script:n)
        Remove-Item -Recurse -Force $fxDir -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $fxDir | Out-Null
        $env:FX_DIR = $fxDir; $env:FX_PLAN = $Plan
        # The machine may already have these set (CI and cloud sandboxes do); the children must get them from the runner.
        Remove-Item Env:GIT_TERMINAL_PROMPT, Env:GCM_INTERACTIVE -ErrorAction SilentlyContinue
        $a = @{
            Name = "t$($script:n)"; ServerUrl = $url; PrivateRoot = $priv; OutDir = $out; LockPath = $lock
            ScriptRetries = $fxRetries; ScriptBatch = $fxBatch; ScriptSummarize = $fxSummarize; OpencodeCmd = $ocGood
            RequiredTools = @("pwsh"); SkipChecks = @("disk", "git"); Hours = 1
            PollSec = 0.3; ServerPollSec = 0.5; WaitServerMinutes = 0; ReportMinutes = 0.05; MinPhaseMinutes = 0.02
        }
        foreach ($k in $Extra.Keys) { $a[$k] = $Extra[$k] }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $text = & $runner @a *>&1 | Out-String
        $code = $LASTEXITCODE
        $sw.Stop()
        $report = Join-Path $out "REPORT.md"
        [pscustomobject]@{ Exit = $code; Out = $out; Text = $text; Seconds = $sw.Elapsed.TotalSeconds
            Report = $(if (Test-Path -LiteralPath $report) { Get-Content -Raw -LiteralPath $report } else { "" })
            Calls = @(if (Test-Path -LiteralPath (Join-Path $fxDir "calls.log")) { Get-Content -LiteralPath (Join-Path $fxDir "calls.log") }) }
    }
    function Phase-Row($r, [string]$id) { ([regex]::Match($r.Report, "(?m)^\| $([regex]::Escape($id)) \| ([a-z-]+) \|")).Groups[1].Value }
    function Calls-Like($r, [string]$pattern) { @($r.Calls | Where-Object { $_ -match $pattern }) }

    # --- the functions -----------------------------------------------------------------------------------
    Write-Host "-- Resolve-WindowTasks"
    & {
        . $runner
        $m = Join-Path $tmp "fn-manifest.json"
        @{ tasks = @(@{ id = "a-01-first" }, @{ id = "a-02-second" }, @{ id = "b-01-third" }, @{ id = "b-02-gone"; retired = $true }, @{ id = "c" }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $m
        $all = Resolve-WindowTasks -Manifest $m
        Check "all = every live task, retired left out" ($all.Ids -join ",") "a-01-first,a-02-second,b-01-third,c"
        Check "a unique prefix names one task" ((Resolve-WindowTasks -Manifest $m -Names "a-02").Ids -join ",") "a-02-second"
        Check "an exact id wins over prefixes" ((Resolve-WindowTasks -Manifest $m -Names "c").Ids -join ",") "c"
        $miss = Resolve-WindowTasks -Manifest $m -Names "a-01", "nope", "a"
        Check "unknown and ambiguous names are reported, the rest kept" ("{0}|{1}" -f ($miss.Ids -join ","), ($miss.Missing -join ",")) "a-01-first|nope,a"
        Check "a retired task cannot be named" ((Resolve-WindowTasks -Manifest $m -Names "b-02").Missing -join ",") "b-02"
        Check "-Match narrows by regex" ((Resolve-WindowTasks -Manifest $m -Match '^b-').Ids -join ",") "b-01-third"
        Check "-Last moves tasks to the end, in the order given" ((Resolve-WindowTasks -Manifest $m -Last "a-01", "b-01").Ids -join ",") "a-02-second,c,a-01-first,b-01-third"
        Check "a -Last name that is not there changes nothing" ((Resolve-WindowTasks -Manifest $m -Last "zzz").Ids -join ",") "a-01-first,a-02-second,b-01-third,c"
        $pub = Resolve-WindowTasks -Manifest (Join-Path $repo "tests/tasks/manifest.json") -Match '^(kane-(0[7-9]|1[0-4])|lfc-0[457]|asohav-0[3-9])-'
        Check "the default baseline pattern selects the 16 live mined tasks of the real manifest" $pub.Ids.Count 16
        Check "...with a retired one (asohav-05) left out" (@($pub.Ids | Where-Object { $_ -like "asohav-05*" -or $_ -like "asohav-06*" }).Count) 0
        Check "...and kane-07 and asohav-09 in" (@($pub.Ids | Where-Object { $_ -like "kane-07*" -or $_ -like "asohav-09*" }).Count) 2

        Write-Host "-- New-TaskArgumentString"
        $argv = New-TaskArgumentString -Parameters ([ordered]@{ Name = "w1"; OutDir = "C:\Users\a b\out\"; Run = @("smoke", "m4"); NoNudge = [switch]::new($true); Plan = [switch]::new($false) })
        Check "values quoted, a trailing backslash doubled, arrays comma-joined, switches bare" $argv '-Name "w1" -OutDir "C:\Users\a b\out\\" -Run "smoke,m4" -NoNudge'

        Write-Host "-- the generated commands"
        $cmd = New-RetriesScript -Script "C:\h\tests\run-retries.ps1" -Tasks @("x", "y'z") -Model "p/m" -Attempts 3 -Manifest "C:\p\m.json" -ResultsDir "C:\p\r" -HarnessArgs @{ NudgeOnStop = $true; RunTimeout = 2700; ShownPrompt = 2; StopClassifier = 3 }
        Has "retries: tasks as a quoted array, a quote inside an id doubled" $cmd "-Tasks @\('x', 'y''z'\)"
        Has "retries: the harness arguments, sorted" $cmd '-HarnessArgs @\{ NudgeOnStop = \$true; RunTimeout = 2700; ShownPrompt = 2; StopClassifier = 3 \}'
        Has "retries: exits with the script's code" $cmd 'exit \$LASTEXITCODE'
        $cmd = New-BatchScript -Script "C:\h\tests\run-tasks-batch.ps1" -Tasks @("x") -Model "p/m" -Reps 6 -RunTimeout 2700 -ResultsDir "C:\p\r"
        Has "batch: unassisted, no setup, no prompts, rep count" $cmd "-SkipSetup -Mode Tasks -Models 'p/m' -Tasks @\('x'\) -Reps 6 -Yes -RunTimeout 2700"
    }

    # --- a full window -------------------------------------------------------------------------------------
    Write-Host "-- a full window"
    $r = Invoke-Window
    Check "exit 0" $r.Exit 0
    Check "the report is written" ($r.Report.Length -gt 0) "True"
    foreach ($id in "gate", "smoke-retries", "smoke-batch", "m4", "baseline") { Check "phase $id is ok" (Phase-Row $r $id) "ok" }
    $order = @($r.Calls | ForEach-Object { ($_ -split "\|")[0..1] -join ":" })
    Check "the phases ran in order" ($order -join " ") "retries:smoke-retries batch:smoke-batch retries:m4 batch:baseline"
    $c = $r.Calls
    Has "smoke retries: cap 2, the two quick tasks, the private manifest" $c[0] 'max=2\|tasks=real-01,wp-0a\|.*manifest=tasks\|gitprompt=0$'
    Has "m4: cap 3 and real-02, wp-5b last of 15 tasks" $c[2] 'max=3\|tasks=real-01,real-03,wp-0a,wp-1a,wp-2b,wp-3a,wp-3b,wp-4a,wp-5a,wp-6a,wp-6f,wp-7a,wp-9a,real-02,wp-5b\|'
    Has "m4: nudged, classifier 3, 2700 s runs, shown prompt 2" $c[2] 'harness=NudgeOnStop=True;RunTimeout=2700;ShownPrompt=2;StopClassifier=3\|'
    Has "every child had opencode's auto-update off" ($c -join "`n") '(?s)autoupdate=1.*autoupdate=1.*autoupdate=1.*autoupdate=1'
    Has "...and git's prompts off, so a fetch cannot wait for a credential" ($c -join "`n") '(?s)gitprompt=0.*gitprompt=0.*gitprompt=0.*gitprompt=0'
    Has "smoke batch: one rep, no setup, no prompts" $c[1] 'skip=True\|mode=Tasks\|yes=True\|reps=1\|'
    Has "baseline: six reps of 16 tasks, kane-07 first" $c[3] 'reps=6\|timeout=2700\|tasks=kane-07-find-qualifier-type,.*asohav-09-seed-virtue-conformance\|'
    Check "baseline: 16 tasks, none of the retired" (@(($c[3] -split "tasks=")[1] -split "\|")[0] -split ",").Count 16
    Check "baseline: asohav-05 and asohav-06 are not in it" ([bool]($c[3] -match "asohav-0[56]")) "False"
    Has "the report carries the loop's own falsifier line" $r.Report 'falsifier: holds'
    Has "...and the summariser's output for m4 and the baseline" $r.Report '(?s)SUMMARY of m4.*SUMMARY of baseline'
    Has "...and the server's build" $r.Report 'llama\.cpp build b11561-stand-in'
    Has "...and nothing flagged" $r.Report '(?m)^- Nothing flagged'
    Check "the exact commands are kept" (@(Get-ChildItem (Join-Path $r.Out "commands") -Filter "*.ps1").Count) 4
    Has "status.txt says the window is done" (Get-Content -Raw (Join-Path $r.Out "status.txt")) 'phase done'
    Check "the lock is released" (Test-Path $lock) "False"

    $r = Invoke-Window @{ Run = @("m4"); NoNudge = $true }
    Check "-Run m4 -NoNudge: only m4 ran, unnudged" ($r.Calls.Count -eq 1 -and $r.Calls[0] -match 'harness=NudgeOnStop=False;') "True"
    Has "...and the report says what was not selected" $r.Report '\| smoke \| not selected'

    # --- the gate ---------------------------------------------------------------------------------------------
    Write-Host "-- the gate"
    $server.Up = $false
    $r = Invoke-Window
    Check "a server that does not answer /health: exit 2" $r.Exit 2
    Check "...and no phase ran" $r.Calls.Count 0
    Has "...the report says NO-GO and names the check" $r.Report 'NO-GO at the gate.*server /health'
    $server.Up = $true
    $server.Models = @("something-else")
    $r = Invoke-Window
    Check "a seat the server does not serve: exit 2" $r.Exit 2
    Has "...named in the report" $r.Report 'seat served'
    $server.Models = @("qwen3.6:35b-a3b-coding")
    $r = Invoke-Window @{ OpencodeCmd = $ocNone }
    Check "a seat opencode does not list: exit 2" $r.Exit 2
    Has "...named in the report" $r.Report 'opencode seat'
    $r = Invoke-Window @{ SmokeTasks = @("real-01", "no-such-task") }
    Check "a smoke task the private manifest lacks: exit 2" $r.Exit 2
    Check "...and nothing ran" $r.Calls.Count 0
    $r = Invoke-Window @{ PrivateRoot = (Join-Path $tmp "nowhere") }
    Check "no private manifest: exit 2" $r.Exit 2
    $r = Invoke-Window @{ RequiredTools = @("pwsh", "no-such-tool-xyz") }
    Check "a missing tool: exit 2" $r.Exit 2

    # --- go / no-go -------------------------------------------------------------------------------------------
    Write-Host "-- go / no-go between phases"
    $r = Invoke-Window -Plan '{"smoke-retries":{"tasks":{"real-01":"infrastructure,infrastructure","wp-0a":"infrastructure,infrastructure"}}}'
    Check "a retries smoke of infrastructure failures only: exit 0 (the window ran)" $r.Exit 0
    Check "...smoke-retries is nogo" (Phase-Row $r "smoke-retries") "nogo"
    Check "...m4 is skipped" (Phase-Row $r "m4") "skipped"
    Check "...the baseline still ran" (Phase-Row $r "baseline") "ok"
    Check "...m4's loop was never started" (Calls-Like $r '^retries\|m4\|').Count 0
    Has "...and the report flags it" $r.Report 'retries smoke was NO-GO'
    $r = Invoke-Window -Plan '{"smoke-retries":{"tasks":{"real-01":"infrastructure,accepted","wp-0a":"infrastructure,infrastructure"}}}'
    Check "one infrastructure attempt, one task accepted: GO, m4 runs" ((Phase-Row $r "smoke-retries") + "/" + (Phase-Row $r "m4")) "ok/ok"
    $r = Invoke-Window -Plan '{"smoke-retries":{"tasks":{"real-01":"acceptance,acceptance","wp-0a":"suite,scope"}}}'
    Check "model rejections without infrastructure failures: GO, m4 runs" ((Phase-Row $r "smoke-retries") + "/" + (Phase-Row $r "m4")) "ok/ok"
    $r = Invoke-Window -Plan '{"smoke-batch":{"exit":1}}'
    Check "a batch smoke that exits 1: baseline skipped, m4 ran" ((Phase-Row $r "smoke-batch") + "/" + (Phase-Row $r "baseline") + "/" + (Phase-Row $r "m4")) "nogo/skipped/ok"
    $r = Invoke-Window -Plan '{"smoke-batch":{"rows":0}}'
    Check "a batch smoke with no graded row: baseline skipped" ((Phase-Row $r "smoke-batch") + "/" + (Phase-Row $r "baseline")) "nogo/skipped"
    Has "...and the report flags it" $r.Report 'batch smoke was NO-GO'

    Write-Host "-- milestone 4's report"
    $r = Invoke-Window -Plan '{"m4":{"falsified":true}}'
    Has "a tripped falsifier is flagged under 'Needs your eyes', with the 2-of-15 caveat" $r.Report '(?s)## Needs your eyes.*falsifier tripped \(mean attempts 1\.6 > 1\.5\).*2 of 15'
    Check "...and a window whose falsifier holds flags nothing" ((Invoke-Window).Report -match '(?m)^- Nothing flagged') "True"
    $r = Invoke-Window -Plan '{"m4":{"tasks":{"real-02":"acceptance,acceptance,acceptance","wp-5b":"tampered,tampered,tampered","wp-3a":"suite,accepted"}}}'
    Has "attempts and the verdict per task" $r.Report 'real-02 +3 attempt\(s\) +not accepted +\[acceptance;acceptance;acceptance\]'
    Has "...an accepted retry" $r.Report 'wp-3a +2 attempt\(s\) +ACCEPTED +\[suite;accepted\]'
    Has "...the count of tasks reached and accepted" $r.Report '15 of 15 task\(s\) reached, 13 accepted, 20 attempt\(s\)'

    # --- the clock and the world -------------------------------------------------------------------------------
    Write-Host "-- the deadline"
    $r = Invoke-Window @{ Run = @("baseline"); Hours = 0.012 } -Plan '{"baseline":{"sleep":120}}'
    Check "a phase still running at the deadline is cut: exit 0" $r.Exit 0
    Check "...its verdict is cut" (Phase-Row $r "baseline") "cut"
    Check "...in well under the stand-in's 120 s" ($r.Seconds -lt 60) "True"
    Check "...and the report was written" ($r.Report.Length -gt 0) "True"
    $r = Invoke-Window @{ Hours = 0.0005 }
    Check "no time left for a phase: each is skipped, not started" (@("smoke-retries", "m4", "baseline") | ForEach-Object { Phase-Row $r $_ } | Sort-Object -Unique) "skipped"

    Write-Host "-- STOP"
    $stopFile = Join-Path $tmp "out-$($script:n + 1)/STOP"
    $helpers += Start-AfterPhase "baseline" 2 { param($f) New-Item -ItemType File -Path $f -Force | Out-Null } $stopFile
    $r = Invoke-Window @{ Run = @("baseline") } -Plan '{"baseline":{"sleep":120}}'
    Check "a STOP file ends the window: exit 0" $r.Exit 0
    Check "...the phase did not run to its 120 s" ($r.Seconds -lt 60) "True"
    Has "...the report says why" $r.Report 'STOP file ended the window'

    Write-Host "-- the server goes away"
    $helpers += Start-AfterPhase "smoke-retries" 2 { param($s) $s.Up = $false } $server
    $r = Invoke-Window @{ Run = @("smoke"); ServerDownMinutes = 0.05; RecoverMinutes = 0.05 } -Plan '{"smoke-retries":{"sleep":120}}'
    Check "a server down past -ServerDownMinutes ends the phase (not at the stand-in's 120 s)" ($r.Seconds -lt 70) "True"
    Has "...the report says the phase ended because the server stayed down" $r.Report 'ended because the server stayed down'
    Has "...and that the window stopped" $r.Report 'server did not come back'
    Check "...and the next step never started" ((Phase-Row $r "smoke-batch") + "|" + (Calls-Like $r '^batch\|').Count) "|0"
    Has "...with the outage in the server section" $r.Report '(?s)## Server.*Down \(as seen'
    $server.Up = $true
    $helpers += Start-AfterPhase "smoke-retries" 2 { param($s) $s.Up = $false; Start-Sleep -Seconds 7; $s.Up = $true } $server
    $r = Invoke-Window @{ Run = @("smoke"); ServerDownMinutes = 0.05; RecoverMinutes = 0.5 } -Plan '{"smoke-retries":{"sleep":120}}'
    Check "a server that comes back inside -RecoverMinutes: the next step still runs" (Phase-Row $r "smoke-batch") "ok"
    Check "...while the interrupted step is nogo (so m4 would have been skipped)" (Phase-Row $r "smoke-retries") "nogo"
    Has "...and the report records the outage" $r.Report 'stayed down'

    $helpers | Wait-Job -Timeout 30 | Out-Null
    $server.Up = $true

    Write-Host "-- one window at a time, -Plan, bad arguments"
    $sleeper = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 120") -PassThru -NoNewWindow
    Set-Content -LiteralPath $lock -Value $sleeper.Id
    $r = Invoke-Window
    Check "a live window's lock refuses a second one: exit 3" $r.Exit 3
    Check "...and nothing ran" $r.Calls.Count 0
    Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $lock -Value 99999999
    $r = Invoke-Window
    Check "a stale lock (no such process) is ignored" $r.Exit 0
    $r = Invoke-Window @{ Plan = $true }
    Check "-Plan runs nothing" $r.Calls.Count 0
    Check "...leaves no output folder" (Test-Path $r.Out) "False"
    Has "...and prints the four commands" $r.Text '(?s)smoke-retries.*smoke-batch.*-- m4.*-- baseline'
    Check "-Run bogus: exit 3" (Invoke-Window @{ Run = @("bogus") }).Exit 3
    Check "-Hours 0: exit 3" (Invoke-Window @{ Hours = 0 }).Exit 3
    if (-not $IsWindows) { Check "-Detach off Windows: exit 3, nothing registered" (Invoke-Window @{ Detach = $true }).Exit 3 }
} finally {
    if ($server) { $server.Stop = $true }
    foreach ($j in @($serverJob) + $helpers) { if ($j) { try { Wait-Job $j -Timeout 5 | Out-Null; Remove-Job $j -Force -ErrorAction SilentlyContinue } catch { } } }
    Remove-Item Env:FX_DIR, Env:FX_PLAN, Env:OPENCODE_DISABLE_AUTOUPDATE, Env:LLAMACPP_SERVER_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

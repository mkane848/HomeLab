# test-gpu-placement.ps1 - regression guard for the GPU-placement check in
# test-tasks.ps1 (Get-OllamaGpuPlacement, exit -5, `-NoGpuCheck`) and the batch's
# stop on it (Get-CpuOnlyRun in run-tasks-batch.ps1).
#
# Why this exists: on 2026-10-12 the server's container lost its GPU after a
# systemd reload. Ollama kept answering from the CPU (qwen3.6 at 38 GB, 100% CPU),
# `ollama list` stayed green, and a benchmark batch crawled for 31 minutes before
# anyone noticed. Nothing in a run looked wrong except its speed. After each run
# the harness now asks the serving Ollama's /api/ps where the seat's model sits;
# loaded with none of it in VRAM is infrastructure (exit -5, a _CPUONLY_
# transcript, no row), and the batch stops driving that host.
#
# What it does:
#   1. Runs the REAL Get-OllamaGpuPlacement against canned /api/ps replies: a
#      healthy split (60% on the GPU), CPU-only (the incident's shape), the CPU-
#      pinned 3b beside a GPU seat (0% by design, must not count), a seat that is
#      not loaded, an empty or malformed list, an unreachable host, a bare tag,
#      case, and the `model` field.
#   2. Runs the REAL Get-CpuOnlyRun (with Get-ResultFileNames / Get-NewRunFiles)
#      on synthetic result folders: a _CPUONLY_ transcript left by this run, an
#      _INFRA_ one, one that was there before, another task's, another model's.
#   3. Runs the REAL test-tasks.ps1 end to end (private manifest, fixture repo,
#      stand-in opencode, a stand-in Invoke-RestMethod for the host): a healthy
#      run is graded and records gpuPlacement; a CPU-only one is exit -5 with a
#      _CPUONLY_ transcript and no JSON and no row; -NoGpuCheck grades it and
#      never asks; not-loaded and unreachable are graded with a WARN; a provider
#      that is not Ollama is graded and never asked.
#   4. Runs the REAL run-tasks-batch.ps1 end to end (stand-in opencode, test-
#      tasks.ps1 and Ollama /api/tags): a _CPUONLY_ run stops the batch with the
#      reason, and a batch without one runs everything.
# Exit 1 on any failure. A control: pass -ScriptPath / -BatchPath a copy with the
# check removed and the matching scenarios fail.
#
# Windows stand-ins, like the neighbouring guards (.cmd for the batch's opencode).
#
# Usage:  .\tests\test-gpu-placement.ps1 [-ScriptPath <a test-tasks.ps1>] [-BatchPath <a run-tasks-batch.ps1>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$BatchPath = (Join-Path $PSScriptRoot "run-tasks-batch.ps1")
)

$ErrorActionPreference = "Stop"

function Get-Functions([string]$Path, [string[]]$Names) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs.Count) { $errs; exit 2 }
    $all = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    foreach ($name in $Names) {
        $fn = $all | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $fn) { Write-Host "FAIL: $name not found in $Path"; exit 1 }
        $fn.Extent.Text
    }
}
foreach ($t in (Get-Functions $ScriptPath @("Get-OllamaGpuPlacement"))) { Invoke-Expression $t }
foreach ($t in (Get-Functions $BatchPath @("Get-ResultFileNames", "Get-NewRunFiles", "Get-CpuOnlyRun"))) { Invoke-Expression $t }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }
function Lacks([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "False" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("gpu-placement-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Write-Fixture([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

# --- canned /api/ps -------------------------------------------------------
# A stand-in Invoke-RestMethod in this scope: the real function's call resolves to
# it. $script:PsReply is the JSON to answer with, or "THROW".
$script:PsReply = ""
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType)
    if ("$Uri" -notmatch '/api/ps$') { throw "fixture: no endpoint $Uri" }
    if ($script:PsReply -eq "THROW") { throw "fixture: $Uri unreachable" }
    return ($script:PsReply | ConvertFrom-Json)
}
function PsJson([object[]]$models) { (@{ models = @($models) } | ConvertTo-Json -Depth 4 -Compress) }
function M([string]$name, [double]$size, [double]$vram, [string]$model = "") {
    @{ name = $name; model = $(if ($model) { $model } else { $name }); size = $size; size_vram = $vram }
}
function Place([string]$tag) { Get-OllamaGpuPlacement -Root "http://fixture.invalid:11434" -Tag $tag }

try {
    Write-Host "-- Get-OllamaGpuPlacement (real function, canned /api/ps)"
    $seat = "qwen3.6:35b-a3b-coding"
    $script:PsReply = PsJson @((M $seat 22.68e9 13.59e9), (M "qwen2.5-coder-3b-cpu:latest" 2.44e9 0))
    $p = Place $seat
    Check "healthy split: gpu"                                   $p.Verdict "gpu"
    Check "...share 0.599 (13.59 of 22.68 GB)"                   $p.Share 0.599
    Check "...the detail names both sizes"                       $p.Detail "22.68 GB, 13.59 GB in VRAM"
    Check "...with the CPU-pinned 3b (0% by design) beside it"   (Place "qwen2.5-coder-3b-cpu").Verdict "cpu-only"
    $script:PsReply = PsJson @((M $seat 38e9 0))
    $p = Place $seat
    Check "the incident's shape (38 GB, 0 VRAM): cpu-only"       $p.Verdict "cpu-only"
    Check "...share 0"                                           $p.Share 0
    Has   "...the detail says so"                                $p.Detail 'entirely in system RAM \(38 GB, size_vram 0\)'
    $script:PsReply = PsJson @((M "other:7b" 5e9 5e9), (M $seat 38e9 0))
    Check "cpu-only even when another model is on the GPU"       (Place $seat).Verdict "cpu-only"
    $script:PsReply = PsJson @((M $seat 14e9 14e9))
    Check "entirely in VRAM: gpu, share 1"                       ("{0} {1}" -f (Place $seat).Verdict, (Place $seat).Share) "gpu 1"
    $script:PsReply = PsJson @((M "other:7b" 5e9 5e9))
    Check "not loaded (another model is): not-loaded"            (Place $seat).Verdict "not-loaded"
    $script:PsReply = PsJson @()
    Check "empty list: not-loaded"                               (Place $seat).Verdict "not-loaded"
    $script:PsReply = "{}"
    Check "no models key: not-loaded"                            (Place $seat).Verdict "not-loaded"
    $script:PsReply = "THROW"
    $p = Place $seat
    Check "unreachable: unchecked"                               $p.Verdict "unchecked"
    Has   "...says which URL"                                    $p.Detail 'fixture\.invalid:11434/api/ps did not answer'
    $script:PsReply = PsJson @((M "foo:latest" 4e9 4e9))
    Check "a bare tag matches :latest"                           (Place "foo").Verdict "gpu"
    $script:PsReply = PsJson @((M $seat 22e9 13e9))
    Check "the tag is matched without regard to case"            (Place "QWEN3.6:35B-A3B-CODING").Verdict "gpu"
    $script:PsReply = PsJson @((M "alias" 4e9 0 "qwen3:8b"))
    Check "the `model` field matches when `name` does not"       (Place "qwen3:8b").Verdict "cpu-only"

    Write-Host "-- Get-CpuOnlyRun (real function, synthetic result folders)"
    $rd = Join-Path $tmp "synthetic"
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    $before = Get-ResultFileNames -Dir $rd
    $label = "ollama-server_qwen3.6_35b-a3b-coding"
    Write-Fixture (Join-Path $rd "tasks-t1-${label}_CPUONLY_20261012-120000.jsonl") "{}"
    Check "a _CPUONLY_ transcript this run left"                 (Get-CpuOnlyRun -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "ollama-server/qwen3.6:35b-a3b-coding") "tasks-t1-${label}_CPUONLY_20261012-120000.jsonl"
    Check "...not for another task"                              ($null -eq (Get-CpuOnlyRun -ResultsDir $rd -Before $before -TaskId "t2" -ModelLabel "ollama-server/qwen3.6:35b-a3b-coding")) "True"
    Check "...not for another model"                             ($null -eq (Get-CpuOnlyRun -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "ollama-server/qwen3:8b")) "True"
    $after = Get-ResultFileNames -Dir $rd
    Check "one that was there before the run: none"              ($null -eq (Get-CpuOnlyRun -ResultsDir $rd -Before $after -TaskId "t1" -ModelLabel "ollama-server/qwen3.6:35b-a3b-coding")) "True"
    $rd2 = Join-Path $tmp "synthetic2"
    New-Item -ItemType Directory -Path $rd2 -Force | Out-Null
    $b2 = Get-ResultFileNames -Dir $rd2
    Write-Fixture (Join-Path $rd2 "tasks-t1-${label}_INFRA_20261012-120000.jsonl") "{}"
    Write-Fixture (Join-Path $rd2 "tasks-t1-${label}_20261012-120100.json") "{}"
    Check "an _INFRA_ transcript and a graded run: none"         ($null -eq (Get-CpuOnlyRun -ResultsDir $rd2 -Before $b2 -TaskId "t1" -ModelLabel "ollama-server/qwen3.6:35b-a3b-coding")) "True"
    Check "a results folder that does not exist: none"           ($null -eq (Get-CpuOnlyRun -ResultsDir (Join-Path $tmp "nope") -Before @{} -TaskId "t1" -ModelLabel "x")) "True"

    # --- end to end: the real test-tasks.ps1 ---------------------------------
    Write-Host "-- end to end: the real test-tasks.ps1, a private manifest, a stand-in opencode and host"
    $psExe = (Get-Process -Id $PID).Path
    $h = Join-Path $tmp "h"
    $priv = Join-Path $tmp "priv"
    $repo = Join-Path $tmp "repo"
    foreach ($d in @("$h/tests/tasks", "$h/bin", "$priv/hidden/fx", $repo)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $h "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $h "tests") -Recurse -Force
    '{"tasks":[]}' | Set-Content -LiteralPath (Join-Path $h "tests/tasks/manifest.json")
    Set-Content -LiteralPath (Join-Path $priv "hidden/fx/hidden.txt") -Value "hidden test"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
if ((Test-Path hidden.txt) -and $src -ne 'fixed') { Write-Host "Tests  1 failed (2)"; exit 1 }
Write-Host "Tests  2 passed (2)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    $task = [ordered]@{
        id = "fx-fix"; title = "fx-fix"; repo = $repo; branch = "bench/fx-fix"; benchBaseCommit = $base
        grading = "acceptance"; scope = "guardrails"; acceptance = [ordered]@{ dir = "hidden/fx" }
        testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt`nso that it reads fixed"
    }
    @{ tasks = @($task) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $priv "manifest.json")

    # Stand-in opencode: fixes src.txt and sums up.
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
$sid = ',"sessionID":"ses_fx"'
function Fin { '{"type":"step_finish"' + $sid + ',"part":{"reason":"stop","tokens":{"input":900,"output":20,"cache":{"read":0,"write":0}}}}' }
Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
'{"type":"tool_use"' + $sid + ',"part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
Fin
'{"type":"text"' + $sid + ',"part":{"text":"Done: src.txt reads fixed and the tests pass."}}'
Fin
exit 0
'@ | Set-Content -LiteralPath (Join-Path $h "bin/opencode.ps1")

    # Driver (a child process, so the exit code is the script's own): a stand-in
    # Invoke-RestMethod for the host. /api/ps answers from a file and logs each call.
    Write-Fixture "$tmp/driver.ps1" @'
param([string]$Script, [string]$ArgsFile)
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType)
    $u = "$Uri"
    if ($u -match '/api/ps$') {
        Add-Content -LiteralPath $env:FIXTURE_PS_CALLS -Value $u
        $reply = Get-Content -LiteralPath $env:FIXTURE_PS_FILE -Raw
        if ($reply.Trim() -eq 'THROW') { throw "fixture: $u unreachable" }
        return ($reply | ConvertFrom-Json)
    }
    if ($u -match '/api/version$') { return [pscustomobject]@{ version = '0.34.3' } }
    if ($u -match '/api/show$') { return [pscustomobject]@{ parameters = 'num_ctx    65536' } }
    throw "fixture: no endpoint $u"
}
$a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json
$splat = @{}
foreach ($p in $a.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [array]) { $splat[$p.Name] = [string[]]$v } else { $splat[$p.Name] = $v }
}
& $Script @splat
exit $LASTEXITCODE
'@
    $tt = Join-Path $h "tests/test-tasks.ps1"
    $fxModel = "fx-model:latest"
    $script:scn = 0
    function Invoke-Harness([string]$Reply, [string]$Model = "ollama-server/fx-model", [switch]$NoGpuCheck) {
        $script:scn++
        $rdir = Join-Path $priv "results-$($script:scn)"
        $psFile = Join-Path $tmp "ps-$($script:scn).json"
        $psCalls = Join-Path $tmp "ps-calls-$($script:scn).txt"
        Write-Fixture $psFile $Reply
        Write-Fixture $psCalls ""
        $argv = @{
            Task = @("fx-fix"); Model = $Model; SkipInstall = $true; RunTimeout = 120
            OllamaLogDir = (Join-Path $tmp "no-log"); TaskManifest = (Join-Path $priv "manifest.json"); ResultsDir = $rdir
        }
        if ($NoGpuCheck) { $argv.NoGpuCheck = $true }
        $argsFile = Join-Path $tmp "args-$($script:scn).json"
        Write-Fixture $argsFile ($argv | ConvertTo-Json -Depth 4)
        $savedPath = $env:PATH
        $env:PATH = "$(Join-Path $h 'bin');$savedPath"
        $env:OLLAMA_SERVER_BASE_URL = "http://fixture.invalid:11434/v1"
        $env:FIXTURE_PS_FILE = $psFile
        $env:FIXTURE_PS_CALLS = $psCalls
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp "driver.ps1") -Script $tt -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            $env:PATH = $savedPath
            Remove-Item Env:OLLAMA_SERVER_BASE_URL, Env:FIXTURE_PS_FILE, Env:FIXTURE_PS_CALLS -ErrorAction SilentlyContinue
        }
        $json = @(Get-ChildItem -LiteralPath $rdir -Filter "tasks-fx-fix-*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_(INFRA|TIMEOUT|TRUNCATED|CPUONLY)_' })
        $tsv = Join-Path $rdir "real-tasks-summary.tsv"
        [pscustomobject]@{
            Out = ($out -replace '\x1b\[[0-9;]*m', ''); Exit = $code
            Json = $(if ($json.Count) { Get-Content -LiteralPath $json[0].FullName -Raw | ConvertFrom-Json } else { $null })
            Rows = $(if (Test-Path -LiteralPath $tsv) { @(Get-Content -LiteralPath $tsv | Select-Object -Skip 1 | Where-Object { $_ }).Count } else { 0 })
            CpuOnly = @(Get-ChildItem -LiteralPath $rdir -Filter "*_CPUONLY_*.jsonl" -ErrorAction SilentlyContinue).Count
            PsCalls = @(Get-Content -LiteralPath $psCalls | Where-Object { $_ }).Count
        }
    }

    Write-Host "   scenario: healthy (60% on the GPU)"
    $r = Invoke-Harness (PsJson @((M $fxModel 22.68e9 13.59e9)))
    Check "exit 0"                                               $r.Exit 0
    Has   "console: a gpu placement PASS with the sizes"         $r.Out '\[PASS\]\s+gpu placement\s+->\s+fx-model:latest: 22\.68 GB in total, 13\.59 GB \(60%\) in VRAM'
    Check "graded: one row"                                      $r.Rows 1
    Check "JSON gpuPlacement: checked, verdict gpu"              ("{0} {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.verdict) "True gpu"
    Check "...share 0.599, 22.68 GB, 13.59 GB in VRAM"           ("{0} {1} {2}" -f $r.Json.gpuPlacement.share, $r.Json.gpuPlacement.totalGB, $r.Json.gpuPlacement.vramGB) "0.599 22.68 13.59"
    Check "asked /api/ps once"                                   $r.PsCalls 1

    Write-Host "   scenario: CPU-only (38 GB, 0 VRAM)"
    $r = Invoke-Harness (PsJson @((M $fxModel 38e9 0)))
    Check "exit 1 (the run FAILed as infrastructure)"            $r.Exit 1
    Has   "console: the FAIL says the seat was in system RAM"    $r.Out 'entirely in system RAM \(38 GB, size_vram 0\) after the run'
    Has   "...and that it measures the host, not the model"      $r.Out 'measures the host, NOT the model: not graded, no summary row'
    Check "a _CPUONLY_ transcript is kept"                       $r.CpuOnly 1
    Check "no run JSON"                                          ($null -eq $r.Json) "True"
    Check "no summary row"                                       $r.Rows 0

    Write-Host "   scenario: CPU-only with -NoGpuCheck"
    $r = Invoke-Harness (PsJson @((M $fxModel 38e9 0))) -NoGpuCheck
    Check "exit 0: graded as before"                             $r.Exit 0
    Check "never asked /api/ps"                                  $r.PsCalls 0
    Check "JSON gpuPlacement: not checked, and why"              ("{0} | {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.note) "False | not checked (-NoGpuCheck)"
    Lacks "console: no gpu placement line"                       $r.Out 'gpu placement'

    Write-Host "   scenario: the seat is not loaded any more"
    $r = Invoke-Harness (PsJson @((M "other:7b" 5e9 5e9)))
    Check "exit 0: graded"                                       $r.Exit 0
    Has   "console: a WARN, not a FAIL"                          $r.Out '\[WARN\]\s+gpu placement\s+->\s+fx-model:latest is not loaded on'
    Check "JSON: checked, verdict not-loaded"                    ("{0} {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.verdict) "True not-loaded"

    Write-Host "   scenario: /api/ps does not answer"
    $r = Invoke-Harness "THROW"
    Check "exit 0: graded"                                       $r.Exit 0
    Has   "console: a WARN"                                      $r.Out '\[WARN\]\s+gpu placement\s+->\s+.*api/ps did not answer'
    Check "JSON: not checked, verdict unchecked"                 ("{0} {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.verdict) "False unchecked"

    Write-Host "   scenario: a provider that is not Ollama"
    $r = Invoke-Harness (PsJson @((M $fxModel 38e9 0))) -Model "fixture/m"
    Check "exit 0: graded"                                       $r.Exit 0
    Check "never asked /api/ps"                                  $r.PsCalls 0
    Has   "JSON: not checked, and why"                           ("{0} | {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.note) 'False \| not checked \(fixture is not an Ollama provider\)'

    # --- end to end: the real batch ------------------------------------------
    Write-Host "-- end to end: the real run-tasks-batch.ps1, stand-in opencode, test-tasks.ps1 and Ollama"
    $tree = Join-Path $tmp "tree"
    $bin = Join-Path $tmp "bin"
    foreach ($d in "$tree\tests\tasks", "$tree\tests\results", "$tree\costs", $bin) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $BatchPath -Destination "$tree\tests\run-tasks-batch.ps1"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination "$tree\tests" -Recurse -Force
    Write-Fixture "$tree\tests\run-tasks-models.tsv" ("# fixture registry`ntag`thosts`tdesc`nqwen3:8b`tdesktop`tlocal seat`n")
    Write-Fixture "$tree\costs\go-rates.tsv" "model`tplan`ttier`tinputPerM`toutputPerM`tcacheReadPerM`tcacheWritePerM`tmonthlyLimitUsd`tchecked`tsource`n"
    Write-Fixture "$tree\tests\results\toolcalls-summary.tsv" "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail`n2026-10-06T09:00:00`tdesktop`t0.34.3`tqwen3:8b`tPASS`t10`tfixture`n"
    $bm = @{ tasks = @(foreach ($id in "fx-cpu", "t1", "t2", "t3") { [ordered]@{ id = $id; title = "fixture $id" } }) }
    Write-Fixture "$tree\tests\tasks\manifest.json" ($bm | ConvertTo-Json -Depth 5)
    # Stand-in test-tasks.ps1, naming files the way the real one does. fx-cpu
    # leaves a _CPUONLY_ transcript and exits 1; anything else is graded, exit 0.
    Write-Fixture "$tree\tests\test-tasks.ps1" @'
param([string[]]$Task, [string]$Model, [string]$ModelLabel, [int]$RunTimeout, [int]$CommandTimeout,
      [switch]$IncludeRetired, [string]$TaskManifest, [string]$ResultsDir)
$t = $Task[0]
Add-Content -LiteralPath $env:FIXTURE_CALLS -Value "$t|$Model"
$label = $ModelLabel -replace '[^a-zA-Z0-9._-]', '_'
$n = @(Get-ChildItem -LiteralPath $ResultsDir -File).Count
$stamp = "20261012-{0:D6}" -f $n
$enc = New-Object System.Text.UTF8Encoding $false
if ($t -eq 'fx-cpu') {
    [IO.File]::WriteAllText((Join-Path $ResultsDir ("tasks-{0}-{1}_CPUONLY_{2}.jsonl" -f $t, $label, $stamp)), "{}`n", $enc)
    Write-Host "  [FAIL] opencode run - fixture: the host was not using its GPU"
    exit 1
}
$base = Join-Path $ResultsDir ("tasks-{0}-{1}_{2}" -f $t, $label, $stamp)
[IO.File]::WriteAllText("$base.jsonl", "{}`n", $enc)
[IO.File]::WriteAllText("$base.json", ('{"taskId":"' + $t + '"}'), $enc)
exit 0
'@
    Write-Fixture "$bin\opencode.cmd" ((@'
@echo off
if "%~1"=="--version" goto version
if "%~1"=="debug" goto debug
exit /b 2
:version
echo 9.9.9
exit /b 0
:debug
echo {"autoupdate":"notify","provider":{"ollama-desktop":{"models":{"qwen3:8b":{}}}}}
exit /b 0
'@) -replace "`r?`n", "`r`n")
    Write-Fixture "$tmp\batch-driver.ps1" @'
param([string]$Script, [string]$ArgsFile)
function Invoke-RestMethod {
    param($Uri, $TimeoutSec)
    if ("$Uri" -match '/api/tags$') { return [pscustomobject]@{ models = @([pscustomobject]@{ name = "qwen3:8b" }) } }
    if ("$Uri" -match '/api/version$') { return [pscustomobject]@{ version = "0.34.3" } }
    throw "fixture: no endpoint $Uri"
}
$a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json
$splat = @{}
foreach ($p in $a.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [array]) { $splat[$p.Name] = [string[]]$v } else { $splat[$p.Name] = $v }
}
& $Script @splat
exit $LASTEXITCODE
'@
    $script:bscn = 0
    function Invoke-Batch([string[]]$Tasks) {
        $script:bscn++
        $rdir = Join-Path $tmp "batch-results-$($script:bscn)"
        New-Item -ItemType Directory -Path $rdir -Force | Out-Null
        $calls = Join-Path $tmp "batch-calls-$($script:bscn).txt"
        Write-Fixture $calls ""
        $all = @{ SkipSetup = $true; Mode = "Tasks"; Reps = 1; Yes = $true; ResultsDir = $rdir; Tasks = $Tasks; Models = @("ollama-desktop/qwen3:8b") }
        $argsFile = Join-Path $tmp "batch-args-$($script:bscn).json"
        Write-Fixture $argsFile ($all | ConvertTo-Json -Depth 4)
        $savedPath = $env:PATH
        $env:PATH = "$bin;$savedPath"
        $env:FIXTURE_CALLS = $calls
        $env:OLLAMA_DESKTOP_BASE_URL = "http://fixture.invalid:11434/v1"
        foreach ($v in "OLLAMA_NODE3_BASE_URL", "OLLAMA_SERVER_BASE_URL", "OPENCODE_SMALL_MODEL") { [Environment]::SetEnvironmentVariable($v, $null) }
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp "batch-driver.ps1") -Script "$tree\tests\run-tasks-batch.ps1" -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            $env:PATH = $savedPath
            Remove-Item Env:FIXTURE_CALLS, Env:OLLAMA_DESKTOP_BASE_URL -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{ Out = ($out -replace '\x1b\[[0-9;]*m', ''); Exit = $code
                           Calls = (@(Get-Content -LiteralPath $calls | Where-Object { $_ } | ForEach-Object { ($_ -split '\|')[0] }) -join ",") }
    }

    Write-Host "   scenario: the second of four runs finds the host CPU-only"
    $r = Invoke-Batch @("t1", "fx-cpu", "t2", "t3")
    Check "runs t1 and fx-cpu, then stops"                       $r.Calls "t1,fx-cpu"
    Check "exit 1"                                               $r.Exit 1
    Has   "the summary says the batch STOPPED"                   $r.Out '=== Batch STOPPED ==='
    Has   "...names the run and the reason"                      $r.Out 'run 2 of 4 \(fx-cpu x ollama-desktop/qwen3:8b\): Ollama had the seat entirely in system RAM after the run'
    Has   "...says how many were not started"                    $r.Out '2 run\(s\) not started'
    Has   "...and how to carry on"                               $r.Out 'then re-run the rest with -OnlyMissing'
    Write-Host "   scenario: no CPU-only run"
    $r = Invoke-Batch @("t1", "t2", "t3")
    Check "runs everything"                                      $r.Calls "t1,t2,t3"
    Check "exit 0"                                               $r.Exit 0
    Lacks "no STOPPED"                                           $r.Out 'Batch STOPPED'
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

# protects: GPU-placement check (CPU-only run = exit -5), runHost and phaseSeconds
# run-after: How a run's outcome is classified or the batch reacts to one
# test-gpu-placement.ps1 - regression guard for the GPU-placement check in
# test-tasks.ps1 (Get-EngineGpuPlacement in the llama.cpp adapter, exit -5,
# `-NoGpuCheck`) and the batch's reader of it (Get-CpuOnlyRun in run-tasks-batch.ps1).
#
# Why this exists: on 2026-10-12 the server's container lost its GPU after a
# systemd reload. The engine (Ollama then) kept answering from the CPU (qwen3.6 at
# 38 GB, 100% CPU), its model list stayed green, and a benchmark batch crawled for
# 31 minutes before anyone noticed. Nothing in a run looked wrong except its speed.
# After each run the harness now asks where the seat sits (llama.cpp: nvidia-smi
# and ps over ssh, LLAMACPP_<HOST>_SSH); loaded with none of it in VRAM is
# infrastructure (exit -5, a _CPUONLY_ transcript, no row), and the batch stops
# driving that host (the others carry on; tests/test-batch-engines.ps1).
#
# What it does:
#   1. Runs the REAL Get-CpuOnlyRun (with Get-ResultFileNames / Get-NewRunFiles)
#      on synthetic result folders: a _CPUONLY_ transcript left by this run, an
#      _INFRA_ one, one that was there before, another task's, another model's.
#   2. Runs the REAL test-tasks.ps1 end to end (private manifest, fixture repo,
#      stand-in opencode, a stand-in Invoke-RestMethod for llama-server and a
#      stand-in ssh first on PATH): a healthy run is graded and records
#      gpuPlacement, runHost and phaseSeconds; a CPU-only one is exit -5 with a
#      _CPUONLY_ transcript and no JSON and no row; -NoGpuCheck grades it and never
#      asks; not loaded and ssh failing are graded with a WARN; a hosted provider is
#      graded and never asked; a llama.cpp provider whose base URL is unset says so.
#   The llama.cpp placement function itself (rewritten ids, the CPU-pinned seat,
#   several seats) is unit-tested in tests/test-engine-adapter.ps1. Ollama's
#   /api/ps scenarios went with Ollama on 2026-11-21.
# Exit 1 on any failure. A control: pass -ScriptPath / -BatchPath a copy with the
# check removed and the matching scenarios fail.
#
# Windows stand-ins, like the neighbouring guards (.cmd for opencode and ssh).
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

try {
    Write-Host "-- Get-CpuOnlyRun (real function, synthetic result folders)"
    $rd = Join-Path $tmp "synthetic"
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    $before = Get-ResultFileNames -Dir $rd
    $label = "llamacpp-server_qwen3.6_35b-a3b-coding"
    Write-Fixture (Join-Path $rd "tasks-t1-${label}_CPUONLY_20261012-120000.jsonl") "{}"
    Check "a _CPUONLY_ transcript this run left"                 (Get-CpuOnlyRun -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "llamacpp-server/qwen3.6:35b-a3b-coding") "tasks-t1-${label}_CPUONLY_20261012-120000.jsonl"
    Check "...not for another task"                              ($null -eq (Get-CpuOnlyRun -ResultsDir $rd -Before $before -TaskId "t2" -ModelLabel "llamacpp-server/qwen3.6:35b-a3b-coding")) "True"
    Check "...not for another model"                             ($null -eq (Get-CpuOnlyRun -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "llamacpp-server/qwen3:8b")) "True"
    $after = Get-ResultFileNames -Dir $rd
    Check "one that was there before the run: none"              ($null -eq (Get-CpuOnlyRun -ResultsDir $rd -Before $after -TaskId "t1" -ModelLabel "llamacpp-server/qwen3.6:35b-a3b-coding")) "True"
    $rd2 = Join-Path $tmp "synthetic2"
    New-Item -ItemType Directory -Path $rd2 -Force | Out-Null
    $b2 = Get-ResultFileNames -Dir $rd2
    Write-Fixture (Join-Path $rd2 "tasks-t1-${label}_INFRA_20261012-120000.jsonl") "{}"
    Write-Fixture (Join-Path $rd2 "tasks-t1-${label}_20261012-120100.json") "{}"
    Check "an _INFRA_ transcript and a graded run: none"         ($null -eq (Get-CpuOnlyRun -ResultsDir $rd2 -Before $b2 -TaskId "t1" -ModelLabel "llamacpp-server/qwen3.6:35b-a3b-coding")) "True"
    Check "a results folder that does not exist: none"           ($null -eq (Get-CpuOnlyRun -ResultsDir (Join-Path $tmp "nope") -Before @{} -TaskId "t1" -ModelLabel "x")) "True"

    # --- end to end: the real test-tasks.ps1 ---------------------------------
    Write-Host "-- end to end: the real test-tasks.ps1, a private manifest, a stand-in opencode, llama-server and ssh"
    $psExe = (Get-Process -Id $PID).Path
    # Stand-in ssh: logs its arguments, answers nvidia-smi / ps from files, exits with exit.txt.
    $sshDir = Join-Path $tmp "ssh"; $sshBin = Join-Path $sshDir "bin"
    New-Item -ItemType Directory -Path $sshBin -Force | Out-Null
    @'
$line = ($args -join ' ')
Add-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'calls.txt') -Value $line
$code = [int](Get-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'exit.txt') -Raw).Trim()
if ($code -ne 0) { [Console]::Error.WriteLine('ssh: connect to host fixture port 22: Connection timed out'); exit $code }
if ($line -match 'nvidia-smi') { Get-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'smi.txt') }
elseif ($line -match '\bps\b') { Get-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'ps.txt') }
exit 0
'@ | Set-Content -LiteralPath (Join-Path $sshBin "ssh-standin.ps1")
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$sshBin\ssh-standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $sshBin "ssh.cmd") -Encoding ascii
    function Set-Ssh([string]$Smi, [string]$Ps, [int]$Exit = 0) {
        Write-Fixture (Join-Path $sshDir "smi.txt") $Smi
        Write-Fixture (Join-Path $sshDir "ps.txt") $Ps
        Write-Fixture (Join-Path $sshDir "exit.txt") "$Exit"
        Write-Fixture (Join-Path $sshDir "calls.txt") ""
    }
    function Get-SshCalls { @(Get-Content -LiteralPath (Join-Path $sshDir "calls.txt") | Where-Object { $_ }).Count }
    # The router and the seat's child (its --alias is the tag); a CPU-pinned seat beside it.
    $psSeat = "  100 /app/llama-server --models-preset /config/models.ini --port 8090`n" +
              "  4242 /app/llama-server --port 5001 --alias fx-model --ctx-size 65536`n" +
              "  4343 /app/llama-server --port 5002 --alias qwen2.5-coder-3b-cpu --device none`n"
    $h = Join-Path $tmp "h"
    $priv = Join-Path $tmp "priv"
    $repo = Join-Path $tmp "repo"
    foreach ($d in @("$h/tests/tasks", "$h/bin", "$priv/hidden/fx", $repo)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $h "tests/test-tasks.ps1")
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $h "tests") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $h "tests") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "checks") -Destination (Join-Path $h "tests") -Recurse -Force
    '{"tasks":[]}' | Set-Content -LiteralPath (Join-Path $h "tests/tasks/manifest.json")
    Set-Content -LiteralPath (Join-Path $priv "hidden/fx/hidden.txt") -Value "hidden test"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
Start-Sleep -Milliseconds 700   # a known cost, so phaseSeconds can be checked against it
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
    # Invoke-RestMethod for llama-server (build, served context, model list).
    Write-Fixture "$tmp/driver.ps1" @'
param([string]$Script, [string]$ArgsFile)
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType, $Headers)
    $u = "$Uri"
    if ($u -match '/props\?model=fx-model&autoload=false$') { return [pscustomobject]@{ default_generation_settings = [pscustomobject]@{ n_ctx = 65536 } } }
    if ($u -match '/props$') { return [pscustomobject]@{ build_info = 'b11561-abcdef0' } }
    if ($u -match '/models$') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 'fx-model'; aliases = @() }) } }
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
    $script:scn = 0
    function Invoke-Harness([string]$Smi, [string]$Ps, [int]$SshExit = 0, [string]$Model = "llamacpp-server/fx-model", [switch]$NoGpuCheck, [switch]$NoBaseUrl) {
        $script:scn++
        $rdir = Join-Path $priv "results-$($script:scn)"
        Set-Ssh $Smi $Ps $SshExit
        $argv = @{
            Task = @("fx-fix"); Model = $Model; SkipInstall = $true; RunTimeout = 120
            TaskManifest = (Join-Path $priv "manifest.json"); ResultsDir = $rdir
        }
        if ($NoGpuCheck) { $argv.NoGpuCheck = $true }
        $argsFile = Join-Path $tmp "args-$($script:scn).json"
        Write-Fixture $argsFile ($argv | ConvertTo-Json -Depth 4)
        $savedPath = $env:PATH
        $savedSsh = $env:LLAMACPP_SERVER_SSH
        $env:PATH = "$(Join-Path $h 'bin');$sshBin;$savedPath"
        if ($NoBaseUrl) { Remove-Item Env:LLAMACPP_SERVER_BASE_URL -ErrorAction SilentlyContinue }
        else { $env:LLAMACPP_SERVER_BASE_URL = "http://fixture.invalid:8090/v1" }
        $env:LLAMACPP_SERVER_SSH = "server"
        $env:FIXTURE_SSH_DIR = $sshDir
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp "driver.ps1") -Script $tt -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            $env:PATH = $savedPath
            Remove-Item Env:LLAMACPP_SERVER_BASE_URL, Env:FIXTURE_SSH_DIR -ErrorAction SilentlyContinue
            $env:LLAMACPP_SERVER_SSH = $savedSsh
        }
        $json = @(Get-ChildItem -LiteralPath $rdir -Filter "tasks-fx-fix-*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '_(INFRA|TIMEOUT|TRUNCATED|CPUONLY)_' })
        $tsv = Join-Path $rdir "real-tasks-summary.tsv"
        [pscustomobject]@{
            Out = ($out -replace '\x1b\[[0-9;]*m', ''); Exit = $code
            Json = $(if ($json.Count) { Get-Content -LiteralPath $json[0].FullName -Raw | ConvertFrom-Json } else { $null })
            Rows = $(if (Test-Path -LiteralPath $tsv) { @(Get-Content -LiteralPath $tsv | Select-Object -Skip 1 | Where-Object { $_ }).Count } else { 0 })
            CpuOnly = @(Get-ChildItem -LiteralPath $rdir -Filter "*_CPUONLY_*.jsonl" -ErrorAction SilentlyContinue).Count
            SshCalls = Get-SshCalls
        }
    }

    Write-Host "   scenario: healthy (the seat's process holds 12960 MiB on the GPU)"
    $r = Invoke-Harness "4242, 12960 MiB`n4343, 0 MiB`n" $psSeat
    Check "exit 0"                                               $r.Exit 0
    Has   "console: a gpu placement PASS with the VRAM"          $r.Out '\[PASS\]\s+gpu placement\s+->\s+fx-model: 13\.59 GB in VRAM \(nvidia-smi on server, pid 4242\)'
    Check "graded: one row"                                      $r.Rows 1
    Check "JSON gpuPlacement: checked, verdict gpu"              ("{0} {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.verdict) "True gpu"
    Check "...13.59 GB in VRAM; total and share unknown on llama.cpp" ("{0} [{1}] [{2}]" -f $r.Json.gpuPlacement.vramGB, $r.Json.gpuPlacement.totalGB, $r.Json.gpuPlacement.share) "13.59 [] []"
    Check "asked over ssh: nvidia-smi and ps"                    $r.SshCalls 2
    # Not about the GPU, but this is the guard that already runs the real harness end to end.
    Check "JSON runHost: this machine's name and its logical processors" ("{0} {1}" -f $r.Json.runHost.name, ($r.Json.runHost.logicalProcessors -eq [Environment]::ProcessorCount)) ("{0} True" -f [Environment]::MachineName)
    $ph = $r.Json.phaseSeconds
    Check "JSON phaseSeconds: baseline, suite and acceptance each ran the 0.7 s test command (>= 0.6 s)" ((@($ph.baseline, $ph.suite, $ph.acceptance) | Where-Object { $null -ne $_ -and $_ -ge 0.6 }).Count) 3
    Check "...and none of them is absurd (< 60 s)"                (((@($ph.baseline, $ph.suite, $ph.acceptance) | Where-Object { $null -ne $_ -and $_ -lt 60 }).Count)) 3
    Check "...install, setup and typecheck did not run here: present and null" ("{0}|{1}|{2}" -f ($null -ne $ph -and $ph.PSObject.Properties["install"] -and $null -eq $ph.install), ($null -ne $ph -and $ph.PSObject.Properties["setup"] -and $null -eq $ph.setup), ($null -ne $ph -and $ph.PSObject.Properties["typecheck"] -and $null -eq $ph.typecheck)) "True|True|True"
    $cimCpu = try { @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0].Name } catch { $null }
    Check "...and its CPU model (as Win32_Processor names it, when the machine has one)" $(if ($cimCpu) { "$($r.Json.runHost.cpu)" -eq (($cimCpu -replace '\s+', ' ').Trim()) } else { $true }) "True"

    Write-Host "   scenario: CPU-only (the seat is loaded, its process is not on the GPU)"
    $r = Invoke-Harness "4343, 300 MiB`n" $psSeat
    Check "exit 1 (the run FAILed as infrastructure)"            $r.Exit 1
    Has   "console: the FAIL says the seat runs on the CPU"      $r.Out 'fx-model \(pid 4242\) is not among the GPU compute processes on server: it runs on the CPU'
    Has   "...and that it measures the host, not the model"      $r.Out 'measures the host, NOT the model: not graded, no summary row'
    Check "a _CPUONLY_ transcript is kept"                       $r.CpuOnly 1
    Check "no run JSON"                                          ($null -eq $r.Json) "True"
    Check "no summary row"                                       $r.Rows 0

    Write-Host "   scenario: CPU-only with -NoGpuCheck"
    $r = Invoke-Harness "" $psSeat -NoGpuCheck
    Check "exit 0: graded as before"                             $r.Exit 0
    Check "never asked over ssh"                                 $r.SshCalls 0
    Check "JSON gpuPlacement: not checked, and why"              ("{0} | {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.note) "False | not checked (-NoGpuCheck)"
    Lacks "console: no gpu placement line"                       $r.Out 'gpu placement'

    Write-Host "   scenario: the seat is not loaded any more"
    $r = Invoke-Harness "4343, 300 MiB`n" "  100 /app/llama-server --models-preset /config/models.ini --port 8090`n  4343 /app/llama-server --port 5002 --alias qwen2.5-coder-3b-cpu --device none`n"
    Check "exit 0: graded"                                       $r.Exit 0
    Has   "console: a WARN, not a FAIL"                          $r.Out '\[WARN\]\s+gpu placement\s+->\s+fx-model is not loaded on server'
    Check "JSON: checked, verdict not-loaded"                    ("{0} {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.verdict) "True not-loaded"

    Write-Host "   scenario: ssh to the host fails"
    $r = Invoke-Harness "" "" 255
    Check "exit 0: graded"                                       $r.Exit 0
    Has   "console: a WARN naming the failed ssh"                $r.Out '\[WARN\]\s+gpu placement\s+->\s+ssh server nvidia-smi failed \(exit 255\)'
    Check "JSON: not checked, verdict unchecked"                 ("{0} {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.verdict) "False unchecked"

    Write-Host "   scenario: a provider that is not llama.cpp (a hosted one)"
    $r = Invoke-Harness "" $psSeat -Model "opencode-go/m"
    Check "exit 0: graded"                                       $r.Exit 0
    Check "never asked over ssh"                                 $r.SshCalls 0
    Has   "JSON: not checked, and why"                           ("{0} | {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.note) 'False \| not checked \(opencode-go is not a llama\.cpp provider\)'

    Write-Host "   scenario: a llama.cpp provider whose base URL is unset"
    $r = Invoke-Harness "" $psSeat -NoBaseUrl
    Check "exit 0: graded"                                       $r.Exit 0
    Check "never asked over ssh"                                 $r.SshCalls 0
    Has   "JSON: not checked, and the note names the unset variable" ("{0} | {1}" -f $r.Json.gpuPlacement.checked, $r.Json.gpuPlacement.note) 'False \| not checked \(LLAMACPP_SERVER_BASE_URL is unset\)'
    Lacks "...and does not call it a non-llama.cpp provider"     ("$($r.Json.gpuPlacement.note)") 'not a llama\.cpp provider'
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

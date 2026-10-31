# run-planner.ps1 - experiment 3's planner step, in a container (docs/planner-tests-experiment.md, "The planner").
#
# One throwaway container per (task, run): Claude Code reads the task's request and a sealed copy of its repository
# (a git bundle of the base commit and its history, nothing later) and writes acceptance tests, without the hidden
# tests, the fix or any earlier run. The container is on an internal network whose only exit is a proxy that
# answers for api.anthropic.com and registry.npmjs.org (desktop/docker/planner/squid.conf); the task repos are public,
# so GitHub is unreachable by construction, not by request. CPU only: the desktop's .wslconfig has gpuSupport=false.
#
# The token is the one secret. It is read from -TokenFile (default ~/.config/planner/token, outside every repo),
# handed to the container through this process's environment (never on a command line, never in the image) and cleared
# when the script ends. Nothing else is mounted: the pack read-only, one output folder.
#
#   .\desktop\scripts\run-planner.ps1 -Pack <planner-packs folder> -Out <output folder> -Run 1 [-Tasks real-01,wp-5b] [-Model <id>]
#   .\desktop\scripts\run-planner.ps1 ... -Probe     # check the token and the allowlist, run no planner
#
# Output: <Out>\run<N>\planner\<task>\<N>\ (the test files and NOTES.md), plus <Out>\run<N>\<task>.json (the session's
# result and usage) and <Out>\run<N>\meta.json (image, Claude Code version, prompt hash).
param(
    [Parameter(Mandatory)][string]$Pack,
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][ValidateRange(1, 99)][int]$Run,
    [string[]]$Tasks = @(),
    [string]$Model = "",
    [string]$TokenFile = (Join-Path $HOME ".config\planner\token"),
    [int]$MaxMinutes = 45,
    [string]$Memory = "4g",
    [string]$Cpus = "4",
    [switch]$Probe
)
$ErrorActionPreference = "Stop"
$image = "planner-claude:1"
$net = "planner-net"

if (-not (Get-Process -Name "com.docker.backend" -ErrorAction SilentlyContinue)) { Write-Host "ERROR: Docker Desktop is not running" -ForegroundColor Red; exit 1 }
& docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: image $image is missing (docker build -f desktop/docker/planner/planner.dockerfile -t $image desktop/docker/planner)" -ForegroundColor Red; exit 1 }
$proxy = (& docker inspect -f "{{.State.Running}}" planner-proxy 2>$null)
if ($proxy -ne "true") { Write-Host "ERROR: planner-proxy is not running (docker compose -f desktop/docker/planner/docker-compose.yml up -d)" -ForegroundColor Red; exit 1 }
if (-not (Test-Path -LiteralPath $TokenFile)) { Write-Host "ERROR: no token file at $TokenFile" -ForegroundColor Red; exit 1 }
$token = (Get-Content -Raw -LiteralPath $TokenFile).Trim()
if (-not $token) { Write-Host "ERROR: $TokenFile is empty (run 'claude setup-token' and paste the token into it)" -ForegroundColor Red; exit 1 }
$Pack = (Resolve-Path -LiteralPath $Pack).Path
$promptFile = Join-Path $Pack "PROMPT.md"
if (-not (Test-Path -LiteralPath $promptFile)) { Write-Host "ERROR: $promptFile is missing" -ForegroundColor Red; exit 1 }
$ids = if ($Tasks.Count) { @($Tasks | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @(Get-ChildItem (Join-Path $Pack "tasks") -Directory | ForEach-Object Name) }
foreach ($id in $ids) { if (-not (Test-Path -LiteralPath (Join-Path $Pack "tasks\$id\base.bundle"))) { Write-Host "ERROR: no pack for task $id" -ForegroundColor Red; exit 1 } }

$runDir = Join-Path $Out "run$Run"
New-Item -ItemType Directory -Force $runDir | Out-Null
$runDir = (Resolve-Path -LiteralPath $runDir).Path
$promptHash = (Get-FileHash -LiteralPath $promptFile -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
$ccVersion = (& docker run --rm --network none $image claude --version 2>&1 | Select-Object -First 1)
[pscustomobject]@{ image = $image; imageId = (& docker image inspect -f "{{.Id}}" $image); claudeCode = "$ccVersion"; model = $(if ($Model) { $Model } else { "default" }); promptSha256 = $promptHash; run = $Run; tasks = $ids; started = (Get-Date -Format o) } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir "meta.json")

$env:CLAUDE_CODE_OAUTH_TOKEN = $token
try {
    if ($Probe) {
        Write-Host "probe: claude -p through the proxy"
        & docker run --rm --network $net -e CLAUDE_CODE_OAUTH_TOKEN --memory 1g $image claude -p "Reply with exactly: OK" --output-format json 2>&1 | Select-Object -Last 3
        exit $LASTEXITCODE
    }
    $failed = 0
    foreach ($id in $ids) {
        $work = Join-Path $runDir "work-$id"
        New-Item -ItemType Directory -Force $work | Out-Null
        $task = "Plan the acceptance tests for task '$id', planner run $Run. Follow /pack/PROMPT.md, with <id> = $id and <run> = $Run."
        $args = @("run", "--rm", "--name", "planner-$id-$Run", "--network", $net, "-e", "CLAUDE_CODE_OAUTH_TOKEN",
            "--memory", $Memory, "--cpus", $Cpus, "--pids-limit", "1024", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
            "-v", "${Pack}:/pack:ro", "-v", "${work}:/workspace", "-w", "/workspace", $image,
            "claude", "-p", $task, "--dangerously-skip-permissions", "--output-format", "json",
            # WebSearch runs on Anthropic's side through api.anthropic.com, which the proxy must allow, so the proxy
            # cannot stop it: switch the web tools off here (WebFetch would be stopped by the proxy anyway).
            "--disallowedTools", "WebSearch", "WebFetch")
        if ($Model) { $args += @("--model", $Model) }
        Write-Host ("[{0}] planner run {1}, task {2}" -f (Get-Date -Format "HH:mm:ss"), $Run, $id)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $job = Start-Job -ScriptBlock { param($a) & docker @a 2>&1 } -ArgumentList (, $args)
        if (-not (Wait-Job $job -Timeout ($MaxMinutes * 60))) {
            Write-Host "  timeout after $MaxMinutes min: stopping the container" -ForegroundColor Yellow
            & docker rm -f "planner-$id-$Run" *> $null
            Stop-Job $job
        }
        $text = (Receive-Job $job 2>&1 | Out-String); Remove-Job $job -Force
        Set-Content -LiteralPath (Join-Path $runDir "$id.json") -Value $text
        $outDir = Join-Path $work "planner\$id\$Run"
        $files = if (Test-Path $outDir) { @(Get-ChildItem $outDir -Recurse -File) } else { @() }
        $tests = @($files | Where-Object { $_.Name -ne "NOTES.md" })
        if ($tests.Count -eq 0) { $failed++; Write-Host ("  no test files written ({0:N0} s)" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Red }
        else { Write-Host ("  {0} test file(s) + notes in {1:N0} s" -f $tests.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor Green }
    }
    exit $(if ($failed) { 1 } else { 0 })
}
finally {
    Remove-Item Env:CLAUDE_CODE_OAUTH_TOKEN -ErrorAction SilentlyContinue
    $token = $null
}

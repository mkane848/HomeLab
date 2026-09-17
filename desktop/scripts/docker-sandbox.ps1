# docker-sandbox.ps1 - spin up a disposable scratch container for quick
# experiments (runtime test, CLI probe, DB one-liner). CPU-only by design
# (gpuSupport=false in .wslconfig). Nothing persists: --rm + ephemeral.
#
# Usage:
#   .\desktop\scripts\docker-sandbox.ps1                                # default dev-base:1, echo
#   .\desktop\scripts\docker-sandbox.ps1 -Command "node -v && python3 -V"
#   .\desktop\scripts\docker-sandbox.ps1 -Image python:3.12 -Command "python --version"
#   .\desktop\scripts\docker-sandbox.ps1 -Work "M:\Projects\LFCbot" -Interactive
#   .\desktop\scripts\docker-sandbox.ps1 -Image redis:7-alpine -Command "redis-cli ping" -HostNetwork
#
# Security: only the explicitly requested host (or a temp) directory is
# mounted; containers get a memory/CPU cap so a runaway sandbox can't starve
# host Ollama; never mount ~/.config/opencode/.secrets or other sensitive dirs.

param(
    [string]$Image = "dev-base:1",
    [string]$Work = "",
    [string]$Command = 'echo sandbox up: $(uname -m)',
    [string]$Memory = "1g",
    [int]$Cpus = 2,
    [switch]$Interactive,
    [switch]$HostNetwork
)

$ErrorActionPreference = "Continue"

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "[docker-sandbox] ERROR: docker not found in PATH - is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

$mountArgs = @()
if ($Work) {
    $resolved = [System.IO.Path]::GetFullPath($Work)
    if (-not (Test-Path -LiteralPath $resolved)) {
        Write-Host "[docker-sandbox] Work dir '$resolved' not found - starting without a mount" -ForegroundColor Yellow
    } else {
        $mountArgs = @("-v", "${resolved}:/workspace", "-w", "/workspace")
    }
}

# Standardize on the image's POSIX shell so commands run identically on
# debian-based (dev-base, node, python - which lack bash) and alpine images.
$execArgs = @()
$execArgs += @("run", "--rm", "--memory", $Memory, "--cpus", $Cpus)
if ($HostNetwork) { $execArgs += @("--network", "host") }

if ($Interactive) {
    $execArgs += "-it"
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $Command = ""
    } else {
        $Command = "$Command; exec sh"
    }
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Host "[docker-sandbox] interactive shell in $Image (exit to destroy)..." -ForegroundColor Cyan
    & docker @execArgs @mountArgs $Image "sh"
} else {
    & docker @execArgs @mountArgs $Image "sh" "-lc" $Command
}

exit $LASTEXITCODE
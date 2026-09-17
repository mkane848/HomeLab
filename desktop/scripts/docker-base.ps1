# docker-base.ps1 - build and tag the shared dev base image used by the desktop
# devcontainers and sandbox templates. CPU-only image (see dev/docker/dev.dockerfile
# for the gpuSupport=false rationale).
#
#   .\desktop\scripts\docker-base.ps1            # build + tag dev-base:1 (if missing)
#   .\desktop\scripts\docker-base.ps1 -Force     # rebuild unconditionally

param(
    [string]$Tag = "dev-base:1",
    [switch]$Force
)

$ErrorActionPreference = "Continue"

$dockerfile = Join-Path $PSScriptRoot "..\..\dev\docker\dev.dockerfile"
if (-not (Test-Path -LiteralPath $dockerfile)) {
    Write-Host "[docker-base] ERROR: $dockerfile not found" -ForegroundColor Red
    exit 1
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "[docker-base] ERROR: docker not found in PATH - is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

& docker image inspect $Tag *> $null
if ($LASTEXITCODE -eq 0 -and -not $Force) {
    Write-Host "[docker-base] $Tag already built (use -Force to rebuild)" -ForegroundColor Green
    exit 0
}

Write-Host "[docker-base] building $Tag ..." -ForegroundColor Cyan
& docker build -t $Tag -f $dockerfile (Split-Path $dockerfile)
exit $LASTEXITCODE
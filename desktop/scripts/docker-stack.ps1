# docker-stack.ps1 - manage the desktop local dev services (Postgres + Redis) in
# desktop/docker/docker-compose.yml. CPU-only services - see the compose file
# header for the gpuSupport=false rationale.
#
# Usage:
#   .\desktop\scripts\docker-stack.ps1 up        # start (pulls images on first run)
#   .\desktop\scripts\docker-stack.ps1 status    # show containers + health
#   .\desktop\scripts\docker-stack.ps1 ps        # alias of status
#   .\desktop\scripts\docker-stack.ps1 logs      # tail logs
#   .\desktop\scripts\docker-stack.ps1 restart   # restart services
#   .\desktop\scripts\docker-stack.ps1 down      # stop + remove containers
#
# Values come from desktop/docker/.env (compose loads it automatically).

param(
    [Parameter(Position = 0)]
    [ValidateSet("up", "down", "ps", "status", "logs", "restart")]
    [string]$Action = "status"
)

$ErrorActionPreference = "Continue"

$composeFile = Join-Path $PSScriptRoot "..\docker\docker-compose.yml"
if (-not (Test-Path -LiteralPath $composeFile)) {
    Write-Host "[docker-stack] ERROR: $composeFile not found" -ForegroundColor Red
    exit 1
}

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "[docker-stack] ERROR: docker not found in PATH - is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

Write-Host "[docker-stack] $Action -> $composeFile" -ForegroundColor Cyan

switch ($Action) {
    "up" {
        & docker compose -f $composeFile up -d
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[docker-stack] up failed. Check desktop/docker/.env exists and POSTGRES_PASSWORD is set." -ForegroundColor Red
            exit $LASTEXITCODE
        }
        & docker compose -f $composeFile ps
    }
    "down"  { & docker compose -f $composeFile down }
    "restart" { & docker compose -f $composeFile restart }
    "logs"  { & docker compose -f $composeFile logs --tail 100 -f }
    default { & docker compose -f $composeFile ps }
}

exit $LASTEXITCODE
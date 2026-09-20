# startup.ps1 - Start desktop Ollama and bake each managed model's served context

param(
    [switch]$Force,
    [int]$ContextLength = 16384
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=== Desktop Startup ===" -ForegroundColor Cyan
Write-Host ""

# Check if profile tier is enabled
if ($env:DEV_TIERS_DESKTOP -eq "false") {
    Write-Host "[startup] Desktop tier disabled by profile, skipping." -ForegroundColor Yellow
    exit 0
}

# Check if Ollama is installed
$ollamaPath = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaPath) {
    Write-Host "[startup] ERROR: Ollama not found in PATH." -ForegroundColor Red
    Write-Host "  Install from: https://ollama.com/download" -ForegroundColor Gray
    exit 1
}

# Context must be raised SERVER-side, not just in the OpenCode config: a client
# that promises more than the host serves gets its prompt truncated and loses
# its system prompt (see docs/troubleshooting.md).
#
# This env var is the GLOBAL default for any tag we do not bake below. As of
# Ollama 0.34.0 it IS honoured on Windows - the serve-log env map shows the
# value we set, and qwen3:8b (unbaked) serves at it. The old v0.32 bug where
# the app reported OLLAMA_CONTEXT_LENGTH:0 is fixed.
$env:OLLAMA_CONTEXT_LENGTH = "$ContextLength"

# Check if Ollama is already running
$ollamaProcess = Get-Process ollama -ErrorAction SilentlyContinue
if ($ollamaProcess -and -not $Force) {
    Write-Host "[startup] Ollama is already running (PID: $($ollamaProcess.Id))" -ForegroundColor Yellow
    Write-Host "  Use -Force to restart it. Baking below still runs either way." -ForegroundColor Gray
} else {
    if ($ollamaProcess) {
        Write-Host "[startup] Stopping existing Ollama to apply context $($ContextLength)..."
        Stop-Process -Id $ollamaProcess.Id -Force
        Start-Sleep -Seconds 2
    }
    Write-Host "[startup] Starting Ollama (OLLAMA_CONTEXT_LENGTH=$($ContextLength))..."
    Start-Process ollama -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 3
}

# Verify API is responding
Write-Host "[startup] Checking Ollama API..."
try {
    $response = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 5
    Write-Host "[startup] Ollama API is UP" -ForegroundColor Green
    Write-Host ""
    Write-Host "Available models:"
    $response.models | ForEach-Object { Write-Host "  - $($_.name)" }
} catch {
    Write-Host "[startup] WARNING: Ollama API not responding yet." -ForegroundColor Yellow
    Write-Host "  It may still be starting. Wait a moment and check status." -ForegroundColor Gray
}

# Pull the context models if not present and bake each one's served context.
#
# NOTE (Ollama 0.34.0): OLLAMA_CONTEXT_LENGTH *is* honoured by the Windows app
# now - the serve-log env map shows the value we set, and qwen3:8b (no bake)
# serves at it. The old "the app zeroes it" workaround is obsolete. Baking is
# still what we do, but for a different and better reason: the env var is a
# single GLOBAL default, and we need PER-MODEL context. The qwen3 seats and the
# 14b coder want 32k; the small/companion models must stay at 16k or
# their KV cache evicts the main model from VRAM.
#
# Per entry:
#   Ctx     - num_ctx baked into the base tag itself (any client using that
#             name gets this context)
#   Aliases - extra context values to publish as derived <name>-<N>k tags
#
# -ContextLength overrides every Ctx and alias when passed explicitly, so the
# documented `.\startup.ps1 -Force -ContextLength 16384` still works.
# The qwen3 pair carries the agent seats and needs 32k: the system prompt plus
# tool schemas measured 11,441 tokens, so a 16k window leaves only ~850 tokens
# of actual working room once output is reserved. At 32k that becomes ~17,200.
# Measured at 32k, both stay 100% on GPU: qwen3:14b = 11.03 GB @ 48.9 tok/s,
# qwen3:8b = 7.16 GB @ 79.8 tok/s.
$contextModels = @(
    @{ Base = "qwen3:14b";         Ctx = 32768; Aliases = @()             }
    @{ Base = "qwen3:8b";          Ctx = 32768; Aliases = @()             }
    @{ Base = "qwen2.5-coder:3b";  Ctx = 16384; Aliases = @()             }
    @{ Base = "deepseek-r1:14b";   Ctx = 16384; Aliases = @(16384, 32768) }
    @{ Base = "qwen2.5-coder:7b";  Ctx = 16384; Aliases = @(16384)        }
    @{ Base = "qwen2.5-coder:14b"; Ctx = 32768; Aliases = @()             }
)

$ctxOverride = $PSBoundParameters.ContainsKey('ContextLength')
if ($ctxOverride) {
    Write-Host "[startup] -ContextLength $ContextLength overrides every per-model context" -ForegroundColor Yellow
}

$tags = (Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 5).models

# `ollama pull` and `ollama create` write progress to stderr, which under
# $ErrorActionPreference = "Stop" becomes a terminating error (AGENTS.md
# gotcha). Drop to Continue for the whole bake loop and restore afterwards.
$savedEapBake = $ErrorActionPreference
$ErrorActionPreference = "Continue"

foreach ($m in $contextModels) {
    if (-not ($tags | Where-Object { $_.name -eq $m.Base })) {
        Write-Host ""
        Write-Host "[startup] $($m.Base) not found. Pulling now..." -ForegroundColor Yellow
        Write-Host "  This may take a while on first run." -ForegroundColor Gray
        & ollama pull $m.Base
    }

    $shortName = $m.Base.Split(':')[0]
    $baseCtx   = if ($ctxOverride) { $ContextLength } else { $m.Ctx }
    $aliasCtxs = if ($ctxOverride) { @($ContextLength) } else { $m.Aliases }

    Write-Host ""
    Write-Host "[startup] Baking num_ctx=$baseCtx into $($m.Base)..." -ForegroundColor Cyan
    $mf = Join-Path $env:TEMP "Modelfile-context-$shortName"
    Set-Content -LiteralPath $mf -Value "FROM $($m.Base)`nPARAMETER num_ctx $baseCtx" -Encoding ascii
    & ollama create $m.Base -f $mf | Out-Null

    foreach ($aliasCtx in $aliasCtxs) {
        $ctxModel = "$shortName-$([math]::Round($aliasCtx / 1024))k"
        Write-Host "[startup]   + alias $ctxModel (num_ctx=$aliasCtx)" -ForegroundColor Cyan
        Set-Content -LiteralPath $mf -Value "FROM $($m.Base)`nPARAMETER num_ctx $aliasCtx" -Encoding ascii
        & ollama create $ctxModel -f $mf | Out-Null
    }

    Remove-Item -LiteralPath $mf -Force
}

$ErrorActionPreference = $savedEapBake

Write-Host ""
Write-Host "[startup] Context contract (must match opencode.jsonc limit.context):" -ForegroundColor Cyan
foreach ($m in $contextModels) {
    $shortName = $m.Base.Split(':')[0]
    $baseCtx   = if ($ctxOverride) { $ContextLength } else { $m.Ctx }
    $aliasCtxs = if ($ctxOverride) { @($ContextLength) } else { $m.Aliases }
    $aliasList = ($aliasCtxs | ForEach-Object { "$shortName-$([math]::Round($_ / 1024))k@$_" }) -join ', '
    Write-Host ("  {0,-22} {1}{2}" -f $m.Base, $baseCtx, $(if ($aliasList) { "  ($aliasList)" } else { "" }))
}
Write-Host "[startup] Desktop ready." -ForegroundColor Green

# Optional local dev stack (Postgres + Redis) via Docker Desktop. Controlled by
# DEV_DOCKER_STACK in the active profile (dev-workflow-quality sets it true).
# CPU-only services - see desktop/docker/docker-compose.yml. Native stderr on
# docker under $ErrorActionPreference=Stop becomes a terminating error, so drop
# to Continue around the calls (AGENTS.md gotcha) and restore after.
if ($env:DEV_DOCKER_STACK -eq "true") {
    $composeFile = Join-Path $PSScriptRoot "..\docker\docker-compose.yml"
    if (Test-Path -LiteralPath $composeFile) {
        Write-Host ""
        Write-Host "[startup] DEV_DOCKER_STACK=true - starting local dev services..."
        $savedEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        docker compose -f $composeFile up -d
        docker compose -f $composeFile ps
        $ErrorActionPreference = $savedEap
    } else {
        Write-Host "[startup] DEV_DOCKER_STACK=true but $composeFile missing" -ForegroundColor Yellow
    }
}

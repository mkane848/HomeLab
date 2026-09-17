# sync-opencode.ps1 — Push your OpenCode config + secrets to the Ubuntu server.
#
# Copies from:  C:\Users\<you>\.config\opencode\
#   to:         ~/.config/opencode/ on SERVER_IP (from dev-docs\.env)
#
# What it transfers:
#   - opencode.jsonc            (providers + MCP servers)
#   - agents/*.md               (custom subagents)
#   - commands/*.md             (custom commands)
#   - .secrets/                 (all API keys/PATs)
# And pre-creates on the server (empty, ready for use):
#   - skills/ agents/ commands/ plugins/ themes/
#
# Usage:
#   .\desktop\scripts\sync-opencode.ps1 -Template   # stage repo template into
#                                                   # ~/.config/opencode first
#   .\desktop\scripts\sync-opencode.ps1             # push live local config
#
# The repo template lives at opencode/global/opencode.jsonc plus
# opencode/agents/*.md and opencode/commands/*.md. Edit the templates, stage
# them with -Template, then sync. Without -Template the current live local
# config is pushed as-is.
#
# If the server is unreachable, local staging still happens and the push is
# skipped with a warning (the script does not hard-fail on a down host).
#
# Notes:
#   - Requires SSH access to $SSH_USER@$SERVER_IP. Will prompt for password
#     per ssh/scp call unless you set up key auth (ssh-copy-id).
#   - node_modules/ in your local .config\opencode is intentionally skipped.

param(
    [switch]$Template
)

$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ENV_FILE = Join-Path $REPO_ROOT ".env"
$TEMPLATE_FILE = Join-Path $REPO_ROOT "opencode\global\opencode.jsonc"
$LOCAL_CONFIG = "$env:USERPROFILE\.config\opencode"

if (-not (Test-Path -LiteralPath $ENV_FILE)) {
    Write-Host "[sync] ERROR: $ENV_FILE not found. Fill in your .env first." -ForegroundColor Red
    exit 1
}

if ($Template) {
    if (-not (Test-Path -LiteralPath $TEMPLATE_FILE)) {
        Write-Host "[sync] ERROR: template not found at $TEMPLATE_FILE" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path -LiteralPath $LOCAL_CONFIG)) {
        New-Item -ItemType Directory -Path $LOCAL_CONFIG -Force | Out-Null
    }
    Copy-Item -LiteralPath $TEMPLATE_FILE -Destination (Join-Path $LOCAL_CONFIG "opencode.jsonc") -Force
    Write-Host "[sync] Staged repo template -> $LOCAL_CONFIG\opencode.jsonc" -ForegroundColor Cyan

    # Stage repo subagent and command templates too, so the live machine and
    # the repo can't drift. Files that only exist locally are left alone.
    $templateDirs = @(
        @{ Src = Join-Path $REPO_ROOT "opencode\agents";   Name = "agents" }
        @{ Src = Join-Path $REPO_ROOT "opencode\commands"; Name = "commands" }
    )
    foreach ($d in $templateDirs) {
        if (-not (Test-Path -LiteralPath $d.Src)) { continue }
        $target = Join-Path $LOCAL_CONFIG $d.Name
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem -LiteralPath $d.Src -Filter *.md -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $target $_.Name) -Force
            Write-Host "[sync] Staged $($d.Name)/$($_.Name)" -ForegroundColor Cyan
        }
    }
}

# --- Parse .env (KEY=VALUE) ---
$vars = @{}
Get-Content $ENV_FILE | Where-Object {
    $_ -match "^[^#]" -and $_ -match "="
} | ForEach-Object {
    $kv = $_ -split "=", 2
    $vars[$kv[0].Trim()] = $kv[1].Trim()
}

$user = $vars["SSH_USER"]
$host_ = $vars["SERVER_IP"]

if (-not $user -or -not $host_) {
    Write-Host "[sync] ERROR: SSH_USER and SERVER_IP must be set in $ENV_FILE" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath (Join-Path $LOCAL_CONFIG "opencode.jsonc"))) {
    Write-Host "[sync] ERROR: $LOCAL_CONFIG\opencode.jsonc not found" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Sync OpenCode config to ${user}@${host_} ===" -ForegroundColor Cyan
Write-Host ""

# 0. Probe SSH so a down host (e.g. the dev server out of commission) doesn't
#    hard-fail after local staging. ConnectTimeout keeps this bounded when the
#    host is unreachable; a live host prompts for the password as usual.
Write-Host "[0/4] Checking SSH to $host_ ..."
# A native command's stderr becomes a terminating error under
# $ErrorActionPreference = "Stop", so drop to Continue just for the probe.
# 2>&1 keeps ssh's connection error from printing; $LASTEXITCODE decides.
$probeEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
ssh -o ConnectTimeout=5 "${user}@${host_}" "true" 2>&1 | Out-Null
$probeExit = $LASTEXITCODE
$ErrorActionPreference = $probeEap
if ($probeExit -ne 0) {
    Write-Host "[sync] WARNING: ${host_} unreachable (or refused the connection)." -ForegroundColor Yellow
    Write-Host "[sync] Local config was staged. Server push skipped - run again when the host is back." -ForegroundColor Yellow
    exit 0
}

# 1. Create remote dirs (config + skill/agent scaffolding)
Write-Host "[1/4] Creating remote directories..."
ssh "${user}@${host_}" "mkdir -p ~/.config/opencode/.secrets ~/.config/opencode/skills ~/.config/opencode/agents ~/.config/opencode/commands ~/.config/opencode/tools ~/.config/opencode/plugins ~/.config/opencode/themes"
if ($LASTEXITCODE -ne 0) { Write-Host "[sync] ssh failed." -ForegroundColor Red; exit 1 }

# 2. Push opencode.jsonc
Write-Host "[2/4] Pushing opencode.jsonc..."
scp "$LOCAL_CONFIG\opencode.jsonc" "${user}@${host_}:~/.config/opencode/opencode.jsonc"
if ($LASTEXITCODE -ne 0) { Write-Host "[sync] scp config failed." -ForegroundColor Red; exit 1 }

# 3. Push agents and commands
Write-Host "[3/4] Pushing agents/* and commands/*..."
$pushDirs = @(
    @{ Src = Join-Path $LOCAL_CONFIG "agents";   Remote = "agents" }
    @{ Src = Join-Path $LOCAL_CONFIG "commands"; Remote = "commands" }
)
foreach ($d in $pushDirs) {
    if (-not (Test-Path -LiteralPath $d.Src)) { continue }
    Get-ChildItem -LiteralPath $d.Src -Filter *.md -File | ForEach-Object {
        Write-Host "  + $($d.Remote)/$($_.Name)"
        scp $_.FullName "${user}@${host_}:~/.config/opencode/$($d.Remote)/$($_.Name)"
        if ($LASTEXITCODE -ne 0) { Write-Host "[sync] scp $($d.Remote) failed." -ForegroundColor Red; exit 1 }
    }
}

# 4. Push secrets
Write-Host "[4/4] Pushing .secrets/*..."
$secretsDir = Join-Path $LOCAL_CONFIG ".secrets"
if (Test-Path -LiteralPath $secretsDir) {
    Get-ChildItem -LiteralPath $secretsDir -File | ForEach-Object {
        Write-Host "  + .secrets/$($_.Name)"
        scp $_.FullName "${user}@${host_}:~/.config/opencode/.secrets/$($_.Name)"
        if ($LASTEXITCODE -ne 0) { Write-Host "[sync] scp secret failed." -ForegroundColor Red; exit 1 }
    }
}

Write-Host ""
Write-Host "=== Sync complete. Restart any running opencode session to pick up changes. ===" -ForegroundColor Green
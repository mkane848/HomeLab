# sync-wezterm.ps1 — Deploy the repo's WezTerm config to this desktop machine.
#
# Source:   dev-docs\wezterm\wezterm.lua
# Target:   C:\Users\<you>\.wezterm.lua   (the location WezTerm actually loads)
#
# Usage:
#   .\desktop\scripts\sync-wezterm.ps1
#
# Notes:
#   - Re-running is safe (overwrites the desktop config with the repo template).
#   - Restart WezTerm after running to pick up the change.

$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SRC = Join-Path $REPO_ROOT "wezterm\wezterm.lua"
$DEST = Join-Path $env:USERPROFILE ".wezterm.lua"

if (-not (Test-Path -LiteralPath $SRC)) {
    Write-Host "[wezterm] ERROR: $SRC not found" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Sync WezTerm config ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  $SRC"
Write-Host "    -> $DEST"

Copy-Item -LiteralPath $SRC -Destination $DEST -Force

Write-Host ""
Write-Host "=== Done. Restart WezTerm to pick up the change. ===" -ForegroundColor Green
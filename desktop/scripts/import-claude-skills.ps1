# import-claude-skills.ps1 — Vendor your Claude plugin skills + assets into dev-docs.
#
# Copies the portable payloads out of ~/.claude/plugins into dev-docs:
#   skills/<plugin>/<skill>/        — portable SKILL.md skill dirs (OpenCode-compatible)
#   claude/imports/<plugin>/        — raw agents/, commands/, .mcp.json, README, LICENSE
#
# Intentionally NOT copied (Claude-plugin-specific, not portable to OpenCode):
#   hooks/, src/, tests/, scripts/, generated/, .github/
#
# Idempotent: re-run any time (it resolves the active installed versions via
# installed_plugins.json, so re-importing after a Claude plugin update picks up
# the new version).
#
# Usage:
#   .\desktop\scripts\import-claude-skills.ps1

$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SKILLS_ROOT = Join-Path $REPO_ROOT "skills"
$IMPORTS_ROOT = Join-Path $REPO_ROOT "claude\imports"
$PLUGINS_ROOT = "$env:USERPROFILE\.claude\plugins"
$INSTALLED_JSON = Join-Path $PLUGINS_ROOT "installed_plugins.json"
$MARKETPLACES = Join-Path $PLUGINS_ROOT "marketplaces"

function Get-InstalledPath {
    param([string]$PluginName)
    if (-not (Test-Path -LiteralPath $INSTALLED_JSON)) { return $null }
    $j = Get-Content -LiteralPath $INSTALLED_JSON -Raw | ConvertFrom-Json
    $key = "${PluginName}@claude-plugins-official"
    $entry = $j.plugins.$key | Select-Object -First 1
    if ($entry -and (Test-Path -LiteralPath $entry.installPath)) {
        return $entry.installPath
    }
    return $null
}

function Sync-Dir {
    param([string]$Source, [string]$Dest)
    if (-not (Test-Path -LiteralPath $Source)) { return }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Dest -Recurse -Force
        Write-Host "  + $($_.Name)"
    }
}

function Sync-ImportAssets {
    param([string]$PluginName, [string]$InstallPath)
    $dest = Join-Path $IMPORTS_ROOT $PluginName
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    foreach ($sub in @("agents", "commands")) {
        $src = Join-Path $InstallPath $sub
        if (Test-Path -LiteralPath $src) {
            $destSub = Join-Path $dest $sub
            New-Item -ItemType Directory -Path $destSub -Force | Out-Null
            Get-ChildItem -LiteralPath $src -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -ne ".tmpl" } |
                ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination $destSub -Force
                    Write-Host "  + $sub/$($_.Name)"
                }
        }
    }

    foreach ($file in @(".mcp.json", "README.md", "LICENSE")) {
        $src = Join-Path $InstallPath $file
        if (Test-Path -LiteralPath $src) {
            $name = if ($file -eq ".mcp.json") { "mcp.json" } else { $file }
            Copy-Item -LiteralPath $src -Destination (Join-Path $dest $name) -Force
            Write-Host "  + $name"
        }
    }
}

Write-Host ""
Write-Host "=== Importing Claude plugins ===" -ForegroundColor Cyan

foreach ($plugin in @("frontend-design", "render", "vercel")) {
    $ip = Get-InstalledPath -PluginName $plugin
    if (-not $ip) { Write-Host "[$plugin] not found in installed_plugins.json, skipping" -ForegroundColor Yellow; continue }

    Write-Host ""
    Write-Host "[$plugin] from $ip" -ForegroundColor Cyan

    $skillSrc = Join-Path $ip "skills"
    if (Test-Path -LiteralPath $skillSrc) {
        Write-Host "  skills:"
        Sync-Dir -Source $skillSrc -Dest (Join-Path $SKILLS_ROOT $plugin)
    }

    Write-Host "  imports:"
    Sync-ImportAssets -PluginName $plugin -InstallPath $ip
}

Write-Host ""
Write-Host "=== Importing ui-ux-pro-max (marketplace) ===" -ForegroundColor Cyan

$uux = Join-Path $MARKETPLACES "ui-ux-pro-max-skill"
if (Test-Path -LiteralPath $uux) {
    Write-Host "  skills:"
    Sync-Dir -Source (Join-Path $uux ".claude\skills") -Dest (Join-Path $SKILLS_ROOT "ui-ux-pro-max")

    Write-Host "  imports:"
    $dest = Join-Path $IMPORTS_ROOT "ui-ux-pro-max"
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($file in @("README.md", "LICENSE", "skill.json")) {
        $src = Join-Path $uux $file
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $dest $file) -Force
            Write-Host "  + $file"
        }
    }
} else {
    Write-Host "[ui-ux-pro-max] marketplace not found, skipping" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Import complete. ===" -ForegroundColor Green
Write-Host "Skills: $SKILLS_ROOT"
Write-Host "Raw imports: $IMPORTS_ROOT"
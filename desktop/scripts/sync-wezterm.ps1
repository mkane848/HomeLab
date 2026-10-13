# sync-wezterm.ps1 — Deploy the repo's WezTerm config to this desktop machine.
#
# Source:   dev-docs\wezterm\wezterm.lua
# Target:   C:\Users\<you>\.wezterm.lua   (the location WezTerm actually loads)
#
# Usage:
#   .\desktop\scripts\sync-wezterm.ps1
#
# Notes:
#   - The template carries two placeholders, YOUR_USER and SERVER_IP. They are filled
#     from SSH_USER and SERVER_IP in .env (the repo's, or the file $env:DEVDOCS_ENV
#     names, which is how a git worktree finds the main checkout's .env). Without
#     both values the script stops and writes nothing: a copy with the placeholders
#     in it would break the SSH entry, and used to overwrite a hand-filled config.
#   - A config already at the target that differs from what would be written is
#     copied to .wezterm.lua.bak-<yyyyMMdd-HHmmss> first.
#   - Re-running is safe. Restart WezTerm after running to pick up the change.

$ErrorActionPreference = "Stop"

$REPO_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SRC = Join-Path $REPO_ROOT "wezterm\wezterm.lua"
$DEST = Join-Path $env:USERPROFILE ".wezterm.lua"
$ENV_FILE = if ($env:DEVDOCS_ENV -and (Test-Path -LiteralPath $env:DEVDOCS_ENV)) { $env:DEVDOCS_ENV } else { Join-Path $REPO_ROOT ".env" }

if (-not (Test-Path -LiteralPath $SRC)) {
    Write-Host "[wezterm] ERROR: $SRC not found" -ForegroundColor Red
    exit 1
}

$text = [IO.File]::ReadAllText($SRC)

if ($text -match "YOUR_USER|SERVER_IP") {
    if (-not (Test-Path -LiteralPath $ENV_FILE)) {
        Write-Host "[wezterm] ERROR: the template has YOUR_USER / SERVER_IP placeholders and $ENV_FILE does not exist. Nothing written." -ForegroundColor Red
        exit 1
    }
    $vars = @{}
    Get-Content -LiteralPath $ENV_FILE | Where-Object { $_ -match "^[^#]" -and $_ -match "=" } | ForEach-Object {
        $kv = $_ -split "=", 2
        $vars[$kv[0].Trim()] = $kv[1].Trim().Trim('"')
    }
    $user = $vars["SSH_USER"]
    $server = $vars["SERVER_IP"]
    if (-not $user -or -not $server) {
        Write-Host "[wezterm] ERROR: SSH_USER and SERVER_IP must both be set in $ENV_FILE. Nothing written." -ForegroundColor Red
        exit 1
    }
    $text = $text.Replace("YOUR_USER", $user).Replace("SERVER_IP", $server)
}

Write-Host ""
Write-Host "=== Sync WezTerm config ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  $SRC"
Write-Host "    -> $DEST"

if (Test-Path -LiteralPath $DEST) {
    if ([IO.File]::ReadAllText($DEST) -ne $text) {
        $bak = "$DEST.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        Copy-Item -LiteralPath $DEST -Destination $bak -Force
        Write-Host "  backed up the existing config to $bak" -ForegroundColor DarkGray
    } else {
        Write-Host "  already up to date" -ForegroundColor DarkGray
    }
}
[IO.File]::WriteAllText($DEST, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "=== Done. Restart WezTerm to pick up the change. ===" -ForegroundColor Green

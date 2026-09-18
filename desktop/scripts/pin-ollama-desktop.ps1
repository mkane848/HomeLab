# pin-ollama-desktop.ps1 - Stop the native desktop Ollama from silently
# auto-upgrading off the version the docs were measured against.
#
# Background
# ----------
# The server's Ollama is pinned by `server/docker/docker-compose.yml` (image
# tag) and `server/ollama/version-pin`. The desktop is a NATIVE Inno Setup
# install (`%LOCALAPPDATA%\Programs\Ollama`) with no image tag to pin, and its
# tray app ("ollama app.exe") runs the auto-updater. Upstream has explicitly
# refused a CLI/env switch to disable the updater
# (ollama/ollama#9404, closed not-merged), so the only first-party controls are
# GUI-only (Settings > "Auto-download updates").
#
# This is not a hypothetical risk on 2026-09-17: the tray updater had already
# staged v0.34.1 (`%LOCALAPPDATA%\Ollama\updates_v2\...\OllamaSetup.exe`,
# ~1.5 GB) and `app.log`/`upgrade.log` show it re-checks hourly and downloads
# the bundle. Without a guard the desktop will silently move itself off the
# version every measurement in docs/ was taken against.
#
# Approach
# --------
# Create a Windows Firewall outbound-block on the tray app's updater. This is
# the documented workaround from the maintainers' own discussions: your own
# firewall rule takes precedence over the app's auto-updater, so the bundle can
# never be downloaded. `ollama pull`, `ollama serve` and localhost traffic are
# untouched (they are separate binaries and directions).
#
# Caveats
# -------
# - A firewall rule is NOT a real version pin (same class as the docs' note on
#   the server pin): it stops the *tray app* from auto-downloading, but a
#   manual `OllamaSetup.exe` run will still move the install. Treat as "never
#   moves by itself", not "can never move". This matches the docs' framing at
#   docs/roadmap.md "not an image tag: watch for admin-driven moves".
# - If Ollama later ships a first-party toggle that writes
#   `auto_update_enabled=0` into `%LOCALAPPDATA%\Ollama\db.sqlite`, prefer that
#   (it's the same table the Settings page writes). Re-check each time you
#   touch this script.
#
# Usage
# -----
#   .\desktop\scripts\pin-ollama-desktop.ps1            # ensure pin (idempotent)
#   .\desktop\scripts\pin-ollama-desktop.ps1 -Remove    # undo, idempotent
#   .\desktop\scripts\pin-ollama-desktop.ps1 -Force     # skip the path check

param(
    [switch]$Remove,
    [switch]$Force
)
$ErrorActionPreference = "Stop"

$RuleName = "Block Ollama desktop auto-update (outbound)"
# The tray app lives here for the per-user Inno install that ollama uses on
# Windows: LOCALAPPDATA\Programs\Ollama\ollama app.exe
$AppPath = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama app.exe"

Write-Host "[pin-ollama] targeting: $AppPath" -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $AppPath) -and -not $Force) {
    throw "Ollama tray app not found at '$AppPath'. Refusing to block a path that doesn't exist. (Use -Force if the layout differs and you know the updater binary.)"
}

$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

if ($Remove) {
    if ($null -eq $existing) {
        Write-Host "[pin-ollama] no rule to remove (already clear)" -ForegroundColor Yellow
        return
    }
    $existing | Remove-NetFirewallRule
    Write-Host "[pin-ollama] removed outbound block for '$AppPath'" -ForegroundColor Green
    return
}

if ($null -ne $existing) {
    Write-Host "[pin-ollama] rule already present - nothing to do" -ForegroundColor Green
    return
}

New-NetFirewallRule `
    -DisplayName $RuleName `
    -Direction Outbound `
    -Action Block `
    -Program $AppPath `
    -Profile Any `
    -Description "Prevent the Ollama desktop tray app from auto-downloading a new OllamaSetup.exe bundle. Keeps the desktop pinned to the version the docs were measured against. See docs/troubleshooting.md (pin Ollama on the desktop)." `
    | Out-Null

Write-Host "[pin-ollama] created outbound block for '$AppPath'" -ForegroundColor Green
Write-Host "[pin-ollama] undo with:  .\desktop\scripts\pin-ollama-desktop.ps1 -Remove" -ForegroundColor DarkGray


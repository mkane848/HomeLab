# dev-desktop-only.ps1 - PowerShell wrapper for the desktop-only profile.
# Sets the same env vars as profiles/dev-desktop-only.sh so that
# models.ps1 -Profile and startup.ps1 work from a pure-PowerShell session.

# $PSScriptRoot is <repo>/profiles; the .sh profiles read <repo>/.env.
$envFile   = Join-Path (Split-Path -Parent $PSScriptRoot) ".env"

# Load .env (same logic as the bash profiles)
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object {
        $_ -match "^[^#]" -and $_ -match "="
    } | ForEach-Object {
        $kv = $_ -split "=", 2
        [System.Environment]::SetEnvironmentVariable($kv[0].Trim(), $kv[1].Trim(), "Process")
    }
}

[System.Environment]::SetEnvironmentVariable("DEV_TIERS_SERVER",   "false", "Process")
[System.Environment]::SetEnvironmentVariable("DEV_TIERS_DESKTOP",  "true",  "Process")
[System.Environment]::SetEnvironmentVariable("DEV_TIERS_GO",       "false", "Process")
[System.Environment]::SetEnvironmentVariable("DEV_TIERS_NODE3",     "false", "Process")

# Models to install on the desktop (explicit tags — lean set, all fit in 16 GB)
[System.Environment]::SetEnvironmentVariable("DEV_DESKTOP_MODELS", "qwen2.5-coder:7b deepseek-r1:14b qwen3:8b", "Process")

# Running on this box — localhost, immune to LAN/IP changes
[System.Environment]::SetEnvironmentVariable("OLLAMA_DESKTOP_URL",       "http://localhost:11434",        "Process")
[System.Environment]::SetEnvironmentVariable("OLLAMA_DESKTOP_BASE_URL", "http://localhost:11434/v1",      "Process")

# llama.cpp providers: {env:...} has no fallbacks, so every live profile exports
# these (mirrors profiles/dev-desktop-only.sh).
$serverIp = [Environment]::GetEnvironmentVariable("SERVER_IP", "Process"); if (-not $serverIp) { $serverIp = "SERVER_IP" }
function Set-Default($n, $v) { if (-not [Environment]::GetEnvironmentVariable($n, "Process")) { [Environment]::SetEnvironmentVariable($n, $v, "Process") } }
Set-Default "LLAMACPP_SERVER_BASE_URL"  "http://${serverIp}:8090/v1"
Set-Default "LLAMACPP_SERVER_SSH"       "server"
Set-Default "LLAMACPP_DESKTOP_BASE_URL" "http://localhost:8090/v1"
[System.Environment]::SetEnvironmentVariable("OPENCODE_DISABLE_CLAUDE_CODE_SKILLS", "1", "Process")

# MAIN SEAT = qwen3:8b - the only model that emits a parseable tool call
# (probe: tests/test-toolcalls.ps1). deepseek-r1 here made the console
# chat-only: it described edits it never made. Keep this in sync with
# profiles/dev-desktop-only.sh.
# Main agent + small model (contexts baked by startup.ps1)
[System.Environment]::SetEnvironmentVariable("OPENCODE_MODEL",       "ollama-desktop/qwen3:8b"     ,  "Process")
[System.Environment]::SetEnvironmentVariable("OPENCODE_SMALL_MODEL", "ollama-desktop/qwen2.5-coder:7b", "Process")

Write-Host "[profile] Desktop only: qwen3:8b drives; Qwen coder 7b + DeepSeek 14b available (no tools)" -ForegroundColor Green
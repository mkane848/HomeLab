# tests/engines/llamacpp-auth.ps1 - the API key every llama-server client sends.
#
# llama-server started with --api-key-file answers only /health without a key (and its web page); every other path
# (/props, /models, /models/unload, /v1/...) needs `Authorization: Bearer <key>`, else HTTP 401.
# docs/engine-api-keys.md is the runbook. Dot-sourced by tests/engines/llamacpp.ps1 and by the scripts that call
# llama-server directly (run-window, bench-speed, probe-overflow, test-toolcalls, node3/scripts/start-llama-server).
#
# Where the key comes from, first match wins:
#   1. $env:LLAMACPP_API_KEY            (a one-off override; never written to a log)
#   2. the file named by $env:LLAMACPP_API_KEY_FILE
#   3. ~/.config/opencode/.secrets/llamacpp-api-key   (the file OpenCode's providers read, {file:...})
# The file may hold comment lines (#) and blank lines; the first other line is the key.
# No key found: no header, so an engine without a key still answers, and one with a key answers 401, which the
# callers report. The key is never printed.

function Get-LlamacppApiKey {
    $k = "$env:LLAMACPP_API_KEY".Trim()
    if ($k) { return $k }
    $file = if ($env:LLAMACPP_API_KEY_FILE) { $env:LLAMACPP_API_KEY_FILE } else {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) ".config/opencode/.secrets/llamacpp-api-key"
    }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)) {
        $t = "$line".Trim()
        if ($t -and -not $t.StartsWith('#')) { return $t }
    }
    return $null
}

function Get-LlamacppHeaders {
    $k = Get-LlamacppApiKey
    if ($k) { return @{ Authorization = "Bearer $k" } }
    return @{}
}

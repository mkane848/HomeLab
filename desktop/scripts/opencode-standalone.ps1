# opencode-standalone.ps1 - dot-sourced by opencode.ps1 (the profile launcher).
#
# OpenCode 2.x runs one shared background service per machine, and every client
# attaches to it by default. The service resolves `{env:...}` in opencode.jsonc
# from ITS OWN environment, not from the shell that launched the client.
# Measured on the desktop, v2.3.2, 2026-11-21: with OPENCODE_MODEL set in the
# shell, `opencode debug config` showed the User-level default
# (ollama-desktop/qwen3:8b), while `opencode --standalone debug config` showed
# the shell's value. OPENCODE_CONFIG and OPENCODE_CONFIG_CONTENT behaved the same
# way. So a profile launch that attaches to the service runs on the wrong model
# and base URLs.
#
# `--standalone` gives this launch a private server that inherits the
# launcher's environment. It goes BEFORE the subcommand (`opencode --standalone
# run ...`): after `run`, the variadic message could swallow it. Opencode 1.x
# has no such flag, so the flag is added for major version >= 2 only. Args
# that already pick a server (--standalone, --server) are left alone.

function Get-OpencodeMajorVersion([string]$VersionText) {
    if ("$VersionText" -match '(\d+)\.\d+\.\d+') { return [int]$matches[1] }
    return $null
}

function Add-OpencodeStandaloneArg([string]$VersionText, [string[]]$OpenCodeArgs) {
    $argsIn = @($OpenCodeArgs | Where-Object { $null -ne $_ })
    $major = Get-OpencodeMajorVersion $VersionText
    if ($null -eq $major -or $major -lt 2) { return ,$argsIn }
    foreach ($a in $argsIn) {
        if ($a -eq '--standalone' -or $a -eq '--server' -or $a -like '--server=*') { return ,$argsIn }
    }
    return ,(@('--standalone') + $argsIn)
}

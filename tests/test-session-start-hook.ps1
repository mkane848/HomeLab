# protects: .claude/hooks/session-start.sh (the remote sessions' pwsh install): nothing unpacked unless its sha256 is the pin
# run-after: .claude/hooks/session-start.sh
# mutation: .claude/hooks/session-start.sh
# mutation-from: if [ "$GOT" != "$PWSH_SHA256" ]; then
# mutation-to: if false; then
# mutation-expect: FAIL\s+REFUSED, naming
# test-session-start-hook.ps1 - regression guard for the remote sessions' PowerShell install.
#
# Why this exists: the hook downloads a PowerShell tarball and unpacks it into /opt as root, in every cloud session.
# The 2026-11-09 audit found it checked nothing ("downloads PowerShell with no checksum"). Since 2026-11-24 it unpacks
# only a tarball whose sha256 is the pin for the machine's architecture. A refusal installs nothing and does not break
# the session.
# What it does: runs the real hook offline, with PWSH_URL pointing at local files (file://) and PWSH_INSTALL_DIR /
# PWSH_LINK in a temp folder, and with no pwsh on PATH:
#   - outside a remote session it does nothing;
#   - with a pwsh already on PATH it does nothing;
#   - a tampered tarball (a valid .tar.gz with a fake pwsh in it) is REFUSED, naming both hashes, and nothing is
#     unpacked or linked;
#   - a failed download is skipped, with nothing installed;
#   - both architectures carry a 64-hex pin.
# The happy path needs the real 70 MB tarball, so it is not run here (it was checked by hand when the pins were set).
# Linux only (bash, tar, sha256sum, curl): CI runs it in the Linux job; elsewhere it SKIPs. Exit 1 on any failure.
#
# Usage:  .\tests\test-session-start-hook.ps1 [-HookPath <session-start.sh>]
param([string]$HookPath = "")

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$hook = if ($HookPath) { $HookPath } else { Join-Path $repo ".claude/hooks/session-start.sh" }
if (-not $IsLinux) { Write-Host "SKIP the hook runs in Linux cloud sessions; CI runs this guard in the Linux job"; exit 0 }
foreach ($tool in "bash", "tar", "sha256sum", "curl", "env") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Write-Host "SKIP needs $tool"; exit 0 }
}
if (-not (Test-Path -LiteralPath $hook)) { Write-Host "FAIL: missing $hook"; exit 1 }

$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")   # Check <name> <actual> <expected>: a PASS/FAIL line, failures counted in $script:fail

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("session-hook-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
# A PATH with the basic tools and no pwsh: the hook's own "already installed" check must not see the runner's pwsh.
$cleanPath = "/usr/bin:/bin"
if (& bash -c "PATH=$cleanPath command -v pwsh") { Write-Host "SKIP a pwsh is in $cleanPath, so the install path cannot be reached"; exit 0 }
try {
    function Invoke-Hook([string]$Name, [string]$Url, [hashtable]$More = @{}, [string]$PathValue = $cleanPath) {
        $inst = Join-Path $tmp "$Name/inst"; $link = Join-Path $tmp "$Name/bin/pwsh"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $link) | Out-Null
        $vars = @("PATH=$PathValue", "PWSH_URL=$Url", "PWSH_INSTALL_DIR=$inst", "PWSH_LINK=$link")
        foreach ($k in $More.Keys) { $vars += "$k=$($More[$k])" }
        $out = & env -i @vars bash $hook 2>&1 | Out-String
        [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE; Installed = (Test-Path -LiteralPath $inst); Linked = (Test-Path -LiteralPath $link) }
    }
    # A valid tarball whose content would "work": if the pin check were missing, it would be unpacked and linked.
    $fake = Join-Path $tmp "fake"; New-Item -ItemType Directory -Force -Path $fake | Out-Null
    [IO.File]::WriteAllText((Join-Path $fake "pwsh"), "#!/bin/sh`necho 'PowerShell 7.4.6 (not really)'`n")
    & chmod +x (Join-Path $fake "pwsh")
    $tampered = Join-Path $tmp "tampered.tar.gz"
    & tar czf $tampered -C $fake pwsh
    $tamperedSha = ((& sha256sum $tampered) -split '\s+')[0]

    Write-Host "-- outside a remote session"
    $r = Invoke-Hook "notremote" "file://$tampered" @{}
    Check "exit 0" $r.Exit 0
    Check "nothing installed or linked" "$($r.Installed)|$($r.Linked)" "False|False"
    Check "nothing printed" $r.Out.Trim() ""

    Write-Host "-- pwsh already on PATH"
    $have = Join-Path $tmp "have"; New-Item -ItemType Directory -Force -Path $have | Out-Null
    Copy-Item -LiteralPath (Join-Path $fake "pwsh") -Destination (Join-Path $have "pwsh"); & chmod +x (Join-Path $have "pwsh")
    $r = Invoke-Hook "present" "file://$tampered" @{ CLAUDE_CODE_REMOTE = "true" } "${have}:$cleanPath"
    Check "exit 0" $r.Exit 0
    Check "nothing installed or linked" "$($r.Installed)|$($r.Linked)" "False|False"

    Write-Host "-- a tampered tarball"
    $r = Invoke-Hook "tampered" "file://$tampered" @{ CLAUDE_CODE_REMOTE = "true" }
    Check "exit 0 (a refusal does not break the session)" $r.Exit 0
    Check "REFUSED, naming the tarball's hash and the pin" ($r.Out -match "REFUSED to install pwsh: .* has sha256 $tamperedSha, expected the pinned [0-9a-f]{64}\. Nothing was installed\.") "True"
    Check "nothing unpacked or linked" "$($r.Installed)|$($r.Linked)" "False|False"

    Write-Host "-- a failed download"
    $r = Invoke-Hook "nodownload" "file://$tmp/no-such.tar.gz" @{ CLAUDE_CODE_REMOTE = "true" }
    Check "exit 0" $r.Exit 0
    Check "says the download failed" ($r.Out -match 'failed to download pwsh, skipping') "True"
    Check "nothing installed or linked" "$($r.Installed)|$($r.Linked)" "False|False"

    Write-Host "-- the pins"
    $text = Get-Content -Raw -LiteralPath $hook
    Check "x64 and arm64 each carry a 64-hex pin" ([regex]::Matches($text, '(?m)^\s+PWSH_SHA256="[0-9a-f]{64}"').Count) 2
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

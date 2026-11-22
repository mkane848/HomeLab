# opencode.ps1 — Launch OpenCode with a workflow profile sourced into the process
#
# A bare `opencode` launch falls back to User-level env defaults and whatever the
# model picker last selected; that is how sessions end up on deepseek-r1-16k as
# the MAIN agent (slow/empty replies) or on a provider whose LLAMACPP_*_BASE_URL
# is blank (every request dies with "cannot be parsed as a URL"). This wrapper
# sources a profile first so the session default is always the profile's main
# coder model with a valid base URL.
#
# Usage (PowerShell, from the repo root):
#   .\desktop\scripts\opencode.ps1                 # dev-workflow-server-llamacpp (default since 2026-10-22)
#   .\desktop\scripts\opencode.ps1 -Profile dev-node3              # qwen3:8b on node3's llama-server
#   .\desktop\scripts\opencode.ps1 run "do the thing"     # args pass through
# Or, once desktop\scripts\install-opencode-profiles.ps1 has run, from anywhere:
#   opencode quality | opencode resident run "do the thing"   (opencode-profiles.ps1)
#
# The profile's env lasts for this launch only: the shell's previous values are
# restored when opencode exits, so a later bare `opencode` is not silently on
# the last profile.
#
# Options:
#   -Profile <name>   profile basename under profiles/ (default dev-workflow-server-llamacpp:
#                     qwen3.6 on the server's llama-server. Needs the llama.cpp stack up on the
#                     server. The desktop runs no models since 2026-11-21).
#   -ListProfiles     print the live profiles and exit.
#   -BashPath         Git Bash executable (auto-detected if omitted).

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Profile = "dev-workflow-server-llamacpp",
    [switch]$ListProfiles,
    [string]$BashPath = "",
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$OpenCodeArgs = @()
)

$ErrorActionPreference = "Stop"

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent (Split-Path -Parent $scriptDir)
$profilesDir = Join-Path $repoRoot "profiles"

if ($ListProfiles) {
    Get-ChildItem -LiteralPath $profilesDir -Filter "dev-*.sh" -File | ForEach-Object { $_.BaseName }
    exit 0
}

$profilePath = Join-Path $profilesDir "$Profile.sh"
if (-not (Test-Path -LiteralPath $profilePath)) {
    Write-Host "[opencode] ERROR: profile not found at $profilePath" -ForegroundColor Red
    exit 1
}

if (-not $BashPath) {
    $candidates = @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files\Git\usr\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $BashPath = $c; break } }
}
if (-not $BashPath) {
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host "[opencode] ERROR: Git Bash not found. Pass -BashPath." -ForegroundColor Red
        exit 1
    }
    $BashPath = $cmd.Source
}

$profileBashPath = $profilePath -replace '\\', '/' -replace '^(\w):', '$1:'
$bashScript = @'
set +e
unset OPENCODE_MODEL OPENCODE_SMALL_MODEL OPENCODE_DISABLE_CLAUDE_CODE_SKILLS LLAMACPP_SERVER_BASE_URL LLAMACPP_SERVER_SSH LLAMACPP_NODE3_BASE_URL DEV_TIERS_SERVER DEV_TIERS_DESKTOP DEV_TIERS_GO DEV_TIERS_NODE3 2>/dev/null
if [ -f "__PROFILEPATH__" ]; then
  . "__PROFILEPATH__" >/dev/null 2>&1
fi
for v in OPENCODE_MODEL OPENCODE_SMALL_MODEL OPENCODE_DISABLE_CLAUDE_CODE_SKILLS LLAMACPP_SERVER_BASE_URL LLAMACPP_SERVER_SSH LLAMACPP_NODE3_BASE_URL DEV_TIERS_SERVER DEV_TIERS_DESKTOP DEV_TIERS_GO DEV_TIERS_NODE3; do
  eval 'val=${'$v':-}'
  printf '%s=%s\n' "$v" "$val"
done
'@ -replace '__PROFILEPATH__', $profileBashPath

$tmp = Join-Path $env:TEMP ("opencode-{0}.sh" -f ([guid]::NewGuid().ToString("N")))
[System.IO.File]::WriteAllText($tmp, $bashScript, (New-Object System.Text.UTF8Encoding($false)))
try {
    $output = & $BashPath --noprofile --norc $tmp 2>$null
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

$savedEnv = @{}
foreach ($line in $output) {
    if ($line -match '^([A-Za-z0-9_]+)=(.*)$') {
        if (-not $savedEnv.ContainsKey($matches[1])) {
            $savedEnv[$matches[1]] = [Environment]::GetEnvironmentVariable($matches[1], "Process")
        }
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
    }
}

if (-not $env:OPENCODE_MODEL) {
    Write-Host "[opencode] WARNING: profile $Profile exported no OPENCODE_MODEL; falling back to User defaults" -ForegroundColor Yellow
}

Write-Host "[opencode] profile=$Profile OPENCODE_MODEL=$env:OPENCODE_MODEL" -ForegroundColor DarkGray

# The real opencode, not the `opencode` function opencode-profiles.ps1 defines.
$realOpencode = Get-Command opencode -CommandType ExternalScript, Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $realOpencode) {
    Write-Host "[opencode] ERROR: opencode is not installed (not on PATH)" -ForegroundColor Red
    exit 1
}
# OpenCode 2.x: run a private server so the profile's env applies (opencode-standalone.ps1).
. (Join-Path $scriptDir "opencode-standalone.ps1")
$ocVersion = (& $realOpencode --version 2>$null | Out-String).Trim()
$launchArgs = Add-OpencodeStandaloneArg $ocVersion $OpenCodeArgs
$code = 1
try {
    & $realOpencode @launchArgs
    $code = $LASTEXITCODE
} finally {
    foreach ($name in $savedEnv.Keys) {
        # A variable that was absent must be removed, not left empty: PowerShell binds $null to
        # a .NET string as "", which sets an empty value on pwsh 7.5+ (.NET 9); NullString is a true null.
        $value = if ($null -eq $savedEnv[$name]) { [NullString]::Value } else { $savedEnv[$name] }
        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}
exit $code
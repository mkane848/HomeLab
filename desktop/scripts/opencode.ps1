# opencode.ps1 — Launch OpenCode with a workflow profile sourced into the process
#
# A bare `opencode` launch falls back to User-level env defaults and whatever the
# model picker last selected; that is how sessions end up on deepseek-r1-16k as
# the MAIN agent (slow/empty replies) or on a provider whose OLLAMA_*_BASE_URL
# is blank (every request dies with "cannot be parsed as a URL"). This wrapper
# sources a profile first so the session default is always the profile's main
# coder model with a valid base URL.
#
# Usage (PowerShell, from the repo root):
#   .\desktop\scripts\opencode.ps1                 # dev-workflow-quality (default)
#   .\desktop\scripts\opencode.ps1 -Profile dev-workflow-resident
#   .\desktop\scripts\opencode.ps1 -Profile dev-workflow-server
#   .\desktop\scripts\opencode.ps1 run "do the thing"     # args pass through
#
# Options:
#   -Profile <name>   profile basename under profiles/ (default dev-workflow-quality).
#   -ListProfiles     print the workflow profiles and exit.
#   -BashPath         Git Bash executable (auto-detected if omitted).

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Profile = "dev-workflow-quality",
    [switch]$ListProfiles,
    [string]$BashPath = "",
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$OpenCodeArgs = @()
)

$ErrorActionPreference = "Stop"

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent (Split-Path -Parent $scriptDir)
$profilesDir = Join-Path $repoRoot "profiles"

if ($ListProfiles) {
    Get-ChildItem -LiteralPath $profilesDir -Filter "dev-workflow-*.sh" | ForEach-Object { $_.BaseName }
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
unset OPENCODE_MODEL OPENCODE_SMALL_MODEL OPENCODE_DISABLE_CLAUDE_CODE_SKILLS OLLAMA_SERVER_BASE_URL OLLAMA_DESKTOP_URL OLLAMA_DESKTOP_BASE_URL OLLAMA_NODE3_URL OLLAMA_NODE3_BASE_URL DEV_TIERS_SERVER DEV_TIERS_DESKTOP DEV_TIERS_GO DEV_TIERS_NODE3 2>/dev/null
if [ -f "__PROFILEPATH__" ]; then
  . "__PROFILEPATH__" >/dev/null 2>&1
fi
for v in OPENCODE_MODEL OPENCODE_SMALL_MODEL OPENCODE_DISABLE_CLAUDE_CODE_SKILLS OLLAMA_SERVER_BASE_URL OLLAMA_DESKTOP_BASE_URL OLLAMA_NODE3_BASE_URL DEV_TIERS_SERVER DEV_TIERS_DESKTOP DEV_TIERS_GO DEV_TIERS_NODE3; do
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

foreach ($line in $output) {
    if ($line -match '^([A-Za-z0-9_]+)=(.*)$') {
        Set-Item -LiteralPath ("Env:" + $matches[1]) -Value $matches[2]
    }
}

if (-not $env:OPENCODE_MODEL) {
    Write-Host "[opencode] WARNING: profile $Profile exported no OPENCODE_MODEL; falling back to User defaults" -ForegroundColor Yellow
}

Write-Host "[opencode] profile=$Profile OPENCODE_MODEL=$env:OPENCODE_MODEL" -ForegroundColor DarkGray

& opencode @OpenCodeArgs
exit $LASTEXITCODE
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
#   .\desktop\scripts\opencode.ps1 run "do the thing"     # args pass through
# Or, once desktop\scripts\install-opencode-profiles.ps1 has run, from anywhere:
#   opencode quality | opencode resident run "do the thing"   (opencode-profiles.ps1)
#
# The profile's env lasts for this launch only: the shell's previous values are
# restored when opencode exits, so a later bare `opencode` is not silently on
# the last profile.
#
# Options:
#   -Profile <name>   profile basename under profiles/ (default dev-workflow-quality).
#   -ListProfiles     print the live profiles and exit.
#   -NoWarm           do not pre-load the profile's desktop main seat (see below).
#   -KeepLoaded       do not unload desktop models the profile does not use (see below).
#   -BashPath         Git Bash executable (auto-detected if omitted).

[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Profile = "dev-workflow-quality",
    [switch]$ListProfiles,
    [switch]$NoWarm,
    [switch]$KeepLoaded,
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

# Warm the profile's main model in the background, so the first reply does not
# also pay the cold load (qwen3.6: ~60 s, measured 2026-10-03). A /api/generate
# with no prompt only loads the model, and OLLAMA_KEEP_ALIVE (4h, User env)
# keeps it loaded after that. Fire-and-forget: the request runs while OpenCode
# starts and never delays or fails the launch. Only an ollama-desktop main seat
# is warmed; -NoWarm skips it.
# The small model is deliberately NOT warmed. Warming both at once let the CPU
# 3b load first, and qwen3.6's load (which does not fit the GPU) then evicted
# it, so it loaded twice. Loaded after the main seat - by the session's first
# title - it stays (docs/main-seat-trial.md, "Second experiment").
$desktopBase = "$env:OLLAMA_DESKTOP_BASE_URL" -replace '/v1/?$', ''

# Switching profiles: unload the desktop models this profile does not use, so
# the last profile's models do not sit in memory for the 4h keep-alive beside
# this one's (qwen3.6 alone holds ~19 GB of RAM with its companion). Only when
# this profile seats a desktop model - a node3 session leaves the desktop
# alone. An unloaded model that something else is still using (a batch run)
# just reloads on its next request; -KeepLoaded skips this.
if (-not $KeepLoaded -and $desktopBase) {
    $wanted = @(@($env:OPENCODE_MODEL, $env:OPENCODE_SMALL_MODEL) |
        Where-Object { $_ -like 'ollama-desktop/*' } |
        ForEach-Object { $_.Substring('ollama-desktop/'.Length) -replace ':latest$', '' })
    if ($wanted.Count -gt 0) {
        try {
            $loaded = @((Invoke-RestMethod "$desktopBase/api/ps" -TimeoutSec 3).models)
            $unloading = @()
            foreach ($m in $loaded) {
                if ($wanted -notcontains ($m.name -replace ':latest$', '')) {
                    $body = @{ model = $m.name; keep_alive = 0 } | ConvertTo-Json -Compress
                    $null = Invoke-RestMethod "$desktopBase/api/generate" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 30
                    $unloading += $m.name
                    Write-Host "[opencode] unloaded $($m.name) (not in $Profile)" -ForegroundColor DarkGray
                }
            }
            # Ollama answers keep_alive 0 before the memory is free. Warming the
            # next model before that makes the scheduler log an "evicting" line
            # (measured 2026-10-03), so wait for /api/ps to drop them, up to 20 s.
            $deadline = (Get-Date).AddSeconds(20)
            while ($unloading.Count -gt 0 -and (Get-Date) -lt $deadline) {
                $still = @((Invoke-RestMethod "$desktopBase/api/ps" -TimeoutSec 3).models | Where-Object { $unloading -contains $_.name })
                if ($still.Count -eq 0) { break }
                Start-Sleep -Milliseconds 500
            }
        } catch {
            Write-Host "[opencode] unload skipped: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}

if (-not $NoWarm) {
    $warmBase = $desktopBase
    $warmModels = @(@($env:OPENCODE_MODEL) |
        Where-Object { $_ -like 'ollama-desktop/*' } |
        ForEach-Object { $_.Substring('ollama-desktop/'.Length) })
    if ($warmBase -and $warmModels.Count -gt 0) {
        try {
            Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
            $warmClient = New-Object System.Net.Http.HttpClient
            $warmClient.Timeout = [TimeSpan]::FromMinutes(10)
            foreach ($m in $warmModels) {
                $body = New-Object System.Net.Http.StringContent(('{"model":"' + $m + '"}'), [System.Text.Encoding]::UTF8, 'application/json')
                $null = $warmClient.PostAsync("$warmBase/api/generate", $body)
            }
            Write-Host "[opencode] warming $($warmModels -join ', ') in the background" -ForegroundColor DarkGray
        } catch {
            Write-Host "[opencode] warm-up skipped: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
}

# The real opencode, not the `opencode` function opencode-profiles.ps1 defines.
$realOpencode = Get-Command opencode -CommandType ExternalScript, Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $realOpencode) {
    Write-Host "[opencode] ERROR: opencode is not installed (not on PATH)" -ForegroundColor Red
    exit 1
}
$code = 1
try {
    & $realOpencode @OpenCodeArgs
    $code = $LASTEXITCODE
} finally {
    foreach ($name in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], "Process")
    }
}
exit $code
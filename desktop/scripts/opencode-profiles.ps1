# opencode-profiles.ps1 — `opencode <profile>` in PowerShell
#
# Dot-sourced from your PowerShell profile ($PROFILE); install it with
# .\desktop\scripts\install-opencode-profiles.ps1. It defines an `opencode`
# function that sits in front of the real command:
#
#   opencode quality                  # dev-workflow-quality: qwen3.6 + CPU 3b
#   opencode resident                 # dev-workflow-resident: qwen3:8b + 7b coder
#   opencode desktop-only run "..."   # anything after the name goes to opencode
#   opencode quality -NoWarm          # launcher switches work too (-KeepLoaded)
#   opencode                          # no profile name: the real opencode, as before
#
# A profile name is a live profile's basename (profiles/dev-*.sh; parked
# profiles and select-model.sh are not), with or without its "dev-workflow-" or
# "dev-" prefix, any case. A name goes to desktop\scripts\opencode.ps1, which
# loads that profile's models for this one launch and puts the shell's env back
# afterwards. Anything else is passed to the real opencode untouched.
#
# A profile name wins over a project directory of the same name in the current
# directory; open such a directory as .\quality.
#
# Only PowerShell sees this function: Git Bash and cmd still run the real
# opencode.

$global:OpencodeProfilesRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Resolve-OpencodeProfile {
    param([string]$Name, [string]$ProfilesDir)
    if (-not $Name -or $Name.StartsWith("-")) { return $null }
    if (-not (Test-Path -LiteralPath $ProfilesDir)) { return $null }
    foreach ($p in @(Get-ChildItem -LiteralPath $ProfilesDir -Filter "dev-*.sh" -File | ForEach-Object { $_.BaseName })) {
        if ($Name -ieq $p -or $Name -ieq ($p -replace '^dev-workflow-', '') -or $Name -ieq ($p -replace '^dev-', '')) {
            return $p
        }
    }
    return $null
}

function opencode {
    $repo = $global:OpencodeProfilesRepo
    $name = if ($args.Count -gt 0) { [string]$args[0] } else { "" }
    $profileName = Resolve-OpencodeProfile -Name $name -ProfilesDir (Join-Path $repo "profiles")
    if ($profileName) {
        $rest = @($args | Select-Object -Skip 1)
        & (Join-Path $repo "desktop\scripts\opencode.ps1") -Profile $profileName @rest
        return
    }
    # Skip this function: the first opencode on PATH that is a file, not a function.
    $real = Get-Command opencode -CommandType ExternalScript, Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $real) {
        Write-Host "[opencode] ERROR: opencode is not installed (not on PATH)" -ForegroundColor Red
        return
    }
    & $real @args
}

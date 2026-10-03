# install-opencode-profiles.ps1 — add `opencode <profile>` to your PowerShell profiles
#
# Appends one line that dot-sources desktop\scripts\opencode-profiles.ps1 to the
# current-user profile of PowerShell 7 and of Windows PowerShell 5.1, creating
# either file if it does not exist. Idempotent: a profile that already has the
# line is left alone. Open a new terminal afterwards (or dot-source $PROFILE).
#
# Usage:
#   .\desktop\scripts\install-opencode-profiles.ps1             # install
#   .\desktop\scripts\install-opencode-profiles.ps1 -Uninstall  # remove the line

[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = "Stop"

$shim   = Join-Path $PSScriptRoot "opencode-profiles.ps1"
$marker = "# dev-docs: opencode <profile>"
# Guarded, so a checkout without the file (another branch, a moved repo) does
# not print an error at every shell start.
$line   = "if (Test-Path -LiteralPath '$shim') { . '$shim' }  $marker"
$docs   = [Environment]::GetFolderPath("MyDocuments")
$targets = @(
    (Join-Path $docs "PowerShell\Microsoft.PowerShell_profile.ps1"),
    (Join-Path $docs "WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
)

foreach ($t in $targets) {
    $existing = @()
    if (Test-Path -LiteralPath $t) { $existing = @(Get-Content -LiteralPath $t) }
    $has = @($existing | Where-Object { $_.Contains($marker) }).Count -gt 0

    if ($Uninstall) {
        if ($has) {
            Set-Content -LiteralPath $t -Value @($existing | Where-Object { -not $_.Contains($marker) })
            Write-Host "[install] removed from $t"
        } else {
            Write-Host "[install] not present in $t"
        }
        continue
    }

    if ($has) {
        Write-Host "[install] already in $t"
        continue
    }
    $dir = Split-Path -Parent $t
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Add-Content -LiteralPath $t -Value $line
    Write-Host "[install] added to $t"
}

if (-not $Uninstall) {
    Write-Host "[install] open a new terminal, then: opencode quality | opencode resident | opencode desktop-only | opencode node3"
}

# opencode-template.ps1 - shared helpers for staging the OpenCode config template.
# Dot-source it:  . (Join-Path $PSScriptRoot "opencode-template.ps1")
#
# Used by desktop/scripts/sync-opencode.ps1 and tests/test-sync-opencode.ps1, so the
# placeholder is resolved one way everywhere. Defines functions only; no side effects.

# The token the template uses where this checkout's location belongs (the plugin
# paths). Staging replaces it with the checkout's file:/// URL.
$script:RepoUrlToken = "__REPO_URL__"

# file:/// URL of a directory, forward slashes, no trailing slash
# (C:\HomeLab\dev-docs -> file:///C:/HomeLab/dev-docs; a space becomes %20).
function Get-RepoRootUrl([string]$RepoRoot) {
    $full = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    return ([Uri]::new($full + [IO.Path]::DirectorySeparatorChar)).AbsoluteUri.TrimEnd('/')
}

# Template text with the token replaced by this checkout's URL.
function Expand-OpenCodeTemplate([string]$Text, [string]$RepoRoot) {
    return $Text.Replace($script:RepoUrlToken, (Get-RepoRootUrl $RepoRoot))
}

# machines.tsv -> objects with Name, Roles (string[]), Note. Header row required.
function Get-MachineRoles([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "machine-roles file not found: $Path" }
    $lines = @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() -and -not $_.StartsWith('#') })
    if ($lines.Count -lt 2) { throw "machine-roles file has no rows: $Path" }
    $head = $lines[0].Split("`t")
    $iName = [array]::IndexOf($head, 'name'); $iRoles = [array]::IndexOf($head, 'roles'); $iNote = [array]::IndexOf($head, 'note')
    if ($iName -lt 0 -or $iRoles -lt 0) { throw "machine-roles file needs 'name' and 'roles' columns: $Path" }
    foreach ($l in $lines[1..($lines.Count - 1)]) {
        $c = $l.Split("`t")
        [pscustomobject]@{
            Name  = $c[$iName].Trim()
            Roles = @($c[$iRoles] -split '\s+' | Where-Object { $_ })
            Note  = if ($iNote -ge 0 -and $c.Count -gt $iNote) { $c[$iNote].Trim() } else { "" }
        }
    }
}

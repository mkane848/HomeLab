# pull-household-backup.ps1 - copy the newest household tracker backup off the server, to this PC.
#
# Phase 1 of docs/household-assistant.md; runbook docs/household/phase1.md -> "Backups".
# The server makes the backup (server/household/backup.sh, nightly at 03:15); this keeps a second copy here,
# so the household's history survives the server (it has been down for weeks before).
#
# Uses the fleet SSH key through the `server` alias in ~/.ssh/config (docs/network-topology.md -> "SSH access"),
# in batch mode so it never waits on a prompt. Run by hand, or nightly as a scheduled task (see the runbook).
param(
    [string]$HostAlias = 'server',
    [string]$RemoteDir = 'backups/household',
    [string]$LocalDir = (Join-Path $env:USERPROFILE 'Backups\household'),
    [int]$Keep = 30
)
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

# -n: stdin from /dev/null, so ssh never waits for input (PowerShell has no `< file` redirection).
$newest = (& ssh -n -o BatchMode=yes $HostAlias "ls -1t $RemoteDir/grocy-*.tar.gz 2>/dev/null | head -n 1")
if ($LASTEXITCODE -ne 0 -or -not $newest) {
    throw "pull-household-backup: no backup found on ${HostAlias}:$RemoteDir (ssh exit ${LASTEXITCODE})"
}
$newest = $newest.Trim()
$name = Split-Path -Leaf $newest
$dest = Join-Path $LocalDir $name

if (Test-Path $dest) {
    Write-Host "pull-household-backup: $name already here"
} else {
    & scp -o BatchMode=yes -q "${HostAlias}:$newest" "$dest.partial"
    if ($LASTEXITCODE -ne 0) { throw "pull-household-backup: scp failed (exit ${LASTEXITCODE})" }
    if ((Get-Item "$dest.partial").Length -le 0) { throw "pull-household-backup: $name arrived empty" }
    Move-Item -Force "$dest.partial" $dest
    Write-Host "pull-household-backup: copied $name ($([math]::Round((Get-Item $dest).Length / 1KB)) KB)"
}

Get-ChildItem $LocalDir -Filter 'grocy-*.tar.gz' | Sort-Object LastWriteTime -Descending |
    Select-Object -Skip $Keep | Remove-Item -Force

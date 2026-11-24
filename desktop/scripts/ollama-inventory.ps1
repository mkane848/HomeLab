# ollama-inventory.ps1 - the dry run of the Ollama uninstall on a Windows machine (the desktop or node3): what it
# would remove, and whether that is safe. It changes nothing.
#
# Ollama was removed from the fleet on 2026-11-21 (docs/roadmap.md -> "Ollama removed (2026-11-21)"), but the
# desktop and node3 still have their native installs, model stores, OLLAMA_* User variables and, on the desktop, an
# updater firewall rule. Deleting them is the owner's step, after a dry run and a hash-compare (AGENTS.md ->
# "Before deleting anything"). This script is that dry run:
#   1. It lists the install and its uninstaller, any running Ollama process, the model store with its size, the
#      OLLAMA_* environment variables, and the startup entries, scheduled tasks and firewall rules that name Ollama.
#   2. It checks that nothing still needs the store. Every llama.cpp preset model on this machine (node3's
#      node3/llamacpp/models.ini; the desktop runs no models) must load from outside the Ollama store, and its sha256
#      must match a `weights` pin in models/server-seats.tsv. -NoHash skips the re-hash.
#   3. When the check passes, it prints the commands that would remove it all, for the owner to read and run. It
#      runs none of them.
# Exit 0: ready, or nothing left. 1: a blocker, named. 2: usage (a given path does not exist).
#
# Usage (pwsh 7, from the repo; on node3 copy it over and run it with `pwsh -NoProfile -File`):
#   pwsh -NoProfile -File desktop\scripts\ollama-inventory.ps1 [-NoHash] [-StorePath <dir>] [-IniPath <models.ini>]
#        [-SeatsPath <server-seats.tsv>]
param(
    [switch]$NoHash,
    [string]$StorePath = "",
    [string]$IniPath = "",
    [string]$SeatsPath = ""
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $IniPath) { $IniPath = Join-Path $repo "node3/llamacpp/models.ini" }
if (-not $SeatsPath) { $SeatsPath = Join-Path $repo "models/server-seats.tsv" }
foreach ($p in $IniPath, $SeatsPath) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "[ollama-inventory] not found: $p"; exit 2 }
}

$found = New-Object System.Collections.Generic.List[string]     # one line per thing that would be removed
$commands = New-Object System.Collections.Generic.List[string]  # the commands that would remove it
$blockers = New-Object System.Collections.Generic.List[string]

function Get-OllamaVar([string]$Name) {
    foreach ($scope in "Process", "User", "Machine") {
        if ($scope -ne "Process" -and -not $IsWindows) { continue }
        $v = [Environment]::GetEnvironmentVariable($Name, $scope)
        if ($v) { return $v }
    }
    return $null
}

# --- 1. what is there ---------------------------------------------------------------------------
$procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^ollama' })
foreach ($p in $procs) { $found.Add("process    $($p.ProcessName) (pid $($p.Id))") }
if ($procs.Count) { $commands.Add("Get-Process | Where-Object { `$_.ProcessName -match '^ollama' } | Stop-Process") }

if ($IsWindows) {
    $install = Join-Path $env:LOCALAPPDATA "Programs\Ollama"
    if (Test-Path -LiteralPath $install) {
        $found.Add("install    $install")
        $unins = @(Get-ChildItem -LiteralPath $install -Filter "unins*.exe" -File -ErrorAction SilentlyContinue)
        if ($unins.Count) { $commands.Add("& '$($unins[0].FullName)'   # Ollama's own uninstaller") }
        else { $commands.Add("# Settings > Apps > Installed apps > Ollama > Uninstall (no uninstaller found in $install)") }
    }
}

if (-not $StorePath) {
    $StorePath = Get-OllamaVar "OLLAMA_MODELS"
    if (-not $StorePath) { $StorePath = Join-Path $HOME ".ollama/models" }
}
$store = $null
if (Test-Path -LiteralPath $StorePath) {
    $store = (Resolve-Path -LiteralPath $StorePath).Path
    $files = @(Get-ChildItem -LiteralPath $store -Recurse -File -Force -ErrorAction SilentlyContinue)
    $gb = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum) / 1GB, 1)
    $found.Add("store      $store ($($files.Count) files, $gb GB)")
    $commands.Add("Remove-Item -LiteralPath '$store' -Recurse -Force")
}

$vars = @()
if ($IsWindows) {
    foreach ($scope in "User", "Machine") {
        $all = [Environment]::GetEnvironmentVariables($scope)
        foreach ($k in @($all.Keys | Where-Object { $_ -like "OLLAMA_*" } | Sort-Object)) {
            $vars += [pscustomobject]@{ Name = $k; Scope = $scope; Value = $all[$k] }
        }
    }
} else {
    foreach ($k in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like "OLLAMA_*" } | Sort-Object)) {
        $vars += [pscustomobject]@{ Name = $k; Scope = "Process"; Value = [Environment]::GetEnvironmentVariable($k) }
    }
}
foreach ($v in $vars) {
    $found.Add("variable   $($v.Name)=$($v.Value) ($($v.Scope))")
    if ($v.Scope -eq "Machine") { $commands.Add("[Environment]::SetEnvironmentVariable('$($v.Name)', `$null, 'Machine')   # needs an elevated shell") }
    elseif ($v.Scope -eq "User") { $commands.Add("[Environment]::SetEnvironmentVariable('$($v.Name)', `$null, 'User')") }
}

if ($IsWindows) {
    $run = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runProps = Get-ItemProperty -LiteralPath $run -ErrorAction SilentlyContinue
    if ($runProps) {
        foreach ($prop in $runProps.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" -and "$($_.Value)" -match 'ollama' }) {
            $found.Add("startup    Run key value '$($prop.Name)'")
            $commands.Add("Remove-ItemProperty -LiteralPath '$run' -Name '$($prop.Name)'")
        }
    }
    $startup = [Environment]::GetFolderPath("Startup")
    foreach ($lnk in @(Get-ChildItem -LiteralPath $startup -Filter "*ollama*" -ErrorAction SilentlyContinue)) {
        $found.Add("startup    $($lnk.FullName)")
        $commands.Add("Remove-Item -LiteralPath '$($lnk.FullName)'")
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'ollama' })) {
        $found.Add("task       $($t.TaskPath)$($t.TaskName)")
        $commands.Add("Unregister-ScheduledTask -TaskName '$($t.TaskName)' -TaskPath '$($t.TaskPath)' -Confirm:`$false")
    }
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        foreach ($r in @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'ollama' -or $_.Name -match 'ollama' })) {
            $found.Add("firewall   $($r.DisplayName) ($($r.Direction), $($r.Action))")
            $commands.Add("Remove-NetFirewallRule -Name '$($r.Name)'   # needs an elevated shell")
        }
    }
}

foreach ($line in $found) { Write-Host $line }
if (-not $found.Count) { Write-Host "[ollama-inventory] nothing Ollama is left on this machine"; exit 0 }

# --- 2. does llama.cpp still need anything of it ------------------------------------------------
$pins = @{}
foreach ($line in Get-Content -LiteralPath $SeatsPath) {
    if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
    $cols = $line -split "`t"
    if ($cols.Count -ge 5 -and $cols[4] -match '^sha256:([0-9a-f]{64})$') { $pins[$Matches[1]] = $cols[0] }
}
$models = @()
foreach ($line in Get-Content -LiteralPath $IniPath) {
    if ($line -match '^\s*model\s*=\s*(.+?)\s*$') { $models += $Matches[1] }
}
$here = @($models | Where-Object { Test-Path -LiteralPath $_ })
if (-not $here.Count) {
    Write-Host "[ollama-inventory] no llama.cpp preset in $IniPath loads a file on this machine"
}
foreach ($m in $here) {
    $full = (Resolve-Path -LiteralPath $m).Path
    if ($store -and ($full.StartsWith($store.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
        $blockers.Add("the llama.cpp preset loads $full, which is inside the Ollama store")
        continue
    }
    if ($NoHash) { Write-Host "[ollama-inventory] $full exists (not re-hashed: -NoHash)"; continue }
    $sha = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($pins.ContainsKey($sha)) { Write-Host "[ollama-inventory] $full matches the pin of $($pins[$sha])" }
    else { $blockers.Add("$full (sha256 $sha) matches no weights pin in $SeatsPath, so the Ollama store may hold the only good copy") }
}

# --- 3. the verdict, and the commands --------------------------------------------------------------
if ($blockers.Count) {
    Write-Host ""
    Write-Host "[ollama-inventory] NOT READY - nothing should be deleted yet:"
    foreach ($b in $blockers) { Write-Host "  - $b" }
    exit 1
}
Write-Host ""
Write-Host "[ollama-inventory] READY. Nothing has been deleted. To remove it (not reversible; read before running):"
foreach ($c in $commands) { Write-Host "  $c" }
if ($NoHash -and $here.Count) { Write-Host "  (the weights were not re-hashed: run again without -NoHash before deleting the store)" }
exit 0

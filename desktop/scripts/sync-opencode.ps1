# sync-opencode.ps1 - Stage the repo's OpenCode config template on THIS machine.
#
# Default (and -Template, kept as an alias): local only, no network, no .env needed.
#   opencode/global/opencode.jsonc  -> ~/.config/opencode/opencode.jsonc
#   opencode/agents/*.md            -> ~/.config/opencode/agents/
#   opencode/commands/*.md          -> ~/.config/opencode/commands/
#   - The template's plugin paths carry a placeholder token (__REPO_URL__ with the
#     underscores, see desktop/scripts/opencode-template.ps1); staging replaces it
#     with this checkout's file:/// URL, so the template names no machine.
#   - Before the live opencode.jsonc is overwritten it is copied to
#     opencode.jsonc.bak-yyyyMMdd-HHmmss and a diff summary is printed. Identical
#     content: nothing is written and no backup is made.
#   - Afterwards `opencode debug config` is run (if opencode is on PATH) to report
#     whether the config loads and whether every plugin path it lists exists.
#     Absent opencode or a bad plugin path is a WARNING, never a failure.
#   Files that only exist locally (agents, commands, secrets) are left alone.
#
# Copying to another machine is opt-in:
#   -Push <machine>   after staging, scp the staged config + agents + commands to
#                     that machine. <machine> must be a row of machines.tsv (repo
#                     root) that has the `opencode-client` role, else exit 1 with
#                     nothing sent. Host and user come from .env (SSH_USER, and
#                     SERVER_IP for `server`, else <NAME>_IP); .env is read only in
#                     this mode. A down host is a warning and exit 0, as before.
#   -RemoteRepoRoot <path>
#                     with -Push: the target's checkout path, so the pushed config's
#                     plugin paths name THAT checkout. Without it they name this one
#                     and a warning says so.
#   -Secrets a,b      with -Push only: also copy these files from .secrets/ (file
#                     names, no paths). There is no "all": API keys never travel
#                     implicitly.
#
# The server is a model host only (machines.tsv): nothing here pushes to it.
#
# Usage:
#   .\desktop\scripts\sync-opencode.ps1                        # stage locally
#   .\desktop\scripts\sync-opencode.ps1 -Push desktop -Secrets opencode-go-key
#
# Restart any running opencode afterwards: config, agents and commands are read at
# session start. node_modules/ in the local config dir is never touched.

param(
    [switch]$Template,
    [string]$Push = "",
    [string[]]$Secrets = @(),
    [string]$RemoteRepoRoot = ""
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "opencode-template.ps1")

$REPO_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ENV_FILE = Join-Path $REPO_ROOT ".env"
$TEMPLATE_FILE = Join-Path $REPO_ROOT "opencode/global/opencode.jsonc"
$MACHINES_FILE = Join-Path $REPO_ROOT "machines.tsv"
$LOCAL_CONFIG = Join-Path $env:USERPROFILE ".config/opencode"
$LIVE = Join-Path $LOCAL_CONFIG "opencode.jsonc"

function Fail([string]$msg) { Write-Host "[sync] ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- Validate the arguments before touching anything ---
$Secrets = @($Secrets | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Secrets.Count -gt 0 -and -not $Push) { Fail "-Secrets only works together with -Push <machine>. Secrets are never copied implicitly." }
foreach ($s in $Secrets) {
    if ($s -match '[\\/]' -or $s -match '[*?]' -or $s -eq '..' -or $s -eq '.') { Fail "-Secrets takes file names inside .secrets/, not paths or wildcards: '$s'" }
}
if ($RemoteRepoRoot -and -not $Push) { Fail "-RemoteRepoRoot only works together with -Push <machine>." }

if ($Push) {
    $machine = @(Get-MachineRoles $MACHINES_FILE) | Where-Object { $_.Name -eq $Push } | Select-Object -First 1
    if (-not $machine) { Fail "unknown machine '$Push' (not in machines.tsv)." }
    if ($machine.Roles -notcontains "opencode-client") {
        Fail "'$Push' has no opencode-client role in machines.tsv (roles: $($machine.Roles -join ', ')). Nothing was sent."
    }
}

# --- Stage locally ---
if (-not (Test-Path -LiteralPath $TEMPLATE_FILE)) { Fail "template not found at $TEMPLATE_FILE" }
New-Item -ItemType Directory -Path $LOCAL_CONFIG -Force | Out-Null

$newText = Expand-OpenCodeTemplate (Get-Content -LiteralPath $TEMPLATE_FILE -Raw) $REPO_ROOT
if (Test-Path -LiteralPath $LIVE) {
    $oldText = Get-Content -LiteralPath $LIVE -Raw
    if ($oldText -ceq $newText) {
        Write-Host "[sync] opencode.jsonc is already identical to the template; nothing written, no backup." -ForegroundColor Cyan
    } else {
        $oldLines = @($oldText -split "`r?`n"); $newLines = @($newText -split "`r?`n")
        $diff = @(Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines -CaseSensitive)
        $removed = @($diff | Where-Object SideIndicator -eq '<='); $added = @($diff | Where-Object SideIndicator -eq '=>')
        $bak = "$LIVE.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $LIVE -Destination $bak
        Write-Host "[sync] Backed up the live config -> $bak" -ForegroundColor Cyan
        Write-Host "[sync] opencode.jsonc changes: $($added.Count) line(s) added, $($removed.Count) removed" -ForegroundColor Cyan
        foreach ($d in ($removed | Select-Object -First 15)) { Write-Host ("  - " + $d.InputObject.Trim()) -ForegroundColor DarkYellow }
        foreach ($d in ($added | Select-Object -First 15)) { Write-Host ("  + " + $d.InputObject.Trim()) -ForegroundColor DarkGreen }
        if ($removed.Count -gt 15 -or $added.Count -gt 15) { Write-Host "  ... (more; diff the backup against the live file)" }
        [IO.File]::WriteAllText($LIVE, $newText, [Text.UTF8Encoding]::new($false))
        Write-Host "[sync] Staged repo template -> $LIVE" -ForegroundColor Cyan
    }
} else {
    [IO.File]::WriteAllText($LIVE, $newText, [Text.UTF8Encoding]::new($false))
    Write-Host "[sync] Staged repo template -> $LIVE (no previous config)" -ForegroundColor Cyan
}

# Subagent and command templates: copied when different, local-only files left alone.
foreach ($d in @(@{ Src = Join-Path $REPO_ROOT "opencode/agents"; Name = "agents" }, @{ Src = Join-Path $REPO_ROOT "opencode/commands"; Name = "commands" })) {
    if (-not (Test-Path -LiteralPath $d.Src)) { continue }
    $target = Join-Path $LOCAL_CONFIG $d.Name
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Get-ChildItem -LiteralPath $d.Src -Filter *.md -File | ForEach-Object {
        $dest = Join-Path $target $_.Name
        if ((Test-Path -LiteralPath $dest) -and ((Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $_.FullName).Hash)) {
            Write-Host "[sync] $($d.Name)/$($_.Name) unchanged"
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
            Write-Host "[sync] Staged $($d.Name)/$($_.Name)" -ForegroundColor Cyan
        }
    }
}

# --- Does it load, and do the plugin paths exist? ---
if (Get-Command opencode -ErrorAction SilentlyContinue) {
    $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $raw = (& opencode debug config 2>&1 | Out-String)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $eap
    $cfg = $null
    try { $cfg = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
    if ($code -ne 0 -or -not $cfg) {
        Write-Host "[sync] WARNING: 'opencode debug config' did not load cleanly (exit $code). Run it by hand." -ForegroundColor Yellow
    } else {
        Write-Host "[sync] opencode debug config: loads." -ForegroundColor Green
        foreach ($p in @($cfg.plugin | Where-Object { $_ -is [string] -and $_ -match '^file:' })) {
            $path = try { ([Uri]$p).LocalPath } catch { $null }
            if ($path -and (Test-Path -LiteralPath $path)) { Write-Host "[sync]   plugin ok: $path" -ForegroundColor Green }
            else { Write-Host "[sync] WARNING: plugin path does not exist: $p" -ForegroundColor Yellow }
        }
    }
} else {
    Write-Host "[sync] WARNING: opencode is not on PATH; skipped the 'opencode debug config' check." -ForegroundColor Yellow
}

if (-not $Push) {
    Write-Host ""
    Write-Host "=== Staged locally. Restart any running opencode to pick up changes. ===" -ForegroundColor Green
    exit 0
}

# --- Opt-in: copy to another machine ---
if (-not (Test-Path -LiteralPath $ENV_FILE)) { Fail "$ENV_FILE not found. -Push needs SSH_USER and the host address in .env." }
$vars = @{}
Get-Content $ENV_FILE | Where-Object { $_ -match "^[^#]" -and $_ -match "=" } | ForEach-Object {
    $kv = $_ -split "=", 2
    $vars[$kv[0].Trim()] = $kv[1].Trim()
}
$user = $vars["SSH_USER"]
$hostKey = if ($Push -eq "server") { "SERVER_IP" } else { ($Push.ToUpper() + "_IP") }
$host_ = $vars[$hostKey]
if (-not $user -or -not $host_) { Fail "SSH_USER and $hostKey must be set in $ENV_FILE" }

foreach ($s in $Secrets) {
    if (-not (Test-Path -LiteralPath (Join-Path $LOCAL_CONFIG ".secrets/$s") -PathType Leaf)) { Fail "no such secret file: .secrets/$s (nothing was sent)" }
}

# The pushed config: this checkout's plugin paths only mean something on this machine.
$pushConfig = $LIVE
$tmpConfig = $null
if ($RemoteRepoRoot) {
    $tmpConfig = Join-Path ([IO.Path]::GetTempPath()) ("opencode-push-" + [guid]::NewGuid().ToString("N") + ".jsonc")
    [IO.File]::WriteAllText($tmpConfig, (Expand-OpenCodeTemplate (Get-Content -LiteralPath $TEMPLATE_FILE -Raw) $RemoteRepoRoot), [Text.UTF8Encoding]::new($false))
    $pushConfig = $tmpConfig
} else {
    Write-Host "[sync] WARNING: the pushed config's plugin paths name THIS checkout ($REPO_ROOT). Pass -RemoteRepoRoot <path on $Push> to fix them." -ForegroundColor Yellow
}

try {
    Write-Host ""
    Write-Host "=== Push OpenCode config to $Push (${user}@${host_}) ===" -ForegroundColor Cyan
    Write-Host "[0/4] Checking SSH to $host_ ..."
    # A native command's stderr is a terminating error under Stop; drop to Continue
    # for the probe. 2>&1 hides ssh's connection error; $LASTEXITCODE decides.
    $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    ssh -o ConnectTimeout=5 "${user}@${host_}" "true" 2>&1 | Out-Null
    $probeExit = $LASTEXITCODE
    $ErrorActionPreference = $eap
    if ($probeExit -ne 0) {
        Write-Host "[sync] WARNING: ${host_} unreachable (or refused the connection)." -ForegroundColor Yellow
        Write-Host "[sync] Local config was staged. Push skipped - run again when the host is back." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "[1/4] Creating remote directories..."
    ssh "${user}@${host_}" "mkdir -p ~/.config/opencode/.secrets ~/.config/opencode/skills ~/.config/opencode/agents ~/.config/opencode/commands ~/.config/opencode/tools ~/.config/opencode/plugins ~/.config/opencode/themes && chmod 700 ~/.config/opencode/.secrets"
    if ($LASTEXITCODE -ne 0) { Fail "ssh failed." }

    Write-Host "[2/4] Pushing opencode.jsonc..."
    scp $pushConfig "${user}@${host_}:~/.config/opencode/opencode.jsonc"
    if ($LASTEXITCODE -ne 0) { Fail "scp config failed." }

    Write-Host "[3/4] Pushing agents/* and commands/*..."
    foreach ($d in @(@{ Src = Join-Path $LOCAL_CONFIG "agents"; Remote = "agents" }, @{ Src = Join-Path $LOCAL_CONFIG "commands"; Remote = "commands" })) {
        if (-not (Test-Path -LiteralPath $d.Src)) { continue }
        Get-ChildItem -LiteralPath $d.Src -Filter *.md -File | ForEach-Object {
            Write-Host "  + $($d.Remote)/$($_.Name)"
            scp $_.FullName "${user}@${host_}:~/.config/opencode/$($d.Remote)/$($_.Name)"
            if ($LASTEXITCODE -ne 0) { Fail "scp $($d.Remote) failed." }
        }
    }

    Write-Host "[4/4] Pushing the named secrets ($($Secrets.Count))..."
    foreach ($s in $Secrets) {
        $src = Join-Path $LOCAL_CONFIG ".secrets/$s"
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Fail "no such secret file: .secrets/$s" }
        Write-Host "  + .secrets/$s"
        scp $src "${user}@${host_}:~/.config/opencode/.secrets/$s"
        if ($LASTEXITCODE -ne 0) { Fail "scp secret failed." }
    }
} finally {
    if ($tmpConfig) { Remove-Item -LiteralPath $tmpConfig -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "=== Push complete. Restart any running opencode on $Push. ===" -ForegroundColor Green

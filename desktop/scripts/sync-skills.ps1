# sync-skills.ps1 — Deploy imported skills/commands/agents to OpenCode config dirs.
#
# Sources (in dev-docs):
#   skills/<source>/<skill>/      ->  ~/.config/opencode/skills/<skill>/   (flattened)
#   opencode/commands/<name>.md   ->  ~/.config/opencode/commands/<name>.md
#   opencode/agents/<name>.md     ->  ~/.config/opencode/agents/<name>.md
#
# Targets:
#   -Local   : this Windows machine ($env:USERPROFILE\.config\opencode)
#   -Server  : Ubuntu server via scp (uses SSH_USER + SERVER_IP from dev-docs\.env)
#
# SCOPE - why every skill is NOT deployed globally
#   opencode advertises the name + description of EVERY installed skill in the
#   system prompt of EVERY request. All 65 vendored skills cost ~5.5k tokens on
#   every single call, on every project, forever - and a 16k-32k local model
#   pays that out of its working window.
#
#   So only $GLOBAL_SKILL_SOURCES deploy to ~/.config/opencode/skills. The rest
#   stay in this repo and a project opts into them from its own opencode.jsonc:
#
#       "skills": { "paths": ["M:/Projects/dev-docs/skills/vercel"] }
#
#   Nothing is copied for that - opencode scans the path for **/SKILL.md, so a
#   project always sees the current repo content. See
#   opencode/project-override/opencode.jsonc.
#
# Usage:
#   .\desktop\scripts\sync-skills.ps1                # both targets, global scope
#   .\desktop\scripts\sync-skills.ps1 -Local         # Windows only
#   .\desktop\scripts\sync-skills.ps1 -Server        # server only
#   .\desktop\scripts\sync-skills.ps1 -Scope all     # deploy every source globally
#   .\desktop\scripts\sync-skills.ps1 -SkipSkills    # limit scope
#
# Notes:
#   - Server push requires SSH access (password prompt, or key auth).
#   - Files are copied verbatim; re-running is safe (overwrites).
#   - -Prune removes globally-deployed skills that are no longer in scope.

param(
    [switch]$Local,
    [switch]$Server,
    [switch]$SkipSkills,
    [switch]$SkipCommands,
    [switch]$SkipAgents,
    [switch]$DryRun,
    [ValidateSet("global", "all")][string]$Scope = "global",
    [switch]$Prune
)

$ErrorActionPreference = "Stop"

# Skill sources that are useful on ANY project and so earn their place in every
# request's system prompt. Everything else (vercel, render, ...) is referenced
# per-project via skills.paths instead.
$GLOBAL_SKILL_SOURCES = @("frontend-design", "ui-ux-pro-max")

$REPO_ROOT = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SKILLS_SRC = Join-Path $REPO_ROOT "skills"
$COMMANDS_SRC = Join-Path $REPO_ROOT "opencode\commands"
$AGENTS_SRC = Join-Path $REPO_ROOT "opencode\agents"

if (-not $Local -and -not $Server) { $Local = $true; $Server = $true }

# --- Parse .env (KEY=VALUE) ---
function Get-EnvVars {
    param([string]$EnvFile)
    $vars = @{}
    Get-Content $EnvFile | Where-Object { $_ -match "^[^#]" -and $_ -match "=" } | ForEach-Object {
        $kv = $_ -split "=", 2
        $vars[$kv[0].Trim()] = $kv[1].Trim()
    }
    return $vars
}

# --- Stage flattened payloads ---
$STAGE = Join-Path $env:TEMP "opencode-skillstage"
if (Test-Path -LiteralPath $STAGE) { Remove-Item -LiteralPath $STAGE -Recurse -Force }
$SEEN = @{}

$stageSkills = Join-Path $STAGE "skills"
$stageCommands = Join-Path $STAGE "commands"
$stageAgents = Join-Path $STAGE "agents"
New-Item -ItemType Directory -Path $stageSkills, $stageCommands, $stageAgents -Force | Out-Null

$fileCount = 0

if (-not $SkipSkills) {
    Write-Host "[stage] skills (scope: $Scope):" -ForegroundColor Cyan
    $sources = Get-ChildItem -LiteralPath $SKILLS_SRC -Directory
    if ($Scope -eq "global") {
        $skipped = $sources | Where-Object { $GLOBAL_SKILL_SOURCES -notcontains $_.Name }
        $sources = $sources | Where-Object { $GLOBAL_SKILL_SOURCES -contains $_.Name }
        foreach ($s in $skipped) {
            $n = (Get-ChildItem -LiteralPath $s.FullName -Directory).Count
            Write-Host "  - $($s.Name) ($n skills) -> project-scoped, reference via skills.paths" -ForegroundColor DarkGray
        }
    }
    $sources | ForEach-Object {
        $srcName = $_.Name
        Get-ChildItem -LiteralPath $_.FullName -Directory | ForEach-Object {
            if ($DryRun) {
                Write-Host "  + $srcName/$($_.Name)" -ForegroundColor Cyan
            } else {
                $dest = Join-Path $stageSkills $_.Name
                if ($SEEN.ContainsKey($_.Name)) {
                    Write-Host "  ! collides with $($SEEN[$_.Name]) - overwriting with $($_.Name)" -ForegroundColor Yellow
                } else {
                    $SEEN[$_.Name] = $_.FullName
                }
                Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
                Write-Host "  + $srcName/$($_.Name)"
                $fileCount++
            }
        }
    }
}

if (-not $SkipCommands) {
    Write-Host "[stage] commands:" -ForegroundColor Cyan
    Get-ChildItem -LiteralPath $COMMANDS_SRC -Filter *.md | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stageCommands $_.Name) -Force
        Write-Host "  + $($_.Name)"; $fileCount++
    }
}

if (-not $SkipAgents) {
    Write-Host "[stage] agents:" -ForegroundColor Cyan
    Get-ChildItem -LiteralPath $AGENTS_SRC -Filter *.md | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stageAgents $_.Name) -Force
        Write-Host "  + $($_.Name)"; $fileCount++
    }
}

if ($fileCount -eq 0) { Write-Host "Nothing to stage." -ForegroundColor Yellow; return }

# --- Local deploy ---
if ($Local) {
    Write-Host ""
    Write-Host "=== Local (~/.config/opencode) ===" -ForegroundColor Cyan
    $localBase = "$env:USERPROFILE\.config\opencode"

    # -Prune drops globally-deployed skills that this run did not stage. Without
    # it, narrowing the scope leaves the old skills in place and the system
    # prompt never actually shrinks.
    if ($Prune -and -not $SkipSkills) {
        $liveSkills = Join-Path $localBase "skills"
        if (Test-Path -LiteralPath $liveSkills) {
            $staged = (Get-ChildItem -LiteralPath $stageSkills -Directory -ErrorAction SilentlyContinue).Name
            $stale = Get-ChildItem -LiteralPath $liveSkills -Directory | Where-Object { $staged -notcontains $_.Name }
            foreach ($d in $stale) {
                if ($DryRun) {
                    Write-Host "  - pruned $($d.Name)" -ForegroundColor DarkGray
                } else {
                    Remove-Item -LiteralPath $d.FullName -Recurse -Force
                    Write-Host "  - pruned $($d.Name)" -ForegroundColor DarkGray
                }
            }
            if ($stale.Count) { Write-Host "  pruned $($stale.Count) out-of-scope skill(s)" -ForegroundColor Yellow }
        }
    }

    foreach ($pair in @(@("skills", "skills"), @("commands", "commands"), @("agents", "agents"))) {
        $src = Join-Path $STAGE $pair[0]
        $dst = Join-Path $localBase $pair[1]
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
            if ($DryRun) {
                Write-Host "  + $($pair[1])/$($_.Name)" -ForegroundColor Cyan
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $dst -Recurse -Force
                Write-Host "  + $($pair[1])/$($_.Name)"
            }
        }
        Write-Host "  synced -> $dst ($( (Get-ChildItem -LiteralPath $dst -Force | Measure-Object).Count ) items)"
    }

    # Clean up the singular-named dirs this script previously created
    foreach ($legacy in @("command", "agent")) {
        $legacyDir = Join-Path $localBase $legacy
        if (Test-Path -LiteralPath $legacyDir) {
            if (-not $DryRun) {
                Remove-Item -LiteralPath $legacyDir -Recurse -Force
                Write-Host "  removed legacy ~/.config/opencode/$legacy"
            } else {
                Write-Host "  legacy ~/.config/opencode/$legacy exists (dry run)" -ForegroundColor DarkGray
            }
        }
    }
}

# --- Server deploy ---
if ($Server) {
    Write-Host ""
    Write-Host "=== Server ===" -ForegroundColor Cyan
    $vars = Get-EnvVars -EnvFile (Join-Path $REPO_ROOT ".env")
    $user = $vars["SSH_USER"]
    $host_ = $vars["SERVER_IP"]
    if (-not $user -or -not $host_) {
        Write-Host "ERROR: SSH_USER/SERVER_IP missing from .env - skip server sync" -ForegroundColor Red
        return
    }
    $remote = "${user}@${host_}"

    if ($DryRun) {
        Write-Host "  (dry run) would create remote dirs" -ForegroundColor Cyan
    } else {
        Write-Host "  creating remote dirs..."
        ssh $remote "mkdir -p ~/.config/opencode/skills ~/.config/opencode/commands ~/.config/opencode/agents"
        if ($LASTEXITCODE -ne 0) { Write-Host "ssh failed - server sync aborted" -ForegroundColor Red; return }
    }

    foreach ($pair in @(@("skills", "skills"), @("commands", "commands"), @("agents", "agents"))) {
        $src = Join-Path $STAGE $pair[0]
        Write-Host "  pushing $($pair[0]) -> ~/.config/opencode/$($pair[1])"
        if ($DryRun) {
            Write-Host "  (dry run) would transfer $($pair[0]) to server" -ForegroundColor Cyan
        } else {
            scp -r -q -o StrictHostKeyChecking=accept-new $src "${remote}:~/.config/opencode/"
            if ($LASTEXITCODE -ne 0) { Write-Host "scp failed for $($pair[0])" -ForegroundColor Red; return }
        }
    }

    # Clean up the singular-named dirs this script previously created on the server
    if (-not $DryRun) {
        ssh $remote "rm -rf ~/.config/opencode/command ~/.config/opencode/agent"
        Write-Host "  removed legacy ~/.config/opencode/command and ~/.config/opencode/agent"
    } else {
        Write-Host "  (dry run) would remove legacy server directories" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "=== Sync complete ($fileCount items staged). Restart OpenCode sessions to load. ===" -ForegroundColor Green
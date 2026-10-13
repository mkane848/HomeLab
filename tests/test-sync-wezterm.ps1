# test-sync-wezterm.ps1 - regression guard for desktop/scripts/sync-wezterm.ps1 and wezterm/wezterm.lua
#
# Why this exists: on 2026-10-13 the owner's live ~/.wezterm.lua turned out to be the repo template with the real
# SSH user and server address filled in BY HAND, and the sync script was a plain Copy-Item. Running it would have
# replaced that file with the YOUR_USER / SERVER_IP placeholders and broken the SSH entry, with no backup. The
# template also made every WezTerm launch connect to the server first (config.default_domain), which is what the
# owner saw as WezTerm "immediately tries to SSH". Now the sync fills the placeholders from SSH_USER and SERVER_IP
# in .env, refuses to write without them, and backs up a config it would change; the template opens a local
# PowerShell 7 and keeps the server one keypress or one launcher-menu entry away.
#
# What it does: runs the REAL sync script (a copy of it inside a throwaway "repo", with USERPROFILE and
# DEVDOCS_ENV pointed at fixtures, so the real ~/.wezterm.lua is never touched):
#   1. fills user and address from .env, leaves no placeholder, makes no backup when there was no file;
#   2. a different file already there is backed up (old content kept) and replaced;
#   3. the same content again: no new backup;
#   4. .env without SSH_USER, or no .env at all: exit 1, nothing written, the existing file untouched;
#   5. the repo's real template: no default_domain, default_prog is pwsh.exe, the server is the first launcher-menu
#      entry and Leader+s opens it, and (when wezterm is installed) WezTerm itself loads the filled-in file.
# Exit 1 on any failure. A control: pass -ScriptPath the old script (a plain copy) and checks 1 to 4 fail.
#
# Usage:  .\tests\test-sync-wezterm.ps1 [-ScriptPath <a sync-wezterm.ps1>] [-TemplatePath <a wezterm.lua>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "..\desktop\scripts\sync-wezterm.ps1"),
    [string]$TemplatePath = (Join-Path $PSScriptRoot "..\wezterm\wezterm.lua")
)

$ErrorActionPreference = "Stop"
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$TemplatePath = (Resolve-Path -LiteralPath $TemplatePath).Path
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ([bool]($text -match $pattern)) "True" }
function Lacks([string]$name, [string]$text, [string]$pattern) { Check $name ([bool]($text -match $pattern)) "False" }

$psExe = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sync-wezterm-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$savedProfile = $env:USERPROFILE
$savedEnvFile = $env:DEVDOCS_ENV
try {
    $repo = Join-Path $tmp "repo"
    $home_ = Join-Path $tmp "home"
    foreach ($d in "$repo\desktop\scripts", "$repo\wezterm", $home_) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination "$repo\desktop\scripts\sync-wezterm.ps1"
    Copy-Item -LiteralPath $TemplatePath -Destination "$repo\wezterm\wezterm.lua"
    $dest = Join-Path $home_ ".wezterm.lua"
    $good = Join-Path $tmp "good.env"
    $noUser = Join-Path $tmp "nouser.env"
    [IO.File]::WriteAllText($good, "# fixture`nSERVER_IP=10.9.8.7`nSSH_USER=alice`nOTHER=1`n", $utf8)
    [IO.File]::WriteAllText($noUser, "SERVER_IP=10.9.8.7`n", $utf8)

    function Sync([string]$EnvFile) {
        $env:USERPROFILE = $home_
        $env:DEVDOCS_ENV = $EnvFile
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File "$repo\desktop\scripts\sync-wezterm.ps1" 2>&1 | Out-String
            [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ($out -replace '\x1b\[[0-9;]*m', '') }
        } finally { $env:USERPROFILE = $savedProfile; $env:DEVDOCS_ENV = $savedEnvFile }
    }
    function Baks { @(Get-ChildItem -LiteralPath $home_ -Filter ".wezterm.lua.bak-*" -ErrorAction SilentlyContinue) }

    Write-Host "-- fills the placeholders from .env"
    $r = Sync $good
    Check "exit 0"                                               $r.Exit 0
    $written = [IO.File]::ReadAllText($dest)
    Has   "the user comes from SSH_USER"                         $written 'username = "alice"'
    Has   "the address comes from SERVER_IP"                     $written 'remote_address = "10\.9\.8\.7:22"'
    Lacks "no placeholder is left"                               $written 'YOUR_USER|SERVER_IP'
    Check "no backup when there was no file"                     (Baks).Count 0

    Write-Host "-- an existing, different config is backed up first"
    [IO.File]::WriteAllText($dest, "-- hand-edited by the owner`nreturn {}`n", $utf8)
    $r = Sync $good
    Check "exit 0"                                               $r.Exit 0
    Check "one backup made"                                      (Baks).Count 1
    Check "...holding the old content"                           $(if ((Baks).Count) { [IO.File]::ReadAllText((Baks)[0].FullName) } else { "<no backup>" }) "-- hand-edited by the owner`nreturn {}`n"
    Check "the target is the filled-in template again"           ([IO.File]::ReadAllText($dest)) $written
    Has   "the console says where the backup went"               $r.Out 'backed up the existing config to'

    Write-Host "-- the same content again: no new backup"
    $r = Sync $good
    Check "exit 0"                                               $r.Exit 0
    Check "still one backup"                                     (Baks).Count 1
    Has   "says it is up to date"                                $r.Out 'already up to date'

    Write-Host "-- refuses without the values (and writes nothing)"
    [IO.File]::WriteAllText($dest, "-- keep me`n", $utf8)
    $before = (Baks).Count
    $r = Sync $noUser
    Check "no SSH_USER: exit 1"                                  $r.Exit 1
    Has   "...names both variables"                              $r.Out 'SSH_USER and SERVER_IP must both be set'
    Check "...the existing file is untouched"                    ([IO.File]::ReadAllText($dest)) "-- keep me`n"
    $r = Sync (Join-Path $tmp "no-such.env")
    Check "no .env at all: exit 1"                               $r.Exit 1
    Has   "...says so"                                           $r.Out 'does not exist\. Nothing written'
    Check "...the existing file is untouched"                    ([IO.File]::ReadAllText($dest)) "-- keep me`n"
    Check "...and no backup was made for a refused run"          (Baks).Count $before

    Write-Host "-- the repo's template"
    $tpl = [IO.File]::ReadAllText($TemplatePath)
    Lacks "no default_domain: opening WezTerm does not connect to the server" $tpl '(?m)^\s*config\.default_domain'
    Has   "default_prog is a local PowerShell 7"                 $tpl '(?m)^\s*config\.default_prog\s*=\s*\{\s*"pwsh\.exe"'
    Has   "the server is a launcher-menu entry"                  $tpl '(?s)config\.launch_menu\s*=\s*\{\s*\{\s*label = "Server \(SSH\)",\s*domain = \{ DomainName = "dev-server" \}'
    Has   "Leader+s opens a tab on the server"                   $tpl 'key = "s", mods = "LEADER", action = act\.SpawnTab\(\{ DomainName = "dev-server" \}\)'
    Has   "the SSH domain is still defined"                      $tpl 'name = "dev-server"'
    $wez = Get-Command wezterm -ErrorAction SilentlyContinue
    if ($wez) {
        $null = Sync $good
        $loaded = & $wez.Source --config-file $dest show-keys --lua 2>&1 | Out-String
        Check "WezTerm loads the filled-in file with no error"   ($LASTEXITCODE -eq 0 -and $loaded -notmatch 'error|Error') "True"
    } else {
        Write-Host "SKIP WezTerm is not installed here: the load check did not run"
    }
} finally {
    $env:USERPROFILE = $savedProfile
    $env:DEVDOCS_ENV = $savedEnvFile
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

# protects: desktop/scripts/pull-household-backup.ps1 (the desktop's copy of the server's household backups): newest copied, a missing tracker backup is an error, nothing empty or half-copied kept under a backup's name, the newest -Keep kept
# run-after: desktop/scripts/pull-household-backup.ps1
# mutation: desktop/scripts/pull-household-backup.ps1
# mutation-from: if ((Get-Item "$dest.partial").Length -le 0) { throw "pull-household-backup: $name arrived empty" }
# mutation-to: $null = $dest
# mutation-expect: FAIL\s+an empty copy is refused
# mutation: desktop/scripts/pull-household-backup.ps1
# mutation-from: if ($Required) { throw "pull-household-backup: no backup found
# mutation-to: if ($false) { throw "pull-household-backup: no backup found
# mutation-expect: FAIL\s+no tracker backup on the server: an error
# test-pull-household-backup.ps1 - regression guard for the desktop's pull of the household backups.
#
# Why this exists: this copy is what lets the household's history survive the server (it has been down for weeks
# before). It runs nightly with no one watching, so a silent success that copied nothing, or kept an empty or
# half-copied file as if it were a backup, would only be found on the day the copy was needed. The 2026-11-09 audit
# found it had no guard ("it needs ssh to the server").
# What it does: runs the real script in its own pwsh with a PATH that puts stand-in `ssh` and `scp` first and holds
# no real ssh. They serve a fake remote folder, log every call, and can be told to fail or deliver an empty file.
#   - the newest tracker (grocy-*) and chat (openwebui-*) backups are copied, byte for byte, with no .partial left;
#   - a second run copies nothing ("already here");
#   - no tracker backup on the server is an error; no chat backup is not (before phase 2);
#   - ssh failing is an error that names its exit code;
#   - an scp failure, or an empty file, is an error, and nothing is left under the backup's name;
#   - only the newest -Keep of each prefix stay, and pruning one prefix never touches the other;
#   - every ssh and scp call is in batch mode, and ssh has -n (so a nightly run never waits on a prompt).
# Exit 1 on any failure.
#
# Usage:  .\tests\test-pull-household-backup.ps1 [-ScriptPath <pull-household-backup.ps1>]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script = if ($ScriptPath) { $ScriptPath } else { Join-Path $repo "desktop/scripts/pull-household-backup.ps1" }
if (-not (Test-Path -LiteralPath $script)) { Write-Host "FAIL: missing $script"; exit 1 }

$script:fail = 0
function Check([string]$name, $actual, $expected, [string]$Context = "") {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) {
        Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++
        if ($Context) { Write-Host "     the script said:"; $Context.TrimEnd() -split "`n" | ForEach-Object { Write-Host "       $_" } }
    }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("pull-backup-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$bin = Join-Path $tmp "bin"; $remote = Join-Path $tmp "remote"
New-Item -ItemType Directory -Force -Path $bin, (Join-Path $remote "backups/household") | Out-Null
$pwshPath = (Get-Process -Id $PID).Path
$saved = @{}
foreach ($k in "PATH", "FAKE_REMOTE", "FAKE_LOG", "FAKE_SSH_EXIT", "FAKE_SCP_EXIT", "FAKE_SCP_EMPTY") { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
try {
    # One stand-in for both tools. ssh: answers the script's `ls -1t <dir>/<prefix>-*.tar.gz | head -n 1` from the
    # fake remote, newest first by modification time. scp: copies <host>:<path> from the fake remote.
    $standIn = Join-Path $bin "stand-in.ps1"
    [IO.File]::WriteAllText($standIn, @'
$tool = $args[0]; $rest = @($args | Select-Object -Skip 1)
Add-Content -LiteralPath $env:FAKE_LOG -Value ("$tool " + ($rest -join " "))
if ($tool -eq "ssh") {
    if ($env:FAKE_SSH_EXIT) { exit [int]$env:FAKE_SSH_EXIT }
    $cmd = $rest[-1]
    if ($cmd -notmatch 'ls -1t (\S+)/([^/\s]+)-\*\.tar\.gz') { Write-Error "stand-in ssh: unexpected command: $cmd"; exit 99 }
    $dir = $Matches[1]; $prefix = $Matches[2]
    $f = Get-ChildItem -LiteralPath (Join-Path $env:FAKE_REMOTE $dir) -Filter "$prefix-*.tar.gz" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { "$dir/$($f.Name)" }
    exit 0
}
if ($tool -eq "scp") {
    if ($env:FAKE_SCP_EXIT) { exit [int]$env:FAKE_SCP_EXIT }
    $src = $rest[-2]; $dst = $rest[-1]
    $path = $src.Substring($src.IndexOf(":") + 1)
    if ($env:FAKE_SCP_EMPTY) { [IO.File]::WriteAllBytes($dst, [byte[]]@()) }
    else { Copy-Item -LiteralPath (Join-Path $env:FAKE_REMOTE $path) -Destination $dst }
    exit 0
}
exit 98
'@)
    foreach ($tool in "ssh", "scp") {
        if ($IsWindows) {
            [IO.File]::WriteAllText((Join-Path $bin "$tool.cmd"), "@`"$pwshPath`" -NoProfile -File `"%~dp0stand-in.ps1`" $tool %*`r`n@exit /b %ERRORLEVEL%`r`n")
        } else {
            $sh = Join-Path $bin $tool
            [IO.File]::WriteAllText($sh, "#!/bin/sh`nexec '$pwshPath' -NoProfile -File '$standIn' $tool `"`$@`"`n"); & chmod +x $sh
        }
    }
    # Only the stand-ins, pwsh's own folder and the system's basics: no real ssh or scp can be reached.
    $pathValue = if ($IsWindows) { "$bin;$(Split-Path -Parent $pwshPath);$env:SystemRoot\System32" } else { "${bin}:$(Split-Path -Parent $pwshPath):/bin" }
    foreach ($t in "ssh", "scp") {
        $env:PATH = $pathValue
        $found = (Get-Command $t -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $env:PATH = $saved["PATH"]
        if (-not $found -or -not $found.StartsWith($bin)) { Write-Host "FAIL: the stand-in $t is not what PATH finds first (found: $found)"; exit 1 }
    }

    $rdir = Join-Path $remote "backups/household"
    function New-RemoteBackup([string]$Name, [int]$MinutesAgo, [string]$Body = "") {
        $p = Join-Path $rdir $Name
        [IO.File]::WriteAllText($p, $(if ($Body) { $Body } else { "backup $Name " + [guid]::NewGuid() }))
        (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddMinutes(-$MinutesAgo)
    }
    $log = Join-Path $tmp "calls.log"
    function Invoke-Pull([string]$LocalDir, [hashtable]$Env = @{}, [int]$Keep = 30) {
        Set-Content -LiteralPath $log -Value $null
        $env:FAKE_REMOTE = $remote; $env:FAKE_LOG = $log
        foreach ($k in "FAKE_SSH_EXIT", "FAKE_SCP_EXIT", "FAKE_SCP_EMPTY") { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        foreach ($k in $Env.Keys) { Set-Item "Env:$k" $Env[$k] }
        $env:PATH = $pathValue
        try { $out = & $pwshPath -NoProfile -File $script -LocalDir $LocalDir -Keep $Keep 2>&1 | Out-String; $code = $LASTEXITCODE }
        finally { $env:PATH = $saved["PATH"] }
        [pscustomobject]@{ Out = $out; Exit = $code; Calls = @(Get-Content -LiteralPath $log | Where-Object { $_ }) }
    }
    $sha = { param($p) (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

    Write-Host "-- the newest of each is copied"
    New-RemoteBackup "grocy-20261120.tar.gz" 300
    New-RemoteBackup "grocy-20261121.tar.gz" 10
    New-RemoteBackup "openwebui-20261121.tar.gz" 20
    $local = Join-Path $tmp "local1"
    $r = Invoke-Pull $local
    Check "exit 0" $r.Exit 0
    Check "the newest tracker backup is copied, byte for byte" (& $sha (Join-Path $local "grocy-20261121.tar.gz")) (& $sha (Join-Path $rdir "grocy-20261121.tar.gz"))
    Check "...and not the older one" (Test-Path (Join-Path $local "grocy-20261120.tar.gz")) "False"
    Check "the chat backup is copied, byte for byte" (& $sha (Join-Path $local "openwebui-20261121.tar.gz")) (& $sha (Join-Path $rdir "openwebui-20261121.tar.gz"))
    Check "no .partial file is left" @(Get-ChildItem -LiteralPath $local -Filter "*.partial").Count 0
    Check "every ssh call is batch mode with -n" @($r.Calls | Where-Object { $_ -like "ssh *" -and -not ($_ -like "ssh -n -o BatchMode=yes *") }).Count 0
    Check "every scp call is batch mode" @($r.Calls | Where-Object { $_ -like "scp *" -and $_ -notmatch '-o BatchMode=yes' }).Count 0
    Check "two lookups and two copies" ("{0}|{1}" -f @($r.Calls -like "ssh *").Count, @($r.Calls -like "scp *").Count) "2|2"

    Write-Host "-- a second run"
    $r = Invoke-Pull $local
    Check "exit 0, and nothing copied again" ("{0}|{1}" -f $r.Exit, @($r.Calls -like "scp *").Count) "0|0"
    Check "...it says so" ($r.Out -match 'grocy-20261121\.tar\.gz already here') "True"

    Write-Host "-- no chat backup yet (before phase 2)"
    Remove-Item -LiteralPath (Join-Path $rdir "openwebui-20261121.tar.gz")
    $r = Invoke-Pull (Join-Path $tmp "local2")
    Check "no chat backup: exit 0" $r.Exit 0
    Check "...and it says there is none yet" ($r.Out -match 'no openwebui backup on server:backups/household yet') "True"

    Write-Host "-- no tracker backup"
    Get-ChildItem -LiteralPath $rdir -Filter "grocy-*" | Remove-Item
    New-RemoteBackup "openwebui-20261122.tar.gz" 5
    $r = Invoke-Pull (Join-Path $tmp "local3")
    Check "no tracker backup on the server: an error" ("{0}|{1}" -f ($r.Exit -ne 0), ($r.Out -match 'no backup found on server:backups/household')) "True|True" $r.Out
    Check "...and the chat backup is not pulled after it" @($r.Calls -like "scp *").Count 0

    Write-Host "-- ssh fails"
    New-RemoteBackup "grocy-20261122.tar.gz" 5
    $r = Invoke-Pull (Join-Path $tmp "local4") @{ FAKE_SSH_EXIT = "255" }
    Check "ssh failing is an error naming its exit code" ("{0}|{1}" -f ($r.Exit -ne 0), ($r.Out -match 'ssh exit 255')) "True|True" $r.Out

    Write-Host "-- scp fails, or delivers nothing"
    $l5 = Join-Path $tmp "local5"
    $r = Invoke-Pull $l5 @{ FAKE_SCP_EXIT = "1" }
    Check "an scp failure is an error" ("{0}|{1}" -f ($r.Exit -ne 0), ($r.Out -match 'scp failed \(exit 1\)')) "True|True" $r.Out
    Check "...and nothing is under the backup's name" (Test-Path (Join-Path $l5 "grocy-20261122.tar.gz")) "False"
    $l6 = Join-Path $tmp "local6"
    $r = Invoke-Pull $l6 @{ FAKE_SCP_EMPTY = "1" }
    Check "an empty copy is refused" ("{0}|{1}" -f ($r.Exit -ne 0), ($r.Out -match 'grocy-20261122\.tar\.gz arrived empty')) "True|True" $r.Out
    Check "...and nothing is under the backup's name" (Test-Path (Join-Path $l6 "grocy-20261122.tar.gz")) "False"
    $r = Invoke-Pull $l6
    Check "the next good run copies it" ("{0}|{1}" -f $r.Exit, ((Get-Item (Join-Path $l6 "grocy-20261122.tar.gz")).Length -gt 0)) "0|True"

    Write-Host "-- -Keep"
    $l7 = Join-Path $tmp "local7"; New-Item -ItemType Directory -Force -Path $l7 | Out-Null
    foreach ($i in 1..4) {
        foreach ($pre in "grocy", "openwebui") {
            $p = Join-Path $l7 "$pre-2026110$i.tar.gz"; [IO.File]::WriteAllText($p, "old $pre $i")
            (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddDays(-10 + $i)
        }
    }
    $r = Invoke-Pull $l7 -Keep 3
    Check "exit 0" $r.Exit 0
    $g = @(Get-ChildItem -LiteralPath $l7 -Filter "grocy-*.tar.gz" | Sort-Object Name | ForEach-Object Name) -join ","
    $o = @(Get-ChildItem -LiteralPath $l7 -Filter "openwebui-*.tar.gz" | Sort-Object Name | ForEach-Object Name) -join ","
    Check "-Keep 3: the newest three tracker backups stay (the new copy among them)" $g "grocy-20261103.tar.gz,grocy-20261104.tar.gz,grocy-20261122.tar.gz"
    Check "...and the newest three chat backups, pruned on their own" $o "openwebui-20261103.tar.gz,openwebui-20261104.tar.gz,openwebui-20261122.tar.gz"
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

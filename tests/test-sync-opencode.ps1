# test-sync-opencode.ps1 - regression guard for desktop/scripts/sync-opencode.ps1
#
# Why this exists: the script used to ALWAYS scp the OpenCode config and every
# .secrets/ file to the Ubuntu server, which has been a model host only for a long
# time (its OpenCode client was removed 2026-10-19). It also needed .env just to stage
# locally, and the template hard-coded this PC's checkout in its plugin paths. Now the
# default is local-only, the plugin paths come from a placeholder token filled in with
# the checkout that stages them, and copying to another machine is opt-in
# (-Push <machine>, only for a machines.tsv row with the opencode-client role;
# -Secrets <names> only with -Push, never "all").
#
# What it does: copies the REAL script, its helper (desktop/scripts/opencode-template.ps1),
# the REAL template, agents/commands, plugins and machines.tsv into a throwaway tree and
# runs the script there as a child process with a throwaway USERPROFILE and stand-in
# ssh / scp / opencode .cmd shims first on PATH that log every call. It never reads the
# real .env or ~/.config/opencode and contacts no host.
# Covered: default run (no .env, zero ssh/scp, token filled, live file written), backup
# and diff summary on change, no backup when identical, the `opencode debug config`
# report (loads / missing plugin path / opencode absent), agents and commands staged,
# -Push refusals (server, unknown machine, missing .env), -Push desktop (config and
# agents, no secret), -Secrets (only the named file; refused alone, as a wildcard or
# path, or for a missing file), a down host, -RemoteRepoRoot.
# Controls: copies of the script with one piece removed (role check, the -Secrets
# gate, the token substitution, the backup) must each fail the matching check.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-sync-opencode.ps1
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:fail = 0
$script:total = 0
function Check([string]$name, $actual, $expected) {
    $script:total++
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

. (Join-Path $repoRoot "desktop/scripts/opencode-template.ps1")

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("syncoc-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
$saved = @{}
foreach ($v in "USERPROFILE", "PATH", "FIXTURE_LOG", "FIXTURE_DEBUG", "FIXTURE_SSH_EXIT") { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }

# One throwaway checkout: real script + helper + template + agents/commands + plugins + machines.tsv.
function New-Checkout([string]$root) {
    foreach ($d in "desktop/scripts", "opencode/global", "opencode/agents", "opencode/commands", "opencode/plugins") {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
    }
    Copy-Item (Join-Path $repoRoot "desktop/scripts/sync-opencode.ps1") (Join-Path $root "desktop/scripts/")
    Copy-Item (Join-Path $repoRoot "desktop/scripts/opencode-template.ps1") (Join-Path $root "desktop/scripts/")
    Copy-Item (Join-Path $repoRoot "opencode/global/opencode.jsonc") (Join-Path $root "opencode/global/")
    Copy-Item (Join-Path $repoRoot "machines.tsv") $root
    # A model host with no client role, so the refusal below never depends on how a real machine is set up.
    Add-Content -LiteralPath (Join-Path $root "machines.tsv") -Value "fx-model`tmodel-host`tfixture: model host only"
    Copy-Item (Join-Path $repoRoot "opencode/plugins/*.js") (Join-Path $root "opencode/plugins/")
    Set-Content -LiteralPath (Join-Path $root "opencode/agents/fx-agent.md") -Value "agent v1"
    Set-Content -LiteralPath (Join-Path $root "opencode/commands/fx-cmd.md") -Value "command v1"
}

function Reset-Home([string]$home_) {
    if (Test-Path $home_) { Remove-Item -Recurse -Force $home_ }
    $sec = Join-Path $home_ ".config/opencode/.secrets"
    New-Item -ItemType Directory -Path $sec -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sec "a-key") -Value "AAA"
    Set-Content -LiteralPath (Join-Path $sec "b-key") -Value "BBB"
    New-Item -ItemType Directory -Path (Join-Path $home_ ".config/opencode/agents") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $home_ ".config/opencode/agents/local-only.md") -Value "mine"
}

function Run-Sync([string]$checkout, [string[]]$SyncArgs = @()) {
    Remove-Item -LiteralPath $env:FIXTURE_LOG, "$($env:FIXTURE_LOG).cfg" -ErrorAction SilentlyContinue
    $out = & $psExe -NoProfile -File (Join-Path $checkout "desktop/scripts/sync-opencode.ps1") @SyncArgs *>&1 | Out-String
    $code = $LASTEXITCODE
    $calls = if (Test-Path -LiteralPath $env:FIXTURE_LOG) { @(Get-Content -LiteralPath $env:FIXTURE_LOG) } else { @() }
    [pscustomobject]@{ Out = $out; Code = $code; Calls = $calls
        Scp = @($calls | Where-Object { $_ -like 'scp *' }); Ssh = @($calls | Where-Object { $_ -like 'ssh *' })
        Cfg = if (Test-Path -LiteralPath "$($env:FIXTURE_LOG).cfg") { Get-Content -LiteralPath "$($env:FIXTURE_LOG).cfg" -Raw } else { $null } }
}

try {
    $co = Join-Path $tmp "checkout"
    $homeDir = Join-Path $tmp "home"
    $bin = Join-Path $tmp "bin"
    New-Checkout $co
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    # Stand-ins. The log redirect comes first so a digit before it is never a handle.
    $shim = @{
        "ssh.cmd"      = "@echo off`r`n>> `"%FIXTURE_LOG%`" echo ssh %*`r`nif defined FIXTURE_SSH_EXIT exit /b %FIXTURE_SSH_EXIT%`r`nexit /b 0"
        "scp.cmd"      = "@echo off`r`n>> `"%FIXTURE_LOG%`" echo scp %*`r`nif /i `"%~x1`"==`".jsonc`" copy /y `"%~1`" `"%FIXTURE_LOG%.cfg`" >nul`r`nexit /b 0"
        "opencode.cmd" = "@echo off`r`n>> `"%FIXTURE_LOG%`" echo opencode %*`r`nif exist `"%FIXTURE_DEBUG%`" type `"%FIXTURE_DEBUG%`"`r`nexit /b 0"
    }
    foreach ($k in $shim.Keys) { Set-Content -LiteralPath (Join-Path $bin $k) -Value $shim[$k] -Encoding ascii }
    $env:USERPROFILE = $homeDir
    $env:FIXTURE_LOG = Join-Path $tmp "calls.log"
    $env:FIXTURE_DEBUG = Join-Path $tmp "debug.json"
    Remove-Item Env:FIXTURE_SSH_EXIT -ErrorAction SilentlyContinue
    $env:PATH = "$bin;$($saved['PATH'])"
    $live = Join-Path $homeDir ".config/opencode/opencode.jsonc"
    $url = Get-RepoRootUrl $co
    $expected = Expand-OpenCodeTemplate (Get-Content -LiteralPath (Join-Path $co "opencode/global/opencode.jsonc") -Raw) $co
    @{ plugin = @("$url/opencode/plugins/compaction-continue.js", "$url/opencode/plugins/read-budget.js") } | ConvertTo-Json | Set-Content -LiteralPath $env:FIXTURE_DEBUG
    $baks = { @(Get-ChildItem (Split-Path $live) -Filter "opencode.jsonc.bak-*") }

    Write-Host "-- default run: local only, no .env"
    Reset-Home $homeDir
    Check "the checkout has no .env (so a read of it would fail)" (Test-Path (Join-Path $co ".env")) "False"
    $r = Run-Sync $co
    Check "exit 0" $r.Code 0
    Check "zero ssh and scp calls" ($r.Ssh.Count + $r.Scp.Count) 0
    Check "the live config was written" (Test-Path $live) "True"
    Check "...equal to the template with the token filled in" ((Get-Content $live -Raw) -ceq $expected) "True"
    Check "...plugin paths name this checkout" ((Get-Content $live -Raw).Contains("`"$url/opencode/plugins/compaction-continue.js`"")) "True"
    Check "...no placeholder token left" ((Get-Content $live -Raw).Contains($script:RepoUrlToken)) "False"
    Check "...no hard-coded M:/Projects/dev-docs left" ((Get-Content $live -Raw) -match 'M:/Projects/dev-docs') "False"
    Check "...the template file itself has no machine path" ((Get-Content (Join-Path $repoRoot "opencode/global/opencode.jsonc") -Raw) -match '(?<![A-Za-z0-9])[A-Za-z]:[/\\]') "False"
    Check "no backup when there was no previous config" (& $baks).Count 0
    Check "opencode debug config was run" (@($r.Calls | Where-Object { $_ -like 'opencode debug config*' }).Count) 1
    Check "...reported as loading" ($r.Out -match 'opencode debug config: loads') "True"
    Check "...and every plugin path as existing" ([regex]::Matches($r.Out, 'plugin ok:').Count) 2
    Check "agents staged" (Get-Content (Join-Path $homeDir ".config/opencode/agents/fx-agent.md") -Raw).Trim() "agent v1"
    Check "commands staged" (Get-Content (Join-Path $homeDir ".config/opencode/commands/fx-cmd.md") -Raw).Trim() "command v1"
    Check "a local-only agent is left alone" (Get-Content (Join-Path $homeDir ".config/opencode/agents/local-only.md") -Raw).Trim() "mine"

    Write-Host "-- identical content: no write, no backup"
    $r = Run-Sync $co
    Check "exit 0" $r.Code 0
    Check "says it is identical" ($r.Out -match 'already identical') "True"
    Check "no backup" (& $baks).Count 0
    $r = Run-Sync $co @("-Template")
    Check "-Template is still accepted (same local staging)" "$($r.Code)/$($r.Ssh.Count + $r.Scp.Count)" "0/0"

    Write-Host "-- changed content: backup and diff summary"
    Add-Content -LiteralPath $live -Value "// edited by hand"
    $edited = Get-Content $live -Raw
    $r = Run-Sync $co
    Check "exit 0" $r.Code 0
    Check "one timestamped backup" (& $baks).Count 1
    Check "...holding the content that was overwritten" ((Get-Content (& $baks)[0].FullName -Raw) -ceq $edited) "True"
    Check "...named opencode.jsonc.bak-yyyyMMdd-HHmmss" ((& $baks)[0].Name -match '^opencode\.jsonc\.bak-\d{8}-\d{6}$') "True"
    Check "the live file is the template again" ((Get-Content $live -Raw) -ceq $expected) "True"
    Check "a diff summary is printed" ($r.Out -match '1 line\(s\) removed|0 line\(s\) added, 1 removed') "True"

    Write-Host "-- the opencode report warns, never fails"
    @{ plugin = @("file:///no/such/place/plugin.js") } | ConvertTo-Json | Set-Content -LiteralPath $env:FIXTURE_DEBUG
    $r = Run-Sync $co
    Check "missing plugin path: exit 0" $r.Code 0
    Check "...WARNING names it" ($r.Out -match 'WARNING: plugin path does not exist: file:///no/such/place/plugin.js') "True"
    $env:PATH = "$bin\no-opencode;$env:SystemRoot\System32"
    New-Item -ItemType Directory -Path (Join-Path $bin "no-opencode") -Force | Out-Null
    $r = Run-Sync $co
    Check "opencode absent: exit 0" $r.Code 0
    Check "...WARNING says so" ($r.Out -match 'WARNING: opencode is not on PATH') "True"
    $env:PATH = "$bin;$($saved['PATH'])"
    @{ plugin = @("$url/opencode/plugins/compaction-continue.js", "$url/opencode/plugins/read-budget.js") } | ConvertTo-Json | Set-Content -LiteralPath $env:FIXTURE_DEBUG

    Write-Host "-- opt-in push: refusals"
    $r = Run-Sync $co @("-Push", "server")
    Check "-Push server: exit 1" $r.Code 1
    Check "...says why" ($r.Out -match "no opencode-client role") "True"
    Check "...no ssh/scp" ($r.Ssh.Count + $r.Scp.Count) 0
    $r = Run-Sync $co @("-Push", "fx-model")
    Check "-Push fx-model (model host only): exit 1, nothing sent" "$($r.Code)/$($r.Ssh.Count + $r.Scp.Count)" "1/0"
    $r = Run-Sync $co @("-Push", "nope")
    Check "-Push of an unknown machine: exit 1, nothing sent" "$($r.Code)/$($r.Ssh.Count + $r.Scp.Count)" "1/0"
    $r = Run-Sync $co @("-Secrets", "a-key")
    Check "-Secrets without -Push: exit 1, nothing sent" "$($r.Code)/$($r.Ssh.Count + $r.Scp.Count)" "1/0"
    $r = Run-Sync $co @("-Push", "desktop")
    Check "-Push desktop without a .env: exit 1, nothing sent" "$($r.Code)/$($r.Ssh.Count + $r.Scp.Count)" "1/0"

    Write-Host "-- opt-in push: allowed client"
    Set-Content -LiteralPath (Join-Path $co ".env") -Value "SSH_USER=fixture`nDESKTOP_IP=192.0.2.9`nSERVER_IP=192.0.2.1"
    $r = Run-Sync $co @("-Push", "desktop")
    Check "-Push desktop: exit 0" $r.Code 0
    Check "...probed ssh at the machine's address" (@($r.Ssh | Where-Object { $_ -match 'fixture@192\.0\.2\.9' }).Count -ge 1) "True"
    Check "...never the server's" (@($r.Calls | Where-Object { $_ -match '192\.0\.2\.1' }).Count) 0
    Check "...scp'd the config" (@($r.Scp | Where-Object { $_ -match 'opencode\.jsonc fixture@192\.0\.2\.9:~/\.config/opencode/opencode\.jsonc' }).Count) 1
    Check "...and the agent and the command" (@($r.Scp | Where-Object { $_ -match 'fx-agent\.md|fx-cmd\.md' }).Count) 2
    Check "...but no secret" (@($r.Scp | Where-Object { $_ -match 'secrets' }).Count) 0
    Check "...warned that the plugin paths name this checkout" ($r.Out -match 'plugin paths name THIS checkout') "True"

    $r = Run-Sync $co @("-Push", "desktop", "-Secrets", "a-key")
    Check "-Secrets a-key: exit 0" $r.Code 0
    Check "...exactly one secret copied" (@($r.Scp | Where-Object { $_ -match 'secrets' }).Count) 1
    Check "...the named one" (@($r.Scp | Where-Object { $_ -match 'a-key fixture@192\.0\.2\.9:~/\.config/opencode/\.secrets/a-key' }).Count) 1
    Check "...not the other" (@($r.Scp | Where-Object { $_ -match 'b-key' }).Count) 0
    $r = Run-Sync $co @("-Push", "desktop", "-Secrets", "a-key,b-key")
    Check "-Secrets a-key,b-key copies both" (@($r.Scp | Where-Object { $_ -match 'secrets' }).Count) 2
    foreach ($bad in "*", "../b-key", "nosuch") {
        $r = Run-Sync $co @("-Push", "desktop", "-Secrets", $bad)
        Check "-Secrets '$bad': exit 1, nothing sent" "$($r.Code)/$($r.Ssh.Count + $r.Scp.Count)" "1/0"
    }

    $r = Run-Sync $co @("-Push", "desktop", "-RemoteRepoRoot", "C:\remote\checkout")
    Check "-RemoteRepoRoot: pushed config names the target's checkout" ($r.Cfg -match [regex]::Escape("file:///C:/remote/checkout/opencode/plugins/read-budget.js")) "True"
    Check "...and not this one" ($r.Cfg.Contains($url)) "False"
    Check "...the live config is unchanged" ((Get-Content $live -Raw) -ceq $expected) "True"

    $env:FIXTURE_SSH_EXIT = "255"
    $r = Run-Sync $co @("-Push", "desktop", "-Secrets", "a-key")
    Remove-Item Env:FIXTURE_SSH_EXIT
    Check "down host: exit 0 with a warning" "$($r.Code)/$([bool]($r.Out -match 'unreachable'))" "0/True"
    Check "...no scp" $r.Scp.Count 0

    Write-Host "-- controls: a script with one piece removed must fail its check"
    function Run-Mutant([string]$label, [string]$file, [string]$from, [string]$to, [scriptblock]$prep, [string[]]$SyncArgs) {
        $mco = Join-Path $tmp "mutant-$label"
        New-Checkout $mco
        Set-Content -LiteralPath (Join-Path $mco ".env") -Value "SSH_USER=fixture`nDESKTOP_IP=192.0.2.9`nSERVER_IP=192.0.2.1"
        $p = Join-Path $mco $file
        $t = Get-Content -LiteralPath $p -Raw
        if (-not $t.Contains($from)) { Check "control $label : the text to remove exists" "missing" "present"; return $null }
        Set-Content -LiteralPath $p -Value $t.Replace($from, $to) -NoNewline
        Reset-Home $homeDir
        & $prep
        return (Run-Sync $mco $SyncArgs)
    }
    $r = Run-Mutant "roles" "desktop/scripts/sync-opencode.ps1" 'if ($machine.Roles -notcontains "opencode-client") {' 'if ($false) {' {} @("-Push", "server")
    if ($r) { Check "control (no role check): -Push server is no longer refused" "$($r.Code)/$($r.Ssh.Count -gt 0)" "0/True" }
    $r = Run-Mutant "secrets" "desktop/scripts/sync-opencode.ps1" '$Secrets.Count -gt 0 -and -not $Push' '$false' {} @("-Secrets", "a-key")
    if ($r) { Check "control (no -Secrets gate): -Secrets alone is no longer refused" $r.Code 0 }
    $r = Run-Mutant "token" "desktop/scripts/opencode-template.ps1" 'return $Text.Replace($script:RepoUrlToken, (Get-RepoRootUrl $RepoRoot))' 'return $Text' {} @()
    if ($r) { Check "control (no token substitution): the token stays in the live config" ((Get-Content $live -Raw).Contains($script:RepoUrlToken)) "True" }
    $r = Run-Mutant "backup" "desktop/scripts/sync-opencode.ps1" 'Copy-Item -LiteralPath $LIVE -Destination $bak' '$null = $bak' { Set-Content -LiteralPath $live -Value "// old" } @()
    if ($r) { Check "control (no backup): no backup file is written" (& $baks).Count 0 }
} finally {
    foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $(if ($null -eq $saved[$v]) { [NullString]::Value } else { $saved[$v] })) }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "$($script:total - $script:fail) of $($script:total) checks passed"
if ($script:fail) { Write-Host "FAIL: $($script:fail) check(s) failed"; exit 1 }
Write-Host "PASS"

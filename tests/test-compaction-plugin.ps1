# test-compaction-plugin.ps1 - regression guard for opencode/plugins/compaction-continue.js
#
# Why this exists: after an automatic compaction opencode adds "Continue if you
# have next steps, or stop and ask for clarification...", and local seats take
# the second half. The plugin rewrites that message, in what the model is sent,
# into the harness's nudge text plus the original request, and asks the
# compaction summary to keep the request verbatim (docs/roadmap.md -> "Context
# overflow"). It rests on EXPERIMENTAL opencode hooks and an internal marker
# that opencode says may change, so this guard fails loudly when either moves.
#
# What it does:
#   - tests/test-compaction-plugin.mjs under node: the module shape opencode
#     1.18.34's loader needs, recognising the continue message, the original
#     request, the rewrite, and the compaction context;
#   - the plugin's CONTINUE_TEXT equals test-tasks.ps1's
#     $script:CompactionNudgeText (the diagnostic and the plugin say the same);
#   - the installed opencode is the version the hooks were read at
#     (-PinnedOpencode): a different one FAILS until someone re-reads
#     session/compaction.ts and session/prompt.ts and moves the pin.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-compaction-plugin.ps1 [-PluginPath <js>] [-ScriptPath <test-tasks.ps1>] [-PinnedOpencode 1.18.34]
param(
    [string]$PluginPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "opencode\plugins\compaction-continue.js"),
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$PinnedOpencode = "1.18.34"
)

$ErrorActionPreference = "Stop"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host "FAIL: node is not on PATH"; exit 1 }
if (-not (Test-Path -LiteralPath $PluginPath)) { Write-Host "FAIL: plugin not found at $PluginPath"; exit 1 }

Write-Host "-- plugin unit checks (node)"
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$out = & node (Join-Path $PSScriptRoot "test-compaction-plugin.mjs") $PluginPath 2>&1
$nodeExit = $LASTEXITCODE
$ErrorActionPreference = $prev
$out | Where-Object { "$_" -notmatch '^CONTINUE_TEXT=' } | ForEach-Object { Write-Host $_ }
$script:fail += @($out | Where-Object { "$_" -match '^FAIL ' }).Count
if ($nodeExit -ne 0 -and @($out | Where-Object { "$_" -match '^FAIL ' }).Count -eq 0) { Write-Host "FAIL node exited $nodeExit"; $script:fail++ }

Write-Host "-- the plugin and the harness say the same thing"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
$nudgeAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:CompactionNudgeText' }, $true)) | Select-Object -First 1
if (-not $nudgeAst) { Write-Host "FAIL `$script:CompactionNudgeText not found in $ScriptPath"; $script:fail++ } else {
    Invoke-Expression $nudgeAst.Extent.Text
    $line = @($out | Where-Object { "$_" -match '^CONTINUE_TEXT=' }) | Select-Object -First 1
    $pluginText = if ($line) { ("$line" -replace '^CONTINUE_TEXT=', '') | ConvertFrom-Json } else { $null }
    Check "CONTINUE_TEXT equals test-tasks.ps1's nudge text" $pluginText $script:CompactionNudgeText
}

Write-Host "-- the harness records plugin runs (real test-tasks.ps1, fixture repo, stand-in opencode)"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ccplugin-e2e-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
try {
    foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $tmp "tests/test-tasks.ps1")
    $repo = Join-Path $tmp "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    # Green at the base too (the harness refuses a broken base); this section
    # checks what the run JSON records, not the gates.
    'Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    Set-Content -LiteralPath (Join-Path $repo "src.test.txt") -Value "test"
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-plugin"; title = "fx"; repo = $repo; branch = "bench/fx"; benchBaseCommit = $base
        allowFiles = @("src.txt"); srcRevertFiles = @("src.txt"); testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/manifest.json")
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { if ($env:FIXTURE_PLUGINS) { '{"plugin":["file:///x/opencode/plugins/compaction-continue.js"]}' } else { '{}' }; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
Add-Content -LiteralPath $env:FIXTURE_SEEN -Value ("log=" + $env:HOMELAB_COMPACTION_PLUGIN_LOG)
if ($env:HOMELAB_COMPACTION_PLUGIN_LOG) {
    Add-Content -LiteralPath $env:HOMELAB_COMPACTION_PLUGIN_LOG -Value '{"message":"loaded"}'
    Add-Content -LiteralPath $env:HOMELAB_COMPACTION_PLUGIN_LOG -Value '{"message":"rewrote the post-compaction continue message","sessionID":"s"}'
    Add-Content -LiteralPath $env:HOMELAB_COMPACTION_PLUGIN_LOG -Value '{"message":"rewrote the post-compaction continue message","sessionID":"s"}'
}
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
'{"type":"tool_use","sessionID":"s","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
'{"type":"step_finish","sessionID":"s","part":{"reason":"stop","tokens":{"input":100,"output":5,"cache":{"read":0,"write":0}}}}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $tmp "bin/standin.ps1")
    $bin = Join-Path $tmp "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    $env:FIXTURE_SEEN = Join-Path $tmp "seen.txt"
    $tt = Join-Path $tmp "tests/test-tasks.ps1"
    try {
        $env:FIXTURE_PLUGINS = "1"
        $withOut = & $tt -Task fx-plugin -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "with") *>&1 | Out-String
        Remove-Item Env:FIXTURE_PLUGINS
        $leaked = [Environment]::GetEnvironmentVariable("HOMELAB_COMPACTION_PLUGIN_LOG")
        $null = & $tt -Task fx-plugin -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "without") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_SEEN, Env:FIXTURE_PLUGINS -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath (Join-Path $tmp "seen.txt"))) {
        Write-Host "FAIL the harness never reached opencode run; its output:"
        Write-Host $withOut
        throw "fixture run did not start"
    }
    $seen = @(Get-Content -LiteralPath (Join-Path $tmp "seen.txt"))
    $jWith = Get-ChildItem (Join-Path $tmp "with") -Filter "tasks-fx-plugin-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    $jWithout = Get-ChildItem (Join-Path $tmp "without") -Filter "tasks-fx-plugin-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "with the plugin: opencodePlugins recorded"            (@($jWith.opencodePlugins) -join ',') "file:///x/opencode/plugins/compaction-continue.js"
    Check "...the run got an evidence log path"                  ($seen[0] -match '^log=.+ccplugin-.+\.jsonl$') "True"
    Check "...compactionPluginRewrites counts the rewrite lines" $jWith.compactionPluginRewrites 2
    Check "...the header names the plugin"                       ($withOut -match 'opencode plugins: file:///x/opencode/plugins/compaction-continue.js') "True"
    Check "...the log variable does not outlive the run"         ([string]::IsNullOrEmpty($leaked)) "True"
    Check "...the evidence log is removed"                       (Test-Path -LiteralPath ($seen[0] -replace '^log=', '')) "False"
    Check "without: no plugins recorded"                         @($jWithout.opencodePlugins).Count 0
    Check "...no evidence log"                                   $seen[1] "log="
    Check "...compactionPluginRewrites null"                     ($null -eq $jWithout.compactionPluginRewrites) "True"
} finally {
    if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host "-- the opencode these hooks were read at"
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$installed = (& opencode --version 2>$null | Out-String).Trim()
$ErrorActionPreference = $prev
Check "installed opencode is $PinnedOpencode (re-read compaction.ts and prompt.ts, then move -PinnedOpencode)" $installed $PinnedOpencode

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

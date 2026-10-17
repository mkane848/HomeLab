# test-read-budget.ps1 - regression guard for opencode/plugins/read-budget.js
#
# Why this exists: opencode 1.18.34's read returns up to 50 KB a call, and on
# kane-08 (qwen3.6, 65,536-token window) two whole-file reads of 131 KB and
# 185 KB overflowed the window, compaction followed, and the same four reads
# came back 17 to 19 times a run until the 45-minute timeout: 3 of 3 runs, no
# edit (docs/roadmap.md -> "Large-file fix (2026-10-17)"). The plugin lowers
# each read's own `limit` to a share of the model's window, appends a hint to
# the result, shrinks a file that has used its budget since the last compaction
# to 100-line reads, and resets that budget at each compaction. It rests on the
# tool.execute.before hook's output.args being the object read runs with, on
# the model reaching chat.params, and on experimental.session.compacting, so
# this guard fails loudly when any of them moves.
#
# What it does:
#   - tests/test-read-budget.mjs under node: the cap arithmetic at 32k / 64k /
#     200k / unknown, the env override and off, the line-fit computation
#     (number prefix, a 2000-char line cut, the offset), the caller's smaller
#     limit, small files, missing / directory / binary / image paths, the hint,
#     the per-file budget and its 100-line window, the reset on compaction, two
#     sessions apart, the log lines and the module shape the v1 loader needs;
#   - tests/test-read-budget-live.mjs: the plugin inside the real `opencode
#     serve` with a scripted stand-in model that reads a ~130 KB file whole -
#     the tool result it gets back is clamped near the cap, read's footer shows
#     the later offset, the hint is its last line (about 10 s; SKIP if opencode
#     cannot start);
#   - the real test-tasks.ps1 with a stand-in opencode: readBudget recorded in
#     the run JSON from the evidence log (clamps, byReason, files), null without
#     the plugin, the log variable restored and the log removed;
#   - controls, each of which must make at least one check fail: the before
#     hook's limit mutation removed (unit and live), the budget reset removed,
#     and the harness's readBudget recording removed;
#   - the installed opencode is the version the hooks were read at
#     (-PinnedOpencode): a different one FAILS until someone re-reads
#     session/tools.ts, read.ts and compaction.ts and moves the pin.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-read-budget.ps1 [-PluginPath <js>] [-ScriptPath <test-tasks.ps1>] [-PinnedOpencode 1.18.34]
param(
    [string]$PluginPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "opencode\plugins\read-budget.js"),
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$PinnedOpencode = "1.18.34"
)

$ErrorActionPreference = "Stop"
$script:fail = 0
$script:total = 0
$script:quiet = $false
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    $script:total++
    if (-not $script:quiet) { Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name) }
    if (-not $ok) {
        if (-not $script:quiet) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual" }
        $script:fail++
    }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host "FAIL: node is not on PATH"; exit 1 }
if (-not (Test-Path -LiteralPath $PluginPath)) { Write-Host "FAIL: plugin not found at $PluginPath"; exit 1 }

# Runs a node script and returns its output lines and exit code.
function Invoke-Node([string]$Script, [string[]]$NodeArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & node (Join-Path $PSScriptRoot $Script) @NodeArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Lines = @($out | ForEach-Object { "$_" }); Exit = $code }
}
function Count-Lines($r, [string]$prefix) { @($r.Lines | Where-Object { $_ -match "^$prefix " }).Count }

Write-Host "-- plugin unit checks (node)"
$unit = Invoke-Node "test-read-budget.mjs" @($PluginPath)
$unit.Lines | ForEach-Object { Write-Host $_ }
$unitPass = Count-Lines $unit "PASS"
$unitFail = Count-Lines $unit "FAIL"
$script:fail += $unitFail
$script:total += $unitPass + $unitFail
if ($unit.Exit -ne 0 -and $unitFail -eq 0) { Write-Host "FAIL node exited $($unit.Exit)"; $script:fail++; $script:total++ }

# The harness section as a function, so a control can run it against a copy
# of the adapter. Returns nothing; its checks go through Check.
function Test-HarnessRecording([string]$AgentsDir, [string]$Label) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("rbplugin-e2e-" + [guid]::NewGuid().ToString("N"))
    $psExe = (Get-Process -Id $PID).Path
    try {
        foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $tmp $d) -Force | Out-Null }
        Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $tmp "tests/test-tasks.ps1")
        Copy-Item -LiteralPath $AgentsDir -Destination (Join-Path $tmp "tests/agents") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $tmp "tests") -Recurse -Force
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
        @{ tasks = @([ordered]@{ id = "fx-readbudget"; title = "fx"; repo = $repo; branch = "bench/fx"; benchBaseCommit = $base
            allowFiles = @("src.txt"); srcRevertFiles = @("src.txt"); testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
            prompt = "fix src.txt" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $tmp "tests/tasks/manifest.json")
        @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { if ($env:FIXTURE_PLUGINS) { '{"plugin":["file:///x/opencode/plugins/read-budget.js"]}' } else { '{}' }; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
Add-Content -LiteralPath $env:FIXTURE_SEEN -Value ("log=" + $env:HOMELAB_READ_BUDGET_LOG)
if ($env:HOMELAB_READ_BUDGET_LOG) {
    $l = $env:HOMELAB_READ_BUDGET_LOG
    Add-Content -LiteralPath $l -Value '{"message":"loaded"}'
    Add-Content -LiteralPath $l -Value '{"message":"clamp","sessionID":"s","path":"/w/a.ts","offset":1,"asked":null,"set":300,"reason":"cap","chars":17000}'
    Add-Content -LiteralPath $l -Value '{"message":"clamp","sessionID":"s","path":"/w/b.ts","offset":1,"asked":null,"set":300,"reason":"cap","chars":17000}'
    Add-Content -LiteralPath $l -Value '{"message":"clamp","sessionID":"s","path":"/w/a.ts","offset":900,"asked":null,"set":100,"reason":"budget","chars":4000}'
    Add-Content -LiteralPath $l -Value 'not json at all'
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
        $leaked = $null
        try {
            $env:FIXTURE_PLUGINS = "1"
            $withOut = & $tt -Task fx-readbudget -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "with") *>&1 | Out-String
            Remove-Item Env:FIXTURE_PLUGINS
            $leaked = [Environment]::GetEnvironmentVariable("HOMELAB_READ_BUDGET_LOG")
            $null = & $tt -Task fx-readbudget -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "without") *>&1 | Out-String
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
        $jWith = Get-ChildItem (Join-Path $tmp "with") -Filter "tasks-fx-readbudget-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        $jWithout = Get-ChildItem (Join-Path $tmp "without") -Filter "tasks-fx-readbudget-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        Check "$Label with the plugin: the run got an evidence log path"   ($seen[0] -match '^log=.+rbplugin-.+\.jsonl$') "True"
        Check "$Label ...readBudget.clamps counts the clamp lines only"   $jWith.readBudget.clamps 3
        Check "$Label ...byReason splits cap and budget"                  "$($jWith.readBudget.byReason.cap)/$($jWith.readBudget.byReason.budget)" "2/1"
        Check "$Label ...files counts distinct paths"                     $jWith.readBudget.files 2
        Check "$Label ...the log variable does not outlive the run"       ([string]::IsNullOrEmpty($leaked)) "True"
        Check "$Label ...the evidence log is removed"                     (Test-Path -LiteralPath ($seen[0] -replace '^log=', '')) "False"
        Check "$Label ...compactionPluginRewrites stays null (no such plugin)" ($null -eq $jWith.compactionPluginRewrites) "True"
        Check "$Label without the plugin: no evidence log"                $seen[1] "log="
        Check "$Label ...readBudget null"                                 ($null -eq $jWithout.readBudget) "True"
    } finally {
        if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host "-- the harness records read-budget runs (real test-tasks.ps1, fixture repo, stand-in opencode)"
Test-HarnessRecording (Join-Path $PSScriptRoot "agents") "harness:"

Write-Host "-- live: the plugin inside the real opencode serve, against a scripted stand-in model"
$live = Invoke-Node "test-read-budget-live.mjs" @($PluginPath)
$live.Lines | ForEach-Object { Write-Host $_ }
$livePass = Count-Lines $live "PASS"
$liveFail = Count-Lines $live "FAIL"
$script:fail += $liveFail
$script:total += $livePass + $liveFail
if ($live.Exit -ne 0 -and $liveFail -eq 0) { Write-Host "FAIL live check exited $($live.Exit)"; $script:fail++; $script:total++ }

Write-Host "-- controls: each broken copy must fail at least one check"
function Test-Control([string]$Name, [int]$Failed) {
    Check "control: $Name fails a check ($Failed failed)" ($Failed -gt 0) "True"
}
$ctl = Join-Path ([IO.Path]::GetTempPath()) ("rbplugin-ctl-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $ctl -Force | Out-Null
try {
    $src = Get-Content -LiteralPath $PluginPath -Raw

    $noMutation = $src.Replace("args.limit = target", "void target")
    if ($noMutation -eq $src) { Check "control setup: the limit mutation is in the plugin" $false $true }
    $p1 = Join-Path $ctl "no-mutation.js"
    Set-Content -LiteralPath $p1 -Value $noMutation -NoNewline
    $r = Invoke-Node "test-read-budget.mjs" @($p1)
    Test-Control "no limit mutation (unit)" (Count-Lines $r "FAIL")
    $r = Invoke-Node "test-read-budget-live.mjs" @($p1)
    Test-Control "no limit mutation (live opencode)" (Count-Lines $r "FAIL")

    $noReset = $src.Replace("state.used.delete(input.sessionID)", "void 0")
    if ($noReset -eq $src) { Check "control setup: the budget reset is in the plugin" $false $true }
    $p2 = Join-Path $ctl "no-reset.js"
    Set-Content -LiteralPath $p2 -Value $noReset -NoNewline
    $r = Invoke-Node "test-read-budget.mjs" @($p2)
    Test-Control "no budget reset on compaction" (Count-Lines $r "FAIL")

    $adapter = Get-Content -LiteralPath (Join-Path $PSScriptRoot "agents/opencode.ps1") -Raw
    $noRecording = $adapter.Replace("ReadBudget = `$readBudget }", "ReadBudget = `$null }")
    if ($noRecording -eq $adapter) { Check "control setup: the readBudget recording is in the adapter" $false $true }
    $agentsCopy = Join-Path $ctl "agents"
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination $agentsCopy -Recurse
    Set-Content -LiteralPath (Join-Path $agentsCopy "opencode.ps1") -Value $noRecording -NoNewline
    $before = $script:fail; $totalBefore = $script:total; $script:quiet = $true
    try { Test-HarnessRecording $agentsCopy "control:" } finally { $script:quiet = $false }
    $delta = $script:fail - $before
    $script:fail = $before; $script:total = $totalBefore
    Test-Control "harness without the readBudget recording" $delta
} finally {
    Remove-Item -Recurse -Force $ctl -ErrorAction SilentlyContinue
}

Write-Host "-- the opencode these hooks were read at"
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$installed = (& opencode --version 2>$null | Out-String).Trim()
$ErrorActionPreference = $prev
Check "installed opencode is $PinnedOpencode (re-read tools.ts, read.ts and compaction.ts, then move -PinnedOpencode)" $installed $PinnedOpencode

Write-Host ""
Write-Host "$($script:total) checks (unit $($unitPass + $unitFail), live $($livePass + $liveFail))"
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

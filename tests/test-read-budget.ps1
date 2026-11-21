# protects: opencode/plugins/read-budget.js (1.x) and read-budget/index.js (2.x); fails on any opencode but 1.19.5 or 2.3.2
# run-after: The plugin or its core.js, any opencode upgrade, Start/Stop-AgentRunEnv
# test-read-budget.ps1 - regression guard for the read-budget plugin:
#   opencode/plugins/read-budget.js        the opencode 1.x plugin ({id, server()})
#   opencode/plugins/read-budget/index.js  the opencode 2.x plugin ({id, setup(ctx)})
#   opencode/plugins/read-budget/core.js   what both share (cap arithmetic, scan, hints, log)
#
# Why this exists: opencode 1.18.34's read returns up to 50 KB a call, and on
# kane-08 (qwen3.6, 65,536-token window) two whole-file reads of 131 KB and
# 185 KB overflowed the window, compaction followed, and the same four reads
# came back 17 to 19 times a run until the 45-minute timeout: 3 of 3 runs, no
# edit (docs/roadmap.md -> "Large-file fix (2026-10-17)"). 2.3.2's read still
# returns up to 2000 lines / 50 KiB. The plugin lowers each read's own `limit`
# to a share of the model's window, appends a hint to the result, shrinks a
# file that has used its budget since the last compaction to 100-line reads,
# and resets that budget at each compaction. It rests on undocumented details
# of each opencode's hooks (1.x: tool.execute.before's output.args is the
# object read runs with, chat.params, experimental.session.compacting; 2.x:
# execute.before's event.input is, execute.after's event.result reaches the
# model, the session context and compaction hooks), so this guard fails loudly
# when any of them moves.
#
# What it does:
#   - tests/test-read-budget.mjs under node, for BOTH entrypoints whatever
#     opencode is installed: the cap arithmetic at 32k / 64k / 200k / unknown,
#     the env override and off, the line-fit computation (number prefix, a
#     2000-char line cut, the offset), the caller's smaller limit, small files,
#     missing / directory / binary / image paths, the hint, the per-file budget
#     and its 100-line window, the reset on compaction, two sessions apart, the
#     log lines; then each entry's own (1.x: the module shape the v1 loader
#     needs; 2.x: setup(ctx)'s four hook registrations, the window from
#     ctx.model.list(), negative offsets, the result's text parts, cleanup);
#   - tests/test-read-budget-live.mjs: the entrypoint for the INSTALLED opencode
#     inside the real `opencode serve` with a scripted stand-in model that reads
#     a ~130 KB file whole - the tool result it gets back is clamped near the
#     cap, read's footer shows the later offset, the hint is its last line; on
#     2.x also a budget spent over five reads and reset by a compaction through
#     the API (about 10 s; SKIP if opencode cannot start);
#   - the real test-tasks.ps1 with a stand-in opencode: readBudget recorded in
#     the run JSON from the evidence log (clamps, byReason, files, and loaded /
#     off / capOverride from the plugin's first "loaded" line, so a run with
#     HOMELAB_READ_MAX_CHARS=off says so itself; the 2026-10-19 plugin-off
#     rounds could only be told apart by their folder name), null without the
#     plugin, the log variable restored and the log removed;
#   - controls, each of which must make at least one check fail: in each
#     entrypoint, the before hook's limit mutation removed (unit, and live for
#     the installed opencode's entry) and the budget reset removed (unit, and
#     live on 2.x); the harness's readBudget recording removed, and the loaded
#     line ignored;
#   - the installed opencode is a version the hooks were read at
#     (-PinnedOpencode 1.19.5 for the 1.x entry, -PinnedOpencodeV2 2.3.2 for the
#     2.x one): a different one FAILS until someone re-reads that version's
#     hooks and read, re-runs this guard and moves the pin.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-read-budget.ps1 [-PluginPath <1.x js>] [-PluginV2Path <2.x index.js>]
#             [-ScriptPath <test-tasks.ps1>] [-PinnedOpencode 1.19.5] [-PinnedOpencodeV2 2.3.2]
param(
    [string]$PluginPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "opencode\plugins\read-budget.js"),
    [string]$PluginV2Path = (Join-Path (Split-Path -Parent $PSScriptRoot) "opencode\plugins\read-budget\index.js"),
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$PinnedOpencode = "1.19.5",
    [string]$PinnedOpencodeV2 = "2.3.2"
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
foreach ($p in @($PluginPath, $PluginV2Path)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "FAIL: plugin not found at $p"; exit 1 }
}

# Runs a node script and returns its output lines and exit code.
function Invoke-Node([string]$Script, [string[]]$NodeArgs) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & node (Join-Path $PSScriptRoot $Script) @NodeArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [pscustomobject]@{ Lines = @($out | ForEach-Object { "$_" }); Exit = $code }
}
function Count-Lines($r, [string]$prefix) { @($r.Lines | Where-Object { $_ -match "^$prefix " }).Count }

# Adds a node run's PASS / FAIL lines to the totals; returns the number of checks.
function Add-NodeRun($r, [string]$What) {
    $r.Lines | ForEach-Object { Write-Host $_ }
    $pass = Count-Lines $r "PASS"
    $failed = Count-Lines $r "FAIL"
    $script:fail += $failed
    $script:total += $pass + $failed
    if ($r.Exit -ne 0 -and $failed -eq 0) { Write-Host "FAIL $What exited $($r.Exit)"; $script:fail++; $script:total++ }
    return $pass + $failed
}

$unitCount = 0
Write-Host "-- plugin unit checks (node), the 1.x entry: $PluginPath"
$unitCount += Add-NodeRun (Invoke-Node "test-read-budget.mjs" @($PluginPath)) "the 1.x unit run"
Write-Host "-- plugin unit checks (node), the 2.x entry: $PluginV2Path"
$unitCount += Add-NodeRun (Invoke-Node "test-read-budget.mjs" @($PluginV2Path)) "the 2.x unit run"

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
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "checks") -Destination (Join-Path $tmp "tests") -Recurse -Force
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
    # The real plugin's "loaded" line: what it saw of HOMELAB_READ_MAX_CHARS.
    if (-not $env:FIXTURE_NO_LOADED) {
        $o = ("$env:HOMELAB_READ_MAX_CHARS".Trim().ToLower() -eq 'off')
        Add-Content -LiteralPath $l -Value (@{ message = 'loaded'; off = $o; capOverride = $(if ($env:HOMELAB_READ_MAX_CHARS) { $env:HOMELAB_READ_MAX_CHARS } else { $null }) } | ConvertTo-Json -Compress)
        Add-Content -LiteralPath $l -Value '{"message":"loaded","off":false,"capOverride":"999"}'
    }
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
        $origMax = [Environment]::GetEnvironmentVariable("HOMELAB_READ_MAX_CHARS")
        Remove-Item Env:HOMELAB_READ_MAX_CHARS -ErrorAction SilentlyContinue
        try {
            $env:FIXTURE_PLUGINS = "1"
            $withOut = & $tt -Task fx-readbudget -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "with") *>&1 | Out-String
            $leaked = [Environment]::GetEnvironmentVariable("HOMELAB_READ_BUDGET_LOG")
            $env:HOMELAB_READ_MAX_CHARS = "off"
            $null = & $tt -Task fx-readbudget -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "off") *>&1 | Out-String
            Remove-Item Env:HOMELAB_READ_MAX_CHARS
            $env:FIXTURE_NO_LOADED = "1"
            $null = & $tt -Task fx-readbudget -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "noloaded") *>&1 | Out-String
            Remove-Item Env:FIXTURE_NO_LOADED, Env:FIXTURE_PLUGINS
            $null = & $tt -Task fx-readbudget -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $tmp "no-log") -ResultsDir (Join-Path $tmp "without") *>&1 | Out-String
        } finally {
            $env:PATH = $origPath
            Remove-Item Env:FIXTURE_SEEN, Env:FIXTURE_PLUGINS, Env:FIXTURE_NO_LOADED, Env:HOMELAB_READ_MAX_CHARS -ErrorAction SilentlyContinue
            if ($null -ne $origMax) { $env:HOMELAB_READ_MAX_CHARS = $origMax }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $tmp "seen.txt"))) {
            Write-Host "FAIL the harness never reached opencode run; its output:"
            Write-Host $withOut
            throw "fixture run did not start"
        }
        $seen = @(Get-Content -LiteralPath (Join-Path $tmp "seen.txt"))
        $jWith = Get-ChildItem (Join-Path $tmp "with") -Filter "tasks-fx-readbudget-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        $jOff = Get-ChildItem (Join-Path $tmp "off") -Filter "tasks-fx-readbudget-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        $jNoLoaded = Get-ChildItem (Join-Path $tmp "noloaded") -Filter "tasks-fx-readbudget-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        $jWithout = Get-ChildItem (Join-Path $tmp "without") -Filter "tasks-fx-readbudget-*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        Check "$Label with the plugin: the run got an evidence log path"   ($seen[0] -match '^log=.+rbplugin-.+\.jsonl$') "True"
        Check "$Label ...readBudget.clamps counts the clamp lines only"   $jWith.readBudget.clamps 3
        Check "$Label ...byReason splits cap and budget"                  "$($jWith.readBudget.byReason.cap)/$($jWith.readBudget.byReason.budget)" "2/1"
        Check "$Label ...files counts distinct paths"                     $jWith.readBudget.files 2
        Check "$Label ...loaded, off and capOverride from the first loaded line" "$($jWith.readBudget.loaded)/$($jWith.readBudget.off)/$($null -eq $jWith.readBudget.capOverride)" "True/False/True"
        Check "$Label ...the log variable does not outlive the run"       ([string]::IsNullOrEmpty($leaked)) "True"
        Check "$Label ...the evidence log is removed"                     (Test-Path -LiteralPath ($seen[0] -replace '^log=', '')) "False"
        Check "$Label ...compactionPluginRewrites stays null (no such plugin)" ($null -eq $jWith.compactionPluginRewrites) "True"
        Check "$Label HOMELAB_READ_MAX_CHARS=off: readBudget records off and the override" "$($jOff.readBudget.loaded)/$($jOff.readBudget.off)/$($jOff.readBudget.capOverride)" "True/True/off"
        Check "$Label no loaded line: loaded false, off and capOverride null" "$($jNoLoaded.readBudget.loaded)/$($null -eq $jNoLoaded.readBudget.off)/$($null -eq $jNoLoaded.readBudget.capOverride)" "False/True/True"
        Check "$Label ...its clamps are still counted"                    $jNoLoaded.readBudget.clamps 3
        Check "$Label without the plugin: no evidence log"                $seen[-1] "log="
        Check "$Label ...readBudget null"                                 ($null -eq $jWithout.readBudget) "True"
    } finally {
        if (Test-Path (Join-Path $tmp "repo")) { git -C (Join-Path $tmp "repo") worktree prune 2>$null }
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host "-- the harness records read-budget runs (real test-tasks.ps1, fixture repo, stand-in opencode)"
Test-HarnessRecording (Join-Path $PSScriptRoot "agents") "harness:"

# The live part runs the entry for the installed opencode ("1.19.5" from 1.x,
# "opencode v2.3.2" from 2.x).
$prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$installed = (& opencode --version 2>$null | Out-String).Trim()
$ErrorActionPreference = $prev
$installedVersion = if ($installed -match '(\d+\.\d+\.\d+)') { $Matches[1] } else { "" }
$liveV2 = $installedVersion -like "2.*"
$livePath = if ($liveV2) { $PluginV2Path } else { $PluginPath }
Write-Host "-- live: the $(if ($liveV2) { '2.x' } else { '1.x' }) entry inside the real opencode serve ($(if ($installed) { $installed } else { 'opencode not found' })), against a scripted stand-in model"
$liveCount = Add-NodeRun (Invoke-Node "test-read-budget-live.mjs" @($livePath)) "the live run"

Write-Host "-- controls: each broken copy must fail at least one check"
function Test-Control([string]$Name, [int]$Failed) {
    Check "control: $Name fails a check ($Failed failed)" ($Failed -gt 0) "True"
}
$ctl = Join-Path ([IO.Path]::GetTempPath()) ("rbplugin-ctl-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $ctl -Force | Out-Null
try {
    # A copy of the plugin tree (both entries and core.js) with one entry's
    # text changed; returns the changed entry's path. The copy keeps the layout,
    # so the entry's import of core.js still resolves.
    $pluginsDir = Split-Path -Parent $PluginPath
    function New-BrokenCopy([string]$Name, [string]$Entry, [string]$Old, [string]$New) {
        $dir = Join-Path $ctl $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath $PluginPath -Destination $dir
        Copy-Item -LiteralPath (Join-Path $pluginsDir "read-budget") -Destination $dir -Recurse
        $rel = [IO.Path]::GetRelativePath($pluginsDir, $Entry)
        $target = Join-Path $dir $rel
        $text = Get-Content -LiteralPath $target -Raw
        $broken = $text.Replace($Old, $New)
        if ($broken -eq $text) { Check "control setup: '$Old' is in $rel" $false $true }
        Set-Content -LiteralPath $target -Value $broken -NoNewline
        return $target
    }

    # 1.x entry: tool.execute.before's output.args; experimental.session.compacting.
    $p1 = New-BrokenCopy "v1-no-mutation" $PluginPath "args.limit = target" "void target"
    Test-Control "1.x: no limit mutation (unit)" (Count-Lines (Invoke-Node "test-read-budget.mjs" @($p1)) "FAIL")
    if (-not $liveV2) { Test-Control "1.x: no limit mutation (live opencode $installedVersion)" (Count-Lines (Invoke-Node "test-read-budget-live.mjs" @($p1)) "FAIL") }
    $p2 = New-BrokenCopy "v1-no-reset" $PluginPath "state.used.delete(input.sessionID)" "void 0"
    Test-Control "1.x: no budget reset on compaction (unit)" (Count-Lines (Invoke-Node "test-read-budget.mjs" @($p2)) "FAIL")

    # 2.x entry: execute.before's event.input; the compaction hook.
    $p3 = New-BrokenCopy "v2-no-mutation" $PluginV2Path "input.limit = target" "void target"
    Test-Control "2.x: no limit mutation (unit)" (Count-Lines (Invoke-Node "test-read-budget.mjs" @($p3)) "FAIL")
    if ($liveV2) { Test-Control "2.x: no limit mutation (live opencode $installedVersion)" (Count-Lines (Invoke-Node "test-read-budget-live.mjs" @($p3)) "FAIL") }
    $p4 = New-BrokenCopy "v2-no-reset" $PluginV2Path "state.used.delete(event.sessionID)" "void 0"
    Test-Control "2.x: no budget reset on compaction (unit)" (Count-Lines (Invoke-Node "test-read-budget.mjs" @($p4)) "FAIL")
    if ($liveV2) { Test-Control "2.x: no budget reset on compaction (live opencode $installedVersion)" (Count-Lines (Invoke-Node "test-read-budget-live.mjs" @($p4)) "FAIL") }

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

    $noLoaded = $adapter.Replace("`$loadedLine = `$e; continue", "continue")
    if ($noLoaded -eq $adapter) { Check "control setup: the loaded-line reading is in the adapter" $false $true }
    Set-Content -LiteralPath (Join-Path $agentsCopy "opencode.ps1") -Value $noLoaded -NoNewline
    $before = $script:fail; $totalBefore = $script:total; $script:quiet = $true
    try { Test-HarnessRecording $agentsCopy "control:" } finally { $script:quiet = $false }
    $delta = $script:fail - $before
    $script:fail = $before; $script:total = $totalBefore
    Test-Control "harness that ignores the plugin's loaded line" $delta
} finally {
    Remove-Item -Recurse -Force $ctl -ErrorAction SilentlyContinue
}

Write-Host "-- the opencode these hooks were read at"
$pin = if ($liveV2) { $PinnedOpencodeV2 } else { $PinnedOpencode }
$reread = if ($liveV2) { "re-read 2.x's tool hooks, session context/compaction hooks and ReadTool, then move -PinnedOpencodeV2" } else { "re-read tools.ts, read.ts and compaction.ts, then move -PinnedOpencode" }
Check "installed opencode is $PinnedOpencode or $PinnedOpencodeV2 ($reread)" $installedVersion $pin

Write-Host ""
Write-Host "$($script:total) checks (unit $unitCount, live $liveCount)"
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

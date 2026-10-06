# test-run-cost.ps1 - regression guard for a run's token usage and cost estimate
#
# Why this exists: hosted seats (OpenCode Go, 2026-10-06) bill by token, and the
# owner wants the repo to show what model access costs next to what it achieves
# (docs/costs.md). test-tasks.ps1 records every run's token totals (`usage`)
# and, for a model with a row in costs/go-rates.tsv, the dollars that run cost
# (`costEstimate`); run-tasks-batch.ps1 stops a hosted model at its spend cap
# from those numbers, so a wrong sum or a misread rate spends real money.
#
# What it does: pulls the REAL Get-TranscriptUsage and Get-RunCostEstimate out
# of test-tasks.ps1 and checks them on a synthetic transcript and rates file
# (exact arithmetic, blank rates, an unknown model, a comma-decimal culture),
# then runs the real test-tasks.ps1 end to end with a stand-in opencode and a
# hosted model id: the run JSON must carry `usage` and `costEstimate`, and a
# local model's run `usage` with costEstimate null. Exit 1 on any failure.
#
# Usage:  .\tests\test-run-cost.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
foreach ($name in "Get-TranscriptUsage", "Get-RunCostEstimate") {
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("runcost-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
$culture = [Threading.Thread]::CurrentThread.CurrentCulture
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    Write-Host "-- Get-TranscriptUsage (real function)"
    $tr = Join-Path $tmp "t.jsonl"
    @(
        '{"type":"step_start","part":{}}'
        '{"type":"step_finish","part":{"reason":"tool-calls","tokens":{"input":1000,"output":200,"reasoning":50,"cache":{"read":100000,"write":0}}}}'
        'not json'
        '{"type":"text","part":{"text":"a step_finish mentioned in prose"}}'
        '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":500,"output":300,"reasoning":0,"cache":{"read":20000,"write":4000}}}}'
    ) | Set-Content -LiteralPath $tr
    $u = Get-TranscriptUsage -Path $tr
    Check "steps counted"                      $u.steps 2
    Check "input summed"                       $u.input 1500
    Check "output summed"                      $u.output 500
    Check "reasoning summed"                   $u.reasoning 50
    Check "cache read summed"                  $u.cacheRead 120000
    Check "cache write summed"                 $u.cacheWrite 4000
    Check "a missing transcript: zeros"        (Get-TranscriptUsage -Path (Join-Path $tmp "nope.jsonl")).steps 0

    Write-Host "-- Get-RunCostEstimate (real function)"
    $rates = Join-Path $tmp "rates.tsv"
    @(
        "model`tplan`ttier`tinputPerM`toutputPerM`tcacheReadPerM`tcacheWritePerM`tmonthlyLimitUsd`tchecked`tsource"
        "opencode-go/full`tgo`t`t2.00`t6.00`t0.25`t2.50`t15`t2026-10-06`thttps://example.invalid"
        "opencode-go/nowrite`tgo`t`t1.40`t4.40`t0.26`t`t60`t2026-10-06`thttps://example.invalid"
    ) | Set-Content -LiteralPath $rates
    # (1500*2 + 500*6 + 120000*0.25 + 4000*2.5) / 1e6 = (3000 + 3000 + 30000 + 10000) / 1e6
    $c = Get-RunCostEstimate -ModelId "opencode-go/full" -Usage $u -RatesPath $rates
    Check "every rate applied"                 $c.usd 0.046
    Check "...the rate's checked date kept"    $c.rateChecked "2026-10-06"
    # (1500*1.4 + 500*4.4 + 120000*0.26 + 4000*0) / 1e6
    Check "a blank cache-write rate counts 0"  (Get-RunCostEstimate -ModelId "opencode-go/nowrite" -Usage $u -RatesPath $rates).usd 0.0355
    Check "a model with no rate: null"         ($null -eq (Get-RunCostEstimate -ModelId "ollama-desktop/qwen3.6" -Usage $u -RatesPath $rates)) "True"
    Check "no rates file: null"                ($null -eq (Get-RunCostEstimate -ModelId "opencode-go/full" -Usage $u -RatesPath (Join-Path $tmp "none.tsv"))) "True"
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo("de-DE")
    Check "a comma-decimal culture reads 2.00 as two" (Get-RunCostEstimate -ModelId "opencode-go/full" -Usage $u -RatesPath $rates).usd.ToString([Globalization.CultureInfo]::InvariantCulture) "0.046"
    [Threading.Thread]::CurrentThread.CurrentCulture = $culture

    Write-Host "-- end to end: the real test-tasks.ps1 records usage and cost"
    $e2e = Join-Path $tmp "e2e"
    foreach ($d in @("tests/tasks", "bin", "repo", "costs")) { New-Item -ItemType Directory -Path (Join-Path $e2e $d) -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $e2e "tests/test-tasks.ps1")
    Copy-Item -LiteralPath $rates -Destination (Join-Path $e2e "costs/go-rates.tsv")
    $repo = Join-Path $e2e "repo"
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
    'Write-Host "Tests  1 passed (1)"; exit 0' | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
    git -C $repo add -A
    git -C $repo commit -q -m base
    $base = (git -C $repo rev-parse HEAD).Trim()
    @{ tasks = @([ordered]@{ id = "fx-cost"; title = "fx"; repo = $repo; branch = "bench/fx"; benchBaseCommit = $base
        allowFiles = @("src.txt"); srcRevertFiles = @("src.txt"); testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @()
        prompt = "fix src.txt" }) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $e2e "tests/tasks/manifest.json")
    @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -ne 'run') { exit 2 }
$dir = $a[[array]::IndexOf($a, '--dir') + 1]
Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
'{"type":"tool_use","sessionID":"s","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"},"output":"ok"}}}'
'{"type":"step_finish","sessionID":"s","part":{"reason":"tool-calls","tokens":{"input":1000,"output":200,"reasoning":50,"cache":{"read":100000,"write":0}}}}'
'{"type":"step_finish","sessionID":"s","part":{"reason":"stop","tokens":{"input":500,"output":300,"reasoning":0,"cache":{"read":20000,"write":4000}}}}'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $e2e "bin/standin.ps1")
    $bin = Join-Path $e2e "bin"
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $origPath = $env:PATH
    $env:PATH = "$bin;$env:PATH"
    try {
        $out = & (Join-Path $e2e "tests/test-tasks.ps1") -Task fx-cost -Model opencode-go/full -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
        $null = & (Join-Path $e2e "tests/test-tasks.ps1") -Task fx-cost -Model fixture/local -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $e2e "no-log") *>&1 | Out-String
    } finally {
        $env:PATH = $origPath
    }
    $res = Join-Path $e2e "tests/results"
    $jh = Get-ChildItem $res -Filter "tasks-fx-cost-opencode-go_full_*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    $jl = Get-ChildItem $res -Filter "tasks-fx-cost-fixture_local_*.json" | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    Check "hosted run: usage recorded"         ("{0}/{1}/{2}/{3}" -f $jh.usage.steps, $jh.usage.input, $jh.usage.cacheRead, $jh.usage.output) "2/1500/120000/500"
    Check "...cost estimated"                  $jh.costEstimate.usd 0.046
    Check "...and printed"                     (($out -replace '\s+', ' ') -match 'model access: about \$0\.0460') "True"
    Check "local run: usage recorded"          $jl.usage.steps 2
    Check "...no rate, no cost"                ($null -eq $jl.costEstimate) "True"
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $culture
    Get-ChildItem -LiteralPath $tmp -Recurse -Directory -Filter repo -ErrorAction SilentlyContinue | ForEach-Object { git -C $_.FullName worktree prune 2>$null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

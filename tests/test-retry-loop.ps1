# test-retry-loop.ps1 - regression guard for tests/run-retries.ps1, milestone 4's dispatcher loop.
#
# What it checks: the real Get-AttemptVerdict and Get-RetryFalsifier on synthetic run JSONs, then the real
# run-retries.ps1 end to end against a stand-in test-tasks.ps1 that plays a scripted outcome per attempt
# (pass, tampered, acceptance FAIL, suite FAIL, scope FAIL, or infrastructure = no run JSON) and records the
# arguments it was given. Cases: accepted at once; accepted after each kind of rejection; the cap reached; every
# attempt shown its tests and handed the harness arguments (and -ReadOnlyAcceptance when set); one summary row per
# task with the reasons in order; the falsifier over the batch, both ways.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-retry-loop.ps1 [-ScriptPath <a run-retries.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "run-retries.ps1"))

$ErrorActionPreference = "Stop"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("retry-loop-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # --- the functions -------------------------------------------------------------
    # Dot-sourcing binds the script's parameters (and its ErrorActionPreference) into this scope, so pass
    # -ScriptPath back explicitly and restore Stop: otherwise $ScriptPath becomes the real harness and an
    # error later in this guard would not stop it.
    $retries = $ScriptPath
    . $retries -Tasks x -Model m -TaskManifest x -ResultsDir $tmp -ScriptPath $retries
    $ScriptPath = $retries
    $ErrorActionPreference = "Stop"
    function J([string]$acc, [string]$scope, [string]$suite, [string[]]$tampered) { [pscustomobject]@{ acceptance = @{ status = $acc }; gates = @{ scope = $scope; suite = $suite }; acceptanceShown = @{ tampered = $tampered } } }
    Write-Host "-- Get-AttemptVerdict"
    Check "all gates green: accepted"            (Get-AttemptVerdict (J PASS PASS PASS @())).Reason "accepted"
    Check "no run JSON: infrastructure"          (Get-AttemptVerdict $null).Reason "infrastructure"
    Check "a tamper wins over the other gates"   (Get-AttemptVerdict (J PASS FAIL PASS @("t.test.ts (edited)"))).Reason "tampered"
    Check "acceptance FAIL"                      (Get-AttemptVerdict (J FAIL PASS PASS @())).Reason "acceptance"
    Check "suite FAIL"                           (Get-AttemptVerdict (J PASS PASS FAIL @())).Reason "suite"
    Check "scope FAIL without a tamper"          (Get-AttemptVerdict (J PASS FAIL PASS @())).Reason "scope"
    Write-Host "-- Get-RetryFalsifier"
    $r1 = @(1, 1, 2, 1) | ForEach-Object { [pscustomobject]@{ Attempts = $_; Accepted = $true } }
    $f = Get-RetryFalsifier -Rows $r1 -Cap 3 -MaxMean 1.5 -MaxCapShare 0.15
    Check "mean 1.25, no cap hit: holds"         ("{0}|{1}|{2}" -f $f.MeanAttempts, $f.CapHits, $f.Falsified) "1.25|0|False"
    $r2 = @($r1) + [pscustomobject]@{ Attempts = 3; Accepted = $false }
    $f = Get-RetryFalsifier -Rows $r2 -Cap 3 -MaxMean 1.5 -MaxCapShare 0.15
    Check "one cap hit in 5 (0.2 > 0.15): falsified" ("{0}|{1}|{2}" -f $f.CapHits, $f.CapHitShare, $f.Falsified) "1|0.2|True"
    $r3 = @(2, 2, 1, 2) | ForEach-Object { [pscustomobject]@{ Attempts = $_; Accepted = $true } }
    Check "mean 1.75 > 1.5: falsified"           (Get-RetryFalsifier -Rows $r3 -Cap 3 -MaxMean 1.5 -MaxCapShare 0.15).Falsified "True"
    Check "accepted at the cap is not a cap hit" (Get-RetryFalsifier -Rows @([pscustomobject]@{ Attempts = 3; Accepted = $true }) -Cap 3 -MaxMean 5 -MaxCapShare 0.15).CapHits 0

    # --- end to end, against a stand-in harness ------------------------------------
    $stand = Join-Path $tmp "test-tasks.ps1"
    @'
param([string[]]$Task, [string]$Model, [string]$TaskManifest, [string]$ResultsDir, [switch]$ShowAcceptance, [switch]$ReadOnlyAcceptance, [switch]$NudgeOnStop, [int]$StopClassifier = 3, [int]$RunTimeout = 900)
$t = $Task[0]
$counter = Join-Path $env:FX_STATE "$t.count"
$n = 1 + $(if (Test-Path $counter) { [int](Get-Content $counter) } else { 0 }); Set-Content $counter $n
Add-Content (Join-Path $env:FX_STATE "calls.log") ("{0}|{1}|show={2}|ro={3}|nudge={4}|cls={5}|timeout={6}" -f $t, $n, [bool]$ShowAcceptance, [bool]$ReadOnlyAcceptance, [bool]$NudgeOnStop, $StopClassifier, $RunTimeout)
$plan = (($env:FX_PLAN -split ";") | Where-Object { $_.StartsWith("${t}:") }) -replace "^${t}:", ""
$o = ($plan -split ",")[$n - 1]
if ($o -eq "infra") { Write-Host "  [FAIL] opencode run -> infrastructure"; exit 0 }
$acc = if ($o -eq "acc") { "FAIL" } else { "PASS" }; $suite = if ($o -eq "suite") { "FAIL" } else { "PASS" }
$scope = if ($o -in "scope", "tamper") { "FAIL" } else { "PASS" }; $tam = if ($o -eq "tamper") { @("x.test.ts (edited)") } else { @() }
$j = [ordered]@{ taskId = $t; elapsedSec = 10; usage = @{ output = 100 }; acceptance = @{ status = $acc }; gates = @{ scope = $scope; suite = $suite }; acceptanceShown = @{ tampered = $tam } }
Start-Sleep -Milliseconds 20
$j | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ResultsDir ("tasks-{0}-m_{1}.json" -f $t, [guid]::NewGuid().ToString("N").Substring(0, 8)))
'@ | Set-Content -LiteralPath $stand
    $state = Join-Path $tmp "state"; New-Item -ItemType Directory $state | Out-Null
    $res = Join-Path $tmp "results"
    $env:FX_STATE = $state
    $env:FX_PLAN = "a:pass;b:acc,pass;c:tamper,tamper,tamper;d:infra,pass;e:suite,scope,pass"
    # In-process: -HarnessArgs is a hashtable, which pwsh -File cannot pass.
    $log = & $ScriptPath -Tasks "a,b,c,d,e" -Model "fx/m" -MaxAttempts 3 -TaskManifest (Join-Path $tmp "m.json") -ResultsDir $res -ScriptPath $stand -HarnessArgs @{ NudgeOnStop = $true; StopClassifier = 2; RunTimeout = 123 } *>&1 | Out-String
    $rows = @(Import-Csv -Delimiter "`t" -LiteralPath (Join-Path $res "retry-summary.tsv"))
    $byTask = @{}; foreach ($r in $rows) { $byTask[$r.task] = $r }
    Write-Host "-- end to end"
    Check "one summary row per task"                    $rows.Count 5
    Check "a: accepted at attempt 1"                    ("{0}|{1}|{2}" -f $byTask.a.attempts, $byTask.a.accepted, $byTask.a.acceptedAttempt) "1|True|1"
    Check "b: acceptance FAIL, then accepted"           ("{0}|{1}" -f $byTask.b.attempts, $byTask.b.reasons) "2|acceptance;accepted"
    Check "c: tampered 3 times, not accepted at the cap" ("{0}|{1}|{2}|{3}" -f $byTask.c.attempts, $byTask.c.accepted, $byTask.c.acceptedAttempt, $byTask.c.reasons) "3|False|-|tampered;tampered;tampered"
    Check "d: no run JSON is infrastructure, then accepted" $byTask.d.reasons "infrastructure;accepted"
    Check "e: suite, then scope, then accepted"         ("{0}|{1}" -f $byTask.e.attempts, $byTask.e.reasons) "3|suite;scope;accepted"
    Check "...each attempt's run JSON is named (- for none)" (($byTask.d.runs -split ";")[0]) "-"
    Check "seconds and output tokens summed over attempts" ("{0}|{1}" -f $byTask.e.seconds, $byTask.e.outputTokens) "30|300"
    $calls = @(Get-Content (Join-Path $state "calls.log"))
    Check "the harness ran once per attempt (1+2+3+2+3)" $calls.Count 11
    Check "every attempt was shown its tests and got the harness arguments" @($calls | Where-Object { $_ -notmatch 'show=True\|ro=False\|nudge=True\|cls=2\|timeout=123$' }).Count 0
    Check "the falsifier is reported: mean 2.2, cap on 1 of 5, FALSIFIED" ([bool]($log -match 'mean 2\.2 attempt' -and $log -match 'cap reached on 1 \(0\.2\)' -and $log -match 'falsifier: FALSIFIED')) "True"

    Write-Host "-- -ReadOnlyAcceptance reaches every attempt"
    Remove-Item (Join-Path $state "*") -Force
    $env:FX_PLAN = "a:acc,pass"
    $null = & $ScriptPath -Tasks "a" -Model "fx/m" -MaxAttempts 2 -TaskManifest (Join-Path $tmp "m.json") -ResultsDir (Join-Path $tmp "results-ro") -ScriptPath $stand -ReadOnlyAcceptance *>&1 | Out-String
    $calls = @(Get-Content (Join-Path $state "calls.log"))
    Check "both attempts got -ReadOnlyAcceptance"       @($calls | Where-Object { $_ -match 'ro=True' }).Count 2
} finally {
    Remove-Item Env:FX_STATE, Env:FX_PLAN -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

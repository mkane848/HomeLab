# test-hosted-seats.ps1 - regression guard for hosted (OpenCode Go) seats and the
# per-model spend cap in run-tasks-batch.ps1.
#
# Why this exists: hosted seats cost the owner money per token. A batch may spend
# at most -SpendCapShare (default 0.2) of a model's monthly allowance
# (costs/go-rates.tsv), so it can never lock a model out for longer than Go's
# 5-hour window. Get the offer gate or the cap wrong and a batch either drives a
# seat that cannot run or spends past the owner's rule without saying so.
#
# What it does:
#   1. Pulls the REAL functions out of run-tasks-batch.ps1 and checks the offer
#      gate (listed by `opencode models opencode-go`, key file present, config
#      resolves), the cap arithmetic and refusals, the transcript token sum and
#      the per-run spend measure (graded JSON, _INFRA_ transcript, a JSON with no
#      estimate, files that were there before), and that local seats are offered
#      exactly as before. Where test-tasks.ps1 has Get-RunCostEstimate /
#      Get-TranscriptUsage, the batch's own estimate must agree with them.
#   2. Checks the real registry and rate table: the five approved seats have
#      `opencode-go` rows and a rate row each, so none is refused for lack of one.
#   3. Runs the REAL run-tasks-batch.ps1 end to end in a scratch tree, with a
#      stand-in `opencode` first on PATH (lists models and prints a config; any
#      other call is logged and fails), a stand-in test-tasks.ps1 that writes run
#      JSONs and transcripts the way the real one names them, and a stand-in
#      Ollama /api/tags for the one local seat. No model is ever called.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-hosted-seats.ps1 [-ScriptPath <a run-tasks-batch.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "run-tasks-batch.ps1"))

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-Functions([string]$Path, [string[]]$Names, [switch]$Optional) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs.Count) { $errs; exit 2 }
    $all = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
    $found = @()
    foreach ($name in $Names) {
        $fn = $all | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $fn) {
            if ($Optional) { continue }
            Write-Host "FAIL: $name not found in $Path"; exit 2
        }
        $found += $fn.Extent.Text
    }
    return $found
}
foreach ($text in (Get-Functions $ScriptPath @("Test-HostedModelId", "Get-HostedSeatGate", "ConvertTo-RateValue", "Get-GoRates",
        "Get-SpendCap", "Get-TranscriptTokenUsage", "Get-UsageCostUsd", "Get-ResultFileNames", "Get-NewRunFiles", "Get-ProviderRefusal", "Measure-RunSpend",
        "Get-CapStatus", "Format-Usd", "Format-SpendCap", "Get-RegistryRows", "Get-AvailableModelSeats"))) {
    Invoke-Expression $text
}
# The run JSON's estimate comes from test-tasks.ps1; the batch's transcript
# estimate must match it. Optional so this guard does not break if they move.
$tt = @(Get-Functions (Join-Path $PSScriptRoot "test-tasks.ps1") @("Get-TranscriptUsage", "Get-RunCostEstimate") -Optional)
foreach ($text in $tt) { Invoke-Expression $text }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }
function Lacks([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "False" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("hosted-seats-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding $false
function Write-Fixture([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Step([hashtable]$Tokens) {
    $c = if ($Tokens.ContainsKey("read")) { ',"cache":{"read":' + $Tokens.read + ',"write":' + $Tokens.write + '}' } else { "" }
    return '{"type":"step_finish","part":{"reason":"stop","tokens":{"input":' + $Tokens.input + ',"output":' + $Tokens.output + ',"reasoning":' + $Tokens.reasoning + $c + '}}}'
}

$registryFixture = @"
# fixture registry
tag`thosts`tdesc
qwen3:8b`tdesktop node3`tlocal seat
qwen3:14b`tdesktop`tlocal seat
alpha`topencode-go`thosted
beta`topencode-go`thosted
gamma`topencode-go`thosted, not listed by opencode
delta`topencode-go`thosted, no rate row
"@ -replace "`r`n", "`n"
$ratesFixture = @"
model`tplan`ttier`tinputPerM`toutputPerM`tcacheReadPerM`tcacheWritePerM`tmonthlyLimitUsd`tchecked`tsource
opencode-go/alpha`tgo`t`t2.00`t4.00`t0.50`t`t10`t2026-10-06`tfixture
opencode-go/beta`tgo`t`t1.00`t1.00`t0.10`t`t100`t2026-10-06`tfixture
opencode-go/gamma`tgo`t`t1.00`t1.00`t`t`t60`t2026-10-06`tfixture
opencode-go/nolimit`tgo`t`t1.00`t1.00`t`t`t`t2026-10-06`tfixture
opencode-go/nooutput`tgo`t`t1.00`t`t`t`t60`t2026-10-06`tfixture
"@ -replace "`r`n", "`n"
# One _INFRA_ transcript's tokens: input 250k, output 125k (reasoning 9,999 is
# already inside output to opencode, so not billed again), cache read 400k,
# cache write 1k at a blank rate. At alpha's rates: 0.50 + 0.50 + 0.20 = 1.20.
$infraTranscript = @(
    '{"type":"step_start","part":{}}',
    (Step @{ input = 200000; output = 50000; reasoning = 0; read = 400000; write = 1000 }),
    'not json',
    '{"type":"text","part":{"text":"step_finish mentioned in text but not an event"}}',
    (Step @{ input = 50000; output = 75000; reasoning = 9999 }),
    '{"type":"error","error":{"name":"APIError","data":{"message":"Cannot connect to API"}}}'
) -join "`n"
# A graded run's transcript: 1M input tokens (alpha $2.00, beta $1.00).
$gradedTranscript = (Step @{ input = 1000000; output = 0; reasoning = 0; read = 0; write = 0 })
# A run the provider refused partway: one billed step, then OpenCode Go's 402,
# in the shape of the real 2026-10-06 transcripts (headers trimmed).
function ErrorEvent([string]$Status, [string]$Message) {
    return '{"type":"error","timestamp":1791338950835,"sessionID":"ses_fixture","error":{"name":"APIError","data":{"message":"' + $Message + '","statusCode":' + $Status + ',"isRetryable":false,"responseBody":"{\"error\":{\"type\":\"server_error\",\"message\":\"' + $Message + '\"}}","metadata":{"url":"https://opencode.ai/inference/go/openai/v1/chat/completions"}}}}'
}
$refusedTranscript = @(
    (Step @{ input = 100000; output = 0; reasoning = 0; read = 0; write = 0 }),
    (ErrorEvent "402" "Upstream request failed: Insufficient account funds")
) -join "`n"

try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    Write-Host "-- offer gate (Get-HostedSeatGate)"
    $listed = @{ "opencode-go/alpha" = $true }
    $ok = [pscustomobject]@{ Listed = $listed; KeyExists = $true; KeyFile = "k"; ConfigOk = $true }
    Check "listed + key + config: offered"            ($null -eq (Get-HostedSeatGate -ModelId "opencode-go/alpha" -State $ok)) "True"
    Has   "not listed: refused, says so"              (Get-HostedSeatGate -ModelId "opencode-go/beta" -State $ok) 'not listed by `opencode models opencode-go`'
    Has   "no key file: refused, names the path"      (Get-HostedSeatGate -ModelId "opencode-go/alpha" -State ([pscustomobject]@{ Listed = $listed; KeyExists = $false; KeyFile = "C:\nokey"; ConfigOk = $true })) 'no OpenCode Go API key file at C:\\nokey'
    Has   "opencode models failed: refused"           (Get-HostedSeatGate -ModelId "opencode-go/alpha" -State ([pscustomobject]@{ Listed = $null; KeyExists = $true; KeyFile = "k"; ConfigOk = $true })) 'failed'
    Has   "config does not resolve: refused"          (Get-HostedSeatGate -ModelId "opencode-go/alpha" -State ([pscustomobject]@{ Listed = $listed; KeyExists = $true; KeyFile = "k"; ConfigOk = $false })) 'does not resolve'
    Check "Test-HostedModelId: opencode-go/x"         (Test-HostedModelId "opencode-go/qwen3.8-max") "True"
    Check "Test-HostedModelId: a local seat is not"   (Test-HostedModelId "ollama-desktop/qwen3:8b") "False"

    Write-Host "-- offered seats (the real Get-AvailableModelSeats; local rows unchanged)"
    $registryPath = Join-Path $tmp "registry.tsv"
    Write-Fixture $registryPath $registryFixture
    $ollamaHosts = @(
        [pscustomobject]@{ Label = "desktop"; Root = "http://d"; Up = $true; Version = "0.34.3"; Tags = @("qwen3:8b", "qwen3:14b") },
        [pscustomobject]@{ Label = "node3"; Root = "http://n"; Up = $false; Version = $null; Tags = @() }
    )
    $localExpected = "ollama-desktop/qwen3:14b ollama-desktop/qwen3:8b"
    $hostedState = [pscustomobject]@{ Listed = @{ "opencode-go/alpha" = $true; "opencode-go/beta" = $true; "opencode-go/delta" = $true }; KeyExists = $true; KeyFile = "k"; ConfigOk = $true }
    $seats = @(Get-AvailableModelSeats 6>$null)
    Check "listed + key: alpha, beta, delta offered; gamma (unlisted) not" (@($seats | Where-Object { Test-HostedModelId $_ }) -join " ") "opencode-go/alpha opencode-go/beta opencode-go/delta"
    Check "...local seats as before (down node3 skipped)" (@($seats | Where-Object { -not (Test-HostedModelId $_) }) -join " ") $localExpected
    $hostedState = [pscustomobject]@{ Listed = $hostedState.Listed; KeyExists = $false; KeyFile = "k"; ConfigOk = $true }
    $seats = @(Get-AvailableModelSeats 6>$null)
    Check "no key file: no hosted seat offered"       (@($seats | Where-Object { Test-HostedModelId $_ }).Count) 0
    Check "...local seats unchanged"                  (@($seats | Where-Object { -not (Test-HostedModelId $_) }) -join " ") $localExpected
    $hostedState = $null
    $seats = @(Get-AvailableModelSeats 6>$null)
    Check "hosted not checked at all: local seats unchanged" ($seats -join " ") $localExpected

    Write-Host "-- spend cap (Get-SpendCap, Get-CapStatus)"
    $ratesPath = Join-Path $tmp "go-rates.tsv"
    Write-Fixture $ratesPath $ratesFixture
    $rates = Get-GoRates -Path $ratesPath
    $cap = Get-SpendCap -ModelId "opencode-go/alpha" -Rates $rates -Share 0.2
    Check "cap = share x monthly (0.2 x 10)"          $cap.Usd 2
    Check "...formatted"                              (Format-SpendCap $cap) '$2.00 cap (20% of $10.00 monthly)'
    Check "share 0.5 x 100"                           (Get-SpendCap -ModelId "opencode-go/beta" -Rates $rates -Share 0.5).Usd 50
    Has   "no rate row: refused, says why"            (Get-SpendCap -ModelId "opencode-go/delta" -Rates $rates -Share 0.2).Refusal 'no row in costs/go-rates.tsv'
    Has   "no monthly allowance: refused"             (Get-SpendCap -ModelId "opencode-go/nolimit" -Rates $rates -Share 0.2).Refusal 'monthlyLimitUsd'
    Has   "no output rate: refused (would read as `$0)" (Get-SpendCap -ModelId "opencode-go/nooutput" -Rates $rates -Share 0.2).Refusal 'outputPerM'
    Check "no rates file: every model refused"        ([bool](Get-SpendCap -ModelId "opencode-go/alpha" -Rates (Get-GoRates -Path (Join-Path $tmp "none.tsv")) -Share 0.2).Refusal) "True"
    $caps = @{ "opencode-go/alpha" = $cap }
    Check "below the cap: runs"                       ($null -eq (Get-CapStatus -ModelId "opencode-go/alpha" -Caps $caps -Spend @{ "opencode-go/alpha" = 1.99 })) "True"
    Check "nothing spent yet: runs"                   ($null -eq (Get-CapStatus -ModelId "opencode-go/alpha" -Caps $caps -Spend @{})) "True"
    Check "at the cap: stopped, says how much"        (Get-CapStatus -ModelId "opencode-go/alpha" -Caps $caps -Spend @{ "opencode-go/alpha" = 2.0 }) 'spent about $2.0000 of its $2.00 cap (20% of $10.00 monthly)'
    Check "uncapped model (-NoSpendCap): never stopped" ($null -eq (Get-CapStatus -ModelId "opencode-go/beta" -Caps $caps -Spend @{ "opencode-go/beta" = 999 })) "True"
    Check "a local seat: never stopped"               ($null -eq (Get-CapStatus -ModelId "ollama-desktop/qwen3:8b" -Caps $caps -Spend @{ "ollama-desktop/qwen3:8b" = 999 })) "True"

    Write-Host "-- transcript tokens and cost (Get-TranscriptTokenUsage, Get-UsageCostUsd)"
    $tf = Join-Path $tmp "infra.jsonl"
    Write-Fixture $tf $infraTranscript
    $u = Get-TranscriptTokenUsage -Path $tf
    Check "sums every step_finish, skips the rest"    ("{0}/{1}/{2}/{3}/{4}/{5}" -f $u.input, $u.output, $u.reasoning, $u.cacheRead, $u.cacheWrite, $u.steps) "250000/125000/9999/400000/1000/2"
    Check "alpha: 0.50 + 0.50 + 0.20 (reasoning and blank cache-write rate add 0)" (Get-UsageCostUsd -Usage $u -Rate $rates["opencode-go/alpha"]) 1.2
    Check "missing transcript: zero usage"            (Get-TranscriptTokenUsage -Path (Join-Path $tmp "none.jsonl")).steps 0
    if ($tt.Count -eq 2) {
        $theirs = Get-TranscriptUsage -Path $tf
        Check "agrees with test-tasks.ps1 Get-TranscriptUsage" ("{0}/{1}/{2}/{3}/{4}" -f $theirs.input, $theirs.output, $theirs.cacheRead, $theirs.cacheWrite, $theirs.steps) ("{0}/{1}/{2}/{3}/{4}" -f $u.input, $u.output, $u.cacheRead, $u.cacheWrite, $u.steps)
        $realRates = Join-Path $repoRoot "costs\go-rates.tsv"
        foreach ($row in (Import-Csv -LiteralPath $realRates -Delimiter "`t")) {
            $est = Get-RunCostEstimate -ModelId $row.model -Usage $theirs -RatesPath $realRates
            Check "agrees with test-tasks.ps1 Get-RunCostEstimate: $($row.model)" (Get-UsageCostUsd -Usage $u -Rate $row) $est.usd
        }
    } else {
        Write-Host "SKIP agreement with test-tasks.ps1 (Get-TranscriptUsage / Get-RunCostEstimate not found there)"
    }

    Write-Host "-- per-run spend (Measure-RunSpend)"
    $rd = Join-Path $tmp "results-unit"
    New-Item -ItemType Directory -Path $rd -Force | Out-Null
    $lab = "opencode-go_alpha"
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_20261006-090000.json") '{"costEstimate":{"usd":9.0}}'   # an earlier run
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_20261006-090000.jsonl") $gradedTranscript
    $before = Get-ResultFileNames -Dir $rd
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_20261006-100000.json") '{"costEstimate":{"usd":0.75,"rateModel":"opencode-go/alpha"}}'
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_20261006-100000.jsonl") $gradedTranscript
    Write-Fixture (Join-Path $rd "tasks-t2-${lab}_20261006-100000.json") '{"costEstimate":{"usd":5.0}}'   # another task
    Write-Fixture (Join-Path $rd "tasks-t1-opencode-go_beta_20261006-100000.json") '{"costEstimate":{"usd":5.0}}'   # another model
    $s = Measure-RunSpend -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha" -Rate $rates["opencode-go/alpha"]
    Check "graded run: the JSON's costEstimate, not the transcript too" $s.Usd 0.75
    Check "...and only this run's, task's and model's files" ($s.Sources -join ";") "run JSON costEstimate"
    $before = Get-ResultFileNames -Dir $rd
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_INFRA_20261006-110000.jsonl") $infraTranscript
    $s = Measure-RunSpend -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha" -Rate $rates["opencode-go/alpha"]
    Check "infrastructure run, no JSON: its transcript's tokens count" $s.Usd 1.2
    Check "...labelled as such"                       ($s.Sources -join ";") "INFRA transcript tokens"
    $before = Get-ResultFileNames -Dir $rd
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_TIMEOUT_20261006-120000.jsonl") $infraTranscript
    Check "timeout run counts too"                    (Measure-RunSpend -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha" -Rate $rates["opencode-go/alpha"]).Usd 1.2
    $before = Get-ResultFileNames -Dir $rd
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_20261006-130000.json") '{"costEstimate":null}'
    Write-Fixture (Join-Path $rd "tasks-t1-${lab}_20261006-130000.jsonl") $gradedTranscript
    $s = Measure-RunSpend -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha" -Rate $rates["opencode-go/alpha"]
    Check "graded JSON with no estimate: falls back to its transcript" ("{0} / {1}" -f $s.Usd, ($s.Sources -join ";")) "2 / transcript tokens (its run JSON has no costEstimate)"
    $before = Get-ResultFileNames -Dir $rd
    $s = Measure-RunSpend -ResultsDir $rd -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha" -Rate $rates["opencode-go/alpha"]
    Check "no new files (e.g. a baseline failure): nothing counted" ("{0} / {1}" -f $s.Usd, ($s.Sources -join ";")) "0 / no result files - nothing counted"

    Write-Host "-- provider refusal (Get-ProviderRefusal)"
    $rr = Join-Path $tmp "results-refusal"
    New-Item -ItemType Directory -Path $rr -Force | Out-Null
    Write-Fixture (Join-Path $rr "tasks-t1-${lab}_INFRA_20261006-090000.jsonl") $refusedTranscript   # an earlier run
    $before = Get-ResultFileNames -Dir $rr
    Check "nothing new: no refusal"                   ($null -eq (Get-ProviderRefusal -ResultsDir $rr -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha")) "True"
    Write-Fixture (Join-Path $rr "tasks-t1-opencode-go_beta_INFRA_20261006-100000.jsonl") $refusedTranscript   # another model
    Write-Fixture (Join-Path $rr "tasks-t2-${lab}_INFRA_20261006-100000.jsonl") $refusedTranscript            # another task
    Check "another model's or task's 402: not this run's" ($null -eq (Get-ProviderRefusal -ResultsDir $rr -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha")) "True"
    Write-Fixture (Join-Path $rr "tasks-t1-${lab}_INFRA_20261006-110000.jsonl") $infraTranscript
    Check "an unreachable host is not a refusal"      ($null -eq (Get-ProviderRefusal -ResultsDir $rr -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha")) "True"
    $before = Get-ResultFileNames -Dir $rr
    Write-Fixture (Join-Path $rr "tasks-t1-${lab}_INFRA_20261006-120000.jsonl") (@((Step @{ input = 1; output = 1; reasoning = 0 }), (ErrorEvent "429" "Rate limited"), (ErrorEvent "500" "Insufficient 402 words in a 500")) -join "`n")
    Check "a 429 or a 500 is not a refusal"           ($null -eq (Get-ProviderRefusal -ResultsDir $rr -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha")) "True"
    $before = Get-ResultFileNames -Dir $rr
    Write-Fixture (Join-Path $rr "tasks-t1-${lab}_INFRA_20261006-130000.jsonl") $refusedTranscript
    Check "a 402 partway through a run: the provider's message" (Get-ProviderRefusal -ResultsDir $rr -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha") "Upstream request failed: Insufficient account funds"
    Check "...and the step before it still counts as spend" (Measure-RunSpend -ResultsDir $rr -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha" -Rate $rates["opencode-go/alpha"]).Usd 0.2
    $before = Get-ResultFileNames -Dir $rr
    Write-Fixture (Join-Path $rr "tasks-t1-${lab}_INFRA_20261006-140000.jsonl") ('{"type":"error","error":{"name":"APIError","data":{"statusCode":402}}}')
    Check "a 402 with no message still stops"        (Get-ProviderRefusal -ResultsDir $rr -Before $before -TaskId "t1" -ModelLabel "opencode-go/alpha") "HTTP 402"

    Write-Host "-- the real registry and rate table"
    $realReg = Get-Content -LiteralPath (Join-Path $PSScriptRoot "run-tasks-models.tsv")
    $realRateRows = Get-GoRates -Path (Join-Path $repoRoot "costs\go-rates.tsv")
    foreach ($tag in "qwen3.7-plus", "qwen3.8-max", "kimi-k2.7-code", "glm-5.2", "deepseek-v4-pro") {
        Check "registry: $tag is an opencode-go row" (@($realReg | Where-Object { $_ -match ("^" + [regex]::Escape($tag) + "`topencode-go`t") }).Count) 1
        $c = Get-SpendCap -ModelId "opencode-go/$tag" -Rates $realRateRows -Share 0.2
        Check "costs/go-rates.tsv: opencode-go/$tag has a rate row and a cap" ($null -eq $c.Refusal -and $c.Usd -gt 0) "True"
    }

    # --- end to end ---------------------------------------------------------
    Write-Host "-- end to end: the real run-tasks-batch.ps1, stand-in opencode, test-tasks.ps1 and Ollama"
    $tree = Join-Path $tmp "tree"
    $bin  = Join-Path $tmp "bin"
    $fx   = Join-Path $tmp "fixture"
    foreach ($d in "$tree\tests\tasks", "$tree\tests\results", "$tree\costs", $bin, $fx) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $ScriptPath -Destination "$tree\tests\run-tasks-batch.ps1"
    Write-Fixture "$tree\tests\run-tasks-models.tsv" (($registryFixture -split "`n" | Where-Object { $_ -notmatch '^qwen3:14b' }) -join "`n")
    Write-Fixture "$tree\costs\go-rates.tsv" $ratesFixture
    Write-Fixture "$tree\tests\results\toolcalls-summary.tsv" "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail`n2026-10-06T09:00:00`tdesktop`t0.34.3`tqwen3:8b`tPASS`t10`tfixture`n"
    $manifest = @{ tasks = @(foreach ($id in "fx-infra", "t1", "t2", "t3", "t4") { [ordered]@{ id = $id; title = "fixture $id" } }) }
    Write-Fixture "$tree\tests\tasks\manifest.json" ($manifest | ConvertTo-Json -Depth 5)

    # Stand-in test-tasks.ps1: names files exactly as the real one does.
    # fx-infra -> an _INFRA_ transcript, no JSON, exit 1. Otherwise a graded JSON
    # (costEstimate.usd 1.00 for a hosted model; null for t3 and for local
    # seats) and its transcript, exit 0.
    Write-Fixture "$tree\tests\test-tasks.ps1" @'
param([string[]]$Task, [string]$Model, [string]$ModelLabel, [int]$RunTimeout, [int]$CommandTimeout,
      [switch]$IncludeRetired, [string]$TaskManifest, [string]$ResultsDir)
$t = $Task[0]
Add-Content -LiteralPath $env:FIXTURE_CALLS -Value "$t|$Model"
$label = $ModelLabel -replace '[^a-zA-Z0-9._-]', '_'
$n = @(Get-ChildItem -LiteralPath $ResultsDir -File).Count
$stamp = "20261006-{0:D6}" -f $n
$enc = New-Object System.Text.UTF8Encoding $false
if ($t -eq 'fx-infra') {
    [IO.File]::WriteAllText((Join-Path $ResultsDir ("tasks-{0}-{1}_INFRA_{2}.jsonl" -f $t, $label, $stamp)), $env:FIXTURE_INFRA_TRANSCRIPT, $enc)
    Write-Host "  [FAIL] opencode run - fixture infrastructure failure"
    exit 1
}
if ($env:FIXTURE_REFUSE_MODEL -and $Model -eq $env:FIXTURE_REFUSE_MODEL -and $t -ne 't1') {
    [IO.File]::WriteAllText((Join-Path $ResultsDir ("tasks-{0}-{1}_INFRA_{2}.jsonl" -f $t, $label, $stamp)), $env:FIXTURE_REFUSED_TRANSCRIPT, $enc)
    Write-Host "  [FAIL] opencode run - fixture provider refusal"
    exit 1
}
$usd = if ($t -eq 't3' -or $Model -notmatch '^opencode-go/') { $null } else { 1.0 }
$base = Join-Path $ResultsDir ("tasks-{0}-{1}_{2}" -f $t, $label, $stamp)
[IO.File]::WriteAllText("$base.jsonl", $env:FIXTURE_GRADED_TRANSCRIPT, $enc)
$json = [pscustomobject]@{ taskId = $t; model = $Model; costEstimate = $(if ($null -ne $usd) { [pscustomobject]@{ usd = $usd } } else { $null }) }
[IO.File]::WriteAllText("$base.json", ($json | ConvertTo-Json -Depth 4), $enc)
exit 0
'@
    # Stand-in opencode: --version, `models opencode-go` (from a file; fails when
    # the file is absent), `debug config` (likewise). Every call is logged, and
    # anything else - `run` above all - fails.
    Write-Fixture "$bin\opencode.cmd" ((@'
@echo off
echo %*>>"%FIXTURE_DIR%\opencode-calls.txt"
if "%~1"=="--version" goto version
if "%~1"=="models" goto models
if "%~1"=="debug" goto debug
exit /b 2
:version
echo 9.9.9
exit /b 0
:models
if not exist "%FIXTURE_DIR%\go-models.txt" exit /b 1
type "%FIXTURE_DIR%\go-models.txt"
exit /b 0
:debug
if not exist "%FIXTURE_DIR%\config.json" exit /b 1
type "%FIXTURE_DIR%\config.json"
exit /b 0
'@) -replace "`r?`n", "`r`n")
    # Driver: a stand-in Invoke-RestMethod for the local seat's Ollama (the
    # function shadows the cmdlet inside the script), then the real batch.
    Write-Fixture "$tmp\driver.ps1" @'
param([string]$Script, [string]$ArgsFile)
function Invoke-RestMethod {
    param($Uri, $TimeoutSec)
    if ("$Uri" -match '/api/tags$') { return [pscustomobject]@{ models = @([pscustomobject]@{ name = "qwen3:8b" }) } }
    if ("$Uri" -match '/api/version$') { return [pscustomobject]@{ version = "0.34.3" } }
    throw "fixture: no endpoint $Uri"
}
$a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json
$splat = @{}
foreach ($p in $a.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [array]) { $splat[$p.Name] = [string[]]$v } else { $splat[$p.Name] = $v }
}
& $Script @splat
exit $LASTEXITCODE
'@
    $keyFile = Join-Path $fx "opencode-go-api-key"
    Write-Fixture $keyFile "not a real key"
    $configJson = '{"autoupdate":"notify","provider":{"ollama-desktop":{"models":{"qwen3:8b":{}}}}}'
    $psExe = (Get-Process -Id $PID).Path

    $saved = @{}
    foreach ($v in "PATH", "FIXTURE_DIR", "FIXTURE_CALLS", "FIXTURE_INFRA_TRANSCRIPT", "FIXTURE_GRADED_TRANSCRIPT",
                   "FIXTURE_REFUSED_TRANSCRIPT", "FIXTURE_REFUSE_MODEL", "OLLAMA_DESKTOP_BASE_URL",
                   "OLLAMA_NODE3_BASE_URL", "OLLAMA_SERVER_BASE_URL", "OPENCODE_SMALL_MODEL", "MANAPOOL_API_KEY") {
        $saved[$v] = [Environment]::GetEnvironmentVariable($v)
    }
    $script:scn = 0
    function Invoke-Batch([hashtable]$BatchArgs, [string[]]$GoList = @("alpha", "beta", "delta"), [switch]$NoGoList, [switch]$NoConfig, [string]$RefuseModel = "") {
        $script:scn++
        $rdir = Join-Path $tmp "results-$($script:scn)"
        New-Item -ItemType Directory -Path $rdir -Force | Out-Null
        Remove-Item -LiteralPath (Join-Path $fx "go-models.txt"), (Join-Path $fx "config.json"), (Join-Path $fx "opencode-calls.txt") -ErrorAction SilentlyContinue
        if (-not $NoGoList) { Write-Fixture (Join-Path $fx "go-models.txt") ((@("opencode-go/zzz-other") + @($GoList | ForEach-Object { "opencode-go/$_" })) -join "`r`n") }
        if (-not $NoConfig) { Write-Fixture (Join-Path $fx "config.json") $configJson }
        $calls = Join-Path $tmp "calls-$($script:scn).txt"
        Write-Fixture $calls ""
        $all = @{ SkipSetup = $true; Mode = "Tasks"; Reps = 1; Yes = $true; ResultsDir = $rdir; GoKeyFile = $keyFile }
        foreach ($k in $BatchArgs.Keys) { $all[$k] = $BatchArgs[$k] }
        $argsFile = Join-Path $tmp "args-$($script:scn).json"
        Write-Fixture $argsFile ($all | ConvertTo-Json -Depth 4)
        $env:PATH = "$bin;$($saved.PATH)"
        $env:FIXTURE_DIR = $fx
        $env:FIXTURE_CALLS = $calls
        $env:FIXTURE_INFRA_TRANSCRIPT = $infraTranscript
        $env:FIXTURE_GRADED_TRANSCRIPT = $gradedTranscript
        $env:FIXTURE_REFUSED_TRANSCRIPT = $refusedTranscript
        $env:FIXTURE_REFUSE_MODEL = $RefuseModel
        $env:OLLAMA_DESKTOP_BASE_URL = "http://fixture.invalid:11434/v1"
        foreach ($v in "OLLAMA_NODE3_BASE_URL", "OLLAMA_SERVER_BASE_URL", "OPENCODE_SMALL_MODEL", "MANAPOOL_API_KEY") { [Environment]::SetEnvironmentVariable($v, $null) }
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp "driver.ps1") -Script "$tree\tests\run-tasks-batch.ps1" -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            foreach ($v in $saved.Keys) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) }
        }
        $ran = @(Get-Content -LiteralPath $calls | Where-Object { $_ })
        $oc = if (Test-Path -LiteralPath (Join-Path $fx "opencode-calls.txt")) { @(Get-Content -LiteralPath (Join-Path $fx "opencode-calls.txt")) } else { @() }
        return [pscustomobject]@{ Out = $out; Exit = $code; Calls = $ran; OpencodeCalls = $oc }
    }
    function RunsOf($r, [string]$model) { (@($r.Calls | Where-Object { $_.EndsWith("|$model") } | ForEach-Object { ($_ -split '\|')[0] })) -join "," }

    Write-Host "   scenario: a local seat and every hosted seat; alpha's cap is `$2.00"
    $r = Invoke-Batch @{ Tasks = @("fx-infra", "t1", "t2", "t3"); Models = @("ollama-desktop/qwen3:8b", "hosted") }
    Check "exit 0"                                    $r.Exit 0
    Has   "gamma (not listed by opencode) is not offered" $r.Out '\[skip\] opencode-go/gamma - not listed by `opencode models opencode-go`'
    Has   "delta (no rate row) is refused, and why"   $r.Out '\[drop\] opencode-go/delta - no row in costs/go-rates\.tsv.*-NoSpendCap'
    Check "...and never runs"                         (RunsOf $r "opencode-go/delta") ""
    Has   "hosted seats are marked smoke-tested, not probed" $r.Out 'opencode-go/alpha is hosted - smoke-tested .* not probed: test-toolcalls\.ps1 is Ollama-only'
    Has   "preflight: alpha's cap in dollars"         $r.Out '\[CAP\]  opencode-go/alpha  \$2\.00 cap \(20% of \$10\.00 monthly\)'
    Has   "preflight: beta's cap in dollars"          $r.Out '\[CAP\]  opencode-go/beta  \$20\.00 cap \(20% of \$100\.00 monthly\)'
    Check "alpha: the _INFRA_ run (`$1.20) counts, so it stops after t1 (`$2.20)" (RunsOf $r "opencode-go/alpha") "fx-infra,t1"
    Has   "...the stop names the spend and the cap"   $r.Out '\[CAP\] opencode-go/alpha: spent about \$2\.2000 of its \$2\.00 cap \(20% of \$10\.00 monthly\) - skipping its remaining 2 run\(s\)'
    Check "beta carries on: every run"                (RunsOf $r "opencode-go/beta") "fx-infra,t1,t2,t3"
    Has   "summary: alpha's spend against its cap"    $r.Out 'opencode-go/alpha\s+\$2\.2000 of its \$2\.00 cap .* 2 run\(s\); 2 skipped at the cap'
    Has   "summary: beta 0.415 + 1 + 1 + 1 (t3's JSON has no estimate: its transcript)" $r.Out 'opencode-go/beta\s+\$3\.4150 of its \$20\.00 cap .* 4 run\(s\)'
    Has   "the capped runs are reported as not started" $r.Out '2 run\(s\) not started: their hosted model reached its spend cap'
    Check "local seat: every run, as before"          (RunsOf $r "ollama-desktop/qwen3:8b") "fx-infra,t1,t2,t3"
    Lacks "local seat: no spend line"                 $r.Out 'so far.*ollama-desktop|ollama-desktop/qwen3:8b so far'
    Lacks "local seat: no cap line"                   $r.Out '\[CAP\]\s+ollama-desktop'
    Lacks "local seat: not in the hosted summary"     ($r.Out -replace '(?s)^.*=== Hosted spend', '') 'ollama-desktop'
    Check "opencode was never asked to run a model"   (@($r.OpencodeCalls | Where-Object { $_ -match '^\s*run' }).Count) 0

    Write-Host "   scenario: -SpendCapShare 0.5 (alpha's cap `$5.00)"
    $r = Invoke-Batch @{ Tasks = @("fx-infra", "t1", "t2", "t3"); Models = @("opencode-go/alpha"); SpendCapShare = 0.5 }
    Has   "preflight shows the larger cap"            $r.Out '\[CAP\]  opencode-go/alpha  \$5\.00 cap \(50% of \$10\.00 monthly\)'
    Check "alpha runs everything (`$3.20 before t3)"  (RunsOf $r "opencode-go/alpha") "fx-infra,t1,t2,t3"
    Has   "summary: `$5.20, one run's overshoot is possible" $r.Out 'opencode-go/alpha\s+\$5\.2000 of its \$5\.00 cap'

    Write-Host "   scenario: the provider refuses beta (HTTP 402) from t2 on"
    $r = Invoke-Batch @{ Tasks = @("t1", "t2", "t3", "t4"); Models = @("ollama-desktop/qwen3:8b", "opencode-go/alpha", "opencode-go/beta"); SpendCapShare = 1 } -RefuseModel "opencode-go/beta"
    Check "exit 0"                                    $r.Exit 0
    Check "beta: t1, then the refused t2, then nothing" (RunsOf $r "opencode-go/beta") "t1,t2"
    Has   "...the stop names the provider's message"  $r.Out '\[REFUSED\] opencode-go/beta: the provider refused the request \(HTTP 402: Upstream request failed: Insufficient account funds\) - skipping its remaining 2 run\(s\)'
    Check "alpha carries on: every run"               (RunsOf $r "opencode-go/alpha") "t1,t2,t3,t4"
    Check "local seat: every run"                     (RunsOf $r "ollama-desktop/qwen3:8b") "t1,t2,t3,t4"
    Has   "summary: beta's refused run still counts as spend (1 + 0.1)" $r.Out 'opencode-go/beta\s+\$1\.1000 of its .* 2 run\(s\); refused by the provider, 2 skipped after'
    Lacks "summary: alpha was not refused"            $r.Out 'opencode-go/alpha\s+[^\r\n]*refused'
    Has   "the skipped runs are reported, with how to fill them" $r.Out '1 hosted model\(s\) refused by the provider \(HTTP 402\); 2 run\(s\) not started\. Re-run them later with -OnlyMissing'
    $r = Invoke-Batch @{ Tasks = @("fx-infra", "t1", "t2"); Models = @("opencode-go/beta"); SpendCapShare = 1 }
    Lacks "an unreachable-host _INFRA_ run does not stop a model" $r.Out '\[REFUSED\]'
    Check "...it runs everything"                     (RunsOf $r "opencode-go/beta") "fx-infra,t1,t2"

    Write-Host "   scenario: no key file"
    $r = Invoke-Batch @{ Tasks = @("t1"); Models = @("ollama-desktop/qwen3:8b", "hosted", "opencode-go/beta"); GoKeyFile = (Join-Path $fx "missing-key") }
    Has   "listed seats are not offered without the key" $r.Out '\[skip\] opencode-go/alpha - no OpenCode Go API key file'
    Has   "a named hosted seat is dropped without the key" $r.Out '\[drop\] opencode-go/beta - no OpenCode Go API key file'
    Check "only the local seat runs"                  ($r.Calls -join ";") "t1|ollama-desktop/qwen3:8b"

    Write-Host "   scenario: 'all' is local only"
    $r = Invoke-Batch @{ Tasks = @("t1"); Models = @("all") }
    Check "-Models all never picks a paid seat"       ($r.Calls -join ";") "t1|ollama-desktop/qwen3:8b"
    Lacks "...and prints no hosted preflight"         $r.Out '\[CAP\]'

    Write-Host "   scenario: opencode models fails"
    $r = Invoke-Batch @{ Tasks = @("t1"); Models = @("opencode-go/alpha") } -NoGoList
    Has   "the seat is dropped, and why"              $r.Out '\[drop\] opencode-go/alpha - `opencode models opencode-go` failed'
    Check "nothing runs"                              $r.Calls.Count 0
    Has   "...nothing selected"                       $r.Out 'No models selected'

    Write-Host "   scenario: the live config does not resolve"
    $r = Invoke-Batch @{ Tasks = @("t1"); Models = @("opencode-go/alpha") } -NoConfig
    Has   "the seat is dropped, and why"              $r.Out '\[drop\] opencode-go/alpha - the live `opencode debug config` does not resolve'
    Check "nothing runs"                              $r.Calls.Count 0

    Write-Host "   scenario: not listed by opencode"
    $r = Invoke-Batch @{ Tasks = @("t1"); Models = @("opencode-go/alpha") } -GoList @("beta")
    Has   "a named seat opencode does not list is dropped" $r.Out '\[drop\] opencode-go/alpha - not listed'
    Check "nothing runs"                              $r.Calls.Count 0

    Write-Host "   scenario: -NoSpendCap"
    $r = Invoke-Batch @{ Tasks = @("t1", "t2", "t3"); Models = @("opencode-go/delta", "opencode-go/alpha"); NoSpendCap = $true }
    Check "delta (no rate row) runs"                  (RunsOf $r "opencode-go/delta") "t1,t2,t3"
    Check "alpha runs past `$2.00 (no cap)"           (RunsOf $r "opencode-go/alpha") "t1,t2,t3"
    Has   "preflight warns: no cap"                   $r.Out '\[WARN\] opencode-go/alpha  -NoSpendCap: NO cap'
    Has   "preflight warns: delta's spend cannot be estimated" $r.Out '\[WARN\] opencode-go/delta  -NoSpendCap and no rate row'
    Has   "summary: alpha's spend still estimated"    $r.Out 'opencode-go/alpha\s+\$4\.0000 no cap \(-NoSpendCap\)'
    Has   "summary: delta not estimated"              $r.Out 'opencode-go/delta\s+not estimated \(no rate row\)'

    Write-Host "   scenario: Both mode leaves hosted seats out"
    $r = Invoke-Batch @{ Mode = "Both"; Tasks = @("t1"); Models = @("none") }
    Has   "says hosted seats are left out"            $r.Out 'hosted seat\(s\) left out: Both mode runs probed seats only'
    Check "only the probed local seat runs"           ($r.Calls -join ";") "t1|ollama-desktop/qwen3:8b"

    Write-Host "   scenario: a bad -SpendCapShare"
    $r = Invoke-Batch @{ Tasks = @("t1"); Models = @("opencode-go/alpha"); SpendCapShare = 0 }
    Check "exit 1"                                    $r.Exit 1
    Has   "...saying what the share is"               $r.Out '-SpendCapShare must be > 0 and <= 1'
    Check "nothing runs"                              $r.Calls.Count 0
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 }
Write-Host "RESULT: all checks passed"

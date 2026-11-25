# protects: bench-speed.ps1 speeds, prompt sizing and TSV logging on llama.cpp
# run-after: Either bench-speed script
# test-bench-speed.ps1 - regression guard for tests/bench-speed.ps1.
#
# Why this exists: bench-speed.ps1 is how two hosts are compared on tokens per
# second instead of wall-clock per task. A wrong divisor, a prompt the prefix
# cache can recognise, or a request sent at or over the served context would give
# a number that looks like a measurement and isn't. llama.cpp is the only local
# engine since Ollama was removed (2026-11-21).
#
# What it does:
#   1. Pulls the REAL New-BenchPrompt, Get-BenchMetricsLlama and Add-BenchRow out
#      of bench-speed.ps1: llama-server's `timings` read as milliseconds of what
#      was evaluated (a cache hit excluded, null for a zero duration or too few
#      tokens), a prompt that reaches its target, begins with its nonce and
#      differs between nonces, a TSV with one header however many appends.
#   2. Runs the REAL bench-speed.ps1 as a child process against a stand-in
#      llama-server (a driver defines Invoke-RestMethod, so no server is needed):
#      the warm-up row and one row per size and rep; /props for the build and the
#      served context (router-mode query first, bare path as the fallback); a size
#      over 92% of num_ctx skipped and logged; every prompt under its own nonce
#      with cache_prompt off; the chars-per-token estimate corrected after the
#      first request; speeds in the row and placement left blank; a failing
#      request logged and exit 1; -NoLog; an unknown num_ctx (nothing skipped);
#      llamacpp as the default engine; -Engine ollama and the removed -OllamaHost
#      refused; and that no Ollama endpoint (/api/*) is ever touched.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-bench-speed.ps1 [-ScriptPath <a bench-speed.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "bench-speed.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
foreach ($name in "New-BenchPrompt", "Get-BenchMetricsLlama", "Add-BenchRow") {
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)) | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 1 }
    Invoke-Expression $fn.Extent.Text
}
$cols = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:Columns' }, $true)) | Select-Object -First 1
if (-not $cols) { Write-Host 'FAIL: $script:Columns not found'; exit 1 }
Invoke-Expression $cols.Extent.Text

$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")   # Check <name> <actual> <expected>: a PASS/FAIL line, failures counted in $script:fail
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("bench-speed-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding($false)
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    Write-Host "-- Get-BenchMetricsLlama (real function, canned llama-server timings in milliseconds)"
    $r = [pscustomobject]@{ usage = [pscustomobject]@{ prompt_tokens = 3000 }
                            timings = [pscustomobject]@{ cache_n = 0; prompt_n = 3000; prompt_ms = 4640; predicted_n = 128; predicted_ms = 1920 } }
    $m = Get-BenchMetricsLlama $r 8.0
    Check "prefill = 3000 tokens / 4.64 s"                   $m.PrefillTokS 646.6
    Check "decode = 128 tokens / 1.92 s"                     $m.DecodeTokS 66.7
    Check "load = 8.0 s wall - (4.64 + 1.92) s of its own"   $m.LoadS 1.4
    Check "a wall time shorter than its own time is load 0, not negative" (Get-BenchMetricsLlama $r 1.0).LoadS 0
    Check "counts are carried"                               ("{0} {1} {2}" -f $m.PromptTokens, $m.EvalTokens, $m.CacheN) "3000 128 0"
    $r = [pscustomobject]@{ usage = [pscustomobject]@{ prompt_tokens = 3000 }
                            timings = [pscustomobject]@{ cache_n = 2000; prompt_n = 1000; prompt_ms = 1000; predicted_n = 128; predicted_ms = 1920 } }
    $m = Get-BenchMetricsLlama $r 0
    Check "a cache hit is not prefill: 1000 evaluated tokens / 1 s, not 3000" $m.PrefillTokS 1000
    Check "...but the prompt is still 3000 tokens long, and the hit is reported" ("{0} {1}" -f $m.PromptTokens, $m.CacheN) "3000 2000"
    $r = [pscustomobject]@{ timings = [pscustomobject]@{ cache_n = 500; prompt_n = 1500; prompt_ms = 1000; predicted_n = 10; predicted_ms = 100 } }
    Check "without a usage block the prompt length is prompt_n + cache_n" (Get-BenchMetricsLlama $r 0).PromptTokens 2000
    $r = [pscustomobject]@{ timings = [pscustomobject]@{ cache_n = 0; prompt_n = 14; prompt_ms = 98; predicted_n = 1; predicted_ms = 1 } }
    $m = Get-BenchMetricsLlama $r 0
    Check "a 14-token prompt and a one-token generation are not speeds (the first real run logged 1,000,000 tok/s)" ("{0}|{1}" -f ($null -eq $m.PrefillTokS), ($null -eq $m.DecodeTokS)) "True|True"
    $r = [pscustomobject]@{ timings = [pscustomobject]@{ cache_n = 0; prompt_n = 64; prompt_ms = 100; predicted_n = 8; predicted_ms = 100 } }
    $m = Get-BenchMetricsLlama $r 0
    Check "64 prompt tokens and 8 generated ones are the smallest that count" ("{0}|{1}" -f $m.PrefillTokS, $m.DecodeTokS) "640|80"
    $r = [pscustomobject]@{ timings = [pscustomobject]@{ cache_n = 0; prompt_n = 0; prompt_ms = 0; predicted_n = 10; predicted_ms = 0 } }
    $m = Get-BenchMetricsLlama $r 0
    Check "a zero duration gives null, not a division error" ("{0}|{1}" -f ($null -eq $m.PrefillTokS), ($null -eq $m.DecodeTokS)) "True|True"

    Write-Host "-- New-BenchPrompt (real function)"
    $p = New-BenchPrompt -Tokens 1000 -CharsPerToken 3.0 -Nonce "aaaaaaaaaaaa"
    Check "reaches its target length (>= 3000 chars)"        ($p.Length -ge 3000) "True"
    Check "...without overshooting by more than a line"      ($p.Length -lt 3000 + 200) "True"
    Check "begins with its nonce"                            $p.StartsWith("Benchmark nonce aaaaaaaaaaaa.") "True"
    Check "ends with the fixed instruction"                  $p.EndsWith("Now write the integers from 1 to 100 separated by single spaces, and nothing else.") "True"
    Check "the same nonce gives the same text"               ($p -eq (New-BenchPrompt -Tokens 1000 -CharsPerToken 3.0 -Nonce "aaaaaaaaaaaa")) "True"
    $q = New-BenchPrompt -Tokens 1000 -CharsPerToken 3.0 -Nonce "bbbbbbbbbbbb"
    Check "another nonce changes the first line (no shared prefix to cache)" ($p.Split("`n")[0] -ne $q.Split("`n")[0]) "True"

    Write-Host "-- Add-BenchRow (real function)"
    $f = Join-Path $tmp "unit/rows.tsv"
    Add-BenchRow -Path $f -Row @{ host = "server"; model = "m"; note = "a`tb`nc" }
    Add-BenchRow -Path $f -Row @{ host = "desktop"; model = "m"; targetTokens = 3000 }
    $lines = @(Get-Content -LiteralPath $f)
    Check "a header and two rows"                            $lines.Count 3
    Check "the header is the column list"                    $lines[0] ($script:Columns -join "`t")
    $c1 = $lines[1] -split "`t"
    Check "row 1: host in its column, empty cells empty"     ("{0}|{1}|{2}" -f $c1[1], $c1[4], $c1[6]) "server|m|"
    Check "row 1: tabs and newlines in a note become spaces" $c1[15] "a b c"
    Check "every row has every column"                       (($lines | ForEach-Object { $_.Split("`t").Count } | Sort-Object -Unique) -join ",") $script:Columns.Count

    # --- the real script, as a child process, against a stand-in host ---------
    Write-Host "-- end to end: the real bench-speed.ps1 against a stand-in llama-server"
    $psExe = (Get-Process -Id $PID).Path
    [IO.File]::WriteAllText("$tmp/driver.ps1", @'
param([string]$Script, [string]$ArgsFile)
# A stand-in llama-server. 3.2 characters per token (the script starts from 3.0,
# so its correction is visible); 600 tok/s prefill, 66 tok/s decode. Any other
# endpoint (an Ollama /api/* one included) falls through to the throw.
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType, $Headers)
    $u = "$Uri"
    if ($env:FIXTURE_HITS) { Add-Content -LiteralPath $env:FIXTURE_HITS -Value $u }
    if ($u -match '/props(\?model=.*)?$') {
        if ($env:FIXTURE_NO_PROPS) { throw "fixture: /props unavailable" }
        if ($u -match '\?model=' -and $env:FIXTURE_PROPS_BARE_ONLY) { throw "fixture: 400, a single-model server does not take ?model=" }
        return [pscustomobject]@{ build_info = 'b11561-abcdef0'; total_slots = 1; default_generation_settings = [pscustomobject]@{ n_ctx = 65536 } }
    }
    if ($u -match '/v1/chat/completions$') {
        if ($env:FIXTURE_FAIL) { throw "fixture: 500 from /v1/chat/completions" }
        $b = $Body | ConvertFrom-Json
        $text = [string]$b.messages[0].content
        $first = ($text -split "`n")[0]
        Add-Content -LiteralPath $env:FIXTURE_LOG -Value ("{0}|{1}|{2}|{3}" -f $first, $text.Length, $b.max_tokens, $b.cache_prompt)
        $count = [int]([math]::Round($text.Length / 3.2))
        $predict = [int]$b.max_tokens
        return [pscustomobject]@{
            usage   = [pscustomobject]@{ prompt_tokens = $count; completion_tokens = $predict }
            timings = [pscustomobject]@{ cache_n = 0; prompt_n = $count; prompt_ms = ($count / 600.0 * 1000.0); predicted_n = $predict; predicted_ms = ($predict / 66.0 * 1000.0) }
        }
    }
    throw "fixture: no endpoint $u"
}
$a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json
$splat = @{}
foreach ($p in $a.PSObject.Properties) { $splat[$p.Name] = $p.Value }
& $Script @splat
exit $LASTEXITCODE
'@, $utf8)
    $script:scn = 0
    function Invoke-Bench([hashtable]$Params, [hashtable]$Env = @{}) {
        $script:scn++
        # Never the repo's tests/results/bench-speed.tsv: a scenario that names no results
        # file gets a scratch one, so a broken refusal cannot log into the real record.
        if (-not $Params.ContainsKey("ResultsFile") -and -not $Params.ContainsKey("NoLog")) {
            $Params = $Params.Clone(); $Params.ResultsFile = Join-Path $tmp "default-$($script:scn).tsv"
        }
        $argsFile = Join-Path $tmp "args-$($script:scn).json"
        [IO.File]::WriteAllText($argsFile, ($Params | ConvertTo-Json -Depth 4), $utf8)
        $log = Join-Path $tmp "gen-$($script:scn).log"
        [IO.File]::WriteAllText($log, "", $utf8)
        $env:FIXTURE_LOG = $log
        $hitsFile = Join-Path $tmp "hits-$($script:scn).log"
        [IO.File]::WriteAllText($hitsFile, "", $utf8)
        $env:FIXTURE_HITS = $hitsFile
        foreach ($k in $Env.Keys) { Set-Item -Path "Env:$k" -Value $Env[$k] }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp "driver.ps1") -Script $ScriptPath -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
            Remove-Item Env:FIXTURE_LOG, Env:FIXTURE_HITS -ErrorAction SilentlyContinue
            foreach ($k in $Env.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        }
        $gen = @(Get-Content -LiteralPath $log | Where-Object { $_ } | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ First = $p[0]; Len = [int]$p[1]; Predict = [int]$p[2]; CachePrompt = $p[3] } })
        $hits = @(Get-Content -LiteralPath $hitsFile | Where-Object { $_ })
        [pscustomobject]@{ Out = ($out -replace '\x1b\[[0-9;]*m', ''); Exit = $code; Gen = $gen; Hits = $hits }
    }
    function Rows([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return @() }
        $lines = @(Get-Content -LiteralPath $Path)
        @($lines | Select-Object -Skip 1 | ForEach-Object { $c = $_.Split("`t"); $o = [ordered]@{}; for ($i = 0; $i -lt $script:Columns.Count; $i++) { $o[$script:Columns[$i]] = $c[$i] }; [pscustomobject]$o })
    }
    $lbase = @{ EngineHost = "http://fixture.invalid:8090"; HostLabel = "server"; Model = "qwen3.6:35b-a3b-coding"; Engine = "llamacpp" }

    Write-Host "   scenario: sizes 3000, 70000 (too big), 30000; two reps"
    $tsv = Join-Path $tmp "bench-6.tsv"
    $r = Invoke-Bench ($lbase + @{ PromptTokens = "3000,70000,30000"; Reps = 2; ResultsFile = $tsv })
    $rows = Rows $tsv
    Check "exit 0"                                           $r.Exit 0
    Check "a warm-up row, then 3 sizes x 2 reps = 7 rows"    $rows.Count 7
    Check "one header, however many rows"                    (@(Get-Content -LiteralPath $tsv | Where-Object { $_ -like "timestamp*" }).Count) 1
    Has   "warm-up note says load is approximate and placement unreported" $rows[0].note 'loadS approximate; placement not reported by llama-server'
    Check "...one token decoded, no speeds logged for it"     ("{0}|{1}|{2}" -f $r.Gen[0].Predict, $rows[0].prefillTokS, $rows[0].decodeTokS) "1||"
    $m1 = $rows | Where-Object { $_.targetTokens -eq "3000" } | Select-Object -First 1
    Check "3000 row: host, engine, build, model, served context (from /props)" ("{0}|{1}|{2}|{3}|{4}" -f $m1.host, $m1.engine, $m1.engineVersion, $m1.model, $m1.numCtx) "server|llamacpp|b11561-abcdef0|qwen3.6:35b-a3b-coding|65536"
    Check "...prefill 600 tok/s and decode 66 tok/s, read from timings" ("{0} {1}" -f $m1.prefillTokS, $m1.decodeTokS) "600 66"
    Check "...placement is blank, not invented"               ("{0}|{1}|{2}" -f $m1.totalGB, $m1.vramGB, $m1.gpuShare) "||"
    Check "...decoded -NumPredict (128) tokens"              $m1.evalTokens 128
    $skipped = @($rows | Where-Object { $_.targetTokens -eq "70000" })
    Check "70000 is skipped in both reps, and logged"        ("{0} {1}" -f $skipped.Count, ($skipped | ForEach-Object { $_.note } | Sort-Object -Unique)) "2 skipped: over 92% of num_ctx 65536"
    Has   "...and the console says llama-server would reject it" $r.Out 'llama-server would reject it'
    Check "...never sent: 1 warm-up + 4 requests"            $r.Gen.Count 5
    Check "every prompt has its own nonce"                   (@($r.Gen | Select-Object -ExpandProperty First | Sort-Object -Unique).Count) 5
    Check "every request turned the prompt cache off (cache_prompt false)" (@($r.Gen | Select-Object -ExpandProperty CachePrompt | Sort-Object -Unique) -join ",") "False"
    $first = [int]($rows | Where-Object { $_.targetTokens -eq "3000" } | Select-Object -First 1).promptTokens
    Check "the first measured size is within 3% of its target (warm-up calibrated the chars per token)" ([math]::Abs($first - 3000) -le 90) "True"
    Check "the router-mode query is tried first: /props?model=<escaped tag>" ($r.Hits[0]) "http://fixture.invalid:8090/props?model=qwen3.6%3A35b-a3b-coding"
    Check "5 chat completions went to /v1/chat/completions"  (@($r.Hits | Where-Object { $_ -like "*/v1/chat/completions" }).Count) 5
    Check "no Ollama endpoint was touched"                   (@($r.Hits | Where-Object { $_ -like "*/api/*" }).Count) 0
    Check "every request URL is one URL (no whitespace: `"a`" + `$x, `"b`" once fused two into one)" (@($r.Hits | Where-Object { $_ -match '\s' }).Count) 0

    Write-Host "   scenario: a single-model server that rejects ?model= (bare /props is the fallback)"
    $tsv = Join-Path $tmp "bench-7.tsv"
    $r = Invoke-Bench ($lbase + @{ PromptTokens = "3000"; ResultsFile = $tsv }) @{ FIXTURE_PROPS_BARE_ONLY = "1" }
    $rows = Rows $tsv
    Check "exit 0, and the build and context still read"     ("{0} {1} {2}" -f $r.Exit, $rows[1].engineVersion, $rows[1].numCtx) "0 b11561-abcdef0 65536"
    Check "both forms of /props were asked, in that order"   (($r.Hits | Select-Object -First 2) -join " ") "http://fixture.invalid:8090/props?model=qwen3.6%3A35b-a3b-coding http://fixture.invalid:8090/props"

    Write-Host "   scenario: a trailing /v1 on the host is accepted"
    $tsv = Join-Path $tmp "bench-8.tsv"
    $slashV1 = $lbase.Clone(); $slashV1.EngineHost = "http://fixture.invalid:8090/v1/"
    $r = Invoke-Bench ($slashV1 + @{ PromptTokens = "3000"; ResultsFile = $tsv })
    Check "exit 0, no doubled /v1 in any request"            ("{0} {1}" -f $r.Exit, (@($r.Hits | Where-Object { $_ -like "*/v1/v1/*" }).Count)) "0 0"

    Write-Host "   scenario: the chat completion fails"
    $tsv = Join-Path $tmp "bench-9.tsv"
    $r = Invoke-Bench ($lbase + @{ PromptTokens = "3000"; ResultsFile = $tsv }) @{ FIXTURE_FAIL = "1" }
    $rows = Rows $tsv
    Check "exit 1"                                           $r.Exit 1
    Check "both the warm-up and the size are logged as FAILED" (@($rows | Where-Object { $_.note -like "FAILED*" }).Count) 2
    Has   "...with the host's error"                         ($rows[1].note) 'FAILED rep 1: fixture: 500 from /v1/chat/completions'

    Write-Host "   scenario: /props unavailable"
    $tsv = Join-Path $tmp "bench-10.tsv"
    $r = Invoke-Bench ($lbase + @{ PromptTokens = "70000"; ResultsFile = $tsv }) @{ FIXTURE_NO_PROPS = "1" }
    $rows = Rows $tsv
    Check "build is 'unknown', num_ctx blank, nothing skipped (2 requests sent)" ("{0}|{1}|{2}|{3}" -f $rows[1].engineVersion, $rows[1].numCtx, $r.Gen.Count, (@($rows | Where-Object { $_.note -like "skipped*" }).Count)) "unknown||2|0"

    Write-Host "   scenario: -NoLog"
    $tsv = Join-Path $tmp "bench-11.tsv"
    $r = Invoke-Bench ($lbase + @{ PromptTokens = "3000"; ResultsFile = $tsv; NoLog = $true })
    Check "exit 0, requests sent, and no results file"       ("{0} {1} {2}" -f $r.Exit, $r.Gen.Count, (Test-Path -LiteralPath $tsv)) "0 2 False"

    Write-Host "   scenario: no -Engine (llamacpp is the default)"
    $tsv = Join-Path $tmp "bench-12.tsv"
    $noEngine = $lbase.Clone(); $noEngine.Remove("Engine")
    $r = Invoke-Bench ($noEngine + @{ PromptTokens = "3000"; ResultsFile = $tsv })
    $rows = @(Rows $tsv) + @($null, $null)
    Check "exit 0, rows say engine llamacpp, requests went to /v1/chat/completions" ("{0} {1} {2}" -f $r.Exit, $rows[1].engine, (@($r.Hits | Where-Object { $_ -like "*/v1/chat/completions" }).Count)) "0 llamacpp 2"

    Write-Host "   scenario: engines and parameters that are gone"
    foreach ($eng in "ollama", "vllm") {
        $tsv = Join-Path $tmp "bench-$eng.tsv"
        $r = Invoke-Bench ($noEngine + @{ Engine = $eng; ResultsFile = $tsv })
        Check "-Engine ${eng}: exit 2, nothing sent, no file"  ("{0} {1} {2}" -f $r.Exit, $r.Hits.Count, (Test-Path -LiteralPath $tsv)) "2 0 False"
        Has   "...says llamacpp is the only engine"            $r.Out 'supports only -Engine llamacpp'
    }
    $tsv = Join-Path $tmp "bench-oldparam.tsv"
    $r = Invoke-Bench @{ OllamaHost = "http://fixture.invalid:11434"; HostLabel = "server"; Model = "qwen3.6:35b-a3b-coding"; ResultsFile = $tsv }
    Check "-OllamaHost is no longer a parameter: nothing sent, no file" ("{0} {1}" -f $r.Hits.Count, (Test-Path -LiteralPath $tsv)) "0 False"
    Has   "...refused by PowerShell's parameter binding"     $r.Out "parameter name 'OllamaHost'"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

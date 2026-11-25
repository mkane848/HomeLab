# protects: probe-overflow.ps1 verdicts and OpenCode overflow patterns
# run-after: probe-overflow.ps1 or an opencode upgrade
# test-probe-overflow.ps1 - regression guard for tests/probe-overflow.ps1.
#
# Why this exists: probe-overflow.ps1 turns "llama-server rejects an oversized
# prompt, and OpenCode recognises the error" from a belief into a measurement on
# a given build (the reason Ollama, which cut such a prompt silently, was left;
# removed 2026-11-21). A verdict that calls a truncation an error (or the
# reverse), or an error message OpenCode would not recognise as an overflow,
# would hide the failure the move was made to avoid.
#
# What it does:
#   1. Pulls the REAL Test-OpenCodeOverflowText, Get-OverflowVerdict,
#      Get-HttpErrorInfo, New-OverflowPrompt and Add-OverflowRow out of the script.
#      The matcher: llama.cpp's own message is an overflow, a rate-limit message
#      containing "too many tokens" is NOT (OpenCode's exclusions win), a bodiless
#      400/413 is. The verdict: error -> EXPLICIT-ERROR, under 90% of the tokens
#      evaluated -> SILENT-TRUNCATION, the 90% line itself -> ACCEPTED-FULL. The
#      prompt starts with its needle and ends with the question.
#   2. Runs the REAL script as a child process against a stand-in llama-server
#      (a driver defines Invoke-RestMethod): refusing with its explicit error,
#      refusing with a text OpenCode would not recognise, cutting the prompt
#      silently, taking the whole prompt, a host that is down, -NoLog, llamacpp
#      as the default engine, and bad arguments (-Engine ollama and the removed
#      -OllamaHost among them). No Ollama endpoint (/api/*) is ever asked.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-probe-overflow.ps1 [-ScriptPath <a probe-overflow.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "probe-overflow.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
foreach ($name in "Test-OpenCodeOverflowText", "Get-OverflowVerdict", "Get-HttpErrorInfo", "New-OverflowPrompt", "Add-OverflowRow") {
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)) | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 1 }
    Invoke-Expression $fn.Extent.Text
}
foreach ($var in '$script:OverflowPatterns', '$script:OverflowExclusions', '$script:Columns') {
    $a = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var }, $true)) | Select-Object -First 1
    if (-not $a) { Write-Host "FAIL: $var not found"; exit 1 }
    Invoke-Expression $a.Extent.Text
}

$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")   # Check <name> <actual> <expected>: a PASS/FAIL line, failures counted in $script:fail
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("probe-overflow-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding($false)
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    Write-Host "-- Test-OpenCodeOverflowText (real function, OpenCode v1.18.34's patterns)"
    Check "llama.cpp's message is an overflow"                (Test-OpenCodeOverflowText "the request exceeds the available context size") "True"
    Check "...with its numbers"                               (Test-OpenCodeOverflowText "request (70000 tokens) exceeds the available context size (65536 tokens), try increasing it") "True"
    Check "OpenAI's wording is one"                           (Test-OpenCodeOverflowText "This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens") "True"
    Check "a bodiless 400 is one"                             (Test-OpenCodeOverflowText "400 status code (no body)") "True"
    Check "a bodiless 413 is one"                             (Test-OpenCodeOverflowText "413 (no body)") "True"
    Check "a rate limit that says 'too many tokens' is NOT (the exclusion wins)" (Test-OpenCodeOverflowText "Rate limit reached: too many tokens per minute") "False"
    Check "'Throttling error:' is NOT either"                 (Test-OpenCodeOverflowText "Throttling error: Too many tokens, please wait") "False"
    Check "a refused connection is not an overflow"           (Test-OpenCodeOverflowText "connection refused") "False"
    Check "an empty message is not"                           (Test-OpenCodeOverflowText "") "False"
    Check "the pattern list has all 27 of OpenCode's v1.18.34 entries and its 3 exclusions" ("{0}/{1}" -f $script:OverflowPatterns.Count, $script:OverflowExclusions.Count) "27/3"

    Write-Host "-- Get-OverflowVerdict (real function)"
    Check "an HTTP error is EXPLICIT-ERROR"                   (Get-OverflowVerdict -SentTokens 85000 -Reported $null -HttpError $true) "EXPLICIT-ERROR"
    Check "evaluated 50000 of 85000: SILENT-TRUNCATION"       (Get-OverflowVerdict -SentTokens 85000 -Reported 50000 -HttpError $false) "SILENT-TRUNCATION"
    Check "evaluated 84000 of 85000: ACCEPTED-FULL"           (Get-OverflowVerdict -SentTokens 85000 -Reported 84000 -HttpError $false) "ACCEPTED-FULL"
    Check "exactly 90% is ACCEPTED-FULL (the line is strict)"  (Get-OverflowVerdict -SentTokens 100000 -Reported 90000 -HttpError $false) "ACCEPTED-FULL"
    Check "just under 90% is SILENT-TRUNCATION"               (Get-OverflowVerdict -SentTokens 100000 -Reported 89999 -HttpError $false) "SILENT-TRUNCATION"
    Check "no count reported on a 200 is not called a truncation, nor a clean accept: UNKNOWN" (Get-OverflowVerdict -SentTokens 85000 -Reported $null -HttpError $false) "UNKNOWN"
    Check "a 400 with a status is EXPLICIT-ERROR"             (Get-OverflowVerdict -SentTokens 85000 -Reported $null -HttpError $true -Status 400) "EXPLICIT-ERROR"
    Check "a failure with no HTTP status (timeout, reset) is UNKNOWN, not EXPLICIT-ERROR" (Get-OverflowVerdict -SentTokens 85000 -Reported $null -HttpError $true -Status $null) "UNKNOWN"

    Write-Host "-- Get-HttpErrorInfo (real function)"
    $ex = New-Object System.Exception "Response status code does not indicate success: 400 (Bad Request)."
    $er = New-Object System.Management.Automation.ErrorRecord $ex, "HttpError", ([System.Management.Automation.ErrorCategory]::InvalidOperation), $null
    $er.ErrorDetails = New-Object System.Management.Automation.ErrorDetails '{"error":{"code":400,"message":"the request exceeds the available context size"}}'
    $i = Get-HttpErrorInfo $er
    Check "status from the message, body from ErrorDetails"   ("{0}" -f $i.Status) "400"
    Has   "...the body text is what the matcher sees"          $i.Text 'exceeds the available context size'
    $er2 = New-Object System.Management.Automation.ErrorRecord (New-Object System.Exception "connection refused"), "x", ([System.Management.Automation.ErrorCategory]::InvalidOperation), $null
    $i = Get-HttpErrorInfo $er2
    Check "no body, no status: the exception message, status null" ("{0}|{1}" -f $i.Text, ($null -eq $i.Status)) "connection refused|True"

    Write-Host "-- New-OverflowPrompt (real function)"
    $p = New-OverflowPrompt -Tokens 1000 -CharsPerToken 3.0 -Needle "MAGENTA-1234"
    Check "the needle is in the FIRST line (the part a front-drop loses)" ($p.Split("`n")[0] -like "*MAGENTA-1234*") "True"
    Check "the question is last"                              $p.EndsWith("What is the secret word? Answer with the word only.") "True"
    Check "reaches its target (>= 3000 chars) without overshooting by a line" (($p.Length -ge 3000) -and ($p.Length -lt 3000 + 250)) "True"
    Check "the needle appears once, not in the filler"        ([regex]::Matches($p, "MAGENTA-1234").Count) 1

    Write-Host "-- Add-OverflowRow (real function)"
    $f = Join-Path $tmp "unit/rows.tsv"
    Add-OverflowRow -Path $f -Row @{ host = "server"; verdict = "EXPLICIT-ERROR"; note = "a`tb`nc" }
    Add-OverflowRow -Path $f -Row @{ host = "desktop"; verdict = "SILENT-TRUNCATION" }
    $lines = @(Get-Content -LiteralPath $f)
    Check "a header and two rows, header = the column list"  ("{0} {1}" -f $lines.Count, ($lines[0] -eq ($script:Columns -join "`t"))) "3 True"
    Check "tabs and newlines in a note become spaces"        (($lines[1] -split "`t")[12]) "a b c"
    Check "every row has every column"                       (($lines | ForEach-Object { $_.Split("`t").Count } | Sort-Object -Unique) -join ",") $script:Columns.Count

    # --- the real script, as a child process, against a stand-in host -------------
    Write-Host "-- end to end: the real probe-overflow.ps1 against stand-in engines"
    $psExe = (Get-Process -Id $PID).Path
    [IO.File]::WriteAllText("$tmp/driver.ps1", @'
param([string]$Script, [string]$ArgsFile)
# A stand-in llama-server with a served context of 4096 tokens and 3.2 characters
# per token. FIXTURE_MODE: error400 (its explicit refusal) | othererror (a refusal
# OpenCode would not call an overflow) | truncate (a silent cut, what Ollama did) |
# full (takes it all) | down. Any other endpoint (/api/* included) throws.
function Throw-Http([int]$Status, [string]$Body) {
    $ex = New-Object System.Exception "Response status code does not indicate success: $Status (Error)."
    $er = New-Object System.Management.Automation.ErrorRecord $ex, "HttpError", ([System.Management.Automation.ErrorCategory]::InvalidOperation), $null
    if ($Body) { $er.ErrorDetails = New-Object System.Management.Automation.ErrorDetails $Body }
    throw $er
}
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType, $Headers)
    $u = "$Uri"
    Add-Content -LiteralPath $env:FIXTURE_HITS -Value $u
    if ($env:FIXTURE_MODE -eq 'down' -and $u -match '/v1/chat/completions$') { throw "fixture: connection refused" }
    if ($u -match '/props$') { return [pscustomobject]@{ build_info = 'b11561-abcdef0' } }
    if ($u -match '/v1/chat/completions$') {
        $b = $Body | ConvertFrom-Json
        $text = [string]$b.messages[0].content
        $count = [int]([math]::Round($text.Length / 3.2))
        $big = $count -gt 4096
        $needle = if ($text -match 'MAGENTA-\d+') { $Matches[0] } else { '' }
        if ($big -and $env:FIXTURE_MODE -eq 'error400') { Throw-Http 400 ('{"error":{"code":400,"message":"request (' + $count + ' tokens) exceeds the available context size (4096 tokens), try increasing it","type":"exceed_context_size_error"}}') }
        if ($big -and $env:FIXTURE_MODE -eq 'othererror') { Throw-Http 500 '{"error":{"code":500,"message":"failed to allocate the KV cache","type":"server_error"}}' }
        $evaluated = if ($big -and $env:FIXTURE_MODE -eq 'truncate') { 4096 - 64 } else { $count }
        $reply = if ($env:FIXTURE_MODE -eq 'full' -and $big) { "The secret word is $needle." } else { "I was not given a secret word." }
        return [pscustomobject]@{ usage = [pscustomobject]@{ prompt_tokens = $evaluated }; choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = $reply } }) }
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
    function Invoke-Probe([hashtable]$Params, [hashtable]$Env = @{}) {
        $script:scn++
        # Never the repo's tests/results/overflow-probe.tsv: a scenario that names no
        # results file gets a scratch one, so a broken refusal cannot log into the real
        # record (a mutation run did, 2026-11-22).
        if (-not $Params.ContainsKey("ResultsFile") -and -not $Params.ContainsKey("NoLog")) {
            $Params = $Params.Clone(); $Params.ResultsFile = Join-Path $tmp "default-$($script:scn).tsv"
        }
        $argsFile = Join-Path $tmp "args-$($script:scn).json"
        [IO.File]::WriteAllText($argsFile, ($Params | ConvertTo-Json -Depth 4), $utf8)
        $hits = Join-Path $tmp "hits-$($script:scn).log"
        [IO.File]::WriteAllText($hits, "", $utf8)
        $env:FIXTURE_HITS = $hits
        foreach ($k in $Env.Keys) { Set-Item -Path "Env:$k" -Value $Env[$k] }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp "driver.ps1") -Script $ScriptPath -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
            Remove-Item Env:FIXTURE_HITS -ErrorAction SilentlyContinue
            foreach ($k in $Env.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        }
        [pscustomobject]@{ Out = ($out -replace '\x1b\[[0-9;]*m', ''); Exit = $code; Hits = @(Get-Content -LiteralPath $hits | Where-Object { $_ }) }
    }
    function LastRow([string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $lines = @(Get-Content -LiteralPath $Path); $c = $lines[-1].Split("`t"); $o = [ordered]@{}
        for ($i = 0; $i -lt $script:Columns.Count; $i++) { $o[$script:Columns[$i]] = $c[$i] }
        [pscustomobject]$o
    }

    $lbase = @{ Engine = "llamacpp"; Endpoint = "http://fixture.invalid:8090"; Model = "qwen3.6:35b-a3b-coding"; NumCtx = 4096; HostLabel = "server" }
    $calls = "/props,/v1/chat/completions,/v1/chat/completions"

    Write-Host "   scenario: llama-server refuses with the explicit error"
    $tsv = Join-Path $tmp "l1.tsv"
    $r = Invoke-Probe ($lbase + @{ ResultsFile = $tsv }) @{ FIXTURE_MODE = "error400" }
    $row = LastRow $tsv
    Check "exit 0 (a verdict is a finding, not a failure)"   $r.Exit 0
    Check "verdict EXPLICIT-ERROR with HTTP 400"             ("{0}|{1}" -f $row.verdict, $row.httpStatus) "EXPLICIT-ERROR|400"
    Check "row: host, engine, build, model, served context"  ("{0}|{1}|{2}|{3}|{4}" -f $row.host, $row.engine, $row.engineVersion, $row.model, $row.numCtx) "server|llamacpp|b11561-abcdef0|qwen3.6:35b-a3b-coding|4096"
    Check "OpenCode would classify the text as an overflow"  $row.opencodeOverflow "True"
    Has   "the error text is kept in the note"               $row.note 'exceeds the available context size'
    Check "no count reported, no needle verdict"             ("{0}|{1}" -f $row.reportedPromptTokens, $row.needleFound) "|"
    Has   "the console says EXPLICIT-ERROR"                   $r.Out 'VERDICT: EXPLICIT-ERROR'
    Check "llama-server endpoints only: /props, then /v1/chat/completions twice (calibration, probe)" (($r.Hits | ForEach-Object { $_ -replace '^http://fixture.invalid:8090', '' }) -join ",") $calls

    Write-Host "   scenario: a refusal OpenCode would not recognise"
    $tsv = Join-Path $tmp "l2.tsv"
    $r = Invoke-Probe ($lbase + @{ ResultsFile = $tsv }) @{ FIXTURE_MODE = "othererror" }
    $row = LastRow $tsv
    Check "verdict EXPLICIT-ERROR with HTTP 500, and opencodeOverflow False" ("{0}|{1}|{2}" -f $row.verdict, $row.httpStatus, $row.opencodeOverflow) "EXPLICIT-ERROR|500|False"
    Has   "...the console says OpenCode would not classify it" $r.Out 'OpenCode would classify it as a context overflow: False'

    Write-Host "   scenario: the engine cuts the prompt silently (what Ollama did)"
    $tsv = Join-Path $tmp "l3.tsv"
    $r = Invoke-Probe ($lbase + @{ ResultsFile = $tsv }) @{ FIXTURE_MODE = "truncate" }
    $row = LastRow $tsv
    Check "exit 0"                                           $r.Exit 0
    Check "verdict SILENT-TRUNCATION, HTTP status blank"     ("{0}|{1}" -f $row.verdict, $row.httpStatus) "SILENT-TRUNCATION|"
    Check "the engine evaluated 4032 tokens, far fewer than were sent (~1.3 x 4096)" ("{0}|{1}" -f $row.reportedPromptTokens, ([int]$row.sentTokensEst -gt 5000)) "4032|True"
    Check "the needle was lost with the front of the prompt" $row.needleFound "False"
    Check "opencodeOverflow is blank (there was no error to classify)" $row.opencodeOverflow ""
    Has   "the console says SILENT-TRUNCATION"                $r.Out 'VERDICT: SILENT-TRUNCATION'
    Check "the same endpoints"                               (($r.Hits | ForEach-Object { $_ -replace '^http://fixture.invalid:8090', '' }) -join ",") $calls

    Write-Host "   scenario: the engine takes the whole prompt"
    $tsv = Join-Path $tmp "l4.tsv"
    $r = Invoke-Probe ($lbase + @{ ResultsFile = $tsv }) @{ FIXTURE_MODE = "full" }
    $row = LastRow $tsv
    Check "verdict ACCEPTED-FULL, and the needle was found"  ("{0}|{1}" -f $row.verdict, $row.needleFound) "ACCEPTED-FULL|True"
    Has   "...with a note to check -NumCtx"                   $row.note 'check -NumCtx'

    Write-Host "   scenario: the host is down"
    $tsv = Join-Path $tmp "l5.tsv"
    $r = Invoke-Probe ($lbase + @{ ResultsFile = $tsv }) @{ FIXTURE_MODE = "down" }
    Check "exit 1, no row"                                   ("{0} {1}" -f $r.Exit, (Test-Path -LiteralPath $tsv)) "1 False"
    Has   "...says the host is not answering"                 $r.Out 'host is not answering'

    Write-Host "   scenario: -NoLog, the default engine, and bad arguments"
    $tsv = Join-Path $tmp "l6.tsv"
    $r = Invoke-Probe ($lbase + @{ ResultsFile = $tsv; NoLog = $true }) @{ FIXTURE_MODE = "truncate" }
    Check "-NoLog: exit 0, requests sent, no file"           ("{0} {1} {2}" -f $r.Exit, $r.Hits.Count, (Test-Path -LiteralPath $tsv)) "0 3 False"
    $tsv = Join-Path $tmp "l7.tsv"
    $noEngine = $lbase.Clone(); $noEngine.Remove("Engine")
    $r = Invoke-Probe ($noEngine + @{ ResultsFile = $tsv }) @{ FIXTURE_MODE = "error400" }
    $row = LastRow $tsv
    Check "no -Engine: llamacpp is the default (row engine, endpoints)" ("{0}|{1}|{2}" -f $r.Exit, $row.engine, (($r.Hits | ForEach-Object { $_ -replace '^http://fixture.invalid:8090', '' }) -join ",")) "0|llamacpp|$calls"
    foreach ($eng in "ollama", "vllm") {
        $bad = $lbase.Clone(); $bad.Engine = $eng
        $r = Invoke-Probe $bad
        Check "-Engine ${eng}: exit 2, nothing sent"           ("{0} {1}" -f $r.Exit, $r.Hits.Count) "2 0"
        Has   "...says llamacpp is the only engine"             $r.Out 'supports only -Engine llamacpp'
    }
    $bad = $noEngine.Clone(); $bad.Remove("Endpoint"); $bad.OllamaHost = "http://fixture.invalid:11434"; $bad.NoLog = $true
    $r = Invoke-Probe $bad @{ FIXTURE_MODE = "error400" }
    Check "-OllamaHost is no longer a parameter: nothing sent" $r.Hits.Count 0
    Has   "...refused by PowerShell's parameter binding"     $r.Out "parameter name 'OllamaHost'"
    $bad = $lbase.Clone(); $bad.NumCtx = 512
    $r = Invoke-Probe $bad
    Check "-NumCtx under 1024: exit 2, nothing sent"          ("{0} {1}" -f $r.Exit, $r.Hits.Count) "2 0"
    $bad = $lbase.Clone(); $bad.Endpoint = "http://fixture.invalid:8090/v1/"; $bad.NoLog = $true
    $r = Invoke-Probe $bad @{ FIXTURE_MODE = "truncate" }
    Check "a trailing /v1/ is accepted (no doubled /v1)"     ("{0} {1}" -f $r.Hits.Count, @($r.Hits | Where-Object { $_ -like "*/v1/v1/*" }).Count) "3 0"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host "all passed"
exit 0

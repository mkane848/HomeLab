# probe-overflow.ps1 - what does an engine do with a prompt longer than its context?
#
# The case for leaving Ollama (docs/llamacpp-trial.md) rests on one behaviour:
# Ollama silently drops the front of a prompt that outgrows num_ctx, the task
# brief first, and the model carries on without it; llama-server rejects the
# request with an explicit error instead. This sends ONE oversized chat request
# and says which happened, so the claim is a measurement on a given engine and
# version rather than a belief. It serves two steps of the trial:
#   - the premise check: does Ollama 0.40.x still cut silently? (a scratch
#     container, a small model, a small num_ctx);
#   - measurement C, first half: does llama-server answer with an error, and is
#     it one OpenCode would recognise as a context overflow?
#
# How it decides. A needle ("The secret word is MAGENTA-nnnn") is the FIRST line
# of the prompt, filler follows, and the question is last. After a calibration
# request (~600 tokens, to learn characters per token), the probe sends about
# -Over x -NumCtx tokens. Then:
#   EXPLICIT-ERROR      the request failed with an HTTP error (status and text
#                       recorded; opencodeOverflow says whether OpenCode's
#                       pattern list would classify that text as an overflow)
#   SILENT-TRUNCATION   HTTP 200, but the engine reports evaluating fewer than 90%
#                       of the tokens sent: it cut the prompt and said nothing
#   ACCEPTED-FULL       HTTP 200 and the whole prompt was evaluated: -NumCtx is
#                       lower than what the engine really serves (check it), or
#                       the engine grew the window
# needleFound is information, not the verdict (a model can guess).
#
# Pass -NumCtx as the context the engine SERVES for this model: an Ollama tag's
# baked num_ctx (or OLLAMA_CONTEXT_LENGTH for an un-baked tag), llama-server's
# `c` in the preset (check /props). The probe does not set it.
#
# Rows go to tests/results/overflow-probe.tsv (-NoLog skips); no prompt text.
#
# Usage:
#   .\tests\probe-overflow.ps1 -Engine ollama   -Endpoint http://SERVER_IP:11500 -Model qwen3:8b -NumCtx 4096 -HostLabel server
#   .\tests\probe-overflow.ps1 -Engine llamacpp -Endpoint http://SERVER_IP:8090  -Model qwen3.6:35b-a3b-coding -NumCtx 65536 -HostLabel server
# Exit 0 whatever the verdict (each is a finding); 1 if the host does not answer
# the calibration request; 2 on bad arguments.
param(
    [string]$Engine = "ollama",
    [Parameter(Mandatory)][Alias("EngineHost", "OllamaHost")][string]$Endpoint,
    [Parameter(Mandatory)][string]$Model,
    [Parameter(Mandatory)][int]$NumCtx,
    [string]$HostLabel = "host",
    # How far past the served context to go. 1.3 puts a silent cut well under the 90% line.
    [double]$Over = 1.3,
    [string]$ResultsFile = (Join-Path $PSScriptRoot "results/overflow-probe.tsv"),
    [switch]$NoLog,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = "Stop"
$script:Columns = @("timestamp", "host", "engine", "engineVersion", "model", "numCtx", "sentTokensEst", "reportedPromptTokens",
                    "httpStatus", "verdict", "needleFound", "opencodeOverflow", "note")

# OpenCode's own test for "this error means the context overflowed": the patterns
# and exclusions of isContextOverflow in packages/llm/src/provider-error.ts at tag
# v1.18.34 (read 2026-10-12; docs/references.md, opencode-provider-error), plus its
# fallback for a bodiless 400/413. Re-copy them when OpenCode is upgraded.
$script:OverflowPatterns = @(
    'prompt is too long', 'request_too_large', 'input is too long for requested model', 'exceeds the context window',
    "exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\d,]+ tokens?|\s*\([\d,]+\))", 'input token count.*exceeds the maximum',
    'tokens in request more than max tokens allowed', 'maximum prompt length is \d+', 'reduce the length of the messages',
    'maximum context length is \d+ tokens', 'exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?',
    "input \(\d+ tokens\) is longer than the model'?s context length \(\d+ tokens\)", 'exceeds the limit of \d+',
    'exceeds the available context size', 'greater than the context length', 'context window exceeds limit', 'exceeded model token limit',
    'context[_ ]length[_ ]exceeded', 'request entity too large', 'context length is only \d+ tokens', 'input length.*exceeds.*context length',
    'prompt too long; exceeded (?:max )?context length', 'too large for model with \d+ maximum context length',
    'prompt has [\d,]+ tokens?, but the configured context size is [\d,]+ tokens?', 'model_context_window_exceeded', 'too many tokens', 'token limit exceeded')
$script:OverflowExclusions = @('^(throttling error|service unavailable):', 'rate limit', 'too many requests')

function Test-OpenCodeOverflowText {
    # Would OpenCode 1.18.34 call this error message a context overflow?
    param([string]$Text)
    if (-not $Text) { return $false }
    foreach ($x in $script:OverflowExclusions) { if ($Text -match "(?i)$x") { return $false } }
    foreach ($p in $script:OverflowPatterns) { if ($Text -match "(?i)$p") { return $true } }
    return ($Text -match '(?i)^4(00|13)\s*(status code)?\s*\(no body\)')
}

function Get-OverflowVerdict {
    # SentTokens: our estimate of what we sent. Reported: what the engine says it
    # evaluated ($null if it did not say). HttpError: $true when the request failed.
    # Status: the HTTP status of that failure when the caller passes it. A failure with
    # no status (timeout, connection reset, host down) is not the engine refusing the
    # request, so it is UNKNOWN, never EXPLICIT-ERROR. A 200 that reports no token
    # count cannot be told from a truncation either: UNKNOWN, not ACCEPTED-FULL.
    param([double]$SentTokens, $Reported, [bool]$HttpError, $Status = -1)
    if ($HttpError) {
        if ($null -eq $Status -or "$Status" -eq "0") { return "UNKNOWN" }
        return "EXPLICIT-ERROR"
    }
    if ($null -eq $Reported) { return "UNKNOWN" }
    if ([double]$Reported -lt 0.9 * $SentTokens) { return "SILENT-TRUNCATION" }
    return "ACCEPTED-FULL"
}

function Get-HttpErrorInfo {
    # Status code and body text from a failed Invoke-RestMethod, on PowerShell 7
    # (the body is in ErrorDetails) and 5.1 (it is in the response stream).
    param($ErrorRecord)
    $status = $null; $body = $null
    try { if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) { $status = [int]$ErrorRecord.Exception.Response.StatusCode } } catch { }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = $ErrorRecord.ErrorDetails.Message }
    elseif ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.GetType().GetMethod("GetResponseStream")) {
        try { $body = (New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
    }
    if ($null -eq $status -and $ErrorRecord.Exception.Message -match '\b([45]\d\d)\b') { $status = [int]$Matches[1] }
    $text = if ($body) { $body } else { $ErrorRecord.Exception.Message }
    [pscustomobject]@{ Status = $status; Text = ($text -replace '\s+', ' ').Trim() }
}

function New-OverflowPrompt {
    # The needle first, filler, then the question. About $Tokens tokens at $CharsPerToken.
    param([int]$Tokens, [double]$CharsPerToken, [string]$Needle)
    $words = @("amber", "river", "stone", "lantern", "meadow", "copper", "harbor", "willow", "ember", "quartz", "falcon", "thistle")
    $rng = New-Object System.Random ([math]::Abs($Needle.GetHashCode()))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("The secret word is $Needle. Remember it; you will be asked for it at the end.`nThe numbered lines below are filler; ignore them.`n")
    $want = [int]($Tokens * $CharsPerToken)
    $i = 0
    while ($sb.Length -lt $want) {
        $i++
        [void]$sb.Append(("Line {0:D6}: {1} {2} {3} {4}.`n" -f $i, $words[$rng.Next($words.Count)], $words[$rng.Next($words.Count)], $rng.Next(1000, 9999), $words[$rng.Next($words.Count)]))
    }
    [void]$sb.Append("`nWhat is the secret word? Answer with the word only.")
    return $sb.ToString()
}

function Add-OverflowRow {
    param([string]$Path, [hashtable]$Row)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text = ""
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) { $text += ($script:Columns -join "`t") + "`n" }
    $text += (($script:Columns | ForEach-Object { $v = $Row[$_]; if ($null -eq $v) { "" } else { ("$v" -replace "[`t`r`n]+", " ") } }) -join "`t") + "`n"
    [IO.File]::AppendAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

if (@("ollama", "llamacpp") -notcontains $Engine) {
    Write-Host "probe-overflow.ps1 supports -Engine ollama or llamacpp, not '$Engine'." -ForegroundColor Red
    exit 2
}
if ($NumCtx -lt 1024 -or $Over -le 1.0) { Write-Host "-NumCtx must be at least 1024 and -Over above 1.0" -ForegroundColor Red; exit 2 }
$root = $Endpoint.TrimEnd('/') -replace '/v1$', ''

$version = "unknown"
try {
    if ($Engine -eq "llamacpp") {
        $bi = (Invoke-RestMethod -Uri "$root/props" -TimeoutSec 10).build_info
        if ($bi) { $version = [string]$bi }
    } else {
        $version = [string](Invoke-RestMethod -Uri "$root/api/version" -TimeoutSec 10).version
    }
} catch { }

function Invoke-Chat([string]$Prompt, [int]$Predict) {
    # One chat request; returns @{ Reported = <prompt tokens the engine says it evaluated>; Reply = <text> }.
    if ($Engine -eq "llamacpp") {
        $body = @{ model = $Model; messages = @(@{ role = "user"; content = $Prompt }); max_tokens = $Predict; temperature = 0; stream = $false; cache_prompt = $false } | ConvertTo-Json -Depth 6
        $r = Invoke-RestMethod -Uri "$root/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec
        $msg = @($r.choices)[0].message
        return @{ Reported = $r.usage.prompt_tokens; Reply = ("$($msg.content) $($msg.reasoning_content)") }
    }
    $body = @{ model = $Model; messages = @(@{ role = "user"; content = $Prompt }); stream = $false; options = @{ num_predict = $Predict; temperature = 0 } } | ConvertTo-Json -Depth 6
    $r = Invoke-RestMethod -Uri "$root/api/chat" -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec
    return @{ Reported = $r.prompt_eval_count; Reply = ("$($r.message.content) $($r.message.thinking)") }
}

Write-Host ("probe-overflow: {0} on {1} ({2}) | {3} {4} | served context {5}, sending ~{6}x" -f $Model, $HostLabel, $root, $Engine, $version, $NumCtx, $Over) -ForegroundColor DarkGray

# Calibration: how many characters is a token on this model?
$charsPerToken = 3.0
try {
    $cal = New-OverflowPrompt -Tokens 600 -CharsPerToken $charsPerToken -Needle ("CAL-" + (Get-Random -Minimum 1000 -Maximum 9999))
    $c = Invoke-Chat $cal 8
    if ($c.Reported -ge 64) { $charsPerToken = [math]::Max(1.0, $cal.Length / [double]$c.Reported) }
} catch {
    Write-Host "calibration request failed, so the host is not answering: $((Get-HttpErrorInfo $_).Text)" -ForegroundColor Red
    exit 1
}

$needle = "MAGENTA-" + (Get-Random -Minimum 1000 -Maximum 9999)
$sentTokens = [int]($NumCtx * $Over)
$prompt = New-OverflowPrompt -Tokens $sentTokens -CharsPerToken $charsPerToken -Needle $needle
$sentEst = [int]([math]::Round($prompt.Length / $charsPerToken))

$status = $null; $reported = $null; $found = $null; $note = ""; $err = $false; $errText = ""
try {
    $r = Invoke-Chat $prompt 64
    $reported = $r.Reported
    $found = ($r.Reply -match [regex]::Escape($needle))
} catch {
    $err = $true
    $info = Get-HttpErrorInfo $_
    $status = $info.Status; $errText = $info.Text
    $note = $errText
}
$verdict = Get-OverflowVerdict -SentTokens $sentEst -Reported $reported -HttpError $err -Status $status
$oc = if ($err) { Test-OpenCodeOverflowText $errText } else { $null }
if ($verdict -eq "ACCEPTED-FULL") { $note = "the engine evaluated all $reported tokens past a served context of ${NumCtx}: check -NumCtx" }
if ($verdict -eq "UNKNOWN") { $note = $(if ($err) { "the request failed with no HTTP status ($errText): a timeout or a dropped connection, not the engine refusing it" } else { "the engine reported no prompt token count, so a truncation cannot be ruled out" }) }
if ($verdict -eq "SILENT-TRUNCATION") { $note = "sent ~$sentEst tokens, engine evaluated $reported ($([math]::Round(100.0 * $reported / $sentEst))%)" }

$color = switch ($verdict) { "EXPLICIT-ERROR" { "Green" } "SILENT-TRUNCATION" { "Red" } default { "Yellow" } }
Write-Host ("  sent ~{0} tokens | engine evaluated {1} | HTTP {2} | needle found: {3}" -f $sentEst, $(if ($null -ne $reported) { $reported } else { "n/a" }), $(if ($status) { $status } else { "200/none" }), $(if ($null -ne $found) { $found } else { "n/a" })) -ForegroundColor DarkGray
Write-Host ("  VERDICT: {0}" -f $verdict) -ForegroundColor $color
if ($err) {
    Write-Host ("  error text: {0}" -f $(if ($errText.Length -gt 220) { $errText.Substring(0, 220) + "..." } else { $errText })) -ForegroundColor DarkGray
    Write-Host ("  OpenCode would classify it as a context overflow: {0}" -f $oc) -ForegroundColor $(if ($oc) { "Green" } else { "Yellow" })
}
if ($note -and ($verdict -eq "UNKNOWN" -or -not $err)) { Write-Host "  $note" -ForegroundColor DarkGray }

if (-not $NoLog) {
    Add-OverflowRow -Path $ResultsFile -Row @{
        timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss"); host = $HostLabel; engine = $Engine; engineVersion = $version; model = $Model
        numCtx = $NumCtx; sentTokensEst = $sentEst; reportedPromptTokens = $reported; httpStatus = $status; verdict = $verdict
        needleFound = $found; opencodeOverflow = $oc; note = $(if ($note.Length -gt 300) { $note.Substring(0, 300) } else { $note }) }
    Write-Host "row appended to $ResultsFile" -ForegroundColor DarkGray
}
exit 0

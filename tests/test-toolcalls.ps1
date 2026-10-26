# protects: Tool-call probe for a model on a host (PASS/FAIL; needs live hosts)
# run-after: n/a (live-host probe, not a CI guard)
# test-toolcalls.ps1 — Does this model actually call tools?
#
# THE most important check before putting a model in any seat that has to read,
# edit, or run something. `ollama show` listing a "tools" capability only means
# the model's TEMPLATE supports tools — it says nothing about whether the
# weights reliably emit a call the parser can extract.
#
# Models that fail this return an EMPTY tool_calls array and print the call as
# chat text instead, e.g.
#     {"name": "write_file", "arguments": {"path": "a.txt", "content": "hello"}}
# An agent driven by such a model will claim it edited files it never touched.
#
# Usage:
#   .\tests\test-toolcalls.ps1                      # every installed chat model
#   .\tests\test-toolcalls.ps1 -Model qwen3:8b      # one model
#   .\tests\test-toolcalls.ps1 -Model a,b -OllamaHost http://SERVER_IP:11434 -HostLabel server
#   .\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -HostLabel server -Model qwen3.6:35b-a3b-coding
#
# Every result is appended to tests/results/toolcalls-summary.tsv, tagged with
# the host and the Ollama version it ran against. A probe result is only valid
# for that version, and before this log they were recorded by hand
# (toolcalls-0.34.1.txt). -NoLog skips the append. run-tasks-batch.ps1 reads
# this file to show each model's last probe result in its menus.
#
# -Engine llamacpp (the engine trial, docs/llamacpp-trial.md) sends the same
# prompt and the same tool schema to llama-server's /v1/chat/completions, where
# the call comes back in the OpenAI shape (arguments as a JSON string). Chat
# template and tool parsing differ by engine, so the verdict is per engine and
# build. Its results go to tests/results/toolcalls-summary-llamacpp.tsv, a
# SEPARATE file with engine + engineVersion columns, so the Ollama log that
# run-tasks-batch.ps1 parses is never touched. After each probe the model is
# unloaded through POST /models/unload (router mode; a single-model server has
# no such endpoint and the call is ignored) unless -KeepLoaded.
#
# Exit code: 0 if every tested model passed, 1 otherwise.

param(
    [string[]]$Model,
    # -EngineHost is the same parameter under the name that fits either engine.
    # Default: Ollama's port, or llama-server's 8090 when -Engine llamacpp.
    [Alias("EngineHost")][string]$OllamaHost,
    # Short name for the host in the log: desktop / node3 / server. Matches the
    # opencode provider suffix (ollama-<label>). Defaults to "desktop" for
    # localhost, else the URL's host part.
    [string]$HostLabel,
    [string]$Engine = "ollama",
    [string]$LogFile = (Join-Path $PSScriptRoot "results\toolcalls-summary.tsv"),
    [switch]$NoLog,
    [int]$TimeoutSec = 900,
    [switch]$KeepLoaded
)

$ErrorActionPreference = "Stop"

if (@("ollama", "llamacpp") -notcontains $Engine) {
    Write-Host "test-toolcalls.ps1 supports -Engine ollama or llamacpp, not '$Engine'." -ForegroundColor Red
    exit 2
}
if (-not $OllamaHost) { $OllamaHost = if ($Engine -eq "llamacpp") { "http://localhost:8090" } else { "http://localhost:11434" } }
if ($Engine -eq "llamacpp" -and -not $PSBoundParameters.ContainsKey("LogFile")) {
    $LogFile = Join-Path $PSScriptRoot "results/toolcalls-summary-llamacpp.tsv"
}

$OllamaHost = $OllamaHost -replace '/v1/?$', '' -replace '/$', ''
if (-not $HostLabel) {
    $HostLabel = if ($OllamaHost -match '//(localhost|127\.0\.0\.1)[:/]?') { "desktop" } else { ([uri]$OllamaHost).Host }
}
if ($Engine -eq "llamacpp") {
    # /props carries the build (build_info, e.g. "b11561-abcdef0").
    $ollamaVersion = "unknown"
    try { $bi = (Invoke-RestMethod -Uri "$OllamaHost/props" -TimeoutSec 10).build_info; if ($bi) { $ollamaVersion = [string]$bi } } catch { }
} else {
    try   { $ollamaVersion = (Invoke-RestMethod -Uri "$OllamaHost/api/version" -TimeoutSec 10).version }
    catch { $ollamaVersion = "unknown" }
}

# Embedding models have no chat endpoint; skip them.
$SKIP_PATTERN = 'embed|bge-|nomic|mxbai'

function Get-ChatModels {
    if ($Engine -eq "llamacpp") {
        # OpenAI-style listing; in router mode the ids are the preset's model names.
        foreach ($u in @("$OllamaHost/v1/models", "$OllamaHost/models")) {
            try {
                $ids = @((Invoke-RestMethod -Uri $u -TimeoutSec 30).data | ForEach-Object { $_.id } | Where-Object { $_ })
                if ($ids.Count -gt 0) { return @($ids | Where-Object { $_ -notmatch $SKIP_PATTERN } | Sort-Object) }
            } catch { }
        }
        return @()
    }
    $r = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 30
    return @($r.models | ForEach-Object { $_.name } | Where-Object { $_ -notmatch $SKIP_PATTERN } | Sort-Object)
}

function Test-ToolCallLlama {
    # The same probe for llama-server: the SAME prompt and tool schema as
    # Test-ToolCall below (keep the two in step; test-toolcalls-engine.ps1 checks
    # they match), sent to /v1/chat/completions. The call comes back in the OpenAI
    # shape, so `arguments` is a JSON string. max_tokens is generous because a
    # reasoning model spends its budget on the think block first.
    param([string]$Tag)

    $body = @{
        model      = $Tag
        messages   = @(@{ role = "user"; content = "Write the text 'hello' to a file named a.txt. Use the tool." })
        tools      = @(@{
            type     = "function"
            function = @{
                name        = "write_file"
                description = "Write text to a file"
                parameters  = @{
                    type       = "object"
                    properties = @{ path = @{ type = "string" }; content = @{ type = "string" } }
                    required   = @("path", "content")
                }
            }
        })
        stream     = $false
        max_tokens = 2048
    } | ConvertTo-Json -Depth 10

    $unload = {
        # Router mode only; a single-model server has no such endpoint, which is fine.
        if (-not $KeepLoaded) {
            try { $null = Invoke-RestMethod -Uri "$OllamaHost/models/unload" -Method Post -Body (@{ model = $Tag } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 60 } catch { }
        }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$OllamaHost/v1/chat/completions" -Method Post -Body $body `
                -ContentType "application/json" -TimeoutSec $TimeoutSec
    } catch {
        & $unload
        return [pscustomobject]@{ Model = $Tag; Status = "ERROR"; Detail = $_.Exception.Message; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    $sw.Stop()
    & $unload

    $msg = @($r.choices)[0].message
    $tc = $msg.tool_calls
    if ($tc -and @($tc).Count -gt 0) {
        $name = @($tc)[0].function.name
        $raw = @($tc)[0].function.arguments
        $argText = if ($raw -is [string]) { ($raw -replace '\s+', ' ').Trim() } else { $raw | ConvertTo-Json -Compress }
        $ok = ($name -eq "write_file")
        return [pscustomobject]@{
            Model  = $Tag
            Status = $(if ($ok) { "PASS" } else { "WARN" })
            Detail = $(if ($ok) { "tool_calls -> $name $argText" } else { "called '$name' instead of write_file: $argText" })
            Sec    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }

    $content = ("$($msg.content)" -replace '\s+', ' ').Trim()
    if ($content.Length -gt 110) { $content = $content.Substring(0, 110) + "..." }
    $hint = if ($content -match '"name"\s*:') { "emitted the call as CHAT TEXT (parser saw no tool_call tags)" } else { "ignored the tool entirely" }
    return [pscustomobject]@{
        Model  = $Tag
        Status = "FAIL"
        Detail = "$hint -> [$content]"
        Sec    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Test-ToolCall {
    param([string]$Tag)

    if ($Engine -eq "llamacpp") { return (Test-ToolCallLlama -Tag $Tag) }

    $body = @{
        model    = $Tag
        messages = @(@{ role = "user"; content = "Write the text 'hello' to a file named a.txt. Use the tool." })
        tools    = @(@{
            type     = "function"
            function = @{
                name        = "write_file"
                description = "Write text to a file"
                parameters  = @{
                    type       = "object"
                    properties = @{ path = @{ type = "string" }; content = @{ type = "string" } }
                    required   = @("path", "content")
                }
            }
        })
        stream     = $false
        keep_alive = $(if ($KeepLoaded) { "5m" } else { "0" })
    } | ConvertTo-Json -Depth 10

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$OllamaHost/api/chat" -Method Post -Body $body `
                -ContentType "application/json" -TimeoutSec $TimeoutSec
    } catch {
        return [pscustomobject]@{ Model = $Tag; Status = "ERROR"; Detail = $_.Exception.Message; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    $sw.Stop()

    $tc = $r.message.tool_calls
    if ($tc -and @($tc).Count -gt 0) {
        $name = @($tc)[0].function.name
        $args = @($tc)[0].function.arguments | ConvertTo-Json -Compress
        $ok = ($name -eq "write_file")
        return [pscustomobject]@{
            Model  = $Tag
            Status = $(if ($ok) { "PASS" } else { "WARN" })
            Detail = $(if ($ok) { "tool_calls -> $name $args" } else { "called '$name' instead of write_file: $args" })
            Sec    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }

    $content = ($r.message.content -replace '\s+', ' ').Trim()
    if ($content.Length -gt 110) { $content = $content.Substring(0, 110) + "..." }
    $hint = if ($content -match '"name"\s*:') { "emitted the call as CHAT TEXT (parser saw no tool_call tags)" } else { "ignored the tool entirely" }
    return [pscustomobject]@{
        Model  = $Tag
        Status = "FAIL"
        Detail = "$hint -> [$content]"
        Sec    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

$targets = if ($Model) { $Model } else { Get-ChatModels }
if (-not $targets) { Write-Host "No chat models found at $OllamaHost" -ForegroundColor Yellow; exit 1 }

Write-Host ""
$engineLabel = if ($Engine -eq "llamacpp") { "llama.cpp $ollamaVersion" } else { "Ollama $ollamaVersion" }
Write-Host "=== Tool-calling probe against $OllamaHost ($HostLabel, $engineLabel) ===" -ForegroundColor Cyan
Write-Host "    PASS = returns a structured tool_calls entry (safe for an agent seat)" -ForegroundColor Gray
Write-Host "    FAIL = empty tool_calls; will claim edits it never made" -ForegroundColor Gray
Write-Host ""

$results = foreach ($t in $targets) {
    Write-Host ("  probing {0} ..." -f $t) -ForegroundColor DarkGray
    $r = Test-ToolCall -Tag $t
    $color = switch ($r.Status) { "PASS" { "Green" } "FAIL" { "Red" } "WARN" { "Yellow" } default { "Magenta" } }
    Write-Host ("  [{0,-5}] {1,-26} {2,6}s  {3}" -f $r.Status, $r.Model, $r.Sec, $r.Detail) -ForegroundColor $color
    if (-not $NoLog) {
        if (-not (Test-Path -LiteralPath $LogFile)) {
            $header = if ($Engine -eq "llamacpp") { "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail" }
                      else { "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail" }
            $header | Set-Content -LiteralPath $LogFile -Encoding utf8
        }
        # Tabs/newlines in model output would break the TSV.
        $detail = $r.Detail -replace '[\t\r\n]+', ' '
        $stamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        $line = if ($Engine -eq "llamacpp") {
            "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f $stamp, $HostLabel, $Engine, $ollamaVersion, $r.Model, $r.Status, $r.Sec, $detail
        } else {
            "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $stamp, $HostLabel, $ollamaVersion, $r.Model, $r.Status, $r.Sec, $detail
        }
        $line | Add-Content -LiteralPath $LogFile -Encoding utf8
    }
    $r
}

Write-Host ""
$pass = @($results | Where-Object Status -eq "PASS").Count
$total = @($results).Count
Write-Host ("Tool-capable: {0}/{1}" -f $pass, $total) -ForegroundColor $(if ($pass -eq $total) { "Green" } else { "Yellow" })
Write-Host ""

if (@($results | Where-Object Status -ne "PASS").Count -gt 0) { exit 1 }
exit 0

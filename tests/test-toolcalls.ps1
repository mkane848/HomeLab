# protects: Tool-call probe for a model on a host (PASS/FAIL; needs live hosts)
# run-after: n/a (live-host probe, not a CI guard)
# test-toolcalls.ps1 — Does this model actually call tools?
#
# THE most important check before putting a model in any seat that has to read,
# edit, or run something. A chat template that supports tools says nothing about
# whether the weights reliably emit a call the parser can extract.
#
# Models that fail this return an EMPTY tool_calls array and print the call as
# chat text instead, e.g.
#     {"name": "write_file", "arguments": {"path": "a.txt", "content": "hello"}}
# An agent driven by such a model will claim it edited files it never touched.
#
# Usage:
#   .\tests\test-toolcalls.ps1                      # every model llama-server lists
#   .\tests\test-toolcalls.ps1 -Model qwen3:8b      # one model
#   .\tests\test-toolcalls.ps1 -EngineHost http://SERVER_IP:8090 -HostLabel server -Model qwen3.6:35b-a3b-coding
#
# llama.cpp is the only local engine (Ollama was removed on 2026-11-21). The probe
# sends one prompt and one tool schema to llama-server's /v1/chat/completions,
# where the call comes back in the OpenAI shape (arguments as a JSON string).
# Chat template and tool parsing differ by build, so the verdict is per build.
# After each probe the model is unloaded through POST /models/unload (router
# mode; a single-model server has no such endpoint and the call is ignored)
# unless -KeepLoaded.
#
# Every result is appended to tests/results/toolcalls-summary-llamacpp.tsv
# (8 columns: engine + engineVersion), tagged with the host and the build it ran
# against. -NoLog skips the append. run-tasks-batch.ps1 reads this file to show
# each model's last probe result in its menus. The Ollama-era log,
# tests/results/toolcalls-summary.tsv (7 columns, ollamaVersion), is history and
# is never written to: a -LogFile whose header is not this script's is refused.
#
# -Engine is accepted for the callers that pass it (run-tasks-batch.ps1 passes
# -Engine llamacpp); llamacpp is its only value.
#
# Exit code: 0 if every tested model passed, 1 otherwise, 2 on bad arguments.

# CmdletBinding makes an unknown parameter an error: the removed -OllamaHost must
# not be dropped silently and the probe sent to localhost instead.
[CmdletBinding()]
param(
    [string[]]$Model,
    # llama-server's root URL (a trailing /v1 is accepted). Default: localhost:8090.
    [string]$EngineHost = "http://localhost:8090",
    # Short name for the host in the log: node3 / server. Matches the opencode
    # provider suffix (llamacpp-<label>). Defaults to "desktop" for localhost,
    # else the URL's host part.
    [string]$HostLabel,
    [string]$Engine = "llamacpp",
    [string]$LogFile = (Join-Path $PSScriptRoot "results/toolcalls-summary-llamacpp.tsv"),
    [switch]$NoLog,
    [int]$TimeoutSec = 900,
    [switch]$KeepLoaded
)

$ErrorActionPreference = "Stop"

if ($Engine -ne "llamacpp") {
    Write-Host "test-toolcalls.ps1 supports only -Engine llamacpp, not '$Engine'." -ForegroundColor Red
    exit 2
}
$script:LogHeader = "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail"
if (-not $NoLog -and (Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 0) {
    # Never append 8-column rows to a log of another shape (the Ollama-era 7-column one).
    $first = (Get-Content -LiteralPath $LogFile -TotalCount 1) -replace '^﻿', ''
    if ($first -ne $script:LogHeader) {
        Write-Host "test-toolcalls.ps1: $LogFile has another header, so it is not this script's log; nothing was sent." -ForegroundColor Red
        exit 2
    }
}

$EngineHost = $EngineHost -replace '/v1/?$', '' -replace '/$', ''
if (-not $HostLabel) {
    $HostLabel = if ($EngineHost -match '//(localhost|127\.0\.0\.1)[:/]?') { "desktop" } else { ([uri]$EngineHost).Host }
}
# llama-server's API key (docs/engine-api-keys.md).
. (Join-Path $PSScriptRoot "engines/llamacpp-auth.ps1")
$llamaHeaders = Get-LlamacppHeaders
# /props carries the build (build_info, e.g. "b11561-abcdef0").
$engineVersion = "unknown"
try { $bi = (Invoke-RestMethod -Headers $llamaHeaders -Uri "$EngineHost/props" -TimeoutSec 10).build_info; if ($bi) { $engineVersion = [string]$bi } } catch { }

# Embedding models have no chat endpoint; skip them.
$SKIP_PATTERN = 'embed|bge-|nomic|mxbai'

function Get-ChatModels {
    # OpenAI-style listing; in router mode the ids are the preset's model names.
    foreach ($u in @("$EngineHost/v1/models", "$EngineHost/models")) {
        try {
            $ids = @((Invoke-RestMethod -Headers $llamaHeaders -Uri $u -TimeoutSec 30).data | ForEach-Object { $_.id } | Where-Object { $_ })
            if ($ids.Count -gt 0) { return @($ids | Where-Object { $_ -notmatch $SKIP_PATTERN } | Sort-Object) }
        } catch { }
    }
    return @()
}

function Test-ToolCall {
    # The probe: one prompt, one tool schema (test-toolcalls-engine.ps1 pins both),
    # sent to /v1/chat/completions. The call comes back in the OpenAI shape, so
    # `arguments` is a JSON string. max_tokens is generous because a reasoning
    # model spends its budget on the think block first.
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
            try { $null = Invoke-RestMethod -Headers $llamaHeaders -Uri "$EngineHost/models/unload" -Method Post -Body (@{ model = $Tag } | ConvertTo-Json) -ContentType "application/json" -TimeoutSec 60 } catch { }
        }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Headers $llamaHeaders -Uri "$EngineHost/v1/chat/completions" -Method Post -Body $body `
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

$targets = if ($Model) { $Model } else { Get-ChatModels }
if (-not $targets) { Write-Host "No chat models found at $EngineHost" -ForegroundColor Yellow; exit 1 }

Write-Host ""
Write-Host "=== Tool-calling probe against $EngineHost ($HostLabel, llama.cpp $engineVersion) ===" -ForegroundColor Cyan
Write-Host "    PASS = returns a structured tool_calls entry (safe for an agent seat)" -ForegroundColor Gray
Write-Host "    FAIL = empty tool_calls; will claim edits it never made" -ForegroundColor Gray
Write-Host ""

$results = foreach ($t in $targets) {
    Write-Host ("  probing {0} ..." -f $t) -ForegroundColor DarkGray
    $r = Test-ToolCall -Tag $t
    $color = switch ($r.Status) { "PASS" { "Green" } "FAIL" { "Red" } "WARN" { "Yellow" } default { "Magenta" } }
    Write-Host ("  [{0,-5}] {1,-26} {2,6}s  {3}" -f $r.Status, $r.Model, $r.Sec, $r.Detail) -ForegroundColor $color
    if (-not $NoLog) {
        if (-not (Test-Path -LiteralPath $LogFile) -or (Get-Item -LiteralPath $LogFile).Length -eq 0) {
            $script:LogHeader | Set-Content -LiteralPath $LogFile -Encoding utf8
        }
        # Tabs/newlines in model output would break the TSV.
        $detail = $r.Detail -replace '[\t\r\n]+', ' '
        $stamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
        $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f $stamp, $HostLabel, $Engine, $engineVersion, $r.Model, $r.Status, $r.Sec, $detail
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

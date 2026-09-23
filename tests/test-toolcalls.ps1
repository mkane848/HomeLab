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
#
# Every result is appended to tests/results/toolcalls-summary.tsv, tagged with
# the host and the Ollama version it ran against. A probe result is only valid
# for that version, and before this log they were recorded by hand
# (toolcalls-0.34.1.txt). -NoLog skips the append. run-tasks-batch.ps1 reads
# this file to show each model's last probe result in its menus.
#
# Exit code: 0 if every tested model passed, 1 otherwise.

param(
    [string[]]$Model,
    [string]$OllamaHost = "http://localhost:11434",
    # Short name for the host in the log: desktop / node3 / server. Matches the
    # opencode provider suffix (ollama-<label>). Defaults to "desktop" for
    # localhost, else the URL's host part.
    [string]$HostLabel,
    [string]$LogFile = (Join-Path $PSScriptRoot "results\toolcalls-summary.tsv"),
    [switch]$NoLog,
    [int]$TimeoutSec = 900,
    [switch]$KeepLoaded
)

$ErrorActionPreference = "Stop"

$OllamaHost = $OllamaHost -replace '/v1/?$', '' -replace '/$', ''
if (-not $HostLabel) {
    $HostLabel = if ($OllamaHost -match '//(localhost|127\.0\.0\.1)[:/]?') { "desktop" } else { ([uri]$OllamaHost).Host }
}
try   { $ollamaVersion = (Invoke-RestMethod -Uri "$OllamaHost/api/version" -TimeoutSec 10).version }
catch { $ollamaVersion = "unknown" }

# Embedding models have no chat endpoint; skip them.
$SKIP_PATTERN = 'embed|bge-|nomic|mxbai'

function Get-ChatModels {
    $r = Invoke-RestMethod -Uri "$OllamaHost/api/tags" -TimeoutSec 30
    return @($r.models | ForEach-Object { $_.name } | Where-Object { $_ -notmatch $SKIP_PATTERN } | Sort-Object)
}

function Test-ToolCall {
    param([string]$Tag)

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
Write-Host "=== Tool-calling probe against $OllamaHost ($HostLabel, Ollama $ollamaVersion) ===" -ForegroundColor Cyan
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
            "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail" | Set-Content -LiteralPath $LogFile -Encoding utf8
        }
        # Tabs/newlines in model output would break the TSV.
        $detail = $r.Detail -replace '[\t\r\n]+', ' '
        ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $HostLabel, $ollamaVersion, $r.Model, $r.Status, $r.Sec, $detail) |
            Add-Content -LiteralPath $LogFile -Encoding utf8
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

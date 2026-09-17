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
#   .\tests\test-toolcalls.ps1 -Model a,b -Host http://SERVER_IP:11434
#
# Exit code: 0 if every tested model passed, 1 otherwise.

param(
    [string[]]$Model,
    [string]$OllamaHost = "http://localhost:11434",
    [int]$TimeoutSec = 900,
    [switch]$KeepLoaded
)

$ErrorActionPreference = "Stop"

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
Write-Host "=== Tool-calling probe against $OllamaHost ===" -ForegroundColor Cyan
Write-Host "    PASS = returns a structured tool_calls entry (safe for an agent seat)" -ForegroundColor Gray
Write-Host "    FAIL = empty tool_calls; will claim edits it never made" -ForegroundColor Gray
Write-Host ""

$results = foreach ($t in $targets) {
    Write-Host ("  probing {0} ..." -f $t) -ForegroundColor DarkGray
    $r = Test-ToolCall -Tag $t
    $color = switch ($r.Status) { "PASS" { "Green" } "FAIL" { "Red" } "WARN" { "Yellow" } default { "Magenta" } }
    Write-Host ("  [{0,-5}] {1,-26} {2,6}s  {3}" -f $r.Status, $r.Model, $r.Sec, $r.Detail) -ForegroundColor $color
    $r
}

Write-Host ""
$pass = @($results | Where-Object Status -eq "PASS").Count
$total = @($results).Count
Write-Host ("Tool-capable: {0}/{1}" -f $pass, $total) -ForegroundColor $(if ($pass -eq $total) { "Green" } else { "Yellow" })
Write-Host ""

if (@($results | Where-Object Status -ne "PASS").Count -gt 0) { exit 1 }
exit 0

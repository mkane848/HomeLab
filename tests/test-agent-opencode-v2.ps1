# protects: The OpenCode adapter reading 2.x transcripts, config sources and compaction threshold
# run-after: tests/agents/opencode.ps1 or tests/agents/fixtures/opencode-v2/
# test-agent-opencode-v2.ps1 - the OpenCode adapter on OpenCode 2.x's output
#
# Why this exists: OpenCode 2.x (the desktop updated itself to v2.3.2 on
# 2026-11-21) changed what the harness reads (docs/opencode-2-migration.md):
#   - file tools take `path`, not `filePath`; the shell tool is `shell`;
#   - error events are {type, message, status, response.body}, and the
#     "context-overflow" classification 2.x makes internally is not in them;
#   - `debug config` lists config sources instead of one resolved config;
#   - compaction triggers at window - max(15%, 16000), with no limit.output term.
# A harness that misread any of these would count no edits, no overflows, no
# model limits, or a wrong threshold, and say nothing.
#
# What it does, with no opencode and no model:
#   1. Read-AgentEvents on transcripts captured from the real v2.3.2 against a
#      scripted stand-in model (tests/agents/fixtures/opencode-v2/).
#   2. Test-OpencodeOverflowText: the overflow wording, and the status rule.
#   3. ConvertFrom-OpencodeConfigSources on a source list shaped like v2.3.2's.
#   4. Get-CompactionThreshold's 2.x formula, against values worked by hand.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-agent-opencode-v2.ps1 [-AdapterPath <an opencode.ps1>]
param([string]$AdapterPath = (Join-Path $PSScriptRoot "agents\opencode.ps1"))

$ErrorActionPreference = "Stop"
. $AdapterPath
$fx = Join-Path $PSScriptRoot "agents\fixtures\opencode-v2"

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

Write-Host "-- 1. transcripts (v2.3.2, scripted model)"
$ev = (Read-AgentEvents -Path (Join-Path $fx "full.jsonl"))
$tools = @($ev | Where-Object Kind -eq "tool")
Check "four tool calls: read, write, edit, shell" (($tools | ForEach-Object Tool) -join ",") "read,write,edit,shell"
Check "all completed" (($tools | ForEach-Object Status) -join ",") "completed,completed,completed,completed"
Check "read/write/edit name their file through path" (($tools | ForEach-Object { $_.Paths -join ";" }) -join ",") 'C:\fixture\project\a.txt,C:\fixture\project\b.txt,C:\fixture\project\a.txt,'
$ends = @($ev | Where-Object Kind -eq "step-end")
Check "five step ends (one per tool call), the last one stop" (($ends | ForEach-Object Finish) -join ",") "tool-calls,tool-calls,tool-calls,tool-calls,stop"
Check "tokens read from step_finish" (($ends | ForEach-Object Input) -join ",") "500,600,700,800,900"
Check "the model's text" (@($ev | Where-Object Kind -eq "text")[0].Text) "FIXTURE-DONE"
$sids = @($ev | Where-Object SessionId | ForEach-Object SessionId | Sort-Object -Unique)
$fu = (Read-AgentEvents -Path (Join-Path $fx "followup.jsonl"))
Check "one session, and the --session follow-up stays on it" ("$($sids.Count) " + ([bool](@($fu | Where-Object SessionId)[0].SessionId -eq $sids[0]))) "1 True"
$ovAll = Read-AgentEvents -Path (Join-Path $fx "overflow.jsonl"); $ov = @($ovAll | Where-Object Kind -eq "error")
Check "llama-server's overflow 400 is a ContextOverflowError" ("$($ov.Count) $($ov[0].Name) $($ov[0].StatusCode)") "1 ContextOverflowError 400"
Check "...with its message" $ov[0].Message "the request exceeds the available context size, try increasing it"
$bmAll = Read-AgentEvents -Path (Join-Path $fx "badmodel.jsonl"); $bm = @($bmAll | Where-Object Kind -eq "error")
Check "an unknown model keeps 2.x's type" ("$($bm[0].Name)|$($bm[0].StatusCode)") "provider.no-route|"
Check "a 1.x error line still reads as before" ((Read-AgentEvents -Path (& {
    $f = Join-Path ([IO.Path]::GetTempPath()) ("v1err-" + [guid]::NewGuid().ToString("N") + ".jsonl")
    Set-Content -LiteralPath $f -Value '{"type":"error","sessionID":"s","error":{"name":"APIError","data":{"message":"m","statusCode":402,"metadata":{"url":"u"}}}}'
    $f }))[0] | ForEach-Object { "$($_.Name)|$($_.Message)|$($_.StatusCode)|$($_.Url)" }) "APIError|m|402|u"
$v2402 = Join-Path ([IO.Path]::GetTempPath()) ("v2err-" + [guid]::NewGuid().ToString("N") + ".jsonl")
Set-Content -LiteralPath $v2402 -Value '{"type":"error","sessionID":"s","error":{"type":"provider.quota","message":"insufficient balance","status":402}}'
Check "a 2.x 402 keeps its status (the Go spend gate reads it)" ((Read-AgentEvents -Path $v2402)[0] | ForEach-Object { "$($_.Name)|$($_.StatusCode)" }) "provider.quota|402"
Remove-Item -LiteralPath $v2402 -ErrorAction SilentlyContinue

Write-Host "-- 2. the overflow rule (packages/ai/src/provider-error.ts at v2.3.2)"
Check "llama.cpp wording, 400"         (Test-OpencodeOverflowText -Text "the request exceeds the available context size" -Status 400) "True"
Check "Ollama/OpenAI wording, no status" (Test-OpencodeOverflowText -Text "This model's maximum context length is 8192 tokens") "True"
Check "the same wording as a 429 is a throttle" (Test-OpencodeOverflowText -Text "the request exceeds the available context size" -Status 429) "False"
Check "...and as a 500 is not client-scoped" (Test-OpencodeOverflowText -Text "the request exceeds the available context size" -Status 500) "False"
Check "an exclusion wins (rate limit)" (Test-OpencodeOverflowText -Text "rate limit: too many tokens" -Status 400) "False"
Check "a bodiless 413"                 (Test-OpencodeOverflowText -Text "413 status code (no body)") "True"
Check "an unrelated 400"               (Test-OpencodeOverflowText -Text "invalid tool schema" -Status 400) "False"

Write-Host "-- 3. config sources (shaped like v2.3.2's debug config)"
$sources = @(
    [pscustomobject]@{ type = "document"; path = "global"; info = [pscustomobject]@{
        model = [pscustomobject]@{ providerID = "p"; model = "m" }; update = "notify"
        plugins = @("file:///a"); permissions = @([pscustomobject]@{ action = "edit"; resource = "*"; effect = "ask" })
        providers = [pscustomobject]@{ p = [pscustomobject]@{ models = [pscustomobject]@{ m = [pscustomobject]@{ limit = [pscustomobject]@{ context = 65536; output = 8192 } } } } } } }
    [pscustomobject]@{ type = "directory"; path = "dir" }
    [pscustomobject]@{ type = "document"; path = "overlay"; info = [pscustomobject]@{
        plugins = @("file:///b"); compaction = [pscustomobject]@{ buffer = "20%" }
        providers = [pscustomobject]@{ p = [pscustomobject]@{ models = [pscustomobject]@{ m = [pscustomobject]@{ limit = [pscustomobject]@{ output = 4096 } }; n = [pscustomobject]@{ limit = [pscustomobject]@{ context = 32768 } } } } } } }
)
$cfg = ConvertFrom-OpencodeConfigSources -Sources $sources
Check "marked as 2.x" $cfg._opencodeMajor 2
Check "providers merged, later wins per key" ("$($cfg.provider.p.models.m.limit.context)/$($cfg.provider.p.models.m.limit.output)") "65536/4096"
Check "model ids from every source" (((Get-AgentModelIds -Config $cfg).Keys | Sort-Object) -join ",") "p/m,p/n"
Check "plugins append across sources" ($cfg.plugin -join ",") "file:///a,file:///b"
Check "update notify -> autoupdate notify (pinned)" ("$($cfg.autoupdate) " + (Test-AgentAutoupdatePinned -Config $cfg -EnvValue "")) "notify True"
Check "update disable -> pinned" (Test-AgentAutoupdatePinned -Config (ConvertFrom-OpencodeConfigSources -Sources @([pscustomobject]@{ type = "document"; info = [pscustomobject]@{ update = "disable" } })) -EnvValue "") "True"
Check "update auto -> not pinned" (Test-AgentAutoupdatePinned -Config (ConvertFrom-OpencodeConfigSources -Sources @([pscustomobject]@{ type = "document"; info = [pscustomobject]@{ update = "auto" } })) -EnvValue "") "False"

Write-Host "-- 4. the 2.x compaction threshold (calculateCeiling, v2.3.2)"
function T($context, $output = 4096, $buffer = $null, $inputLimit = $null) {
    $lim = [ordered]@{ context = $context; output = $output }; if ($inputLimit) { $lim.input = $inputLimit }
    $info = [ordered]@{ providers = @{ p = @{ models = @{ m = @{ limit = $lim } } } } }
    if ($null -ne $buffer) { $info.compaction = @{ buffer = $buffer } }
    $c = ConvertFrom-OpencodeConfigSources -Sources @([pscustomobject]@{ type = "document"; info = ([pscustomobject]$info | ConvertTo-Json -Depth 10 | ConvertFrom-Json) })
    return (Get-CompactionThreshold -Config $c -ModelId "p/m").threshold
}
Check "64k, no buffer: 65536 - 16000"            (T 65536) 49536
Check "limit.output does not move it"            (T 65536 16384) 49536
Check "32k: the 16000 floor"                     (T 32768) 16768
Check "16k: below 32000, 15% only"               (T 16384) 13927
Check 'buffer "20%": round(13107.2)'             (T 65536 4096 "20%") 52429
Check "buffer 8000 tokens"                       (T 65536 4096 8000) 57536
Check "a buffer >= the window is ignored"        (T 65536 4096 70000) 49536
Check "limit.input below the context is the window" (T 65536 4096 $null 40000) 24000

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"

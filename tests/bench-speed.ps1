# bench-speed.ps1 - prefill and decode speed of one seat on one host, at depth.
#
# Why this exists: "the server is faster" rested on wall-clock per task, which mixes
# the engine with how much work the model chose to do (the server's two early-stopped
# runs were also its fastest). This asks the host the same question at the same
# prompt sizes, so two hosts, or two engines, compare on tokens per second:
#   - cold load: the first request (about 600 tokens in, one out), which also
#     calibrates characters per token for this model's tokenizer; no speeds are
#     logged for it, a one-token generation measures nothing;
#   - at each -PromptTokens size: prefill tok/s and decode tok/s, from
#     llama-server's `timings` (prompt_n over prompt_ms, predicted_n over
#     predicted_ms) on /v1/chat/completions.
# Every prompt starts with a fresh nonce and is sent with `cache_prompt` off, so a
# prefix hit can't make a repeat look fast. Sizes above ~92% of the served context
# (less -NumPredict) are skipped and logged: llama-server rejects a request over
# it, and a size at the edge would measure a different prompt.
#
# llama.cpp is the only local engine (Ollama was removed on 2026-11-21); -Engine
# accepts llamacpp only. What to know about the numbers:
#   - placement: llama-server reports none per model, so totalGB / vramGB /
#     gpuShare are empty (the columns stay for the Ollama-era rows, which read
#     them from /api/ps); read `nvidia-smi` on the host and the server's offload
#     log line by hand;
#   - loadS is approximate: the request's wall time minus llama-server's own
#     prompt + predict time (the router loads a model on its first request);
#   - num_ctx comes from /props (default_generation_settings.n_ctx).
#
# Rows are appended to tests/results/bench-speed.tsv (-NoLog skips); its columns
# are unchanged, so the older rows still read. No prompt text, only sizes and
# speeds, so the file is public-safe.
#
# Usage:
#   .\tests\bench-speed.ps1 -EngineHost http://SERVER_IP:8090 -HostLabel server -Model qwen3.6:35b-a3b-coding
#   .\tests\bench-speed.ps1 -EngineHost http://NODE3_IP:8090 -HostLabel node3 -Model qwen3.6:35b-a3b-coding -PromptTokens 3000,30000
# Exit 1 if any request failed (the row is still logged, with the error as its note).
param(
    # llama-server's root URL (a trailing /v1 is accepted).
    [Parameter(Mandatory)][string]$EngineHost,
    [Parameter(Mandatory)][string]$HostLabel,
    [Parameter(Mandatory)][string]$Model,
    # Comma-separated: `pwsh -File` does not split an array argument.
    [string]$PromptTokens = "3000,30000,60000",
    [int]$Reps = 1,
    [int]$NumPredict = 128,
    [string]$Engine = "llamacpp",
    [string]$ResultsFile = (Join-Path $PSScriptRoot "results/bench-speed.tsv"),
    [switch]$NoLog,
    [int]$TimeoutSec = 900
)

$ErrorActionPreference = "Stop"
$script:Columns = @("timestamp", "host", "engine", "engineVersion", "model", "numCtx", "targetTokens", "promptTokens",
                    "loadS", "prefillTokS", "decodeTokS", "evalTokens", "totalGB", "vramGB", "gpuShare", "note")

function New-BenchPrompt {
    # About $Tokens tokens of filler under a fresh nonce, then a fixed instruction
    # that makes the model decode a predictable stream. $CharsPerToken is a
    # running estimate, corrected after each measured request.
    param([int]$Tokens, [double]$CharsPerToken, [string]$Nonce)
    $words = @("amber", "river", "stone", "lantern", "meadow", "copper", "harbor", "willow", "ember", "quartz", "falcon", "thistle")
    $rng = New-Object System.Random ([math]::Abs($Nonce.GetHashCode()))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("Benchmark nonce $Nonce. The numbered lines below are filler; ignore them.`n")
    $want = [int]($Tokens * $CharsPerToken)
    $i = 0
    while ($sb.Length -lt $want) {
        $i++
        [void]$sb.Append(("Line {0:D5}: {1} {2} {3} {4}.`n" -f $i, $words[$rng.Next($words.Count)], $words[$rng.Next($words.Count)], $rng.Next(1000, 9999), $words[$rng.Next($words.Count)]))
    }
    [void]$sb.Append("`nNow write the integers from 1 to 100 separated by single spaces, and nothing else.")
    return $sb.ToString()
}

function Get-BenchMetricsLlama {
    # Speeds from one llama-server /v1/chat/completions reply. Its `timings` are
    # milliseconds and token counts of what was actually evaluated: prompt_n
    # excludes tokens served from the prompt cache (cache_n), so prefill is
    # prompt_n over prompt_ms. A speed needs enough tokens behind it: a one-token
    # generation lasts microseconds and reads as a million tokens a second, so
    # below 64 prompt tokens or 8 generated ones the speed is null (the first real
    # run logged exactly that). $WallS is the request's wall time; loadS is what is
    # left after llama-server's own prompt and predict time, so it is approximate.
    param($Reply, [double]$WallS = 0)
    $t = $Reply.timings
    $perSec = { param($count, $ms, $min) if ($count -ge $min -and $ms -gt 0) { [math]::Round($count / ($ms / 1000.0), 1) } else { $null } }
    $promptN = [int]$t.prompt_n; $cacheN = [int]$t.cache_n
    $total = if ($null -ne $Reply.usage -and $null -ne $Reply.usage.prompt_tokens) { [int]$Reply.usage.prompt_tokens } else { $promptN + $cacheN }
    $own = ([double]$t.prompt_ms + [double]$t.predicted_ms) / 1000.0
    [pscustomobject]@{
        PromptTokens = $total
        EvalTokens   = [int]$t.predicted_n
        LoadS        = [math]::Round([math]::Max(0.0, $WallS - $own), 1)
        PrefillTokS  = (& $perSec $promptN $t.prompt_ms 64)
        DecodeTokS   = (& $perSec $t.predicted_n $t.predicted_ms 8)
        CacheN       = $cacheN
    }
}

function Add-BenchRow {
    # One TSV line, in $script:Columns order; the header is written when the file is new or empty.
    param([string]$Path, [hashtable]$Row)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text = ""
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) { $text += ($script:Columns -join "`t") + "`n" }
    $text += (($script:Columns | ForEach-Object { $v = $Row[$_]; if ($null -eq $v) { "" } else { ("$v" -replace "[`t`r`n]+", " ") } }) -join "`t") + "`n"
    [IO.File]::AppendAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

if ($Engine -ne "llamacpp") {
    Write-Host "bench-speed.ps1 supports only -Engine llamacpp, not '$Engine'." -ForegroundColor Red
    exit 2
}
$root = $EngineHost.TrimEnd('/') -replace '/v1$', ''
$targets = @($PromptTokens -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($targets.Count -eq 0 -or $Reps -lt 1) { Write-Host "no prompt sizes, or -Reps below 1" -ForegroundColor Red; exit 2 }

$numCtx = $null
# llama-server's API key (docs/engine-api-keys.md).
. (Join-Path $PSScriptRoot "engines/llamacpp-auth.ps1")
$llamaHeaders = Get-LlamacppHeaders

# /props carries the build and the served context. In router mode it wants the
# model as a query parameter, so ask that way first and fall back to the bare path.
$props = $null
# (The parentheses matter: in @("a" + $x, "b") the comma binds tighter than +, which
# would fuse both URLs into one string.)
$propsUrls = @(("$root/props?model=" + [uri]::EscapeDataString($Model)), "$root/props")
foreach ($u in $propsUrls) {
    try { $props = Invoke-RestMethod -Headers $llamaHeaders -Uri $u -TimeoutSec 10; if ($props) { break } } catch { }
}
$version = if ($props -and $props.build_info) { [string]$props.build_info } else { "unknown" }
if ($props) {
    $n = if ($props.default_generation_settings -and $props.default_generation_settings.n_ctx) { $props.default_generation_settings.n_ctx } else { $props.n_ctx }
    if ($n) { $numCtx = [int]$n }
}
Write-Host ("bench-speed: {0} on {1} ({2}) | {3} {4} | num_ctx {5}" -f $Model, $HostLabel, $root, $Engine, $version, $(if ($numCtx) { $numCtx } else { "unknown" })) -ForegroundColor DarkGray

$script:Failed = 0
function Measure-Request([string]$Prompt, [int]$Predict) {
    # One timed request to /v1/chat/completions, as the metrics object the rest of the script reads.
    $body = @{ model = $Model; messages = @(@{ role = "user"; content = $Prompt }); max_tokens = $Predict
               temperature = 0; seed = 1; stream = $false; cache_prompt = $false } | ConvertTo-Json -Depth 6
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $reply = Invoke-RestMethod -Headers $llamaHeaders -Uri "$root/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec
    $sw.Stop()
    return (Get-BenchMetricsLlama $reply $sw.Elapsed.TotalSeconds)
}
# llama-server reports no per-model placement: the placement columns stay blank.
$script:NoPlacement = @{ Total = $null; Vram = $null; Share = $null }
function Save-Row([hashtable]$Row) {
    $Row.timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss"); $Row.host = $HostLabel; $Row.engine = $Engine
    $Row.engineVersion = $version; $Row.model = $Model; $Row.numCtx = $numCtx
    if (-not $NoLog) { Add-BenchRow -Path $ResultsFile -Row $Row }
}
function Show-Row([string]$What, $m, $pl, [switch]$NoSpeeds) {
    $pre = if ($NoSpeeds -or $null -eq $m.PrefillTokS) { "n/a" } else { $m.PrefillTokS }
    $dec = if ($NoSpeeds -or $null -eq $m.DecodeTokS) { "n/a" } else { $m.DecodeTokS }
    Write-Host ("  {0,-22} prompt {1,6} tok | load {2,5} s | prefill {3,8} tok/s | decode {4,6} tok/s | {5} GB, {6} GB in VRAM ({7})" -f $What, $m.PromptTokens, $m.LoadS, $pre, $dec, $pl.Total, $pl.Vram, $(if ($null -ne $pl.Share) { "{0:P0}" -f $pl.Share } else { "n/a" }))
}

# Cold load and calibration in one request: a ~600-token prompt, one token out.
# loadS is roughly the time llama-server took to bring the seat in (small when it
# was already loaded). The prompt's size tells how many characters a token is on this model's
# tokenizer, so even the first measured size lands near its target; the filler
# tokenises at ~2 chars/token, not the 3.0 it starts from. No speeds are logged for
# it: a one-token generation measures nothing.
$charsPerToken = 3.0
try {
    $warmPrompt = New-BenchPrompt -Tokens 600 -CharsPerToken $charsPerToken -Nonce ([guid]::NewGuid().ToString("N").Substring(0, 12))
    $m = Measure-Request $warmPrompt 1
    if ($m.PromptTokens -ge 64) { $charsPerToken = [math]::Max(1.0, $warmPrompt.Length / $m.PromptTokens) }
    $pl = $script:NoPlacement
    Show-Row "load / calibration" $m $pl -NoSpeeds
    $warmNote = "warm-up (load, chars-per-token calibration); loadS approximate; placement not reported by llama-server"
    Save-Row @{ targetTokens = 0; promptTokens = $m.PromptTokens; loadS = $m.LoadS; evalTokens = $m.EvalTokens
                totalGB = $pl.Total; vramGB = $pl.Vram; gpuShare = $pl.Share; note = $warmNote }
} catch {
    $script:Failed++
    Write-Host "  warm-up failed: $($_.Exception.Message)" -ForegroundColor Red
    Save-Row @{ targetTokens = 0; note = "FAILED warm-up: $($_.Exception.Message)" }
}

foreach ($rep in 1..$Reps) {
    foreach ($target in $targets) {
        if ($numCtx -and ($target + $NumPredict) -gt [int]($numCtx * 0.92)) {
            Write-Host ("  {0,6} tokens: skipped, over 92% of num_ctx {1} (llama-server would reject it)" -f $target, $numCtx) -ForegroundColor Yellow
            Save-Row @{ targetTokens = $target; note = "skipped: over 92% of num_ctx $numCtx" }
            continue
        }
        $nonce = [guid]::NewGuid().ToString("N").Substring(0, 12)
        $prompt = New-BenchPrompt -Tokens $target -CharsPerToken $charsPerToken -Nonce $nonce
        try {
            $m = Measure-Request $prompt $NumPredict
            $pl = $script:NoPlacement
            if ($m.PromptTokens -gt 0) { $charsPerToken = [math]::Max(1.0, $prompt.Length / $m.PromptTokens) }
            Show-Row ("{0} tok (rep {1})" -f $target, $rep) $m $pl
            $note = "rep $rep"
            # A prompt-cache hit would inflate prefill; cache_prompt is off, so any cache_n is worth saying.
            if ($m.CacheN -gt 0) { $note += "; $($m.CacheN) prompt tokens came from the cache" }
            Save-Row @{ targetTokens = $target; promptTokens = $m.PromptTokens; loadS = $m.LoadS; prefillTokS = $m.PrefillTokS; decodeTokS = $m.DecodeTokS
                        evalTokens = $m.EvalTokens; totalGB = $pl.Total; vramGB = $pl.Vram; gpuShare = $pl.Share; note = $note }
        } catch {
            $script:Failed++
            Write-Host "  $target tokens failed: $($_.Exception.Message)" -ForegroundColor Red
            Save-Row @{ targetTokens = $target; note = "FAILED rep ${rep}: $($_.Exception.Message)" }
        }
    }
}
if (-not $NoLog) { Write-Host "rows appended to $ResultsFile" -ForegroundColor DarkGray }
exit $(if ($script:Failed) { 1 } else { 0 })

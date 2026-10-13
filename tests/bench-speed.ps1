# bench-speed.ps1 - prefill and decode speed of one seat on one host, at depth.
#
# Why this exists: "the server is faster" rested on wall-clock per task, which mixes
# the engine with how much work the model chose to do (the server's two early-stopped
# runs were also its fastest). This asks the host the same question at the same
# prompt sizes, so two hosts, or two engines, compare on tokens per second:
#   - cold load: the first request (about 600 tokens in, one out), which also
#     calibrates characters per token for this model's tokenizer; no speeds are
#     logged for it, a one-token generation measures nothing;
#   - at each -PromptTokens size: prefill tok/s (prompt_eval_count over
#     prompt_eval_duration) and decode tok/s (eval_count over eval_duration),
#     with the placement /api/ps reports right after (total GB, GB in VRAM).
# Every prompt starts with a fresh nonce, so Ollama's prefix cache can't make a
# repeat look fast. Sizes above ~92% of the seat's baked num_ctx (less -NumPredict)
# are skipped and logged, because a request over num_ctx is silently cut from the
# front and would measure a different prompt.
#
# Ollama only (/api/generate). llama-server gets its own path in the engine trial
# (docs/roadmap.md -> "Replacing Ollama"), tested against a real one; `-Engine`
# is already a column in the results so the rows compare.
#
# Rows are appended to tests/results/bench-speed.tsv (-NoLog skips). No prompt
# text, only sizes and speeds, so the file is public-safe.
#
# Usage:
#   .\tests\bench-speed.ps1 -OllamaHost http://SERVER_IP:11434 -HostLabel server -Model qwen3.6:35b-a3b-coding
#   .\tests\bench-speed.ps1 -OllamaHost http://localhost:11434 -HostLabel desktop -Model qwen3.6:35b-a3b-coding -PromptTokens 3000,30000
# Exit 1 if any request failed (the row is still logged, with the error as its note).
param(
    [Parameter(Mandatory)][string]$OllamaHost,
    [Parameter(Mandatory)][string]$HostLabel,
    [Parameter(Mandatory)][string]$Model,
    # Comma-separated: `pwsh -File` does not split an array argument.
    [string]$PromptTokens = "3000,30000,60000",
    [int]$Reps = 1,
    [int]$NumPredict = 128,
    [string]$Engine = "ollama",
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

function Get-BenchMetrics {
    # Speeds from one /api/generate reply (durations are nanoseconds).
    # A speed needs enough tokens behind it: a one-token generation lasts
    # microseconds and reads as a million tokens a second, so below 64 prompt tokens
    # or 8 generated ones the speed is null (the first real run logged exactly that).
    param($Reply)
    $perSec = { param($count, $ns, $min) if ($count -ge $min -and $ns -gt 0) { [math]::Round($count / ($ns / 1e9), 1) } else { $null } }
    [pscustomobject]@{
        PromptTokens = [int]$Reply.prompt_eval_count
        EvalTokens   = [int]$Reply.eval_count
        LoadS        = [math]::Round([double]$Reply.load_duration / 1e9, 1)
        PrefillTokS  = (& $perSec $Reply.prompt_eval_count $Reply.prompt_eval_duration 64)
        DecodeTokS   = (& $perSec $Reply.eval_count $Reply.eval_duration 8)
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

if ($Engine -ne "ollama") {
    Write-Host "bench-speed.ps1 supports -Engine ollama only; llama-server arrives with the engine trial (docs/roadmap.md -> `"Replacing Ollama`")." -ForegroundColor Red
    exit 2
}
$root = $OllamaHost.TrimEnd('/') -replace '/v1$', ''
$targets = @($PromptTokens -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($targets.Count -eq 0 -or $Reps -lt 1) { Write-Host "no prompt sizes, or -Reps below 1" -ForegroundColor Red; exit 2 }

$version = try { [string](Invoke-RestMethod -Uri "$root/api/version" -TimeoutSec 10).version } catch { "unknown" }
$numCtx = $null
try {
    $show = Invoke-RestMethod -Uri "$root/api/show" -Method Post -ContentType "application/json" -Body (@{ model = $Model } | ConvertTo-Json) -TimeoutSec 10
    $line = @($show.parameters -split "`n" | Where-Object { $_ -match '^\s*num_ctx\s+(\d+)' })
    if ($line.Count -gt 0 -and $line[0] -match '(\d+)\s*$') { $numCtx = [int]$Matches[1] }
} catch { }
Write-Host ("bench-speed: {0} on {1} ({2}) | ollama {3} | num_ctx {4}" -f $Model, $HostLabel, $root, $version, $(if ($numCtx) { $numCtx } else { "unknown" })) -ForegroundColor DarkGray

$script:Failed = 0
function Invoke-Generate([string]$Prompt, [int]$Predict) {
    $body = @{ model = $Model; prompt = $Prompt; stream = $false; options = @{ num_predict = $Predict; temperature = 0; seed = 1 } } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri "$root/api/generate" -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec
}
function Get-Placement {
    # The same /api/ps query and arithmetic as Get-OllamaGpuPlacement in
    # test-tasks.ps1, kept as a copy on purpose: this script runs on its own, and
    # test-tasks.ps1 is a script the guards read function by function, not a module.
    # Change one, change the other (name or model match, bytes to GB, share).
    try {
        $m = @((Invoke-RestMethod -Uri "$root/api/ps" -TimeoutSec 10).models | Where-Object { $_ -and (($_.name -ieq $Model) -or ($_.model -ieq $Model)) })
        if ($m.Count -eq 0) { return @{ Total = $null; Vram = $null; Share = $null } }
        $t = [double]$m[0].size; $v = [double]$m[0].size_vram
        return @{ Total = [math]::Round($t / 1e9, 2); Vram = [math]::Round($v / 1e9, 2); Share = $(if ($t -gt 0) { [math]::Round($v / $t, 3) } else { $null }) }
    } catch { return @{ Total = $null; Vram = $null; Share = $null } }
}
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
# loadS is the time Ollama took to bring the seat in (small when it was already
# loaded). The prompt's size tells how many characters a token is on this model's
# tokenizer, so even the first measured size lands near its target; the filler
# tokenises at ~2 chars/token, not the 3.0 it starts from. No speeds are logged for
# it: a one-token generation measures nothing.
$charsPerToken = 3.0
try {
    $warmPrompt = New-BenchPrompt -Tokens 600 -CharsPerToken $charsPerToken -Nonce ([guid]::NewGuid().ToString("N").Substring(0, 12))
    $m = Get-BenchMetrics (Invoke-Generate $warmPrompt 1)
    if ($m.PromptTokens -ge 64) { $charsPerToken = [math]::Max(1.0, $warmPrompt.Length / $m.PromptTokens) }
    $pl = Get-Placement
    Show-Row "load / calibration" $m $pl -NoSpeeds
    Save-Row @{ targetTokens = 0; promptTokens = $m.PromptTokens; loadS = $m.LoadS; evalTokens = $m.EvalTokens
                totalGB = $pl.Total; vramGB = $pl.Vram; gpuShare = $pl.Share; note = "warm-up (load, chars-per-token calibration)" }
} catch {
    $script:Failed++
    Write-Host "  warm-up failed: $($_.Exception.Message)" -ForegroundColor Red
    Save-Row @{ targetTokens = 0; note = "FAILED warm-up: $($_.Exception.Message)" }
}

foreach ($rep in 1..$Reps) {
    foreach ($target in $targets) {
        if ($numCtx -and ($target + $NumPredict) -gt [int]($numCtx * 0.92)) {
            Write-Host ("  {0,6} tokens: skipped, over 92% of num_ctx {1} (a request over num_ctx is cut from the front)" -f $target, $numCtx) -ForegroundColor Yellow
            Save-Row @{ targetTokens = $target; note = "skipped: over 92% of num_ctx $numCtx" }
            continue
        }
        $nonce = [guid]::NewGuid().ToString("N").Substring(0, 12)
        $prompt = New-BenchPrompt -Tokens $target -CharsPerToken $charsPerToken -Nonce $nonce
        try {
            $m = Get-BenchMetrics (Invoke-Generate $prompt $NumPredict)
            $pl = Get-Placement
            if ($m.PromptTokens -gt 0) { $charsPerToken = [math]::Max(1.0, $prompt.Length / $m.PromptTokens) }
            Show-Row ("{0} tok (rep {1})" -f $target, $rep) $m $pl
            Save-Row @{ targetTokens = $target; promptTokens = $m.PromptTokens; loadS = $m.LoadS; prefillTokS = $m.PrefillTokS; decodeTokS = $m.DecodeTokS
                        evalTokens = $m.EvalTokens; totalGB = $pl.Total; vramGB = $pl.Vram; gpuShare = $pl.Share; note = "rep $rep" }
        } catch {
            $script:Failed++
            Write-Host "  $target tokens failed: $($_.Exception.Message)" -ForegroundColor Red
            Save-Row @{ targetTokens = $target; note = "FAILED rep ${rep}: $($_.Exception.Message)" }
        }
    }
}
if (-not $NoLog) { Write-Host "rows appended to $ResultsFile" -ForegroundColor DarkGray }
exit $(if ($script:Failed) { 1 } else { 0 })

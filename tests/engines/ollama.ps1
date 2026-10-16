# tests/engines/ollama.ps1 - the Ollama adapter for the task harness.
#
# Everything test-tasks.ps1 needs to know about the engine that serves a model
# lives in one file per engine, here. The grading and the analysis of a run are
# engine-neutral; the harness picks the adapter from the provider prefix of
# -Model (`ollama-*` -> this file, `llamacpp-*` -> llamacpp.ps1; any other
# provider, a hosted one say, loads this file and finds no base URL, so it
# records "not checked" exactly as before). Mirrors tests/agents/opencode.ps1.
# Results from another engine are a new era (the run JSON records `engine`).
#
# The interface every engine adapter provides (dot-sourced; functions and
# $script: variables land in the caller's scope):
#   $script:EngineName                  "ollama"
#   Get-EngineBaseUrlVar -ProviderId    the env var that holds this provider's base URL, or $null
#                                       when the provider is not this engine's
#   Get-EngineBaseUrl -ProviderId       the host's root URL from that variable (a trailing
#                                       /v1 and slashes stripped), or $null when it is unset
#   Test-EngineAlive -Root              $true when the host answers
#   Get-EngineVersion -Root             the engine's version string, or $null
#   Format-EngineVersion -ProviderId -Root -Version
#                                       the human line the console and the legacy
#                                       `ollamaVersion` field carry ("ollama version is 0.34.3",
#                                       "unknown (...)", "n/a (...)")
#   Get-EngineServedModels -Root        ids the host serves, or $null when it does not answer
#   Get-EngineServedContext -Root -Tag  the context window the host serves the model with:
#                                       an [int], or a string saying why not
#   Get-EnginePromptLossSetup -Root -LogDir -ProviderId
#                                       { Enabled; LogDir; Description }: whether and how a prompt
#                                       the engine cut silently can be detected after a run
#   Get-EnginePromptLoss -Setup -Since -Until
#                                       the log lines that show a silent loss in that window
#   Get-EnginePromptLossText -Hits      one sentence naming the loss, for the FAIL line
#   Get-EngineGpuPlacement -ProviderId -Root -Tag
#                                       { Verdict gpu|cpu-only|not-loaded|unchecked; Model;
#                                         TotalBytes; VramBytes; Share; Detail }
# Ollama-only internals the guards load directly: Get-OllamaGpuPlacement,
# Get-OllamaPromptTruncation.

$script:EngineName = "ollama"

function Get-EngineBaseUrlVar {
    param([string]$ProviderId)
    switch ($ProviderId) {
        "ollama-desktop" { "OLLAMA_DESKTOP_BASE_URL" }
        "ollama-server"  { "OLLAMA_SERVER_BASE_URL" }
        "ollama-node3"   { "OLLAMA_NODE3_BASE_URL" }
        default          { $null }
    }
}

function Get-EngineBaseUrl {
    param([string]$ProviderId)
    $var = Get-EngineBaseUrlVar -ProviderId $ProviderId
    if (-not $var) { return $null }
    $base = [Environment]::GetEnvironmentVariable($var)
    if (-not $base) { return $null }
    return ($base.TrimEnd('/') -replace '/v1$', '')
}

function Test-EngineAlive {
    param([string]$Root, [int]$TimeoutSec = 10)
    try { $null = Invoke-RestMethod -Uri "$Root/api/tags" -TimeoutSec $TimeoutSec; return $true } catch { return $false }
}

function Get-EngineVersion {
    param([string]$Root)
    try { return [string](Invoke-RestMethod -Uri "$Root/api/version" -TimeoutSec 10).version } catch { return $null }
}

function Format-EngineVersion {
    # The "ollama version is X" shape is kept so existing result files compare.
    param([string]$ProviderId, [string]$Root, [string]$Version)
    $var = Get-EngineBaseUrlVar -ProviderId $ProviderId
    if (-not $var)  { return "n/a ($ProviderId is not an Ollama provider)" }
    if (-not $Root) { return "unknown ($var is unset)" }
    if ($Version)   { return "ollama version is $Version" }
    return "unknown ($Root/api/version unreachable)"
}

function Get-EngineServedModels {
    param([string]$Root)
    try {
        $r = Invoke-RestMethod -Uri "$Root/api/tags" -TimeoutSec 10
        return @($r.models | ForEach-Object { $_.name } | Where-Object { $_ })
    } catch { return $null }
}

function Get-EngineServedContext {
    # The context window baked into the served model (/api/show parameters). It
    # is not part of the prompt hash, so without this stamp a 32k run and a 64k
    # run of the same task are indistinguishable afterwards (the 64k context
    # trial, docs/roadmap.md -> "Context budget").
    param([string]$Root, [string]$Tag)
    try {
        $showBody = @{ model = $Tag } | ConvertTo-Json
        $show = Invoke-RestMethod -Uri "$Root/api/show" -Method Post -ContentType "application/json" -Body $showBody -TimeoutSec 10
        $ctxLine = @($show.parameters -split "`n" | Where-Object { $_ -match '^\s*num_ctx\s+(\d+)' })
        if ($ctxLine.Count -gt 0 -and $ctxLine[0] -match '(\d+)\s*$') { return [int]$Matches[1] }
        return "unset (server default)"
    } catch {
        return "unknown (/api/show failed)"
    }
}

function Get-EnginePromptLossSetup {
    # Prompt-truncation check (Get-OllamaPromptTruncation): Ollama-specific, and
    # only a local Ollama's server.log is readable from here. Every graded run
    # records which it was, so another engine records "not checked", not a clean.
    param([string]$Root, [string]$LogDir, [string]$ProviderId)
    $dir = $null
    if ($LogDir) {
        $dir = $LogDir
    } elseif ($Root -and @("localhost", "127.0.0.1", "::1") -contains ([uri]$Root).Host) {
        $dir = Join-Path $env:LOCALAPPDATA "Ollama"
    }
    $enabled = $false
    $desc = if ($dir -and (Test-Path -LiteralPath $dir)) {
        $enabled = $true
        "checked Ollama server.log in $dir"
    } elseif ($dir) {
        $dir = $null; "not checked (no Ollama log directory at $dir)"
    } elseif ($Root) {
        "not checked ($Root is not local; its server.log is on that host)"
    } else {
        "not checked (no truncation detector for engine 'unknown', provider $ProviderId)"
    }
    return [pscustomobject]@{ Enabled = $enabled; LogDir = $dir; Description = $desc }
}

function Get-EnginePromptLoss {
    param($Setup, [DateTimeOffset]$Since, [DateTimeOffset]$Until)
    if (-not $Setup -or -not $Setup.Enabled) { return @() }
    return @(Get-OllamaPromptTruncation -LogDir $Setup.LogDir -Since $Since -Until $Until)
}

function Get-EnginePromptLossText {
    param($Hits)
    $what = (@($Hits)[0] -replace '^.*msg="truncating input prompt"\s*', '').Trim()
    return ("Ollama truncated the prompt {0} time(s) during the run ({1})" -f @($Hits).Count, $what)
}

function Get-EngineGpuPlacement {
    param([string]$ProviderId, [string]$Root, [string]$Tag)
    return (Get-OllamaGpuPlacement -Root $Root -Tag $Tag)
}

function Get-OllamaGpuPlacement {
    # Where an Ollama host has the model $Tag loaded, from /api/ps: its total
    # size and the part of it in VRAM. Verdicts:
    #   "gpu"        some of it is in VRAM (a 35B MoE on a 16 GB card is split:
    #                60% on the server's 4070 Ti SUPER, 12.5 of 21 GB on the desktop)
    #   "cpu-only"   loaded, and none of it in VRAM: the host was not using its GPU
    #   "not-loaded" /api/ps answers but the model is not in it (unloaded already)
    #   "unchecked"  /api/ps did not answer
    # A container that lost its GPU keeps answering from the CPU (2026-10-12:
    # qwen3.6 at 38 GB, 100% CPU), so nothing else in a run notices. Only the
    # model asked about counts: the CPU-pinned 3b beside it is 0% GPU by design.
    param([string]$Root, [string]$Tag, [int]$TimeoutSec = 10)
    $want = if ($Tag -match ':') { $Tag } else { "${Tag}:latest" }
    $result = { param($verdict, $total, $vram, $detail)
        $share = if ($null -ne $total -and $total -gt 0) { [math]::Round($vram / $total, 3) } else { $null }
        [pscustomobject]@{ Verdict = $verdict; Model = $want; TotalBytes = $total; VramBytes = $vram; Share = $share; Detail = $detail } }
    try {
        $ps = Invoke-RestMethod -Uri "$Root/api/ps" -TimeoutSec $TimeoutSec
    } catch {
        return (& $result "unchecked" $null $null "$Root/api/ps did not answer")
    }
    $loaded = @($ps.models | Where-Object { $_ -and (($_.name -ieq $want) -or ($_.model -ieq $want)) })
    if ($loaded.Count -eq 0) { return (& $result "not-loaded" $null $null "$want is not loaded on $Root") }
    $total = [double]$loaded[0].size
    $vram = [double]$loaded[0].size_vram
    if ($total -gt 0 -and $vram -le 0) { return (& $result "cpu-only" $total $vram "$want is entirely in system RAM ($([math]::Round($total / 1e9, 2)) GB, size_vram 0)") }
    return (& $result "gpu" $total $vram "$([math]::Round($total / 1e9, 2)) GB, $([math]::Round($vram / 1e9, 2)) GB in VRAM")
}

function Get-OllamaPromptTruncation {
    # Ollama's "truncating input prompt" warnings logged between $Since and
    # $Until. When a request is longer than the served num_ctx, Ollama keeps
    # the first `keep` tokens (4) and the tail of the window and drops the
    # rest - the system prompt, the tool schemas and the task go first. The
    # model then answers whatever is left, usually in prose, and the writes
    # gate used to file that as liar mode. On 2026-10-03 asohav-05/06 did this
    # on all four runs: the repo's 280 KB CLAUDE.md at their pins made the
    # first request ~83k tokens against qwen3.6's 65,536.
    # The log has no request id, so a second run against the same Ollama at
    # the same time would be blamed too; the harness runs one at a time.
    param([string]$LogDir, [DateTimeOffset]$Since, [DateTimeOffset]$Until)
    $hits = @()
    if (-not $LogDir -or -not (Test-Path -LiteralPath $LogDir)) { return $hits }
    # server.log is current; Ollama renames it to server-1.log (and so on) when
    # it restarts, so a restart mid-run leaves part of the run in a rotated file.
    # server.log is always read: Windows does not keep LastWriteTime current on
    # a file another process holds open (it read 14:37 at 17:30 on 2026-10-03).
    # Rotated files are closed, so their timestamp is trustworthy.
    $files = @(Get-ChildItem -LiteralPath $LogDir -Filter "server*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "server.log" -or $_.LastWriteTime -ge $Since.LocalDateTime })
    foreach ($f in $files) {
        # Ollama is still writing server.log: share ReadWrite or the open fails.
        try {
            $fs = New-Object System.IO.FileStream($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        } catch { continue }
        $reader = New-Object System.IO.StreamReader($fs)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line -notmatch 'truncating input prompt') { continue }
                if ($line -notmatch '^time=(\S+)') { continue }
                $t = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse($Matches[1], [ref]$t)) { continue }
                if ($t -ge $Since -and $t -le $Until) { $hits += $line }
            }
        } finally {
            $reader.Dispose()
        }
    }
    return $hits
}


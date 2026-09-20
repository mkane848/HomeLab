# test-profiles.ps1 — Verify that a profile's env contract, opencode registration,
# host availability, and (opt-in) prompt round-trips all actually work.
#
# Usage (PowerShell, from anywhere):
#   .\tests\test-profiles.ps1                              # ALL profiles, liveness + registration + intent only
#   .\tests\test-profiles.ps1 -Profile dev-desktop-only    # one profile (or comma-separated names)
#   .\tests\test-profiles.ps1 -RoundTrip                   # prompt every referenced model (slow, loads VRAM)
#   .\tests\test-profiles.ps1 -Bench                       # -RoundTrip + enforce per-model latency budgets + report table
#   .\tests\test-profiles.ps1 -Reliability                 # single-write canary on every tool-capable MAIN seat
#
# Options:
#   -Profile <name[,name]>  profile names (without .sh). Default: every profiles/*.sh except select-model.sh.
#   -RoundTrip              run PONG, a capability probe, and a latency benchmark for each referenced model.
#   -Bench                  implies -RoundTrip; a model over its latency budget FAILs; summary table printed.
#   -Reliability            run the "create docs/_scratch.md" canary through `opencode run --format json` on
#                           each profile's MAIN seat and FAIL if it issues more than one write/edit tool call
#                           for the single prompt - the repeated-call regression that once unseated qwen3:14b.
#                           A seat that makes NO write call (describes the edit instead) also FAILs. Tool-less
#                           seats and unreachable hosts SKIP. Slow - loads the seat and runs a real task.
#   -ReliabilityTimeout     seconds per canary run (default 360; `opencode run` is killed if it exceeds this).
#   -ConfigPath             live opencode config to validate registration against.
#   -BashPath               Git Bash executable (auto-detected if omitted).
#   -RequestTimeout         seconds for Ollama API liveness/presence calls (default 15).
#   -RoundTripTimeout       seconds per inference call (default 240).
#
# Exit code: 0 if no FAIL, 1 otherwise. WARN/SKIP do not fail the run.

param(
    [string[]]$Profile = @(),
    [switch]$RoundTrip,
    [switch]$Bench,
    [switch]$Reliability,
    [int]$ReliabilityTimeout = 360,
    [string]$ConfigPath = (Join-Path $env:USERPROFILE ".config\opencode\opencode.jsonc"),
    [string]$BashPath = "",
    [int]$RequestTimeout = 15,
    [int]$RoundTripTimeout = 240
)

if ($Bench) { $RoundTrip = $true }

$ErrorActionPreference = "Stop"

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot   = Split-Path -Parent $scriptDir
$catalogPath = Join-Path $repoRoot "models\catalog.tsv"
$profilesDir = Join-Path $repoRoot "profiles"

$results = [System.Collections.Generic.List[object]]::new()
$statusCounts = @{ PASS = 0; FAIL = 0; WARN = 0; SKIP = 0 }

function Write-Result {
    param([string]$Profile, [string]$Check, [string]$Status, [string]$Detail = "")

    $script:results.Add([pscustomobject]@{
        Profile = $Profile
        Check   = $Check
        Status  = $Status
        Detail  = $Detail
    })
    $script:statusCounts[$Status]++

    $color = switch ($Status) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "WARN" { "Yellow" }
        "SKIP" { "Gray" }
    }
    Write-Host ("  [{0,-4}] {1}" -f $Status, $Check) -ForegroundColor $color -NoNewline
    if ($Detail) {
        Write-Host ("  -> {0}" -f $Detail) -ForegroundColor Gray
    } else {
        Write-Host ""
    }
}

function ConvertFrom-Jsonc {
    param([string]$Text)

    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $inLineComment = $false
    $inBlockComment = $false
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { "" }

        if ($inLineComment) {
            if ($c -eq "`n") { $inLineComment = $false; [void]$sb.Append($c) }
        } elseif ($inBlockComment) {
            if ($c -eq "*" -and $n -eq "/") { $inBlockComment = $false; $i++ }
        } elseif ($inString) {
            [void]$sb.Append($c)
            if ($c -eq "\") { $i++; if ($i -lt $Text.Length) { [void]$sb.Append($Text[$i]) } }
            elseif ($c -eq '"') { $inString = $false }
        } else {
            if ($c -eq '"') { $inString = $true; [void]$sb.Append($c) }
            elseif ($c -eq "/" -and $n -eq "/") { $inLineComment = $true; $i++ }
            elseif ($c -eq "/" -and $n -eq "*") { $inBlockComment = $true; $i++ }
            else { [void]$sb.Append($c) }
        }
        $i++
    }
    return ($sb.ToString() | ConvertFrom-Json)
}

function Find-Bash {
    if ($BashPath -and (Test-Path -LiteralPath $BashPath)) { return $BashPath }
    $candidates = @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files\Git\usr\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-ProfileEnv {
    param([string]$ProfilePath)

    $profileBashPath = ($ProfilePath -replace '\\', '/' -replace '^\w:', '$0')
    $bashScript = @'
set +e
unset OPENCODE_MODEL OPENCODE_SMALL_MODEL OLLAMA_SERVER_URL OLLAMA_SERVER_BASE_URL OLLAMA_DESKTOP_URL OLLAMA_DESKTOP_BASE_URL OLLAMA_NODE3_URL OLLAMA_NODE3_BASE_URL DEV_TIERS_SERVER DEV_TIERS_DESKTOP DEV_TIERS_GO DEV_TIERS_NODE3 DEV_SERVER_MODELS DEV_DESKTOP_MODELS DEV_NODE3_MODELS OLLAMA_CONTEXT_LENGTH 2>/dev/null
if [ -f "__PROFILEPATH__" ]; then
  . "__PROFILEPATH__" >/dev/null 2>&1
fi
for v in DEV_TIERS_SERVER DEV_TIERS_DESKTOP DEV_TIERS_GO DEV_TIERS_NODE3 DEV_SERVER_MODELS DEV_DESKTOP_MODELS DEV_NODE3_MODELS OPENCODE_MODEL OPENCODE_SMALL_MODEL OLLAMA_SERVER_BASE_URL OLLAMA_DESKTOP_BASE_URL OLLAMA_NODE3_BASE_URL SERVER_IP DESKTOP_IP; do
  eval 'val=${'$v':-<unset>}'
  printf 'ENV %s=%s\n' "$v" "$val"
done
'@ -replace '__PROFILEPATH__', $profileBashPath

    $tmp = Join-Path $env:TEMP ("profile-env-{0}.sh" -f ([guid]::NewGuid().ToString("N")))
    [System.IO.File]::WriteAllText($tmp, $bashScript, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $output = & $bash --noprofile --norc $tmp 2>$null
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    $map = @{}
    foreach ($line in $output) {
        if ($line -match '^ENV ([A-Z0-9_]+)=(.*)$') {
            $map[$matches[1]] = $matches[2]
        }
    }
    return $map
}

function Split-ModelId {
    param([string]$ModelId)
    $parts = $ModelId -split '/', 2
    if ($parts.Count -ne 2) { return $null }
    return [pscustomobject]@{ Provider = $parts[0]; Model = $parts[1] }
}

function Get-ProviderEnvVar {
    param($Providers, [string]$ProviderName)

    if (-not $Providers) { return $null }
    $p = $Providers.PSObject.Properties[$ProviderName]
    if (-not $p) { return $null }
    $base = $p.Value.options.baseURL
    if ($base -is [string] -and $base -match '\{env:([^}]+)\}') { return $matches[1] }
    return $null
}

function Get-InstalledModelIds {
    param([string]$BaseUrl)

    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/models" -TimeoutSec $RequestTimeout -ErrorAction Stop
        if ($r.PSObject.Properties['data']) {
            return @($r.data | ForEach-Object { $_.id })
        }
        return @($r.id)
    } catch {
        return $null
    }
}

# Served context for a tag, straight from the host's /api/show. This is the
# ground truth that opencode's limit.context is not allowed to exceed.
# $BaseUrl is the OpenAI-compat endpoint (".../v1"); /api/show lives one level up.
$script:servedCtxCache = @{}
function Get-ServedContext {
    param([string]$BaseUrl, [string]$Tag)

    $key = "$BaseUrl|$Tag"
    if ($script:servedCtxCache.ContainsKey($key)) { return $script:servedCtxCache[$key] }

    $root = $BaseUrl -replace '/v1/?$', ''
    $ctx = $null
    try {
        $body = @{ name = $Tag } | ConvertTo-Json -Compress
        $r = Invoke-RestMethod -Uri "$root/api/show" -Method Post -Body $body `
                -ContentType "application/json" -TimeoutSec $RequestTimeout -ErrorAction Stop
        # Baked num_ctx wins; otherwise the host serves OLLAMA_CONTEXT_LENGTH,
        # which /api/show does not report - leave null and skip the check.
        if ($r.parameters -match 'num_ctx\s+(\d+)') { $ctx = [int]$matches[1] }
    } catch {
        $ctx = $null
    }
    $script:servedCtxCache[$key] = $ctx
    return $ctx
}

function Test-ModelPresent {
    param([string[]]$Installed, [string]$ModelId)
    $norm = $ModelId.Trim()
    foreach ($id in $Installed) {
        if (($id -replace ':latest$', '') -eq $norm) { return $true }
    }
    return $false
}

function Expand-InstallGroup {
    param([string[]]$Tokens)

    $tags = [System.Collections.Generic.List[string]]::new()
    $rows = Import-Csv -LiteralPath $catalogPath -Delimiter "`t"
    foreach ($t in $Tokens) {
        if (-not $t) { continue }
        $row = $rows | Where-Object { $_.tag -eq $t }
        if ($row) { $tags.Add($t) }
        else {
            $groupRows = $rows | Where-Object { ($_.groups -split ",") -contains $t }
            if ($groupRows) { $groupRows | ForEach-Object { $tags.Add($_.tag) } }
            else { $tags.Add($t) }
        }
    }
    return @($tags | Select-Object -Unique)
}

function Test-ChatRoundTrip {
    param([string]$BaseUrl, [string]$ModelId, [bool]$IsReasoning, [int]$TimeoutSec)

    $body = @{
        model    = $ModelId
        messages = @(@{ role = "user"; content = "Reply with exactly: PONG" })
        stream   = $false
        max_tokens = 4096
    } | ConvertTo-Json -Depth 6

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/chat/completions" -Method Post `
            -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop
        $stopwatch.Stop()
    } catch {
        return [pscustomobject]@{
            Ok = $false
            Detail = "request failed: $($_.Exception.Message)"
            Ms = 0
        }
    }

    $choice = @($r.choices)[0]
    $content = if ($choice.message.content) { "$($choice.message.content)".Trim() } else { "" }
    $reasoning = if ($choice.message.reasoning) { "$($choice.message.reasoning)".Trim() } else { "" }
    $finish = $choice.finish_reason

    if ($content -ne "") {
        return [pscustomobject]@{ Ok = $true; Detail = "responded '$content' (${finish}, $($stopwatch.ElapsedMilliseconds) ms)"; Ms = $stopwatch.ElapsedMilliseconds }
    }
    if ($reasoning -ne "") {
        return [pscustomobject]@{ Ok = $false; Detail = "EMPTY content, reasoning-only ($finish, $($stopwatch.ElapsedMilliseconds) ms) - opencode can't surface this as a reply" }
    }
    if ($r.error) {
        return [pscustomobject]@{ Ok = $false; Detail = "API error: $($r.error | ConvertTo-Json -Compress)" }
    }
    return [pscustomobject]@{ Ok = $false; Detail = "empty response, no reasoning, finish=$finish" }
}

# The write-discipline canary (-Reliability). Runs a real task through the
# actual OpenCode tool layer (`opencode run --format json`) and counts the
# write/edit tool calls the model emitted. `tool_call` in the config proves a
# model CAN call tools; this proves it calls them ONCE per request and stops.
#   - 0 calls    -> the model described the edit instead of making it
#                   (the old qwen2.5/deepseek failure mode - report edits it
#                   never made).
#   - 1 call     -> correct discipline: one prompt, one write, then stop.
#   - >1 calls   -> the repeated-call regression that once unseated qwen3:14b
#                   (6 writes for one request). FAIL - that seat must not drive
#                   an append/commit/migration until it stops repeating.
# The canary file (docs/_scratch.md) is deleted afterwards so the tree stays
# clean no matter how many seats are exercised.
function Test-ReliableWrite {
    param([string]$ModelId, [int]$TimeoutSec)

    $scratchPath = Join-Path $repoRoot "docs\_scratch.md"
    Remove-Item -LiteralPath $scratchPath -Force -ErrorAction SilentlyContinue

    $msg = "Create a file at docs/_scratch.md containing the single line: it works"
    $tmp = Join-Path $env:TEMP ("reliability-{0}.jsonl" -f ([guid]::NewGuid().ToString("N")))

    # Run in a job so a wedged `opencode run` can be killed on timeout instead
    # of hanging the whole harness. The child inherits this process's env, which
    # is exactly what -RoundTrip relies on for resolved BASE_URL vars.
    $job = Start-Job -ScriptBlock {
        param($RepoRoot, $ModelId, $Msg, $Out)
        & opencode run --dir $RepoRoot --model $ModelId --format json --auto $Msg 2>$null |
            Out-File -LiteralPath $Out -Encoding utf8
        return $LASTEXITCODE
    } -ArgumentList $repoRoot, $ModelId, $msg, $tmp

    if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Ok = $false; Detail = "opencode run timed out after $TimeoutSec s"; Writes = -1 }
    }
    $code = @(Receive-Job $job)[0]
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    $writes = 0
    $bad = 0
    if (Test-Path -LiteralPath $tmp) {
        foreach ($line in [System.IO.File]::ReadLines($tmp)) {
            if (-not $line.Trim()) { continue }
            try { $e = $line | ConvertFrom-Json } catch { continue }
            if ($e.type -ne "tool_use") { continue }
            if ($e.part.tool -in @("write", "edit", "Patch", "NotebookEdit")) {
                $writes++
            } elseif ($e.part.state.status -and $e.part.state.status -ne "completed") {
                $bad++
            }
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    $exists = Test-Path -LiteralPath $scratchPath
    $contentOk = $false
    if ($exists) {
        $contentOk = ((Get-Content -LiteralPath $scratchPath -Raw -ErrorAction SilentlyContinue).Trim() -eq "it works")
    }
    Remove-Item -LiteralPath $scratchPath -Force -ErrorAction SilentlyContinue

    if ($code -ne 0) {
        return [pscustomobject]@{ Ok = $false; Detail = "opencode run exited $code - canary did not complete"; Writes = $writes }
    }
    if ($writes -eq 1 -and $exists -and $contentOk) {
        return [pscustomobject]@{ Ok = $true; Detail = "exactly 1 write tool call; file correct"; Writes = 1 }
    }
    if ($writes -gt 1) {
        return [pscustomobject]@{ Ok = $false; Detail = "$writes write/edit tool calls for ONE prompt - repeated-call regression; that seat must not append/commit/migrate until it stops (drop to qwen3:8b, see docs/troubleshooting.md)"; Writes = $writes }
    }
    if ($writes -eq 0) {
        return [pscustomobject]@{ Ok = $false; Detail = "no write tool call made - the model described the edit instead of making it"; Writes = 0 }
    }
    return [pscustomobject]@{ Ok = $false; Detail = "wrote the file but content mismatch (exists=$exists contentOk=$contentOk)"; Writes = $writes }
}

$script:catalogRows = Import-Csv -LiteralPath $catalogPath -Delimiter "`t"

function Get-ModelRole {
    param([string]$Tag)
    if (-not $Tag) { return "general" }
    $row = $script:catalogRows | Where-Object { $_.tag -eq $Tag } | Select-Object -First 1
    if ($row) {
        foreach ($g in @("coder", "reasoner", "creative", "embed")) {
            if (($row.groups -split ",") -contains $g) { return $g }
        }
        return "general"
    }
    if ($Tag -match 'deepseek|qwq') { return "reasoner" }
    if ($Tag -match 'coder|codestral|gpt-oss') { return "coder" }
    if ($Tag -match 'gemma') { return "creative" }
    if ($Tag -match 'embed') { return "embed" }
    return "general"
}

$budgetsMs = @{
    "qwen2.5-coder:7b"    = 45000;  "qwen2.5-coder:14b"    = 60000;  "qwen2.5-coder-16k"  = 180000
    "qwen3:8b"            = 60000;  "qwen3:14b"            = 90000;  "deepseek-r1:14b"    = 120000
    "deepseek-r1-16k"     = 90000;  "codestral:22b"        = 90000;  "gemma3:12b"         = 90000
    "glm4:9b"             = 60000;  "gpt-oss:20b"          = 90000;  "qwq:32b"            = 240000
}

function Get-Budget {
    param([string]$Tag)
    if ($budgetsMs.ContainsKey($Tag)) { return $budgetsMs[$Tag] }
    $row = $script:catalogRows | Where-Object { $_.tag -eq $Tag } | Select-Object -First 1
    if ($row) { return [int][Math]::Min(240000, [Math]::Max(45000, 15000 + [double]$row.size_gb * 9000)) }
    return 120000
}

function Test-EmbedCapability {
    param([string]$BaseUrl, [string]$ModelId, [int]$TimeoutSec)
    $body = @{ model = $ModelId; input = @("hello") } | ConvertTo-Json -Depth 4
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/embeddings" -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop
        $dims = @($r.data[0].embedding).Count
        if ($dims -gt 0) { return [pscustomobject]@{ Ok = $true; Detail = "dims=$dims" } }
        return [pscustomobject]@{ Ok = $false; Detail = "embedding vector empty" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = "request failed: $($_.Exception.Message)" }
    }
}

function Test-Capability {
    param([string]$BaseUrl, [string]$ModelId, [string]$Role, [int]$TimeoutSec)
    $prompt = switch ($Role) {
        "coder"    { "Write a Python function add(a, b) that returns their sum. Reply with ONLY the code." }
        "reasoner" { "What is 17*23? Reply with only the integer." }
        "general"  { "Which weighs more: 1 kg of feathers or 1 kg of steel? Reply with a single word." }
        "creative" { "Write a single haiku about autumn. Reply with only the poem." }
        default    { "Reply with exactly: OK" }
    }
    $body = @{
        model = $ModelId; messages = @(@{ role = "user"; content = $prompt }); stream = $false; max_tokens = 4096
    } | ConvertTo-Json -Depth 6
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $r = Invoke-RestMethod -Uri "$BaseUrl/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec $TimeoutSec -ErrorAction Stop; $sw.Stop() }
    catch { return [pscustomobject]@{ Ok = $false; Detail = "request failed: $($_.Exception.Message)"; Ms = 0 } }
    $choice = @($r.choices)[0]
    $content   = if ($choice.message.content)   { "$($choice.message.content)".Trim() }   else { "" }
    $reasoning = if ($choice.message.reasoning) { "$($choice.message.reasoning)".Trim() } else { "" }
    $finish    = $choice.finish_reason
    $pass = switch ($Role) {
        "coder"    { ($content -match 'def\s+add' -or $content -match 'def\s') -and ($content -match 'return') }
        "reasoner" { ($content -match '391') -and ($reasoning -ne "") }
        "general"  { [bool]($content -match '(?i)(same|equal|identical|neither|both)') }
        "creative" { ($content -ne "") -and ((@($content -split "`n")).Count -ge 2) }
        default    { $content -ne "" }
    }
    $snippet = ($content -replace "\s+", " ")
    $snippet = $snippet.Substring(0, [Math]::Min(40, $snippet.Length))
    $reasonNote = if ($reasoning) { " reasoning=yes" } else { "" }
    return [pscustomobject]@{ Ok = $pass; Detail = "'$snippet' (finish=$finish$reasonNote $($sw.ElapsedMilliseconds) ms)"; Ms = $sw.ElapsedMilliseconds }
}

function New-Intent {
    param(
        [string]$Purpose, [string]$Main, [string]$Role, [string]$Small,
        [bool]$Server = $false, [bool]$Desktop = $false, [bool]$Go = $false, [bool]$Node3 = $false,
        [bool]$GoDefault = $false, [bool]$Stub = $false
    )
    [pscustomobject]@{
        Purpose = $Purpose; Main = $Main; Role = $Role; Small = $Small
        Server = $Server; Desktop = $Desktop; Go = $Go; Node3 = $Node3
        GoDefault = $GoDefault; Stub = $Stub
    }
}

$profileIntents = @{
    # Main seat must be a model that can actually CALL TOOLS. qwen2.5-coder and
    # deepseek-r1 cannot (tests/test-toolcalls.ps1) - they print the call as
    # chat text and report edits they never made. Only the qwen3 family (8b/14b)
    # and devstral:24b pass, so a qwen3 holds the main seat here regardless of
    # code-quality ranking. 14b was re-seated 2026-09-17 for loose-prompt intent
    # handling; watch for repeated tool calls (see docs/troubleshooting.md).
    "dev-workflow-quality"  = New-Intent -Purpose "qwen3:14b drives in-thread at 32k, /plan on demand" -Main "ollama-desktop/qwen3:14b" -Role "general" -Small "ollama-desktop/qwen2.5-coder:3b" -Desktop $true
    "dev-workflow-resident" = New-Intent -Purpose "qwen3:8b drives, 7b coder resident as a no-tools code/review model (no coder subagent since 2026-09-17)" -Main "ollama-desktop/qwen3:8b" -Role "general" -Small "ollama-desktop/qwen2.5-coder:7b" -Desktop $true
    "dev-workflow-server"   = New-Intent -Purpose "qwen3:8b drives from the server, desktop planner" -Main "ollama-server/qwen3:8b" -Role "general" -Small "ollama-server/qwen2.5-coder:7b" -Server $true -Desktop $true
    "dev-desktop-only"      = New-Intent -Purpose "standalone desktop console, no LAN deps" -Main "ollama-desktop/qwen3:8b" -Role "general" -Small "ollama-desktop/qwen2.5-coder:7b" -Desktop $true
    "dev-local-only"        = New-Intent -Purpose "zero-cloud local stack: desktop main seat + server autocomplete" -Main "ollama-desktop/qwen3:8b" -Role "general" -Small "ollama-server/qwen2.5-coder:7b" -Server $true -Desktop $true
    "dev-server-all"        = New-Intent -Purpose "everything heavy on the server, desktop idle" -Main "ollama-server/qwen3:8b" -Role "general" -Small "ollama-server/qwen2.5-coder:7b" -Server $true
    "dev-quick"             = New-Intent -Purpose "fastest loop: server autocomplete only" -Main "ollama-server/qwen3:8b" -Role "general" -Small "ollama-server/qwen2.5-coder:7b" -Server $true
    "dev-coder"             = New-Intent -Purpose "code quality: server 14b coder available as a no-tools model" -Main "ollama-server/qwen3:8b" -Role "general" -Small "ollama-server/qwen2.5-coder:7b" -Server $true
    "dev-embeddings"        = New-Intent -Purpose "server autocomplete + nomic/mxbai embeddings for semantic search" -Main "ollama-server/qwen3:8b" -Role "general" -Small "ollama-server/qwen2.5-coder:7b" -Server $true
    "dev-go-only"           = New-Intent -Purpose "cloud evaluation: OPENCODE_MODEL must stay unset (config default = Go model)" -Main "<unset>" -Role "unset" -Small "<unset>" -Server $true -Go $true -GoDefault $true
    "dev-full"              = New-Intent -Purpose "all tiers, cloud default for testing anything new" -Main "<unset>" -Role "unset" -Small "<unset>" -Server $true -Desktop $true -Go $true -GoDefault $true
    "dev-node3"              = New-Intent -Purpose "third node (RTX 3080 FE, live since 2026-09-20): node3 qwen3:8b when NODE3_IP set; degrades gracefully to server autocomplete without it" -Main "ollama-server/qwen3:8b" -Role "general" -Small "ollama-server/qwen2.5-coder:7b" -Server $true -Stub $true
}

$capCache    = @{}
$script:relCache = @{}
$benchRows   = [System.Collections.Generic.List[object]]::new()

if (-not (Test-Path -LiteralPath $profilesDir)) {
    Write-Host "ERROR: profiles directory not found at $profilesDir" -ForegroundColor Red
    exit 1
}

$bash = Find-Bash
if (-not $bash) {
    Write-Host "ERROR: Git Bash not found. Set -BashPath." -ForegroundColor Red
    exit 1
}

$cfg = $null
$providers = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = ConvertFrom-Jsonc (Get-Content -LiteralPath $ConfigPath -Raw)
        $providers = $cfg.provider
    } catch {
        Write-Host "WARNING: could not parse config at $ConfigPath ($($_.Exception.Message))" -ForegroundColor Yellow
    }
} else {
    Write-Host "WARNING: config not found at $ConfigPath - registration checks skipped" -ForegroundColor Yellow
}

$profileNames = if (@($Profile).Count -gt 0) {
    @($Profile | ForEach-Object { $_.Trim() })
} else {
    @(Get-ChildItem -LiteralPath $profilesDir -Filter "*.sh" |
        Where-Object { $_.BaseName -ne "select-model" } |
        ForEach-Object { $_.BaseName } | Sort-Object)
}

foreach ($profileName in $profileNames) {
    Write-Host ""
    Write-Host ("=== {0} ===" -f $profileName) -ForegroundColor Cyan

    $candidate = Join-Path $profilesDir "$profileName.sh"
    if (-not (Test-Path -LiteralPath $candidate)) {
        $candidate = Join-Path $profilesDir $profileName
    }
    if (-not (Test-Path -LiteralPath $candidate)) {
        Write-Result $profileName "profile file" "FAIL" "no profiles/$profileName.sh"
        continue
    }

    $envMap = Get-ProfileEnv -ProfilePath $candidate
    if ($envMap.Count -eq 0) {
        Write-Result $profileName "profile sourcing" "FAIL" "bash subshell returned no env vars"
        continue
    }

    $tiers = @{
        server  = ($envMap["DEV_TIERS_SERVER"]  -eq "true")
        desktop = ($envMap["DEV_TIERS_DESKTOP"] -eq "true")
        node3    = ($envMap["DEV_TIERS_NODE3"]    -eq "true")
        go      = ($envMap["DEV_TIERS_GO"]      -eq "true")
    }
    Write-Host ("  tiers: server={0} desktop={1} node3={2} go={3}" -f $tiers.server, $tiers.desktop, $tiers.node3, $tiers.go) -ForegroundColor DarkGray

    $intent = $profileIntents[$profileName]
    if ($intent) {
        Write-Host ("  purpose: {0}" -f $intent.Purpose) -ForegroundColor DarkGray

        $expMain = $intent.Main
        $expSmall = $intent.Small
        $expRole = $intent.Role

        if ($intent.Stub) {
            if ($tiers.node3) {
                $expMain = "ollama-node3/qwen3:8b"; $expRole = "general"
                Write-Result $profileName "intent: third-node tier" "PASS" "node active -> main on ollama-node3"
            } else {
                Write-Result $profileName "intent: third-node tier" "WARN" "NODE3_IP unset - third-node tier off (documented stub state), server autocomplete only"
            }
        }

        foreach ($t in @("server", "desktop", "go", "node3")) {
            if ($intent.Stub -and $t -eq "node3") { continue }
            $expected = [bool]$intent.$t
            $actual   = [bool]$tiers[$t]
            $tierName = "DEV_TIERS_" + $t.ToUpper()
            if ($actual -eq $expected) {
                Write-Result $profileName "intent: tier $tierName" "PASS" "= $expected"
            } else {
                Write-Result $profileName "intent: tier $tierName" "FAIL" "should be $expected, got $actual"
            }
        }

        if ($intent.GoDefault) {
            $m = $envMap["OPENCODE_MODEL"]; $s = $envMap["OPENCODE_SMALL_MODEL"]
            if ($m -eq "<unset>" -and $s -eq "<unset>") {
                Write-Result $profileName "intent: cloud default" "PASS" "OPENCODE_MODEL/SMALL unset -> config default (Go model)"
            } else {
                Write-Result $profileName "intent: cloud default" "FAIL" "purpose is the Go default but profile pins OPENCODE_MODEL=$m SMALL=$s"
            }
        } else {
            if ($expMain -eq $envMap["OPENCODE_MODEL"]) {
                Write-Result $profileName "intent: main model" "PASS" $expMain
            } else {
                Write-Result $profileName "intent: main model" "FAIL" "should be $expMain, got $($envMap['OPENCODE_MODEL'])"
            }
            if ($expSmall -eq $envMap["OPENCODE_SMALL_MODEL"]) {
                Write-Result $profileName "intent: small model" "PASS" $expSmall
            } else {
                Write-Result $profileName "intent: small model" "FAIL" "should be $expSmall, got $($envMap['OPENCODE_SMALL_MODEL'])"
            }
        }

        # MAIN SEAT SAFETY.
        #
        # This used to assert the main model's catalog ROLE (coder/reasoner/
        # general) on the theory that a reasoner must never drive. That rule is
        # obsolete and was actively wrong: measured 2026-09-17, the only local
        # model that can emit a parseable tool call is qwen3, whose catalog
        # groups are "reasoner,general". Role says nothing about whether a model
        # can drive a session.
        #
        # The property that actually matters is tool capability, so that is what
        # we assert. `tool_call` in the opencode config is set from
        # tests/test-toolcalls.ps1 results - a model that cannot call tools
        # cannot read, edit or run anything, and will report edits it never made.
        if ($expRole -ne "unset") {
            $modelTag = $expMain -replace '^ollama-[^/]+/', ''
            $split = Split-ModelId $expMain
            $modelDef = $null
            if ($providers -and $split) {
                $prov = $providers.PSObject.Properties[$split.Provider]
                if ($prov) { $modelDef = $prov.Value.models.PSObject.Properties[$split.Model] }
            }

            if (-not $modelDef) {
                Write-Result $profileName "intent: main seat" "WARN" "$modelTag not registered in the opencode config - cannot verify tool capability"
            } elseif ($modelDef.Value.tool_call -eq $true) {
                Write-Result $profileName "intent: main seat" "PASS" "$modelTag is tool-capable (role: $(Get-ModelRole -Tag $modelTag))"
            } else {
                Write-Result $profileName "intent: main seat" "FAIL" "$modelTag has tool_call=false - it CANNOT edit files and will claim it did. Seat a tool-capable model (probe with tests\test-toolcalls.ps1)"
            }
        }
    }

    $mainId  = $envMap["OPENCODE_MODEL"]
    $smallId = $envMap["OPENCODE_SMALL_MODEL"]

    $refModels = @()
    foreach ($id in @($mainId, $smallId) | Where-Object { $_ -ne "<unset>" -and $_ }) {
        $refModels += [pscustomobject]@{ Id = $id; Source = "default" }
    }
    # Models the desktop must be able to serve beyond the main/small pair.
    # qwen3:8b is the lighter main seat in dev-workflow-resident and
    # dev-desktop-only, so it must stay registered. The -16k aliases are
    # derived tags startup.ps1 bakes; they are kept as deliberate no-tools
    # models (code text, review) and profiles may seat them as small_model, so
    # their presence is still part of the contract.
    if ($tiers.desktop) {
        $refModels += [pscustomobject]@{ Id = "ollama-desktop/qwen3:8b"; Source = "lighter seat (resident/desktop-only)" }
        foreach ($agentId in @("deepseek-r1-16k", "qwen2.5-coder-16k")) {
            $refModels += [pscustomobject]@{ Id = "ollama-desktop/$agentId"; Source = "derived alias (no-tools)" }
        }
    }

    $contractOk = $true
    foreach ($ref in $refModels | Select-Object -Unique Id) {
        $split = Split-ModelId $ref.Id
        if (-not $split) {
            Write-Result $profileName "model id format '$($ref.Id)'" "FAIL" "expected provider/model"
            $contractOk = $false
            continue
        }
        $tierVar = switch ($split.Provider) {
            "ollama-server"  { "DEV_TIERS_SERVER" }
            "ollama-desktop" { "DEV_TIERS_DESKTOP" }
            "ollama-node3"    { "DEV_TIERS_NODE3" }
            default           { $null }
        }
        if (-not $tierVar) {
            if ($ref.Source -eq "default") {
                Write-Result $profileName "provider '$($split.Provider)'" "FAIL" "not an ollama-*/registered tier host"
                $contractOk = $false
            }
            continue
        }
        $tierName = $tierVar -replace '^DEV_TIERS_', ''
        if (-not $tiers[$tierName.ToLower()]) {
            Write-Result $profileName "coherence '$($ref.Id)'" "FAIL" "references $($split.Provider) but $tierVar is false"
            $contractOk = $false
        }
    }
    if ($contractOk) {
        Write-Result $profileName "profile contract" "PASS" "model IDs reference enabled tiers"
    }

    if ($profileName -eq "dev-workflow-server" -and $tiers.server -and $envMap["SERVER_IP"] -ne "<unset>" -and $envMap["OLLAMA_SERVER_BASE_URL"] -match 'localhost|127\.0\.0\.1') {
        Write-Result $profileName "server baseURL" "WARN" "OLLAMA_SERVER_BASE_URL points at localhost, but SERVER_IP=$($envMap['SERVER_IP']) - opencode on the desktop would hit its own Ollama, not the server"
    }

    $installHosts = @(
        if ($tiers.desktop -and $envMap["DEV_DESKTOP_MODELS"] -ne "<unset>") {
            [pscustomobject]@{ Host = "desktop"; Var = "DEV_DESKTOP_MODELS"; Tokens = @($envMap["DEV_DESKTOP_MODELS"] -split ' ') }
        }
        if ($tiers.server -and $envMap["DEV_SERVER_MODELS"] -ne "<unset>") {
            [pscustomobject]@{ Host = "server"; Var = "DEV_SERVER_MODELS"; Tokens = @($envMap["DEV_SERVER_MODELS"] -split ' ') }
        }
        if ($tiers.node3 -and $envMap["DEV_NODE3_MODELS"] -ne "<unset>") {
            [pscustomobject]@{ Host = "node3"; Var = "DEV_NODE3_MODELS"; Tokens = @($envMap["DEV_NODE3_MODELS"] -split ' ') }
        }
    )
    foreach ($ih in $installHosts) {
        $envVarName = switch ($ih.Host) {
            "desktop" { "OLLAMA_DESKTOP_BASE_URL" }
            "server"  { "OLLAMA_SERVER_BASE_URL" }
            "node3"    { "OLLAMA_NODE3_BASE_URL" }
        }
        $baseUrl = [Environment]::GetEnvironmentVariable($envVarName, "Process")
        if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            Write-Result $profileName "install intent ($($ih.Host))" "WARN" "$envVarName not set in this shell - set by sourcing the profile; skipping host model checks"
            continue
        }
        $installTags = Expand-InstallGroup -Tokens $ih.Tokens
        $installed = Get-InstalledModelIds -BaseUrl $baseUrl
        if ($null -eq $installed) {
            Write-Result $profileName "install intent ($($ih.Host))" "SKIP" "$baseUrl unreachable"
            continue
        }
        $missing = @($installTags | Where-Object { -not (Test-ModelPresent -Installed $installed -ModelId $_) })
        if ($missing.Count -eq 0) {
            Write-Result $profileName "install intent ($($ih.Host))" "PASS" "$baseUrl has all $($installTags.Count) models"
        } else {
            Write-Result $profileName "install intent ($($ih.Host))" "WARN" "missing on host: $($missing -join ', ')"
        }
        foreach ($btag in @($installTags | Where-Object { (Get-ModelRole -Tag $_) -eq "embed" })) {
            $e = Test-EmbedCapability -BaseUrl $baseUrl -ModelId $btag -TimeoutSec $RequestTimeout
            if ($e.Ok) {
                Write-Result $profileName "embed capability '$btag'" "PASS" $e.Detail
            } else {
                Write-Result $profileName "embed capability '$btag'" "WARN" "$($e.Detail) - an embed model must answer /api/embeddings"
            }
        }
    }

    if ($tiers.desktop) {
        foreach ($agentId in @("deepseek-r1-16k", "qwen2.5-coder-16k")) {
            $baseUrl = [Environment]::GetEnvironmentVariable("OLLAMA_DESKTOP_BASE_URL", "Process")
            if ([string]::IsNullOrWhiteSpace($baseUrl)) {
                Write-Result $profileName "derived model $agentId" "WARN" "OLLAMA_DESKTOP_BASE_URL unset in this shell"
                continue
            }
            $installed = Get-InstalledModelIds -BaseUrl $baseUrl
            if ($null -eq $installed) {
                Write-Result $profileName "derived model $agentId" "SKIP" "$baseUrl unreachable"
            } elseif (Test-ModelPresent -Installed $installed -ModelId $agentId) {
                Write-Result $profileName "derived model $agentId" "PASS" "present (created by startup.ps1)"
            } else {
                Write-Result $profileName "derived model $agentId" "FAIL" "missing - run desktop\scripts\startup.ps1 to bake it (opencode subagents hard-reference it)"
            }
        }
    }

    if ($providers) {
        foreach ($ref in @($refModels | Select-Object -Unique Id)) {
            $split = Split-ModelId $ref.Id
            if (-not $split) { continue }
            $p = $providers.PSObject.Properties[$split.Provider]
            if (-not $p) {
                if ($ref.Source -eq "default") {
                    Write-Result $profileName "registration '$($ref.Id)'" "FAIL" "provider '$($split.Provider)' not in opencode config"
                }
                continue
            }
            $modelProp = $p.Value.models.PSObject.Properties[$split.Model]
            if (-not $modelProp) {
                Write-Result $profileName "registration '$($ref.Id)'" "FAIL" "model '$($split.Model)' not registered under '$($split.Provider)' in opencode config"
                continue
            }

            # --- schema check -------------------------------------------------
            # opencode SILENTLY DROPS model keys it does not recognise, so a
            # config can look perfect and still resolve with no limits at all.
            # That is exactly what happened with "context_window": the model had
            # no context limit, opencode never trimmed the prompt, and Ollama
            # answered `truncating input prompt limit=8194 prompt=46505 keep=4`.
            # We read the RESOLVED config here, so a dropped key shows up.
            $lim = $modelProp.Value.limit
            if (-not $lim -or -not $lim.context -or -not $lim.output) {
                Write-Result $profileName "schema '$($ref.Id)'" "FAIL" "resolved entry has no limit.context/limit.output - the key was dropped by opencode (use limit:{context,output}, NOT context_window). Prompts will not be trimmed."
            } else {
                Write-Result $profileName "schema '$($ref.Id)'" "PASS" "limit.context=$($lim.context) limit.output=$($lim.output)"
            }

            $envVar = Get-ProviderEnvVar -Providers $providers -ProviderName $split.Provider
            if (-not $envVar) {
                $resolved = "static"
            } else {
                $resolvedVal = [Environment]::GetEnvironmentVariable($envVar, "Process")
                if ([string]::IsNullOrWhiteSpace($resolvedVal)) {
                    Write-Result $profileName "registration '$($ref.Id)'" "WARN" "registered, but config resolves $envVar to blank - requests to $($split.Provider) will 'fail to parse as URL' until the env var is set"
                    continue
                }
                $resolved = "$envVar=$resolvedVal"

                # --- promise check --------------------------------------------
                # limit.context must never exceed what the host actually serves,
                # or the client over-promises and the prompt gets truncated
                # (system prompt thrown away, request dies). Baked num_ctx is
                # ground truth; hosts serving the OLLAMA_CONTEXT_LENGTH default
                # do not report it, so those are skipped rather than guessed.
                if ($lim -and $lim.context) {
                    $served = Get-ServedContext -BaseUrl $resolvedVal -Tag $split.Model
                    if ($served) {
                        if ($lim.context -gt $served) {
                            Write-Result $profileName "promise '$($ref.Id)'" "FAIL" "limit.context=$($lim.context) exceeds served num_ctx=$served - re-bake with startup.ps1 or lower limit.context"
                        } else {
                            Write-Result $profileName "promise '$($ref.Id)'" "PASS" "limit.context=$($lim.context) <= served $served"
                        }
                    }
                }
            }
            Write-Result $profileName "registration '$($ref.Id)'" "PASS" "outlined under $($split.Provider) ($resolved)"
        }
    }

    foreach ($ref in @($refModels | Select-Object -Unique Id)) {
        $split = Split-ModelId $ref.Id
        if (-not $split) { continue }
        $envVar = if ($providers) { Get-ProviderEnvVar -Providers $providers -ProviderName $split.Provider } else { $null }
        if (-not $envVar) {
            $envVar = switch ($split.Provider) {
                "ollama-server"  { "OLLAMA_SERVER_BASE_URL" }
                "ollama-desktop" { "OLLAMA_DESKTOP_BASE_URL" }
                "ollama-node3"    { "OLLAMA_NODE3_BASE_URL" }
                default          { $null }
            }
        }
        if (-not $envVar) { continue }

        $baseUrl = [Environment]::GetEnvironmentVariable($envVar, "Process")
        if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            Write-Result $profileName "host '$($ref.Id)'" "WARN" "$envVar unset in this shell - skip host checks (source the profile first)"
            continue
        }

        $installed = Get-InstalledModelIds -BaseUrl $baseUrl
        if ($null -eq $installed) {
            Write-Result $profileName "host '$($ref.Id)'" "SKIP" "$baseUrl unreachable (server down? wrong tier?)"
            continue
        }
        if (-not (Test-ModelPresent -Installed $installed -ModelId $split.Model)) {
            Write-Result $profileName "host '$($ref.Id)'" "FAIL" "model '$($split.Model)' not served by $baseUrl"
            continue
        }
        Write-Result $profileName "host '$($ref.Id)'" "PASS" "served by $baseUrl"

        if ($Reliability -and $ref.Id -eq $mainId) {
            $relSplit = Split-ModelId $ref.Id
            $toolCapable = $false
            if ($providers -and $relSplit) {
                $relProv = $providers.PSObject.Properties[$relSplit.Provider]
                if ($relProv) {
                    $relDef = $relProv.Value.models.PSObject.Properties[$relSplit.Model]
                    if ($relDef -and $relDef.Value.tool_call -eq $true) { $toolCapable = $true }
                }
            }
            if (-not $toolCapable) {
                Write-Result $profileName "reliability '$($ref.Id)'" "SKIP" "seat tool_call=false - write-discipline gate N/A"
            } else {
                if (-not $script:relCache.ContainsKey($ref.Id)) {
                    $script:relCache[$ref.Id] = Test-ReliableWrite -ModelId $ref.Id -TimeoutSec $ReliabilityTimeout
                }
                $rel = $script:relCache[$ref.Id]
                if ($rel.Ok) {
                    Write-Result $profileName "reliability '$($ref.Id)'" "PASS" $rel.Detail
                } else {
                    Write-Result $profileName "reliability '$($ref.Id)'" "FAIL" $rel.Detail
                }
            }
        }

        if ($RoundTrip) {
            $isReasoning = $split.Model -match 'deepseek|qwq|qwen3'
            $rt = Test-ChatRoundTrip -BaseUrl $baseUrl -ModelId $split.Model -IsReasoning $isReasoning -TimeoutSec $RoundTripTimeout
            if ($rt.Ok) {
                Write-Result $profileName "round-trip '$($ref.Id)'" "PASS" $rt.Detail
            } else {
                Write-Result $profileName "round-trip '$($ref.Id)'" "FAIL" $rt.Detail
            }

            $role = Get-ModelRole -Tag $split.Model
            $capKey = "{0}|{1}" -f $baseUrl, $split.Model
            if (-not $capCache.ContainsKey($capKey)) {
                $cap = Test-Capability -BaseUrl $baseUrl -ModelId $split.Model -Role $role -TimeoutSec $RoundTripTimeout
                $capCache[$capKey] = $cap
            } else {
                $cap = $capCache[$capKey]
            }
            if ($cap.Ok) {
                Write-Result $profileName "capability ${role} '$($split.Model)'" "PASS" $cap.Detail
            } else {
                Write-Result $profileName "capability ${role} '$($split.Model)'" "FAIL" "$($cap.Detail) - model is not delivering its $role capability"
            }

            $budget = Get-Budget -Tag $split.Model
            $over = $rt.Ms -gt $budget
            if ($over) {
                if ($Bench) {
                    Write-Result $profileName "benchmark '$($split.Model)'" "FAIL" ("PONG took {0} ms, budget {1} ms" -f $rt.Ms, $budget)
                } else {
                    Write-Result $profileName "benchmark '$($split.Model)'" "WARN" ("PONG took {0} ms, budget {1} ms - slow; check VRAM/swap" -f $rt.Ms, $budget)
                }
            } else {
                Write-Result $profileName "benchmark '$($split.Model)'" "PASS" ("PONG {0} ms within {1} ms budget" -f $rt.Ms, $budget)
            }
            $benchRows.Add([pscustomobject]@{ Profile = $profileName; Model = $split.Model; Ms = $rt.Ms; Budget = $budget; Status = $(if ($over) { if ($Bench) { "FAIL" } else { "WARN" } } else { "PASS" }) })
        }
    }
}

Write-Host ""
Write-Host ("Results: {0} PASS, {1} FAIL, {2} WARN, {3} SKIP" -f $statusCounts.PASS, $statusCounts.FAIL, $statusCounts.WARN, $statusCounts.SKIP) -ForegroundColor Cyan

if ($Bench -and $benchRows.Count -gt 0) {
    Write-Host ""
    Write-Host "Benchmark summary (measured PONG latency vs budget):" -ForegroundColor Cyan
    Write-Host ("  {0,-24} {1,-24} {2,9} {3,9} {4,6}" -f "PROFILE", "MODEL", "MS", "BUDGET", "STATUS")
    foreach ($row in $benchRows) {
        $color = switch ($row.Status) { "PASS" { "Green" }; "FAIL" { "Red" }; default { "Yellow" } }
        Write-Host ("  {0,-24} {1,-24} {2,9} {3,9} {4,6}" -f $row.Profile, $row.Model, $row.Ms, $row.Budget, $row.Status) -ForegroundColor $color
    }
}

$fails = @($results | Where-Object { $_.Status -eq "FAIL" })
if ($fails.Count -gt 0) {
    Write-Host ""
    Write-Host "Failing checks:" -ForegroundColor Red
    $fails | ForEach-Object { Write-Host ("  [{0}] {1} -> {2}" -f $_.Profile, $_.Check, $_.Detail) -ForegroundColor Red }
    exit 1
}
exit 0
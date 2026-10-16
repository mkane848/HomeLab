# tests/engines/llamacpp.ps1 - the llama.cpp (llama-server, router mode) adapter
# for the task harness. Same interface as tests/engines/ollama.ps1 (see its
# header); what differs is what llama-server can and cannot say, measured in the
# engine trial (docs/llamacpp-trial.md -> Results):
#   - version: the router's /props carries build_info ("b11561-abcdef0").
#   - served models: GET /models (router mode: id, aliases, status.value).
#   - served context: the seat's `--ctx-size` in GET /models (loaded or not), else
#     GET /props?model=<seat>&autoload=false -> default_generation_settings.n_ctx.
#     Seat ids are the preset's `alias`, because router mode rewrites colon names.
#   - prompt loss: none to detect. An over-long request is refused explicitly
#     (HTTP 400 exceed_context_size_error), opencode logs a ContextOverflowError, and
#     the harness's transcript-based overflow handling (Get-OverflowRecovery, the
#     contextExceeded outcome) covers it.
#   - GPU placement: no HTTP signal (trial E2). `nvidia-smi --query-compute-apps`
#     over ssh lists the processes on the GPU, and `ps -eo pid,args` maps a child's
#     `--alias <seat>` to its pid; a loaded seat missing from the GPU list is on the
#     CPU, the same verdict as Ollama's size_vram 0. The ssh host is the optional
#     env var LLAMACPP_<HOST>_SSH (a ~/.ssh/config alias, e.g. `server`); unset gives
#     verdict "unchecked" and a note naming it. ssh never prompts (BatchMode).

$script:EngineName = "llamacpp"

function Get-EngineBaseUrlVar {
    param([string]$ProviderId)
    switch ($ProviderId) {
        "llamacpp-desktop" { "LLAMACPP_DESKTOP_BASE_URL" }
        "llamacpp-server"  { "LLAMACPP_SERVER_BASE_URL" }
        "llamacpp-node3"   { "LLAMACPP_NODE3_BASE_URL" }
        default            { $null }
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
    try { $null = Invoke-RestMethod -Uri "$Root/health" -TimeoutSec $TimeoutSec; return $true } catch { return $false }
}

function Get-EngineVersion {
    param([string]$Root)
    try {
        $bi = (Invoke-RestMethod -Uri "$Root/props" -TimeoutSec 10).build_info
        if ($bi) { return [string]$bi }
    } catch { }
    return $null
}

function Format-EngineVersion {
    param([string]$ProviderId, [string]$Root, [string]$Version)
    $var = Get-EngineBaseUrlVar -ProviderId $ProviderId
    if (-not $var)  { return "n/a ($ProviderId is not a llama.cpp provider)" }
    if (-not $Root) { return "unknown ($var is unset)" }
    if ($Version)   { return "llama.cpp build $Version" }
    return "unknown ($Root/props unreachable)"
}

function Get-EngineServedModels {
    # Router mode lists each preset section with its aliases; both are ids a
    # client can send.
    param([string]$Root)
    foreach ($u in @("$Root/models", "$Root/v1/models")) {
        try {
            $data = @((Invoke-RestMethod -Uri $u -TimeoutSec 10).data)
            $ids = @()
            foreach ($m in $data) {
                if ($m.id) { $ids += [string]$m.id }
                foreach ($a in @($m.aliases)) { if ($a) { $ids += [string]$a } }
            }
            if ($ids.Count -gt 0) { return @($ids | Select-Object -Unique) }
        } catch { }
    }
    return $null
}

function Get-EngineServedContext {
    # First the seat's own launch args in GET /models (`--ctx-size N`): known for a
    # seat that is not loaded, and touching nothing. The preset sets `c` explicitly
    # (llamacpp-check.sh enforces it), so the configured size is the served size.
    # Then /props?model=<seat>&autoload=false, which never loads a seat as a side
    # effect (router mode would otherwise autoload it).
    param([string]$Root, [string]$Tag)
    try {
        $data = @((Invoke-RestMethod -Uri "$Root/models" -TimeoutSec 10).data)
        $m = $data | Where-Object { $_.id -ceq $Tag -or (@($_.aliases) -ccontains $Tag) } | Select-Object -First 1
        if ($m -and $m.status -and $m.status.args) {
            $a = @($m.status.args); $i = [array]::IndexOf($a, "--ctx-size")
            if ($i -ge 0 -and $i + 1 -lt $a.Count -and "$($a[$i + 1])" -match '^\d+$') { return [int]$a[$i + 1] }
        }
    } catch { }
    try {
        $props = Invoke-RestMethod -Uri ("$Root/props?model=" + [uri]::EscapeDataString($Tag) + "&autoload=false") -TimeoutSec 10
        $n = $props.default_generation_settings.n_ctx
        if ($null -ne $n -and "$n" -match '^\d+$') { return [int]$n }
        return "unset (no --ctx-size in /models, no n_ctx in /props?model=)"
    } catch {
        return "unknown (no --ctx-size in /models, /props?model= failed)"
    }
}

function Get-EnginePromptLossSetup {
    param([string]$Root, [string]$LogDir, [string]$ProviderId)
    return [pscustomobject]@{
        Enabled = $false; LogDir = $null
        Description = "not applicable: refused explicitly (llama-server answers HTTP 400 exceed_context_size_error; the transcript's ContextOverflowError handling covers it)"
    }
}

function Get-EnginePromptLoss {
    param($Setup, [DateTimeOffset]$Since, [DateTimeOffset]$Until)
    return @()
}

function Get-EnginePromptLossText {
    param($Hits)
    return ("llama-server refused {0} over-long request(s)" -f @($Hits).Count)
}

function Get-EngineGpuPlacement {
    # Verdicts as Get-OllamaGpuPlacement's (tests/engines/ollama.ps1). TotalBytes
    # and Share are not known (nvidia-smi reports the GPU part only).
    param([string]$ProviderId, [string]$Root, [string]$Tag, [int]$TimeoutSec = 8)
    $want = $Tag
    $result = { param($verdict, $vram, $detail)
        [pscustomobject]@{ Verdict = $verdict; Model = $want; TotalBytes = $null; VramBytes = $vram; Share = $null; Detail = $detail } }
    $hostPart = if ($ProviderId -match '^llamacpp-(.+)$') { $Matches[1].ToUpperInvariant() } else { "" }
    $sshVar = "LLAMACPP_${hostPart}_SSH"
    $sshHost = if ($hostPart) { [Environment]::GetEnvironmentVariable($sshVar) } else { $null }
    if (-not $sshHost) {
        return (& $result "unchecked" $null "no HTTP signal for placement on llama-server; set $sshVar to the ssh host alias to check it with nvidia-smi")
    }
    $ssh = { param([string[]]$remote)
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try {
            $out = @(& ssh -o BatchMode=yes -o "ConnectTimeout=$TimeoutSec" $sshHost @remote 2>&1 | ForEach-Object { "$_" })
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out }
        } catch {
            return [pscustomobject]@{ ExitCode = 255; Lines = @("$_") }
        } finally { $ErrorActionPreference = $prev }
    }
    $smi = & $ssh @("nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader")
    if ($smi.ExitCode -ne 0) { return (& $result "unchecked" $null "ssh $sshHost nvidia-smi failed (exit $($smi.ExitCode)): $((($smi.Lines | Select-Object -First 2) -join ' ').Trim())") }
    $psr = & $ssh @("ps", "-eo", "pid,args")
    if ($psr.ExitCode -ne 0) { return (& $result "unchecked" $null "ssh $sshHost ps failed (exit $($psr.ExitCode)): $((($psr.Lines | Select-Object -First 2) -join ' ').Trim())") }

    # pids whose command line carries `--alias <seat>` (the router's child per model)
    $pids = @()
    foreach ($line in $psr.Lines) {
        if ($line -notmatch '^\s*(\d+)\s+(.*)$') { continue }
        $procId = $Matches[1]; $tok = @($Matches[2] -split '\s+')
        $i = [array]::IndexOf($tok, "--alias")
        if ($i -ge 0 -and $i + 1 -lt $tok.Count -and $tok[$i + 1] -ceq $want) { $pids += $procId }
    }
    if ($pids.Count -eq 0) { return (& $result "not-loaded" $null "$want is not loaded on $sshHost (no process with --alias $want)") }

    # GPU processes: "pid, 14930 MiB"
    $mib = 0.0; $onGpu = $false
    foreach ($line in $smi.Lines) {
        if ($line -notmatch '^\s*(\d+)\s*,\s*(\d+(?:\.\d+)?)\s*MiB') { continue }
        if ($pids -contains $Matches[1]) { $onGpu = $true; $mib += [double]$Matches[2] }
    }
    if (-not $onGpu) { return (& $result "cpu-only" 0 "$want (pid $($pids -join ',')) is not among the GPU compute processes on ${sshHost}: it runs on the CPU") }
    return (& $result "gpu" ($mib * 1048576) "$([math]::Round($mib / 1024, 2)) GB in VRAM (nvidia-smi on $sshHost, pid $($pids -join ','))")
}

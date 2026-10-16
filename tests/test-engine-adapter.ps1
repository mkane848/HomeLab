# test-engine-adapter.ps1 - regression guard for the engine adapter boundary
# (tests/engines/ollama.ps1, tests/engines/llamacpp.ps1; Phase 2 of the
# Ollama-replacement program, docs/roadmap.md)
#
# Why this exists: the harness used to ask Ollama's own endpoints (/api/version,
# /api/show, /api/ps) and read its server.log inline, so a second engine meant
# editing the grading script. Everything engine-specific now sits behind one
# interface per engine, chosen by the provider prefix of -Model (ollama-* /
# llamacpp-*), the way tests/agents/opencode.ps1 isolates the agent.
#
# What it does:
#   1. The interface: both adapters define every function, and $script:EngineName.
#   2. The boundary: outside comments, test-tasks.ps1 names no /api/ endpoint,
#      no server.log and no Ollama-only function, and loads the adapter by provider.
#   3. The REAL Ollama functions against a stand-in Invoke-RestMethod: base URL,
#      liveness, version, served models, served context, the prompt-loss setup and
#      its log reader, and the GPU placement verdicts.
#   4. The REAL llama.cpp functions the same way (/health, /props, /props?model=,
#      /models), and its placement over ssh with a stand-in `ssh` first on PATH that
#      prints canned nvidia-smi / ps output: GPU, CPU-only, not loaded, a seat
#      beside it, ssh failing, the env var unset.
#   5. The real test-tasks.ps1 end to end for one Ollama and one llama.cpp provider
#      (a stand-in opencode, host and ssh): the run JSON's `engine`, `ollamaVersion`,
#      `servingEngine`, `numCtx`, `promptTruncation` and `gpuPlacement`.
#   6. Controls: an adapter with one function removed fails the interface check; a
#      harness with a /api/ call put back fails the boundary check.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-engine-adapter.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }

$ollamaPath = Join-Path $PSScriptRoot "engines\ollama.ps1"
$llamaPath  = Join-Path $PSScriptRoot "engines\llamacpp.ps1"
$interface = @("Get-EngineBaseUrlVar", "Get-EngineBaseUrl", "Test-EngineAlive", "Get-EngineVersion", "Format-EngineVersion",
               "Get-EngineServedModels", "Get-EngineSeatTags", "Get-EngineServedContext", "Get-EnginePromptLossSetup", "Get-EnginePromptLoss",
               "Get-EnginePromptLossText", "Get-EngineGpuPlacement")

function Get-Ast([string]$Path) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs.Count) { $errs; exit 2 }
    $ast
}
function Get-MissingFunctions([string]$Path, [string]$Text) {
    # The interface functions an adapter does not define (Text overrides the file, for a control).
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) ("engine-if-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        [IO.File]::WriteAllText($tmpFile, $(if ($Text) { $Text } else { [IO.File]::ReadAllText($Path) }))
        $ast = Get-Ast $tmpFile
        $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        $missing = @($interface | Where-Object { $defined -notcontains $_ })
        if ($ast.Extent.Text -notmatch '\$script:EngineName\s*=') { $missing += '$script:EngineName' }
        return $missing
    } finally { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
}
function Get-BoundaryViolations([string]$Text) {
    # Non-comment tokens of a script that name an engine endpoint, its log or an Ollama-only function.
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) ("engine-bd-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        [IO.File]::WriteAllText($tmpFile, $Text)
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($tmpFile, [ref]$tokens, [ref]$errs)
        return @($tokens | Where-Object { $_.Kind -ne "Comment" -and $_.Text -match '/api/|server\.log|Get-Ollama|\bollamaRoot\b' } | ForEach-Object { $_.Text })
    } finally { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
}

# --- environment helpers (an unset variable needs [NullString]::Value on pwsh 7.5+) ---
$script:SavedEnv = @{}
function Set-Env([string]$Name, $Value) {
    if (-not $script:SavedEnv.ContainsKey($Name)) { $script:SavedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name) }
    [Environment]::SetEnvironmentVariable($Name, $(if ($null -eq $Value) { [NullString]::Value } else { $Value }))
}
function Restore-Env { foreach ($k in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $script:SavedEnv[$k]) { [NullString]::Value } else { $script:SavedEnv[$k] })) }; $script:SavedEnv = @{} }

# --- a stand-in Invoke-RestMethod: first matching route answers; "THROW" fails ---------
$script:Routes = @()
$script:Calls = New-Object System.Collections.Generic.List[string]
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType)
    $u = "$Uri"
    $script:Calls.Add($u)
    foreach ($r in $script:Routes) {
        if ($u -match $r.Pattern) {
            if ($r.Reply -is [string] -and $r.Reply -eq "THROW") { throw "fixture: $u unreachable" }
            return $r.Reply
        }
    }
    throw "fixture: no route for $u"
}
function Route([string]$pattern, $reply) { $script:Routes += , @{ Pattern = $pattern; Reply = $reply } }
function Reset-Routes { $script:Routes = @(); $script:Calls.Clear() }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("engine-adapter-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

try {
    # ---------------------------------------------------------------- 1. interface
    Write-Host "-- the interface (both adapters)"
    Check "ollama.ps1 defines every function and EngineName"   ((Get-MissingFunctions $ollamaPath) -join ",") ""
    Check "llamacpp.ps1 defines every function and EngineName" ((Get-MissingFunctions $llamaPath) -join ",") ""

    # ---------------------------------------------------------------- 2. boundary
    Write-Host "-- the boundary (test-tasks.ps1)"
    $src = [IO.File]::ReadAllText($ScriptPath)
    Check "no /api/ endpoint, server.log or Ollama-only call outside comments" ((Get-BoundaryViolations $src) -join " | ") ""
    Check "the adapter is loaded by provider prefix"           ($src -match 'engines\\\{0\}\.ps1') "True"
    Check "...llamacpp-* picks llamacpp, anything else ollama" ($src -match "(?s)-like 'llamacpp-\*'.{0,40}\`"llamacpp\`".{0,20}\`"ollama\`"") "True"

    # ---------------------------------------------------------------- 3. ollama
    Write-Host "-- Ollama adapter (real functions, canned replies)"
    & {
        . $ollamaPath
        Check "engine name"                                    $script:EngineName "ollama"
        Check "var: ollama-desktop"                            (Get-EngineBaseUrlVar -ProviderId "ollama-desktop") "OLLAMA_DESKTOP_BASE_URL"
        Check "var: ollama-server"                             (Get-EngineBaseUrlVar -ProviderId "ollama-server") "OLLAMA_SERVER_BASE_URL"
        Check "var: ollama-node3"                              (Get-EngineBaseUrlVar -ProviderId "ollama-node3") "OLLAMA_NODE3_BASE_URL"
        Check "var: a hosted provider has none"                ($null -eq (Get-EngineBaseUrlVar -ProviderId "opencode-go")) "True"
        Check "var: an unknown ollama-* host has none"         ($null -eq (Get-EngineBaseUrlVar -ProviderId "ollama-lab")) "True"
        Check "var: a llamacpp provider is not Ollama's"       ($null -eq (Get-EngineBaseUrlVar -ProviderId "llamacpp-server")) "True"
        Set-Env "OLLAMA_SERVER_BASE_URL" "http://fx.invalid:11434/v1/"
        Check "base URL: /v1 and the slash stripped"           (Get-EngineBaseUrl -ProviderId "ollama-server") "http://fx.invalid:11434"
        Set-Env "OLLAMA_SERVER_BASE_URL" $null
        Check "base URL: unset is null"                        ($null -eq (Get-EngineBaseUrl -ProviderId "ollama-server")) "True"
        Restore-Env

        Reset-Routes; Route '/api/tags$' ([pscustomobject]@{ models = @([pscustomobject]@{ name = "qwen3:8b" }, [pscustomobject]@{ name = "qwen3.6:35b-a3b-coding" }) })
        Check "alive: /api/tags answers"                       (Test-EngineAlive -Root "http://fx.invalid") "True"
        Check "served models"                                  ((Get-EngineServedModels -Root "http://fx.invalid") -join ",") "qwen3:8b,qwen3.6:35b-a3b-coding"
        Check "seat tags: the served names themselves"         ((Get-EngineSeatTags -Root "http://fx.invalid") -join ",") "qwen3:8b,qwen3.6:35b-a3b-coding"
        Reset-Routes; Route '/api/tags$' "THROW"
        Check "alive: unreachable"                             (Test-EngineAlive -Root "http://fx.invalid") "False"
        Check "served models: unreachable is null"             ($null -eq (Get-EngineServedModels -Root "http://fx.invalid")) "True"

        Reset-Routes; Route '/api/version$' ([pscustomobject]@{ version = "0.34.3" })
        Check "version"                                        (Get-EngineVersion -Root "http://fx.invalid") "0.34.3"
        Reset-Routes; Route '/api/version$' "THROW"
        Check "version: unreachable is null"                   ($null -eq (Get-EngineVersion -Root "http://fx.invalid")) "True"
        Check "text: a version"                                (Format-EngineVersion -ProviderId "ollama-server" -Root "http://h" -Version "0.34.3") "ollama version is 0.34.3"
        Check "text: unreachable"                              (Format-EngineVersion -ProviderId "ollama-server" -Root "http://h" -Version "") "unknown (http://h/api/version unreachable)"
        Check "text: base URL unset"                           (Format-EngineVersion -ProviderId "ollama-node3" -Root "" -Version "") "unknown (OLLAMA_NODE3_BASE_URL is unset)"
        Check "text: not an Ollama provider"                   (Format-EngineVersion -ProviderId "opencode-go" -Root "" -Version "") "n/a (opencode-go is not an Ollama provider)"

        Reset-Routes; Route '/api/show$' ([pscustomobject]@{ parameters = "temperature 0.6`nnum_ctx    65536`ntop_k 20" })
        Check "served context: num_ctx from /api/show"         (Get-EngineServedContext -Root "http://h" -Tag "qwen3.6:35b-a3b-coding") 65536
        Reset-Routes; Route '/api/show$' ([pscustomobject]@{ parameters = "temperature 0.6" })
        Check "served context: none baked"                     (Get-EngineServedContext -Root "http://h" -Tag "x") "unset (server default)"
        Reset-Routes; Route '/api/show$' "THROW"
        Check "served context: /api/show failed"               (Get-EngineServedContext -Root "http://h" -Tag "x") "unknown (/api/show failed)"

        $logDir = Join-Path $tmp "ollama-log"; New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $hit = 'time=2026-10-03T16:41:00.123-04:00 level=WARN source=llama_server.go:318 msg="truncating input prompt" limit=32770 prompt=83886 keep=4 new=32770'
        [IO.File]::WriteAllText((Join-Path $logDir "server.log"), "$hit`n", $utf8)
        $s = Get-EnginePromptLossSetup -Root "http://remote.invalid:11434" -LogDir $logDir -ProviderId "ollama-server"
        Check "prompt loss: a log directory enables it"        $s.Enabled "True"
        Check "...and says so"                                 $s.Description "checked Ollama server.log in $logDir"
        $hits = @(Get-EnginePromptLoss -Setup $s -Since ([DateTimeOffset]::Parse("2026-10-03T16:40:30-04:00")) -Until ([DateTimeOffset]::Parse("2026-10-03T16:45:00-04:00")))
        Check "...a hit inside the window"                     $hits.Count 1
        Check "...outside the window none"                     @(Get-EnginePromptLoss -Setup $s -Since ([DateTimeOffset]::Parse("2026-10-03T16:50:00-04:00")) -Until ([DateTimeOffset]::Parse("2026-10-03T16:55:00-04:00"))).Count 0
        Check "...the FAIL text names it"                      (Get-EnginePromptLossText -Hits $hits) "Ollama truncated the prompt 1 time(s) during the run (limit=32770 prompt=83886 keep=4 new=32770)"
        $s = Get-EnginePromptLossSetup -Root "http://remote.invalid:11434" -LogDir "" -ProviderId "ollama-server"
        Check "prompt loss: a remote Ollama is not checked"    $s.Description "not checked (http://remote.invalid:11434 is not local; its server.log is on that host)"
        Check "...and not enabled"                             $s.Enabled "False"
        $s = Get-EnginePromptLossSetup -Root "" -LogDir "" -ProviderId "opencode-go"
        Check "prompt loss: no engine at all"                  $s.Description "not checked (no truncation detector for engine 'unknown', provider opencode-go)"
        Check "...no lines from a disabled setup"              @(Get-EnginePromptLoss -Setup $s -Since ([DateTimeOffset]::Now.AddHours(-1)) -Until ([DateTimeOffset]::Now)).Count 0

        $seat = "qwen3.6:35b-a3b-coding"
        Reset-Routes; Route '/api/ps$' ([pscustomobject]@{ models = @([pscustomobject]@{ name = $seat; model = $seat; size = 22.68e9; size_vram = 13.59e9 }, [pscustomobject]@{ name = "qwen2.5-coder-3b-cpu:latest"; model = "qwen2.5-coder-3b-cpu:latest"; size = 2.44e9; size_vram = 0 }) })
        $p = Get-EngineGpuPlacement -ProviderId "ollama-server" -Root "http://h" -Tag $seat
        Check "placement: a split model is gpu"                "$($p.Verdict) $($p.Share)" "gpu 0.599"
        $p = Get-EngineGpuPlacement -ProviderId "ollama-server" -Root "http://h" -Tag "qwen2.5-coder-3b-cpu"
        Check "placement: the CPU-pinned seat is cpu-only"     $p.Verdict "cpu-only"
        $p = Get-EngineGpuPlacement -ProviderId "ollama-server" -Root "http://h" -Tag "absent"
        Check "placement: absent is not-loaded"                $p.Verdict "not-loaded"
        Reset-Routes; Route '/api/ps$' "THROW"
        $p = Get-EngineGpuPlacement -ProviderId "ollama-server" -Root "http://h" -Tag $seat
        Check "placement: unreachable is unchecked"            $p.Verdict "unchecked"
    }

    # ---------------------------------------------------------------- 4. llama.cpp
    Write-Host "-- llama.cpp adapter (real functions, canned replies)"
    $sshDir = Join-Path $tmp "ssh"; $sshBin = Join-Path $sshDir "bin"
    New-Item -ItemType Directory -Path $sshBin -Force | Out-Null
    $psExe = (Get-Process -Id $PID).Path
    # Stand-in ssh: logs its arguments, answers nvidia-smi / ps from files, exits with exit.txt.
    @'
$line = ($args -join ' ')
Add-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'calls.txt') -Value $line
$code = [int](Get-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'exit.txt') -Raw).Trim()
if ($code -ne 0) { [Console]::Error.WriteLine('ssh: connect to host fixture port 22: Connection timed out'); exit $code }
if ($line -match 'nvidia-smi') { Get-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'smi.txt') }
elseif ($line -match '\bps\b') { Get-Content -LiteralPath (Join-Path $env:FIXTURE_SSH_DIR 'ps.txt') }
exit 0
'@ | Set-Content -LiteralPath (Join-Path $sshBin "ssh-standin.ps1")
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$sshBin\ssh-standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $sshBin "ssh.cmd") -Encoding ascii
    function Set-Ssh([string]$Smi, [string]$Ps, [int]$Exit = 0) {
        [IO.File]::WriteAllText((Join-Path $sshDir "smi.txt"), $Smi, $utf8)
        [IO.File]::WriteAllText((Join-Path $sshDir "ps.txt"), $Ps, $utf8)
        [IO.File]::WriteAllText((Join-Path $sshDir "exit.txt"), "$Exit", $utf8)
        [IO.File]::WriteAllText((Join-Path $sshDir "calls.txt"), "", $utf8)
    }
    $psBoth = @"
  100 /app/llama-server --models-preset /config/models.ini --port 8090
  4242 /app/llama-server --port 5001 --alias qwen3.6:35b-a3b-coding --ctx-size 65536
  4343 /app/llama-server --port 5002 --alias qwen2.5-coder-3b-cpu --device none
  4444 /app/llama-server --port 5003 --alias qwen3:8b-extra
"@
    $origPath = $env:PATH
    $env:PATH = "$sshBin;$env:PATH"
    $env:FIXTURE_SSH_DIR = $sshDir
    try {
        & {
            . $llamaPath
            Check "engine name"                                $script:EngineName "llamacpp"
            Check "var: llamacpp-desktop"                      (Get-EngineBaseUrlVar -ProviderId "llamacpp-desktop") "LLAMACPP_DESKTOP_BASE_URL"
            Check "var: llamacpp-server"                       (Get-EngineBaseUrlVar -ProviderId "llamacpp-server") "LLAMACPP_SERVER_BASE_URL"
            Check "var: llamacpp-node3"                        (Get-EngineBaseUrlVar -ProviderId "llamacpp-node3") "LLAMACPP_NODE3_BASE_URL"
            Check "var: an ollama provider is not llama.cpp's" ($null -eq (Get-EngineBaseUrlVar -ProviderId "ollama-server")) "True"
            Set-Env "LLAMACPP_SERVER_BASE_URL" "http://fx.invalid:8090/v1"
            Check "base URL: /v1 stripped"                     (Get-EngineBaseUrl -ProviderId "llamacpp-server") "http://fx.invalid:8090"
            Set-Env "LLAMACPP_SERVER_BASE_URL" $null
            Check "base URL: unset is null"                    ($null -eq (Get-EngineBaseUrl -ProviderId "llamacpp-server")) "True"
            Restore-Env

            Reset-Routes; Route '/health$' ([pscustomobject]@{ status = "ok" })
            Check "alive: /health"                             (Test-EngineAlive -Root "http://fx.invalid:8090") "True"
            Reset-Routes; Route '/health$' "THROW"
            Check "alive: unreachable"                         (Test-EngineAlive -Root "http://fx.invalid:8090") "False"

            Reset-Routes; Route '/props$' ([pscustomobject]@{ build_info = "b11561-abcdef0" })
            Check "version: build_info from the router's /props" (Get-EngineVersion -Root "http://fx.invalid:8090") "b11561-abcdef0"
            Reset-Routes; Route '/props$' "THROW"
            Check "version: unreachable is null"               ($null -eq (Get-EngineVersion -Root "http://fx.invalid:8090")) "True"
            Check "text: a build"                              (Format-EngineVersion -ProviderId "llamacpp-server" -Root "http://h" -Version "b11561-abcdef0") "llama.cpp build b11561-abcdef0"
            Check "text: unreachable"                          (Format-EngineVersion -ProviderId "llamacpp-server" -Root "http://h" -Version "") "unknown (http://h/props unreachable)"
            Check "text: base URL unset"                       (Format-EngineVersion -ProviderId "llamacpp-node3" -Root "" -Version "") "unknown (LLAMACPP_NODE3_BASE_URL is unset)"

            Reset-Routes
            Route '/models$' ([pscustomobject]@{ data = @(
                [pscustomobject]@{ id = "qwen3.6:CODING"; aliases = @("qwen3.6:35b-a3b-coding"); status = [pscustomobject]@{ value = "loaded" } },
                [pscustomobject]@{ id = "qwen3:8B"; aliases = @("qwen3:8b"); status = [pscustomobject]@{ value = "unloaded" } }) })
            Check "served models: ids and aliases from /models" ((Get-EngineServedModels -Root "http://h") -join ",") "qwen3.6:CODING,qwen3.6:35b-a3b-coding,qwen3:8B,qwen3:8b"
            Check "seat tags: one per model, the alias when it has one" ((Get-EngineSeatTags -Root "http://h") -join ",") "qwen3.6:35b-a3b-coding,qwen3:8b"
            Reset-Routes
            Route '//h/models$' "THROW"
            Route '/v1/models$' ([pscustomobject]@{ data = @([pscustomobject]@{ id = "only" }, [pscustomobject]@{ id = "other"; aliases = @() }) })
            Check "seat tags: an id without an alias, via /v1/models" ((Get-EngineSeatTags -Root "http://h") -join ",") "only,other"
            Reset-Routes; Route '/models$' "THROW"; Route '/v1/models$' "THROW"
            Check "seat tags: unreachable is null"             ($null -eq (Get-EngineSeatTags -Root "http://h")) "True"
            Reset-Routes
            Route '//h/models$' "THROW"
            Route '/v1/models$' ([pscustomobject]@{ data = @([pscustomobject]@{ id = "only" }) })
            Check "served models: falls back to /v1/models"    ((Get-EngineServedModels -Root "http://h") -join ",") "only"
            Reset-Routes; Route '/models$' "THROW"; Route '/v1/models$' "THROW"
            Check "served models: unreachable is null"         ($null -eq (Get-EngineServedModels -Root "http://h")) "True"

            # /models first: an unloaded seat's own launch args, found by its alias; /props never asked
            Reset-Routes
            Route '/models$' ([pscustomobject]@{ data = @(
                [pscustomobject]@{ id = "qwen3:8B"; aliases = @("qwen3:8b"); status = [pscustomobject]@{ value = "unloaded"; args = @("/app/llama-server", "--alias", "qwen3:8B", "--ctx-size", "32768", "--parallel", "1") } }) })
            Route '/props\?model=' "THROW"
            Check "served context: --ctx-size from /models (unloaded seat, by alias)" (Get-EngineServedContext -Root "http://h" -Tag "qwen3:8b") 32768
            Check "...without asking /props"                   (@($script:Calls | Where-Object { $_ -match '/props' }).Count) 0
            # no args for the seat: /props?model= with autoload=false
            Reset-Routes; Route '/models$' ([pscustomobject]@{ data = @() })
            Route '/props\?model=qwen3\.6%3A35b-a3b-coding&autoload=false$' ([pscustomobject]@{ default_generation_settings = [pscustomobject]@{ n_ctx = 65536 } })
            Check "served context: /props?model= n_ctx"       (Get-EngineServedContext -Root "http://h" -Tag "qwen3.6:35b-a3b-coding") 65536
            Check "...URL-encoded, and never autoloads"        (@($script:Calls)[-1]) "http://h/props?model=qwen3.6%3A35b-a3b-coding&autoload=false"
            Reset-Routes; Route '/models$' "THROW"; Route '/props\?model=' ([pscustomobject]@{ default_generation_settings = [pscustomobject]@{} })
            Check "served context: no n_ctx"                   (Get-EngineServedContext -Root "http://h" -Tag "x") "unset (no --ctx-size in /models, no n_ctx in /props?model=)"
            Reset-Routes; Route '/models$' "THROW"; Route '/props\?model=' "THROW"
            Check "served context: request failed"             (Get-EngineServedContext -Root "http://h" -Tag "x") "unknown (no --ctx-size in /models, /props?model= failed)"

            $s = Get-EnginePromptLossSetup -Root "http://h" -LogDir $tmp -ProviderId "llamacpp-server"
            Check "prompt loss: not enabled (refused explicitly)" $s.Enabled "False"
            Has   "...and says why"                            $s.Description '^not applicable: refused explicitly'
            Check "...no lines"                                @(Get-EnginePromptLoss -Setup $s -Since ([DateTimeOffset]::Now.AddHours(-1)) -Until ([DateTimeOffset]::Now)).Count 0
            Check "...a -LogDir does not turn it on"           $s.LogDir ""

            $seat = "qwen3.6:35b-a3b-coding"
            Set-Env "LLAMACPP_SERVER_SSH" "server"
            Set-Ssh "4242, 14930 MiB`n" $psBoth
            $p = Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag $seat
            Check "placement: seat in compute-apps is gpu"     "$($p.Verdict) $($p.Model)" "gpu $seat"
            Check "...14930 MiB of VRAM"                       $p.VramBytes (14930 * 1048576)
            Check "...total and share are unknown"             "$($null -eq $p.TotalBytes) $($null -eq $p.Share)" "True True"
            $calls = @(Get-Content -LiteralPath (Join-Path $sshDir "calls.txt"))
            Check "...two ssh calls: nvidia-smi, then ps"      $calls.Count 2
            Has   "...the first is BatchMode, ConnectTimeout=8, the alias, nvidia-smi" $calls[0] '^-o BatchMode=yes -o ConnectTimeout=8 server nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader$'
            Has   "...the second maps pids: ps -eo pid,args"   $calls[1] '^-o BatchMode=yes -o ConnectTimeout=8 server ps -eo pid,args$'

            Set-Ssh "4343, 100 MiB`n" $psBoth
            $p = Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag $seat
            Check "placement: loaded but only another seat on the GPU: cpu-only" $p.Verdict "cpu-only"
            Has   "...the detail names the pid"                $p.Detail 'pid 4242'
            Set-Ssh "" $psBoth
            Check "placement: loaded, nothing on the GPU: cpu-only" (Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag $seat).Verdict "cpu-only"
            $p = Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag "qwen2.5-coder-3b-cpu"
            Check "placement: the CPU-pinned seat asked for is cpu-only" $p.Verdict "cpu-only"
            Set-Ssh "4242, 14930 MiB`n" $psBoth
            Check "placement: a seat with no process is not-loaded" (Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag "qwen3:8b").Verdict "not-loaded"
            Check "...a longer alias is not a match"           (Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag "qwen3:8b-ext").Verdict "not-loaded"
            Set-Ssh "" "" 255
            $p = Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag $seat
            Check "placement: ssh failing is unchecked"        $p.Verdict "unchecked"
            Has   "...the detail carries ssh's complaint"      $p.Detail 'ssh server nvidia-smi failed \(exit 255\).*Connection timed out'
            Set-Env "LLAMACPP_SERVER_SSH" $null
            Set-Ssh "4242, 14930 MiB`n" $psBoth
            $p = Get-EngineGpuPlacement -ProviderId "llamacpp-server" -Root "http://h" -Tag $seat
            Check "placement: the env var unset is unchecked"  $p.Verdict "unchecked"
            Has   "...and the note names LLAMACPP_SERVER_SSH"  $p.Detail 'LLAMACPP_SERVER_SSH'
            Check "...with no ssh call made"                   @(Get-Content -LiteralPath (Join-Path $sshDir "calls.txt")).Count 0
            Restore-Env
        }
    } finally {
        $env:PATH = $origPath
        Remove-Item Env:FIXTURE_SSH_DIR -ErrorAction SilentlyContinue
        Restore-Env
    }

    # ---------------------------------------------------------------- 5. end to end
    Write-Host "-- end to end: the real test-tasks.ps1 for an Ollama and a llama.cpp provider"
    function Invoke-Harness([string]$harnessPath, [string]$root, [string]$model, [hashtable]$envVars) {
        foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
        Copy-Item -LiteralPath $harnessPath -Destination (Join-Path $root "tests/test-tasks.ps1")
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $root "tests") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $root "tests") -Recurse -Force
        $repo = Join-Path $root "repo"
        git -C $repo init -q
        git -C $repo config user.email "t@example.invalid"
        git -C $repo config user.name "t"
        Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
        @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
if ((Test-Path test.txt) -and $src -ne 'fixed') { Write-Host "Tests  1 failed (1)"; exit 1 }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
        git -C $repo add -A
        git -C $repo commit -q -m base
        $base = (git -C $repo rev-parse HEAD).Trim()
        @{ tasks = @([ordered]@{
            id = "fx-ok"; title = "fx-ok"; repo = $repo; branch = "bench/fx-ok"; benchBaseCommit = $base
            baselineExpect = @{ testsTotal = 1; testsPass = 1 }
            allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
            testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1"); installFlags = @(); prompt = "fix it" }) } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root "tests/tasks/manifest.json")
        @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value 'a test'
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $root "bin/standin.ps1")
        $bin = Join-Path $root "bin"
        "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
        # Driver: a child process with a stand-in Invoke-RestMethod for both engines' hosts.
        @'
param([string]$Script, [string[]]$Rest)
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType)
    $u = "$Uri"
    if ($u -match '/api/version$') { return [pscustomobject]@{ version = '0.34.3' } }
    if ($u -match '/api/show$') { return [pscustomobject]@{ parameters = 'num_ctx    65536' } }
    if ($u -match '/api/ps$') { return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'fx:latest'; model = 'fx:latest'; size = 10e9; size_vram = 6e9 }) } }
    if ($u -match '/props\?model=fx%3Atag&autoload=false$') { return [pscustomobject]@{ default_generation_settings = [pscustomobject]@{ n_ctx = 49152 } } }
    if ($u -match '/props$') { return [pscustomobject]@{ build_info = 'b11561-abcdef0' } }
    throw "fixture: no endpoint $u"
}
& $Script -Task fx-ok -Model $env:FIXTURE_MODEL -SkipInstall -RunTimeout 120 -OllamaLogDir $env:FIXTURE_NOLOG
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath (Join-Path $root "driver.ps1")
        $saved = $env:PATH
        $env:PATH = "$bin;$sshBin;$env:PATH"
        $env:FIXTURE_MODEL = $model
        $env:FIXTURE_NOLOG = Join-Path $root "no-log"
        foreach ($k in $envVars.Keys) { Set-Env $k $envVars[$k] }
        try {
            $out = & $psExe -NoProfile -File (Join-Path $root "driver.ps1") -Script (Join-Path $root "tests/test-tasks.ps1") 2>&1 | Out-String
        } finally {
            $env:PATH = $saved
            Remove-Item Env:FIXTURE_MODEL, Env:FIXTURE_NOLOG -ErrorAction SilentlyContinue
            Restore-Env
        }
        $json = Get-ChildItem (Join-Path $root "tests/results") -Filter "tasks-fx-ok-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
        [pscustomobject]@{ Output = $out; Json = $json }
    }

    $env:FIXTURE_SSH_DIR = $sshDir
    try {
        $r = Invoke-Harness $ScriptPath (Join-Path $tmp "e2e-ollama") "ollama-server/fx" @{ OLLAMA_SERVER_BASE_URL = "http://fx-ollama.invalid:11434/v1" }
        Check "ollama: the run was graded"                     ([bool]$r.Json) "True"
        Check "ollama: engine.name"                            $r.Json.engine.name "ollama"
        Check "ollama: engine.version"                         $r.Json.engine.version "0.34.3"
        Check "ollama: engine.baseUrl (no /v1)"                $r.Json.engine.baseUrl "http://fx-ollama.invalid:11434"
        Check "ollama: ollamaVersion keeps its shape"          $r.Json.ollamaVersion "ollama version is 0.34.3"
        Check "ollama: servingEngine unchanged"                "$($r.Json.servingEngine.name) $($r.Json.servingEngine.version) $($r.Json.servingEngine.endpoint) $($r.Json.servingEngine.provider)" "ollama 0.34.3 http://fx-ollama.invalid:11434 ollama-server"
        Check "ollama: numCtx from /api/show"                  $r.Json.numCtx 65536
        Check "ollama: gpuPlacement from /api/ps"              "$($r.Json.gpuPlacement.verdict) $($r.Json.gpuPlacement.share)" "gpu 0.6"
        Has   "ollama: promptTruncation not checked (no log directory)"  $r.Json.promptTruncation '^not checked \(no Ollama log directory'
        Has   "ollama: the console line is 'ollama: ...'"      $r.Output 'ollama: ollama version is 0\.34\.3 \| opencode:'

        Set-Ssh "4242, 14930 MiB`n" "  4242 /app/llama-server --port 5001 --alias fx:tag --ctx-size 49152`n"
        $r = Invoke-Harness $ScriptPath (Join-Path $tmp "e2e-llama") "llamacpp-server/fx:tag" @{ LLAMACPP_SERVER_BASE_URL = "http://fx-llama.invalid:8090/v1"; LLAMACPP_SERVER_SSH = "server" }
        Check "llamacpp: the run was graded"                   ([bool]$r.Json) "True"
        Check "llamacpp: engine.name"                          $r.Json.engine.name "llamacpp"
        Check "llamacpp: engine.version is the build"          $r.Json.engine.version "b11561-abcdef0"
        Check "llamacpp: engine.baseUrl (no /v1)"              $r.Json.engine.baseUrl "http://fx-llama.invalid:8090"
        Check "llamacpp: ollamaVersion is null"                ($null -eq $r.Json.ollamaVersion) "True"
        Check "llamacpp: servingEngine names the engine"       "$($r.Json.servingEngine.name) $($r.Json.servingEngine.provider)" "llamacpp llamacpp-server"
        Check "llamacpp: numCtx from /props?model="            $r.Json.numCtx 49152
        Has   "llamacpp: promptTruncation not applicable"      $r.Json.promptTruncation '^not applicable: refused explicitly'
        Check "llamacpp: gpuPlacement from nvidia-smi over ssh" "$($r.Json.gpuPlacement.checked) $($r.Json.gpuPlacement.verdict) $($r.Json.gpuPlacement.vramGB)" "True gpu 15.66"
        Has   "llamacpp: the console line names the engine"    $r.Output 'llamacpp: llama\.cpp build b11561-abcdef0 \| opencode:'

        # the seat is on the CPU: nothing in compute-apps -> the run is infrastructure (exit -5)
        Set-Ssh "" "  4242 /app/llama-server --port 5001 --alias fx:tag --ctx-size 49152`n"
        $r = Invoke-Harness $ScriptPath (Join-Path $tmp "e2e-llama-cpu") "llamacpp-server/fx:tag" @{ LLAMACPP_SERVER_BASE_URL = "http://fx-llama.invalid:8090/v1"; LLAMACPP_SERVER_SSH = "server" }
        Check "llamacpp CPU-only: not graded, a _CPUONLY_ transcript" ("{0} {1}" -f [bool]$r.Json, @(Get-ChildItem (Join-Path $tmp "e2e-llama-cpu/tests/results") -Filter "*_CPUONLY_*.jsonl").Count) "False 1"

        # ssh not configured: the run is graded, with an unchecked placement
        $r = Invoke-Harness $ScriptPath (Join-Path $tmp "e2e-llama-nossh") "llamacpp-server/fx:tag" @{ LLAMACPP_SERVER_BASE_URL = "http://fx-llama.invalid:8090/v1"; LLAMACPP_SERVER_SSH = $null }
        Check "llamacpp, no ssh variable: graded, placement unchecked" "$([bool]$r.Json) $($r.Json.gpuPlacement.checked) $($r.Json.gpuPlacement.verdict)" "True False unchecked"
        Has   "...the note names LLAMACPP_SERVER_SSH"          $r.Json.gpuPlacement.note 'LLAMACPP_SERVER_SSH'

        # a hosted provider: no engine
        $r = Invoke-Harness $ScriptPath (Join-Path $tmp "e2e-hosted") "opencode-go/fx" @{}
        Check "hosted provider: engine 'unknown', nothing borrowed" "$($r.Json.engine.name) $($null -eq $r.Json.engine.version) $($null -eq $r.Json.engine.baseUrl)" "unknown True True"
        Check "hosted provider: numCtx stays null"             ($null -eq $r.Json.numCtx) "True"
        Has   "hosted provider: placement not checked, as before" $r.Json.gpuPlacement.note '^not checked \(opencode-go is not an Ollama provider\)$'
    } finally {
        Remove-Item Env:FIXTURE_SSH_DIR -ErrorAction SilentlyContinue
        Restore-Env
    }

    # ---------------------------------------------------------------- 6. controls
    Write-Host "-- controls"
    $llamaText = [IO.File]::ReadAllText($llamaPath)
    $fnAst = (Get-Ast $llamaPath).FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Get-EnginePromptLoss" }, $true) | Select-Object -First 1
    $without = $llamaText.Replace($fnAst.Extent.Text, "")
    Check "an adapter without Get-EnginePromptLoss fails the interface check" ((Get-MissingFunctions $llamaPath $without) -join ",") "Get-EnginePromptLoss"
    $withoutName = $llamaText.Replace('$script:EngineName = "llamacpp"', "")
    Check "an adapter without `$script:EngineName fails it too" ((Get-MissingFunctions $llamaPath $withoutName) -join ",") '$script:EngineName'
    $dirty = $src + "`n`$ps = Invoke-RestMethod -Uri `"`$engineRoot/api/ps`"`n"
    Check "a harness with a /api/ call put back fails the boundary check" ((Get-BoundaryViolations $dirty).Count -gt 0) "True"
    $dirty2 = $src + "`n`$x = Get-OllamaGpuPlacement -Root `$r -Tag `$t`n"
    Check "...and so does a direct Get-OllamaGpuPlacement call"  ((Get-BoundaryViolations $dirty2).Count -gt 0) "True"
    $commented = $src + "`n# talks to /api/ps and server.log in a comment only`n"
    Check "...but a comment naming them is fine"            (Get-BoundaryViolations $commented).Count (Get-BoundaryViolations $src).Count
} finally {
    $env:PATH = $env:PATH
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

# protects: run-tasks-batch.ps1 engine discovery, offered seats and probes (llama.cpp hosts, hosted)
# run-after: How the batch finds hosts, offers seats or probes
# test-batch-engines.ps1 - regression guard for run-tasks-batch.ps1 driving its
# llama.cpp hosts through the adapter (tests/engines/llamacpp.ps1), the only engine
# since Ollama was removed (2026-11-21; docs/roadmap.md "Phase 2, engine adapter").
#
# Why this exists: the batch used to know Ollama alone (OLLAMA_<HOST>_BASE_URL,
# /api/tags, /api/version, `ollama-` id prefixes, one probe log). It now asks the
# adapter, loaded as a module so nothing lands in the batch's scope, and the
# registry (run-tasks-models.tsv) has an `engine` column. A probe PASS goes stale
# on host + engine + engine version, and each host keeps its own build.
#
# What it does (stand-in hosts are real HttpListeners on 127.0.0.1: two llama.cpp
# routers, the server's and node3's, plus a port nothing listens on; stand-in
# opencode, test-tasks.ps1 and test-toolcalls.ps1; no real host, no model, never
# the repo's .env):
#   1. The real functions of the batch against those hosts: provider endpoints,
#      id splitting (a removed ollama-* id is no engine), host discovery
#      (liveness, version, tags, llama.cpp aliases, a down host, /v1 stripped),
#      the probe-log reader, the probe state (PASS, FAIL, NONE, STALE on a changed
#      build, each host independent), the registry reader (new and old shape) and
#      writer (tag + engine rows), and the offered seats (an old ollama row skipped
#      as an unknown engine).
#   2. The real run-tasks-batch.ps1 end to end in a scratch tree: both hosts' seats
#      offered and run, a down host refused by the preflight (and an unset
#      variable, and as the small model), STALE and the Both-mode drop, the probe
#      invoked once per host with -Engine llamacpp -EngineHost <root> and the
#      registry row written with its engine, -OnlyMissing, the CPU-only stop for one
#      host while the other carries on, and a hosted seat.
#   3. Controls: the batch with one piece removed fails named checks.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-batch-engines.ps1 [-ScriptPath <a run-tasks-batch.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "run-tasks-batch.ps1"))

$ErrorActionPreference = "Stop"
$script:fail = 0
$script:quiet = $false
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    if (-not $script:quiet) { Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name) }
    if (-not $ok) {
        if (-not $script:quiet) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual" }
        $script:fail++
    }
}
function Section([string]$t) { if (-not $script:quiet) { Write-Host $t } }
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }
function Lacks([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "False" }

$utf8 = New-Object System.Text.UTF8Encoding $false
function Write-Fixture([string]$Path, [string]$Text) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
$script:SavedEnv = @{}
function Set-Env([string]$Name, $Value) {
    if (-not $script:SavedEnv.ContainsKey($Name)) { $script:SavedEnv[$Name] = [Environment]::GetEnvironmentVariable($Name) }
    [Environment]::SetEnvironmentVariable($Name, $(if ($null -eq $Value) { [NullString]::Value } else { $Value }))
}
function Restore-Env {
    foreach ($k in @($script:SavedEnv.Keys)) { [Environment]::SetEnvironmentVariable($k, $(if ($null -eq $script:SavedEnv[$k]) { [NullString]::Value } else { $script:SavedEnv[$k] })) }
    $script:SavedEnv = @{}
}
# Every variable the batch or an adapter reads about a host, set by each scenario, never inherited.
# The OLLAMA_* ones are cleared too, so a leftover one in the caller's shell cannot leak in.
$hostVars = "OLLAMA_DESKTOP_BASE_URL", "OLLAMA_NODE3_BASE_URL", "OLLAMA_SERVER_BASE_URL",
            "LLAMACPP_DESKTOP_BASE_URL", "LLAMACPP_NODE3_BASE_URL", "LLAMACPP_SERVER_BASE_URL",
            "LLAMACPP_SERVER_SSH", "LLAMACPP_NODE3_SSH", "LLAMACPP_DESKTOP_SSH", "OPENCODE_SMALL_MODEL", "OPENCODE_MODEL"
function Clear-HostEnv { foreach ($v in $hostVars) { Set-Env $v $null } }

# --- stand-in hosts: real listeners on loopback ---------------------------------
function Get-FreePort {
    $t = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $t.Start(); $p = $t.LocalEndpoint.Port; $t.Stop(); return $p
}
function Start-FakeHost([hashtable]$Routes) {
    # path -> JSON text; "DOWN" aborts the connection; anything unlisted is a 404.
    $routes = [hashtable]::Synchronized($Routes)
    $hits = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $port = Get-FreePort
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://127.0.0.1:$port/")
    $l.Start()
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($l, $routes, $hits)
        while ($l.IsListening) {
            try { $c = $l.GetContext() } catch { break }
            try {
                $path = $c.Request.Url.AbsolutePath
                $null = $hits.Add("$($c.Request.HttpMethod) $path")
                $r = $routes[$path]
                if ($r -eq "DOWN") { $c.Response.Abort(); continue }
                if ($null -eq $r) { $c.Response.StatusCode = 404; $r = '{"error":"no route"}' }
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$r)
                $c.Response.ContentType = "application/json"
                $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $c.Response.Close()
            } catch { }
        }
    }).AddArgument($l).AddArgument($routes).AddArgument($hits)
    $null = $ps.BeginInvoke()
    return [pscustomobject]@{ Port = $port; Url = "http://127.0.0.1:$port"; Routes = $routes; Hits = $hits; Listener = $l; Shell = $ps }
}
function Stop-FakeHost($H) { try { $H.Listener.Stop(); $H.Listener.Close() } catch { }; try { $H.Shell.Dispose() } catch { } }

# The server's router: three models (ids differ from their aliases), build b11561.
$llamaModels = '{"data":[{"id":"qwen3.6:CODING","aliases":["qwen3.6:35b-a3b-coding"],"status":{"value":"loaded"}},' +
               '{"id":"qwen3:8B","aliases":["qwen3:8b"],"status":{"value":"unloaded"}},' +
               '{"id":"qwen3.7:NEW","aliases":["qwen3.7:new"],"status":{"value":"unloaded"}}]}'
$llamaRoutes = @{
    "/health" = '{"status":"ok"}'
    "/models" = $llamaModels
    "/props"  = '{"build_info":"b11561-abcdef0"}'
}
# node3's router: one model, its own (older) build.
$node3Routes = @{
    "/health" = '{"status":"ok"}'
    "/models" = '{"data":[{"id":"qwen3:8B","aliases":["qwen3:8b"],"status":{"value":"loaded"}}]}'
    "/props"  = '{"build_info":"b11000-1234567"}'
}
$llamaHost = Start-FakeHost $llamaRoutes
$node3Host = Start-FakeHost $node3Routes
$deadPort  = Get-FreePort    # nothing listens: a llama.cpp host that is down
$deadUrl   = "http://127.0.0.1:$deadPort"

# --- the real batch functions, from a script text (a control passes a changed one) ---
$script:EngineModules = @{}
foreach ($k in @("llamacpp")) {
    $script:EngineModules[$k] = [psmoduleinfo]::new([scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot "engines\$k.ps1"))))
}
$batchFunctions = @("Invoke-Engine", "Get-EngineKind", "Get-ProviderEndpoint", "Split-ModelId", "Get-EngineHosts", "Get-EngineDisplayName",
                    "Get-ProbeLog", "Get-ProbeState", "Format-ProbeNote", "Get-RegistryRows", "Add-RegistrySeat",
                    "Get-AvailableModelSeats", "Test-EngineEndpoint", "Test-HostedModelId", "Get-HostedSeatGate")
function Get-BatchFunctionText([string]$ScriptText) {
    $tmpFile = Join-Path ([IO.Path]::GetTempPath()) ("batch-eng-" + [guid]::NewGuid().ToString("N") + ".ps1")
    try {
        [IO.File]::WriteAllText($tmpFile, $ScriptText)
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($tmpFile.Replace('\', '/'), [ref]$null, [ref]$errs)
        if ($errs.Count) { $errs; exit 2 }
        $all = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $out = @()
        foreach ($name in $batchFunctions) {
            $fn = $all | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if (-not $fn) { Write-Host "FAIL: $name not found in the batch script"; exit 2 }
            $out += $fn.Extent.Text
        }
        return $out
    } finally { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
}

$origPath = $env:PATH
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("batch-engines-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function Invoke-UnitChecks([string]$ScriptText) {
    # Defines the batch's functions locally (dynamic scope carries them and the
    # variables below to each other) and checks them against the stand-in hosts.
    foreach ($text in (Get-BatchFunctionText $ScriptText)) { Invoke-Expression $text }

    Section "-- provider endpoints and ids"
    Clear-HostEnv
    Set-Env "LLAMACPP_NODE3_BASE_URL" "http://n3:8080/v1/"
    Set-Env "LLAMACPP_SERVER_BASE_URL" "http://srv:8090/v1"
    $p = Get-ProviderEndpoint -ModelId "llamacpp-node3/qwen3:8b"
    Check "node3 provider: variable, engine, root (/v1 and slash stripped)" ("{0} {1} {2}" -f $p.VarName, $p.Engine, $p.Root) "LLAMACPP_NODE3_BASE_URL llamacpp http://n3:8080"
    Check "...BaseUrl is the variable as set"                          $p.BaseUrl "http://n3:8080/v1/"
    $p = Get-ProviderEndpoint -ModelId "llamacpp-server/qwen3.6:35b-a3b-coding"
    Check "server provider: variable, engine, root"                    ("{0} {1} {2}" -f $p.VarName, $p.Engine, $p.Root) "LLAMACPP_SERVER_BASE_URL llamacpp http://srv:8090"
    $p = Get-ProviderEndpoint -ModelId "llamacpp-desktop/x"
    Check "a provider whose variable is unset: named, no root"         ("{0} [{1}]" -f $p.VarName, $p.Root) "LLAMACPP_DESKTOP_BASE_URL []"
    $p = Get-ProviderEndpoint -ModelId "llamacpp-lab/x"
    Check "a host the adapter does not know: PREFIX_HOST_BASE_URL"     $p.VarName "LLAMACPP_LAB_BASE_URL"
    Check "a hosted provider has no endpoint"                          ($null -eq (Get-ProviderEndpoint -ModelId "opencode-go/alpha")) "True"
    Check "Get-EngineKind: llamacpp, removed ollama, hosted, bare provider" ("{0} [{1}] [{2}] {3}" -f (Get-EngineKind "llamacpp-node3/y"), (Get-EngineKind "ollama-server/x"), (Get-EngineKind "opencode-go/z"), (Get-EngineKind "llamacpp-server")) "llamacpp [] [] llamacpp"
    $m = Split-ModelId "llamacpp-server/qwen3:8b"
    Check "Split-ModelId: llamacpp"                                    ("{0} {1} {2} {3}" -f $m.Provider, $m.Engine, $m.Host, $m.Tag) "llamacpp-server llamacpp server qwen3:8b"
    $m = Split-ModelId "llamacpp-node3/laguna-xs-2.1:latest"
    Check "Split-ModelId: :latest dropped"                             ("{0} {1} {2} {3}" -f $m.Provider, $m.Engine, $m.Host, $m.Tag) "llamacpp-node3 llamacpp node3 laguna-xs-2.1"
    $m = Split-ModelId "ollama-desktop/qwen3:8b"
    Check "Split-ModelId: a removed ollama id has no engine and no host" ("[{0}] [{1}]" -f $m.Engine, $m.Host) "[] []"
    $m = Split-ModelId "opencode-go/alpha"
    Check "Split-ModelId: hosted has no engine and no host"            ("[{0}] [{1}] {2}" -f $m.Engine, $m.Host, $m.Tag) "[] [] alpha"

    Section "-- host discovery (stand-in llama.cpp routers)"
    Clear-HostEnv
    Set-Env "LLAMACPP_SERVER_BASE_URL" "$($llamaHost.Url)/v1"
    Set-Env "LLAMACPP_NODE3_BASE_URL" "$($node3Host.Url)/v1"
    Set-Env "LLAMACPP_DESKTOP_BASE_URL" "$deadUrl/v1"
    Set-Env "OLLAMA_SERVER_BASE_URL" "$($llamaHost.Url)/v1"    # a leftover Ollama variable finds nothing
    $node3Host.Hits.Clear(); $llamaHost.Hits.Clear()
    $hosts = @(Get-EngineHosts)
    Check "three hosts found (one per LLAMACPP_ variable set, none for OLLAMA_)" (($hosts | ForEach-Object Provider) -join ",") "llamacpp-desktop,llamacpp-node3,llamacpp-server"
    $s = $hosts | Where-Object Provider -eq "llamacpp-server"
    Check "server: up, version is the router's build"                  ("{0} {1}" -f $s.Up, $s.Version) "True b11561-abcdef0"
    Check "server: root has no /v1"                                    $s.Root $llamaHost.Url
    Check "server: tags are ids plus aliases"                          ($s.Tags -join ",") "qwen3.6:CODING,qwen3.6:35b-a3b-coding,qwen3:8B,qwen3:8b,qwen3.7:NEW,qwen3.7:new"
    Check "server: seat tags are one per model, the alias"             ($s.SeatTags -join ",") "qwen3.6:35b-a3b-coding,qwen3:8b,qwen3.7:new"
    $n = $hosts | Where-Object Provider -eq "llamacpp-node3"
    Check "node3: up, its own build and tags"                          ("{0} {1} {2}" -f $n.Up, $n.Version, ($n.Tags -join ",")) "True b11000-1234567 qwen3:8B,qwen3:8b"
    $d = $hosts | Where-Object Provider -eq "llamacpp-desktop"
    Check "a host that does not answer is down, with no tags"          ("{0} [{1}] {2}" -f $d.Up, $d.Version, @($d.Tags).Count) "False [] 0"
    Check "liveness asked /health on both hosts"                       ((@($llamaHost.Hits | Where-Object { $_ -eq "GET /health" }).Count -ge 1) -and (@($node3Host.Hits | Where-Object { $_ -eq "GET /health" }).Count -ge 1)) "True"
    Check "...and no host was asked an Ollama /api/ endpoint"          (@(@($llamaHost.Hits) + @($node3Host.Hits) | Where-Object { $_ -like "*/api/*" }).Count) 0
    $e = Test-EngineEndpoint -Provider "llamacpp-server" -Root $llamaHost.Url
    Check "Test-EngineEndpoint: up, counts model ids"                  ("{0} {1}" -f $e.Ok, $e.Detail) "True 6 model id(s)"
    $e = Test-EngineEndpoint -Provider "llamacpp-desktop" -Root $deadUrl
    Check "Test-EngineEndpoint: down"                                  ("{0} {1}" -f $e.Ok, ($e.Detail -match 'llama\.cpp not answering')) "False True"

    Section "-- probe log, and STALE on host + engine + version"
    $llamaLog = Join-Path $tmp "unit-llama-log.tsv"
    Write-Fixture $llamaLog ("timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail`n" +
        "2026-10-16T09:00:00`tserver`tllamacpp`tb11561-abcdef0`tqwen3.6:35b-a3b-coding`tPASS`t30`ty`n" +
        "2026-10-16T09:05:00`tserver`tllamacpp`tb11561-abcdef0`tqwen3:8b`tFAIL`t30`ty`n" +
        "2026-10-17T09:00:00`tnode3`tllamacpp`tb11000-1234567`tqwen3:8b`tPASS`t20`ty`n" +
        "2026-10-17T09:01:00`tnode3`tllamacpp`tb10999-0000000`told:latest`tPASS`t20`ty`n")
    $probeLogPaths = @{ llamacpp = $llamaLog }
    $probeLog = Get-ProbeLog
    $probeKeys = [string[]]@($probeLog.Keys); [Array]::Sort($probeKeys, [StringComparer]::Ordinal)
    Check "reader: keys are provider/model, :latest dropped"           ($probeKeys -join " ") "llamacpp-node3/old llamacpp-node3/qwen3:8b llamacpp-server/qwen3.6:35b-a3b-coding llamacpp-server/qwen3:8b"
    Check "reader: a row keeps its engine and build"                   ("{0} {1}" -f $probeLog["llamacpp-node3/qwen3:8b"].engine, $probeLog["llamacpp-node3/qwen3:8b"].engineVersion) "llamacpp b11000-1234567"
    $hostVersions = @{ "llamacpp-server" = "b11561-abcdef0"; "llamacpp-node3" = "b11000-1234567" }
    Check "state: PASS on the current build"                           (Get-ProbeState "llamacpp-server/qwen3.6:35b-a3b-coding") "PASS"
    Check "state: FAIL on the current build"                           (Get-ProbeState "llamacpp-server/qwen3:8b") "FAIL"
    Check "state: the same tag on node3 has its own result"            (Get-ProbeState "llamacpp-node3/qwen3:8b") "PASS"
    Check "state: PASS on an older build is STALE"                     (Get-ProbeState "llamacpp-node3/old") "STALE"
    Check "state: same tag on a host with no row is NONE"              (Get-ProbeState "llamacpp-desktop/qwen3:8b") "NONE"
    Check "state: a removed ollama id is NONE"                         (Get-ProbeState "ollama-desktop/qwen3:8b") "NONE"
    $hostVersions["llamacpp-server"] = "b12000-0000000"
    Check "state: the server's build changed: STALE"                   (Get-ProbeState "llamacpp-server/qwen3.6:35b-a3b-coding") "STALE"
    Check "state: ...and node3's result is untouched by it"            (Get-ProbeState "llamacpp-node3/qwen3:8b") "PASS"
    Has   "note: names the old build and the host's now"               (Format-ProbeNote "llamacpp-server/qwen3.6:35b-a3b-coding") 'probe: PASS on b11561-abcdef0, 2026-10-16; host now b12000-0000000'
    Has   "note: a current row has no 'host now'"                      (Format-ProbeNote "llamacpp-node3/qwen3:8b") '^\[probe: PASS on b11000-1234567, 2026-10-17\]$'
    Check "state: a host not answering has no current version: not STALE" ((Get-ProbeState "llamacpp-desktop/qwen3.6:35b-a3b-coding") -eq "NONE") "True"
    $hostVersions.Remove("llamacpp-server")
    Check "state: no current version known: the row's status"          (Get-ProbeState "llamacpp-server/qwen3.6:35b-a3b-coding") "PASS"

    Section "-- registry: reader and writer"
    $registryPath = Join-Path $tmp "unit-registry.tsv"
    Write-Fixture $registryPath ("# fixture`ntag`tengine`thosts`tdesc`n" +
        "qwen3:8b`tllamacpp`tnode3`tlight`n" +
        "qwen3.6:35b-a3b-coding`tllamacpp`tserver`tmain seat`n" +
        "alpha`topencode-go`topencode-go`thosted`n")
    $rows = @(Get-RegistryRows)
    Check "reader: rows with engine, hosts, desc"                      (($rows | ForEach-Object { "{0}/{1}/{2}" -f $_.Tag, $_.Engine, ($_.Hosts -join "+") }) -join " ") "qwen3:8b/llamacpp/node3 qwen3.6:35b-a3b-coding/llamacpp/server alpha/opencode-go/opencode-go"
    Add-RegistrySeat -Tag "qwen3:8b" -Engine "llamacpp" -HostLabel "server" -Version "b1" 6>$null
    Add-RegistrySeat -Tag "qwen3:8b" -Engine "llamacpp" -HostLabel "server" -Version "b1" 6>$null
    Add-RegistrySeat -Tag "qwen3:8b" -Engine "vllm" -HostLabel "server" -Version "1" 6>$null
    Add-RegistrySeat -Tag "qwen3.7:new" -Engine "llamacpp" -HostLabel "server" -Version "b1" 6>$null
    Add-RegistrySeat -Tag "qwen3.7:new" -Engine "llamacpp" -HostLabel "server" -Version "b1" 6>$null
    $lines = @(Get-Content -LiteralPath $registryPath | Where-Object { $_ -and -not $_.StartsWith("#") })
    Check "writer: the row gains the host once (tag + engine match)"   ((($lines[1] -split "`t")[0..2]) -join "|") "qwen3:8b|llamacpp|node3 server"
    Check "writer: the same tag on another engine is a row of its own" (@($lines | Where-Object { $_ -like "qwen3:8b`tvllm`tserver`t*" }).Count) 1
    Check "writer: a new tag is a new row with its engine, once"       (@($lines | Where-Object { $_ -like "qwen3.7:new`tllamacpp`tserver`t*" }).Count) 1
    Check "writer: the file ends with one newline, LF only"            (([IO.File]::ReadAllText($registryPath) -match "`n$") -and ([IO.File]::ReadAllText($registryPath) -notmatch "`r")) "True"
    Write-Fixture $registryPath "tag`thosts`tdesc`nqwen3:8b`tdesktop`told shape`nalpha`topencode-go`thosted`n"
    $rows = @(Get-RegistryRows)
    Check "reader: the old tag/hosts/desc shape reads as unknown, or opencode-go" (($rows | ForEach-Object { "{0}/{1}" -f $_.Tag, $_.Engine }) -join " ") "qwen3:8b/unknown alpha/opencode-go"
    $threw = $false
    try { Add-RegistrySeat -Tag "x" -Engine "llamacpp" -HostLabel "server" -Version "1" 6>$null } catch { $threw = $true }
    Check "writer: a registry with no engine column is refused, not corrupted" ($threw -and ([IO.File]::ReadAllText($registryPath) -notmatch "`tx`t")) "True"

    Section "-- offered seats (the real Get-AvailableModelSeats)"
    $registryPath = Join-Path $tmp "unit-registry2.tsv"
    Write-Fixture $registryPath ("tag`tengine`thosts`tdesc`n" +
        "qwen3:8b`tllamacpp`tnode3 server`tlight`n" +
        "qwen3.6:35b-a3b-coding`tllamacpp`tserver node3`tmain seat`n" +
        "qwen3:14b`tllamacpp`tserver desktop`tnot served there`n" +
        "qwen3:4b`tllamacpp`tlab`ta host with no variable`n" +
        "qwen3:8b`tollama`tdesktop`ta row left from Ollama`n" +
        "weird`tvllm`tserver`tunknown engine`n" +
        "alpha`topencode-go`topencode-go`thosted`n")
    $engineHosts = $hosts
    $hostedState = $null
    $out = (@(Get-AvailableModelSeats 6>&1) | ForEach-Object { "$_" })
    $seats = @($out | Where-Object { $_ -match '^llamacpp-[a-z0-9]+/' })
    Check "seats: served on an up host only"                           ($seats -join " ") "llamacpp-node3/qwen3:8b llamacpp-server/qwen3:8b llamacpp-server/qwen3.6:35b-a3b-coding"
    Has   "skip: a down host"                                          ($out -join "`n") '\[skip\] llamacpp-desktop - host not answering'
    Has   "skip: a host whose variable is unset names it"              ($out -join "`n") '\[skip\] llamacpp-lab - LLAMACPP_LAB_BASE_URL is not set in this shell'
    Has   "skip: a tag the host does not serve"                        ($out -join "`n") "\[skip\] llamacpp-server - tag 'qwen3:14b' not served there yet"
    Has   "skip: ...on node3 too (it serves only qwen3:8b)"             ($out -join "`n") "\[skip\] llamacpp-node3 - tag 'qwen3\.6:35b-a3b-coding' not served there yet"
    Has   "skip: an old ollama row is an unknown engine, not a seat"   ($out -join "`n") "\[skip\] qwen3:8b - unknown engine 'ollama'"
    Has   "skip: an unknown engine"                                    ($out -join "`n") "unknown engine 'vllm'"
    Lacks "no ollama-* seat is ever offered"                           ($out -join "`n") '(?m)^ollama-'
}

try {
    Write-Host "== unit checks against the real batch"
    $realText = [IO.File]::ReadAllText($ScriptPath)
    Invoke-UnitChecks $realText

    # --- end to end ------------------------------------------------------------
    Write-Host "== end to end: the real run-tasks-batch.ps1 against the stand-in hosts"
    $bin = Join-Path $tmp "bin"
    $fx  = Join-Path $tmp "fixture"
    New-Item -ItemType Directory -Path $bin, $fx -Force | Out-Null
    $keyFile = Join-Path $fx "opencode-go-api-key"
    Write-Fixture $keyFile "not a real key"

    $registryText = "# fixture registry`ntag`tengine`thosts`tdesc`n" +
        "qwen3:8b`tllamacpp`tnode3`tnode3 seat`n" +
        "qwen3.6:35b-a3b-coding`tllamacpp`tserver`tllama.cpp main seat`n" +
        "qwen3:4b`tllamacpp`tdesktop`ta seat on a host that is down`n" +
        "alpha`topencode-go`topencode-go`thosted`n"
    $ratesText = "model`tplan`ttier`tinputPerM`toutputPerM`tcacheReadPerM`tcacheWritePerM`tmonthlyLimitUsd`tchecked`tsource`n" +
        "opencode-go/alpha`tgo`t`t2.00`t4.00`t0.50`t`t10`t2026-10-06`tfixture`n"
    $now = [datetime]::UtcNow
    $planText = "plan`tmeter`tlimitUsd`tperiod`tanchorUtc`tchecked`tbasis`n" +
        "go`twindow`t900`t5h`t`t2026-10-07`tfixture`n" +
        ("go`tweek`t900`t7d`t{0}`t2026-10-07`tfixture`n" -f $now.AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ")) +
        ("go`tmonth`t900`t1mo`t{0}`t2026-10-07`tfixture`n" -f $now.AddDays(-12).ToString("yyyy-MM-ddTHH:mm:ssZ"))
    $configJson = '{"autoupdate":"notify","provider":{"llamacpp-server":{"models":{"qwen3.6:35b-a3b-coding":{},"qwen3:8b":{},"qwen3.7:new":{}}},' +
                  '"llamacpp-node3":{"models":{"qwen3:8b":{}}},"llamacpp-desktop":{"models":{"qwen3:4b":{}}}}}'
    # The Ollama-era log: history the batch no longer reads (its seats are gone).
    $ollamaLogText = "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail`n2026-10-06T09:00:00`tnode3`t0.34.3`tqwen3:8b`tFAIL`t10`tfixture`n"
    $llamaLogText  = "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail`n" +
                     "2026-10-16T09:00:00`tserver`tllamacpp`tb11561-abcdef0`tqwen3.6:35b-a3b-coding`tPASS`t30`tfixture`n" +
                     "2026-10-17T09:00:00`tnode3`tllamacpp`tb11000-1234567`tqwen3:8b`tPASS`t20`tfixture`n"

    Write-Fixture "$bin\opencode.cmd" ((@'
@echo off
echo %*>>"%FIXTURE_DIR%\opencode-calls.txt"
if "%~1"=="--version" goto version
if "%~1"=="models" goto models
if "%~1"=="debug" goto debug
if "%~1"=="db" goto db
exit /b 2
:version
echo 9.9.9
exit /b 0
:models
type "%FIXTURE_DIR%\go-models.txt"
exit /b 0
:debug
type "%FIXTURE_DIR%\config.json"
exit /b 0
:db
echo []
exit /b 0
'@) -replace "`r?`n", "`r`n")
    Write-Fixture (Join-Path $fx "go-models.txt") "opencode-go/alpha`r`n"
    Write-Fixture (Join-Path $fx "config.json") $configJson

    $stubTasks = @'
param([string[]]$Task, [string]$Model, [string]$ModelLabel, [int]$RunTimeout, [int]$CommandTimeout,
      [switch]$IncludeRetired, [string]$TaskManifest, [string]$ResultsDir)
$t = $Task[0]
Add-Content -LiteralPath $env:FIXTURE_CALLS -Value "$t|$Model"
$label = $ModelLabel -replace '[^a-zA-Z0-9._-]', '_'
$n = @(Get-ChildItem -LiteralPath $ResultsDir -File).Count
$stamp = "20261016-{0:D6}" -f $n
$enc = New-Object System.Text.UTF8Encoding $false
if ($t -eq 'fx-cpu' -and $Model -like 'llamacpp-server/*') {
    [IO.File]::WriteAllText((Join-Path $ResultsDir ("tasks-{0}-{1}_CPUONLY_{2}.jsonl" -f $t, $label, $stamp)), "{}`n", $enc)
    Write-Host "  [FAIL] opencode run - fixture: the seat was not on the GPU"
    exit 1
}
$base = Join-Path $ResultsDir ("tasks-{0}-{1}_{2}" -f $t, $label, $stamp)
[IO.File]::WriteAllText("$base.jsonl", "{}`n", $enc)
[IO.File]::WriteAllText("$base.json", ('{"taskId":"' + $t + '"}'), $enc)
exit 0
'@
    # Stand-in test-toolcalls.ps1: the real script's parameters (llama.cpp only since
    # 2026-11-21), records how it was called, and logs one row per model in the real
    # log's shape (PASS, or FAIL for a tag containing "bad"; nothing when told not to).
    # The build it logs is the one the probed host reports.
    $stubProbe = @'
[CmdletBinding()]
param([string[]]$Model, [string]$EngineHost, [string]$HostLabel,
      [string]$Engine = "llamacpp", [string]$LogFile, [switch]$NoLog, [int]$TimeoutSec, [switch]$KeepLoaded)
Add-Content -LiteralPath $env:FIXTURE_PROBES -Value ("{0}|{1}|{2}|{3}" -f $Engine, $EngineHost, $HostLabel, ($Model -join ","))
if ($Engine -ne "llamacpp") { exit 2 }
if ($env:FIXTURE_PROBE_NOLOG) { exit 0 }
$enc = New-Object System.Text.UTF8Encoding $false
$ver = (Invoke-RestMethod -Uri "$EngineHost/props" -TimeoutSec 5).build_info
if (-not (Test-Path -LiteralPath $LogFile)) {
    [IO.File]::WriteAllText($LogFile, "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail`n", $enc)
}
foreach ($m in $Model) {
    $st = if ($m -like "*bad*") { "FAIL" } else { "PASS" }
    [IO.File]::AppendAllText($LogFile, "2026-10-18T12:00:00`t$HostLabel`t$Engine`t$ver`t$m`t$st`t1`tfixture`n", $enc)
}
exit 0
'@
    $driver = @'
param([string]$Script, [string]$ArgsFile)
$a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json
$splat = @{}
foreach ($p in $a.PSObject.Properties) {
    $v = $p.Value
    if ($v -is [array]) { $splat[$p.Name] = [string[]]$v } else { $splat[$p.Name] = $v }
}
& $Script @splat
exit $LASTEXITCODE
'@
    Write-Fixture "$tmp\driver.ps1" $driver
    $psExe = (Get-Process -Id $PID).Path

    function New-BatchTree([string]$Name, [string]$BatchText) {
        $tree = Join-Path $tmp $Name
        foreach ($d in "$tree\tests\tasks", "$tree\tests\results", "$tree\costs") { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        Write-Fixture "$tree\tests\run-tasks-batch.ps1" $BatchText
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination "$tree\tests" -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination "$tree\tests" -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "checks") -Destination "$tree\tests" -Recurse -Force
        Write-Fixture "$tree\tests\test-tasks.ps1" $stubTasks
        Write-Fixture "$tree\tests\test-toolcalls.ps1" $stubProbe
        Write-Fixture "$tree\costs\go-rates.tsv" $ratesText
        Write-Fixture "$tree\costs\go-plan.tsv" $planText
        $bm = @{ tasks = @(foreach ($id in "fx-cpu", "t1", "t2", "t3") { [ordered]@{ id = $id; title = "fixture $id" } }) }
        Write-Fixture "$tree\tests\tasks\manifest.json" ($bm | ConvertTo-Json -Depth 5)
        return $tree
    }
    function Reset-Tree($Tree) {
        Write-Fixture "$Tree\tests\run-tasks-models.tsv" $registryText
        Write-Fixture "$Tree\tests\results\toolcalls-summary.tsv" $ollamaLogText
        Write-Fixture "$Tree\tests\results\toolcalls-summary-llamacpp.tsv" $llamaLogText
    }

    $script:scn = 0
    function Invoke-Batch($Tree, [hashtable]$BatchArgs, [hashtable]$Env = @{}, [string]$TasksSummary = "") {
        $script:scn++
        Reset-Tree $Tree
        $rdir = Join-Path $tmp "results-$($script:scn)"
        New-Item -ItemType Directory -Path $rdir -Force | Out-Null
        if ($TasksSummary) { Write-Fixture (Join-Path $rdir "tasks-summary.tsv") $TasksSummary }
        $calls = Join-Path $tmp "calls-$($script:scn).txt";   Write-Fixture $calls ""
        $probes = Join-Path $tmp "probes-$($script:scn).txt"; Write-Fixture $probes ""
        $all = @{ SkipSetup = $true; Mode = "Tasks"; Reps = 1; Yes = $true; ResultsDir = $rdir; GoKeyFile = $keyFile }
        foreach ($k in $BatchArgs.Keys) { $all[$k] = $BatchArgs[$k] }
        $argsFile = Join-Path $tmp "args-$($script:scn).json"
        Write-Fixture $argsFile ($all | ConvertTo-Json -Depth 4)
        Clear-HostEnv
        # the defaults: the server and node3 up, the desktop's variable pointing at a dead port
        Set-Env "LLAMACPP_SERVER_BASE_URL" "$($llamaHost.Url)/v1"
        Set-Env "LLAMACPP_NODE3_BASE_URL" "$($node3Host.Url)/v1"
        Set-Env "LLAMACPP_DESKTOP_BASE_URL" "$deadUrl/v1"
        foreach ($k in $Env.Keys) { Set-Env $k $Env[$k] }
        Set-Env "PATH" "$bin;$origPath"
        Set-Env "FIXTURE_DIR" $fx
        Set-Env "FIXTURE_CALLS" $calls
        Set-Env "FIXTURE_PROBES" $probes
        Set-Env "FIXTURE_PROBE_NOLOG" $(if ($Env.ContainsKey("FIXTURE_PROBE_NOLOG")) { $Env["FIXTURE_PROBE_NOLOG"] } else { $null })
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File "$tmp\driver.ps1" -Script "$Tree\tests\run-tasks-batch.ps1" -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            Restore-Env
        }
        $callLines = @(Get-Content -LiteralPath $calls | Where-Object { $_ })
        return [pscustomobject]@{
            Out    = ($out -replace '\x1b\[[0-9;]*m', ''); Exit = $code
            Calls  = (($callLines | Sort-Object) -join " ")
            Seen   = (@($callLines | ForEach-Object { $p = $_ -split '\|'; "{0}@{1}" -f $p[0], ($p[1] -split '/')[0] }) -join ",")
            Probes = @(Get-Content -LiteralPath $probes | Where-Object { $_ })
            Registry = [IO.File]::ReadAllText("$Tree\tests\run-tasks-models.tsv")
        }
    }

    $tree = New-BatchTree "tree" $realText
    $node3Seat = "llamacpp-node3/qwen3:8b"
    $llamaSeat = "llamacpp-server/qwen3.6:35b-a3b-coding"

    Write-Host "   scenario: -Models all, Tasks mode: both hosts' seats, a down host skipped"
    $llamaHost.Hits.Clear(); $node3Host.Hits.Clear()
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @("all") }
    Check "exit 0"                                      $r.Exit 0
    Check "the server seat and the node3 seat ran (alias served; desktop down; hosted not in 'all')" $r.Calls "t1|$node3Seat t1|$llamaSeat"
    Has   "skip: llamacpp-desktop not answering"         $r.Out '\[skip\] llamacpp-desktop - host not answering'
    Has   "preflight: the server passes with its id count (the /v1 surface kept in the line)" $r.Out '\[PASS\] llamacpp-server\s+http://127\.0\.0\.1:\d+/v1 - 6 model id\(s\)'
    Has   "preflight: node3 passes with its own count"   $r.Out '\[PASS\] llamacpp-node3\s+http://127\.0\.0\.1:\d+/v1 - 2 model id\(s\)'
    Check "the hosts were asked /health, never an /api/ endpoint" ((@($llamaHost.Hits | Where-Object { $_ -eq "GET /health" }).Count -ge 1) -and (@(@($llamaHost.Hits) + @($node3Host.Hits) | Where-Object { $_ -like "*/api/*" }).Count -eq 0)) "True"
    Lacks "the Ollama-era probe log's FAIL for qwen3:8b on node3 is not read" $r.Out "$([regex]::Escape($node3Seat)) - probe FAIL"

    Write-Host "   scenario: a down host is refused by the endpoint preflight"
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @("llamacpp-desktop/qwen3:4b") }
    Check "exit 1, no run started"                       ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    Has   "[FAIL] names the provider and the engine"     $r.Out '\[FAIL\] llamacpp-desktop\s+http://127\.0\.0\.1:\d+/v1 - llama\.cpp not answering at'
    Has   "...and the batch is not started"              $r.Out '1 endpoint\(s\) not answering - not starting the batch'
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($node3Seat) } @{ LLAMACPP_NODE3_BASE_URL = $null }
    Check "an unset variable: exit 1, no run"            ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    Has   "...the FAIL names the variable"               $r.Out '\[FAIL\] llamacpp-node3\s+LLAMACPP_NODE3_BASE_URL is not set'
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($llamaSeat) } @{ OPENCODE_SMALL_MODEL = "llamacpp-desktop/qwen3:4b" }
    Check "a dead host as the small model also stops the batch" ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    Has   "...[FAIL] llamacpp-desktop"                   $r.Out '\[FAIL\] llamacpp-desktop'

    Write-Host "   scenario: the server's llama.cpp build changed (STALE)"
    $llamaHost.Routes["/props"] = '{"build_info":"b12000-1111111"}'
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($llamaSeat, $node3Seat) }
    Check "Tasks mode: both run, with a WARN for the server seat" ("{0} {1}" -f $r.Exit, $r.Calls) "0 t1|$node3Seat t1|$llamaSeat"
    Has   "...WARN says STALE on the host's current version"  $r.Out "WARN: $([regex]::Escape($llamaSeat)) - probe STALE on this host's current version"
    Lacks "...and none for node3, whose build did not move"   $r.Out "WARN: $([regex]::Escape($node3Seat))"
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($llamaSeat, $node3Seat); Mode = "Both" } @{ FIXTURE_PROBE_NOLOG = "1" }
    Check "Both mode, the probe logged nothing new: the stale server seat is dropped, node3 runs" ("{0} {1}" -f $r.Exit, $r.Calls) "0 t1|$node3Seat"
    Has   "...[drop] names STALE and the engine version"      $r.Out "\[drop\] $([regex]::Escape($llamaSeat)) - probe STALE on this host's current engine version"
    $llamaHost.Routes["/props"] = '{"build_info":"b11561-abcdef0"}'

    Write-Host "   scenario: Probe mode probes each host once and writes the registry row with its engine"
    function Scenario-Probe($Tree) {
        $models = @($node3Seat, "llamacpp-server/qwen3:8b", "llamacpp-server/qwen3.7:new")
        $r = Invoke-Batch $Tree @{ Mode = "Probe"; Models = $models; Tasks = @("t1") }
        Check "exit 0"                                       $r.Exit 0
        Check "two probe calls, one per host"                $r.Probes.Count 2
        Check "the probes: -Engine llamacpp -EngineHost <root>, label, tags" ((@($r.Probes -replace ':\d+\|', ':PORT|') | Sort-Object) -join ";") "llamacpp|http://127.0.0.1:PORT|node3|qwen3:8b;llamacpp|http://127.0.0.1:PORT|server|qwen3:8b,qwen3.7:new"
        Check "each probe got its own host's router root (no /v1)" ((@($r.Probes | Where-Object { $_ -like "*|server|*" }) -join "") -like "llamacpp|$($llamaHost.Url)|server|*" -and (@($r.Probes | Where-Object { $_ -like "*|node3|*" }) -join "") -like "llamacpp|$($node3Host.Url)|node3|*") "True"
        $reg = @($r.Registry -split "`n" | Where-Object { $_ -and -not $_.StartsWith("#") })
        Check "registry: the new tag is a row with engine llamacpp and host server" (@($reg | Where-Object { $_ -like "qwen3.7:new`tllamacpp`tserver`t*" }).Count) 1
        Check "registry: the qwen3:8b row gains server (tag + engine match)" ((@($reg | Where-Object { $_ -like "qwen3:8b`t*" }) | ForEach-Object { ($_ -split "`t")[0..2] -join "|" }) -join " ; ") "qwen3:8b|llamacpp|node3 server"
        Check "registry: the existing main seat row is unchanged" (@($reg | Where-Object { $_ -like "qwen3.6:35b-a3b-coding`tllamacpp`tserver`tllama.cpp main seat" }).Count) 1
        return $r
    }
    $r = Scenario-Probe $tree
    Has   "summary: PASS lines for the probed seats"     $r.Out '(?s)\[PASS \] llamacpp-server/qwen3:8b.*'
    Check "a 'new' probe menu offers one entry per model, not its id and alias" ((Invoke-Batch $tree @{ Mode = "Probe"; Models = @("new"); Tasks = @("t1") } @{ FIXTURE_PROBE_NOLOG = "1" }).Probes -join ";" -replace ':\d+\|', ':PORT|') "llamacpp|http://127.0.0.1:PORT|server|qwen3:8b,qwen3.7:new"

    Write-Host "   scenario: -OnlyMissing, unchanged"
    $summary = "taskId`tmodel`topencodeExit`nt1`t$llamaSeat`t0`nt2`t$node3Seat`t1`n"
    $r = Invoke-Batch $tree @{ Tasks = @("t1", "t2"); Models = @($llamaSeat, $node3Seat); OnlyMissing = $true } @{} $summary
    Check "a graded server pair is skipped, a non-graded (exit 1) node3 pair is not" $r.Calls "t1|$node3Seat t2|$node3Seat t2|$llamaSeat"

    Write-Host "   scenario: a seat found on the CPU stops that host; the other host carries on"
    $r = Invoke-Batch $tree @{ Tasks = @("t1", "fx-cpu", "t2"); Models = @($llamaSeat, $node3Seat) }
    Check "runs"                                          (($r.Seen -split ",") -join " ") "t1@llamacpp-node3 fx-cpu@llamacpp-node3 t2@llamacpp-node3 t1@llamacpp-server fx-cpu@llamacpp-server"
    Check "exit 1 (a host was stopped)"                  $r.Exit 1
    Has   "the stop names the run and the engine"        $r.Out "run 5 of 6 \(fx-cpu x $([regex]::Escape($llamaSeat))\): llama\.cpp had the seat entirely in system RAM after the run"
    Has   "...says one run was not started on llamacpp-server" $r.Out '1 run\(s\) not started on llamacpp-server'
    Lacks "...and nothing is stopped on node3"           $r.Out 'not started on llamacpp-node3'
    Has   "...and says the other hosts carry on"         $r.Out '\[GPU\] llamacpp-server:.*Other hosts carry on'
    $r = Invoke-Batch $tree @{ Tasks = @("t1", "t2", "t3"); Models = @($llamaSeat, $node3Seat) }
    Check "no CPU-only run: everything runs, exit 0"     ("{0} {1}" -f $r.Exit, @($r.Seen -split ",").Count) "0 6"
    Lacks "...and the batch is not STOPPED"              $r.Out 'Batch STOPPED'

    Write-Host "   scenario: a hosted seat beside both hosts"
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($node3Seat, $llamaSeat, "hosted") }
    Check "exit 0"                                       $r.Exit 0
    Check "all three ran, the hosted one as opencode-go/alpha" $r.Calls "t1|$node3Seat t1|$llamaSeat t1|opencode-go/alpha"
    Has   "hosted: smoke-tested, not probed (the probe covers local engines only)" $r.Out 'opencode-go/alpha is hosted - smoke-tested .* not probed: test-toolcalls\.ps1 probes local engines only'
    Check "...and no endpoint check for it"              ($r.Out -match '\[PASS\] opencode-go\s+key file present') "True"
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @("all") }
    Check "'all' still never picks the paid seat"        ($r.Calls -notmatch 'opencode-go') "True"

    # --- controls: the batch with one piece removed fails named checks ------------
    Write-Host "== controls (each broken batch must fail its checks)"
    function Invoke-Control([string]$Name, [string]$Needle, [string]$Replacement, [scriptblock]$Block, [int]$Min) {
        if (-not $realText.Contains($Needle)) { Write-Host "FAIL control '$Name': the text to break was not found in the batch"; $script:fail++; return }
        $broken = $realText.Replace($Needle, $Replacement)
        $before = $script:fail; $script:quiet = $true
        try { & $Block $broken } finally { $script:quiet = $false }
        $failed = $script:fail - $before
        $script:fail = $before   # the failures are the point; do not count them against the run
        Check "control: $Name -> at least $Min check(s) fail" ($failed -ge $Min) "True"
        Write-Host ("     ({0} failed)" -f $failed)
    }
    Invoke-Control "no host discovery" '$hosts = foreach ($kind in @("llamacpp")) {' '$hosts = foreach ($kind in @()) {' { param($t) Invoke-UnitChecks $t } 8
    Invoke-Control "the probe state ignores the engine version (no STALE)" 'if ($cur -and $row.engineVersion -ne $cur) { return "STALE" }' '' { param($t) Invoke-UnitChecks $t } 2
    Invoke-Control "the probe key leaves the host out" '$last["$engine-$($row.host)/' '$last["$engine-server/' { param($t) Invoke-UnitChecks $t } 3
    Invoke-Control "the registry writer ignores the engine" ' -or $cols[1].Trim() -ne $Engine' '' { param($t) Invoke-UnitChecks $t } 1
    Invoke-Control "an old ollama row is offered as a seat" '            if (@("llamacpp") -notcontains $r.Engine) {' '            if (@("llamacpp", "ollama") -notcontains $r.Engine) {' { param($t) Invoke-UnitChecks $t } 1
    Invoke-Control "liveness always passes" 'if (-not (Invoke-Engine $kind "Test-EngineAlive" @{ Root = $Root; TimeoutSec = 5 })) {' 'if ($false) {' {
        param($t)
        $ctl = New-BatchTree "ctl-live" $t
        $r = Invoke-Batch $ctl @{ Tasks = @("t1"); Models = @("llamacpp-desktop/qwen3:4b") }
        Check "ctl: a down host is refused" ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    } 1
    Invoke-Control "the probe is called the Ollama way" '& $toolcallsPs1 -Engine $h.Engine -EngineHost $h.Root' '& $toolcallsPs1 -Engine ollama -EngineHost $h.Root' {
        param($t)
        $ctl = New-BatchTree "ctl-probe" $t
        $null = Scenario-Probe $ctl
    } 2
    Invoke-Control "the registry row is written without its engine" 'Add-RegistrySeat -Tag $m.Tag -Engine $m.Engine -HostLabel' 'Add-RegistrySeat -Tag $m.Tag -Engine "ollama" -HostLabel' {
        param($t)
        $ctl = New-BatchTree "ctl-reg" $t
        $null = Scenario-Probe $ctl
    } 2
} finally {
    Restore-Env
    Stop-FakeHost $llamaHost
    Stop-FakeHost $node3Host
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

# test-batch-engines.ps1 - regression guard for run-tasks-batch.ps1 driving BOTH
# engines through the adapters (tests/engines/<engine>.ps1; Phase 2b of the
# Ollama-replacement program, docs/roadmap.md "Phase 2, engine adapter").
#
# Why this exists: the batch used to know Ollama alone (OLLAMA_<HOST>_BASE_URL,
# /api/tags, /api/version, `ollama-` id prefixes, one probe log), so a
# llamacpp-<host> provider could not be discovered, checked, listed, probed or
# stopped. It now asks the adapters, loaded one module each so the two adapters'
# same-named functions cannot clobber each other, and the registry
# (run-tasks-models.tsv) has an `engine` column. The probe log is read from both
# files (the Ollama log: ollamaVersion, engine implied; the llama.cpp log: engine,
# engineVersion) and a probe PASS goes stale on host + engine + engine version.
#
# What it does (stand-in hosts are real HttpListeners on 127.0.0.1: an Ollama host
# and a llama.cpp router; stand-in opencode, test-tasks.ps1 and test-toolcalls.ps1;
# no real host, no model, never the repo's .env):
#   1. The real functions of the batch against those hosts: provider endpoints,
#      id splitting, host discovery for both engines (liveness, version, tags,
#      llama.cpp aliases, a down host, /v1 stripped), the probe-log reader for both
#      shapes, the probe state (PASS, FAIL, NONE, STALE on a changed llama.cpp
#      build, the two engines independent), the registry reader (new and old
#      shape) and writer (tag + engine rows), and the offered seats.
#   2. The real run-tasks-batch.ps1 end to end in a scratch tree: both engines'
#      seats offered and run, a down llama.cpp host refused by the preflight (and
#      an unset variable, and as the small model), STALE and the Both-mode drop,
#      the probe invoked with each engine's own arguments and the registry row
#      written with its engine, -OnlyMissing, the CPU-only stop for a llamacpp
#      provider while the other engine's host carries on, and a hosted seat.
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

$ollamaRoutes = @{
    "/api/tags"    = '{"models":[{"name":"qwen3:8b"},{"name":"nomic-embed-text:latest"}]}'
    "/api/version" = '{"version":"0.34.3"}'
}
$llamaModels = '{"data":[{"id":"qwen3.6:CODING","aliases":["qwen3.6:35b-a3b-coding"],"status":{"value":"loaded"}},' +
               '{"id":"qwen3:8B","aliases":["qwen3:8b"],"status":{"value":"unloaded"}},' +
               '{"id":"qwen3.7:NEW","aliases":["qwen3.7:new"],"status":{"value":"unloaded"}}]}'
$llamaRoutes = @{
    "/health" = '{"status":"ok"}'
    "/models" = $llamaModels
    "/props"  = '{"build_info":"b11561-abcdef0"}'
}
$ollamaHost = Start-FakeHost $ollamaRoutes
$llamaHost  = Start-FakeHost $llamaRoutes
$deadPort   = Get-FreePort    # nothing listens: a llama.cpp host that is down
$deadUrl    = "http://127.0.0.1:$deadPort"

# --- the real batch functions, from a script text (a control passes a changed one) ---
$script:EngineModules = @{}
foreach ($k in "ollama", "llamacpp") {
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
    Set-Env "OLLAMA_NODE3_BASE_URL" "http://n3:11434/v1/"
    Set-Env "LLAMACPP_SERVER_BASE_URL" "http://srv:8090/v1"
    $p = Get-ProviderEndpoint -ModelId "ollama-node3/qwen3:8b"
    Check "ollama provider: variable, engine, root (/v1 and slash stripped)" ("{0} {1} {2}" -f $p.VarName, $p.Engine, $p.Root) "OLLAMA_NODE3_BASE_URL ollama http://n3:11434"
    Check "...BaseUrl is the variable as set"                          $p.BaseUrl "http://n3:11434/v1/"
    $p = Get-ProviderEndpoint -ModelId "llamacpp-server/qwen3.6:35b-a3b-coding"
    Check "llamacpp provider: variable, engine, root"                  ("{0} {1} {2}" -f $p.VarName, $p.Engine, $p.Root) "LLAMACPP_SERVER_BASE_URL llamacpp http://srv:8090"
    $p = Get-ProviderEndpoint -ModelId "llamacpp-node3/x"
    Check "llamacpp provider, variable unset: named, no root"          ("{0} [{1}]" -f $p.VarName, $p.Root) "LLAMACPP_NODE3_BASE_URL []"
    $p = Get-ProviderEndpoint -ModelId "llamacpp-lab/x"
    Check "a host the adapter does not know: PREFIX_HOST_BASE_URL"     $p.VarName "LLAMACPP_LAB_BASE_URL"
    Check "a hosted provider has no endpoint"                          ($null -eq (Get-ProviderEndpoint -ModelId "opencode-go/alpha")) "True"
    Check "Get-EngineKind: ollama, llamacpp, hosted, bare provider"    ("{0} {1} [{2}] {3}" -f (Get-EngineKind "ollama-server/x"), (Get-EngineKind "llamacpp-node3/y"), (Get-EngineKind "opencode-go/z"), (Get-EngineKind "llamacpp-server")) "ollama llamacpp [] llamacpp"
    $m = Split-ModelId "llamacpp-server/qwen3:8b"
    Check "Split-ModelId: llamacpp"                                    ("{0} {1} {2} {3}" -f $m.Provider, $m.Engine, $m.Host, $m.Tag) "llamacpp-server llamacpp server qwen3:8b"
    $m = Split-ModelId "ollama-desktop/laguna-xs-2.1:latest"
    Check "Split-ModelId: ollama, :latest dropped"                     ("{0} {1} {2} {3}" -f $m.Provider, $m.Engine, $m.Host, $m.Tag) "ollama-desktop ollama desktop laguna-xs-2.1"
    $m = Split-ModelId "opencode-go/alpha"
    Check "Split-ModelId: hosted has no engine and no host"            ("[{0}] [{1}] {2}" -f $m.Engine, $m.Host, $m.Tag) "[] [] alpha"

    Section "-- host discovery (stand-in Ollama and llama.cpp router)"
    Clear-HostEnv
    Set-Env "OLLAMA_DESKTOP_BASE_URL" "$($ollamaHost.Url)/v1"
    Set-Env "LLAMACPP_SERVER_BASE_URL" "$($llamaHost.Url)/v1"
    Set-Env "LLAMACPP_NODE3_BASE_URL" "$deadUrl/v1"
    $ollamaHost.Hits.Clear(); $llamaHost.Hits.Clear()
    $hosts = @(Get-EngineHosts)
    Check "three hosts found (one per variable set)"                   (($hosts | ForEach-Object Provider) -join ",") "ollama-desktop,llamacpp-node3,llamacpp-server"
    $d = $hosts | Where-Object Provider -eq "ollama-desktop"
    Check "ollama: up, version, tags (embed model included here)"      ("{0} {1} {2}" -f $d.Up, $d.Version, ($d.Tags -join ",")) "True 0.34.3 qwen3:8b,nomic-embed-text"
    Check "ollama: root has no /v1"                                    $d.Root $ollamaHost.Url
    $s = $hosts | Where-Object Provider -eq "llamacpp-server"
    Check "llamacpp: up, version is the router's build"                ("{0} {1}" -f $s.Up, $s.Version) "True b11561-abcdef0"
    Check "llamacpp: tags are ids plus aliases"                        ($s.Tags -join ",") "qwen3.6:CODING,qwen3.6:35b-a3b-coding,qwen3:8B,qwen3:8b,qwen3.7:NEW,qwen3.7:new"
    Check "llamacpp: seat tags are one per model, the alias"           ($s.SeatTags -join ",") "qwen3.6:35b-a3b-coding,qwen3:8b,qwen3.7:new"
    $n = $hosts | Where-Object Provider -eq "llamacpp-node3"
    Check "llamacpp: a host that does not answer is down, with no tags" ("{0} [{1}] {2}" -f $n.Up, $n.Version, @($n.Tags).Count) "False [] 0"
    Check "llamacpp liveness asked /health, not Ollama's endpoint"     (@($llamaHost.Hits | Where-Object { $_ -eq "GET /health" }).Count -ge 1 -and @($llamaHost.Hits | Where-Object { $_ -like "*/api/*" }).Count -eq 0) "True"
    Check "ollama liveness asked /api/tags"                            (@($ollamaHost.Hits | Where-Object { $_ -eq "GET /api/tags" }).Count -ge 1) "True"
    Check "...and neither host was asked the other engine's endpoints" (@($ollamaHost.Hits | Where-Object { $_ -match '/health|/props|/models' }).Count) 0
    $e = Test-EngineEndpoint -Provider "llamacpp-server" -Root $llamaHost.Url
    Check "Test-EngineEndpoint: llamacpp up, counts model ids"         ("{0} {1}" -f $e.Ok, $e.Detail) "True 6 model id(s)"
    $e = Test-EngineEndpoint -Provider "llamacpp-node3" -Root $deadUrl
    Check "Test-EngineEndpoint: llamacpp down"                         ("{0} {1}" -f $e.Ok, ($e.Detail -match 'llama\.cpp not answering')) "False True"
    $e = Test-EngineEndpoint -Provider "ollama-desktop" -Root $ollamaHost.Url
    Check "Test-EngineEndpoint: ollama up, counts tags (as before)"    ("{0} {1}" -f $e.Ok, $e.Detail) "True 2 model tag(s)"

    Section "-- probe log: both shapes, and STALE on host + engine + version"
    $ollamaLog = Join-Path $tmp "unit-ollama-log.tsv"
    $llamaLog  = Join-Path $tmp "unit-llama-log.tsv"
    Write-Fixture $ollamaLog ("timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail`n" +
        "2026-10-06T09:00:00`tdesktop`t0.34.3`tqwen3:8b`tPASS`t10`tx`n" +
        "2026-10-06T09:01:00`tdesktop`t0.34.3`tbadmodel`tFAIL`t10`tx`n" +
        "2026-10-06T09:02:00`tdesktop`t0.34.2`told:latest`tPASS`t10`tx`n")
    Write-Fixture $llamaLog ("timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail`n" +
        "2026-10-16T09:00:00`tserver`tllamacpp`tb11561-abcdef0`tqwen3.6:35b-a3b-coding`tPASS`t30`ty`n" +
        "2026-10-16T09:05:00`tserver`tllamacpp`tb11561-abcdef0`tqwen3:8b`tFAIL`t30`ty`n")
    $probeLogPaths = @{ ollama = $ollamaLog; llamacpp = $llamaLog }
    $probeLog = Get-ProbeLog
    $probeKeys = [string[]]@($probeLog.Keys); [Array]::Sort($probeKeys, [StringComparer]::Ordinal)
    Check "reader: keys are provider/model, :latest dropped"           ($probeKeys -join " ") "llamacpp-server/qwen3.6:35b-a3b-coding llamacpp-server/qwen3:8b ollama-desktop/badmodel ollama-desktop/old ollama-desktop/qwen3:8b"
    Check "reader: an Ollama row reads engine ollama and its ollamaVersion as engineVersion" ("{0} {1}" -f $probeLog["ollama-desktop/qwen3:8b"].engine, $probeLog["ollama-desktop/qwen3:8b"].engineVersion) "ollama 0.34.3"
    Check "reader: a llama.cpp row keeps its engine and build"         ("{0} {1}" -f $probeLog["llamacpp-server/qwen3:8b"].engine, $probeLog["llamacpp-server/qwen3:8b"].engineVersion) "llamacpp b11561-abcdef0"
    $hostVersions = @{ "ollama-desktop" = "0.34.3"; "llamacpp-server" = "b11561-abcdef0"; "llamacpp-node3" = "b11561-abcdef0" }
    Check "state: ollama PASS on the current version"                  (Get-ProbeState "ollama-desktop/qwen3:8b") "PASS"
    Check "state: ollama FAIL on the current version"                  (Get-ProbeState "ollama-desktop/badmodel") "FAIL"
    Check "state: ollama PASS on an older version is STALE"            (Get-ProbeState "ollama-desktop/old") "STALE"
    Check "state: llamacpp PASS on the current build"                  (Get-ProbeState "llamacpp-server/qwen3.6:35b-a3b-coding") "PASS"
    Check "state: llamacpp FAIL on the current build"                  (Get-ProbeState "llamacpp-server/qwen3:8b") "FAIL"
    Check "state: same tag and host label on the other engine is NONE" (Get-ProbeState "llamacpp-desktop/qwen3:8b") "NONE"
    Check "state: ollama-server/qwen3:8b has no row: NONE"             (Get-ProbeState "ollama-server/qwen3:8b") "NONE"
    $hostVersions["llamacpp-server"] = "b12000-0000000"
    Check "state: the llama.cpp build changed: STALE"                  (Get-ProbeState "llamacpp-server/qwen3.6:35b-a3b-coding") "STALE"
    Check "state: ...and the Ollama result is untouched by it"         (Get-ProbeState "ollama-desktop/qwen3:8b") "PASS"
    Has   "note: names the old build and the host's now"               (Format-ProbeNote "llamacpp-server/qwen3.6:35b-a3b-coding") 'probe: PASS on b11561-abcdef0, 2026-10-16; host now b12000-0000000'
    Has   "note: an ollama row keeps its shape"                        (Format-ProbeNote "ollama-desktop/qwen3:8b") '^\[probe: PASS on 0\.34\.3, 2026-10-06\]$'
    Check "state: a host not answering has no current version: not STALE" ((Get-ProbeState "llamacpp-node3/qwen3.6:35b-a3b-coding") -eq "NONE") "True"
    $hostVersions.Remove("llamacpp-server")
    Check "state: no current version known: the row's status"          (Get-ProbeState "llamacpp-server/qwen3.6:35b-a3b-coding") "PASS"

    Section "-- registry: reader and writer"
    $registryPath = Join-Path $tmp "unit-registry.tsv"
    Write-Fixture $registryPath ("# fixture`ntag`tengine`thosts`tdesc`n" +
        "qwen3:8b`tollama`tdesktop node3`tlight`n" +
        "qwen3:8b`tllamacpp`tserver`tsame tag, other engine`n" +
        "alpha`topencode-go`topencode-go`thosted`n")
    $rows = @(Get-RegistryRows)
    Check "reader: rows with engine, hosts, desc"                      (($rows | ForEach-Object { "{0}/{1}/{2}" -f $_.Tag, $_.Engine, ($_.Hosts -join "+") }) -join " ") "qwen3:8b/ollama/desktop+node3 qwen3:8b/llamacpp/server alpha/opencode-go/opencode-go"
    Add-RegistrySeat -Tag "qwen3:8b" -Engine "llamacpp" -HostLabel "node3" -Version "b1" 6>$null
    Add-RegistrySeat -Tag "qwen3:8b" -Engine "ollama" -HostLabel "server" -Version "0.34.3" 6>$null
    Add-RegistrySeat -Tag "qwen3.7:new" -Engine "llamacpp" -HostLabel "server" -Version "b1" 6>$null
    Add-RegistrySeat -Tag "qwen3.7:new" -Engine "llamacpp" -HostLabel "server" -Version "b1" 6>$null
    $lines = @(Get-Content -LiteralPath $registryPath | Where-Object { $_ -and -not $_.StartsWith("#") })
    Check "writer: llamacpp row gains the host (tag + engine match)"    ((($lines[2] -split "`t")[0..2]) -join "|") "qwen3:8b|llamacpp|server node3"
    Check "writer: the ollama row gains its own host"                  ((($lines[1] -split "`t")[0..2]) -join "|") "qwen3:8b|ollama|desktop node3 server"
    Check "writer: a new tag is a new row with its engine, once"       (@($lines | Where-Object { $_ -like "qwen3.7:new`tllamacpp`tserver`t*" }).Count) 1
    Check "writer: the file ends with one newline, LF only"            (([IO.File]::ReadAllText($registryPath) -match "`n$") -and ([IO.File]::ReadAllText($registryPath) -notmatch "`r")) "True"
    Write-Fixture $registryPath "tag`thosts`tdesc`nqwen3:8b`tdesktop`told shape`nalpha`topencode-go`thosted`n"
    $rows = @(Get-RegistryRows)
    Check "reader: the old tag/hosts/desc shape reads as ollama, or opencode-go" (($rows | ForEach-Object { "{0}/{1}" -f $_.Tag, $_.Engine }) -join " ") "qwen3:8b/ollama alpha/opencode-go"
    $threw = $false
    try { Add-RegistrySeat -Tag "x" -Engine "ollama" -HostLabel "desktop" -Version "1" 6>$null } catch { $threw = $true }
    Check "writer: a registry with no engine column is refused, not corrupted" ($threw -and ([IO.File]::ReadAllText($registryPath) -notmatch "`tx`t")) "True"

    Section "-- offered seats (the real Get-AvailableModelSeats)"
    $registryPath = Join-Path $tmp "unit-registry2.tsv"
    Write-Fixture $registryPath ("tag`tengine`thosts`tdesc`n" +
        "qwen3:8b`tollama`tdesktop node3`tlight`n" +
        "qwen3.6:35b-a3b-coding`tllamacpp`tserver node3`tmain seat`n" +
        "qwen3:14b`tllamacpp`tserver`tnot served there`n" +
        "weird`tvllm`tserver`tunknown engine`n" +
        "alpha`topencode-go`topencode-go`thosted`n")
    $engineHosts = $hosts
    $hostedState = $null
    $out = (@(Get-AvailableModelSeats 6>&1) | ForEach-Object { "$_" })
    $seats = @($out | Where-Object { $_ -match '^(ollama|llamacpp)-[a-z0-9]+/' })
    Check "seats: served on an up host of the registry's engine only"  ($seats -join " ") "llamacpp-server/qwen3.6:35b-a3b-coding ollama-desktop/qwen3:8b"
    Has   "skip: a down llamacpp host"                                 ($out -join "`n") '\[skip\] llamacpp-node3 - host not answering'
    Has   "skip: an ollama host whose variable is unset names it"      ($out -join "`n") '\[skip\] ollama-node3 - OLLAMA_NODE3_BASE_URL is not set in this shell'
    Has   "skip: a tag the llamacpp host does not serve"               ($out -join "`n") "\[skip\] llamacpp-server - tag 'qwen3:14b' not served there yet"
    Has   "skip: an unknown engine"                                    ($out -join "`n") "unknown engine 'vllm'"
    Check "a registry tag served by the OTHER engine is not offered on this one" (($seats -join " ") -notmatch 'ollama-desktop/qwen3\.6') "True"
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
        "qwen3:8b`tollama`tdesktop`tlocal ollama seat`n" +
        "qwen3.6:35b-a3b-coding`tllamacpp`tserver`tllama.cpp main seat`n" +
        "qwen3:8b`tllamacpp`tnode3`tllama.cpp seat on a host that is down`n" +
        "alpha`topencode-go`topencode-go`thosted`n"
    $ratesText = "model`tplan`ttier`tinputPerM`toutputPerM`tcacheReadPerM`tcacheWritePerM`tmonthlyLimitUsd`tchecked`tsource`n" +
        "opencode-go/alpha`tgo`t`t2.00`t4.00`t0.50`t`t10`t2026-10-06`tfixture`n"
    $now = [datetime]::UtcNow
    $planText = "plan`tmeter`tlimitUsd`tperiod`tanchorUtc`tchecked`tbasis`n" +
        "go`twindow`t900`t5h`t`t2026-10-07`tfixture`n" +
        ("go`tweek`t900`t7d`t{0}`t2026-10-07`tfixture`n" -f $now.AddDays(-3).ToString("yyyy-MM-ddTHH:mm:ssZ")) +
        ("go`tmonth`t900`t1mo`t{0}`t2026-10-07`tfixture`n" -f $now.AddDays(-12).ToString("yyyy-MM-ddTHH:mm:ssZ"))
    $configJson = '{"autoupdate":"notify","provider":{"ollama-desktop":{"models":{"qwen3:8b":{}}},' +
                  '"llamacpp-server":{"models":{"qwen3.6:35b-a3b-coding":{},"qwen3:8b":{},"qwen3.7:new":{}}},' +
                  '"llamacpp-node3":{"models":{"qwen3:8b":{}}}}}'
    $ollamaLogText = "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail`n2026-10-06T09:00:00`tdesktop`t0.34.3`tqwen3:8b`tPASS`t10`tfixture`n"
    $llamaLogText  = "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail`n2026-10-16T09:00:00`tserver`tllamacpp`tb11561-abcdef0`tqwen3.6:35b-a3b-coding`tPASS`t30`tfixture`n"

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
    # Stand-in test-toolcalls.ps1: records how it was called, and logs one row per
    # model in the shape the real script writes for the engine it was asked for
    # (PASS, or FAIL for a tag containing "bad"; nothing at all when told not to).
    $stubProbe = @'
param([string[]]$Model, [Alias("EngineHost")][string]$OllamaHost, [string]$HostLabel,
      [string]$Engine = "ollama", [string]$LogFile, [switch]$NoLog, [int]$TimeoutSec, [switch]$KeepLoaded)
Add-Content -LiteralPath $env:FIXTURE_PROBES -Value ("{0}|{1}|{2}|{3}" -f $Engine, $OllamaHost, $HostLabel, ($Model -join ","))
if ($env:FIXTURE_PROBE_NOLOG) { exit 0 }
$enc = New-Object System.Text.UTF8Encoding $false
$ver = if ($Engine -eq "llamacpp") { $env:FIXTURE_PROBE_LLAMA_BUILD } else { "0.34.3" }
if (-not (Test-Path -LiteralPath $LogFile)) {
    $hdr = if ($Engine -eq "llamacpp") { "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail`n" } else { "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail`n" }
    [IO.File]::WriteAllText($LogFile, $hdr, $enc)
}
foreach ($m in $Model) {
    $st = if ($m -like "*bad*") { "FAIL" } else { "PASS" }
    $row = if ($Engine -eq "llamacpp") { "2026-10-16T12:00:00`t$HostLabel`t$Engine`t$ver`t$m`t$st`t1`tfixture`n" } else { "2026-10-16T12:00:00`t$HostLabel`t$ver`t$m`t$st`t1`tfixture`n" }
    [IO.File]::AppendAllText($LogFile, $row, $enc)
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
        # the defaults: the Ollama desktop and the llama.cpp server up, llama.cpp node3 down
        Set-Env "OLLAMA_DESKTOP_BASE_URL" "$($ollamaHost.Url)/v1"
        Set-Env "LLAMACPP_SERVER_BASE_URL" "$($llamaHost.Url)/v1"
        Set-Env "LLAMACPP_NODE3_BASE_URL" "$deadUrl/v1"
        foreach ($k in $Env.Keys) { Set-Env $k $Env[$k] }
        Set-Env "PATH" "$bin;$origPath"
        Set-Env "FIXTURE_DIR" $fx
        Set-Env "FIXTURE_CALLS" $calls
        Set-Env "FIXTURE_PROBES" $probes
        Set-Env "FIXTURE_PROBE_LLAMA_BUILD" $(if ($Env.ContainsKey("FIXTURE_PROBE_LLAMA_BUILD")) { $Env["FIXTURE_PROBE_LLAMA_BUILD"] } else { "b11561-abcdef0" })
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
    $ollamaSeat = "ollama-desktop/qwen3:8b"
    $llamaSeat  = "llamacpp-server/qwen3.6:35b-a3b-coding"

    Write-Host "   scenario: -Models all, Tasks mode: both engines' seats, a down llama.cpp host skipped"
    $llamaHost.Hits.Clear(); $ollamaHost.Hits.Clear()
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @("all") }
    Check "exit 0"                                      $r.Exit 0
    Check "the Ollama seat and the llama.cpp seat ran (alias served; node3 down; hosted not in 'all')" $r.Calls "t1|$llamaSeat t1|$ollamaSeat"
    Has   "skip: llamacpp-node3 not answering"           $r.Out '\[skip\] llamacpp-node3 - host not answering'
    Has   "preflight: ollama host passes with its tag count" $r.Out '\[PASS\] ollama-desktop\s+http://127\.0\.0\.1:\d+/v1 - 2 model tag\(s\)'
    Has   "preflight: llamacpp host passes with its id count (the /v1 surface kept in the line)" $r.Out '\[PASS\] llamacpp-server\s+http://127\.0\.0\.1:\d+/v1 - 6 model id\(s\)'
    Check "the llama.cpp host was asked /health, never an /api/ endpoint" ((@($llamaHost.Hits | Where-Object { $_ -eq "GET /health" }).Count -ge 1) -and (@($llamaHost.Hits | Where-Object { $_ -like "*/api/*" }).Count -eq 0)) "True"
    Check "the Ollama host was never asked a llama.cpp endpoint" (@($ollamaHost.Hits | Where-Object { $_ -match '/health|/props|/models' }).Count) 0

    Write-Host "   scenario: a down llama.cpp host is refused by the endpoint preflight"
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @("llamacpp-node3/qwen3:8b") }
    Check "exit 1, no run started"                       ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    Has   "[FAIL] names the provider and the engine"     $r.Out '\[FAIL\] llamacpp-node3\s+http://127\.0\.0\.1:\d+/v1 - llama\.cpp not answering at'
    Has   "...and the batch is not started"              $r.Out '1 endpoint\(s\) not answering - not starting the batch'
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @("llamacpp-node3/qwen3:8b") } @{ LLAMACPP_NODE3_BASE_URL = $null }
    Check "an unset variable: exit 1, no run"            ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    Has   "...the FAIL names the variable"               $r.Out '\[FAIL\] llamacpp-node3\s+LLAMACPP_NODE3_BASE_URL is not set'
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($ollamaSeat) } @{ OPENCODE_SMALL_MODEL = "llamacpp-node3/qwen3:8b" }
    Check "a dead llama.cpp host as the small model also stops the batch" ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    Has   "...[FAIL] llamacpp-node3"                     $r.Out '\[FAIL\] llamacpp-node3'

    Write-Host "   scenario: the llama.cpp build changed (STALE)"
    $llamaHost.Routes["/props"] = '{"build_info":"b12000-1111111"}'
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($llamaSeat, $ollamaSeat) }
    Check "Tasks mode: both run, with a WARN for the llama.cpp seat" ("{0} {1}" -f $r.Exit, $r.Calls) "0 t1|$llamaSeat t1|$ollamaSeat"
    Has   "...WARN says STALE on the host's current version"  $r.Out "WARN: $([regex]::Escape($llamaSeat)) - probe STALE on this host's current version"
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($llamaSeat, $ollamaSeat); Mode = "Both" } @{ FIXTURE_PROBE_NOLOG = "1" }
    Check "Both mode, the probe logged nothing new: the stale llama.cpp seat is dropped, the Ollama seat runs" ("{0} {1}" -f $r.Exit, $r.Calls) "0 t1|$ollamaSeat"
    Has   "...[drop] names STALE and the engine version"      $r.Out "\[drop\] $([regex]::Escape($llamaSeat)) - probe STALE on this host's current engine version"
    $llamaHost.Routes["/props"] = '{"build_info":"b11561-abcdef0"}'

    Write-Host "   scenario: Probe mode calls each engine's probe its own way and writes the registry row with its engine"
    function Scenario-Probe($Tree) {
        $models = @($ollamaSeat, "llamacpp-server/qwen3:8b", "llamacpp-server/qwen3.7:new")
        $r = Invoke-Batch $Tree @{ Mode = "Probe"; Models = $models; Tasks = @("t1") }
        Check "exit 0"                                       $r.Exit 0
        Check "two probe calls, one per provider"            $r.Probes.Count 2
        $ol = @($r.Probes | Where-Object { $_ -like "ollama|*" })
        $ll = @($r.Probes | Where-Object { $_ -like "llamacpp|*" })
        Check "the Ollama probe: engine ollama, the host root, its label, its tag"  (($ol -replace ':\d+\|', ':PORT|') -join ";") "ollama|http://127.0.0.1:PORT|desktop|qwen3:8b"
        Check "the llama.cpp probe: -Engine llamacpp -EngineHost <root>, label, both tags" (($ll -replace ':\d+\|', ':PORT|') -join ";") "llamacpp|http://127.0.0.1:PORT|server|qwen3:8b,qwen3.7:new"
        Has   "the llama.cpp probe got the router root (no /v1)" ($ll -join ";") '^llamacpp\|http://127\.0\.0\.1:\d+\|server\|'
        $reg = @($r.Registry -split "`n" | Where-Object { $_ -and -not $_.StartsWith("#") })
        Check "registry: the new llama.cpp tag is a row with engine llamacpp and host server" (@($reg | Where-Object { $_ -like "qwen3.7:new`tllamacpp`tserver`t*" }).Count) 1
        Check "registry: qwen3:8b llamacpp row gains server (tag + engine match), the ollama row is untouched" ((@($reg | Where-Object { $_ -like "qwen3:8b`t*" }) | ForEach-Object { ($_ -split "`t")[0..2] -join "|" }) -join " ; ") "qwen3:8b|ollama|desktop ; qwen3:8b|llamacpp|node3 server"
        Check "registry: the existing llama.cpp main seat row is unchanged" (@($reg | Where-Object { $_ -like "qwen3.6:35b-a3b-coding`tllamacpp`tserver`tllama.cpp main seat" }).Count) 1
        return $r
    }
    $r = Scenario-Probe $tree
    Has   "summary: PASS lines for the three probed seats" $r.Out '(?s)\[PASS \] llamacpp-server/qwen3:8b.*'
    Check "a 'new' probe menu offers one entry per llama.cpp model, not its id and alias" ((Invoke-Batch $tree @{ Mode = "Probe"; Models = @("new"); Tasks = @("t1") } @{ FIXTURE_PROBE_NOLOG = "1" }).Probes -join ";" -replace ':\d+\|', ':PORT|') "llamacpp|http://127.0.0.1:PORT|server|qwen3:8b,qwen3.7:new"

    Write-Host "   scenario: -OnlyMissing, unchanged"
    $summary = "taskId`tmodel`topencodeExit`nt1`t$llamaSeat`t0`nt2`t$ollamaSeat`t1`n"
    $r = Invoke-Batch $tree @{ Tasks = @("t1", "t2"); Models = @($llamaSeat, $ollamaSeat); OnlyMissing = $true } @{} $summary
    Check "a graded llama.cpp pair is skipped, a non-graded (exit 1) Ollama pair is not" $r.Calls "t1|$ollamaSeat t2|$llamaSeat t2|$ollamaSeat"

    Write-Host "   scenario: a llama.cpp seat found on the CPU stops that provider; the Ollama host carries on"
    $r = Invoke-Batch $tree @{ Tasks = @("t1", "fx-cpu", "t2"); Models = @($llamaSeat, $ollamaSeat) }
    Check "runs"                                          (($r.Seen -split ",") -join " ") "t1@llamacpp-server fx-cpu@llamacpp-server t1@ollama-desktop fx-cpu@ollama-desktop t2@ollama-desktop"
    Check "exit 1 (a host was stopped)"                  $r.Exit 1
    Has   "the stop names the run and the engine"        $r.Out "run 2 of 6 \(fx-cpu x $([regex]::Escape($llamaSeat))\): llama\.cpp had the seat entirely in system RAM after the run"
    Has   "...says one run was not started on llamacpp-server" $r.Out '1 run\(s\) not started on llamacpp-server'
    Lacks "...and nothing is stopped on the Ollama host" $r.Out 'not started on ollama-desktop'

    Write-Host "   scenario: a hosted seat beside both engines"
    $r = Invoke-Batch $tree @{ Tasks = @("t1"); Models = @($ollamaSeat, $llamaSeat, "hosted") }
    Check "exit 0"                                       $r.Exit 0
    Check "all three ran, the hosted one as opencode-go/alpha" $r.Calls "t1|$llamaSeat t1|$ollamaSeat t1|opencode-go/alpha"
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
    Invoke-Control "no llamacpp host discovery" '$hosts = foreach ($kind in "ollama", "llamacpp") {' '$hosts = foreach ($kind in "ollama") {' { param($t) Invoke-UnitChecks $t } 8
    Invoke-Control "the probe state ignores the engine version (no STALE)" 'if ($cur -and $row.engineVersion -ne $cur) { return "STALE" }' '' { param($t) Invoke-UnitChecks $t } 2
    Invoke-Control "the probe log is read from the Ollama file only" '$path = $probeLogPaths[$kind]' '$path = $probeLogPaths["ollama"]' { param($t) Invoke-UnitChecks $t } 4
    Invoke-Control "the probe key leaves the engine out" '$last["$engine-$($row.host)/' '$last["ollama-$($row.host)/' { param($t) Invoke-UnitChecks $t } 3
    Invoke-Control "the registry writer ignores the engine" ' -or $cols[1].Trim() -ne $Engine' '' { param($t) Invoke-UnitChecks $t } 1
    Invoke-Control "liveness always passes" 'if (-not (Invoke-Engine $kind "Test-EngineAlive" @{ Root = $Root; TimeoutSec = 5 })) {' 'if ($false) {' {
        param($t)
        $ctl = New-BatchTree "ctl-live" $t
        $r = Invoke-Batch $ctl @{ Tasks = @("t1"); Models = @("llamacpp-node3/qwen3:8b") }
        Check "ctl: a down llama.cpp host is refused" ("{0} [{1}]" -f $r.Exit, $r.Calls) "1 []"
    } 1
    Invoke-Control "the probe is always called the Ollama way" 'if ($h.Engine -eq "llamacpp") {' 'if ($false) {' {
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
    Stop-FakeHost $ollamaHost
    Stop-FakeHost $llamaHost
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

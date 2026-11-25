# protects: test-toolcalls.ps1 on llama.cpp (payload, verdicts, logging, unload)
# run-after: test-toolcalls.ps1
# test-toolcalls-engine.ps1 - regression guard for tests/test-toolcalls.ps1.
#
# Why this exists: the tool-calling probe decides which models may hold an agent
# seat. llama.cpp is the only local engine since Ollama was removed (2026-11-21).
# This pins that the probe asks the same question every time (the prompt and the
# write_file tool schema, compared with a pinned copy), reads the OpenAI-shaped
# answer (arguments as a JSON string), logs 8-column rows to
# results/toolcalls-summary-llamacpp.tsv (the file run-tasks-batch.ps1 reads),
# never appends to a log of another shape (the Ollama-era 7-column one is
# history), unloads after each probe in router mode, and never calls /api/*.
#
# What it does: runs the REAL test-toolcalls.ps1 as a child process against a
# stand-in Invoke-RestMethod (a driver defines it, so no server is needed; the
# same technique as test-bench-speed.ps1). Scenarios: PASS, FAIL (call printed as
# chat text), FAIL (ignored the tool), WARN (wrong tool), ERROR (HTTP failure),
# router unload on and off (-KeepLoaded), model listing from /v1/models with an
# embed model skipped, the build read from /props, -NoLog, the default log path,
# an existing log appended to, an Ollama-era log refused, an unknown engine and
# the removed -OllamaHost parameter.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-toolcalls-engine.ps1 [-ScriptPath <a test-toolcalls.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-toolcalls.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }

$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")   # Check <name> <actual> <expected>: a PASS/FAIL line, failures counted in $script:fail
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }
function Get-Canonical($o) {
    # A string form of parsed JSON that ignores key order. PowerShell hashtables
    # enumerate in a per-process random order on .NET Core, so two runs of the
    # same script serialise the same request with its keys in different orders.
    if ($null -eq $o) { return "null" }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $names = @($o.PSObject.Properties.Name); [Array]::Sort($names, [StringComparer]::Ordinal)
        return "{" + (($names | ForEach-Object { "`"$_`":" + (Get-Canonical $o.$_) }) -join ",") + "}"
    }
    if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { return "[" + ((@($o) | ForEach-Object { Get-Canonical $_ }) -join ",") + "]" }
    return (ConvertTo-Json $o -Compress)
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("toolcalls-engine-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding($false)
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $psExe = (Get-Process -Id $PID).Path

    [IO.File]::WriteAllText("$tmp/driver.ps1", @'
param([string]$Script, [string]$ArgsFile)
# A stand-in host. Every request is appended to FIXTURE_HITS as "METHOD URI" and
# every POST body to FIXTURE_BODIES (one JSON per line). FIXTURE_MODE picks what
# the model "says": pass | text | prose | wrongtool | http500.
function Invoke-RestMethod {
    param($Uri, $TimeoutSec, $Method, $Body, $ContentType)
    $u = "$Uri"
    $m = if ($Method) { "$Method" } else { "GET" }
    Add-Content -LiteralPath $env:FIXTURE_HITS -Value "$m $u"
    if ($Body) { Add-Content -LiteralPath $env:FIXTURE_BODIES -Value (($Body | ConvertFrom-Json | ConvertTo-Json -Depth 10 -Compress)) }
    # --- llama-server (the only engine; any /api/* request falls through to the throw) ---
    if ($u -match '/props$') {
        if ($env:FIXTURE_NO_PROPS) { throw "fixture: /props unavailable" }
        return [pscustomobject]@{ build_info = 'b11561-abcdef0'; total_slots = 1 }
    }
    if ($u -match '/v1/models$') {
        return [pscustomobject]@{ data = @([pscustomobject]@{ id = 'qwen3.6:35b-a3b-coding' }, [pscustomobject]@{ id = 'nomic-embed-text' }, [pscustomobject]@{ id = 'qwen3:8b' }) }
    }
    if ($u -match '/models/unload$') {
        if ($env:FIXTURE_NO_UNLOAD) { throw "fixture: 404, a single-model server has no /models/unload" }
        return [pscustomobject]@{ success = $true }
    }
    if ($u -match '/v1/chat/completions$') {
        switch ($env:FIXTURE_MODE) {
            'http500'   { throw "fixture: 500 from /v1/chat/completions" }
            'text'      { return [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = '{"name": "write_file", "arguments": {"path": "a.txt", "content": "hello"}}' } }) } }
            'prose'     { return [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = "To write the text hello to a file, you can use a text editor." } }) } }
            'wrongtool' { return [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = ''; tool_calls = @([pscustomobject]@{ type = 'function'; function = [pscustomobject]@{ name = 'read_file'; arguments = '{"path":"a.txt"}' } }) } }) } }
            default     { return [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = ''; tool_calls = @([pscustomobject]@{ type = 'function'; function = [pscustomobject]@{ name = 'write_file'; arguments = '{"path": "a.txt",  "content": "hello"}' } }) } }) } }
        }
    }
    throw "fixture: no endpoint $u"
}
$a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json
$splat = @{}
foreach ($p in $a.PSObject.Properties) { $splat[$p.Name] = $p.Value }
& $Script @splat
exit $LASTEXITCODE
'@, $utf8)

    $script:scn = 0
    function Invoke-Probe([hashtable]$Params, [hashtable]$Env = @{}, [switch]$DefaultLog) {
        $script:scn++
        # Never the repo's tests/results/toolcalls-summary-llamacpp.tsv: a scenario that
        # names no log gets a scratch one, so a broken refusal cannot log into the real record.
        if (-not $DefaultLog -and -not $Params.ContainsKey("LogFile") -and -not $Params.ContainsKey("NoLog")) {
            $Params = $Params.Clone(); $Params.LogFile = Join-Path $tmp "default-$($script:scn).tsv"
        }
        $argsFile = Join-Path $tmp "args-$($script:scn).json"
        [IO.File]::WriteAllText($argsFile, ($Params | ConvertTo-Json -Depth 4), $utf8)
        $hits = Join-Path $tmp "hits-$($script:scn).log"; $bodies = Join-Path $tmp "bodies-$($script:scn).log"
        [IO.File]::WriteAllText($hits, "", $utf8); [IO.File]::WriteAllText($bodies, "", $utf8)
        $env:FIXTURE_HITS = $hits; $env:FIXTURE_BODIES = $bodies
        foreach ($k in $Env.Keys) { Set-Item -Path "Env:$k" -Value $Env[$k] }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp "driver.ps1") -Script $ScriptPath -ArgsFile $argsFile 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
            Remove-Item Env:FIXTURE_HITS, Env:FIXTURE_BODIES -ErrorAction SilentlyContinue
            foreach ($k in $Env.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        }
        [pscustomobject]@{
            Out    = ($out -replace '\x1b\[[0-9;]*m', '')
            Exit   = $code
            Hits   = @(Get-Content -LiteralPath $hits | Where-Object { $_ })
            Bodies = @(Get-Content -LiteralPath $bodies | Where-Object { $_ })
        }
    }
    function LogRows([string]$Path) { if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() } }

    # The question the probe must always ask (prompt + tool schema), pinned here.
    # Ollama's /api/chat was sent the same one until 2026-11-21; change it on purpose only.
    $wantMessages = Get-Canonical (ConvertFrom-Json -NoEnumerate '[{"role":"user","content":"Write the text ''hello'' to a file named a.txt. Use the tool."}]')
    $wantTools = Get-Canonical (ConvertFrom-Json -NoEnumerate '[{"type":"function","function":{"name":"write_file","description":"Write text to a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]')

    Write-Host "-- a passing model"
    $lbase = @{ Engine = "llamacpp"; EngineHost = "http://fixture.invalid:8090"; HostLabel = "server" }
    $log = Join-Path $tmp "llama.tsv"
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3.6:35b-a3b-coding"); LogFile = $log })
    $rows = LogRows $log
    Check "PASS exits 0"                                     $r.Exit 0
    $h = @($r.Hits | ForEach-Object { $_ -replace '^(GET|POST) http://fixture.invalid:8090', '$1 ' })
    Check "asks /props, POSTs /v1/chat/completions, then unloads (router mode)" ($h -join ",") "GET /props,POST /v1/chat/completions,POST /models/unload"
    Check "...never an Ollama endpoint"                      (@($r.Hits | Where-Object { $_ -like "*/api/*" }).Count) 0
    $lb = $r.Bodies[0] | ConvertFrom-Json
    Check "request: model, stream false, a generous max_tokens (2048)" ("{0} {1} {2}" -f $lb.model, $lb.stream, $lb.max_tokens) "qwen3.6:35b-a3b-coding False 2048"
    Check "request: no keep_alive (that was Ollama's)"       ($null -eq $lb.keep_alive) "True"
    Check "the prompt (messages) is the pinned one"          (Get-Canonical $lb.messages) $wantMessages
    Check "...and the tool schema (tools) is the pinned write_file one" (Get-Canonical $lb.tools) $wantTools
    $unloadBody = if ($r.Bodies.Count -gt 1) { ($r.Bodies[1] | ConvertFrom-Json).model } else { "<no unload request>" }
    Check "the unload names the model"                       $unloadBody "qwen3.6:35b-a3b-coding"
    Check "log: 8-column header with engine + engineVersion" $rows[0] "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail"
    $c = $rows[1] -split "`t"
    Check "row: host, engine, build, model, status"          ("{0}|{1}|{2}|{3}|{4}|{5}" -f $c.Count, $c[1], $c[2], $c[3], $c[4], $c[5]) "8|server|llamacpp|b11561-abcdef0|qwen3.6:35b-a3b-coding|PASS"
    Has   "...detail carries the call, arguments' whitespace collapsed" $c[7] 'tool_calls -> write_file \{"path": "a.txt", "content": "hello"\}'
    Has   "banner names llama.cpp and the build"             $r.Out '=== Tool-calling probe against http://fixture.invalid:8090 \(server, llama.cpp b11561-abcdef0\) ==='

    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); LogFile = $log })
    $rows = LogRows $log
    Check "a second run appends one row to the same log, no second header" ("{0} {1}" -f $rows.Count, @($rows | Where-Object { $_ -like "timestamp*" }).Count) "3 1"

    $r = Invoke-Probe @{ Model = @("qwen3:8b"); EngineHost = "http://fixture.invalid:8090"; HostLabel = "server"; NoLog = $true }
    Check "no -Engine: llamacpp is the default (PASS, exit 0)" $r.Exit 0
    Check "...and it is llama-server that is asked"          (@($r.Hits | Where-Object { $_ -like "POST*/v1/chat/completions" }).Count) 1

    Write-Host "-- unload, verdicts, failures"
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); NoLog = $true; KeepLoaded = $true })
    Check "-KeepLoaded: no unload call"                      (@($r.Hits | Where-Object { $_ -like "*/models/unload" }).Count) 0

    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); NoLog = $true }) @{ FIXTURE_NO_UNLOAD = "1" }
    Check "a single-model server (no /models/unload) is fine: still PASS, exit 0" $r.Exit 0

    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); NoLog = $true }) @{ FIXTURE_MODE = "text" }
    Check "call printed as chat text: FAIL, exit 1"          $r.Exit 1
    Has   "...and says so"                                    $r.Out 'emitted the call as CHAT TEXT'
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); NoLog = $true }) @{ FIXTURE_MODE = "prose" }
    Check "tool ignored: FAIL, exit 1"                       $r.Exit 1
    Has   "...and says so"                                    $r.Out 'ignored the tool entirely'
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); NoLog = $true }) @{ FIXTURE_MODE = "wrongtool" }
    Check "wrong tool: WARN, exit 1"                         $r.Exit 1
    Has   "...names the tool it called"                       $r.Out "called 'read_file' instead of write_file"

    $log = Join-Path $tmp "llama-err.tsv"
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); LogFile = $log }) @{ FIXTURE_MODE = "http500" }
    $rows = LogRows $log
    Check "HTTP failure: ERROR, exit 1, logged"              ("{0} {1}" -f $r.Exit, (($rows[1] -split "`t")[5])) "1 ERROR"
    Check "...and the model is still unloaded"               (@($r.Hits | Where-Object { $_ -like "*/models/unload" }).Count) 1

    $r = Invoke-Probe ($lbase + @{ NoLog = $true })
    $probed = @($r.Bodies | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.messages } | ForEach-Object { $_.model })
    [Array]::Sort($probed, [StringComparer]::Ordinal)
    Check "no -Model: listed once from /v1/models, the embed model skipped" ("{0} | {1}" -f @($r.Hits | Where-Object { $_ -like "GET*/v1/models" }).Count, ($probed -join ",")) "1 | qwen3.6:35b-a3b-coding,qwen3:8b"

    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); NoLog = $true }) @{ FIXTURE_NO_PROPS = "1" }
    Has   "/props unavailable: build is 'unknown', the probe still runs" $r.Out 'llama.cpp unknown\)'
    Check "...and still passes"                              $r.Exit 0

    $r = Invoke-Probe @{ Engine = "llamacpp"; EngineHost = "http://fixture.invalid:8090/v1/"; HostLabel = "server"; Model = @("qwen3:8b"); NoLog = $true }
    Check "a trailing /v1/ on the host is accepted (no doubled /v1)" (@($r.Hits | Where-Object { $_ -like "*/v1/v1/*" }).Count) 0
    Check "...and no request URL contains whitespace"        (@($r.Hits | Where-Object { ($_ -replace '^(GET|POST) ', '') -match '\s' }).Count) 0

    Write-Host "-- logs: the right file, and never one of another shape"
    $log = Join-Path $tmp "unrelated.tsv"
    Set-Content -LiteralPath $log -Value "keep me" -Encoding utf8
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); LogFile = (Join-Path $tmp "elsewhere.tsv") })
    Check "an explicit unrelated log file is left alone"      ((Get-Content -LiteralPath $log) -join "") "keep me"

    # An Ollama-era log (7 columns, ollamaVersion) is history: the probe must not append to it.
    $oldLog = Join-Path $tmp "toolcalls-summary.tsv"
    $oldText = "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail`n2026-10-06T09:00:00`tdesktop`t0.34.3`tqwen3:8b`tPASS`t10`tfixture`n"
    [IO.File]::WriteAllText($oldLog, $oldText, $utf8)
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); LogFile = $oldLog })
    Check "an Ollama-era 7-column log as -LogFile: exit 2, nothing sent" ("{0} {1}" -f $r.Exit, $r.Hits.Count) "2 0"
    Check "...the old log is byte-identical"                 ([IO.File]::ReadAllText($oldLog) -eq $oldText) "True"
    Has   "...and it says why"                                $r.Out 'has another header'
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); LogFile = $oldLog; NoLog = $true })
    Check "...but with -NoLog the probe runs and the log is not touched" ("{0} {1}" -f $r.Exit, ([IO.File]::ReadAllText($oldLog) -eq $oldText)) "0 True"

    # The default log is relative to the script, so run a COPY of it in the temp
    # directory: the real tests/results/ must never be written to by a guard.
    $copyDir = Join-Path $tmp "copy"
    New-Item -ItemType Directory -Path (Join-Path $copyDir "results") -Force | Out-Null
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $copyDir "test-toolcalls.ps1")
    # ...with the API-key helper it dot-sources from beside itself (docs/engine-api-keys.md).
    New-Item -ItemType Directory -Path (Join-Path $copyDir "engines") -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines/llamacpp-auth.ps1") -Destination (Join-Path $copyDir "engines/llamacpp-auth.ps1")
    $realScript = $ScriptPath; $ScriptPath = Join-Path $copyDir "test-toolcalls.ps1"
    try { $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b") }) -DefaultLog } finally { $ScriptPath = $realScript }
    $defaultLog = Join-Path $copyDir "results/toolcalls-summary-llamacpp.tsv"
    Check "with no -LogFile, the probe logs to results/toolcalls-summary-llamacpp.tsv" (Test-Path -LiteralPath $defaultLog) "True"
    Check "...and to no other toolcalls-summary file (the Ollama-era name is not created)" (@(Get-ChildItem -LiteralPath (Join-Path $copyDir "results") | Where-Object { $_.Name -like "toolcalls-summary*" -and $_.Name -ne "toolcalls-summary-llamacpp.tsv" }).Count) 0

    Write-Host "-- arguments that are gone"
    foreach ($eng in "ollama", "vllm") {
        $r = Invoke-Probe @{ Engine = $eng; EngineHost = "http://fixture.invalid:8000"; HostLabel = "server"; Model = @("m"); NoLog = $true }
        Check "-Engine ${eng}: exit 2, nothing sent"           ("{0} {1}" -f $r.Exit, $r.Hits.Count) "2 0"
        Has   "...says llamacpp is the only engine"             $r.Out 'supports only -Engine llamacpp'
    }
    $r = Invoke-Probe @{ OllamaHost = "http://fixture.invalid:11434"; HostLabel = "server"; Model = @("qwen3:8b"); NoLog = $true }
    Check "-OllamaHost is no longer a parameter: refused, nothing sent" $r.Hits.Count 0
    Has   "...by PowerShell's parameter binding"              $r.Out "parameter name 'OllamaHost'"
    $src = [IO.File]::ReadAllText($ScriptPath)
    Check "the script names no Ollama endpoint (/api/...)"   ($src -match '/api/') "False"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host "all passed"
exit 0

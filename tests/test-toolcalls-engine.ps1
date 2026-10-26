# protects: test-toolcalls.ps1 on Ollama and llama.cpp (identical payload, logging, unload)
# run-after: test-toolcalls.ps1
# test-toolcalls-engine.ps1 - regression guard for tests/test-toolcalls.ps1, both engines.
#
# Why this exists: the tool-calling probe decides which models may hold an agent
# seat, and it had no guard. -Engine llamacpp (the engine trial,
# docs/llamacpp-trial.md) adds a second path through it. This pins two things:
#   - the Ollama path is unchanged: /api/chat with keep_alive 0, the 7-column log
#     that run-tasks-batch.ps1 parses, the banner;
#   - the llamacpp path asks the SAME question (same prompt, same tool schema),
#     reads the OpenAI-shaped answer (arguments as a JSON string), logs to a
#     SEPARATE file so the Ollama log is never touched, and unloads after each
#     probe in router mode.
#
# What it does: runs the REAL test-toolcalls.ps1 as a child process against a
# stand-in Invoke-RestMethod (a driver defines it, so no server is needed; the
# same technique as test-bench-speed.ps1). Scenarios: PASS, FAIL (call printed as
# chat text), FAIL (ignored the tool), WARN (wrong tool), ERROR (HTTP failure),
# router unload on and off (-KeepLoaded), model listing from /v1/models with an
# embed model skipped, the build read from /props, -NoLog, an unknown engine,
# and that the two engines send an identical messages + tools payload.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-toolcalls-engine.ps1 [-ScriptPath <a test-toolcalls.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-toolcalls.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
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
    # --- Ollama ---
    if ($u -match '/api/version$') { return [pscustomobject]@{ version = '0.34.3' } }
    if ($u -match '/api/tags$') {
        return [pscustomobject]@{ models = @([pscustomobject]@{ name = 'qwen3:8b' }, [pscustomobject]@{ name = 'nomic-embed-text:latest' }, [pscustomobject]@{ name = 'qwen3.6:35b-a3b-coding' }) }
    }
    if ($u -match '/api/chat$') {
        switch ($env:FIXTURE_MODE) {
            'http500'   { throw "fixture: 500 from /api/chat" }
            'text'      { return [pscustomobject]@{ message = [pscustomobject]@{ content = '{"name": "write_file", "arguments": {"path": "a.txt", "content": "hello"}}'; tool_calls = @() } } }
            'prose'     { return [pscustomobject]@{ message = [pscustomobject]@{ content = "To write the text hello to a file, you can use a text editor."; tool_calls = @() } } }
            'wrongtool' { return [pscustomobject]@{ message = [pscustomobject]@{ content = ''; tool_calls = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'read_file'; arguments = [pscustomobject]@{ path = 'a.txt' } } }) } } }
            default     { return [pscustomobject]@{ message = [pscustomobject]@{ content = ''; tool_calls = @([pscustomobject]@{ function = [pscustomobject]@{ name = 'write_file'; arguments = [pscustomobject]@{ path = 'a.txt'; content = 'hello' } } }) } } }
        }
    }
    # --- llama-server ---
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
    function Invoke-Probe([hashtable]$Params, [hashtable]$Env = @{}) {
        $script:scn++
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

    # ===================== Ollama: unchanged =====================
    Write-Host "-- Ollama path (must stay as it was)"
    $log = Join-Path $tmp "ollama.tsv"
    $r = Invoke-Probe @{ Model = @("qwen3:8b"); OllamaHost = "http://fixture.invalid:11434"; HostLabel = "server"; LogFile = $log }
    $rows = LogRows $log
    Check "PASS exits 0"                                     $r.Exit 0
    Check "asks /api/version, then POSTs /api/chat"          (($r.Hits | ForEach-Object { $_ -replace '^(GET|POST) http://fixture.invalid:11434', '$1 ' }) -join ",") "GET /api/version,POST /api/chat"
    $ob = $r.Bodies[0] | ConvertFrom-Json
    Check "...with keep_alive 0 (unload after the probe)"     $ob.keep_alive "0"
    Check "...and the model, stream false"                   ("{0} {1}" -f $ob.model, $ob.stream) "qwen3:8b False"
    Check "7-column header, ollamaVersion in column 3"       $rows[0] "timestamp`thost`tollamaVersion`tmodel`tstatus`tsec`tdetail"
    $c = $rows[1] -split "`t"
    Check "row: host, version, model, status"                ("{0}|{1}|{2}|{3}|{4}" -f $c.Count, $c[1], $c[2], $c[3], $c[4]) "7|server|0.34.3|qwen3:8b|PASS"
    Has   "...detail carries the call"                        $c[6] 'tool_calls -> write_file \{"path":"a.txt","content":"hello"\}'
    Has   "banner names Ollama and its version"              $r.Out '=== Tool-calling probe against http://fixture.invalid:11434 \(server, Ollama 0.34.3\) ==='

    $r = Invoke-Probe @{ Model = @("qwen3:8b"); OllamaHost = "http://fixture.invalid:11434"; HostLabel = "server"; NoLog = $true } @{ FIXTURE_MODE = "text" }
    Check "call printed as chat text: FAIL, exit 1"          ("{0}" -f $r.Exit) 1
    Has   "...and says so"                                    $r.Out 'emitted the call as CHAT TEXT'

    $r = Invoke-Probe @{ OllamaHost = "http://fixture.invalid:11434"; HostLabel = "server"; NoLog = $true }
    Check "no -Model: every installed chat model, embeds skipped" ((@($r.Hits | Where-Object { $_ -like "POST*" }).Count)) 2

    # ===================== llamacpp =====================
    Write-Host "-- llamacpp path"
    $lbase = @{ Engine = "llamacpp"; OllamaHost = "http://fixture.invalid:8090"; HostLabel = "server" }
    $log = Join-Path $tmp "llama.tsv"
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3.6:35b-a3b-coding"); LogFile = $log })
    $rows = LogRows $log
    Check "PASS exits 0"                                     $r.Exit 0
    $h = @($r.Hits | ForEach-Object { $_ -replace '^(GET|POST) http://fixture.invalid:8090', '$1 ' })
    Check "asks /props, POSTs /v1/chat/completions, then unloads (router mode)" ($h -join ",") "GET /props,POST /v1/chat/completions,POST /models/unload"
    Check "...never an Ollama endpoint"                      (@($r.Hits | Where-Object { $_ -like "*/api/*" }).Count) 0
    $lb = $r.Bodies[0] | ConvertFrom-Json
    Check "request: model, stream false, a generous max_tokens (2048)" ("{0} {1} {2}" -f $lb.model, $lb.stream, $lb.max_tokens) "qwen3.6:35b-a3b-coding False 2048"
    Check "request: no keep_alive (that is Ollama's)"        ($null -eq $lb.keep_alive) "True"
    $unloadBody = if ($r.Bodies.Count -gt 1) { ($r.Bodies[1] | ConvertFrom-Json).model } else { "<no unload request>" }
    Check "the unload names the model"                       $unloadBody "qwen3.6:35b-a3b-coding"
    Check "separate log: 8-column header with engine + engineVersion" $rows[0] "timestamp`thost`tengine`tengineVersion`tmodel`tstatus`tsec`tdetail"
    $c = $rows[1] -split "`t"
    Check "row: host, engine, build, model, status"          ("{0}|{1}|{2}|{3}|{4}|{5}" -f $c.Count, $c[1], $c[2], $c[3], $c[4], $c[5]) "8|server|llamacpp|b11561-abcdef0|qwen3.6:35b-a3b-coding|PASS"
    Has   "...detail carries the call, arguments' whitespace collapsed" $c[7] 'tool_calls -> write_file \{"path": "a.txt", "content": "hello"\}'
    Has   "banner names llama.cpp and the build"             $r.Out '\(server, llama.cpp b11561-abcdef0\)'

    Check "both engines send the SAME prompt (messages)"     ((Get-Canonical $lb.messages) -eq (Get-Canonical $ob.messages)) "True"
    Check "...and the SAME tool schema (tools)"              ((Get-Canonical $lb.tools) -eq (Get-Canonical $ob.tools)) "True"
    Has   "...which is the write_file schema, not an empty one" (Get-Canonical $lb.tools) '"name":"write_file"'

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

    $r = Invoke-Probe @{ Engine = "llamacpp"; OllamaHost = "http://fixture.invalid:8090/v1/"; HostLabel = "server"; Model = @("qwen3:8b"); NoLog = $true }
    Check "a trailing /v1/ on the host is accepted (no doubled /v1)" (@($r.Hits | Where-Object { $_ -like "*/v1/v1/*" }).Count) 0
    Check "...and no request URL contains whitespace"        (@($r.Hits | Where-Object { ($_ -replace '^(GET|POST) ', '') -match '\s' }).Count) 0

    $log = Join-Path $tmp "ollama-untouched.tsv"
    Set-Content -LiteralPath $log -Value "keep me" -Encoding utf8
    $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b"); LogFile = (Join-Path $tmp "elsewhere.tsv") })
    Check "an explicit unrelated log file is left alone"      ((Get-Content -LiteralPath $log) -join "") "keep me"

    # The default log is relative to the script, so run a COPY of it in the temp
    # directory: the real tests/results/ must never be written to by a guard.
    $copyDir = Join-Path $tmp "copy"
    New-Item -ItemType Directory -Path (Join-Path $copyDir "results") -Force | Out-Null
    Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $copyDir "test-toolcalls.ps1")
    $realScript = $ScriptPath; $ScriptPath = Join-Path $copyDir "test-toolcalls.ps1"
    try { $r = Invoke-Probe ($lbase + @{ Model = @("qwen3:8b") }) } finally { $ScriptPath = $realScript }
    $defaultLog = Join-Path $copyDir "results/toolcalls-summary-llamacpp.tsv"
    Check "with no -LogFile, llamacpp logs to results/toolcalls-summary-llamacpp.tsv" (Test-Path -LiteralPath $defaultLog) "True"
    Check "...the Ollama log file name is not created beside it" (@(Get-ChildItem -LiteralPath (Join-Path $copyDir "results") | Where-Object { $_.Name -like "toolcalls-summary*" -and $_.Name -ne "toolcalls-summary-llamacpp.tsv" }).Count) 0

    $r = Invoke-Probe @{ Engine = "vllm"; OllamaHost = "http://fixture.invalid:8000"; HostLabel = "server"; Model = @("m"); NoLog = $true }
    Check "an unknown engine: exit 2, nothing sent"          ("{0} {1}" -f $r.Exit, $r.Hits.Count) "2 0"
    Has   "...says what is supported"                        $r.Out 'supports -Engine ollama or llamacpp'
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host "all passed"
exit 0

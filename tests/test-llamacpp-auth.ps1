# protects: the llama-server API key: clients send it, servers require it (docs/engine-api-keys.md)
# run-after: tests/engines/llamacpp-auth.ps1, tests/engines/llamacpp.ps1, a new llama-server client, the llama.cpp or household compose, node3's start-llama-server.ps1, opencode.jsonc's llamacpp providers
# test-llamacpp-auth.ps1 - regression guard for the engines' API key.
#
# Why this exists: once llama-server has --api-key-file, a client that does not send the key gets 401 on everything
# but /health, so the engine looks alive but serves nothing. A server whose key did not take is open to the LAN with
# no sign of it. Both failures are silent at the point they are made, so this guard pins the pieces:
#   1. tests/engines/llamacpp-auth.ps1 finds the key in the documented order and never needs a key to be present.
#   2. The engine adapter's real functions, against a fake llama-server that requires the key: the right key works,
#      a wrong or missing key gives a version line that names the key, not "unreachable".
#   3. Static: every Invoke-RestMethod in the adapter and in run-window's llama.cpp functions sends the headers; the
#      compose files, node3's launcher, the systemd unit and OpenCode's providers carry the key.
# Run: pwsh -NoProfile -File tests/test-llamacpp-auth.ps1   (no network beyond loopback, no real key)
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }

function Get-FreePort {
    $t = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $t.Start(); $p = $t.LocalEndpoint.Port; $t.Stop(); return $p
}
# A llama-server stand-in: /health is public; every other route needs `Authorization: Bearer <Key>`, else 401.
function Start-KeyedHost([string]$Key, [hashtable]$Routes) {
    $routes = [hashtable]::Synchronized($Routes)
    $seen = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $port = Get-FreePort
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://127.0.0.1:$port/")
    $l.Start()
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($l, $routes, $seen, $key)
        while ($l.IsListening) {
            try { $c = $l.GetContext() } catch { break }
            try {
                $path = $c.Request.Url.AbsolutePath
                $auth = "$($c.Request.Headers['Authorization'])"
                $null = $seen.Add("$path|$auth")
                $r = $routes[$path]
                if ($path -ne "/health" -and $auth -ne "Bearer $key") { $c.Response.StatusCode = 401; $r = '{"error":{"code":401,"message":"Invalid API Key"}}' }
                elseif ($null -eq $r) { $c.Response.StatusCode = 404; $r = '{"error":"no route"}' }
                $bytes = [Text.Encoding]::UTF8.GetBytes([string]$r)
                $c.Response.ContentType = "application/json"
                $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $c.Response.Close()
            } catch { }
        }
    }).AddArgument($l).AddArgument($routes).AddArgument($seen).AddArgument($Key)
    $null = $ps.BeginInvoke()
    return [pscustomobject]@{ Url = "http://127.0.0.1:$port"; Seen = $seen; Listener = $l; Shell = $ps }
}
function Stop-KeyedHost($H) { try { $H.Listener.Stop(); $H.Listener.Close() } catch { }; try { $H.Shell.Dispose() } catch { } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("llamacpp-auth-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$saved = @{ LLAMACPP_API_KEY = $env:LLAMACPP_API_KEY; LLAMACPP_API_KEY_FILE = $env:LLAMACPP_API_KEY_FILE }
$h = $null
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    . (Join-Path $repo "tests/engines/llamacpp.ps1")     # brings llamacpp-auth.ps1 with it

    Write-Host "-- where the key comes from (llamacpp-auth.ps1)"
    $kf = Join-Path $tmp "key"
    [IO.File]::WriteAllText($kf, "# fleet`n`n  k-fleet  `n# household`nk-household`n")
    $env:LLAMACPP_API_KEY = $null; $env:LLAMACPP_API_KEY_FILE = $kf
    Check "the file's first key line, trimmed; comments and blanks skipped" (Get-LlamacppApiKey) "k-fleet"
    Check "...sent as a Bearer header"                    ((Get-LlamacppHeaders).Authorization) "Bearer k-fleet"
    $env:LLAMACPP_API_KEY = "k-env"
    Check "the environment variable wins over the file"   (Get-LlamacppApiKey) "k-env"
    $env:LLAMACPP_API_KEY = $null; $env:LLAMACPP_API_KEY_FILE = (Join-Path $tmp "absent")
    Check "no key anywhere: no header, no error"          ((Get-LlamacppHeaders).Count) 0
    [IO.File]::WriteAllText($kf, "# only comments`n`n")
    $env:LLAMACPP_API_KEY_FILE = $kf
    Check "a file with no key line: no key"               ([string](Get-LlamacppApiKey)) ""

    Write-Host "-- the adapter against a llama-server that requires the key"
    $h = Start-KeyedHost "k-fleet" @{
        "/health" = '{"status":"ok"}'
        "/props"  = '{"build_info":"b11561-abcdef0"}'
        "/models" = '{"data":[{"id":"qwen3:8B","aliases":["qwen3:8b"],"status":{"value":"loaded","args":["--ctx-size","32768"]}}]}'
    }
    [IO.File]::WriteAllText($kf, "k-fleet`n")
    Check "with the key: alive"                            (Test-EngineAlive -Root $h.Url) "True"
    Check "...the version"                                 (Get-EngineVersion -Root $h.Url) "b11561-abcdef0"
    Check "...the served models"                           ((Get-EngineServedModels -Root $h.Url) -join ",") "qwen3:8B,qwen3:8b"
    Check "...the served context"                          (Get-EngineServedContext -Root $h.Url -Tag "qwen3:8b") 32768
    $bad = @($h.Seen | Where-Object { $_ -notmatch '^/health\|' -and $_ -notmatch '\|Bearer k-fleet$' })
    Check "...every call but /health carried the key"      $bad.Count 0

    [IO.File]::WriteAllText($kf, "k-wrong`n")
    Check "a wrong key: /health still answers (alive)"     (Test-EngineAlive -Root $h.Url) "True"
    Check "...but no version"                              ([string](Get-EngineVersion -Root $h.Url)) ""
    Has   "...and the version line names the key"          (Format-EngineVersion -ProviderId "llamacpp-server" -Root $h.Url -Version $null) '401: no or wrong API key; docs/engine-api-keys\.md'
    $env:LLAMACPP_API_KEY_FILE = (Join-Path $tmp "absent")
    Has   "no key at all: the same line"                   (Format-EngineVersion -ProviderId "llamacpp-server" -Root $h.Url -Version $null) '401: no or wrong API key'
    $dead = "http://127.0.0.1:$(Get-FreePort)"
    Has   "a host that is down is still 'unreachable'"     (Format-EngineVersion -ProviderId "llamacpp-server" -Root $dead -Version $null) 'props unreachable\)$'

    Write-Host "-- the adapter as the batch loads it (a module built from its text, no `$PSScriptRoot)"
    $adapterText = [IO.File]::ReadAllText((Join-Path $repo "tests/engines/llamacpp.ps1"))
    $mod = $null
    try { $mod = [psmoduleinfo]::new([scriptblock]::Create($adapterText)) } catch { }
    Check "it loads as a module"                           ($null -ne $mod) "True"
    if ($mod) {
        [IO.File]::WriteAllText($kf, "k-fleet`n"); $env:LLAMACPP_API_KEY_FILE = $kf
        Check "...and sends the key from there"             (& $mod { param($r) Get-EngineVersion -Root $r } $h.Url) "b11561-abcdef0"
    }
    $authText = [IO.File]::ReadAllText((Join-Path $repo "tests/engines/llamacpp-auth.ps1"))
    $want = $authText.Substring($authText.IndexOf("function Get-LlamacppApiKey")).TrimEnd()
    $copy = [regex]::Match($adapterText, '(?s)# --- BEGIN copy of llamacpp-auth\.ps1 ---\r?\n(.*?)\r?\n# --- END copy of llamacpp-auth\.ps1 ---').Groups[1].Value.TrimEnd()
    Check "the adapter's copy of the key functions equals llamacpp-auth.ps1's" (($copy -replace "`r", "") -eq ($want -replace "`r", "")) "True"

    Write-Host "-- static: the clients send it"
    $adapter = $adapterText
    $irm = [regex]::Matches($adapter, 'Invoke-RestMethod[^\r\n]*')
    $noHdr = @($irm | Where-Object { $_.Value -notmatch '-Headers' })
    Check "every Invoke-RestMethod in the adapter sends headers ($($irm.Count) calls)" $noHdr.Count 0
    $rw = Get-Content -Raw (Join-Path $repo "tests/run-window.ps1")
    foreach ($fn in "Get-OtherLoadedModels", "Invoke-SeatUnload") {
        $body = [regex]::Match($rw, "function $fn \{[\s\S]*?\n\}").Value
        Has "run-window's $fn sends the key"               $body 'Invoke-RestMethod -Headers \(Get-LlamacppHeaders\)'
    }
    foreach ($f in "tests/bench-speed.ps1", "tests/probe-overflow.ps1", "tests/test-toolcalls.ps1") {
        $t = Get-Content -Raw (Join-Path $repo $f)
        Has "$f loads the key helper"                      $t 'engines/llamacpp-auth\.ps1'
        $llamaCalls = @([regex]::Matches($t, 'Invoke-RestMethod[^\r\n]*(/props|/v1/|/models|\$u )[^\r\n]*') | Where-Object { $_.Value -notmatch '/api/' })
        $unsent = @($llamaCalls | Where-Object { $_.Value -notmatch '-Headers \$llamaHeaders' })
        Check "...and every llama.cpp call in it sends it ($($llamaCalls.Count) calls)" $unsent.Count 0
    }
    $oc = Get-Content -Raw (Join-Path $repo "opencode/global/opencode.jsonc")
    foreach ($v in "SERVER", "DESKTOP", "NODE3") {
        Has "OpenCode's llamacpp-$($v.ToLower()) provider reads the key file" $oc ('"baseURL": "\{env:LLAMACPP_' + $v + '_BASE_URL\}",\s*(//[^\n]*\n\s*)*"apiKey": "\{file:\.secrets/llamacpp-api-key\}"')
    }
    foreach ($f in "server/scripts/llamacpp-window.sh", "server/scripts/llamacpp-soak.sh", "server/scripts/status.sh") {
        $t = Get-Content -Raw (Join-Path $repo $f)
        Has "$f loads llamacpp-auth.sh"                    $t 'llamacpp-auth\.sh'
        # A plain curl (not llamacpp_curl) on a path that needs the key; /health is public and may stay bare.
        $bare = @([regex]::Matches($t, '(?<![\w])("\$CURL"|curl) [^\n]*(:8090|\$URL)/(props|models|v1)'))
        Check "...and calls no key-needing path with bare curl" $bare.Count 0
    }

    Write-Host "-- static: the servers require it"
    $lc = Get-Content -Raw (Join-Path $repo "server/docker/docker-compose.llamacpp.yml")
    Has   "the server's llama-server gets --api-key-file from a compose secret" $lc '- --api-key-file\s+- /run/secrets/llamacpp_api_key'
    Has   "...the secret is declared from a host file"     $lc 'secrets:\s+llamacpp_api_key:\s+(#[^\n]*\n\s*)*file: \$\{LLAMACPP_API_KEY_FILE'
    Has   "...and the healthcheck wants 401 from /props without it" $lc "http_code\}' http://127\.0\.0\.1:8090/props\)\\?`" = 401"
    $unit = Get-Content -Raw (Join-Path $repo "server/systemd/llamacpp-server.service")
    Has   "the systemd unit refuses to start without the key file" $unit 'ExecStartPre=/usr/bin/test -s [^\n]*/\.config/llamacpp/api-key'
    $hh = Get-Content -Raw (Join-Path $repo "server/docker/docker-compose.household.yml")
    Has   "Open WebUI sends the household key, required"   $hh 'OPENAI_API_KEY=\$\{LLAMACPP_HOUSEHOLD_KEY:\?'
    Check "...and no longer 'none'"                        ($hh -match 'OPENAI_API_KEY=none') "False"
    $n3 = Get-Content -Raw (Join-Path $repo "node3/scripts/start-llama-server.ps1")
    Has   "node3 passes --api-key-file when the key exists" $n3 '\$argLine \+= " --api-key-file'
    Has   "...-Lan refuses without it"                     $n3 'if \(\$Lan -and -not \$useKey -and -not \$NoKey\)'
    Has   "...and it checks for 401 without the key after the start" $n3 'if \(\$code -ne 401\)'
} finally {
    if ($h) { Stop-KeyedHost $h }
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host "all passed"
exit 0

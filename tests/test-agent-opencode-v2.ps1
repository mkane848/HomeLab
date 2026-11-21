# protects: The OpenCode adapter reading 2.x transcripts, config sources and compaction threshold
# run-after: tests/agents/opencode.ps1 or tests/agents/fixtures/opencode-v2/
# test-agent-opencode-v2.ps1 - the OpenCode adapter on OpenCode 2.x's output
#
# Why this exists: OpenCode 2.x (the desktop updated itself to v2.3.2 on
# 2026-11-21) changed what the harness reads (docs/opencode-2-migration.md):
#   - file tools take `path`, not `filePath`; the shell tool is `shell`;
#   - error events are {type, message, status, response.body}, and the
#     "context-overflow" classification 2.x makes internally is not in them;
#   - `debug config` lists config sources instead of one resolved config;
#   - compaction triggers at window - max(15%, 16000), with no limit.output term.
# A harness that misread any of these would count no edits, no overflows, no
# model limits, or a wrong threshold, and say nothing.
#
# What it does, with no opencode and no model:
#   1. Read-AgentEvents on transcripts captured from the real v2.3.2 against a
#      scripted stand-in model (tests/agents/fixtures/opencode-v2/).
#   2. Test-OpencodeOverflowText: the overflow wording, and the status rule.
#   3. ConvertFrom-OpencodeConfigSources on a source list shaped like v2.3.2's.
#   4. Get-CompactionThreshold's 2.x formula, against values worked by hand.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-agent-opencode-v2.ps1 [-AdapterPath <an opencode.ps1>]
param([string]$AdapterPath = (Join-Path $PSScriptRoot "agents\opencode.ps1"))

$ErrorActionPreference = "Stop"
. $AdapterPath
$fx = Join-Path $PSScriptRoot "agents\fixtures\opencode-v2"

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

Write-Host "-- 1. transcripts (v2.3.2, scripted model)"
$ev = (Read-AgentEvents -Path (Join-Path $fx "full.jsonl"))
$tools = @($ev | Where-Object Kind -eq "tool")
Check "four tool calls: read, write, edit, shell" (($tools | ForEach-Object Tool) -join ",") "read,write,edit,shell"
Check "all completed" (($tools | ForEach-Object Status) -join ",") "completed,completed,completed,completed"
Check "read/write/edit name their file through path" (($tools | ForEach-Object { $_.Paths -join ";" }) -join ",") 'C:\fixture\project\a.txt,C:\fixture\project\b.txt,C:\fixture\project\a.txt,'
$ends = @($ev | Where-Object Kind -eq "step-end")
Check "five step ends (one per tool call), the last one stop" (($ends | ForEach-Object Finish) -join ",") "tool-calls,tool-calls,tool-calls,tool-calls,stop"
Check "tokens read from step_finish" (($ends | ForEach-Object Input) -join ",") "500,600,700,800,900"
Check "the model's text" (@($ev | Where-Object Kind -eq "text")[0].Text) "FIXTURE-DONE"
$sids = @($ev | Where-Object SessionId | ForEach-Object SessionId | Sort-Object -Unique)
$fu = (Read-AgentEvents -Path (Join-Path $fx "followup.jsonl"))
Check "one session, and the --session follow-up stays on it" ("$($sids.Count) " + ([bool](@($fu | Where-Object SessionId)[0].SessionId -eq $sids[0]))) "1 True"
$ovAll = Read-AgentEvents -Path (Join-Path $fx "overflow.jsonl"); $ov = @($ovAll | Where-Object Kind -eq "error")
Check "llama-server's overflow 400 is a ContextOverflowError" ("$($ov.Count) $($ov[0].Name) $($ov[0].StatusCode)") "1 ContextOverflowError 400"
Check "...with its message" $ov[0].Message "the request exceeds the available context size, try increasing it"
$bmAll = Read-AgentEvents -Path (Join-Path $fx "badmodel.jsonl"); $bm = @($bmAll | Where-Object Kind -eq "error")
Check "an unknown model keeps 2.x's type" ("$($bm[0].Name)|$($bm[0].StatusCode)") "provider.no-route|"
Check "a 1.x error line still reads as before" ((Read-AgentEvents -Path (& {
    $f = Join-Path ([IO.Path]::GetTempPath()) ("v1err-" + [guid]::NewGuid().ToString("N") + ".jsonl")
    Set-Content -LiteralPath $f -Value '{"type":"error","sessionID":"s","error":{"name":"APIError","data":{"message":"m","statusCode":402,"metadata":{"url":"u"}}}}'
    $f }))[0] | ForEach-Object { "$($_.Name)|$($_.Message)|$($_.StatusCode)|$($_.Url)" }) "APIError|m|402|u"
$v2402 = Join-Path ([IO.Path]::GetTempPath()) ("v2err-" + [guid]::NewGuid().ToString("N") + ".jsonl")
Set-Content -LiteralPath $v2402 -Value '{"type":"error","sessionID":"s","error":{"type":"provider.quota","message":"insufficient balance","status":402}}'
Check "a 2.x 402 keeps its status (the Go spend gate reads it)" ((Read-AgentEvents -Path $v2402)[0] | ForEach-Object { "$($_.Name)|$($_.StatusCode)" }) "provider.quota|402"
Remove-Item -LiteralPath $v2402 -ErrorAction SilentlyContinue

Write-Host "-- 2. the overflow rule (packages/ai/src/provider-error.ts at v2.3.2)"
Check "llama.cpp wording, 400"         (Test-OpencodeOverflowText -Text "the request exceeds the available context size" -Status 400) "True"
Check "Ollama/OpenAI wording, no status" (Test-OpencodeOverflowText -Text "This model's maximum context length is 8192 tokens") "True"
Check "the same wording as a 429 is a throttle" (Test-OpencodeOverflowText -Text "the request exceeds the available context size" -Status 429) "False"
Check "...and as a 500 is not client-scoped" (Test-OpencodeOverflowText -Text "the request exceeds the available context size" -Status 500) "False"
Check "an exclusion wins (rate limit)" (Test-OpencodeOverflowText -Text "rate limit: too many tokens" -Status 400) "False"
Check "a bodiless 413"                 (Test-OpencodeOverflowText -Text "413 status code (no body)") "True"
Check "an unrelated 400"               (Test-OpencodeOverflowText -Text "invalid tool schema" -Status 400) "False"

Write-Host "-- 3. config sources (shaped like v2.3.2's debug config)"
$sources = @(
    [pscustomobject]@{ type = "document"; path = "global"; info = [pscustomobject]@{
        model = [pscustomobject]@{ providerID = "p"; model = "m" }; update = "notify"
        plugins = @("file:///a"); permissions = @([pscustomobject]@{ action = "edit"; resource = "*"; effect = "ask" })
        providers = [pscustomobject]@{ p = [pscustomobject]@{ models = [pscustomobject]@{ m = [pscustomobject]@{ limit = [pscustomobject]@{ context = 65536; output = 8192 } } } } } } }
    [pscustomobject]@{ type = "directory"; path = "dir" }
    [pscustomobject]@{ type = "document"; path = "overlay"; info = [pscustomobject]@{
        plugins = @("file:///b"); compaction = [pscustomobject]@{ buffer = "20%" }
        providers = [pscustomobject]@{ p = [pscustomobject]@{ models = [pscustomobject]@{ m = [pscustomobject]@{ limit = [pscustomobject]@{ output = 4096 } }; n = [pscustomobject]@{ limit = [pscustomobject]@{ context = 32768 } } } } } } }
)
$cfg = ConvertFrom-OpencodeConfigSources -Sources $sources
Check "marked as 2.x" $cfg._opencodeMajor 2
Check "providers merged, later wins per key" ("$($cfg.provider.p.models.m.limit.context)/$($cfg.provider.p.models.m.limit.output)") "65536/4096"
Check "model ids from every source" (((Get-AgentModelIds -Config $cfg).Keys | Sort-Object) -join ",") "p/m,p/n"
Check "plugins append across sources" ($cfg.plugin -join ",") "file:///a,file:///b"
Check "update notify -> autoupdate notify (pinned)" ("$($cfg.autoupdate) " + (Test-AgentAutoupdatePinned -Config $cfg -EnvValue "")) "notify True"
Check "update disable -> pinned" (Test-AgentAutoupdatePinned -Config (ConvertFrom-OpencodeConfigSources -Sources @([pscustomobject]@{ type = "document"; info = [pscustomobject]@{ update = "disable" } })) -EnvValue "") "True"
Check "update auto -> not pinned" (Test-AgentAutoupdatePinned -Config (ConvertFrom-OpencodeConfigSources -Sources @([pscustomobject]@{ type = "document"; info = [pscustomobject]@{ update = "auto" } })) -EnvValue "") "False"

Write-Host "-- 4. the 2.x compaction threshold (calculateCeiling, v2.3.2)"
function T($context, $output = 4096, $buffer = $null, $inputLimit = $null) {
    $lim = [ordered]@{ context = $context; output = $output }; if ($inputLimit) { $lim.input = $inputLimit }
    $info = [ordered]@{ providers = @{ p = @{ models = @{ m = @{ limit = $lim } } } } }
    if ($null -ne $buffer) { $info.compaction = @{ buffer = $buffer } }
    $c = ConvertFrom-OpencodeConfigSources -Sources @([pscustomobject]@{ type = "document"; info = ([pscustomobject]$info | ConvertTo-Json -Depth 10 | ConvertFrom-Json) })
    return (Get-CompactionThreshold -Config $c -ModelId "p/m").threshold
}
Check "64k, no buffer: 65536 - 16000"            (T 65536) 49536
Check "limit.output does not move it"            (T 65536 16384) 49536
Check "32k: the 16000 floor"                     (T 32768) 16768
Check "16k: below 32000, 15% only"               (T 16384) 13927
Check 'buffer "20%": round(13107.2)'             (T 65536 4096 "20%") 52429
Check "buffer 8000 tokens"                       (T 65536 4096 8000) 57536
Check "a buffer >= the window is ignored"        (T 65536 4096 70000) 49536
Check "limit.input below the context is the window" (T 65536 4096 $null 40000) 24000

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agent-oc2-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$savedPath = $env:PATH
try {
    Write-Host "-- 5. Go spend from the 2.x message store (Get-AgentSpendRecords -DbPath -CatalogPath)"
    # A store shaped like v2.3.2's session_message, written with node's built-in SQLite.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $mk = @'
const { DatabaseSync } = await import("node:sqlite")
const [file, now, extra] = process.argv.slice(2)
const d = new DatabaseSync(file)
d.exec("CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")
const ins = d.prepare("INSERT INTO session_message VALUES (?, 's', ?, 0, ?, ?, ?)")
const h = 3600000, n = Number(now)
const msg = (p, m, cost, tin, tout) => JSON.stringify({ model: { id: m, providerID: p }, cost, tokens: { input: tin, output: tout } })
const rows = [
  ["a1", "assistant", n - 1 * h, msg("opencode-go", "priced-m", 0.5, 1000, 100)],
  ["a2", "assistant", n - 2 * h, msg("opencode-go", "free-m", 0, 500, 50)],
  ["a3", "assistant", n - 40 * 24 * h, msg("opencode-go", "priced-m", 0.25, 900, 90)],
  ["a4", "assistant", n - 1 * h, msg("other-p", "x", 9, 10, 1)],
  ["a5", "assistant", n - 1 * h, msg("local-p", "y", 0, 400, 40)],
  ["u1", "user", n - 1 * h, JSON.stringify({ model: { providerID: "opencode-go" }, cost: 7 })],
]
if (extra === "unpriced") rows.push(["a6", "assistant", n - 0.5 * h, msg("opencode-go", "priced-m", 0, 800, 80)])
for (const r of rows) ins.run(r[0], r[1], r[2], r[2], r[3])
'@
    $mkFile = Join-Path $tmp "mkdb.mjs"; [IO.File]::WriteAllText($mkFile, $mk, (New-Object System.Text.UTF8Encoding($false)))
    $db1 = Join-Path $tmp "ok.db"; $db2 = Join-Path $tmp "unpriced.db"
    & node --no-warnings $mkFile $db1 "$now" "" | Out-Null
    & node --no-warnings $mkFile $db2 "$now" "unpriced" | Out-Null
    $cat = Join-Path $tmp "models.json"
    '{"opencode-go":{"models":{"priced-m":{"cost":{"input":1,"output":2}},"free-m":{"cost":{"input":0,"output":0}}}}}' | Set-Content -LiteralPath $cat
    $since = (Get-Date).ToUniversalTime().AddDays(-35)
    $r = Get-AgentSpendRecords -Provider "opencode-go" -Since $since -DbPath $db1 -CatalogPath $cat
    Check 'assistant replies of the provider since -Since: 2, $0.50 (a free model''s $0 is fine; older, other-provider and user rows left out)' ("{0}|{1}" -f $r.Count, (($r | Measure-Object Usd -Sum).Sum)) "2|0.5"
    Check "...their times are UTC from time_created" ([bool](@($r | Where-Object { $_.Time -gt (Get-Date).ToUniversalTime().AddHours(-3) }).Count -eq 2)) "True"
    $out2 = @(Get-AgentSpendRecords -Provider "opencode-go" -Since $since -DbPath $db2 -CatalogPath $cat 3>&1)
    $w = @($out2 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    $r2 = @($out2 | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
    Check "a priced model's reply with tokens and no cost: fails closed (null)" ("{0}|{1}" -f $r2.Count, ($null -eq $r2[0])) "1|True"
    Check "...and the warning says which model" ([bool]("$($w.Message)" -match 'no cost for priced opencode-go replies \(priced-m\)')) "True"
    Check "no catalog: a zero-cost reply with tokens cannot be told free, so null" ($null -eq (Get-AgentSpendRecords -Provider "opencode-go" -Since $since -DbPath $db1 -CatalogPath (Join-Path $tmp "none.json") 3>$null)) "True"
    $r3 = Get-AgentSpendRecords -Provider "local-p" -Since $since -DbPath $db1 -CatalogPath $cat
    Check "a provider the catalog does not list prices nothing: read, not null" ("{0}|{1}" -f ($null -eq $r3), $r3.Count) "False|1"
    $r4 = Get-AgentSpendRecords -Provider "nobody" -Since $since -DbPath $db1 -CatalogPath $cat
    Check "no replies: an empty list (read, nothing spent), not null" ("{0}|{1}" -f ($null -eq $r4), $r4.Count) "False|0"
    Check "a missing store: null" ($null -eq (Get-AgentSpendRecords -Provider "opencode-go" -Since $since -DbPath (Join-Path $tmp "nope.db") -CatalogPath $cat)) "True"

    Write-Host "-- 6. listing one provider's models (Get-AgentProviderModels), 1.x and 2.x"
    $bin = Join-Path $tmp "bin"; New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $rgBin = Join-Path $tmp "oc-bin"; New-Item -ItemType Directory -Path $rgBin -Force | Out-Null
    @"
@echo off
echo %*>>"%FX_CALLS%"
if "%~1"=="--version" (echo %FX_VER%& exit /b 0)
if "%~1"=="--standalone" if "%~2"=="models" (echo opencode-go/alpha& echo opencode-go/beta& echo llamacpp-server/alpha& exit /b 0)
if "%~1"=="models" if "%~2"=="opencode-go" (echo opencode-go/alpha& exit /b 0)
if "%~1"=="debug" if "%~2"=="paths" (echo bin        $rgBin& exit /b 0)
echo USAGE
exit /b 0
"@ | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
    $env:FX_CALLS = Join-Path $tmp "calls.txt"
    $env:PATH = "$bin;$savedPath"
    $env:FX_VER = "opencode v2.3.2"
    Check "2.x: --standalone models, kept to the provider" ((Get-AgentProviderModels -Provider "opencode-go") -join ",") "opencode-go/alpha,opencode-go/beta"
    Check "...asked as --standalone models (2.x prints help for a provider argument)" (@(Get-Content -LiteralPath $env:FX_CALLS)[-1]) "--standalone models"
    $env:FX_VER = "1.19.5"
    Check "1.x: models <provider>, as before" ((Get-AgentProviderModels -Provider "opencode-go") -join ",") "opencode-go/alpha"
    Check "...asked as models opencode-go" (@(Get-Content -LiteralPath $env:FX_CALLS)[-1]) "models opencode-go"

    Write-Host "-- 7. the 2.x ripgrep check (Test-AgentTools -Version 2.3.2)"
    $errs = $null
    $ttAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "test-tasks.ps1"), [ref]$null, [ref]$errs)
    foreach ($fn in $ttAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @("Run-Native", "Run-NativeTimed", "ConvertTo-WindowsArgument") }, $true)) { Invoke-Expression $fn.Extent.Text }
    $env:FX_VER = "opencode v2.3.2"
    # No rg anywhere on PATH (the CI runner puts one there), and an empty opencode bin folder.
    $noRg = @($savedPath -split ';' | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $_ "rg.exe")) -and -not (Test-Path -LiteralPath (Join-Path $_ "rg.cmd")) }) -join ';'
    $env:PATH = "$bin;$noRg"
    $t1 = Test-AgentTools -Version "2.3.2"
    Check "no rg on PATH or in opencode's bin: checked, not ok" ("{0}|{1}" -f $t1.checked, $t1.ok) "True|False"
    Check "...and the detail says where it looked" ([bool]($t1.detail -match 'ripgrep not found' -and $t1.detail.Contains($rgBin))) "True"
    # An rg on PATH comes first, as in opencode's lookup: a stand-in that finds the probe.
    $pathRg = Join-Path $tmp "path-rg"; New-Item -ItemType Directory -Path $pathRg -Force | Out-Null
    "@echo off`r`necho probe.txt`r`nexit /b 0" | Set-Content -LiteralPath (Join-Path $pathRg "rg.cmd") -Encoding ascii
    $env:PATH = "$bin;$pathRg;$noRg"
    $t2 = Test-AgentTools -Version "2.3.2"
    Check "rg on PATH that finds the probe: ok, and it names that rg" ("{0}|{1}" -f $t2.ok, [bool]($t2.detail -match [regex]::Escape((Join-Path $pathRg "rg.cmd")))) "True|True"
    "@echo off`r`nexit /b 2" | Set-Content -LiteralPath (Join-Path $pathRg "rg.cmd") -Encoding ascii
    $t3 = Test-AgentTools -Version "2.3.2"
    Check "an rg that fails: not ok, with its exit" ("{0}|{1}" -f $t3.ok, [bool]($t3.detail -match 'exit 2')) "False|True"
    # The real ripgrep in opencode's bin folder (if this machine has one to copy): found there and works.
    $realRg = @((Get-Command rg.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source), (Join-Path $HOME ".cache\opencode\bin\rg.exe")) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($realRg) {
        Copy-Item -LiteralPath $realRg -Destination (Join-Path $rgBin "rg.exe")
        $env:PATH = "$bin;$noRg"
        $t4 = Test-AgentTools -Version "2.3.2"
        Check "a real rg.exe in opencode's bin folder: ok, and it names it" ("{0}|{1}" -f $t4.ok, [bool]($t4.detail -match [regex]::Escape((Join-Path $rgBin "rg.exe")))) "True|True"
    } else {
        Write-Host "SKIP a real rg.exe in opencode's bin folder (no ripgrep on this machine to copy)"
    }
    Check "another version is not checked" ((Test-AgentTools -Version "2.4.0").checked) "False"
} finally {
    $env:PATH = $savedPath
    Remove-Item Env:FX_CALLS, Env:FX_VER -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"

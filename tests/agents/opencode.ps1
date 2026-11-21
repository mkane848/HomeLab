# tests/agents/opencode.ps1 - the OpenCode adapter for the task harness.
#
# Everything test-tasks.ps1 and run-tasks-batch.ps1 need to know about the agent
# that runs a task lives in one file per agent, here. The grading (worktrees,
# pinned bases, hidden tests, guard rails, scope, suite, summaries) and the
# analysis of a run (context events, stop kinds, outside writes, usage, cap
# hits) are client-neutral: they read the events Read-AgentEvents returns and
# never the agent's own transcript format. Switching agents means writing a
# sibling of this file with the same functions and passing -Agent <name>;
# results from another agent are a new era (the run JSON records `agent`).
# Owner, 2026-10-10: the daily client may move off OpenCode, so OpenCode-specific
# code stays here and stays thin.
#
# The interface every adapter provides (dot-sourced; functions and $script:
# variables land in the caller's scope):
#   $script:AgentName                 "opencode"
#   $script:AgentSamplingNote         what the agent lets a run pin (seed, temperature)
#   Get-AgentVersion                  the agent's version string, or $null
#   Get-AgentConfig                   the agent's resolved config object, or $null
#   Get-AgentModelIds [-Config]       hashtable of model ids the agent can drive, or $null
#   Test-AgentAutoupdatePinned        whether the agent will not upgrade itself mid-batch
#   Get-AgentModelSettings -ModelId   { OutputLimit; Compaction; Plugins } for one model
#   Start-AgentRunEnv -Plugins        per-run environment; returns a state object (its
#                                     Shell: the shell the agent's own commands run in, or $null)
#   Stop-AgentRunEnv -State           undoes it; returns what it measured (plugin rewrites)
#   Invoke-AgentRun                   start or continue (-SessionId) a run; appends the
#                                     agent's raw transcript to -Transcript
#   Stop-OrphanAgent -WtPath          kill agent processes left running against a worktree
#   Test-AgentTools [-Version]        whether the agent's own tools work on this machine
#                                     (before any run); { checked; ok; detail; seconds }
#   Read-AgentEvents -Path            the transcript as neutral events (below)
#
# Neutral events (Read-AgentEvents), one per transcript line the agent wrote:
#   Kind       step-start | step-end | text | tool | error | other
#   SessionId  the agent's session id, when the line carries one
#   step-end:  Finish (finish reason), HasTokens, Input, Output, Reasoning,
#              CacheRead, CacheWrite (raw counts; $null when absent)
#   text:      Text, CompactionContinue ($true for the message the agent itself
#              sends after compacting a session, which is not the model's text)
#   tool:      Tool (the agent's tool name), Status, Input (raw arguments),
#              Paths (files it names: filePath (1.x), path (2.x), patch
#              headers), OutputChars
#   error:     Name, Message, StatusCode, Url, Line (the raw line). 1.x writes
#              error.{name, data.{message, statusCode, metadata.url}}; 2.x writes
#              error.{type, message, status, response.body} and drops its own
#              "context-overflow" classification, so a 2.x overflow (a 4xx that is
#              not a 429, overflow wording; Test-OpencodeOverflowText) is named
#              ContextOverflowError here as 1.x named it. Other 2.x errors keep
#              their type (provider.no-route, provider.transport, ...).
# Tool names are opencode's (1.x: read, write, edit, multiedit, patch, bash, ...;
# 2.x: read, write, edit, shell, ... - no patch or multiedit); another adapter
# maps its own names onto these. 2.x shapes: tests/agents/fixtures/opencode-v2/
# (captured 2026-11-21 against a scripted stand-in model, v2.3.2).

$script:AgentName = "opencode"

# opencode's synthetic user message after an automatic compaction
# (session/compaction.ts in 1.18.34, hard-coded). It marks a compaction in a
# `--format json` transcript, which has no compaction event of its own.
$script:CompactionContinueText = "Continue if you have next steps, or stop and ask for clarification"

$script:AgentSamplingNote = "opencode run has no known per-invocation seed/temperature flag, and opencode.jsonc's model schema only supports limit/modalities/tool_call (AGENTS.md) - not pinned, not independently reproducible across runs. See the header comment and docs/review-gate/r3-runner.ps1 (which pins these by calling the Ollama API directly, outside the real opencode tool loop)."

# OpenCode 2.x's own "this error is a context overflow" test: the patterns,
# exclusions and bodiless-4xx fallback of isContextOverflow, and the status rule
# around it (a client-scoped 4xx that is not a 429), in packages/ai/src/
# provider-error.ts at tag v2.3.2 (read 2026-11-21). 2.x classifies such an error
# as "context-overflow" but its `run --format json` error event carries only
# type/message/status, so Read-AgentEvents re-applies the rule. Re-copy on upgrade.
# (1.x's list, for probing an engine directly, is tests/probe-overflow.ps1's.)
$script:OpencodeV2OverflowPatterns = @(
    'prompt is too long', 'input is too long for (?:the )?(?:requested|selected) model',
    "too large for the model'?s configured input limit", 'exceeded this model context window limit', 'exceeds the context window',
    "exceeds (?:the )?(?:model'?s )?maximum context length(?: of [\d,]+ tokens?|\s*\([\d,]+\))", 'input token count.*exceeds the maximum',
    'number of input tokens exceeds maximum length', 'tokens in request more than max tokens allowed', 'maximum prompt length is \d+',
    'reduce the length of the messages', 'requested input length \d+ exceeds maximum input length', 'maximum context length is \d+ tokens',
    'exceeds (?:the )?maximum allowed input length of [\d,]+ tokens?', "input(?: \(\d+ tokens\))? is longer than the model'?s context length",
    'exceeds the limit of \d+', 'exceeds the available context size', 'greater than the context length',
    '`inputs` tokens \+ `max_new_tokens` must be <= \d+', 'context window exceeds limit', 'context window exceeded', 'exceeded model token limit',
    'context[_ ]length[_ ]exceeded', 'context length is only \d+ tokens', 'input length.*exceeds.*context length',
    'prompt (?:too long|exceeds max length|超长)', 'too large for model with \d+ maximum context length',
    'prompt has [\d,]+ tokens?, but the configured context size is [\d,]+ tokens?', 'model_context_window_exceeded',
    'range of input length should be', 'too many tokens', 'token limit exceeded', 'request_too_large')
$script:OpencodeV2OverflowExclusions = @('^(throttling error|service unavailable):', 'rate limit', 'too many requests',
    'max[_ ]tokens must be less than', 'too many tokens(?: per day)?, please wait')

function Test-OpencodeOverflowText {
    # Would OpenCode 2.x classify this error as a context overflow? -Status is the
    # HTTP status when known: only a 4xx other than 429 (or no status) qualifies.
    param([string]$Text, $Status = $null)
    if (-not $Text) { return $false }
    if ($null -ne $Status -and "$Status" -ne "") {
        $s = [int]$Status
        if ($s -lt 400 -or $s -ge 500 -or $s -eq 429) { return $false }
    }
    foreach ($x in $script:OpencodeV2OverflowExclusions) { if ($Text -match "(?im)$x") { return $false } }
    foreach ($p in $script:OpencodeV2OverflowPatterns) { if ($Text -match "(?i)$p") { return $true } }
    return ($Text -match '(?im)^4(?:00|13)\s*(status code)?\s*\(no body\)')
}

function Get-OpencodeMajor {
    # The major version of the opencode on PATH (1 or 2), or $null. Callers take
    # the 2.x layout for major 2 ONLY: a later major is unread (as the version pins
    # are), and the guards' stand-ins report "9.9.9" for "some unpinned version".
    param([string]$Version = (Get-AgentVersion))
    if ("$Version" -match '^(\d+)\.') { return [int]$matches[1] }
    return $null
}

function ConvertFrom-OpencodeConfigSources {
    # OpenCode 2.x's `debug config` lists config SOURCES ([{type, path, info}],
    # each `info` normalized to 2.x keys) instead of one resolved config. This
    # merges the `info` objects in the order listed (later wins; objects merge,
    # arrays replace, except `plugins` and `permissions`, which append) and adds
    # the 1.x names the harness reads, so callers keep one shape:
    #   provider <- providers; plugin <- plugins; autoupdate <- update
    #   ("disable" -> $false, "notify", "auto" -> $true). compaction stays 2.x
    # (keep, buffer, background). _opencodeMajor = 2 marks the result.
    # An approximation of opencode's own merge, recorded with each run.
    param($Sources)
    function Merge-Into($Dst, $Src) {
        foreach ($k in @($Src.Keys)) {
            $v = $Src[$k]
            if ($Dst.Contains($k) -and $Dst[$k] -is [System.Collections.IDictionary] -and $v -is [System.Collections.IDictionary]) { Merge-Into $Dst[$k] $v }
            elseif ($Dst.Contains($k) -and ($k -eq "plugins" -or $k -eq "permissions") -and $Dst[$k] -is [System.Collections.IList] -and $v -is [System.Collections.IList]) { $Dst[$k] = @($Dst[$k]) + @($v) }
            else { $Dst[$k] = $v }
        }
    }
    $merged = [ordered]@{}
    foreach ($s in @($Sources)) {
        if ($null -eq $s -or -not $s.PSObject.Properties["info"] -or $null -eq $s.info) { continue }
        $h = $s.info | ConvertTo-Json -Depth 50 -Compress | ConvertFrom-Json -AsHashtable -Depth 50
        if ($h -is [System.Collections.IDictionary]) { Merge-Into $merged $h }
    }
    if ($merged.Contains("providers")) { $merged["provider"] = $merged["providers"] }
    if ($merged.Contains("plugins")) { $merged["plugin"] = $merged["plugins"] }
    if ($merged.Contains("update")) {
        $merged["autoupdate"] = switch ("$($merged["update"])") { "disable" { $false } "auto" { $true } default { "$($merged["update"])" } }
    }
    $merged["_opencodeMajor"] = 2
    return ($merged | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50)
}

function Read-AgentEvents {
    # opencode's `--format json` transcript (one JSON event per line, across
    # every turn appended to it) as neutral events. Unparseable lines are
    # skipped. Shares ReadWrite: a live run may still be appending.
    param([string]$Path)
    $events = New-Object System.Collections.Generic.List[object]
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return , $events }
    $reader = New-Object System.IO.StreamReader((New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)))
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { continue }
            try { $e = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($null -eq $e) { continue }
            $sid = if ($e.PSObject.Properties["sessionID"] -and $e.sessionID) { [string]$e.sessionID } else { $null }
            $p = $e.part
            switch ("$($e.type)") {
                "step_start" { $events.Add([pscustomobject]@{ Kind = "step-start"; SessionId = $sid }) }
                "step_finish" {
                    $t = if ($p) { $p.tokens } else { $null }
                    $c = if ($t) { $t.cache } else { $null }
                    $events.Add([pscustomobject]@{
                        Kind = "step-end"; SessionId = $sid
                        Finish = $(if ($p) { $p.reason } else { $null })
                        HasTokens = [bool]$t
                        Input = $(if ($t) { $t.input } else { $null }); Output = $(if ($t) { $t.output } else { $null })
                        Reasoning = $(if ($t) { $t.reasoning } else { $null })
                        CacheRead = $(if ($c) { $c.read } else { $null }); CacheWrite = $(if ($c) { $c.write } else { $null })
                    })
                }
                "text" {
                    $txt = if ($p) { [string]$p.text } else { "" }
                    $events.Add([pscustomobject]@{ Kind = "text"; SessionId = $sid; Text = $txt; CompactionContinue = $txt.TrimStart().StartsWith($script:CompactionContinueText) })
                }
                "tool_use" {
                    $st = if ($p) { $p.state } else { $null }
                    $in = if ($st) { $st.input } else { $null }
                    $paths = @()
                    if ($in -and $in.filePath) { $paths += "$($in.filePath)" }
                    elseif ($in -and $in.PSObject.Properties["path"] -and $in.path -is [string] -and "$($p.tool)" -in @("read", "write", "edit")) { $paths += "$($in.path)" }
                    if ($in -and $in.patchText) {
                        foreach ($m in [regex]::Matches("$($in.patchText)", '(?m)^\*\*\* (?:(?:Add|Update|Delete) File|Move to): (.+?)\s*$')) { $paths += $m.Groups[1].Value }
                    }
                    $events.Add([pscustomobject]@{
                        Kind = "tool"; SessionId = $sid
                        Tool = $(if ($p) { "$($p.tool)" } else { "" })
                        Status = $(if ($st) { "$($st.status)" } else { "" })
                        Input = $in; Paths = $paths
                        OutputChars = $(if ($st) { ([string]$st.output).Length } else { 0 })
                    })
                }
                "error" {
                    $er = $e.error
                    if ($er -and $er.PSObject.Properties["type"] -and -not $er.PSObject.Properties["name"]) {
                        # 2.x
                        $status = if ($er.PSObject.Properties["status"]) { $er.status } else { $null }
                        $body = if ($er.response -and $er.response.PSObject.Properties["body"]) { [string]$er.response.body } else { "" }
                        $name = [string]$er.type
                        if ($name -eq "provider.invalid-request" -and (Test-OpencodeOverflowText -Text (([string]$er.message) + "`n" + $body) -Status $status)) { $name = "ContextOverflowError" }
                        $events.Add([pscustomobject]@{
                            Kind = "error"; SessionId = $sid; Name = $name
                            Message = [string]$er.message; StatusCode = $status; Url = $null; Line = $line
                        })
                        continue
                    }
                    $d = if ($er) { $er.data } else { $null }
                    $events.Add([pscustomobject]@{
                        Kind = "error"; SessionId = $sid
                        Name = $(if ($er) { $er.name } else { $null })
                        Message = $(if ($d) { $d.message } else { $null })
                        StatusCode = $(if ($d) { $d.statusCode } else { $null })
                        Url = $(if ($d -and $d.metadata) { $d.metadata.url } else { $null })
                        Line = $line
                    })
                }
                default { $events.Add([pscustomobject]@{ Kind = "other"; SessionId = $sid }) }
            }
        }
    } finally {
        $reader.Dispose()
    }
    return , $events
}

function Get-AgentVersion {
    # `opencode --version`, trimmed - the string every run JSON records. $null
    # when opencode is missing or prints something that is not a version.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = (& opencode --version 2>$null | Out-String).Trim()
        # 2.x prints "opencode v2.3.2"; recorded as "2.3.2", like 1.x's "1.19.5".
        $out = $out -replace '^opencode\s+v', ''
        if ($out -match '^\d+\.\d+\.\d+') { return $out }
    } catch {
        # fall through to $null
    } finally {
        $ErrorActionPreference = $prev
    }
    return $null
}

function Get-AgentConfig {
    # The RESOLVED opencode config (`opencode debug config`, including an
    # OPENCODE_CONFIG overlay) as an object, or $null. On 2.x through
    # `--standalone` (the shared service ignores this process's env, so the
    # overlays and {env:} would not apply) and ConvertFrom-OpencodeConfigSources.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ((Get-OpencodeMajor) -eq 2) {
            $src = (& opencode --standalone debug config 2>$null | Out-String) | ConvertFrom-Json -ErrorAction Stop
            return (ConvertFrom-OpencodeConfigSources -Sources $src)
        }
        return ((& opencode debug config 2>$null | Out-String) | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-AgentModelIds {
    # Model ids the resolved config knows ("provider/model"). `opencode run`
    # cannot drive anything else - it would exit non-zero and burn a run as
    # _INFRA_. $null when the config cannot be read, and then nothing is filtered.
    param($Config = (Get-AgentConfig))
    if ($null -eq $Config) { return $null }
    $ids = @{}
    foreach ($prov in $Config.provider.PSObject.Properties) {
        foreach ($mod in $prov.Value.models.PSObject.Properties) { $ids["$($prov.Name)/$($mod.Name)"] = $true }
    }
    return $ids
}

function Get-AgentProviderModels {
    # The full model ids ("opencode-go/qwen3.8-max") the agent lists for one
    # provider, or $null when the listing fails. It lists; it calls no model.
    # 1.x: `opencode models <provider>`. 2.x prints its help for a provider
    # argument (measured 2026-11-21, v2.3.2), so: `opencode --standalone models`
    # (the caller's env and overlays apply) and keep that provider's lines.
    param([string]$Provider)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ((Get-OpencodeMajor) -eq 2) {
            $out = @(& opencode --standalone models 2>$null)
        } else {
            $out = @(& opencode models $Provider 2>$null)
        }
        if ($LASTEXITCODE -ne 0) { return $null }
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prev
    }
    $pat = '^' + [regex]::Escape($Provider) + '/\S+$'
    return , @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match $pat })
}

# Reads OpenCode 2.x's message store for Get-AgentSpendRecords. Node's built-in
# SQLite (Node 22.13+/24, the version opencode's npm install needs anyway),
# opened READ-ONLY; only session_message is read (the account and credential
# tables hold tokens). Prints {rows: [{t, usd}], unpriced: [model ids]}, where
# unpriced lists models with a reply that used tokens and recorded no cost although
# the catalog (argv 4, opencode's cached models.json) prices them; with no catalog,
# every such reply's model counts (a free model cannot be told from a lost cost).
$script:OpencodeV2SpendJs = @'
const { DatabaseSync } = await import("node:sqlite")
const { readFileSync, existsSync } = await import("node:fs")
const [db, provider, since, catalog] = process.argv.slice(2)
const d = new DatabaseSync(db, { readOnly: true })
const rows = d.prepare("SELECT time_created AS t, json_extract(data,'$.cost') AS usd, json_extract(data,'$.model.id') AS model, json_extract(data,'$.tokens.input') AS tin, json_extract(data,'$.tokens.output') AS tout FROM session_message WHERE type = 'assistant' AND json_extract(data,'$.model.providerID') = ? AND time_created >= ?").all(provider, Number(since))
let prices = null
// A provider the catalog does not list (a local or custom one) prices nothing: {}.
try { if (catalog && existsSync(catalog)) prices = JSON.parse(readFileSync(catalog, "utf8"))?.[provider]?.models ?? {} } catch { prices = null }
const unpriced = new Set()
for (const r of rows) {
  const used = Number(r.tin || 0) + Number(r.tout || 0)
  if (Number(r.usd || 0) > 0 || used === 0) continue
  const c = prices ? prices[r.model]?.cost : undefined
  if (!prices || (c && (Number(c.input || 0) > 0 || Number(c.output || 0) > 0))) unpriced.add(r.model)
}
process.stdout.write(JSON.stringify({ rows: rows.map((r) => ({ t: Number(r.t), usd: r.usd == null ? 0 : Number(r.usd) })), unpriced: [...unpriced] }))
'@

function Get-OpencodeCatalogPath {
    # The model catalog opencode caches (<cache>/models.json; `opencode debug paths`), or $null.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        foreach ($l in @(& opencode debug paths 2>$null)) { if ("$l" -match '^\s*cache\s+(.+?)\s*$') { return (Join-Path $matches[1] "models.json") } }
    } catch { } finally { $ErrorActionPreference = $prev }
    return $null
}

function Get-OpencodeDbPath {
    # OpenCode 2.x's database path (`opencode debug paths`: "db  <path>"), or $null.
    # `debug paths` runs in this process's env (XDG_*, OPENCODE_DB) and rejects --standalone.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        foreach ($l in @(& opencode debug paths 2>$null)) { if ("$l" -match '^\s*db\s+(.+?)\s*$') { return $matches[1] } }
    } catch { } finally { $ErrorActionPreference = $prev }
    return $null
}

function Get-AgentSpendRecords {
    # Every reply from -Provider the agent has recorded on this machine since
    # -Since: a list of { Time (UTC); Usd }, the agent's own per-message cost.
    # That covers interactive use as well as harness runs. $null when it cannot
    # be read (an empty list means "read, nothing spent").
    # 1.x: `opencode db` (a SELECT on the message table).
    # 2.x: `opencode db` is gone; replies are session_message rows of type
    # "assistant" with data.model.providerID and data.cost (v2.3.2, 2026-11-21),
    # read from the database `opencode debug paths` names, read-only, through
    # node (-DbPath and -CatalogPath override the lookups; a guard passes fixtures).
    # 2.x fails closed: if a reply used tokens and recorded no cost although the
    # catalog prices its model, the result is $null ("could not read"), with a
    # warning. Measured 2026-11-21 on v2.3.2: 482 opencode-go/deepseek-v4.1-flash
    # replies (catalog $0.15/$0.60 per M tokens, ~773k in, ~85k out) recorded $0,
    # where 1.x had priced every Go model. A meter that read them as free would
    # never stop a batch.
    param([string]$Provider, [datetime]$Since, [string]$DbPath = "", [string]$CatalogPath = "")
    $ms = [DateTimeOffset]::new([datetime]::SpecifyKind($Since, [DateTimeKind]::Utc)).ToUnixTimeMilliseconds()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $jsFile = $null
    $v2 = $false
    try {
        if ($DbPath -or (Get-OpencodeMajor) -eq 2) {
            if (-not $DbPath) { $DbPath = Get-OpencodeDbPath }
            if (-not $DbPath -or -not (Test-Path -LiteralPath $DbPath)) { return $null }
            $jsFile = Join-Path ([IO.Path]::GetTempPath()) ("oc-spend-" + [guid]::NewGuid().ToString("N") + ".mjs")
            [IO.File]::WriteAllText($jsFile, $script:OpencodeV2SpendJs, (New-Object System.Text.UTF8Encoding($false)))
            $catalog = if ($CatalogPath) { $CatalogPath } else { Get-OpencodeCatalogPath }
            $out = & node --no-warnings $jsFile $DbPath $Provider "$ms" "$catalog" 2>$null
            $v2 = $true
        } else {
            # BETWEEN rather than >=: no character cmd.exe could read as a redirect
            # when opencode is a .cmd shim.
            $q = "SELECT time_created AS t, json_extract(data,'$.cost') AS usd FROM message WHERE json_extract(data,'$.providerID')='$Provider' AND json_extract(data,'$.role')='assistant' AND time_created BETWEEN $ms AND 99999999999999"
            $out = & opencode db $q --format json 2>$null
        }
        $code = $LASTEXITCODE
    } catch {
        return $null
    } finally {
        $ErrorActionPreference = $prevEap
        if ($jsFile) { Remove-Item -LiteralPath $jsFile -ErrorAction SilentlyContinue }
    }
    if ($code -ne 0) { return $null }
    $text = ($out | Out-String).Trim()
    # The leading comma keeps an empty list a list: an unrolled @() would reach
    # the caller as $null, which means "could not read".
    $records = New-Object System.Collections.Generic.List[object]
    if (-not $text) { return , $records }
    try { $rows = $text | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($v2) {
        if (@($rows.unpriced | Where-Object { $_ }).Count -gt 0) {
            Write-Warning ("opencode recorded no cost for priced $Provider replies ($(@($rows.unpriced) -join ', ')): its spend cannot be read")
            return $null
        }
        $rows = @($rows.rows)
    }
    foreach ($r in $rows) {
        if ($null -eq $r -or $null -eq $r.t) { continue }
        $records.Add([pscustomobject]@{ Time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$r.t).UtcDateTime; Usd = [double]$r.usd })
    }
    return , $records
}

function Test-AgentAutoupdatePinned {
    # True when opencode will not upgrade itself: the global config sets
    # autoupdate to false or "notify", or OPENCODE_DISABLE_AUTOUPDATE is "1" or
    # "true" (opencode's own rule for boolean flags, case-insensitive). Unset
    # means ON - patch releases install themselves when a TUI starts (never from
    # `opencode run`), which is how the corpus went 1.18.31 -> .32 -> .33 in ten days.
    param($Config, [string]$EnvValue = $env:OPENCODE_DISABLE_AUTOUPDATE)

    if ($EnvValue -and @("true", "1") -contains $EnvValue.ToLower()) { return $true }
    if ($null -ne $Config) {
        $a = $Config.autoupdate
        if ($a -is [bool] -and -not $a) { return $true }
        if ($a -is [string] -and $a -eq "notify") { return $true }
    }
    return $false
}

function Get-ModelOutputLimit {
    # limit.output for -ModelId in the RESOLVED opencode config (`opencode debug
    # config`, the same source test-profiles.ps1 checks). $null when it cannot be
    # read - opencode missing, config invalid, model not registered - so the gate
    # degrades to "cannot confirm a cap" instead of failing the run.
    param([string]$ModelId)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $cfg = Get-AgentConfig
        $provider, $name = $ModelId -split '/', 2
        $lim = $cfg.provider.PSObject.Properties[$provider].Value.models.PSObject.Properties[$name].Value.limit
        if ($lim -and $lim.output) { return [int]$lim.output }
    } catch {
        # fall through to $null
    } finally {
        $ErrorActionPreference = $prev
    }
    return $null
}

function Get-CompactionThreshold {
    # The prompt size at which opencode 1.18.34 compacts a session for
    # -ModelId, from a resolved config object (session/overflow.ts `usable`):
    #   reserved  = compaction.reserved, else min(20000, maxOutput)
    #   threshold = limit.input - reserved   when limit.input is set,
    #               limit.context - maxOutput otherwise (reserved unused)
    # where maxOutput = min(limit.output, 32000). It is part of what a run
    # measured: a lower threshold compacts earlier, so it is recorded per run.
    param($Config, [string]$ModelId)
    $provider, $name = $ModelId -split '/', 2
    $lim = $null
    try { $lim = $Config.provider.PSObject.Properties[$provider].Value.models.PSObject.Properties[$name].Value.limit } catch { }
    if (-not $lim -or -not $lim.context) { return $null }
    if ($Config.PSObject.Properties["_opencodeMajor"] -and [int]$Config._opencodeMajor -ge 2) {
        # OpenCode 2.x, calculateCeiling in packages/core/src/session/compaction.ts
        # at v2.3.2 (read 2026-11-21). limit.output is NOT subtracted any more:
        #   window    = min(limit.input, limit.context), or whichever is set
        #   threshold = window - buffer        when compaction.buffer is set
        #               ("15%" = round(window*15/100), or a token count) and < window,
        #   else      = window - max(floor(window*0.15), 16000 if window >= 32000 else 0)
        $window = if ($lim.input -and $lim.context) { [Math]::Min([int]$lim.input, [int]$lim.context) } elseif ($lim.input) { [int]$lim.input } else { [int]$lim.context }
        $buffer = $null; $keep = $null
        if ($Config.PSObject.Properties["compaction"] -and $Config.compaction) {
            if ($Config.compaction.PSObject.Properties["buffer"]) { $buffer = $Config.compaction.buffer }
            if ($Config.compaction.PSObject.Properties["keep"] -and $Config.compaction.keep) { $keep = $Config.compaction.keep.tokens }
        }
        $tokens = $null
        if ($buffer -is [string] -and $buffer.Trim().EndsWith("%")) { $tokens = [int][Math]::Round(($window * [double]::Parse($buffer.Trim().TrimEnd('%'), [Globalization.CultureInfo]::InvariantCulture)) / 100, [MidpointRounding]::AwayFromZero) }
        elseif ($null -ne $buffer -and "$buffer" -ne "") { $tokens = [int]$buffer }
        $reserve = if ($null -ne $tokens -and $tokens -lt $window) { $tokens } else { [Math]::Max([int][Math]::Floor($window * 0.15), $(if ($window -ge 32000) { 16000 } else { 0 })) }
        return [pscustomobject]@{
            limitContext = [int]$lim.context
            limitInput   = $(if ($lim.input) { [int]$lim.input } else { $null })
            limitOutput  = $(if ($lim.output) { [int]$lim.output } else { $null })
            reserved     = $reserve
            threshold    = $window - $reserve
            prune        = $null
            buffer       = $buffer
            keepTokens   = $keep
            formula      = "opencode 2.x calculateCeiling (v2.3.2)"
        }
    }
    $maxOut = if ($lim.output) { [Math]::Min([int]$lim.output, 32000) } else { 32000 }
    $cfgReserved = $null
    if ($Config.PSObject.Properties["compaction"] -and $null -ne $Config.compaction.reserved) { $cfgReserved = [int]$Config.compaction.reserved }
    $reserved = if ($null -ne $cfgReserved) { $cfgReserved } else { [Math]::Min(20000, $maxOut) }
    $threshold = if ($lim.input) { [Math]::Max(0, [int]$lim.input - $reserved) } else { [Math]::Max(0, [int]$lim.context - $maxOut) }
    return [pscustomobject]@{
        limitContext = [int]$lim.context
        limitInput   = $(if ($lim.input) { [int]$lim.input } else { $null })
        limitOutput  = $(if ($lim.output) { [int]$lim.output } else { $null })
        reserved     = $(if ($lim.input) { $reserved } else { $null })
        threshold    = $threshold
        # compaction.prune (removes old tool outputs; off by default). Part of what a run measured (2026-11-04: the
        # prune experiment runs with it on through OPENCODE_CONFIG); $null when the config does not set it.
        prune        = $(if ($Config.PSObject.Properties["compaction"] -and $null -ne $Config.compaction.prune) { [bool]$Config.compaction.prune } else { $null })
    }
}

function Get-ModelCompactionConfig {
    # Get-CompactionThreshold on the RESOLVED config. $null when unreadable.
    param([string]$ModelId)
    $cfg = Get-AgentConfig
    if ($null -eq $cfg) { return $null }
    return Get-CompactionThreshold -Config $cfg -ModelId $ModelId
}

function Get-OpencodePlugins {
    # The `plugin` entries of the RESOLVED opencode config. A plugin can change
    # what the model is sent - opencode/plugins/compaction-continue.js rewrites
    # the post-compaction message - so it is part of what a run measured. Empty
    # when none or unreadable.
    $cfg = Get-AgentConfig
    if ($cfg -and $cfg.PSObject.Properties["plugin"]) {
        return @($cfg.plugin | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | ConvertTo-Json -Compress -Depth 4 } })
    }
    return @()
}

function Get-AgentModelSettings {
    # What the harness records about how opencode will treat one model:
    # OutputLimit (limit.output, for the output-cap check), Compaction (when it
    # compacts, Get-CompactionThreshold) and Plugins (opencode plugins in effect).
    param([string]$ModelId)
    return [pscustomobject]@{
        OutputLimit = Get-ModelOutputLimit -ModelId $ModelId
        Compaction  = Get-ModelCompactionConfig -ModelId $ModelId
        Plugins     = @(Get-OpencodePlugins)
    }
}

function Get-AgentShellPath {
    # The shell opencode's own shell tool should run: this process's pwsh, by
    # full path. opencode 1.18.34 takes the config's `shell`, else $env:SHELL,
    # else the first of pwsh, powershell, Git Bash and cmd that it finds on PATH
    # (packages/core/src/shell.ts), and it does not accept a 0-byte Store app
    # alias. node3's PowerShell 7 is the Store install, whose only pwsh.exe on
    # PATH is such an alias, so every node3 run's commands went to Windows
    # PowerShell 5.1, whose script policy there is Restricted: 139 of 140
    # transcripts of 2026-10-24/25 hit "npm.ps1 cannot be loaded" at least once.
    # $PSHOME is the real install folder (the Store's versioned package folder
    # on node3), so the path is always a real file and follows upgrades.
    $exe = if ($IsWindows) { "pwsh.exe" } else { "pwsh" }
    return (Join-Path $PSHOME $exe)
}

function Start-AgentRunEnv {
    # The agent's shell: Get-AgentShellPath, set as `shell` through
    # OPENCODE_CONFIG_CONTENT, which opencode merges after every config file
    # (packages/opencode/src/config/config.ts), so it wins over the global
    # config's "shell": "pwsh". An OPENCODE_CONFIG_CONTENT the caller set is
    # kept (the shell is added to it) and restored afterwards; one that is not
    # a JSON object is left alone and the run records no forced shell.
    # compaction-continue.js writes one JSON line per model call it rewrote to
    # HOMELAB_COMPACTION_PLUGIN_LOG (opencode inherits the env); counted after
    # the run. Its idle continue stays off here: `opencode run` exits when the
    # session goes idle, so a message sent then would land in a session nobody
    # answers (and in the next follow-up's). -NudgeAfterCompaction and
    # -NudgeOnStop are what measure that behaviour.
    # read-budget.js writes one JSON line per read it clamped to
    # HOMELAB_READ_BUDGET_LOG; summarised after the run (Stop-AgentRunEnv).
    param([string[]]$Plugins = @())
    $state = [pscustomobject]@{ PluginLog = $null; ReadLog = $null; Shell = $null
        ConfigContent = [Environment]::GetEnvironmentVariable("OPENCODE_CONFIG_CONTENT") }
    $content = $null
    if ($state.ConfigContent) {
        try { $content = $state.ConfigContent | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $content = $null }
        if ($content -isnot [System.Collections.IDictionary]) { $content = $null }
    } else {
        $content = @{}
    }
    if ($null -ne $content) {
        $state.Shell = Get-AgentShellPath
        $content["shell"] = $state.Shell
        $env:OPENCODE_CONFIG_CONTENT = ($content | ConvertTo-Json -Compress -Depth 20)
    }
    if (@($Plugins | Where-Object { $_ -match 'compaction-continue' }).Count -gt 0) {
        $state.PluginLog = Join-Path ([System.IO.Path]::GetTempPath()) ("ccplugin-" + [guid]::NewGuid().ToString("N").Substring(0, 12) + ".jsonl")
        $env:HOMELAB_COMPACTION_PLUGIN_LOG = $state.PluginLog
        $env:HOMELAB_COMPACTION_IDLE_CONTINUE = "off"
    }
    if (@($Plugins | Where-Object { $_ -match 'read-budget' }).Count -gt 0) {
        $state.ReadLog = Join-Path ([System.IO.Path]::GetTempPath()) ("rbplugin-" + [guid]::NewGuid().ToString("N").Substring(0, 12) + ".jsonl")
        $env:HOMELAB_READ_BUDGET_LOG = $state.ReadLog
    }
    return $state
}

function Stop-AgentRunEnv {
    # Undoes Start-AgentRunEnv. Returns $null when none of our plugins was
    # loaded, else an object with
    #   CompactionRewrites  the number of model calls that carried the plugin's
    #                       rewritten continue message (every step after a
    #                       compaction carries it, so this counts calls, not
    #                       compactions), or $null without that plugin;
    #   ReadBudget          { clamps; byReason { cap; budget }; files; loaded;
    #                       off; capOverride } from the read-budget plugin's log
    #                       (files = distinct paths; loaded, off and capOverride
    #                       from its first "loaded" line, i.e. what the plugin
    #                       saw of HOMELAB_READ_MAX_CHARS inside opencode; off
    #                       and capOverride are $null when it never logged
    #                       loading), or $null without that plugin.
    param($State)
    if (-not $State) { return $null }
    if ($State.PSObject.Properties['Shell'] -and $State.Shell) {
        if ($State.ConfigContent) { $env:OPENCODE_CONFIG_CONTENT = $State.ConfigContent } else { Remove-Item Env:OPENCODE_CONFIG_CONTENT -ErrorAction SilentlyContinue }
    }
    $rewrites = $null
    if ($State.PluginLog) {
        Remove-Item Env:HOMELAB_COMPACTION_PLUGIN_LOG, Env:HOMELAB_COMPACTION_IDLE_CONTINUE -ErrorAction SilentlyContinue
        $rewrites = if (Test-Path -LiteralPath $State.PluginLog) { @(Select-String -LiteralPath $State.PluginLog -Pattern '"message":"rewrote').Count } else { 0 }
        Remove-Item -LiteralPath $State.PluginLog -ErrorAction SilentlyContinue
    }
    $readBudget = $null
    if ($State.ReadLog) {
        Remove-Item Env:HOMELAB_READ_BUDGET_LOG -ErrorAction SilentlyContinue
        $cap = 0; $budget = 0; $paths = @{}; $loadedLine = $null
        if (Test-Path -LiteralPath $State.ReadLog) {
            foreach ($line in (Get-Content -LiteralPath $State.ReadLog)) {
                $e = $null
                try { $e = $line | ConvertFrom-Json } catch { continue }
                if ($e -and $e.message -eq "loaded" -and -not $loadedLine) { $loadedLine = $e; continue }
                if (-not $e -or $e.message -ne "clamp") { continue }
                if ($e.reason -eq "budget") { $budget++ } else { $cap++ }
                if ($e.path) { $paths[[string]$e.path] = $true }
            }
        }
        $readBudget = [pscustomobject]@{ clamps = $cap + $budget; byReason = [pscustomobject]@{ cap = $cap; budget = $budget }; files = $paths.Count
            loaded = [bool]$loadedLine
            off = $(if ($loadedLine -and $null -ne $loadedLine.off) { [bool]$loadedLine.off } else { $null })
            capOverride = $(if ($loadedLine -and $loadedLine.capOverride) { [string]$loadedLine.capOverride } else { $null }) }
        Remove-Item -LiteralPath $State.ReadLog -ErrorAction SilentlyContinue
    }
    if (-not $State.PluginLog -and -not $State.ReadLog) { return $null }
    return [pscustomobject]@{ CompactionRewrites = $rewrites; ReadBudget = $readBudget }
}

# The opencode version Test-AgentTools was written against: `opencode debug rg`
# and the ripgrep lookup behind it (packages/core/src/ripgrep/binary.ts at
# v1.18.34; re-checked at v1.19.5 (2026-10-31): those files unchanged, and shell.ts with it).
# On another version re-read that file, then move this.
$script:AgentToolsCheckedVersion = "1.19.5"
# 2.x has no `debug rg`. Its lookup (packages/core/src/ripgrep/binary.ts at v2.3.2,
# read 2026-11-21): rg on PATH, else <bin>/rg.exe (`opencode debug paths` "bin"),
# else download ripgrep 15.1.0 (hash-pinned) and unpack it with System32's tar.exe.
# The 2.x check runs that lookup and a nonce search with the binary it finds.
$script:AgentToolsCheckedVersionV2 = "2.3.2"

function Test-AgentTools {
    # Do the agent's search tools work on this machine? opencode's grep and glob
    # run ripgrep, which it finds as rg.exe on PATH, else in its cache
    # (~/.cache/opencode/bin), else downloads and unpacks with Windows
    # PowerShell's Expand-Archive. On 2026-10-21 that unpacking failed on node3
    # inside a scheduled task ("module could not be loaded"): every grep and glob
    # call of a 15-task round errored (83 calls, 12 runs), the model searched
    # blind, and the round read like a weaker seat (10 of 15). So before any run,
    # `opencode debug rg search` (the same lookup, no model) looks for a nonce in
    # a throwaway folder, under this process's environment. It also installs
    # ripgrep where unpacking works. Returns { checked; ok; detail; seconds };
    # checked is $false on another opencode version, because `debug rg` is an
    # undocumented debugging command.
    # The shell the run will hand opencode (Get-AgentShellPath, set by
    # Start-AgentRunEnv) is checked first: it must start and report PowerShell
    # 7 (edition Core). Since 2026-10-26 the result also carries shell (path)
    # and shellVersion ("Core 7.6.7").
    param([string]$Version = (Get-AgentVersion), [int]$TimeoutSec = 180)
    if ($Version -ne $script:AgentToolsCheckedVersion -and $Version -ne $script:AgentToolsCheckedVersionV2) {
        return [pscustomobject]@{ checked = $false; ok = $null; seconds = $null; shell = $null; shellVersion = $null
            detail = "not checked: opencode $(if ($Version) { $Version } else { '(no version)' }) is not $script:AgentToolsCheckedVersion or $script:AgentToolsCheckedVersionV2, the versions this check was written against" }
    }
    $shell = Get-AgentShellPath
    $shellVersion = $null
    if (Test-Path -LiteralPath $shell -PathType Leaf) {
        $sv = Run-NativeTimed $shell @("-NoProfile", "-NonInteractive", "-Command", '$PSVersionTable.PSEdition + " " + $PSVersionTable.PSVersion.ToString()') ([System.IO.Path]::GetTempPath()) 60
        if ($sv.ExitCode -eq 0) { $shellVersion = (@($sv.Output | Where-Object { "$_".Trim() }) | Select-Object -Last 1) -as [string] }
    }
    if (-not $shellVersion -or $shellVersion -notmatch '^Core 7\.') {
        $why = if (-not (Test-Path -LiteralPath $shell -PathType Leaf)) { "$shell does not exist" } elseif ($shellVersion) { "$shell reports '$shellVersion'" } else { "$shell did not run" }
        return [pscustomobject]@{ checked = $true; ok = $false; seconds = $null; shell = $shell; shellVersion = $shellVersion
            detail = "the agent's shell is not PowerShell 7: $why" }
    }
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("agenttools-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    $nonce = "toolprobe" + [guid]::NewGuid().ToString("N").Substring(0, 16)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        Set-Content -LiteralPath (Join-Path $dir "probe.txt") -Value "x $nonce y"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        if ($Version -eq $script:AgentToolsCheckedVersionV2) {
            $rg = Get-Command rg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            $rgPath = if ($rg) { $rg.Source } else { $null }
            if (-not $rgPath) {
                $binDir = $null
                $pr = Run-NativeTimed "opencode" @("debug", "paths") $dir 60
                foreach ($l in @($pr.Output)) { if ("$l" -match '^\s*bin\s+(.+?)\s*$') { $binDir = $matches[1] } }
                $cand = if ($binDir) { Join-Path $binDir $(if ($IsWindows) { "rg.exe" } else { "rg" }) } else { $null }
                if ($cand -and (Test-Path -LiteralPath $cand -PathType Leaf)) { $rgPath = $cand }
            }
            if (-not $rgPath) {
                return [pscustomobject]@{ checked = $true; ok = $false; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); shell = $shell; shellVersion = $shellVersion
                    detail = "ripgrep not found: no rg on PATH and none in opencode's bin folder ($(if ($binDir) { $binDir } else { 'unknown' })); opencode 2.x would download and unpack it at the first search. Put a pinned rg on PATH" }
            }
            $r = Run-NativeTimed $rgPath @("--no-config", "-l", $nonce, ".") $dir $TimeoutSec
            $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $out = ($r.Output | Out-String)
            if ($r.ExitCode -eq 0 -and $out.Contains("probe.txt")) {
                return [pscustomobject]@{ checked = $true; ok = $true; seconds = $secs; shell = $shell; shellVersion = $shellVersion
                    detail = "ripgrep search works ($rgPath, the rg opencode 2.x uses, found the probe file); shell $shellVersion" }
            }
            $tail = (@($r.Output | Where-Object { "$_".Trim() } | Select-Object -Last 3) -join " | ")
            $why = if ($r.TimedOut) { "timed out after $TimeoutSec s" } elseif ($r.ExitCode -ne 0) { "exit $($r.ExitCode)" } else { "exit 0 but the probe file was not found" }
            return [pscustomobject]@{ checked = $true; ok = $false; seconds = $secs; shell = $shell; shellVersion = $shellVersion
                detail = "ripgrep search does not work ($rgPath, $why): $tail" }
        }
        $r = Run-NativeTimed "opencode" @("debug", "rg", "search", $nonce) $dir $TimeoutSec
        $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $out = ($r.Output | Out-String)
        if ($r.ExitCode -eq 0 -and $out.Contains($nonce) -and $out.Contains("probe.txt")) {
            return [pscustomobject]@{ checked = $true; ok = $true; seconds = $secs; shell = $shell; shellVersion = $shellVersion
                detail = "ripgrep search works (opencode debug rg search found the probe file); shell $shellVersion" }
        }
        $tail = (@($r.Output | Where-Object { "$_".Trim() } | Select-Object -Last 3) -join " | ")
        $why = if ($r.TimedOut) { "timed out after $TimeoutSec s" } elseif ($r.ExitCode -ne 0) { "exit $($r.ExitCode)" } else { "exit 0 but the probe file was not found" }
        return [pscustomobject]@{ checked = $true; ok = $false; seconds = $secs; shell = $shell; shellVersion = $shellVersion
            detail = "ripgrep search does not work ($why): $tail" }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-OrphanAgent {
    # Stop-Job does not take the native `opencode run` child with it, and a job
    # whose PowerShell died leaves it running too - it orphans and keeps driving
    # the model (and, on a hosted provider, spending the key). Kill every
    # opencode process pointed at this worktree, whole tree, so the run really
    # ends and the transcript file is released for archiving.
    param([string]$WtPath)
    $orphans = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'opencode%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($WtPath) })
    foreach ($o in $orphans) {
        Run-Native "taskkill" @("/PID", "$($o.ProcessId)", "/T", "/F") | Out-Null
    }
    if ($orphans.Count -gt 0) {
        Write-Host "    killed $($orphans.Count) orphaned opencode process(es) still running against $WtPath" -ForegroundColor Yellow
    }
}

function Invoke-AgentRun {
    # One `opencode run` turn in a background job, with a timeout.
    # -SessionId continues an earlier turn (`opencode run --session`) and
    # -Transcript appends to that turn's transcript, so a multi-turn task keeps
    # one transcript and Writes counts every turn (see the follow-ups in
    # test-tasks.ps1). Returns { ExitCode; Writes; ElapsedSec; TranscriptPath;
    # Ending; Detail }: ExitCode -1 is a timeout, -2 a dead job host.
    param([string]$WtPath, [string]$ModelId, [string]$Prompt, [string]$PromptHash, [int]$TimeoutSec,
          [string]$SessionId = "", [string]$Transcript = "")

    $promptFile = Join-Path $env:TEMP ("task-prompt-{0}.md" -f ([guid]::NewGuid().ToString("N")))
    [System.IO.File]::WriteAllText($promptFile, $Prompt, (New-Object System.Text.UTF8Encoding($false)))
    if ($Transcript) {
        $out = $Transcript
    } else {
        $out = Join-Path $env:TEMP ("task-run-{0}.jsonl" -f ([guid]::NewGuid().ToString("N")))
        # Create the transcript up front: the job only appends per event, so a run
        # that emits nothing before the timeout (north-mini on 2026-09-26, stuck
        # re-prefilling) otherwise leaves no file and vanishes without a trace. An
        # empty _TIMEOUT_ transcript is the evidence that it never got a step out.
        [System.IO.File]::WriteAllText($out, "")
    }

    # OpenCode 2.x (measured 2026-11-21, v2.3.2): `run` has no --dir (it works in
    # the current directory), the shared service ignores this process's env unless
    # --standalone, and a piped stdin that stays open makes `run` wait for it.
    # --archived keeps batch sessions out of the owner's session list. The title
    # carries the worktree path so Stop-OrphanAgent still finds the process by its
    # command line, as it found --dir's path on 1.x.
    $major = Get-OpencodeMajor
    $job = Start-Job -ScriptBlock {
        param($Dir, $ModelId, $PromptFile, $Out, $SessionId, $Major)
        # The canary pattern: run through the real opencode tool layer, JSONL
        # events on stdout, and let the (inherited) process env resolve the
        # provider baseURLs from the sourced profile.
        # Each event is appended to $Out as it arrives, not buffered until exit:
        # a run killed at the timeout used to leave no transcript at all (the
        # whole stream sat in a variable), so a timeout was a pure unknown.
        # The job's own PID first, so the caller can tell a dead job host from a
        # slow run (PowerShell 7 leaves such a job "Running" forever).
        [pscustomobject]@{ JobPid = $PID }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $msg = Get-Content -LiteralPath $PromptFile -Raw
            $enc = New-Object System.Text.UTF8Encoding($false)
            # opencode writes UTF-8; without this the job decodes its stdout
            # with the OEM codepage and every non-ASCII char in the transcript
            # is mojibake (an em dash became "ΓÇö" in the 2026-09-26 runs).
            [Console]::OutputEncoding = $enc
            # Not `$x = if (...) {...} else { @() }`: that assigns $null, which splats
            # as an empty argument to a script (seen with the guard's stand-in).
            $sessionArgs = @()
            if ($SessionId) { $sessionArgs = @("--session", $SessionId) }
            if ($Major -eq 2) {
                Set-Location -LiteralPath $Dir
                @() | & opencode --standalone run --model $ModelId --format json --auto --archived --title "bench $Dir" @sessionArgs $msg 2>$null |
                    ForEach-Object { [System.IO.File]::AppendAllText($Out, "$_`n", $enc) }
            } else {
                & opencode run --dir $Dir --model $ModelId --format json --auto @sessionArgs $msg 2>$null |
                    ForEach-Object { [System.IO.File]::AppendAllText($Out, "$_`n", $enc) }
            }
        } finally {
            $ErrorActionPreference = $prev
        }
        return $LASTEXITCODE
    } -ArgumentList $WtPath, $ModelId, $promptFile, $out, $SessionId, $major

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Wait in slices of up to 5 s, checking between them that the job's
    # PowerShell process is still alive. Windows PowerShell 5.1 marks a job
    # whose process died as Failed and Wait-Job returns; PowerShell 7 leaves it
    # "Running" forever, so without this a dead host sat out the whole timeout
    # and was recorded as a TIMEOUT.
    $finished = $false
    $jobPid = $null
    $hostGone = $false
    while ($true) {
        $left = $TimeoutSec - $sw.Elapsed.TotalSeconds
        if ($left -le 0) { break }
        if (Wait-Job $job -Timeout ([int][math]::Max(1, [math]::Min(5, [math]::Ceiling($left))))) { $finished = $true; break }
        if (-not $jobPid) {
            try {
                $marker = @(Receive-Job $job -Keep -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.PSObject.Properties.Name -contains "JobPid" }) | Select-Object -First 1
                if ($marker) { $jobPid = [int]$marker.JobPid }
            } catch { }
        }
        if ($jobPid -and -not (Get-Process -Id $jobPid -ErrorAction SilentlyContinue)) { $hostGone = $true; break }
    }
    if (-not $finished -and -not $hostGone) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Stop-OrphanAgent -WtPath $WtPath
        Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        # $out is NOT deleted here - whatever the model did before being killed
        # is evidence, not noise. The caller rescues it into tests/results/.
        return [pscustomobject]@{ ExitCode = -1; Writes = -1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "opencode run timed out after $TimeoutSec s (prompt sha $PromptHash)"; TranscriptPath = $out }
    }
    # The job's own PowerShell process can die under the run (2026-10-02, the
    # first run of a batch: "The background process closed or ended abnormally",
    # PSSessionStateBroken). Receive-Job then raises an error that the script's
    # "Stop" made terminating, and it took the whole batch down. A dead job is
    # infrastructure: report it as such (ExitCode -2; -1 means timeout to the
    # caller) and let the batch move on.
    $jobErrs = @()
    $jobBroken = $null
    if ($hostGone) {
        $jobBroken = "its PowerShell process (PID $jobPid) exited before the job finished"
        $jobResult = @()
        # Remove-Job below takes ~57 s on such a job in PowerShell 7 (a fixed
        # transport timeout, measured 2026-10-03; Stop-Job costs the same). Paid
        # once, only on a dead host, and far short of the run timeout.
    } else {
        try {
            $jobResult = @(Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrs |
                Where-Object { -not ($_ -and $_.PSObject.Properties.Name -contains "JobPid") })
        } catch {
            $jobResult = @()
            $jobBroken = $_.Exception.Message
        }
    }
    if (-not $jobBroken) {
        $transport = @($jobErrs | Where-Object { $_.Exception -is [System.Management.Automation.Remoting.PSRemotingTransportException] })
        if ($transport.Count -gt 0) {
            $jobBroken = $transport[0].Exception.Message
        } elseif ($job.State -eq "Failed") {
            $jobBroken = if ($job.JobStateInfo.Reason) { $job.JobStateInfo.Reason.Message } else { "job state Failed" }
        }
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
    $sw.Stop()
    if ($jobBroken) {
        Stop-OrphanAgent -WtPath $WtPath
        return [pscustomobject]@{ ExitCode = -2; Writes = -1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "the background job running opencode ended abnormally ($jobBroken) (prompt sha $PromptHash). Infrastructure failure, NOT model behaviour: not graded, no summary row."; TranscriptPath = $out }
    }

    $code = -1
    $noExit = $false
    if ($jobResult.Count -ge 1) {
        $first = $jobResult[0]
        $raw = if ($first -is [psobject] -and $first.PSObject.Properties.Name -contains "value") { $first.value } else { $first }
        # A job in which `opencode` was never found ends with $LASTEXITCODE
        # $null; [int]$null is 0, which graded an agent that never started as
        # an exit-0 run with zero writes (liar mode, with a summary row).
        if ($null -eq $raw) { $noExit = $true } else { $code = [int]$raw }
    }
    if ($noExit) {
        return [pscustomobject]@{ ExitCode = -2; Writes = -1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = "the agent produced no exit code (is opencode on PATH inside the job?) (prompt sha $PromptHash). Infrastructure failure, NOT model behaviour: not graded, no summary row."; TranscriptPath = $out }
    }
    # $out is NOT deleted here - the caller moves the raw transcript into the
    # results folder next to the graded JSON, so a run's "why" is auditable
    # later instead of stranded in %TEMP% (the round-2 mistake this repo's own
    # review-gate work already learned from - see r3-protocol.md).
    return [pscustomobject]@{ ExitCode = $code; Writes = (Get-WriteCount -Path $out); ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); TranscriptPath = $out; Ending = (Get-TranscriptEnding -Path $out) }
}

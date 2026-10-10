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
#   Start-AgentRunEnv -Plugins        per-run environment; returns a state object
#   Stop-AgentRunEnv -State           undoes it; returns what it measured (plugin rewrites)
#   Invoke-AgentRun                   start or continue (-SessionId) a run; appends the
#                                     agent's raw transcript to -Transcript
#   Stop-OrphanAgent -WtPath          kill agent processes left running against a worktree
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
#              Paths (files it names: filePath, patch headers), OutputChars
#   error:     Name, Message, StatusCode, Url, Line (the raw line)
# Tool names are opencode's (read, write, edit, multiedit, patch, bash, ...);
# another adapter maps its own names onto these.

$script:AgentName = "opencode"

# opencode's synthetic user message after an automatic compaction
# (session/compaction.ts in 1.18.34, hard-coded). It marks a compaction in a
# `--format json` transcript, which has no compaction event of its own.
$script:CompactionContinueText = "Continue if you have next steps, or stop and ask for clarification"

$script:AgentSamplingNote = "opencode run has no known per-invocation seed/temperature flag, and opencode.jsonc's model schema only supports limit/modalities/tool_call (AGENTS.md) - not pinned, not independently reproducible across runs. See the header comment and docs/review-gate/r3-runner.ps1 (which pins these by calling the Ollama API directly, outside the real opencode tool loop)."

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
    # OPENCODE_CONFIG overlay) as an object, or $null.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
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
        $cfg = (& opencode debug config 2>$null | Out-String) | ConvertFrom-Json -ErrorAction Stop
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

function Start-AgentRunEnv {
    # compaction-continue.js writes one JSON line per model call it rewrote to
    # HOMELAB_COMPACTION_PLUGIN_LOG (opencode inherits the env); counted after
    # the run. Its idle continue stays off here: `opencode run` exits when the
    # session goes idle, so a message sent then would land in a session nobody
    # answers (and in the next follow-up's). -NudgeAfterCompaction and
    # -NudgeOnStop are what measure that behaviour.
    param([string[]]$Plugins = @())
    $state = [pscustomobject]@{ PluginLog = $null }
    if (@($Plugins | Where-Object { $_ -match 'compaction-continue' }).Count -gt 0) {
        $state.PluginLog = Join-Path ([System.IO.Path]::GetTempPath()) ("ccplugin-" + [guid]::NewGuid().ToString("N").Substring(0, 12) + ".jsonl")
        $env:HOMELAB_COMPACTION_PLUGIN_LOG = $state.PluginLog
        $env:HOMELAB_COMPACTION_IDLE_CONTINUE = "off"
    }
    return $state
}

function Stop-AgentRunEnv {
    # Undoes Start-AgentRunEnv. Returns the number of model calls that carried
    # the plugin's rewritten continue message (every step after a compaction
    # carries it, so this counts calls, not compactions), or $null without the
    # plugin.
    param($State)
    if (-not $State -or -not $State.PluginLog) { return $null }
    Remove-Item Env:HOMELAB_COMPACTION_PLUGIN_LOG, Env:HOMELAB_COMPACTION_IDLE_CONTINUE -ErrorAction SilentlyContinue
    $n = if (Test-Path -LiteralPath $State.PluginLog) { @(Select-String -LiteralPath $State.PluginLog -Pattern '"message":"rewrote').Count } else { 0 }
    Remove-Item -LiteralPath $State.PluginLog -ErrorAction SilentlyContinue
    return $n
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

    $job = Start-Job -ScriptBlock {
        param($Dir, $ModelId, $PromptFile, $Out, $SessionId)
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
            $sessionArgs = if ($SessionId) { @("--session", $SessionId) } else { @() }
            & opencode run --dir $Dir --model $ModelId --format json --auto @sessionArgs $msg 2>$null |
                ForEach-Object { [System.IO.File]::AppendAllText($Out, "$_`n", $enc) }
        } finally {
            $ErrorActionPreference = $prev
        }
        return $LASTEXITCODE
    } -ArgumentList $WtPath, $ModelId, $promptFile, $out, $SessionId

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
    if ($jobResult.Count -ge 1) {
        $first = $jobResult[0]
        if ($first -is [psobject] -and $first.PSObject.Properties.Name -contains "value") {
            $code = [int]$first.value
        } else {
            $code = [int]$first
        }
    }
    # $out is NOT deleted here - the caller moves the raw transcript into the
    # results folder next to the graded JSON, so a run's "why" is auditable
    # later instead of stranded in %TEMP% (the round-2 mistake this repo's own
    # review-gate work already learned from - see r3-protocol.md).
    return [pscustomobject]@{ ExitCode = $code; Writes = (Get-WriteCount -Path $out); ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); TranscriptPath = $out; Ending = (Get-TranscriptEnding -Path $out) }
}

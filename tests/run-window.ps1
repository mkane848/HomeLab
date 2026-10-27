# run-window.ps1 - an unattended testing window on the run host (node3): gate, smoke, milestone 4's loop, the
# capability baseline, a report in the morning, nothing that waits for a person.
#
# Why this exists: a window of 8 or 9 free hours on the server and node3 (docs/roadmap.md) is only used if someone
# is there to start each step, read each result and decide whether the next one is worth running. This script is
# that someone for the parts that are mechanical. It runs the existing entry points (run-retries.ps1,
# run-tasks-batch.ps1, summarize-rounds.ps1) in a fixed order, decides go or no-go between them from their result
# files, watches the model server while they run, stops everything before a hard deadline, and writes REPORT.md.
# It measures nothing itself and changes nothing in the repo. docs/unattended-window.md is the runbook; the server's
# half is server/scripts/llamacpp-window.sh.
#
# The plan (each phase says what ends it and what a failure costs):
#   gate      Static checks, each PASS / WARN / FAIL; a FAIL ends the window before anything runs (exit 2).
#             The server answers /health (waits up to -WaitServerMinutes for it, so the server's half can be started
#             second) and serves the seat; opencode lists the seat; the private manifest and the task selections
#             resolve; the disk has room; the tools exist. A dirty checkout or a short disk is a WARN.
#   smoke     (about 40 min) run-retries.ps1 on two tasks that normally pass, and the batch on one mined task per
#             repo. GO for a pipeline unless it ran only into infrastructure failures: the retries smoke is GO when
#             at least one task was accepted or none hit an infrastructure outcome; the batch smoke is GO when it
#             exited 0 and left a graded row. The retries smoke gates milestone 4, the batch smoke gates the baseline.
#   m4        (-M4Minutes, default 240) milestone 4's loop: run-retries.ps1 on every live task of the private manifest,
#             real-02 and wp-5b last (they never pass, so they use the most attempts and are what is lost if the phase
#             is cut), -ShowAcceptance with the shown prompt 2, cap -MaxAttempts. Prints the design's falsifier.
#   baseline  (the rest of the window) the capability baseline: the 16 live mined tasks of the public manifest on the
#             batch, unassisted, rep-outer, -BaselineReps repetitions. Rep-outer order means a cut leaves whole reps.
# While a phase runs the script polls the server every -ServerPollSec. A server that stays down for
# -ServerDownMinutes ends the phase; the script then waits -RecoverMinutes for it to come back and, if it does not,
# stops (the report says so). A file named STOP in the output folder ends the window at the next poll.
#
# Output (under -OutDir, default <PrivateRoot>\results\window-<Name>): window.log, status.txt (rewritten every poll),
# commands\<phase>.ps1 (the exact command each phase ran), <phase>.log, one results folder per phase, REPORT.md.
# Exit 0: the window ran to its end (phases may have failed; read the report). 2: the gate said no-go. 3: bad arguments.
#
# Usage (on the run host, from the repo root):
#   pwsh -File tests\run-window.ps1 -Plan                    # show what would run, change nothing
#   pwsh -File tests\run-window.ps1 -Detach                  # run it as a one-shot scheduled task (survives ssh)
#   pwsh -File tests\run-window.ps1 -Hours 6 -Run m4         # directly, for six hours, only milestone 4
# -Run takes any of smoke, m4, baseline (the gate always runs). -Model, -ServerUrl (default $env:LLAMACPP_SERVER_BASE_URL,
# else http://<SERVER_IP>:8090/v1 from the repo's .env), -PrivateRoot (default: the HomeLab-private checkout beside this one)
# and the task selections are parameters; the script sets OPENCODE_DISABLE_AUTOUPDATE=1 for its children, because the
# batch stops when opencode changes version under it.
# The -Script* / -LockPath / -OpencodeCmd / -RequiredTools parameters are the guard's seams (tests/test-run-window.ps1).
param(
    [string]$Name = (Get-Date -Format "yyyyMMdd-HHmm"),
    [double]$Hours = 8,
    [string]$Model = "llamacpp-server/qwen3.6:35b-a3b-coding",
    [string]$ServerUrl = "",
    [string]$PrivateRoot = "",
    [string]$OutDir = "",
    [string[]]$Run = @("smoke", "m4", "baseline"),
    [int]$MaxAttempts = 3,
    [string[]]$M4Tasks = @("all"),
    [string[]]$Last = @("real-02", "wp-5b"),
    [double]$M4Minutes = 240,
    [string[]]$SmokeTasks = @("real-01", "wp-0a"),
    [string[]]$SmokeBatchTasks = @("kane-08", "lfc-04", "asohav-03"),
    [double]$SmokeMinutes = 40,
    [string]$BaselineMatch = '^(kane-(0[7-9]|1[0-4])|lfc-0[457]|asohav-0[3-9])-',
    [int]$BaselineReps = 6,
    [int]$RunTimeout = 2700,
    [int]$StopClassifier = 3,
    [switch]$NoNudge,
    [double]$WaitServerMinutes = 30,
    [double]$ServerDownMinutes = 20,
    [double]$RecoverMinutes = 30,
    [double]$ServerPollSec = 60,
    [double]$PollSec = 15,
    [double]$ReportMinutes = 5,
    [double]$MinPhaseMinutes = 10,
    [string[]]$SkipChecks = @(),
    [switch]$Plan,
    [switch]$Detach,
    [string]$ScriptRetries = (Join-Path $PSScriptRoot "run-retries.ps1"),
    [string]$ScriptBatch = (Join-Path $PSScriptRoot "run-tasks-batch.ps1"),
    [string]$ScriptSummarize = (Join-Path $PSScriptRoot "summarize-rounds.ps1"),
    [string]$LockPath = (Join-Path ([IO.Path]::GetTempPath()) "homelab-window.lock"),
    [string]$OpencodeCmd = "opencode",
    [string[]]$RequiredTools = @("git", "node", "npm")
)
$ErrorActionPreference = "Continue"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Split-List([string[]]$Value) { @($Value | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# The live tasks of a manifest (not `retired`), optionally narrowed. -Names are ids or the unique prefix of one
# ("kane-08" for "kane-08-aristocrats-false-positives"), "all" is every live task; -Match is a regex on the id and wins
# over -Names; ids in -Last move to the end in the order given. Missing = names that matched no (or several) tasks.
function Resolve-WindowTasks {
    param([string]$Manifest, [string[]]$Names = @("all"), [string]$Match = "", [string[]]$Last = @())
    $m = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
    $live = @($m.tasks | Where-Object { -not $_.retired } | ForEach-Object { [string]$_.id })
    $names = Split-List $Names
    $missing = @()
    if ($Match) {
        $ids = @($live | Where-Object { $_ -match $Match })
    } elseif ($names.Count -eq 0 -or $names -contains "all") {
        $ids = $live
    } else {
        $ids = @()
        foreach ($n in $names) {
            $hit = @($live | Where-Object { $_ -eq $n })
            if ($hit.Count -eq 0) { $hit = @($live | Where-Object { $_ -like "$n-*" }) }
            if ($hit.Count -eq 1) { if ($ids -notcontains $hit[0]) { $ids += $hit[0] } } else { $missing += $n }
        }
    }
    foreach ($l in (Split-List $Last)) {
        $hit = @($ids | Where-Object { $_ -eq $l -or $_ -like "$l-*" })
        if ($hit.Count -eq 1) { $ids = @($ids | Where-Object { $_ -ne $hit[0] }) + $hit[0] }
    }
    [pscustomobject]@{ Ids = @($ids); Missing = @($missing) }
}

# 'single-quoted PowerShell literal' for the generated phase scripts.
function Q([string]$s) { "'" + $s.Replace("'", "''") + "'" }
function QList([string[]]$a) { "@(" + ((@($a) | ForEach-Object { Q $_ }) -join ", ") + ")" }

# The text of one phase's command, as written to commands\<phase>.ps1 and run with `pwsh -File`.
function New-RetriesScript {
    param([string]$Script, [string[]]$Tasks, [string]$Model, [int]$Attempts, [string]$Manifest, [string]$ResultsDir, [hashtable]$HarnessArgs)
    $h = ($HarnessArgs.Keys | Sort-Object | ForEach-Object {
            $v = $HarnessArgs[$_]; "$_ = " + $(if ($v -is [bool]) { if ($v) { '$true' } else { '$false' } } else { "$v" }) }) -join "; "
    @(
        "# generated by run-window.ps1: milestone 4's dispatcher loop",
        "& $(Q $Script) -Tasks $(QList $Tasks) -Model $(Q $Model) -MaxAttempts $Attempts -TaskManifest $(Q $Manifest) -ResultsDir $(Q $ResultsDir) -HarnessArgs @{ $h }",
        'exit $LASTEXITCODE') -join "`n"
}
function New-BatchScript {
    param([string]$Script, [string[]]$Tasks, [string]$Model, [int]$Reps, [int]$RunTimeout, [string]$ResultsDir)
    @(
        "# generated by run-window.ps1: the batch, unassisted, rep-outer",
        "& $(Q $Script) -SkipSetup -Mode Tasks -Models $(Q $Model) -Tasks $(QList $Tasks) -Reps $Reps -Yes -RunTimeout $RunTimeout -ResultsDir $(Q $ResultsDir)",
        'exit $LASTEXITCODE') -join "`n"
}

# The command line a scheduled task runs, from the resolved parameters: -Name value, switches bare, arrays comma-joined
# into one argument. Each value is quoted for the Windows command line (a trailing backslash is doubled so it cannot
# swallow the closing quote).
function ConvertTo-CommandLineArg([string]$s) { '"' + (($s -replace '(\\+)$', '$1$1') -replace '"', '\"') + '"' }
function New-TaskArgumentString {
    param([System.Collections.IDictionary]$Parameters)
    $parts = foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v) { "-$k" }; continue }
        "-$k " + (ConvertTo-CommandLineArg (@($v) -join ","))
    }
    ($parts -join " ")
}

# --- the server -------------------------------------------------------------------------------------
. (Join-Path $PSScriptRoot "engines\llamacpp.ps1")     # Test-EngineAlive, Get-EngineServedModels, Get-EngineVersion
function Get-ServerRoot([string]$Url) { ($Url.TrimEnd('/') -replace '/v1$', '') }
function Resolve-ServerUrl([string]$Given) {
    if ($Given) { return $Given }
    if ($env:LLAMACPP_SERVER_BASE_URL) { return $env:LLAMACPP_SERVER_BASE_URL }
    $envFile = Join-Path $repoRoot ".env"
    if (Test-Path -LiteralPath $envFile) {
        $line = Get-Content -LiteralPath $envFile | Where-Object { $_ -match '^\s*SERVER_IP\s*=\s*\S' } | Select-Object -First 1
        if ($line) { return "http://{0}:8090/v1" -f (($line -split "=", 2)[1].Trim().Trim('"').Trim("'")) }
    }
    return ""
}

# --- everything below runs only when the script is run, not when a guard dot-sources it for the functions ---
if ($MyInvocation.InvocationName -eq '.') { return }

$Run = Split-List $Run
if ($Plan) { $WaitServerMinutes = 0 }
foreach ($r in $Run) { if ($r -notin "smoke", "m4", "baseline") { Write-Host "ERROR: -Run takes smoke, m4, baseline (got '$r')" -ForegroundColor Red; exit 3 } }
if ($Hours -le 0) { Write-Host "ERROR: -Hours must be > 0" -ForegroundColor Red; exit 3 }
if (-not $PrivateRoot) { $PrivateRoot = Join-Path (Split-Path $repoRoot) "HomeLab-private" }
if (-not $OutDir) { $OutDir = Join-Path $PrivateRoot ("results\window-" + $Name) }
$OutDir = [IO.Path]::GetFullPath($OutDir)
$ServerUrl = Resolve-ServerUrl $ServerUrl
$serverRoot = Get-ServerRoot $ServerUrl
$seatTag = ($Model -split "/", 2)[1]
$privateManifest = Join-Path $PrivateRoot "tasks\manifest.json"
$publicManifest = Join-Path $PSScriptRoot "tasks\manifest.json"
$pwshPath = (Get-Process -Id $PID).Path

# --- -Detach: hand the same command line to a one-shot scheduled task and return -----------------------
if ($Detach) {
    if (-not $IsWindows) { Write-Host "ERROR: -Detach registers a Windows scheduled task; elsewhere run the script under nohup/systemd" -ForegroundColor Red; exit 3 }
    # The task starts later, in another logon session: give it the values this command line resolved (the name's default is
    # a timestamp, the server URL may come from this session's environment) instead of letting it resolve them again.
    $pass = [ordered]@{}
    foreach ($k in $PSBoundParameters.Keys) { if ($k -ne "Detach") { $pass[$k] = $PSBoundParameters[$k] } }
    $pass["Name"] = $Name; $pass["PrivateRoot"] = $PrivateRoot; $pass["OutDir"] = $OutDir
    if ($ServerUrl) { $pass["ServerUrl"] = $ServerUrl }
    $argv = New-TaskArgumentString -Parameters $pass
    $taskName = "HomeLab-window-$Name"
    $action = New-ScheduledTaskAction -Execute $pwshPath -WorkingDirectory $repoRoot -Argument ("-NoProfile -ExecutionPolicy Bypass -File {0} {1}" -f (ConvertTo-CommandLineArg $PSCommandPath), $argv)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours ([math]::Ceiling($Hours) + 1)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host "started scheduled task '$taskName' (S4U, as $([Security.Principal.WindowsIdentity]::GetCurrent().Name))"
    Write-Host "follow it:  Get-Content -Wait '$(Join-Path $OutDir 'window.log')'     status:  Get-Content '$(Join-Path $OutDir 'status.txt')'"
    Write-Host "end early:  New-Item '$(Join-Path $OutDir 'STOP')'            remove the task afterwards:  Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false"
    exit 0
}

# One window at a time per machine: two would share the task worktrees. The lock is a temp file holding the pid.
$lockPath = $LockPath
if (-not $Plan -and (Test-Path -LiteralPath $lockPath)) {
    $other = try { [int](Get-Content -LiteralPath $lockPath -TotalCount 1) } catch { 0 }
    if ($other -and $other -ne $PID -and (Get-Process -Id $other -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: another window is running on this machine (pid $other; $lockPath). End it with a STOP file in its output folder." -ForegroundColor Red
        exit 3
    }
}
if (-not $Plan) { Set-Content -LiteralPath $lockPath -Value $PID }
if (-not $Plan) { New-Item -ItemType Directory -Force -Path $OutDir, (Join-Path $OutDir "commands") | Out-Null }
$logPath = if ($Plan) { $null } else { Join-Path $OutDir "window.log" }
$statusPath = Join-Path $OutDir "status.txt"
$stopPath = Join-Path $OutDir "STOP"
$start = Get-Date
$windowEnd = $start.AddHours($Hours)
$harnessEnd = $windowEnd.AddMinutes(-$ReportMinutes)

function Write-Log([string]$Message) {
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    if ($logPath) { try { Add-Content -LiteralPath $logPath -Value $line } catch { } }
}

# --- state for the report ---------------------------------------------------------------------------
$script:phases = [ordered]@{}        # id -> @{ Status; Started; Ended; Notes = @(); Detail = "" }
function Set-Phase([string]$Id, [string]$Status, [string]$Note = "") {
    if (-not $script:phases.Contains($Id)) { $script:phases[$Id] = @{ Status = "pending"; Started = $null; Ended = $null; Notes = @(); Detail = "" } }
    $p = $script:phases[$Id]
    if ($Status -eq "running" -and -not $p.Started) { $p.Started = Get-Date }
    if ($Status -in "ok", "failed", "skipped", "nogo", "cut", "aborted") { $p.Ended = Get-Date }
    $p.Status = $Status
    if ($Note) { $p.Notes += $Note; Write-Log "[$Id] $Status - $Note" } else { Write-Log "[$Id] $Status" }
}
function Add-Detail([string]$Id, [string]$Text) { $script:phases[$Id].Detail += $Text.TrimEnd() + "`n`n" }
$script:serverEvents = @()           # @{ At; Up }
$script:serverUp = $null
$script:attention = @()              # lines for "Needs your eyes"
function Add-Attention([string]$Text) { $script:attention += $Text; Write-Log "ATTENTION: $Text" }
$script:gateResults = @()
$script:go = @{ retries = $true; batch = $true; window = $true }
$script:exitCode = 0
$script:m4Tasks = @(); $script:baselineTasks = @()
$script:child = $null

function Test-Server {
    $up = [bool](Test-EngineAlive -Root $serverRoot -TimeoutSec 10)
    if ($script:serverUp -ne $up) {
        $script:serverEvents += @{ At = Get-Date; Up = $up }
        if ($null -ne $script:serverUp) { Write-Log ("server {0}" -f $(if ($up) { "is back" } else { "stopped answering /health" })) }
        $script:serverUp = $up
    }
    return $up
}
function Wait-Server([double]$Minutes) {
    $until = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        if (Test-Server) { return $true }
        if ((Get-Date) -ge $until -or (Test-Path -LiteralPath $stopPath)) { return $false }
        Start-Sleep -Seconds ([math]::Min($PollSec, 30))
    }
}
function Write-Status([string]$Phase, [string]$Extra = "") {
    $up = if ($null -eq $script:serverUp) { "?" } elseif ($script:serverUp) { "up" } else { "DOWN" }
    $left = [math]::Max(0, ($windowEnd - (Get-Date)).TotalMinutes)
    $line = "{0}  phase {1}  server {2}  {3:N0} min left of {4:N0}  {5}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Phase, $up, $left, ($Hours * 60), $Extra
    try { Set-Content -LiteralPath $statusPath -Value $line } catch { }
}

# One child process (a generated phase script) with the server watch, the deadline and the STOP file around it.
# Returns @{ Exit; Reason } where Reason is "" (it ended by itself), "time", "stop", or "server".
function Invoke-PhaseProcess {
    param([string]$Id, [string]$ScriptText, [datetime]$Limit)
    $scriptPath = Join-Path $OutDir "commands\$Id.ps1"
    Set-Content -LiteralPath $scriptPath -Value $ScriptText
    $out = Join-Path $OutDir "$Id.log"; $err = Join-Path $OutDir "$Id.err.log"
    Write-Log "[$Id] starting: $scriptPath (limit $($Limit.ToString('HH:mm:ss')))"
    $p = Start-Process -FilePath $pwshPath -ArgumentList @("-NoProfile", "-File", ('"{0}"' -f $scriptPath)) -WorkingDirectory $repoRoot `
        -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    $null = $p.Handle
    $script:child = $p       # the main block's finally ends it if this function is interrupted (Ctrl-C, a stopped task)
    $reason = ""; $downSince = $null; $nextServer = Get-Date
    while (-not $p.WaitForExit([int]($PollSec * 1000))) {
        $now = Get-Date
        if ($now -ge $nextServer) {
            $nextServer = $now.AddSeconds($ServerPollSec)
            if (Test-Server) { $downSince = $null } else {
                if (-not $downSince) { $downSince = $now }
                if (($now - $downSince).TotalMinutes -ge $ServerDownMinutes) { $reason = "server" }
            }
        }
        Write-Status $Id ("(running {0:N0} min)" -f ($now - $script:phases[$Id].Started).TotalMinutes)
        if (-not $reason -and (Test-Path -LiteralPath $stopPath)) { $reason = "stop" }
        if (-not $reason -and $now -ge $Limit) { $reason = "time" }
        if ($reason) {
            Write-Log "[$Id] ending the phase: $reason"
            if ($IsWindows) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            $null = $p.WaitForExit(30000)
            break
        }
    }
    try { $p.WaitForExit() } catch { }
    $script:child = $null
    $code = try { $p.ExitCode } catch { $null }
    @{ Exit = $code; Reason = $reason }
}

function Get-TsvRows([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Import-Csv -Delimiter "`t" -LiteralPath $Path)
}
function Get-GradedRowCount([string]$Dir) {
    (Get-TsvRows (Join-Path $Dir "tasks-summary.tsv")).Count + (Get-TsvRows (Join-Path $Dir "real-tasks-summary.tsv")).Count
}
function Get-LogTail([string]$Path, [int]$Lines = 12) {
    if (Test-Path -LiteralPath $Path) { (Get-Content -LiteralPath $Path -Tail $Lines | ForEach-Object { "    $_" }) -join "`n" } else { "    (no log)" }
}

# Run one phase process and return what happened, with the server-recovery rule applied.
function Invoke-Phase {
    param([string]$Id, [string]$ScriptText, [datetime]$Limit)
    $minutesLeft = ($Limit - (Get-Date)).TotalMinutes
    if ($minutesLeft -lt $MinPhaseMinutes) {
        Set-Phase $Id "skipped" ("{0:N0} min left, less than the {1} a phase needs" -f [math]::Max(0, $minutesLeft), $MinPhaseMinutes)
        return $null
    }
    Set-Phase $Id "running"
    $res = Invoke-PhaseProcess -Id $Id -ScriptText $ScriptText -Limit $Limit
    if ($res.Reason -eq "server") {
        Add-Attention "[$Id] ended because the server stayed down for $ServerDownMinutes min"
        if (-not (Wait-Server $RecoverMinutes)) {
            $script:go.window = $false
            Add-Attention "the server did not come back within $RecoverMinutes min; the window stops here"
        }
    }
    if ($res.Reason -eq "stop") { $script:go.window = $false; Add-Attention "a STOP file ended the window" }
    return $res
}

# --- the gate -----------------------------------------------------------------------------------------
function Add-Gate([string]$CheckName, [string]$Status, [string]$Detail) {
    $script:gateResults += [pscustomobject]@{ Check = $CheckName; Status = $Status; Detail = $Detail }
    Write-Log ("gate {0,-4} {1}: {2}" -f $Status, $CheckName, $Detail)
}
function Invoke-Gate {
    Set-Phase "gate" "running"
    $skip = Split-List $SkipChecks
    if ($PSVersionTable.PSVersion.Major -ge 7) { Add-Gate "pwsh" "PASS" "PowerShell $($PSVersionTable.PSVersion)" } else { Add-Gate "pwsh" "FAIL" "PowerShell 7 is the only supported version (this is $($PSVersionTable.PSVersion))" }
    foreach ($t in $RequiredTools) {
        if (Get-Command $t -ErrorAction SilentlyContinue) { Add-Gate "tool $t" "PASS" "found" } else { Add-Gate "tool $t" "FAIL" "not on PATH" }
    }
    if (-not $ServerUrl) {
        Add-Gate "server url" "FAIL" "no -ServerUrl, no LLAMACPP_SERVER_BASE_URL, and no SERVER_IP in $(Join-Path $repoRoot '.env')"
    } else {
        $env:LLAMACPP_SERVER_BASE_URL = $ServerUrl
        if (Wait-Server $WaitServerMinutes) {
            Add-Gate "server /health" "PASS" "$serverRoot answers"
            $served = Get-EngineServedModels -Root $serverRoot
            if ($served -and ($served -contains $seatTag)) { Add-Gate "seat served" "PASS" "$seatTag is in the router's list" }
            else { Add-Gate "seat served" "FAIL" "$seatTag is not served by $serverRoot (served: $(if ($served) { $served -join ', ' } else { 'nothing' }))" }
            $build = Get-EngineVersion -Root $serverRoot
            if ($build) { Add-Gate "llama.cpp build" "PASS" $build }
        } else {
            Add-Gate "server /health" "FAIL" "$serverRoot did not answer within $WaitServerMinutes min (is the server's half open? bash server/scripts/llamacpp-window.sh status)"
        }
    }
    if ("opencode" -notin $skip) {
        $listed = $null
        try { $listed = @(& $OpencodeCmd models ($Model -split "/", 2)[0] 2>&1 | ForEach-Object { "$_" }) } catch { }
        if ($listed -and ($listed | Where-Object { $_ -match [regex]::Escape($seatTag) })) { Add-Gate "opencode seat" "PASS" "opencode lists $Model" }
        else { Add-Gate "opencode seat" "FAIL" "$OpencodeCmd models does not list $Model (stage the config: desktop\scripts\sync-opencode.ps1)" }
    }
    if ("smoke" -in $Run -or "m4" -in $Run) {
        if (Test-Path -LiteralPath $privateManifest) {
            try {
                $a = Resolve-WindowTasks -Manifest $privateManifest -Names $M4Tasks -Last $Last
                $b = Resolve-WindowTasks -Manifest $privateManifest -Names $SmokeTasks
                $script:m4Tasks = $a.Ids; $script:smokeTasks = $b.Ids
                if ($b.Missing.Count) { Add-Gate "smoke tasks" "FAIL" "not in the private manifest: $($b.Missing -join ', ')" } else { Add-Gate "smoke tasks" "PASS" ($b.Ids -join ", ") }
                if ($a.Ids.Count -eq 0) { Add-Gate "m4 tasks" "FAIL" "no live task in $privateManifest" }
                elseif ($a.Missing.Count) { Add-Gate "m4 tasks" "FAIL" "not in the private manifest: $($a.Missing -join ', ')" }
                else { Add-Gate "m4 tasks" "PASS" ("{0} live task(s), last: {1}" -f $a.Ids.Count, (($a.Ids | Select-Object -Last ((Split-List $Last).Count)) -join ", ")) }
            } catch { Add-Gate "private manifest" "FAIL" "cannot read $privateManifest ($($_.Exception.Message))" }
        } else {
            Add-Gate "private manifest" "FAIL" "$privateManifest does not exist (-PrivateRoot)"
        }
    }
    if ("smoke" -in $Run -or "baseline" -in $Run) {
        $c = Resolve-WindowTasks -Manifest $publicManifest -Match $BaselineMatch
        $s = Resolve-WindowTasks -Manifest $publicManifest -Names $SmokeBatchTasks
        $script:baselineTasks = $c.Ids; $script:smokeBatchTasks = $s.Ids
        if ($s.Missing.Count) { Add-Gate "batch smoke tasks" "FAIL" "not in the public manifest: $($s.Missing -join ', ')" } else { Add-Gate "batch smoke tasks" "PASS" ($s.Ids -join ", ") }
        if ($c.Ids.Count -eq 0) { Add-Gate "baseline tasks" "FAIL" "-BaselineMatch selects no live task" }
        elseif ($c.Ids.Count -ne 16) { Add-Gate "baseline tasks" "WARN" "$($c.Ids.Count) live task(s) selected; the plan was written for 16" }
        else { Add-Gate "baseline tasks" "PASS" "16 live mined tasks" }
    }
    if ("disk" -notin $skip) {
        try {
            $free = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($OutDir))).AvailableFreeSpace / 1GB
            $f = "{0:N0} GB free" -f $free
            if ($free -lt 5) { Add-Gate "disk" "FAIL" "$f on the results drive" } elseif ($free -lt 20) { Add-Gate "disk" "WARN" "$f on the results drive" } else { Add-Gate "disk" "PASS" $f }
        } catch { Add-Gate "disk" "WARN" "could not read the free space ($($_.Exception.Message))" }
    }
    if ("git" -notin $skip -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $dirty = @(& git -C $repoRoot status --porcelain 2>$null)
        if ($dirty.Count) { Add-Gate "checkout" "WARN" "$($dirty.Count) uncommitted path(s) in $repoRoot; a result may not be reproducible from a commit" }
        else { Add-Gate "checkout" "PASS" "clean at $((& git -C $repoRoot rev-parse --short HEAD 2>$null))" }
    }
    $bad = @($script:gateResults | Where-Object Status -eq "FAIL")
    if ($bad.Count) {
        $script:go.window = $false
        Set-Phase "gate" "nogo" "$($bad.Count) check(s) failed: $(($bad | ForEach-Object Check) -join ', ')"
        Add-Attention "NO-GO at the gate; nothing ran. Failed: $(($bad | ForEach-Object { '{0} ({1})' -f $_.Check, $_.Detail }) -join '; ')"
        $script:exitCode = 2
    } else {
        Set-Phase "gate" "ok" ("{0} check(s), {1} warning(s)" -f $script:gateResults.Count, @($script:gateResults | Where-Object Status -eq "WARN").Count)
    }
    foreach ($w in @($script:gateResults | Where-Object Status -eq "WARN")) { Add-Attention "gate warning - $($w.Check): $($w.Detail)" }
}

# --- the phases ---------------------------------------------------------------------------------------
function Get-HarnessArgs { @{ NudgeOnStop = (-not $NoNudge); StopClassifier = $StopClassifier; RunTimeout = $RunTimeout; ShownPrompt = 2 } }

function Invoke-Smoke {
    $begin = Get-Date
    $limit = (@($begin.AddMinutes($SmokeMinutes), $harnessEnd) | Sort-Object)[0]
    if (-not $script:go.window) { return }
    # retries
    if (Test-Path -LiteralPath $privateManifest) {
        $dir = Join-Path $OutDir "smoke-retries"
        $res = Invoke-Phase -Id "smoke-retries" -ScriptText (New-RetriesScript -Script $ScriptRetries -Tasks $script:smokeTasks -Model $Model -Attempts 2 -Manifest $privateManifest -ResultsDir $dir -HarnessArgs (Get-HarnessArgs)) -Limit $limit
        if ($res) {
            $rows = Get-TsvRows (Join-Path $dir "retry-summary.tsv")
            $accepted = @($rows | Where-Object { $_.accepted -eq "True" }).Count
            $infra = @($rows | Where-Object { $_.reasons -match "infrastructure" }).Count
            $ok = ($rows.Count -gt 0) -and ($accepted -ge 1 -or $infra -eq 0) -and -not $res.Reason
            $detail = "{0} task(s) run, {1} accepted, {2} with an infrastructure attempt; exit {3}{4}" -f $rows.Count, $accepted, $infra, $res.Exit, $(if ($res.Reason) { "; ended: $($res.Reason)" } else { "" })
            Add-Detail "smoke-retries" ($detail + "`n" + (($rows | ForEach-Object { "    {0}: {1} attempt(s) [{2}]" -f $_.task, $_.attempts, $_.reasons }) -join "`n"))
            if ($ok) { Set-Phase "smoke-retries" "ok" $detail }
            else {
                $script:go.retries = $false
                Set-Phase "smoke-retries" "nogo" $detail
                Add-Attention "retries smoke was NO-GO, so milestone 4 was skipped: $detail"
                Add-Detail "smoke-retries" ("last lines of the log:`n" + (Get-LogTail (Join-Path $OutDir "smoke-retries.log")) + "`n" + (Get-LogTail (Join-Path $OutDir "smoke-retries.err.log") 6))
            }
        } else { $script:go.retries = $false }
    } else {
        Set-Phase "smoke-retries" "skipped" "no private manifest"; $script:go.retries = $false
    }
    if (-not $script:go.window) { return }
    # batch
    $dir = Join-Path $OutDir "smoke-batch"
    $res = Invoke-Phase -Id "smoke-batch" -ScriptText (New-BatchScript -Script $ScriptBatch -Tasks $script:smokeBatchTasks -Model $Model -Reps 1 -RunTimeout $RunTimeout -ResultsDir $dir) -Limit $limit
    if ($res) {
        $graded = Get-GradedRowCount $dir
        $ok = ($res.Exit -eq 0) -and ($graded -ge 1) -and -not $res.Reason
        $detail = "exit {0}, {1} graded row(s){2}" -f $res.Exit, $graded, $(if ($res.Reason) { "; ended: $($res.Reason)" } else { "" })
        Add-Detail "smoke-batch" $detail
        if ($ok) { Set-Phase "smoke-batch" "ok" $detail }
        else {
            $script:go.batch = $false
            Set-Phase "smoke-batch" "nogo" $detail
            Add-Attention "batch smoke was NO-GO, so the baseline was skipped: $detail"
            Add-Detail "smoke-batch" ("last lines of the log:`n" + (Get-LogTail (Join-Path $OutDir "smoke-batch.log")) + "`n" + (Get-LogTail (Join-Path $OutDir "smoke-batch.err.log") 6))
        }
    } else { $script:go.batch = $false }
}

function Invoke-M4 {
    if (-not $script:go.window) { Set-Phase "m4" "skipped" "the window was stopped"; return }
    if (-not $script:go.retries) { Set-Phase "m4" "skipped" "the retries smoke was not GO"; return }
    $dir = Join-Path $OutDir "m4"
    $limit = (@((Get-Date).AddMinutes($M4Minutes), $harnessEnd) | Sort-Object)[0]
    $res = Invoke-Phase -Id "m4" -ScriptText (New-RetriesScript -Script $ScriptRetries -Tasks $script:m4Tasks -Model $Model -Attempts $MaxAttempts -Manifest $privateManifest -ResultsDir $dir -HarnessArgs (Get-HarnessArgs)) -Limit $limit
    if (-not $res) { return }
    $rows = Get-TsvRows (Join-Path $dir "retry-summary.tsv")
    $done = @($rows | ForEach-Object task)
    $notReached = @($script:m4Tasks | Where-Object { $_ -notin $done })
    $accepted = @($rows | Where-Object { $_.accepted -eq "True" }).Count
    $attempts = ($rows | ForEach-Object { [int]$_.attempts } | Measure-Object -Sum).Sum
    $capHits = @($rows | Where-Object { $_.accepted -ne "True" -and [int]$_.attempts -ge $MaxAttempts })
    $summaryLines = @(if (Test-Path -LiteralPath (Join-Path $OutDir "m4.log")) { Get-Content -LiteralPath (Join-Path $OutDir "m4.log") | Where-Object { $_ -match '^(retries:|falsifier:)' } })
    $detail = "{0} of {1} task(s) reached, {2} accepted, {3} attempt(s); exit {4}{5}" -f $rows.Count, $script:m4Tasks.Count, $accepted, $attempts, $res.Exit, $(if ($res.Reason) { "; ended: $($res.Reason)" } else { "" })
    $table = $rows | ForEach-Object { "    {0,-8} {1} attempt(s)  {2}  [{3}]" -f $_.task, $_.attempts, $(if ($_.accepted -eq "True") { "ACCEPTED" } else { "not accepted" }), $_.reasons }
    Add-Detail "m4" ($detail + "`n" + ($table -join "`n"))
    if ($summaryLines) { Add-Detail "m4" ("the loop's own summary:`n" + (($summaryLines | ForEach-Object { "    $_" }) -join "`n")) }
    $tripped = @($summaryLines | Where-Object { $_ -match '^falsifier: FALSIFIED' })
    if ($tripped.Count) { Add-Attention "m4: the loop's falsifier tripped ($($tripped[0] -replace '^falsifier: FALSIFIED - ', '')). real-02 and wp-5b alone are 2 of 15 tasks at the cap (13%), so read which tasks hit it before reading the verdict." }
    else { Add-Detail "m4" ("no summary line from the loop (it was cut or died). Partial: mean {0:N2} attempt(s) per reached task, cap reached on {1}: {2}." -f $(if ($rows.Count) { $attempts / $rows.Count } else { 0 }), $capHits.Count, (($capHits | ForEach-Object task) -join ", ")) }
    if ($notReached.Count) { Add-Detail "m4" "not reached: $($notReached -join ', ')"; Add-Attention "m4 did not reach: $($notReached -join ', ')" }
    $failed = ($res.Reason -in "time", "stop", "server") -or ($res.Exit -ne 0) -or ($rows.Count -eq 0)
    Set-Phase "m4" $(if ($res.Reason -eq "time") { "cut" } elseif ($failed) { "failed" } else { "ok" }) $detail
}

function Invoke-Baseline {
    if (-not $script:go.window) { Set-Phase "baseline" "skipped" "the window was stopped"; return }
    if (-not $script:go.batch) { Set-Phase "baseline" "skipped" "the batch smoke was not GO"; return }
    $dir = Join-Path $OutDir "baseline"
    $res = Invoke-Phase -Id "baseline" -ScriptText (New-BatchScript -Script $ScriptBatch -Tasks $script:baselineTasks -Model $Model -Reps $BaselineReps -RunTimeout $RunTimeout -ResultsDir $dir) -Limit $harnessEnd
    if (-not $res) { return }
    $graded = Get-GradedRowCount $dir
    $detail = "exit {0}, {1} graded row(s) of {2} planned ({3} task(s) x {4} rep(s)){5}" -f $res.Exit, $graded, ($script:baselineTasks.Count * $BaselineReps), $script:baselineTasks.Count, $BaselineReps, $(if ($res.Reason) { "; ended: $($res.Reason)" } else { "" })
    Add-Detail "baseline" $detail
    $failed = ($res.Reason -in "stop", "server") -or ($res.Exit -ne 0 -and -not $res.Reason) -or ($graded -eq 0)
    Set-Phase "baseline" $(if ($res.Reason -eq "time") { "cut" } elseif ($failed) { "failed" } else { "ok" }) $detail
}

# --- the report -----------------------------------------------------------------------------------------
function Write-Report {
    try {
        $end = Get-Date
        $b = New-Object System.Text.StringBuilder
        [void]$b.AppendLine("# Window $Name")
        [void]$b.AppendLine("")
        [void]$b.AppendLine(("Started {0}, ended {1} ({2:N1} of {3:N1} h). Host {4}, model {5}, server {6}." -f $start.ToString("yyyy-MM-dd HH:mm"), $end.ToString("yyyy-MM-dd HH:mm"), ($end - $start).TotalHours, $Hours, [Environment]::MachineName, $Model, $(if ($serverRoot) { $serverRoot } else { "(none)" })))
        $commit = if (Get-Command git -ErrorAction SilentlyContinue) { (& git -C $repoRoot rev-parse --short HEAD 2>$null) } else { "" }
        $oc = try { (& $OpencodeCmd --version 2>$null | Select-Object -First 1) } catch { "" }
        $build = if ($serverRoot) { try { Get-EngineVersion -Root $serverRoot } catch { "" } } else { "" }
        [void]$b.AppendLine(("Repo commit {0}, opencode {1}, llama.cpp build {2}." -f $commit, $oc, $build))
        [void]$b.AppendLine("")
        [void]$b.AppendLine("## Phases")
        [void]$b.AppendLine("")
        [void]$b.AppendLine("| phase | verdict | minutes | note |")
        [void]$b.AppendLine("|---|---|---|---|")
        foreach ($id in $script:phases.Keys) {
            $p = $script:phases[$id]
            $mins = if ($p.Started -and $p.Ended) { [math]::Round(($p.Ended - $p.Started).TotalMinutes, 1) } else { "" }
            [void]$b.AppendLine(("| {0} | {1} | {2} | {3} |" -f $id, $p.Status, $mins, (($p.Notes | Select-Object -Last 1) -replace '\|', '/')))
        }
        foreach ($id in "smoke", "m4", "baseline") { if ($id -notin $Run) { [void]$b.AppendLine("| $id | not selected | | -Run did not include it |") } }
        [void]$b.AppendLine("")
        [void]$b.AppendLine("## Needs your eyes")
        [void]$b.AppendLine("")
        if ($script:attention.Count) { foreach ($a in $script:attention) { [void]$b.AppendLine("- $a") } } else { [void]$b.AppendLine("- Nothing flagged. Read the phase details below anyway.") }
        [void]$b.AppendLine("")
        [void]$b.AppendLine("## Server")
        [void]$b.AppendLine("")
        if ($script:serverEvents.Count -eq 0) { [void]$b.AppendLine("Never polled.") }
        else {
            $downs = @(); $cursor = $null
            foreach ($e in $script:serverEvents) { if (-not $e.Up) { $cursor = $e.At } elseif ($cursor) { $downs += ("{0} to {1} ({2:N0} min)" -f $cursor.ToString("HH:mm"), $e.At.ToString("HH:mm"), ($e.At - $cursor).TotalMinutes); $cursor = $null } }
            if ($cursor) { $downs += ("{0} to the end" -f $cursor.ToString("HH:mm")) }
            if ($downs.Count) { [void]$b.AppendLine("Down (as seen by this script's polls): " + ($downs -join "; ") + ". The server's own log: ~/llamacpp-window/window.log.") } else { [void]$b.AppendLine("Answered /health at every poll.") }
        }
        [void]$b.AppendLine("")
        [void]$b.AppendLine("## Gate")
        [void]$b.AppendLine("")
        foreach ($g in $script:gateResults) { [void]$b.AppendLine(("- {0} {1}: {2}" -f $g.Status, $g.Check, $g.Detail)) }
        foreach ($id in $script:phases.Keys) {
            $p = $script:phases[$id]
            if ($p.Detail) { [void]$b.AppendLine(""); [void]$b.AppendLine("## $id"); [void]$b.AppendLine(""); [void]$b.AppendLine($p.Detail.TrimEnd()) }
        }
        # The baseline and m4 numbers, by the repo's own summariser.
        foreach ($id in "m4", "baseline") {
            $dir = Join-Path $OutDir $id
            if ((Test-Path -LiteralPath $ScriptSummarize) -and (Test-Path -LiteralPath $dir) -and (Get-GradedRowCount $dir) -gt 0) {
                [void]$b.AppendLine(""); [void]$b.AppendLine("## $id by summarize-rounds.ps1"); [void]$b.AppendLine("")
                $txt = try { (& $ScriptSummarize -ResultsDir $dir *>&1 | Out-String -Width 200) } catch { "(summarize-rounds.ps1 failed: $($_.Exception.Message))" }
                [void]$b.AppendLine('```'); [void]$b.AppendLine($txt.TrimEnd()); [void]$b.AppendLine('```')
            }
        }
        [void]$b.AppendLine("")
        [void]$b.AppendLine("## In the morning")
        [void]$b.AppendLine("")
        [void]$b.AppendLine('```')
        [void]$b.AppendLine("# the server: is it still holding the GPU?  close it before using Ollama")
        [void]$b.AppendLine("bash server/scripts/llamacpp-window.sh status")
        [void]$b.AppendLine("bash server/scripts/llamacpp-window.sh down")
        [void]$b.AppendLine("# bring this folder to the desktop")
        [void]$b.AppendLine("scp -r node3:'$($OutDir -replace '\\', '/')' .")
        [void]$b.AppendLine('```')
        [void]$b.AppendLine("")
        [void]$b.AppendLine("Every row of this window is its own era (llama.cpp, sealed checkouts, node3's shell); do not pool it with older rounds.")
        Set-Content -LiteralPath (Join-Path $OutDir "REPORT.md") -Value $b.ToString()
        Write-Log "report written: $(Join-Path $OutDir 'REPORT.md')"
    } catch { Write-Log "could not write the report: $($_.Exception.Message)" }
}

# --- main -----------------------------------------------------------------------------------------------
$env:OPENCODE_DISABLE_AUTOUPDATE = "1"
Write-Log ("window {0}: {1:N1} h, model {2}, run {3}, output {4}" -f $Name, $Hours, $Model, ($Run -join ","), $OutDir)

if ($Plan) {
    Invoke-Gate
    Write-Host ""
    foreach ($id in "smoke", "m4", "baseline") {
        if ($id -notin $Run) { continue }
        switch ($id) {
            "smoke" {
                if ($script:smokeTasks) { Write-Host "-- smoke-retries`n$(New-RetriesScript -Script $ScriptRetries -Tasks $script:smokeTasks -Model $Model -Attempts 2 -Manifest $privateManifest -ResultsDir (Join-Path $OutDir 'smoke-retries') -HarnessArgs (Get-HarnessArgs))`n" }
                if ($script:smokeBatchTasks) { Write-Host "-- smoke-batch`n$(New-BatchScript -Script $ScriptBatch -Tasks $script:smokeBatchTasks -Model $Model -Reps 1 -RunTimeout $RunTimeout -ResultsDir (Join-Path $OutDir 'smoke-batch'))`n" }
            }
            "m4" { if ($script:m4Tasks) { Write-Host "-- m4 ($($script:m4Tasks.Count) task(s), up to $M4Minutes min)`n$(New-RetriesScript -Script $ScriptRetries -Tasks $script:m4Tasks -Model $Model -Attempts $MaxAttempts -Manifest $privateManifest -ResultsDir (Join-Path $OutDir 'm4') -HarnessArgs (Get-HarnessArgs))`n" } }
            "baseline" { if ($script:baselineTasks) { Write-Host "-- baseline ($($script:baselineTasks.Count) task(s) x $BaselineReps rep(s), the rest of the window)`n$(New-BatchScript -Script $ScriptBatch -Tasks $script:baselineTasks -Model $Model -Reps $BaselineReps -RunTimeout $RunTimeout -ResultsDir (Join-Path $OutDir 'baseline'))`n" } }
        }
    }
    Write-Host "-Plan: nothing was run."
    exit $script:exitCode
}

try {
    Invoke-Gate
    if ($script:go.window) {
        if ("smoke" -in $Run) { Invoke-Smoke }
        if ("m4" -in $Run) { Invoke-M4 }
        if ("baseline" -in $Run) { Invoke-Baseline }
    }
} catch {
    Add-Attention "the runner itself threw: $($_.Exception.Message)"
    Write-Log ($_ | Out-String)
    $script:exitCode = 1
} finally {
    if ($script:child -and -not $script:child.HasExited) {
        if ($IsWindows) { & taskkill.exe /PID $script:child.Id /T /F 2>&1 | Out-Null } else { Stop-Process -Id $script:child.Id -Force -ErrorAction SilentlyContinue }
    }
    Write-Status "done"
    Write-Report
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
exit $script:exitCode

# protects: server/scripts/llamacpp-window.sh (open, watchdog, deadline and close of an unattended llama.cpp window)
# run-after: server/scripts/llamacpp-window.sh or the llama.cpp compose file it starts
# test-llamacpp-window.ps1 - regression guard for the server's unattended-window script.
#
# Why this exists: the script is the thing that takes the GPU away from Ollama for a night and must give it back by
# the deadline whatever else happens; a bug in it costs the owner their morning, and it is never run on a machine
# that has a docker daemon, a GPU and no one watching, except the real one. So the real script runs here against
# stand-in `docker`, `curl`, `nvidia-smi` and `llamacpp-check.sh` that keep their state in files and record every
# call, and each branch is walked:
#   - up, the happy path: Ollama's resident seat is stopped BEFORE the stack starts, the stack is started once, the
#     seat is asked to load, the deadline is hours ahead, status is ready, down closes it and clears the deadline;
#   - every refusal leaves nothing running: GPU still held (4, the stack never started), compose up failing, a
#     container that never gets healthy (5), a seat that fails to load (6), a failing contract check (7) - each of
#     the last four takes the stack down again;
#   - the watchdog: a deadline in the past closes the window, a STOP file closes it, two failed polls restart the
#     container and load the seat again, the fifth restart within an hour gives up (GAVE-UP, stack down, exit 1);
#   - a second `up` while a watchdog is alive is refused (3), and `down` stops that watchdog.
# The script targets the Ubuntu server, so this guard SKIPs elsewhere (CI runs it in the Linux job). Needs bash and
# python3. Exit 1 on any failure.
#
# Usage:  .\tests\test-llamacpp-window.ps1 [-ScriptPath <a llamacpp-window.sh>]
param([string]$ScriptPath = "")

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$real = if ($ScriptPath) { $ScriptPath } else { Join-Path $repo "server/scripts/llamacpp-window.sh" }

if (-not $IsLinux) { Write-Host "SKIP llamacpp-window.sh is the Ubuntu server's script; CI runs this guard in the Linux job"; exit 0 }
foreach ($tool in "bash", "python3", "timeout") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Write-Host "SKIP needs $tool"; exit 0 }
}
if (-not (Test-Path -LiteralPath $real)) { Write-Host "FAIL: missing $real"; exit 1 }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("llamacpp-window-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$tree = Join-Path $tmp "tree"; $fx = Join-Path $tmp "fx"; $state = Join-Path $fx "state"; $win = Join-Path $tmp "window"
New-Item -ItemType Directory -Force -Path (Join-Path $tree "server/scripts"), (Join-Path $tree "server/docker"), $fx, $state, $win | Out-Null
$script:watchers = @()

function Write-Lf([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"))
    & chmod +x $Path
}

# --- the stand-ins ---------------------------------------------------------------------------
# State files under $state: container (none|running|exited), health (healthy|starting|unhealthy), seat
# (unloaded|loaded|failed), gpu (MiB), ollama_running (present = the Ollama container is up), ollama_models (one
# per line). Flags: FAIL_UP, NEVER_HEALTHY, LOAD_FAILS, CHECK_FAILS, RESTART_FIXES; health_fail_once makes the next
# /health poll fail and the ones after it succeed.
Write-Lf (Join-Path $fx "docker") @'
#!/usr/bin/env bash
S="$FX_STATE"
echo "docker $*" >> "$S/calls.log"
case "$1" in
  ps)
    [ -e "$S/ollama_running" ] && echo ollama-server
    [ "$(cat "$S/container")" = running ] && echo llamacpp-server
    exit 0 ;;
  exec)
    if [ "$3" = ollama ] && [ "$4" = ps ]; then
      echo "NAME ID SIZE PROCESSOR CONTEXT UNTIL"
      while read -r m; do [ -n "$m" ] && echo "$m abc123 20 GB 100% GPU 65536 4 hours from now"; done < "$S/ollama_models"
      exit 0
    fi
    if [ "$3" = ollama ] && [ "$4" = stop ]; then
      grep -vx "$5" "$S/ollama_models" > "$S/om.tmp"; mv "$S/om.tmp" "$S/ollama_models"; echo 300 > "$S/gpu"; exit 0
    fi
    exit 0 ;;
  compose)
    case " $* " in
      *" up "*)
        [ -e "$S/FAIL_UP" ] && exit 1
        echo running > "$S/container"
        if [ -e "$S/NEVER_HEALTHY" ]; then echo starting > "$S/health"; else echo healthy > "$S/health"; fi
        exit 0 ;;
      *" down "*) echo none > "$S/container"; echo none > "$S/health"; echo unloaded > "$S/seat"; exit 0 ;;
    esac
    exit 0 ;;
  inspect)
    [ "$(cat "$S/container")" = none ] && exit 1
    echo "$(cat "$S/container") $(cat "$S/health")"; exit 0 ;;
  logs) echo "stand-in container log line"; exit 0 ;;
  restart)
    if [ -e "$S/RESTART_FIXES" ]; then echo running > "$S/container"; echo healthy > "$S/health"; echo unloaded > "$S/seat"; fi
    exit 0 ;;
esac
exit 0
'@
Write-Lf (Join-Path $fx "curl") @'
#!/usr/bin/env bash
S="$FX_STATE"
echo "curl $*" >> "$S/calls.log"
url=""; method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$(cat "$S/container")" = running ] || exit 7
case "$url" in
  */models/load)
    if [ -e "$S/LOAD_FAILS" ]; then echo failed > "$S/seat"; else echo loaded > "$S/seat"; fi
    echo '{"success":true}'; exit 0 ;;
  */models)
    seat="$(cat "$S/seat")"
    if [ "$seat" = failed ]; then echo '{"data":[{"id":"qwen3.6:35b-a3b-coding","aliases":[],"status":{"value":"unloaded","failed":true}}]}'
    else echo "{\"data\":[{\"id\":\"qwen3.6:35b-a3b-coding\",\"aliases\":[],\"status\":{\"value\":\"$seat\"}}]}"; fi
    exit 0 ;;
  */health)
    [ "$(cat "$S/health")" = unhealthy ] && exit 22
    if [ -e "$S/health_fail_once" ]; then rm -f "$S/health_fail_once"; exit 22; fi
    echo '{"status":"ok"}'; exit 0 ;;
esac
exit 0
'@
Write-Lf (Join-Path $fx "nvidia-smi") "#!/usr/bin/env bash`ncat `"`$FX_STATE/gpu`"`n"
Write-Lf (Join-Path $tree "server/scripts/llamacpp-check.sh") @'
#!/usr/bin/env bash
echo "llamacpp-check $*" >> "$FX_STATE/calls.log"
[ -e "$FX_STATE/CHECK_FAILS" ] && { echo "FAIL stand-in"; exit 1; }
echo "OK stand-in"; exit 0
'@
Copy-Item -LiteralPath $real -Destination (Join-Path $tree "server/scripts/llamacpp-window.sh")
& chmod +x (Join-Path $tree "server/scripts/llamacpp-window.sh")
Set-Content -LiteralPath (Join-Path $tree "server/docker/docker-compose.llamacpp.yml") -Value "name: llamacpp"
$window = Join-Path $tree "server/scripts/llamacpp-window.sh"

$envNames = "FX_STATE", "DOCKER", "CURL", "NVIDIA_SMI", "WINDOW_DIR", "POLL", "HEALTH_WAIT", "LOAD_WAIT", "GPU_WAIT", "WATCH_INTERVAL", "MAX_RESTARTS", "URL"
function Set-Env {
    $env:FX_STATE = $state; $env:DOCKER = Join-Path $fx "docker"; $env:CURL = Join-Path $fx "curl"; $env:NVIDIA_SMI = Join-Path $fx "nvidia-smi"
    $env:WINDOW_DIR = $win; $env:POLL = "0.1"; $env:HEALTH_WAIT = "2"; $env:LOAD_WAIT = "2"; $env:GPU_WAIT = "1"
    $env:WATCH_INTERVAL = "0.3"; $env:MAX_RESTARTS = "4"; $env:URL = "http://stand-in:8090"
}

function Reset-State([hashtable]$Flags = @{}) {
    Get-ChildItem -LiteralPath $state -Force | Remove-Item -Force
    Get-ChildItem -LiteralPath $win -Force | Remove-Item -Force -Recurse
    Set-Content -LiteralPath (Join-Path $state "container") -Value "none"
    Set-Content -LiteralPath (Join-Path $state "health") -Value "none"
    Set-Content -LiteralPath (Join-Path $state "seat") -Value "unloaded"
    Set-Content -LiteralPath (Join-Path $state "gpu") -Value "14000"
    Set-Content -LiteralPath (Join-Path $state "ollama_models") -Value "qwen3.6:35b-a3b-coding"
    New-Item -ItemType File -Path (Join-Path $state "ollama_running") | Out-Null
    New-Item -ItemType File -Path (Join-Path $state "calls.log") | Out-Null
    foreach ($k in $Flags.Keys) { if ($Flags[$k]) { New-Item -ItemType File -Path (Join-Path $state $k) | Out-Null } }
}
function Calls { @(Get-Content -LiteralPath (Join-Path $state "calls.log")) }
function CallIndex([string]$Pattern) { $c = Calls; for ($i = 0; $i -lt $c.Count; $i++) { if ($c[$i] -match $Pattern) { return $i } }; return -1 }
function CallCount([string]$Pattern) { @(Calls | Where-Object { $_ -match $Pattern }).Count }
function Invoke-Window([string[]]$Arguments) {
    Set-Env
    # `timeout` so a loop that should have ended (a watchdog that ignores its deadline) fails the check instead of hanging CI.
    $out = & timeout 60 bash $window @Arguments 2>&1 | Out-String
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
}
function Wait-For([scriptblock]$Condition, [int]$Seconds = 15) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 100 }
    return [bool](& $Condition)
}
function WindowLog { $p = Join-Path $win "window.log"; if (Test-Path $p) { Get-Content -Raw -LiteralPath $p } else { "" } }

try {
    Write-Host "-- up: the happy path"
    Reset-State
    $r = Invoke-Window @("up", "--no-watch")
    Check "exit 0" $r.Exit 0
    $iStop = CallIndex 'ollama stop qwen3\.6'; $iUp = CallIndex 'compose .* up -d'
    Check "Ollama's resident seat was stopped" ($iStop -ge 0) "True"
    Check "...before the stack started" ($iStop -ge 0 -and $iUp -gt $iStop) "True"
    Check "the stack was started exactly once" (CallCount 'compose .* up -d') 1
    Check "the seat was asked to load" (CallCount 'curl .*-X POST .*/models/load') 1
    Check "the contract check ran against the server's URL" (CallCount 'llamacpp-check --url http://stand-in:8090') 1
    $deadline = [long](Get-Content -LiteralPath (Join-Path $win "deadline"))
    $ahead = $deadline - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Check "the deadline is 9 h ahead by default" ($ahead -gt (9 * 3600 - 120) -and $ahead -le (9 * 3600)) "True"
    $s = Invoke-Window @("status")
    Check "status exits 0 when open, healthy and loaded" $s.Exit 0
    Check "status says how long is left" ($s.Out -match 'open, 8 h|open, 9 h') "True"
    $d = Invoke-Window @("down")
    Check "down exits 0" $d.Exit 0
    Check "down took the stack down" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "none"
    Check "down cleared the deadline" (Test-Path (Join-Path $win "deadline")) "False"
    Check "status exits 1 when closed" (Invoke-Window @("status")).Exit 1

    Write-Host "-- up adopts a stack that is already up (the primary engine since Phase 3)"
    Reset-State
    Set-Content -LiteralPath (Join-Path $state "container") -Value "running"
    Set-Content -LiteralPath (Join-Path $state "health") -Value "healthy"
    $r = Invoke-Window @("up", "--no-watch")
    Check "adopt: exit 0" $r.Exit 0
    Check "...the stack was not started again" (CallCount 'compose .* up') 0
    Check "...Ollama was left alone" (CallCount 'ollama stop') 0
    Check "...the seat was still loaded and checked" ("{0}|{1}" -f (CallCount 'curl .*-X POST .*/models/load'), (CallCount 'llamacpp-check --url')) "1|1"
    Check "...and the window says it adopted it" ((WindowLog) -match 'adopting the running stack') "True"
    $d = Invoke-Window @("down")
    Check "down after adopting: exit 0" $d.Exit 0
    Check "...the stack is still running" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "running"
    Check "...compose down was never called" (CallCount 'compose .* down') 0
    Check "...and the marker is gone, so the next window decides afresh" (Test-Path (Join-Path $win "adopted")) "False"

    Reset-State
    Set-Content -LiteralPath (Join-Path $state "container") -Value "running"
    Set-Content -LiteralPath (Join-Path $state "health") -Value "healthy"
    $r = Invoke-Window @("up", "--hours", "0.0005")
    $closed = Wait-For { (WindowLog) -match 'deadline reached' }
    Check "adopt + watchdog: the deadline fires" $closed "True"
    $null = Wait-For { -not (Test-Path (Join-Path $win "watch.pid")) }
    Check "...and the adopted stack is left running" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "running"
    Check "...with no compose down" (CallCount 'compose .* down') 0
    Check "...and the log says why" ((WindowLog) -match 'leaving the stack up') "True"

    Write-Host "-- up --hours"
    Reset-State
    $null = Invoke-Window @("up", "--hours", "0.5", "--no-watch")
    $ahead = [long](Get-Content -LiteralPath (Join-Path $win "deadline")) - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Check "--hours 0.5 sets a deadline 30 min ahead" ($ahead -gt 1700 -and $ahead -le 1800) "True"
    $null = Invoke-Window @("down")
    Check "an unknown option is refused (2)" (Invoke-Window @("up", "--bogus")).Exit 2
    Check "no sub-command prints usage and exits 2" (Invoke-Window @()).Exit 2

    Write-Host "-- up refusals leave nothing running"
    Reset-State
    Set-Content -LiteralPath (Join-Path $state "ollama_models") -Value ""
    Set-Content -LiteralPath (Join-Path $state "gpu") -Value "9000"
    $r = Invoke-Window @("up", "--no-watch")
    Check "GPU still held by something else: exit 4" $r.Exit 4
    Check "...and the stack was never started" (CallCount 'compose .* up') 0
    Check "...the message says how much is held" ($r.Out -match '9000 MiB') "True"

    Reset-State @{ FAIL_UP = $true }
    $r = Invoke-Window @("up", "--no-watch")
    Check "compose up failing: exit 5" $r.Exit 5
    Check "...and the stack was taken down" (CallCount 'compose .* down') 1

    Reset-State @{ NEVER_HEALTHY = $true }
    $r = Invoke-Window @("up", "--no-watch")
    Check "a container that never gets healthy: exit 5" $r.Exit 5
    Check "...and the stack was taken down" (CallCount 'compose .* down') 1
    Check "...with its log lines kept for the morning" ((WindowLog) -match 'stand-in container log line') "True"

    Reset-State @{ LOAD_FAILS = $true }
    $r = Invoke-Window @("up", "--no-watch")
    Check "a seat that fails to load: exit 6" $r.Exit 6
    Check "...and the stack was taken down" (CallCount 'compose .* down') 1
    Check "...and no deadline was written" (Test-Path (Join-Path $win "deadline")) "False"

    Reset-State @{ CHECK_FAILS = $true }
    $r = Invoke-Window @("up", "--no-watch")
    Check "llamacpp-check reporting a FAIL: exit 7" $r.Exit 7
    Check "...and the stack was taken down" (CallCount 'compose .* down') 1

    Write-Host "-- an interrupted up takes the stack down again"
    Reset-State @{ NEVER_HEALTHY = $true }
    Set-Env; $env:HEALTH_WAIT = "60"
    $proc = Start-Process -FilePath bash -ArgumentList @($window, "up", "--no-watch") -PassThru -RedirectStandardOutput (Join-Path $tmp "int.out") -RedirectStandardError (Join-Path $tmp "int.err")
    $script:watchers += $proc.Id
    Check "up starts the stack and waits for it to be healthy" (Wait-For { (CallCount 'compose .* up -d') -ge 1 } 15) "True"
    & kill -TERM $proc.Id
    Check "a SIGTERM while it waits ends it with exit 130" ($proc.WaitForExit(15000) -and $proc.ExitCode -eq 130) "True"
    Check "...and the stack was taken down" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "none"
    Check "...with the reason in the window log" ((WindowLog) -match 'interrupted while opening the window') "True"

    Write-Host "-- the watchdog"
    # Open a real window (watchdog started by `up`), then walk its branches.
    Reset-State @{ RESTART_FIXES = $true }
    $r = Invoke-Window @("up", "--hours", "1")
    Check "up with the watchdog: exit 0" $r.Exit 0
    $pidFile = Join-Path $win "watch.pid"
    Check "the watchdog wrote its pid" (Wait-For { Test-Path $pidFile }) "True"
    $wpid = [int](Get-Content -LiteralPath $pidFile)
    $script:watchers += $wpid
    Check "...and it is alive" ([bool](Get-Process -Id $wpid -ErrorAction SilentlyContinue)) "True"
    Check "status shows the watchdog" ((Invoke-Window @("status")).Out -match "watchdog:\s+pid $wpid") "True"
    $r2 = Invoke-Window @("up")
    Check "a second up while the watchdog is alive is refused (3)" $r2.Exit 3
    # Break the container: the watchdog must restart it and load the seat again.
    Set-Content -LiteralPath (Join-Path $state "container") -Value "exited"
    Check "two failed polls restart the container" (Wait-For { (CallCount 'docker restart llamacpp-server') -ge 1 } 20) "True"
    Check "...the seat is loaded again afterwards" (Wait-For { (Get-Content -Raw (Join-Path $state "seat")).Trim() -eq "loaded" } 20) "True"
    Check "...and the restart is recorded for the give-up rule" (Wait-For { Test-Path (Join-Path $win "restarts") }) "True"
    Check "...and the window stays open" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "running"
    # (the next block is the transient-failure case; it needs a window that is open and healthy again)
    Check "a window is open and healthy again before the flake test" (Wait-For { (Invoke-Window @("status")).Exit -eq 0 } 20) "True"
    $restartsBefore = CallCount 'docker restart llamacpp-server'
    New-Item -ItemType File -Path (Join-Path $state "health_fail_once") | Out-Null
    Check "the flake was consumed by a poll" (Wait-For { -not (Test-Path (Join-Path $state "health_fail_once")) } 10) "True"
    Start-Sleep -Seconds 2
    Check "one failed poll is not enough to restart" ((CallCount 'docker restart llamacpp-server') - $restartsBefore) 0
    Check "...the watchdog is still alive" ([bool](Get-Process -Id $wpid -ErrorAction SilentlyContinue)) "True"
    $d = Invoke-Window @("down")
    Check "down exits 0" $d.Exit 0
    Check "down stopped the watchdog" (Wait-For { -not (Get-Process -Id $wpid -ErrorAction SilentlyContinue) }) "True"
    Check "...and took the stack down" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "none"

    Write-Host "-- the watchdog closes the window by itself"
    foreach ($case in @(
            @{ Name = "a deadline in the past"; Prep = { Set-Content -LiteralPath (Join-Path $win "deadline") -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 5) }; Needle = "deadline reached" },
            @{ Name = "a STOP file"; Prep = { Set-Content -LiteralPath (Join-Path $win "deadline") -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600); New-Item -ItemType File -Path (Join-Path $win "STOP") | Out-Null }; Needle = "STOP file found" })) {
        Reset-State
        $null = Invoke-Window @("up", "--no-watch")          # opens the stack; the watchdog is run in the foreground below
        & $case.Prep
        $w = Invoke-Window @("watch")
        Check "$($case.Name): the watchdog exits 0" $w.Exit 0
        Check "...says why" ((WindowLog) -match $case.Needle) "True"
        Check "...and took the stack down" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "none"
    }

    Write-Host "-- the watchdog gives up"
    Reset-State
    $null = Invoke-Window @("up", "--no-watch")
    # Four restarts in the last hour already; the container is broken and the restart does not fix it.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Set-Content -LiteralPath (Join-Path $win "restarts") -Value (1..4 | ForEach-Object { $now - 60 * $_ })
    Set-Content -LiteralPath (Join-Path $state "container") -Value "exited"
    $w = Invoke-Window @("watch")
    Check "the fifth restart in an hour is not made: exit 1" $w.Exit 1
    Check "...GAVE-UP is written" (Test-Path (Join-Path $win "GAVE-UP")) "True"
    Check "...no restart was attempted" (CallCount 'docker restart') 0
    Check "...and the stack was taken down" ((Get-Content -Raw (Join-Path $state "container")).Trim()) "none"
    Check "status says it gave up" ((Invoke-Window @("status")).Out -match 'GAVE-UP') "True"
} finally {
    foreach ($p in $script:watchers) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    foreach ($n in $envNames) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

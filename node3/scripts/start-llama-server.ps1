# start-llama-server.ps1 - node3's llama-server ("Replacing Ollama" Phase 5, model-host half; node3/README.md).
#
# Registers (or re-registers) the scheduled task HomeLab-llamacpp, which runs the pinned llama-server build in router
# mode on node3's preset, and starts it. Run on node3, as its user, from this checkout:
#
#   pwsh -File node3\scripts\start-llama-server.ps1            # 127.0.0.1:8090: node3 itself only
#   pwsh -File node3\scripts\start-llama-server.ps1 -Lan       # 0.0.0.0:8090: needs the firewall rule (README) first
#   pwsh -File node3\scripts\start-llama-server.ps1 -Stop      # stop it and remove the task
#
# API key (docs/engine-api-keys.md): when the key file exists, llama-server gets --api-key-file and then answers only
# /health without `Authorization: Bearer <key>`. -Lan refuses to start without the key file (-NoKey overrides, for a
# trusted test only). After the start it checks that /props without the key is refused (401), so a key that did not
# take is caught here, not found later on the LAN. The key file is the one node3's OpenCode reads; never printed.
#
# The task runs llama-server.exe directly. node3's PowerShell 7 is the Store install, whose `pwsh` on PATH is an app
# alias a scheduled task cannot launch (0x80070002, file not found; the same quirk as #162's agentShell), so nothing
# here goes through a shell. Logging is llama-server's own --log-file. It is node3's only model engine (Ollama was
# removed 2026-11-21).
param(
    [string]$Build = "b11562",
    [string]$Root = "C:\HomeLab\llama.cpp",
    [string]$Preset = (Join-Path $PSScriptRoot "..\llamacpp\models.ini"),
    [int]$Port = 8090,
    [switch]$Lan,
    [switch]$Stop,
    [string]$KeyFile = (Join-Path $env:USERPROFILE ".config\opencode\.secrets\llamacpp-api-key"),
    [switch]$NoKey
)
$ErrorActionPreference = "Stop"
$task = "HomeLab-llamacpp"
if ($Stop) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $task; Unregister-ScheduledTask -TaskName $task -Confirm:$false }
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
    "stopped"; exit 0
}
$exe = Join-Path $Root "$Build\llama-server.exe"
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "ERROR: $exe is missing (README: download the pinned zips and check their digests)" -ForegroundColor Red; exit 1 }
$Preset = (Resolve-Path -LiteralPath $Preset).Path
$hostAddr = if ($Lan) { "0.0.0.0" } else { "127.0.0.1" }
$log = Join-Path $Root "llama-server.log"
$argLine = "--host $hostAddr --port $Port --models-preset `"$Preset`" --models-max 1 --log-file `"$log`""
$useKey = (-not $NoKey) -and (Test-Path -LiteralPath $KeyFile -PathType Leaf)
if ($Lan -and -not $useKey -and -not $NoKey) {
    Write-Host "ERROR: -Lan needs an API key file at $KeyFile (docs/engine-api-keys.md); refusing to serve the LAN without one" -ForegroundColor Red
    exit 1
}
if ($useKey) { $argLine += " --api-key-file `"$KeyFile`"" }
. (Join-Path $PSScriptRoot "..\..\tests\engines\llamacpp-auth.ps1")
if ($useKey) { $env:LLAMACPP_API_KEY_FILE = $KeyFile }
$hdr = if ($useKey) { Get-LlamacppHeaders } else { @{} }
$action = New-ScheduledTaskAction -Execute $exe -Argument $argLine -WorkingDirectory $Root
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Register-ScheduledTask -TaskName $task -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
foreach ($i in 1..30) {
    Start-Sleep -Seconds 2
    try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3).status -eq "ok") {
        $bi = (Invoke-RestMethod -Headers $hdr "http://127.0.0.1:$Port/props" -TimeoutSec 10).build_info
        if ($useKey) {
            $code = 0
            try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/props" -TimeoutSec 10 } catch { $code = try { [int]$_.Exception.Response.StatusCode } catch { -1 } }
            if ($code -ne 401) {
                Write-Host "ERROR: llama-server answered /props without the key (status $code, want 401); the key did not take. Stopping it." -ForegroundColor Red
                Stop-ScheduledTask -TaskName $task; Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
                exit 1
            }
        }
        "llama-server $bi on ${hostAddr}:$Port, preset $Preset, API key $(if ($useKey) { 'on (401 without it, checked)' } else { 'off' })"
        exit 0 } } catch { }
}
Write-Host ("ERROR: no /health answer after 60 s (task result 0x{0:X}); see $log" -f (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult) -ForegroundColor Red
exit 1

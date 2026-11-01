# start-llama-server.ps1 - node3's llama-server ("Replacing Ollama" Phase 5, model-host half; node3/README.md).
#
# Registers (or re-registers) the scheduled task HomeLab-llamacpp, which runs the pinned llama-server build in router
# mode on node3's preset, and starts it. Run on node3, as its user, from this checkout:
#
#   pwsh -File node3\scripts\start-llama-server.ps1            # 127.0.0.1:8090: node3 itself only
#   pwsh -File node3\scripts\start-llama-server.ps1 -Lan       # 0.0.0.0:8090: needs the firewall rule (README) first
#   pwsh -File node3\scripts\start-llama-server.ps1 -Stop      # stop it and remove the task
#
# The task runs llama-server.exe directly. node3's PowerShell 7 is the Store install, whose `pwsh` on PATH is an app
# alias a scheduled task cannot launch (0x80070002, file not found; the same quirk as #162's agentShell), so nothing
# here goes through a shell. Logging is llama-server's own --log-file. Ollama keeps running beside it (Phase 6 retires
# it); the two engines must not both hold a seat on the 10 GB card.
param(
    [string]$Build = "b11562",
    [string]$Root = "C:\HomeLab\llama.cpp",
    [string]$Preset = (Join-Path $PSScriptRoot "..\llamacpp\models.ini"),
    [int]$Port = 8090,
    [switch]$Lan,
    [switch]$Stop
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
$action = New-ScheduledTaskAction -Execute $exe -Argument $argLine -WorkingDirectory $Root
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Register-ScheduledTask -TaskName $task -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task
foreach ($i in 1..30) {
    Start-Sleep -Seconds 2
    try { if ((Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3).status -eq "ok") {
        "llama-server $((Invoke-RestMethod "http://127.0.0.1:$Port/props" -TimeoutSec 10).build_info) on ${hostAddr}:$Port, preset $Preset"
        exit 0 } } catch { }
}
Write-Host ("ERROR: no /health answer after 60 s (task result 0x{0:X}); see $log" -f (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult) -ForegroundColor Red
exit 1

# run-guards.ps1 - run every regression guard (tests/test-*.ps1) in its own pwsh, with a
# timeout each, and say which failed.
#
# Why this exists: the guards are Windows-first (stand-in `opencode.cmd` shims, %TEMP%,
# taskkill, Win32_Process), and most changes are now written in Linux sessions that
# cannot run them, so a broken script was often first exercised on the desktop days
# later (CHANGELOG: the python3 Store placeholder, test-task-pins under 5.1's
# ErrorActionPreference). CI (.github/workflows/checks.yml) runs this on a Windows
# runner on every pull request; on the desktop it is the same run in one command.
#
# What it does: finds tests/test-*.ps1, leaves out the scripts in $Excluded (they need
# live hosts and are not guards), runs each remaining one as `pwsh -NoProfile -File` with
# an empty stdin and its output in a log file, ends it with its whole process tree after
# -TimeoutSec, and prints a table (guard, verdict, exit, seconds, PASS/FAIL line counts)
# plus the tail of every failing guard's log. A guard is OK only if it exits 0 in time.
# Exit 1 if any guard was not OK.
#
# Usage:  .\tests\run-guards.ps1 [-Only <names>] [-Exclude <names>] [-TimeoutSec 900] [-LogDir <folder>]
#   Names may be given with or without "test-" and ".ps1" (cap-hit, test-cap-hit, test-cap-hit.ps1).
param(
    [string[]]$Only = @(),
    [string[]]$Exclude = @(),
    [int]$TimeoutSec = 900,
    [string]$LogDir = "",
    [int]$TailLines = 40
)

$ErrorActionPreference = "Stop"

# Not guards: each needs live Ollama hosts, a live model or the owner's live OpenCode
# config, so they stay desktop-side checks and a PR lists them as not run.
$Excluded = [ordered]@{
    "test-profiles"  = "live Ollama hosts and the live OpenCode config"
    "test-tasks"     = "the task harness itself (real opencode runs against real repos)"
    "test-toolcalls" = "the tool-call probe, against a live model"
}

function ConvertTo-GuardName([string]$Name) {
    $n = [IO.Path]::GetFileNameWithoutExtension($Name.Trim())
    if (-not $n.StartsWith("test-")) { $n = "test-$n" }
    $n
}

$all = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "test-*.ps1" -File | Sort-Object Name)
$onlyNames = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ } | ForEach-Object { ConvertTo-GuardName $_ })
$skipNames = @($Exclude | ForEach-Object { $_ -split "," } | Where-Object { $_ } | ForEach-Object { ConvertTo-GuardName $_ })

foreach ($n in $onlyNames) {
    if (-not ($all | Where-Object { $_.BaseName -eq $n })) { Write-Host "ERROR: no guard named $n in $PSScriptRoot" -ForegroundColor Red; exit 2 }
}

$guards = @($all | Where-Object {
    $n = $_.BaseName
    if ($onlyNames.Count) { $onlyNames -contains $n } else { -not $Excluded.Contains($n) -and $skipNames -notcontains $n }
})
if (-not $guards.Count) { Write-Host "ERROR: no guards selected" -ForegroundColor Red; exit 2 }

if (-not $LogDir) { $LogDir = Join-Path ([IO.Path]::GetTempPath()) ("guards-" + [guid]::NewGuid().ToString("N").Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path -LiteralPath $LogDir).Path
$emptyStdin = Join-Path $LogDir ".stdin-empty"
Set-Content -LiteralPath $emptyStdin -Value $null -NoNewline

$pwshPath = (Get-Process -Id $PID).Path
Write-Host "[guards] $($guards.Count) guard(s), timeout $TimeoutSec s each, pwsh $($PSVersionTable.PSVersion), logs in $LogDir"
if (-not $onlyNames.Count) {
    foreach ($k in $Excluded.Keys) { Write-Host "[guards] not run: $k ($($Excluded[$k]))" -ForegroundColor DarkGray }
}

$results = foreach ($g in $guards) {
    $name = $g.BaseName
    $out = Join-Path $LogDir "$name.out.log"
    $err = Join-Path $LogDir "$name.err.log"
    Write-Host "[guards] $name ..." -NoNewline
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $pwshPath -ArgumentList @("-NoProfile", "-File", "`"$($g.FullName)`"") `
        -WorkingDirectory (Split-Path -Parent $PSScriptRoot) -NoNewWindow -PassThru `
        -RedirectStandardInput $emptyStdin -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle   # keeps ExitCode readable after the process ends
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) {
        try { $p.Kill($true) } catch { }   # the whole tree, on every platform (.NET Core 3+)
        $null = $p.WaitForExit(10000)
    }
    $sw.Stop()
    $exit = if ($timedOut) { $null } else { $p.ExitCode }
    $text = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue) + @(Get-Content -LiteralPath $err -ErrorAction SilentlyContinue)
    $verdict = if ($timedOut) { "TIMEOUT" } elseif ($exit -eq 0) { "OK" } else { "FAIL" }
    $color = if ($verdict -eq "OK") { "Green" } else { "Red" }
    Write-Host " $verdict ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)" -ForegroundColor $color
    [pscustomobject]@{
        Guard   = $name
        Verdict = $verdict
        Exit    = $exit
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Pass    = @($text | Where-Object { "$_" -match '^\s*PASS\b' }).Count
        Fail    = @($text | Where-Object { "$_" -match '^\s*FAIL\b' }).Count
        Out     = $out
        Err     = $err
    }
}

Write-Host ""
# -Width: with output redirected (CI, a log file) the host width is 0 and the table prints blank.
($results | Format-Table Guard, Verdict, Exit, Seconds, Pass, Fail -AutoSize | Out-String -Width 200).Trim() | Write-Host

$bad = @($results | Where-Object { $_.Verdict -ne "OK" })
foreach ($r in $bad) {
    Write-Host "---- $($r.Guard): $($r.Verdict), last $TailLines lines ----" -ForegroundColor Red
    @(Get-Content -LiteralPath $r.Out -ErrorAction SilentlyContinue) + @(Get-Content -LiteralPath $r.Err -ErrorAction SilentlyContinue) |
        Select-Object -Last $TailLines | ForEach-Object { Write-Host $_ }
}

if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### Guards: $($results.Count - $bad.Count) of $($results.Count) OK", "", "| guard | verdict | exit | seconds | PASS | FAIL |", "|---|---|---|---|---|---|")
    $md += $results | ForEach-Object { "| ``$($_.Guard)`` | $($_.Verdict) | $($_.Exit) | $($_.Seconds) | $($_.Pass) | $($_.Fail) |" }
    if (-not $onlyNames.Count) { $md += ""; $md += "Not run here (need live hosts): " + (($Excluded.Keys | ForEach-Object { "``$_``" }) -join ", ") }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}

if ($bad.Count) { Write-Host "$($bad.Count) of $($results.Count) guard(s) not OK: $(($bad | ForEach-Object Guard) -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host "all $($results.Count) guard(s) OK" -ForegroundColor Green
exit 0

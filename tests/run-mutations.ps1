# run-mutations.ps1 - prove each guard can fail: break the rule it protects, and expect it to go red.
#
# Why this exists: AGENTS.md says to mutation-check every new check, and nothing enforced it (the 2026-11-09 audit:
# "every recurring incident class came back after its rule was written; only mechanised checks held"). Twice a new
# guard stayed green with its rule removed: once its check matched text that appears either way, once a later step's
# exit 1 hid the missing refusal. So a guard now names, in its header, a one-line break of the code it protects and the
# FAIL line that break must cause. This script makes each break, runs the guard, and puts the file back.
#
# The header lines (in the guard's leading comment block; one group per mutation, any number of groups):
#   # mutation: <repo-relative path of the file to break>
#   # mutation-from: <text that occurs exactly once in that file, on one line>
#   # mutation-to: <what replaces it>
#   # mutation-expect: <regex the guard's output must then match, e.g. "FAIL REFUSED">
# The FAIL line it expects is what shows WHERE the guard caught it, so a later step's failure cannot pass for it.
#
# For each guard with mutations:
#   - the guard runs once unmutated. It must exit 0. With no PASS line at all (it SKIPs everything here, e.g. a
#     Linux-only guard on Windows) its mutations are reported SKIPPED, not run;
#   - each mutation: the file must be unchanged from git (`git status --porcelain`), and its text must occur exactly
#     once. The file is copied aside, the text replaced byte for byte (line endings kept), the guard run, and the
#     original bytes written back; then the sha256 must equal the one taken before. CAUGHT means the guard exited
#     non-zero and its output matched the expect regex. SURVIVED (exit 0) and WRONG-PLACE (red, but not with the
#     expected line) fail this run.
# python3 tests/make-reference.py --check requires at least one mutation in every guard not listed in
# tests/mutation-exempt.txt (the guards that existed on 2026-11-25; that list only shrinks).
# Exit 1 if any mutation was not CAUGHT (SKIPPED excepted), a mutation is stale, or a file did not restore exactly.
#
# Usage:  .\tests\run-mutations.ps1 [-Only <names>] [-TimeoutSec 900] [-LogDir <folder>]
param(
    [string[]]$Only = @(),
    [int]$TimeoutSec = 900,
    [string]$LogDir = "",
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"
$repo = if ($RepoRoot) { (Resolve-Path -LiteralPath $RepoRoot).Path } else { Split-Path -Parent $PSScriptRoot }
$testsDir = Join-Path $repo "tests"
$latin1 = [Text.Encoding]::Latin1   # byte-preserving: one char per byte

function ConvertTo-GuardName([string]$Name) {
    $n = [IO.Path]::GetFileNameWithoutExtension($Name.Trim())
    if (-not $n.StartsWith("test-")) { $n = "test-$n" }
    $n
}

function Get-Mutations([string]$GuardPath) {
    $list = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($raw in [IO.File]::ReadAllLines($GuardPath)) {
        $line = $raw.TrimEnd("`r")
        if ($line -notmatch '^\s*#') { if ($line.Trim()) { break } else { continue } }
        if ($line -match '^\s*#\s*mutation:\s*(.+?)\s*$') {
            $cur = [ordered]@{ Path = $Matches[1]; From = $null; To = $null; Expect = $null }
            $list.Add($cur)
        } elseif ($line -match '^\s*#\s*mutation-(from|to|expect):\s?(.*)$') {
            if (-not $cur) { throw "${GuardPath}: '# mutation-$($Matches[1]):' before any '# mutation:' line" }
            $cur[[cultureinfo]::InvariantCulture.TextInfo.ToTitleCase($Matches[1])] = $Matches[2].Trim()
        }
    }
    $list
}

function Invoke-Guard([string]$GuardPath, [string]$Log) {
    $p = Start-Process -FilePath $script:pwshPath -ArgumentList @("-NoProfile", "-File", "`"$GuardPath`"") `
        -WorkingDirectory $repo -NoNewWindow -PassThru `
        -RedirectStandardInput $script:emptyStdin -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
    $null = $p.Handle
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { try { $p.Kill($true) } catch { }; $null = $p.WaitForExit(10000) }
    $text = (@(Get-Content -LiteralPath $Log -ErrorAction SilentlyContinue) + @(Get-Content -LiteralPath "$Log.err" -ErrorAction SilentlyContinue)) -join "`n"
    [pscustomobject]@{ Exit = $(if ($timedOut) { $null } else { $p.ExitCode }); TimedOut = $timedOut; Text = $text }
}

$all = @(Get-ChildItem -LiteralPath $testsDir -Filter "test-*.ps1" -File | Sort-Object Name)
$onlyNames = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ } | ForEach-Object { ConvertTo-GuardName $_ })
foreach ($n in $onlyNames) {
    if (-not ($all | Where-Object { $_.BaseName -eq $n })) { Write-Host "ERROR: no guard named $n in $testsDir"; exit 2 }
}
$guards = @($all | Where-Object { -not $onlyNames.Count -or $onlyNames -contains $_.BaseName } |
    ForEach-Object { [pscustomobject]@{ File = $_; Mutations = @(Get-Mutations $_.FullName) } } |
    Where-Object { $_.Mutations.Count })
if (-not $guards.Count) { Write-Host "[mutations] no selected guard carries a '# mutation:' header"; exit 0 }

if (-not $LogDir) { $LogDir = Join-Path ([IO.Path]::GetTempPath()) ("mutations-" + [guid]::NewGuid().ToString("N").Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogDir = (Resolve-Path -LiteralPath $LogDir).Path
$script:emptyStdin = Join-Path $LogDir ".stdin-empty"
Set-Content -LiteralPath $script:emptyStdin -Value $null -NoNewline
$script:pwshPath = (Get-Process -Id $PID).Path
$haveGit = [bool](Get-Command git -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path $repo ".git"))
Write-Host "[mutations] $($guards.Count) guard(s), $(($guards | ForEach-Object { $_.Mutations.Count } | Measure-Object -Sum).Sum) mutation(s), logs in $LogDir"

$results = [System.Collections.Generic.List[object]]::new()
foreach ($g in $guards) {
    $name = $g.File.BaseName
    $base = Invoke-Guard $g.File.FullName (Join-Path $LogDir "$name.base.log")
    $baseOk = ($base.Exit -eq 0)
    $runsHere = ($base.Text -match '(?m)^\s*PASS\b')
    $i = 0
    foreach ($m in $g.Mutations) {
        $i++
        $row = [ordered]@{ Guard = $name; N = $i; File = $m.Path; Verdict = $null; Detail = ""; Log = $null }
        $results.Add($row)
        if (-not $m.From -or $null -eq $m.To -or -not $m.Expect) { $row.Verdict = "INCOMPLETE"; $row.Detail = "needs mutation-from, -to and -expect"; continue }
        if (-not $baseOk) { $row.Verdict = "BASE-RED"; $row.Detail = "the guard is red unmutated (exit $($base.Exit))"; $row.Log = $base.Text; continue }
        if (-not $runsHere) { $row.Verdict = "SKIPPED"; $row.Detail = "the guard printed no PASS line here"; continue }
        $target = Join-Path $repo $m.Path
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $row.Verdict = "STALE"; $row.Detail = "no file $($m.Path)"; continue }
        if ($haveGit) {
            $dirty = & git -C $repo status --porcelain -- $m.Path 2>$null
            if ($dirty) { $row.Verdict = "DIRTY"; $row.Detail = "$($m.Path) differs from git; refusing to touch it"; continue }
        }
        $bytes = [IO.File]::ReadAllBytes($target)
        $shaBefore = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        $text = $latin1.GetString($bytes)
        $from = $latin1.GetString([Text.Encoding]::UTF8.GetBytes($m.From))
        $to = $latin1.GetString([Text.Encoding]::UTF8.GetBytes($m.To))
        $count = ([regex]::Matches($text, [regex]::Escape($from))).Count
        if ($count -ne 1) { $row.Verdict = "STALE"; $row.Detail = "mutation-from occurs $count time(s) in $($m.Path), not once"; continue }
        $aside = Join-Path $LogDir "$name.$i.original"
        [IO.File]::WriteAllBytes($aside, $bytes)
        try {
            [IO.File]::WriteAllBytes($target, $latin1.GetBytes($text.Replace($from, $to)))
            $r = Invoke-Guard $g.File.FullName (Join-Path $LogDir "$name.$i.log")
        } finally {
            [IO.File]::WriteAllBytes($target, $bytes)
        }
        $shaAfter = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($target)))
        if ($shaAfter -ne $shaBefore) { $row.Verdict = "NOT-RESTORED"; $row.Detail = "the original is in $aside"; continue }
        Remove-Item -LiteralPath $aside -Force
        $row.Log = $r.Text
        if ($r.TimedOut) { $row.Verdict = "TIMEOUT"; $row.Detail = "the mutated run hit $TimeoutSec s" }
        elseif ($r.Exit -eq 0) { $row.Verdict = "SURVIVED"; $row.Detail = "the guard stayed green with the rule broken" }
        elseif ($r.Text -notmatch $m.Expect) { $row.Verdict = "WRONG-PLACE"; $row.Detail = "red (exit $($r.Exit)) but no output matched '$($m.Expect)'" }
        else { $row.Verdict = "CAUGHT"; $row.Detail = "exit $($r.Exit), matched '$($m.Expect)'" }
    }
}

Write-Host ""
foreach ($r in $results) {
    $color = switch ($r.Verdict) { "CAUGHT" { "Green" } "SKIPPED" { "Yellow" } default { "Red" } }
    Write-Host ("{0,-12} {1} #{2} ({3}): {4}" -f $r.Verdict, $r.Guard, $r.N, $r.File, $r.Detail) -ForegroundColor $color
}
$bad = @($results | Where-Object { $_.Verdict -notin "CAUGHT", "SKIPPED" })
# The guard's own words, for a verdict that needs them: CI keeps only this step's output.
foreach ($r in @($bad | Where-Object { $_.Log })) {
    Write-Host "---- $($r.Guard) #$($r.N) ($($r.Verdict)), the guard's last 30 lines ----"
    @($r.Log -split "`n") | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
}
if ($env:GITHUB_STEP_SUMMARY) {
    $md = @("### Mutations: $(@($results | Where-Object Verdict -eq 'CAUGHT').Count) caught, $(@($results | Where-Object Verdict -eq 'SKIPPED').Count) skipped, $($bad.Count) not caught", "", "| guard | # | file | verdict | detail |", "|---|---|---|---|---|")
    $md += $results | ForEach-Object { "| ``$($_.Guard)`` | $($_.N) | ``$($_.File)`` | $($_.Verdict) | $($_.Detail -replace '\|', '\|') |" }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}
if ($bad.Count) { Write-Host "$($bad.Count) of $($results.Count) mutation(s) not caught"; exit 1 }
Write-Host "all $($results.Count) mutation(s) caught or skipped here"
exit 0

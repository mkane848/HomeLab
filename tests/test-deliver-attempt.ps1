# protects: fleet delivery: the best allowed attempt becomes a fleet/<task> branch; main, the working copy and remotes untouched
# run-after: tests/deliver-attempt.ps1, tests/record-verdict.ps1, or the patch saving / Get-AttemptVerdict they read
# test-deliver-attempt.ps1 - regression guard for delivering an attempt to the owner (Step 2, 2026-11-02).
#
# Why this exists: the owner reviews the fleet's work as a branch in their own repository. The rules that make that
# safe are each one line a later edit could break: an accepted attempt first; a near miss only when no attempt was
# accepted and never one that broke a hard block (integrity, suite, scope, tampering); the owner's working copy,
# current branch and main never touched; nothing pushed; the patch applied byte for byte (CRLF too).
#
# What it does: a throwaway repository with a bare "remote" and a local main the owner is "working" on (an
# uncommitted edit), patches made by git from real changes, run JSONs in the shapes test-tasks.ps1 writes, then
# deliver-attempt.ps1 and record-verdict.ps1 against them.
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$deliver = Join-Path $PSScriptRoot "deliver-attempt.ps1"
$verdict = Join-Path $PSScriptRoot "record-verdict.ps1"
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "PASS $name" }
    else { Write-Host "FAIL $name (got '$actual', expected '$expected')"; $script:fail++ }
}
function G { $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"; try { (& git @args 2>&1 | ForEach-Object { "$_" }) -join "`n" } finally { $ErrorActionPreference = $prev } }
function Run([string]$script, [string[]]$a) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $o = & pwsh -NoProfile -File $script @a 2>&1 | Out-String; [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $o } } finally { $ErrorActionPreference = $prev }
}

Write-Host "-- static"
$code = Get-Content -Raw -LiteralPath $deliver
Check "deliver-attempt.ps1 never pushes" ($code -match '"push"|git push|\bpush\b"') "False"
Check "...reads the dispatcher's own verdict from run-retries.ps1" ($code -match 'Get-AttemptVerdict' -and $code -match 'run-retries\.ps1') "True"
$tt = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "test-tasks.ps1")
Check "test-tasks.ps1 saves each attempt's patch with git --output" ($tt -match '"diff", "--binary", "--output=\$patchPath"') "True"
Check "...and records it as patchFile" ($tt -match 'patchFile\s+= \$patchField') "True"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("deliver-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding($false)
try {
    $repo = Join-Path $tmp "repo"; $bare = Join-Path $tmp "remote.git"; $res = Join-Path $tmp "results"; $scratch = Join-Path $tmp "scratch"
    New-Item -ItemType Directory -Force $repo, $res | Out-Null
    G init -q -b main $repo | Out-Null
    G -C $repo config core.autocrlf false | Out-Null
    G -C $repo config user.name owner | Out-Null; G -C $repo config user.email owner@x | Out-Null
    [IO.File]::WriteAllText((Join-Path $repo "AGENTS.md"), "# AGENTS`n`n## Layout`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $repo "crlf.txt"), "one`r`ntwo`r`n", $utf8)
    G -C $repo add -A | Out-Null; G -C $repo commit -q -m base | Out-Null
    $base = (G -C $repo rev-parse HEAD).Trim()
    G init -q --bare $bare | Out-Null; G -C $repo remote add origin $bare | Out-Null; G -C $repo push -q origin main | Out-Null
    # The owner keeps working: a later commit on main and an uncommitted edit.
    [IO.File]::WriteAllText((Join-Path $repo "notes.md"), "mine`n", $utf8); G -C $repo add notes.md | Out-Null; G -C $repo commit -q -m "owner's later work" | Out-Null
    $mainBefore = (G -C $repo rev-parse main).Trim()
    [IO.File]::WriteAllText((Join-Path $repo "notes.md"), "mine, uncommitted`n", $utf8)

    # A patch from a real change at the base (what test-tasks.ps1 does: intent-to-add, then diff --binary --output).
    $n = 0
    function New-Attempt([string]$task, [hashtable]$gates, [string]$selStatus, [string]$selDetail, [scriptblock]$change, [bool]$tampered = $false) {
        $script:n++
        Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
        G clone -q $bare $scratch | Out-Null; G -C $scratch config core.autocrlf false | Out-Null; G -C $scratch checkout -q $base | Out-Null
        & $change $scratch
        G -C $scratch add -A -N | Out-Null
        $stem = "tasks-$task-fx_m_20261102-0000{0:D2}" -f $script:n
        G -C $scratch diff --binary "--output=$(Join-Path $res "$stem.patch")" $base | Out-Null
        [pscustomobject]@{ taskId = $task; taskTitle = "fx"; model = "fx/m"; baseCommit = $base; repoPath = $repo; elapsedSec = 1
            gates = [pscustomobject]$gates; selector = [pscustomobject]@{ status = $selStatus; source = "planner"; detail = $selDetail }
            acceptance = [pscustomobject]@{ status = "PASS" }; acceptanceShown = [pscustomobject]@{ tampered = @($(if ($tampered) { "x.test.ts" })) }
            ideal = [pscustomobject]@{ total = 3; done = 2; missedIds = @("I2") }; patchFile = "$stem.patch" } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $res "$stem.json")
    }
    $ok = @{ suite = "PASS"; scope = "PASS"; integrity = "PASS" }
    $edit = { param($w) [IO.File]::WriteAllText((Join-Path $w "AGENTS.md"), "# AGENTS`n`n## Layout`n`n- src/`n", $utf8) }

    Write-Host "-- an accepted attempt"
    New-Attempt "t-acc" $ok "FAIL" "Tests 3 failed | 1 passed (4)" $edit
    New-Attempt "t-acc" $ok "PASS" "Tests 4 passed (4)" { param($w) & $edit $w; [IO.File]::WriteAllText((Join-Path $w "crlf.txt"), "one`r`ntwo`r`nthree`r`n", $utf8); [IO.File]::WriteAllText((Join-Path $w "new.md"), "added`n", $utf8) }
    $r = Run $deliver @("-ResultsDir", $res, "-Task", "t-acc")
    Check "exit 0" $r.Exit 0
    Check "a branch fleet/t-acc exists" ([bool](G -C $repo rev-parse --verify --quiet refs/heads/fleet/t-acc)) "True"
    Check "...one commit on the base, not on main" ((G -C $repo rev-parse fleet/t-acc~1).Trim()) $base
    Check "...labelled accepted" ((G -C $repo log -1 --format=%s fleet/t-acc).Trim()) "fleet: t-acc (accepted)"
    Check "...carrying the gate, integrity and ideal" ((G -C $repo log -1 --format=%B fleet/t-acc) -match '(?s)Planner.s tests.*PASS.*Integrity.*PASS.*Ideal tier: 2 of 3 done; missed I2') "True"
    Check "...the accepted attempt, not the earlier failing one (new.md is there)" ((G -C $repo show fleet/t-acc:new.md).Trim()) "added"
    # The blob's raw bytes, through a file: PowerShell's pipeline would split lines and drop the CRs being checked.
    $p = Start-Process -FilePath git -ArgumentList @("-C", $repo, "cat-file", "-p", "fleet/t-acc:crlf.txt") -RedirectStandardOutput (Join-Path $tmp "crlf.bin") -NoNewWindow -Wait -PassThru
    $b = [IO.File]::ReadAllBytes((Join-Path $tmp "crlf.bin"))
    Check "...CRLF content applied byte for byte" ([Text.Encoding]::UTF8.GetString($b)) "one`r`ntwo`r`nthree`r`n"
    Check "main untouched" ((G -C $repo rev-parse main).Trim()) $mainBefore
    Check "...still the current branch" ((G -C $repo branch --show-current).Trim()) "main"
    Check "...the owner's uncommitted edit still there" ([IO.File]::ReadAllText((Join-Path $repo "notes.md"))) "mine, uncommitted`n"
    Check "nothing pushed: the remote has no fleet branch" ((G -C $bare branch --list "fleet/*").Trim()) ""
    Check "no worktree left behind" (@((G -C $repo worktree list) -split "`n" | Where-Object { $_ }).Count) 1
    Check "deliveries.tsv records it" ((Import-Csv (Join-Path $res "deliveries.tsv") -Delimiter "`t")[-1].kind) "accepted"
    $r = Run $deliver @("-ResultsDir", $res, "-Task", "t-acc")
    Check "a second delivery takes fleet/t-acc-2" ([bool](G -C $repo rev-parse --verify --quiet refs/heads/fleet/t-acc-2)) "True"

    Write-Host "-- near misses and hard blocks"
    New-Attempt "t-near" $ok "FAIL" "Tests 3 failed | 5 passed (8)" $edit
    New-Attempt "t-near" $ok "FAIL" "Tests 1 failed | 7 passed (8)" { param($w) & $edit $w; [IO.File]::WriteAllText((Join-Path $w "best.md"), "fewest failures`n", $utf8) }
    New-Attempt "t-near" @{ suite = "PASS"; scope = "PASS"; integrity = "FAIL" } "FAIL" "Tests 0 failed | 8 passed (8)" { param($w) [IO.File]::WriteAllText((Join-Path $w "blocked.md"), "x`n", $utf8) }
    $r = Run $deliver @("-ResultsDir", $res, "-Task", "t-near")
    Check "no accepted attempt: the near miss with the fewest failures" ((G -C $repo show fleet/t-near:best.md).Trim()) "fewest failures"
    Check "...labelled NEAR MISS" ((G -C $repo log -1 --format=%s fleet/t-near) -match 'NEAR MISS, not accepted: 1 planner test') "True"
    Check "...never the integrity-blocked one" ($r.Out -match 'blocked') "False"
    New-Attempt "t-blocked" @{ suite = "FAIL"; scope = "PASS"; integrity = "PASS" } "PASS" "Tests 4 passed (4)" $edit
    New-Attempt "t-blocked" @{ suite = "PASS"; scope = "FAIL"; integrity = "PASS" } "FAIL" "Tests 1 failed (4)" $edit
    New-Attempt "t-blocked" $ok "PASS" "Tests 4 passed (4)" $edit $true
    $r = Run $deliver @("-ResultsDir", $res, "-Task", "t-blocked")
    Check "only hard-block failures (suite, scope, tampered): exit 2" $r.Exit 2
    Check "...and no branch" ([bool](G -C $repo rev-parse --verify --quiet refs/heads/fleet/t-blocked)) "False"
    $r = Run $deliver @("-ResultsDir", $res, "-Task", "t-near", "-Branch", "main")
    Check "-Branch main is refused" $r.Exit 3
    $r = Run $deliver @("-ResultsDir", $res, "-Task", "t-near", "-Branch", "fleet/dry", "-DryRun")
    Check "-DryRun creates nothing" ([bool](G -C $repo rev-parse --verify --quiet refs/heads/fleet/dry)) "False"

    Write-Host "-- the owner's verdict"
    $r = Run $verdict @("-ResultsDir", $res, "-Task", "t-acc", "-Verdict", "merged")
    Check "merged: recorded" $r.Exit 0
    Check "...as the gate being right" ($r.Out -match 'the gate was right') "True"
    $r = Run $verdict @("-ResultsDir", $res, "-Task", "t-near", "-Verdict", "merged")
    Check "a near miss merged as is: a false negative" ($r.Out -match 'too strict') "True"
    $r = Run $verdict @("-ResultsDir", $res, "-Task", "t-acc", "-Verdict", "rejected")
    Check "rejected without a note: refused" $r.Exit 3
    $r = Run $verdict @("-ResultsDir", $res, "-Task", "t-acc", "-Verdict", "rejected", "-Note", "wrong`tsection")
    Check "rejected with a note: a false positive" ($r.Out -match 'false positive') "True"
    $rows = @(Import-Csv (Join-Path $res "verdicts.tsv") -Delimiter "`t")
    Check "verdicts.tsv has the three rows" $rows.Count 3
    Check "...the note cleaned of tabs" $rows[-1].note "wrong section"
    $r = Run $verdict @("-ResultsDir", $res, "-Task", "t-none", "-Verdict", "merged")
    Check "a task never delivered: refused" $r.Exit 3
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host "all passed"
exit 0

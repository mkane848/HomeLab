# protects: tests/run-mutations.ps1 (a guard must go red when the rule it protects is broken) and make-reference.py's mutation-header rule
# run-after: tests/run-mutations.ps1, tests/make-reference.py, tests/mutation-exempt.txt
# mutation: tests/run-mutations.ps1
# mutation-from: $row.Verdict = "SURVIVED"
# mutation-to: $row.Verdict = "CAUGHT"
# mutation-expect: FAIL\s+a guard that stays green is SURVIVED
# mutation: tests/make-reference.py
# mutation-from: if not groups and name not in exempt:
# mutation-to: if False:
# mutation-expect: FAIL\s+a new guard with no mutation header is refused
# mutation: tests/run-mutations.ps1
# mutation-from: [IO.File]::WriteAllBytes($target, $bytes)
# mutation-to: $null = $bytes
# mutation-expect: FAIL\s+\.\.\.and the target is byte-identical
# test-run-mutations.ps1 - regression guard for the mutation runner and the rule that a new guard carries a mutation.
#
# Why this exists: run-mutations.ps1 is what makes "a guard that cannot fail protects nothing" (AGENTS.md) a check
# instead of a hope. If it called a surviving mutation caught, or left a broken file behind, it would be worse than
# nothing: green, and wrong. And the header rule in make-reference.py is what makes every new guard carry a mutation.
# What it does: builds a throwaway git repo (autocrlf off) with stand-in guards and a target file, and runs the real
# run-mutations.ps1 on it with -RepoRoot:
#   - a guard that catches the break is CAUGHT, and the run exits 0;
#   - a guard that stays green is SURVIVED; red for another reason is WRONG-PLACE; red unmutated is BASE-RED;
#     each makes the run exit 1;
#   - a mutation whose text occurs 0 or 2 times is STALE, and nothing is changed;
#   - a guard that prints no PASS line (it SKIPs here) is SKIPPED, and the run exits 0;
#   - a target that differs from git is DIRTY, and is left as it was;
#   - the target, with CRLF line endings and non-ASCII bytes, is byte-identical after every run.
# Then make-reference.py, copied into a temp tree, must refuse: a new guard with no mutation, an exempt list over its
# cap, a name in the list that is not a guard, a stale mutation-from; and accept a guard with a good one.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-run-mutations.ps1
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repo "tests/run-mutations.ps1"
foreach ($p in $runner, (Join-Path $repo "tests/make-reference.py")) { if (-not (Test-Path -LiteralPath $p)) { Write-Host "FAIL: missing $p"; exit 1 } }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host "SKIP needs git"; exit 0 }
$py = @("python3", "python") | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("mutations-guard-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp "tests"), (Join-Path $tmp "src") | Out-Null
try {
    # The target: CRLF line endings and a non-ASCII byte, so a lossy rewrite would show in its hash.
    $target = Join-Path $tmp "src/rule.txt"
    [IO.File]::WriteAllBytes($target, [Text.Encoding]::UTF8.GetBytes("caf$([char]0xE9) first line`r`nrule: on`r`ntwice`r`ntwice`r`n"))
    $sha = { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($target))) }
    $shaStart = & $sha

    function New-Guard([string]$Name, [string[]]$Header, [string]$Body) {
        $text = (($Header | ForEach-Object { "# $_" }) -join "`n") + "`n" + $Body + "`n"
        [IO.File]::WriteAllText((Join-Path $tmp "tests/$Name.ps1"), $text)
    }
    $reads = '$t = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) "src/rule.txt"))'
    $catches = "$reads`nif (`$t -match 'rule: on') { 'PASS rule holds'; exit 0 } else { 'FAIL rule holds'; exit 1 }"
    $m = { param($from, $to, $expect) @("mutation: src/rule.txt", "mutation-from: $from", "mutation-to: $to", "mutation-expect: $expect") }
    New-Guard "test-catches" (& $m "rule: on" "rule: off" "FAIL rule holds") $catches
    New-Guard "test-survives" (& $m "rule: on" "rule: off" "FAIL rule holds") "'PASS always'; exit 0"
    New-Guard "test-wrongplace" (& $m "rule: on" "rule: off" "FAIL rule holds") "$reads`nif (`$t -match 'rule: on') { 'PASS ok'; exit 0 } else { 'FAIL something later'; exit 1 }"
    New-Guard "test-basered" (& $m "rule: on" "rule: off" "FAIL rule holds") "'FAIL already'; exit 1"
    New-Guard "test-missing" (& $m "no such text" "x" "FAIL rule holds") $catches
    New-Guard "test-twice" (& $m "twice" "once" "FAIL rule holds") $catches
    New-Guard "test-skips" (& $m "rule: on" "rule: off" "FAIL rule holds") "'SKIP not on this machine'; exit 0"

    & git -C $tmp init -q 2>$null; & git -C $tmp config core.autocrlf false; & git -C $tmp config user.email "g@example.invalid"; & git -C $tmp config user.name "guard"
    & git -C $tmp add -A; & git -C $tmp commit -q -m fixture

    function Invoke-Runner([string[]]$Only) {
        $out = & pwsh -NoProfile -File $runner -RepoRoot $tmp -Only ($Only -join ",") -TimeoutSec 120 2>&1 | Out-String
        [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
    }

    Write-Host "-- a guard that catches the break"
    $r = Invoke-Runner @("test-catches")
    Check "a guard that catches the break is CAUGHT" ($r.Out -match '(?m)^CAUGHT\s+test-catches #1') "True"
    Check "...and the run exits 0" $r.Exit 0
    Check "...and the target is byte-identical" (& $sha) $shaStart

    Write-Host "-- a guard that does not"
    $r = Invoke-Runner @("test-survives")
    Check "a guard that stays green is SURVIVED" ($r.Out -match '(?m)^SURVIVED\s+test-survives #1') "True"
    Check "...and the run exits 1" $r.Exit 1
    Check "...and the target is byte-identical" (& $sha) $shaStart

    $r = Invoke-Runner @("test-wrongplace")
    Check "red with another FAIL line is WRONG-PLACE" ($r.Out -match '(?m)^WRONG-PLACE\s+test-wrongplace #1') "True"
    Check "...and the run exits 1" $r.Exit 1

    $r = Invoke-Runner @("test-basered")
    Check "red before any mutation is BASE-RED" ($r.Out -match '(?m)^BASE-RED\s+test-basered #1') "True"
    Check "...and the run exits 1" $r.Exit 1

    Write-Host "-- stale mutations"
    $r = Invoke-Runner @("test-missing", "test-twice")
    Check "text that is not there is STALE" ($r.Out -match '(?m)^STALE\s+test-missing #1.*occurs 0 time') "True"
    Check "text that occurs twice is STALE" ($r.Out -match '(?m)^STALE\s+test-twice #1.*occurs 2 time') "True"
    Check "...and the run exits 1" $r.Exit 1
    Check "...and the target is byte-identical" (& $sha) $shaStart

    Write-Host "-- a guard that skips here"
    $r = Invoke-Runner @("test-skips", "test-catches")
    Check "a guard with no PASS line is SKIPPED" ($r.Out -match '(?m)^SKIPPED\s+test-skips #1') "True"
    Check "...and SKIPPED with CAUGHT exits 0" $r.Exit 0

    Write-Host "-- a target that differs from git"
    $dirty = [Text.Encoding]::UTF8.GetBytes("rule: on`nlocal edit`n")
    [IO.File]::WriteAllBytes($target, $dirty)
    $shaDirty = & $sha
    $r = Invoke-Runner @("test-catches")
    Check "a target that differs from git is DIRTY" ($r.Out -match '(?m)^DIRTY\s+test-catches #1') "True"
    Check "...and is left as it was" (& $sha) $shaDirty
    Check "...and the run exits 1" $r.Exit 1
    & git -C $tmp checkout -q -- src/rule.txt
    Check "the fixture is back to its committed bytes" (& $sha) $shaStart

    Write-Host "-- make-reference.py's header rule"
    if (-not $py) { Write-Host "SKIP make-reference.py: no python3 here" }
    else {
        $mr = Join-Path $tmp "mr"
        New-Item -ItemType Directory -Force -Path (Join-Path $mr "tests"), (Join-Path $mr "docs/reference"), (Join-Path $mr "src") | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo "tests/make-reference.py") -Destination (Join-Path $mr "tests/make-reference.py")
        [IO.File]::WriteAllText((Join-Path $mr "src/rule.txt"), "rule: on`n")
        [IO.File]::WriteAllText((Join-Path $mr "machines.tsv"), "name`troles`tnote`n")
        foreach ($d in @(@("guards.md", "guards"), @("machines.md", "machines"))) {
            [IO.File]::WriteAllText((Join-Path $mr "docs/reference/$($d[0])"), "<!-- BEGIN GENERATED: $($d[1]) -->`n<!-- END GENERATED: $($d[1]) -->`n")
        }
        $hdr = @("protects: x", "run-after: y")
        function New-MrGuard([string]$Name, [string[]]$Extra) {
            [IO.File]::WriteAllText((Join-Path $mr "tests/$Name.ps1"), ((($hdr + $Extra) | ForEach-Object { "# $_" }) -join "`n") + "`n'PASS x'`n")
        }
        function Invoke-Mr { & $py -I (Join-Path $mr "tests/make-reference.py") 2>&1 | Out-String }
        $good = @("mutation: src/rule.txt", "mutation-from: rule: on", "mutation-to: rule: off", "mutation-expect: FAIL x")

        [IO.File]::WriteAllText((Join-Path $mr "tests/mutation-exempt.txt"), "# list`ntest-old.ps1`n")
        New-MrGuard "test-old" @()
        New-MrGuard "test-good" $good
        $o = Invoke-Mr
        Check "an exempt guard with no mutation is accepted" ($o -match 'test-old\.ps1: no "# mutation:" header') "False"
        Check "a guard with a good mutation is accepted" ($o -match 'test-good\.ps1') "False"

        New-MrGuard "test-new" @()
        $o = Invoke-Mr
        Check "a new guard with no mutation header is refused" ($o -match 'FAIL tests/test-new\.ps1: no "# mutation:" header') "True"
        Remove-Item -LiteralPath (Join-Path $mr "tests/test-new.ps1")

        New-MrGuard "test-stale" @("mutation: src/rule.txt", "mutation-from: not in the file", "mutation-to: x", "mutation-expect: FAIL x")
        $o = Invoke-Mr
        Check "a stale mutation-from is refused" ($o -match 'FAIL tests/test-stale\.ps1: mutation 1 \(src/rule\.txt\): mutation-from occurs 0 time') "True"
        Remove-Item -LiteralPath (Join-Path $mr "tests/test-stale.ps1")

        [IO.File]::WriteAllText((Join-Path $mr "tests/mutation-exempt.txt"), "test-old.ps1`ntest-gone.ps1`n")
        $o = Invoke-Mr
        Check "an exempt name that is not a guard is refused" ($o -match 'FAIL tests/mutation-exempt\.txt: test-gone\.ps1 is not a guard') "True"

        $cap = [int]([regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $mr "tests/make-reference.py")), '(?m)^EXEMPT_MAX = (\d+)').Groups[1].Value)
        $names = @("test-old.ps1") + @(1..$cap | ForEach-Object { "test-pad$_.ps1" })
        foreach ($n in $names[1..($names.Count - 1)]) { New-MrGuard ([IO.Path]::GetFileNameWithoutExtension($n)) @() }
        [IO.File]::WriteAllText((Join-Path $mr "tests/mutation-exempt.txt"), ($names -join "`n") + "`n")
        $o = Invoke-Mr
        Check "an exempt list over its cap ($cap) is refused" ($o -match "FAIL tests/mutation-exempt\.txt: $($cap + 1) names, more than the $cap") "True"
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

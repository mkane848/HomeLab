# protects: the owner's standing hard blocks for Markdown (integrity gate: nothing lost, nothing wrong)
# run-after: tests/checks/doc-integrity.ps1, or the integrity gate in test-tasks.ps1 / run-retries.ps1
# test-doc-integrity.ps1 - regression guard for Test-DocIntegrity (tests/checks/doc-integrity.ps1).
#
# Why this exists: the owner merges small gaps but never lost or wrong content (2026-11-01). On real-02 an attempt
# demoted every `##` heading to `###` and passed the hidden tests, whose `toContain('## Project')` matched `### Project`;
# another dropped `## Project` and was one of the first run's three false positives. The integrity gate catches both.
# Each rule is one line a later edit could loosen, so each has a case here, in a throwaway git repository.
#
# What it does: builds a repo with a README (headings, a fenced block, paths, an em dash), commits it as the base, then
# for each scenario resets the tree, applies one change and checks Test-DocIntegrity's verdict. Then the dispatcher:
# run-retries.ps1's verdict rejects an integrity FAIL and keeps a row with no integrity gate (rows before the gate).
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo "tests/checks/doc-integrity.ps1")
$script:fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "PASS $name" }
    else { Write-Host "FAIL $name (got '$actual', expected '$expected')"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("doc-integrity-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$readme = @"
# Project

Intro.

## Layout — where things are

- ``src/app.ts`` - the app
- ``scripts/backup.sh`` - backups
- ``docs/old-guide.md`` - stale already at the base

## Testing

``````text
## not a heading, an example
``````
"@
# LF whatever the checkout: CI checks this file out with CRLF (core.autocrlf), which put "
" into the here-string
# above, and a scenario that removes "# Project`n" then changed nothing (2026-11-02, PR #188's first CI run).
$readme = $readme -replace "`r`n", "`n"
try {
    New-Item -ItemType Directory -Force (Join-Path $tmp "src"), (Join-Path $tmp "scripts"), (Join-Path $tmp "docs") | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp "README.md"), $readme + "`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp "NOTES.md"), "# Notes`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp "src/app.ts"), "export {}`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp "scripts/backup.sh"), "true`n", $utf8)
    & git -C $tmp init -q
    # This repo's own setting, over any global one: with core.autocrlf=true (CI's runners) the checkout between
    # scenarios rewrote README.md with CRLF and "# Project`n" no longer matched (PR #188, 2026-11-02).
    & git -C $tmp config core.autocrlf false
    & git -C $tmp -c user.email=g@x -c user.name=guard add -A; & git -C $tmp -c user.email=g@x -c user.name=guard commit -q -m base
    $base = (& git -C $tmp rev-parse HEAD)
    function Scenario([string]$name, [scriptblock]$change, [string]$expect, [string]$detailLike = "") {
        & git -C $tmp checkout -q -- . ; & git -C $tmp clean -qfd
        & $change
        $r = Test-DocIntegrity -Worktree $tmp -Base $base
        Check $name $r.Status $expect
        if ($detailLike) { Check "...detail names it" ($r.Detail -like "*$detailLike*") "True" }
    }
    $edit = { param($f, $from, $to) $p = Join-Path $tmp $f; [IO.File]::WriteAllText($p, ([IO.File]::ReadAllText($p)).Replace($from, $to), $utf8) }

    Scenario "no Markdown change: SKIP"                           { [IO.File]::WriteAllText((Join-Path $tmp "src/app.ts"), "export const x = 1`n", $utf8) } "SKIP"
    Scenario "text added, headings kept: PASS"                    { & $edit "README.md" "Intro." "Intro, longer." } "PASS"
    Scenario "a heading added: PASS"                              { & $edit "README.md" "## Testing" "## Testing`n`n## Deploying" } "PASS"
    Scenario "a heading demoted (## to ###): FAIL"                { & $edit "README.md" "## Testing" "### Testing" } "FAIL" "## Testing"
    Scenario "a heading removed: FAIL"                            { & $edit "README.md" "# Project`n" "" } "FAIL" "# Project"
    Scenario "a heading reworded: FAIL"                           { & $edit "README.md" "## Testing" "## Tests" } "FAIL" "## Testing"
    Scenario "an em-dash heading untouched: PASS (encoding)"      { & $edit "README.md" "Intro." "Intro!" } "PASS"
    Scenario "only the line endings changed (CRLF): PASS"         { $p = Join-Path $tmp "README.md"; [IO.File]::WriteAllText($p, (([IO.File]::ReadAllText($p)) -replace "`n", "`r`n"), $utf8) } "PASS"
    Scenario "CRLF and a heading removed: FAIL"                   { $p = Join-Path $tmp "README.md"; [IO.File]::WriteAllText($p, ((([IO.File]::ReadAllText($p)).Replace("## Testing`n", "")) -replace "`n", "`r`n"), $utf8) } "FAIL" "## Testing"
    Scenario "a Markdown file deleted: FAIL"                      { Remove-Item (Join-Path $tmp "NOTES.md") } "FAIL" "deleted"
    Scenario "an added path that exists: PASS"                    { & $edit "README.md" "Intro." "See ``src/app.ts``." } "PASS"
    Scenario "an added bare file name that exists: PASS"          { & $edit "README.md" "Intro." "See ``backup.sh``." } "PASS"
    Scenario "an added directory that exists: PASS"               { & $edit "README.md" "Intro." "See ``scripts/``." } "PASS"
    Scenario "an added path that does not exist: FAIL"            { & $edit "README.md" "Intro." "See ``src/missing.ts``." } "FAIL" "src/missing.ts"
    Scenario "an added bare name that does not exist: FAIL"       { & $edit "README.md" "Intro." "See ``deploy.sh``." } "FAIL" "deploy.sh"
    Scenario "example branch names (fix/x, feat/y-z): PASS, not paths" { & $edit "README.md" "Intro." "Branches like ``fix/digest-retry`` or ``feat/have-multi``." } "PASS"
    Scenario "a missing folder under a real top-level one: FAIL"  { & $edit "README.md" "Intro." "See ``src/nope/``." } "FAIL" "src/nope"
    Scenario "a missing file whose first part is not a folder: FAIL" { & $edit "README.md" "Intro." "See ``fix/thing.ts``." } "FAIL" "fix/thing.ts"
    Scenario "a stale path the base already had: PASS"            { & $edit "README.md" "Intro." "Intro (edited)." } "PASS"
    Scenario "a path in a new file, made in the same change: PASS" { [IO.File]::WriteAllText((Join-Path $tmp "src/new.ts"), "export {}`n", $utf8); & $edit "README.md" "Intro." "See ``src/new.ts``." } "PASS"
    Scenario "a fenced example removed: PASS (not structure)"     { & $edit "README.md" "## not a heading, an example" "an example" } "PASS"
    Scenario "a missing path inside a fence: PASS (an example)"   { & $edit "README.md" "## not a heading, an example" "see ``src/nope.ts``" } "PASS"
    Scenario "a URL and a glob are not paths: PASS"               { & $edit "README.md" "Intro." "See ``https://x.invalid/a.md`` and ``src/*.ts``." } "PASS"
    Scenario "a new Markdown file with a broken path: FAIL"       { New-Item -ItemType Directory -Force (Join-Path $tmp "docs") | Out-Null; [IO.File]::WriteAllText((Join-Path $tmp "docs/new.md"), "# New`n`nSee ``src/gone.ts``.`n", $utf8) } "FAIL" "src/gone.ts"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host "-- the dispatcher's verdict (run-retries.ps1)"
$code = Get-Content -Raw -LiteralPath (Join-Path $repo "tests/run-retries.ps1")
$fn = [regex]::Match($code, '(?s)function Get-AttemptVerdict \{.*?\n\}').Value
Invoke-Expression $fn
$row = { param($integrity) $g = [ordered]@{ suite = "PASS"; scope = "PASS" }; if ($integrity) { $g.integrity = $integrity }
    [pscustomobject]@{ selector = [pscustomobject]@{ status = "PASS"; source = "planner" }; acceptance = [pscustomobject]@{ status = "PASS" }; gates = [pscustomobject]$g; acceptanceShown = [pscustomobject]@{ tampered = @() } } }
Check "integrity FAIL: not kept"                    (Get-AttemptVerdict (& $row "FAIL")).Reason "integrity"
Check "integrity PASS: kept"                        (Get-AttemptVerdict (& $row "PASS")).Accepted "True"
Check "integrity SKIP (no Markdown changed): kept"  (Get-AttemptVerdict (& $row "SKIP")).Accepted "True"
Check "a row from before the gate: kept"            (Get-AttemptVerdict (& $row $null)).Accepted "True"

Write-Host "-- the harness records it (static)"
$tt = Get-Content -Raw -LiteralPath (Join-Path $repo "tests/test-tasks.ps1")
Check "test-tasks.ps1 dot-sources the check"         ($tt -match 'checks\\doc-integrity\.ps1') "True"
Check "...runs it on every task"                     ($tt -match 'Test-DocIntegrity -Worktree \$wt\.Wt -Base \$wt\.Head') "True"
Check "...fails the run on FAIL"                     ($tt -match 'Status -eq "FAIL"\) \{ \$overallPass = \$false \}') "True"
Check "...records gates.integrity"                   ($tt -match 'integrity = \$integrity\.Status') "True"
Check "...resets it per task"                        ($tt -match '\$integrity = \[pscustomobject\]@\{ Status = "SKIP"') "True"
$sr = Get-Content -Raw -LiteralPath (Join-Path $repo "tests/summarize-rounds.ps1")
Check "summarize-rounds.ps1 counts it in 'accepted'" ($sr -match 'gates\.integrity -eq "FAIL"') "True"

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host "all passed"
exit 0

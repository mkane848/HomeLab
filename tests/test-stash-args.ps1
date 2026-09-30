# test-stash-args.ps1 - regression guard for the failsOnOld revert in test-tasks.ps1.
#
# Why this exists: test-tasks.ps1 reverts a task's srcRevertFiles with
# `git stash push -- <files>`. The argument list used to be built with the file
# list NESTED inside the array (@(..., "--", @($tk.srcRevertFiles))). Run-Native
# declares [string[]]$Arguments, so a nested array arrives as ONE space-joined
# element ("a.ts b.ts"), git rejects it as a pathspec, and any task listing two
# or more source files reported "git stash push failed - cannot grade" for every
# model. All nine original tasks list exactly one file, so it never fired.
#
# What it does: pulls the REAL Run-Native function and the REAL stash-push line
# out of test-tasks.ps1 (so it tests the harness as written, not a copy) and runs
# them against a throwaway git repo for a two-file list, a one-file list and a
# bare string. Each case also checks that the model's test file is NOT reverted
# and that `git stash pop` restores everything. Exit 1 on any failure.
#
# Usage:  .\tests\test-stash-args.ps1 [-ScriptPath <path to a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Run-Native" }, $true)
if (-not $fn) { Write-Host "FAIL: Run-Native not found in $ScriptPath"; exit 2 }
Invoke-Expression $fn.Extent.Text

$stashLines = @(Get-Content -LiteralPath $ScriptPath | Where-Object { $_ -match 'Run-Native "git" .*"stash", "push", "--"' })
if ($stashLines.Count -ne 1) { Write-Host "FAIL: expected exactly one stash-push line in $ScriptPath, found $($stashLines.Count)"; exit 2 }
$expr = $stashLines[0] -replace '^\s*\$r\s*=\s*', ''
Write-Host "line under test: $($stashLines[0].Trim())"

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stash-args-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

function New-Repo {
    $repo = Join-Path $tmpRoot ([guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $repo "src"), (Join-Path $repo "tests") -Force | Out-Null
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    foreach ($f in "src/a.ts", "src/b.ts", "tests/a.test.ts") { Set-Content -LiteralPath (Join-Path $repo $f) -Value "base $f" }
    git -C $repo add -A
    git -C $repo commit -q -m base
    foreach ($f in "src/a.ts", "src/b.ts", "tests/a.test.ts") { Set-Content -LiteralPath (Join-Path $repo $f) -Value "model edit $f" }
    return $repo
}

$script:fail = 0
function Check([string]$name, $srcRevertFiles, [string[]]$expectReverted) {
    $repo = New-Repo
    $wt = [pscustomobject]@{ Wt = $repo }
    $tk = [pscustomobject]@{ srcRevertFiles = $srcRevertFiles }
    $r = Invoke-Expression $expr
    $ok = ($r.ExitCode -eq 0)
    if ($ok) {
        $stillModified = @(git -C $repo diff --name-only)
        foreach ($f in $expectReverted) { if ($stillModified -contains $f) { $ok = $false; Write-Host "   $f was NOT reverted" } }
        if ($stillModified -notcontains "tests/a.test.ts") { $ok = $false; Write-Host "   the model's test file was reverted too" }
        $p = Run-Native "git" @("-C", $repo, "stash", "pop")
        if ($p.ExitCode -ne 0 -or @(git -C $repo diff --name-only).Count -ne 3) { $ok = $false; Write-Host "   stash pop did not restore all 3 files" }
    } else {
        Write-Host "   exit $($r.ExitCode): $($r.Output -join ' ')"
    }
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { $script:fail++ }
}

try {
    Check "two files in srcRevertFiles (array)" @("src/a.ts", "src/b.ts") @("src/a.ts", "src/b.ts")
    Check "one file in srcRevertFiles (array)"  @("src/a.ts")             @("src/a.ts")
    Check "one file as a bare string"           "src/a.ts"                @("src/a.ts")
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 } else { Write-Host "RESULT: all checks passed" }

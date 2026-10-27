param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$TmpRoot)
# Runs the ACTUAL `git stash push` line of test-tasks.ps1 (the failsOnOld revert) against a throwaway repo,
# using the ACTUAL Run-Native function, for 2-file, 1-file and bare-string srcRevertFiles.
$ErrorActionPreference = 'Stop'
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Run-Native' }, $true)
Invoke-Expression $fn.Extent.Text
$stashLines = @(Get-Content -LiteralPath $ScriptPath | Where-Object { $_ -match 'Run-Native "git" .*"stash", "push", "--"' })
if ($stashLines.Count -ne 1) { Write-Host "FAIL: expected exactly one stash-push line, found $($stashLines.Count)"; exit 2 }
$expr = $stashLines[0] -replace '^\s*\$r\s*=\s*', ''
Write-Host "line under test: $($stashLines[0].Trim())"

function New-Repo {
    $repo = Join-Path $TmpRoot ("stash-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $repo 'src'), (Join-Path $repo 'tests') -Force | Out-Null
    git -C $repo init -q
    git -C $repo config user.email t@t; git -C $repo config user.name t
    foreach ($f in 'src/a.ts', 'src/b.ts', 'tests/a.test.ts') { Set-Content -LiteralPath (Join-Path $repo $f) -Value "base $f" }
    git -C $repo add -A; git -C $repo commit -q -m base
    foreach ($f in 'src/a.ts', 'src/b.ts', 'tests/a.test.ts') { Set-Content -LiteralPath (Join-Path $repo $f) -Value "model edit $f" }   # simulate the model's edits
    return $repo
}

$fail = 0
function Check([string]$name, $srcRevertFiles, [string[]]$expectReverted) {
    $repo = New-Repo
    $wt = [pscustomobject]@{ Wt = $repo }
    $tk = [pscustomobject]@{ srcRevertFiles = $srcRevertFiles }
    $r = Invoke-Expression $expr
    $ok = ($r.ExitCode -eq 0)
    if ($ok) {
        $stillModified = @(git -C $repo diff --name-only)
        foreach ($f in $expectReverted) { if ($stillModified -contains $f) { $ok = $false; Write-Host "   $f was NOT reverted" } }
        if ($stillModified -notcontains 'tests/a.test.ts') { $ok = $false; Write-Host "   the model's test file was reverted too" }
        $p = Run-Native 'git' @('-C', $repo, 'stash', 'pop')
        if ($p.ExitCode -ne 0 -or @(git -C $repo diff --name-only).Count -ne 3) { $ok = $false; Write-Host "   stash pop did not restore all 3 files" }
    } else {
        Write-Host "   exit $($r.ExitCode): $($r.Output -join ' ')"
    }
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name)
    if (-not $ok) { $script:fail++ }
}

Check '2 files in srcRevertFiles (array)'    @('src/a.ts', 'src/b.ts') @('src/a.ts', 'src/b.ts')
Check '1 file in srcRevertFiles (array)'     @('src/a.ts')             @('src/a.ts')
Check '1 file as a bare string'              'src/a.ts'                @('src/a.ts')
if ($fail) { Write-Host "RESULT: $fail check(s) failed"; exit 1 } else { Write-Host 'RESULT: all checks passed' }

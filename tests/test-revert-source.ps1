# test-revert-source.ps1 - regression guard for the failsOnOld revert in test-tasks.ps1.
# (It replaces test-stash-args.ps1, which guarded the same step while it was still a `git stash`.)
#
# Why this exists, twice over:
#   1. The revert used to run `git stash push -- <files>` with the file list NESTED inside the
#      argument array. Run-Native declares [string[]]$Arguments, so a nested array arrives as ONE
#      space-joined element ("a.ts b.ts"), git rejects it as a pathspec, and any task listing two
#      or more source files reported "cannot grade" for every model. The nine original tasks list
#      one file each, so it never fired (three of the 2026-10-03 tasks list two).
#   2. refs/stash belongs to the REPOSITORY, not to a worktree. Two tasks of one repo graded at
#      the same time - two terminals, the documented way to run seats concurrently - pushed and
#      popped each other's stashes: a pop could apply the other task's source into this worktree,
#      or fail and leave this task's source reverted for the acceptance run that follows, and a
#      collision on the stash lock would read as "cannot grade". Three agents hit it independently on
#      2026-10-03. The revert now saves the model's bytes and checks the files out of the pinned
#      base, which touches nothing outside the worktree.
#
# What it does: pulls the REAL Run-Native, Set-TaskTestEnv, Restore-TaskTestEnv, Invoke-Test,
# Save-SourceFiles, Restore-SourceFiles and Invoke-WithSourceReverted out of test-tasks.ps1 (so it
# tests the harness as written, not a copy) and runs them against throwaway git repos:
#   - two files, one file and a bare string in srcRevertFiles: inside the window the listed
#     files read as the pinned base, the model's test file and any unlisted file are untouched,
#     afterwards everything is back byte for byte, and the repository's stash was never used;
#   - bytes that are not text (CRLF, a lone 0xFF, a NUL) survive the round trip;
#   - a source path the base does not have (a file the model created) is an error that never runs
#     the tests and leaves the worktree as it was;
#   - the model committed (HEAD moved off the pinned base): the pin is still what gets restored to;
#   - two worktrees of ONE repository graded at the same time, held open together by a barrier:
#     each sees its own base inside its own window and gets its own source back.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-revert-source.ps1 [-ScriptPath <path to a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$allFns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
$names = @("Run-Native", "ConvertTo-WindowsArgument", "Run-NativeTimed", "Set-TaskTestEnv", "Restore-TaskTestEnv", "Invoke-Test", "Save-SourceFiles", "Restore-SourceFiles", "Invoke-WithSourceReverted")
# Invoke-Test passes -CommandTimeout, a test-tasks.ps1 parameter: the default, here and in the job below.
$fnBlock = "`$script:CommandTimeout = 300`n"
foreach ($name in $names) {
    $fn = $allFns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    $fnBlock += ($fn.Extent.Text -replace '^function\s+', 'function script:') + "`n"
}
Invoke-Expression $fnBlock

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function B64([string]$path) {
    if (Test-Path -LiteralPath $path) { return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path)) }
    return "<absent>"
}

$psExe = (Get-Process -Id $PID).Path
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("revert-source-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

# The task's "suite": prints the bytes of the three files as they are WHILE the tests run, and how
# many stashes the repository holds. With BARRIER_ME / BARRIER_OTHER set it also holds its window
# open until the other worktree's window is open too.
$suite = @'
$b64 = { param($p) if (Test-Path -LiteralPath $p) { [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($p)) } else { "<absent>" } }
$stash = @(& git stash list 2>$null).Count
Write-Output ("SAW a=" + (& $b64 "src/a.ts") + " b=" + (& $b64 "src/b.ts") + " t=" + (& $b64 "tests/a.test.ts") + " stash=" + $stash)
if ($env:BARRIER_ME) {
    New-Item -ItemType File -Path $env:BARRIER_ME -Force | Out-Null
    $dead = (Get-Date).AddSeconds(90)
    while (-not (Test-Path -LiteralPath $env:BARRIER_OTHER) -and (Get-Date) -lt $dead) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $env:BARRIER_OTHER)) { Write-Output "BARRIER TIMEOUT" }
}
exit 0
'@

function New-Repo {
    $repo = Join-Path $tmpRoot ([guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $repo "src"), (Join-Path $repo "tests") -Force | Out-Null
    git -C $repo init -q
    git -C $repo config user.email "t@example.invalid"
    git -C $repo config user.name "t"
    foreach ($f in "src/a.ts", "src/b.ts", "tests/a.test.ts") { Set-Content -LiteralPath (Join-Path $repo $f) -Value "base $f" }
    Set-Content -LiteralPath (Join-Path $repo "check.ps1") -Value $suite
    git -C $repo add -A
    git -C $repo commit -q -m base
    return $repo
}

# A worktree at the pinned base with the model's edits in it. Returns the paths, the pin and the bytes.
function New-ModelWorktree($repo, [string]$name, [string]$tag) {
    $base = (git -C $repo rev-parse HEAD).Trim()
    $wt = Join-Path $tmpRoot $name
    git -C $repo worktree add -q --detach $wt $base
    $baseBytes = @{}
    foreach ($f in "src/a.ts", "src/b.ts", "tests/a.test.ts") { $baseBytes[$f] = B64 (Join-Path $wt $f) }
    # Bytes that are not text: CRLF, a lone 0xFF, a NUL - what a Windows checkout or an odd edit can leave.
    $odd = [byte[]](0x6d, 0x6f, 0x64, 0x65, 0x6c, 0x0d, 0x0a, 0xff, 0x00, 0x20) + [System.Text.Encoding]::ASCII.GetBytes($tag)
    [System.IO.File]::WriteAllBytes((Join-Path $wt "src/a.ts"), $odd)
    Set-Content -LiteralPath (Join-Path $wt "src/b.ts") -Value "model edit b $tag"
    Set-Content -LiteralPath (Join-Path $wt "tests/a.test.ts") -Value "model test $tag"
    $model = @{}
    foreach ($f in "src/a.ts", "src/b.ts", "tests/a.test.ts") { $model[$f] = B64 (Join-Path $wt $f) }
    return [pscustomobject]@{ Repo = $repo; Wt = $wt; Base = $base; BaseBytes = $baseBytes; Model = $model }
}

function New-Task($srcRevertFiles) {
    return [pscustomobject]@{ srcRevertFiles = $srcRevertFiles; testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1") }
}

function Parse-Saw($result) {
    $line = @($result.Output | Where-Object { $_ -match '^SAW ' }) | Select-Object -First 1
    $o = @{}
    if ($line) { foreach ($m in [regex]::Matches($line, '(\w+)=(\S+)')) { $o[$m.Groups[1].Value] = $m.Groups[2].Value } }
    return $o
}

try {
    Write-Host "-- shapes of srcRevertFiles"
    $cases = @(
        @{ name = "two files (array)";  src = @("src/a.ts", "src/b.ts"); reverted = @("src/a.ts", "src/b.ts") },
        @{ name = "one file (array)";   src = @("src/a.ts");             reverted = @("src/a.ts") },
        @{ name = "one file (bare string)"; src = "src/a.ts";           reverted = @("src/a.ts") }
    )
    foreach ($c in $cases) {
        $fx = New-ModelWorktree (New-Repo) ("shape-" + [guid]::NewGuid().ToString("N").Substring(0, 6)) $c.name
        $rv = Invoke-WithSourceReverted (New-Task $c.src) $fx.Wt $fx.Base
        $saw = Parse-Saw $rv.Result
        Check "$($c.name): no error, tests ran"                   ([bool](-not $rv.Error -and $rv.Result -and $rv.Result.ExitCode -eq 0)) $true
        $key = @{ "src/a.ts" = "a"; "src/b.ts" = "b" }
        foreach ($f in "src/a.ts", "src/b.ts") {
            $want = if ($c.reverted -contains $f) { $fx.BaseBytes[$f] } else { $fx.Model[$f] }
            $verb = if ($c.reverted -contains $f) { "reads as the pinned base" } else { "keeps the model's version" }
            Check "$($c.name): $f $verb inside the window"        $saw[$key[$f]] $want
        }
        Check "$($c.name): the model's test file is untouched inside the window" $saw["t"] $fx.Model["tests/a.test.ts"]
        Check "$($c.name): the stash was never used (inside the window)" $saw["stash"] "0"
        Check "$($c.name): Restored says every file is back"       $rv.Restored $true
        foreach ($f in "src/a.ts", "src/b.ts", "tests/a.test.ts") {
            Check "$($c.name): $f is back byte for byte"          (B64 (Join-Path $fx.Wt $f)) $fx.Model[$f]
        }
        Check "$($c.name): the repository's stash is empty afterwards" (@(git -C $fx.Repo stash list).Count) 0
    }

    Write-Host "-- a source path the base does not have (a file the model created)"
    $fx = New-ModelWorktree (New-Repo) "created" "created"
    Set-Content -LiteralPath (Join-Path $fx.Wt "src/new.ts") -Value "the model made this"
    $newBytes = B64 (Join-Path $fx.Wt "src/new.ts")
    $rv = Invoke-WithSourceReverted (New-Task @("src/a.ts", "src/new.ts")) $fx.Wt $fx.Base
    Check "an unknown path is an error that names git"            ([bool]($rv.Error -match "git checkout")) $true
    Check "...and the tests never ran"                            ([bool]($null -eq $rv.Result)) $true
    Check "...and nothing was reverted: src/a.ts is the model's"  (B64 (Join-Path $fx.Wt "src/a.ts")) $fx.Model["src/a.ts"]
    Check "...and the created file is still there, untouched"     (B64 (Join-Path $fx.Wt "src/new.ts")) $newBytes
    Check "...and Restored is true"                               $rv.Restored $true

    Write-Host "-- the model committed (HEAD moved off the pinned base)"
    $fx = New-ModelWorktree (New-Repo) "committed" "committed"
    git -C $fx.Wt add -A
    git -C $fx.Wt -c user.email=t@example.invalid -c user.name=t commit -q -m "the model ignored 'do not commit'"
    $rv = Invoke-WithSourceReverted (New-Task @("src/a.ts")) $fx.Wt $fx.Base
    $saw = Parse-Saw $rv.Result
    Check "src/a.ts reads as the PINNED base, not as the model's commit" $saw["a"] $fx.BaseBytes["src/a.ts"]
    Check "...and the model's version is back afterwards"         (B64 (Join-Path $fx.Wt "src/a.ts")) $fx.Model["src/a.ts"]

    Write-Host "-- two worktrees of ONE repository graded at the same time"
    $repo = New-Repo
    $fa = New-ModelWorktree $repo "conc-a" "task A"
    $fb = New-ModelWorktree $repo "conc-b" "task B"
    $flagA = Join-Path $tmpRoot "flag-a"; $flagB = Join-Path $tmpRoot "flag-b"
    $job = Start-Job -ScriptBlock {
        param($fnBlock, $wt, $base, $me, $other, $psExe)
        $ErrorActionPreference = "Stop"
        Invoke-Expression $fnBlock
        $env:BARRIER_ME = $me; $env:BARRIER_OTHER = $other
        $tk = [pscustomobject]@{ srcRevertFiles = @("src/a.ts"); testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1") }
        $rv = Invoke-WithSourceReverted $tk $wt $base
        return [pscustomobject]@{ Output = @($rv.Result.Output); Restored = $rv.Restored; Error = $rv.Error }
    } -ArgumentList $fnBlock, $fb.Wt, $fb.Base, $flagB, $flagA, $psExe
    $env:BARRIER_ME = $flagA; $env:BARRIER_OTHER = $flagB
    try { $rvA = Invoke-WithSourceReverted (New-Task @("src/a.ts")) $fa.Wt $fa.Base } finally { Remove-Item Env:BARRIER_ME, Env:BARRIER_OTHER -ErrorAction SilentlyContinue }
    $null = Wait-Job $job -Timeout 120
    $rvB = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $sawA = Parse-Saw $rvA.Result
    $sawB = Parse-Saw ([pscustomobject]@{ Output = $rvB.Output })
    Check "both windows were open together (no barrier timeout)"  ([bool](-not (@($rvA.Result.Output) -contains "BARRIER TIMEOUT") -and -not (@($rvB.Output) -contains "BARRIER TIMEOUT"))) $true
    Check "task A saw its own base source inside its window"      $sawA["a"] $fa.BaseBytes["src/a.ts"]
    Check "task B saw its own base source inside its window"      $sawB["a"] $fb.BaseBytes["src/a.ts"]
    Check "the stash was never used (A's window)"                 $sawA["stash"] "0"
    Check "the stash was never used (B's window)"                 $sawB["stash"] "0"
    Check "task A got its own source back byte for byte"          (B64 (Join-Path $fa.Wt "src/a.ts")) $fa.Model["src/a.ts"]
    Check "task B got its own source back byte for byte"          (B64 (Join-Path $fb.Wt "src/a.ts")) $fb.Model["src/a.ts"]
    Check "neither run reports a restore problem or an error"     ([bool]($rvA.Restored -and $rvB.Restored -and -not $rvA.Error -and -not $rvB.Error)) $true
    Check "the shared repository's stash is empty afterwards"     (@(git -C $repo stash list).Count) 0
} finally {
    Remove-Item Env:BARRIER_ME, Env:BARRIER_OTHER -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 } else { Write-Host "RESULT: all checks passed" }

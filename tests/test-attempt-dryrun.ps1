# protects: desktop/scripts/attempt-dryrun.ps1, step 1 of containerised runs: each phase's docker flags (limits, no capabilities, read-only root, grading with --network none and a read-only cache, the bundle read-only), no secrets folder, home or task repo mounted, the sealed checkout script, the report
# run-after: desktop/scripts/attempt-dryrun.ps1, desktop/docker/attempt/attempt.dockerfile, docs/container-runs.md's phases or limits
# mutation: desktop/scripts/attempt-dryrun.ps1
# mutation-from: $a += @("--network", "none", "-v", "${CacheVolume}:/cache:ro")
# mutation-to: $a += @("-v", "${CacheVolume}:/cache:ro")
# mutation-expect: FAIL\s+grading runs with --network none
# mutation: desktop/scripts/attempt-dryrun.ps1
# mutation-from: "-v", "${Bundle}:/in/base.bundle:ro")
# mutation-to: "-v", "${Bundle}:/in/base.bundle")
# mutation-expect: FAIL\s+the bundle is mounted read-only
# mutation: desktop/scripts/attempt-dryrun.ps1
# mutation-from:         "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--read-only",
# mutation-to:         "--security-opt", "no-new-privileges:true", "--read-only",
# mutation-expect: FAIL\s+every phase drops all capabilities
# test-attempt-dryrun.ps1 - regression guard for desktop/scripts/attempt-dryrun.ps1 (docs/container-runs.md, step 1).
#
# Why this exists: the point of the attempt container is what it cannot reach. A phase that lost --network none, a
# writable bundle, or a home folder mounted by mistake would still run and pass its baseline, so only the flags show it.
# What it does: runs the REAL script against a stand-in `docker` (a pwsh script passed as -Docker) that logs every call
# and plays each one's part (an image id, the versions, the phase output with its timing markers, an exit code), on a
# throwaway task repo whose sealed bundle the harness's own Get-CommitBundle makes (a copy of test-tasks.ps1, so the bundle
# lands in a temp .worktrees). It checks, for every phase: the limits, --cap-drop ALL, no-new-privileges, a read-only root,
# the label; install: the network given and the bundle read-only; grading: --network none, the cache read-only, no bundle
# and no environment; that no mount is a secrets folder, an ssh folder, the home folder or the task repo; the volume removed
# (kept with -KeepVolume); the phase scripts (the sealed fetch, the repo's own settings, the install and test commands,
# quoting); and the report (versions, seconds, the baseline, the exit code), with a failing baseline and a failing install.
#
# Usage:  pwsh -NoProfile -File tests/test-attempt-dryrun.ps1
$ErrorActionPreference = "Stop"
$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")

$repoRoot = Split-Path $PSScriptRoot -Parent
$script = Join-Path $repoRoot "desktop/scripts/attempt-dryrun.ps1"
. $script

Write-Host "-- the functions"
Check "ConvertTo-ShArg quotes a single quote" (ConvertTo-ShArg "it's") "'it'\''s'"
$s = Get-StepSeconds -Lines @("@@ clone 100.0", "x", "@@ install 100.5", "@@ setup 103.04", "@@ done 103.2")
Check "Get-StepSeconds: each step until the next marker" ("{0}|{1}|{2}" -f $s.clone, $s.install, $s.setup) "0.5|2.5|0.2"

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("attempt-dry-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
$psExe = (Get-Process -Id $PID).Path
try {
    New-Item -ItemType Directory -Force (Join-Path $tmp "harness") | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "test-tasks.ps1") -Destination (Join-Path $tmp "harness/test-tasks.ps1")
    $repo = Join-Path $tmp "task repo"
    New-Item -ItemType Directory -Force (Join-Path $repo "app") | Out-Null
    git -C $repo init -q; git -C $repo config core.autocrlf false; git -C $repo config user.email "t@example.invalid"; git -C $repo config user.name "t"
    Set-Content -LiteralPath (Join-Path $repo "app/a.txt") -Value "base"
    git -C $repo add -A; git -C $repo commit -q -m base
    $sha = (git -C $repo rev-parse HEAD).Trim()
    # Not $task: dot-sourcing the script declared its [string]$Task, and PowerShell names ignore case.
    $fxTask = [ordered]@{ id = "fx"; repo = $repo; benchBaseCommit = $sha; packageManager = "npm"; installFlags = @("--ignore-scripts")
        testDir = "app"; testCmd = @("npx", "vitest", "run", "src/it's.test.ts")
        setup = @([ordered]@{ cwd = "app"; cmd = @("node", "seed.js"); copy = @(".env.example", "cfg/.env") }) }
    $manifest = Join-Path $tmp "manifest.json"
    @{ tasks = @($fxTask) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest

    # The stand-in docker: one JSON line per call to FX_DOCKER_LOG, then the part each call plays.
    $stand = Join-Path $tmp "docker.ps1"
    @'
$log = $env:FX_DOCKER_LOG
(@($args | ForEach-Object { "$_" }) | ConvertTo-Json -Compress -AsArray) | Add-Content -LiteralPath $log
$a = @($args | ForEach-Object { "$_" })
if ($a[0] -eq "image" -and $a[1] -eq "inspect") { if ($a -contains "--format") { "sha256:fakeimage0000000000000000" }; exit 0 }
if ($a[0] -eq "volume") { if ($a[1] -eq "create") { $a[-1] }; exit 0 }
if ($a[0] -eq "build") { exit 0 }
if ($a[0] -eq "run") {
    if ($a -contains "/out/install.sh") { "@@ clone 100.0"; "commits 1"; "@@ install 100.5"; "@@ setup 103.0"; "@@ done 103.2"; exit ([int]("0" + $env:FX_INSTALL_EXIT)) }
    if ($a -contains "/out/grade.sh") { "@@ test 200.0"; "      Tests  1 passed (1)"; "@@ done 201.5"; exit ([int]("0" + $env:FX_GRADE_EXIT)) }
    "opencode opencode v2.3.2"; "rg ripgrep 14.1.1 (rev 4649aa9700)"; "node v22.23.5"; exit 0
}
exit 0
'@ | Set-Content -LiteralPath $stand

    function Invoke-Dry([string]$Name, [string[]]$Extra = @(), [hashtable]$EnvVars = @{}) {
        $out = Join-Path $tmp "out-$Name"
        $env:FX_DOCKER_LOG = Join-Path $tmp "docker-$Name.log"
        foreach ($k in $EnvVars.Keys) { Set-Item "Env:$k" $EnvVars[$k] }
        $text = & $psExe -NoProfile -File $script -Task fx -TaskManifest $manifest -Out $out -Docker $stand -HarnessScript (Join-Path $tmp "harness/test-tasks.ps1") @Extra *>&1 | Out-String
        $exit = $LASTEXITCODE
        foreach ($k in $EnvVars.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
        if (-not (Test-Path -LiteralPath $env:FX_DOCKER_LOG)) { Write-Host "FAIL $Name`: docker was never called (exit $exit)"; Write-Host $text; $script:fail++; return [pscustomobject]@{ Exit = $exit; Text = $text; Calls = @(); Report = $null; Out = $out } }
        $calls = @(Get-Content -LiteralPath $env:FX_DOCKER_LOG | ForEach-Object { , @($_ | ConvertFrom-Json) })
        $report = if (Test-Path (Join-Path $out "report.json")) { Get-Content -Raw (Join-Path $out "report.json") | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ Exit = $exit; Text = $text; Calls = $calls; Report = $report; Out = $out }
    }
    $phase = { param($calls, $p) @($calls | Where-Object { $_[0] -eq "run" -and ($_ -contains "/out/$p.sh") }) }
    $flag = { param($c, $f) $i = [array]::IndexOf([string[]]$c, $f); if ($i -ge 0 -and $i + 1 -lt $c.Count) { $c[$i + 1] } else { $null } }
    $mounts = { param($c) @(for ($i = 0; $i -lt $c.Count - 1; $i++) { if ($c[$i] -eq "-v") { $c[$i + 1] } }) }

    Write-Host "-- a dry run, volume and bind mount"
    $r = Invoke-Dry "ok" @("-InstallNetwork", "proxy-net", "-InstallEnv", "HTTPS_PROXY=http://attempt-proxy:3128")
    if ($r.Exit -ne 0) { Write-Host $r.Text }
    Check "exit 0: the install worked and the baseline passed" $r.Exit 0
    $inst = & $phase $r.Calls "install"; $grade = & $phase $r.Calls "grade"
    Check "two install and two grade phases (volume, bind)" ("{0}|{1}" -f $inst.Count, $grade.Count) "2|2"
    $all = @($inst) + @($grade)
    Check "every phase drops all capabilities" (@($all | Where-Object { (& $flag $_ "--cap-drop") -eq "ALL" }).Count) 4
    Check "every phase: no-new-privileges, a read-only root, --rm" (@($all | Where-Object { (& $flag $_ "--security-opt") -eq "no-new-privileges:true" -and $_ -contains "--read-only" -and $_ -contains "--rm" }).Count) 4
    Check "every phase: memory, cpus and 1024 pids" (@($all | Where-Object { (& $flag $_ "--memory") -eq "6g" -and (& $flag $_ "--cpus") -eq "4" -and (& $flag $_ "--pids-limit") -eq "1024" }).Count) 4
    Check "every phase is labelled with the run" (@($all | Where-Object { (& $flag $_ "--label") -match '^homelab\.attempt=dry-fx-\d{8}-\d{6}$' }).Count) 4
    Check "grading runs with --network none" (@($grade | Where-Object { (& $flag $_ "--network") -eq "none" }).Count) 2
    Check "grading has the cache read-only, no bundle, no environment" (@($grade | Where-Object { $m = & $mounts $_; ($m -contains "homelab-attempt-cache:/cache:ro") -and -not ($m | Where-Object { $_ -match 'base\.bundle' }) -and -not ($_ -contains "-e") }).Count) 2
    Check "install runs on the network it was given, with its environment" (@($inst | Where-Object { (& $flag $_ "--network") -eq "proxy-net" -and (& $flag $_ "-e") -eq "HTTPS_PROXY=http://attempt-proxy:3128" }).Count) 2
    Check "the bundle is mounted read-only" (@($inst | Where-Object { @(& $mounts $_ | Where-Object { $_ -match "\.bundles[\\/]$sha\.bundle:/in/base\.bundle:ro$" }).Count -eq 1 }).Count) 2
    $homeDir = [Environment]::GetFolderPath("UserProfile").TrimEnd('\', '/')
    $badMounts = @($r.Calls | ForEach-Object { & $mounts $_ } | Where-Object { $src = ($_ -replace ':/[^:]*(:ro)?$', ''); $src -match '(?i)\.secrets|\.ssh|\.config[\\/]opencode' -or $src.TrimEnd('\', '/') -eq $homeDir -or $src.StartsWith($repo) })
    Check "no mount is a secrets folder, an ssh folder, the home folder or the task repo" ($badMounts -join ", ") ""
    Check "the volume checkout is a named volume, the bind one a folder under -Out" ("{0}|{1}" -f [bool](@($inst[0] | Where-Object { $_ -match '^homelab-dry-fx-\d{8}-\d{6}:/work$' }).Count), [bool](@($inst[1] | Where-Object { $_ -match 'bind-work:/work$' }).Count)) "True|True"
    Check "the work volume is removed afterwards" (@($r.Calls | Where-Object { $_[0] -eq "volume" -and $_[1] -eq "rm" -and $_[-1] -match '^homelab-dry-fx-' }).Count) 1
    Check "the versions are read with no network" (@($r.Calls | Where-Object { $_[0] -eq "run" -and $_ -contains "sh" -and (& $flag $_ "--network") -eq "none" }).Count) 1

    Write-Host "-- the phase scripts"
    $is = Get-Content -Raw (Join-Path $r.Out "install.sh")
    Check "install: the sealed fetch of the one ref, no tags" ($is.Contains("git fetch -q --no-tags /in/base.bundle 'refs/homelab-seal/$sha'")) "True"
    Check "install: a detached checkout of the base" ($is.Contains("git checkout -q --force --detach '$sha'")) "True"
    Check "install: the task repo's own settings" ($is.Contains("git config 'core.autocrlf' 'false'") -and $is.Contains("git config 'user.name' 't'")) "True"
    Check "install: npm ci with the task's flags" ($is.Contains("'npm' 'ci' '--ignore-scripts'")) "True"
    Check "install: the setup step in its folder, and its copy" ($is.Contains("(cd '/work/repo/app' && 'node' 'seed.js')") -and $is.Contains("cp -f '.env.example' 'cfg/.env'")) "True"
    $gs = Get-Content -Raw (Join-Path $r.Out "grade.sh")
    Check "grade: the test command in testDir, quoted" ($gs.Contains("cd '/work/repo/app'") -and $gs.Contains("'npx' 'vitest' 'run' 'src/it'\''s.test.ts'")) "True"

    Write-Host "-- the report"
    $v = $r.Report.checkouts.volume
    Check "versions from inside the image" ("{0}|{1}|{2}" -f $r.Report.versions.opencode, $r.Report.versions.node, $r.Report.image.id) "2.3.2|v22.23.5|sha256:fakeimage0000000000000000"
    Check "the volume's seconds per step, commits, baseline" ("{0}|{1}|{2}|{3}|{4}" -f $v.cloneSec, $v.installSec, $v.testSec, $v.commits, $v.baseline) "0.5|2.5|1.5|1|PASS"
    Check "the bind mount is reported beside it" $r.Report.checkouts.bind.baseline "PASS"

    Write-Host "-- failures, and the switches"
    $r = Invoke-Dry "red" @() @{ FX_GRADE_EXIT = "1" }
    Check "a failing baseline: exit 1, FAIL in the report" ("{0}|{1}" -f $r.Exit, $r.Report.checkouts.volume.baseline) "1|FAIL"
    $r = Invoke-Dry "noinst" @("-SkipBindCompare") @{ FX_INSTALL_EXIT = "1" }
    Check "a failing install: exit 1, no grading run, 'not run'" ("{0}|{1}|{2}" -f $r.Exit, (& $phase $r.Calls "grade").Count, $r.Report.checkouts.volume.baseline) "1|0|not run"
    Check "-SkipBindCompare: no bind checkout" ($null -eq $r.Report.checkouts.bind) "True"
    $r = Invoke-Dry "keep" @("-SkipBindCompare", "-KeepVolume")
    Check "-KeepVolume: the work volume stays" (@($r.Calls | Where-Object { $_[0] -eq "volume" -and $_[1] -eq "rm" }).Count) 0
    $r = Invoke-Dry "build" @("-SkipBindCompare", "-Build")
    Check "-Build: builds the image with the pinned OpenCode" (@($r.Calls | Where-Object { $_[0] -eq "build" -and $_ -contains "OPENCODE_VERSION=2.3.2" -and ($_ | Where-Object { $_ -match 'attempt\.dockerfile$' }) }).Count) 1
    $out = & $psExe -NoProfile -File $script -Docker $stand *>&1 | Out-String
    Check "no -Task: refused with its reason" ([bool]($out -match '-Task is required')) "True"
} finally {
    Remove-Item Env:FX_DOCKER_LOG -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

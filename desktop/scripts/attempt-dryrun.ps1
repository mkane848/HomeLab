# attempt-dryrun.ps1 - step 1 of containerised task runs (docs/container-runs.md, "Building it"): the attempt image and
# a dry run with NO model. For one task of the manifest:
#   1. the image: build attempt:1 if asked or missing, and read OpenCode's, ripgrep's and node's versions from inside it;
#   2. phase 1 (checkout and install): clone the task's sealed bundle (the harness's own, tests/.worktrees/.bundles) into
#      a per-attempt Docker volume, as Initialize-SealedCheckout does on the host, then install and run the setup steps;
#   3. phase 3 (grading), with --network none: the task's test command on the untouched base, the baseline;
#   4. the same two phases with the checkout in a host folder (a bind mount) instead of the volume, timed side by side,
#      to settle "The checkout: a volume, not a Windows folder" with numbers (on Docker Desktop, NTFS into Linux).
# Phase 2, the agent, is step 3 of the design, with the proxy. So here phase 1 has the network -InstallNetwork names
# (default: Docker's bridge), and nothing else is allowlisted yet.
#
# Every phase runs as the image's user (uid 1001) with --memory, --cpus, --pids-limit 1024, --cap-drop ALL,
# no-new-privileges, a read-only root filesystem and tmpfs for /tmp and HOME. The only host paths mounted are the
# bundle (read-only, phase 1) and this run's output folder (/out). No secrets folder, no home directory, no task repo.
#
#   pwsh -File desktop\scripts\attempt-dryrun.ps1 -Task lfc-03 [-TaskManifest <manifest>] [-Build] [-Out <folder>]
#        [-SkipBindCompare] [-KeepVolume] [-Memory 6g] [-Cpus 4]
#
# Output: <Out>\report.json (versions, the image id, per checkout kind: clone, install, setup and baseline seconds, the
# baseline's exit and summary) and the phase logs. Exit 0 when the volume's install worked and its baseline passed.
# Guard: tests/test-attempt-dryrun.ps1 (a stand-in docker; the flags of every call).
param(
    [string]$Task = "",
    [string]$TaskManifest = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "tests\tasks\manifest.json"),
    [string]$Image = "attempt:1",
    [switch]$Build,
    [string]$OpencodeVersion = "2.3.2",
    [string[]]$BuildArgs = @(),
    [string]$Out = "",
    [string]$Memory = "6g",
    [string]$Cpus = "4",
    [string]$InstallNetwork = "bridge",
    [string[]]$InstallEnv = @(),
    [switch]$SkipBindCompare,
    [switch]$KeepVolume,
    [string]$Docker = "docker",
    [string]$HarnessScript = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "tests\test-tasks.ps1")
)

function ConvertTo-ShArg([string]$s) {
    # One word for bash, single-quoted.
    return "'" + $s.Replace("'", "'\''") + "'"
}

function Get-AttemptRunArgs {
    # The `docker run` arguments for one phase of an attempt. -Work is a volume name or a host folder; -Phase is
    # "install" (the bundle read-only, the cache writable, the network given) or "grade" (--network none, the cache
    # read-only, no bundle, no extra environment). -Script is the phase script's path inside /out.
    param([ValidateSet("install", "grade")][string]$Phase, [string]$Image, [string]$Name, [string]$Label, [string]$Work,
          [string]$OutDir, [string]$CacheVolume, [string]$Bundle = "", [string]$Network = "bridge", [string[]]$Env = @(),
          [string]$Memory = "6g", [string]$Cpus = "4", [string]$Script)
    $a = @("run", "--rm", "--name", $Name, "--label", "homelab.attempt=$Label",
        "--memory", $Memory, "--cpus", $Cpus, "--pids-limit", "1024",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--read-only",
        "--tmpfs", "/tmp:rw,exec,size=2g", "--tmpfs", "/home/attempt:rw,exec,size=512m,uid=1001,gid=1001",
        "-v", "${Work}:/work", "-v", "${OutDir}:/out")
    if ($Phase -eq "install") {
        $a += @("--network", $Network, "-v", "${CacheVolume}:/cache", "-v", "${Bundle}:/in/base.bundle:ro")
        foreach ($e in $Env) { $a += @("-e", $e) }
    } else {
        $a += @("--network", "none", "-v", "${CacheVolume}:/cache:ro")
    }
    return @($a + @($Image, "bash", $Script))
}

function New-InstallScript {
    # Phase 1's bash: the sealed checkout (git init, the task repo's own line-ending and identity settings, the one
    # commit from the bundle, detached), then the install and the setup steps, as Install-TaskDependencies runs them.
    # "@@ <step> <epoch>" lines time each step.
    param($Task, [string]$Sha, [string]$Ref, [hashtable]$RepoConfig = @{})
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('set -euo pipefail'); $L.Add('t() { echo "@@ $1 $(date +%s.%N)"; }')
    $L.Add('t clone'); $L.Add('rm -rf /work/repo && git init -q /work/repo && cd /work/repo')
    foreach ($k in ($RepoConfig.Keys | Sort-Object)) { $L.Add("git config $(ConvertTo-ShArg $k) $(ConvertTo-ShArg $RepoConfig[$k])") }
    $L.Add("git fetch -q --no-tags /in/base.bundle $(ConvertTo-ShArg $Ref)")
    $L.Add("git checkout -q --force --detach $(ConvertTo-ShArg $Sha)")
    $L.Add('echo "commits $(git rev-list --count --all)"')
    $pm = if ($Task.packageManager) { $Task.packageManager } else { "pnpm" }
    $verb = if ($pm -eq "npm") { "ci" } else { "install" }
    $L.Add('t install'); $L.Add((@($pm, $verb) + @($Task.installFlags) | Where-Object { "$_" } | ForEach-Object { ConvertTo-ShArg "$_" }) -join ' ')
    $L.Add('t setup')
    foreach ($step in @($Task.setup | Where-Object { $_ })) {
        $cwd = if ($step.cwd) { "/work/repo/$($step.cwd)" } else { "/work/repo" }
        $L.Add("(cd $(ConvertTo-ShArg $cwd) && $((@($step.cmd) | ForEach-Object { ConvertTo-ShArg "$_" }) -join ' '))")
        if ($step.copy) { $L.Add("(cd $(ConvertTo-ShArg $cwd) && if [ -e $(ConvertTo-ShArg $step.copy[0]) ]; then mkdir -p `"`$(dirname $(ConvertTo-ShArg $step.copy[1]))`" && cp -f $(ConvertTo-ShArg $step.copy[0]) $(ConvertTo-ShArg $step.copy[1]); fi)") }
    }
    $L.Add('t done')
    return ($L -join "`n") + "`n"
}

function New-GradeScript {
    # Phase 3's bash: the task's test command in its testDir, on the untouched base. Its exit is the script's.
    param($Task)
    $dir = if ($Task.testDir -and $Task.testDir -ne ".") { "/work/repo/$($Task.testDir)" } else { "/work/repo" }
    return @('t() { echo "@@ $1 $(date +%s.%N)"; }', 't test', "cd $(ConvertTo-ShArg $dir)",
        ((@($Task.testCmd) | ForEach-Object { ConvertTo-ShArg "$_" }) -join ' '), 'rc=$?', 't done', 'exit $rc') -join "`n"
}

function Get-StepSeconds {
    # "@@ <step> <epoch>" markers -> seconds per step (each step until the next marker).
    param([string[]]$Lines)
    $marks = @($Lines | ForEach-Object { if ("$_" -match '^@@ (\S+) ([0-9.]+)$') { [pscustomobject]@{ Step = $Matches[1]; T = [double]$Matches[2] } } })
    $out = [ordered]@{}
    for ($i = 0; $i -lt $marks.Count - 1; $i++) { $out[$marks[$i].Step] = [math]::Round($marks[$i + 1].T - $marks[$i].T, 1) }
    return $out
}

# --- everything below runs only when the script is run, not when a guard dot-sources it for the functions ---
if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = "Stop"
if (-not $Task) { Write-Host "ERROR: -Task is required" -ForegroundColor Red; exit 3 }
if (-not (Test-Path -LiteralPath $TaskManifest)) { Write-Host "ERROR: no manifest at $TaskManifest" -ForegroundColor Red; exit 1 }
$tk = @((Get-Content -Raw -LiteralPath $TaskManifest | ConvertFrom-Json).tasks | Where-Object id -eq $Task) | Select-Object -First 1
if (-not $tk) { Write-Host "ERROR: no task $Task in $TaskManifest" -ForegroundColor Red; exit 1 }
foreach ($f in "repo", "benchBaseCommit", "testCmd") { if (-not $tk.$f) { Write-Host "ERROR: task $Task has no $f" -ForegroundColor Red; exit 1 } }

# The harness's own bundle builder (and Run-Native, which it calls), so the container gets the very file the host would.
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HarnessScript, [ref]$null, [ref]$errs)
foreach ($name in "Run-Native", "Get-CommitBundle") {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { Write-Host "ERROR: $name not found in $HarnessScript" -ForegroundColor Red; exit 1 }
    Invoke-Expression $fn.Extent.Text
}
$wtRoot = Join-Path (Split-Path $HarnessScript) ".worktrees"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runId = "dry-$($Task -replace '[^A-Za-z0-9_.-]', '-')-$stamp"
if (-not $Out) { $Out = Join-Path ([IO.Path]::GetTempPath()) "attempt-$runId" }
New-Item -ItemType Directory -Force $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
# stderr lines come back as ErrorRecords; their TargetObject is the line itself (an empty one would read as the type name).
$dock = { param([string[]]$A) $o = & $Docker @A 2>&1; [pscustomobject]@{ Exit = $LASTEXITCODE; Output = @($o | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { "$($_.TargetObject)" } else { "$_" } }) } }

# 1. The image.
$have = & $dock @("image", "inspect", "--format", "{{.Id}}", $Image)
if ($Build -or $have.Exit -ne 0) {
    $base = & $dock @("image", "inspect", "dev-base:1")
    if ($base.Exit -ne 0) { Write-Host "ERROR: dev-base:1 is missing; build it first: .\desktop\scripts\docker-base.ps1" -ForegroundColor Red; exit 1 }
    $ctx = Join-Path (Split-Path (Split-Path $PSScriptRoot)) "desktop\docker\attempt"
    $ba = @("build", "-t", $Image, "--build-arg", "OPENCODE_VERSION=$OpencodeVersion") + @($BuildArgs | ForEach-Object { @("--build-arg", $_) }) + @("-f", (Join-Path $ctx "attempt.dockerfile"), $ctx)
    Write-Host "[dry-run] building $Image (OpenCode $OpencodeVersion)..." -ForegroundColor Cyan
    $b = & $dock $ba
    $b.Output | Set-Content -LiteralPath (Join-Path $Out "build.log")
    if ($b.Exit -ne 0) { Write-Host "ERROR: docker build failed (see $Out\build.log)" -ForegroundColor Red; exit 1 }
    $have = & $dock @("image", "inspect", "--format", "{{.Id}}", $Image)
}
$imageId = "$($have.Output | Select-Object -First 1)".Trim()
if ($have.Exit -ne 0 -or -not $imageId) { Write-Host "ERROR: no image $Image after the build (docker image inspect: $($have.Output -join ' '))" -ForegroundColor Red; exit 1 }
$ver = & $dock @("run", "--rm", "--network", "none", $Image, "sh", "-c", 'echo "opencode $(opencode --version)"; echo "rg $(rg --version | head -1)"; echo "node $(node --version)"')
$versions = [ordered]@{}
foreach ($l in $ver.Output) { if ($l -match '^(opencode|rg|node) (.+)$') { $versions[$Matches[1]] = ($Matches[2] -replace '^opencode\s+v', '').Trim() } }
Write-Host ("[dry-run] {0} ({1}): opencode {2}, {3}, node {4}" -f $Image, $imageId.Substring(0, [Math]::Min(19, $imageId.Length)), $versions.opencode, $versions.rg, $versions.node)

# 2-4. The bundle, then each kind of checkout.
$bundle = Get-CommitBundle -Repo $tk.repo -Sha $tk.benchBaseCommit
if (-not $bundle.Path) { Write-Host "ERROR: $($bundle.Error)" -ForegroundColor Red; exit 1 }
$repoConfig = @{}
foreach ($key in "core.autocrlf", "core.eol", "core.longpaths", "user.name", "user.email") {
    $v = (Run-Native "git" @("-C", $tk.repo, "config", "--get", $key)).Output | Select-Object -First 1
    if ($v) { $repoConfig[$key] = "$v".Trim() }
}
[IO.File]::WriteAllText((Join-Path $Out "install.sh"), (New-InstallScript -Task $tk -Sha $tk.benchBaseCommit -Ref $bundle.Ref -RepoConfig $repoConfig))
[IO.File]::WriteAllText((Join-Path $Out "grade.sh"), (New-GradeScript -Task $tk))
$cache = "homelab-attempt-cache"
$null = & $dock @("volume", "create", "--label", "homelab.attempt=cache", $cache)

$kinds = @("volume") + $(if ($SkipBindCompare) { @() } else { @("bind") })
$results = [ordered]@{}
foreach ($kind in $kinds) {
    if ($kind -eq "volume") {
        $work = "homelab-$runId"
        $null = & $dock @("volume", "create", "--label", "homelab.attempt=$runId", $work)
    } else {
        $work = Join-Path $Out "bind-work"
        New-Item -ItemType Directory -Force $work | Out-Null
        # On a Linux host the container's uid 1001 must be able to write it; Docker Desktop maps it by itself.
        if (-not $IsWindows) { & chmod 0777 $work }
    }
    $r = [ordered]@{ work = $kind }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p1 = & $dock (Get-AttemptRunArgs -Phase install -Image $Image -Name "$runId-$kind-install" -Label $runId -Work $work -OutDir $Out -CacheVolume $cache -Bundle $bundle.Path -Network $InstallNetwork -Env $InstallEnv -Memory $Memory -Cpus $Cpus -Script "/out/install.sh")
    $r.installPhaseSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $p1.Output | Set-Content -LiteralPath (Join-Path $Out "$kind-install.log")
    $steps = Get-StepSeconds -Lines $p1.Output
    foreach ($k in $steps.Keys) { $r["${k}Sec"] = $steps[$k] }
    $r.installExit = $p1.Exit
    $c = @($p1.Output | Where-Object { $_ -match '^commits (\d+)$' } | Select-Object -First 1)
    if ($c) { $r.commits = [int]($c[0] -replace '^commits ', '') }
    if ($p1.Exit -eq 0) {
        $sw.Restart()
        $p3 = & $dock (Get-AttemptRunArgs -Phase grade -Image $Image -Name "$runId-$kind-grade" -Label $runId -Work $work -OutDir $Out -CacheVolume $cache -Memory $Memory -Cpus $Cpus -Script "/out/grade.sh")
        $r.gradePhaseSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $p3.Output | Set-Content -LiteralPath (Join-Path $Out "$kind-grade.log")
        $r.testSec = (Get-StepSeconds -Lines $p3.Output)["test"]
        $r.baselineExit = $p3.Exit
        $r.baseline = if ($p3.Exit -eq 0) { "PASS" } else { "FAIL" }
        $r.summary = (@($p3.Output | Where-Object { $_ -match '^\s*Tests\s+' } | ForEach-Object { $_.Trim() }) -join " | ")
    } else {
        $r.baseline = "not run"; $r.summary = ($p1.Output | Select-Object -Last 3) -join " | "
    }
    if ($kind -eq "volume" -and -not $KeepVolume) { $null = & $dock @("volume", "rm", "-f", $work) }
    if ($kind -eq "bind") { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    $results[$kind] = [pscustomobject]$r
    Write-Host ("[dry-run] {0,-6}: install exit {1} ({2} s), baseline {3} ({4} s) {5}" -f $kind, $r.installExit, $r.installPhaseSec, $r.baseline, $r.gradePhaseSec, $r.summary)
}

$report = [ordered]@{ task = $Task; base = $tk.benchBaseCommit; image = [ordered]@{ tag = $Image; id = $imageId }; versions = $versions
    installNetwork = $InstallNetwork; limits = [ordered]@{ memory = $Memory; cpus = $Cpus; pids = 1024 }; checkouts = $results; when = (Get-Date -Format o) }
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Out "report.json")
Write-Host "[dry-run] report: $(Join-Path $Out 'report.json')"
$v = $results["volume"]
exit $(if ($v.installExit -eq 0 -and $v.baseline -eq "PASS") { 0 } else { 1 })

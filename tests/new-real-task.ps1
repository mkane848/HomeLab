# new-real-task.ps1 - one real task from the owner, from request to a branch to review (Step 2 of "from experiments to
# real work", 2026-11-02; docs/planner-tests-experiment.md, "Real work").
#
# Real work has no hidden tests: the owner's confirmed done list is the spec, the planner's Gate tests decide merge or
# retry, the Ideal tests are measured, and the owner's review of the delivered branch is the truth. Each step is run
# separately, because the owner confirms the list between "done" and "tests":
#
#   add      a task in the REAL-WORK manifest (HomeLab-private/tasks/real-work/manifest.json, not the benchmark's
#            manifest.json, which build_manifest.py regenerates): base = the repository's HEAD, grading "checklist"
#            (no hidden tests), its checklist = the confirmed DONE.md, the test command copied from a benchmark task
#            of the same repository (or -TestCmd).
#   done     the planner writes DONE.md (run-planner.ps1 -Phase done, in the container); copied to
#            real-work/<id>/1/DONE.md and shown. The owner reviews it; planner_done.py confirm records that.
#   tests    the planner writes the Gate and Ideal tests from the confirmed list (-Phase tests refuses an unconfirmed
#            one); copied to real-work/<id>/1/ and 1-ideal/.
#   run      run-retries.ps1 on this machine against the server: the Gate set as the selector, the Ideal set
#            measured, up to -MaxAttempts; results in HomeLab-private/results/real-work/<id>/.
#   deliver  deliver-attempt.ps1: the accepted attempt, or the best near miss, as fleet/<id> in the repository.
#
#   pwsh -File tests\new-real-task.ps1 -Step add -Repo M:\Projects\LFCbot -Id lfc-w01 -Title "..." -Prompt "..."
#   pwsh -File tests\new-real-task.ps1 -Step done|tests|run|deliver -Id lfc-w01
# Exit 0 ok, 1 a step failed, 3 bad arguments.
param(
    [Parameter(Mandatory)][ValidateSet("add", "done", "tests", "run", "deliver")][string]$Step,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{1,40}$')][string]$Id,
    [string]$Repo = "",
    [string]$Title = "",
    [string]$Prompt = "",
    [string[]]$TestCmd = @(),
    [string]$PrivateRoot = "",
    [string]$Model = "llamacpp-server/qwen3.6:35b-a3b-coding",
    [string]$PlannerModel = "claude-opus-5-5",
    [int]$MaxAttempts = 3,
    [string]$ServerUrl = "",     # default: $env:LLAMACPP_SERVER_BASE_URL, else SERVER_IP in -EnvFile (as tests/run-window.ps1)
    [string]$EnvFile = ""
)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$repoRoot = Split-Path -Parent $here
if (-not $PrivateRoot) { $PrivateRoot = Join-Path (Split-Path -Parent $repoRoot) "HomeLab-private" }
$work = Join-Path $PrivateRoot "tasks\real-work"
$manifest = Join-Path $work "manifest.json"
$taskDir = Join-Path $work $Id
$scratch = Join-Path ([IO.Path]::GetTempPath()) "homelab-real-work\$Id"
$py = foreach ($c in "python3", "python") { $g = Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1; if ($g) { $o = & $g.Source -c "print(42)" 2>$null; if ($o -eq "42") { $g.Source; break } } }
function Fail([string]$m, [int]$code = 1) { Write-Host "ERROR: $m" -ForegroundColor Red; exit $code }
function Read-Manifest { if (Test-Path -LiteralPath $manifest) { Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json } else { [pscustomobject]@{ tasks = @() } } }
function Get-Task { $t = @((Read-Manifest).tasks | Where-Object { $_.id -eq $Id }); if (-not $t.Count) { Fail "no task $Id in $manifest (run -Step add first)" 3 }; $t[0] }
function Invoke-Pack([string[]]$extra) {
    Remove-Item -Recurse -Force (Join-Path $scratch "pack") -ErrorAction SilentlyContinue
    & $py -I (Join-Path $repoRoot "desktop\scripts\make-planner-packs.py") --manifest $manifest --out (Join-Path $scratch "pack") --tasks $Id --prompts (Join-Path $PrivateRoot "tasks\planner") @extra
    if ($LASTEXITCODE -ne 0) { Fail "make-planner-packs.py failed" }
}

switch ($Step) {
    "add" {
        if (-not $Repo -or -not (Test-Path -LiteralPath (Join-Path $Repo ".git"))) { Fail "-Repo must be a git repository" 3 }
        if (-not $Prompt) { Fail "-Prompt is required: the request in the owner's own words" 3 }
        $m = Read-Manifest
        if (@($m.tasks | Where-Object { $_.id -eq $Id }).Count) { Fail "$Id is already in $manifest" 3 }
        $repoNorm = ((Resolve-Path -LiteralPath $Repo).Path -replace '\\', '/').TrimEnd('/')
        $head = (& git -C $Repo rev-parse HEAD).Trim()
        $dirty = @(& git -C $Repo status --porcelain --untracked-files=no).Count
        if ($dirty) { Write-Host "WARN: $Repo has $dirty uncommitted change(s); the task starts from HEAD $($head.Substring(0, 7)) without them" -ForegroundColor Yellow }
        $bench = Get-Content -Raw -LiteralPath (Join-Path $PrivateRoot "tasks\manifest.json") | ConvertFrom-Json
        $tpl = @($bench.tasks | Where-Object { ($_.repo -replace '\\', '/').TrimEnd('/') -ieq $repoNorm -and $_.testCmd }) | Select-Object -First 1
        if (-not $TestCmd.Count -and -not $tpl) { Fail "no benchmark task uses ${repoNorm}: pass -TestCmd (e.g. npx,vitest,run)" 3 }
        $task = [ordered]@{
            id = $Id; title = $(if ($Title) { $Title } else { $Prompt.Substring(0, [math]::Min(60, $Prompt.Length)) })
            repo = $repoNorm; benchBaseCommit = $head; grading = "checklist"; checklist = "$Id/1/DONE.md"; scope = "guardrails"
            prompt = $Prompt; added = (Get-Date -Format o)
            testDir = $(if ($tpl) { $tpl.testDir } else { "." })
            testCmd = @($(if ($TestCmd.Count) { $TestCmd | ForEach-Object { $_ -split "," } } else { $tpl.testCmd }))
        }
        foreach ($k in "installFlags", "packageManager", "testEnv") { if ($tpl -and $tpl.PSObject.Properties[$k]) { $task[$k] = $tpl.$k } }
        New-Item -ItemType Directory -Force $work | Out-Null
        $m.tasks = @($m.tasks) + @([pscustomobject]$task)
        [IO.File]::WriteAllText($manifest, (($m | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "added ${Id}: $repoNorm at $($head.Substring(0, 7)), tests: $($task.testCmd -join ' '). Next: -Step done" -ForegroundColor Green
    }
    "done" {
        $t = Get-Task
        Invoke-Pack @()
        & pwsh -NoProfile -File (Join-Path $repoRoot "desktop\scripts\run-planner.ps1") -Pack (Join-Path $scratch "pack") -Out (Join-Path $scratch "out") -Run 1 -Tasks $Id -Model $PlannerModel -Phase done
        if ($LASTEXITCODE -ne 0) { Fail "the done phase failed" }
        $src = Join-Path $scratch "out\run1-done\work-$Id\planner\$Id\1\DONE.md"
        New-Item -ItemType Directory -Force (Join-Path $taskDir "1") | Out-Null
        Copy-Item -LiteralPath $src -Destination (Join-Path $taskDir "1\DONE.md") -Force
        Copy-Item -LiteralPath $src -Destination (Join-Path $taskDir "1\DONE.planner.md") -Force
        & $py -I (Join-Path $repoRoot "desktop\scripts\planner_done.py") show (Join-Path $taskDir "1\DONE.md")
        Write-Host "`nreview it, then: python -I desktop\scripts\planner_done.py confirm '$(Join-Path $taskDir '1\DONE.md')' --by owner; then -Step tests" -ForegroundColor Green
    }
    "tests" {
        $t = Get-Task
        Invoke-Pack @("--confirmed", $work)
        & pwsh -NoProfile -File (Join-Path $repoRoot "desktop\scripts\run-planner.ps1") -Pack (Join-Path $scratch "pack") -Out (Join-Path $scratch "out") -Run 1 -Tasks $Id -Model $PlannerModel -Phase tests
        if ($LASTEXITCODE -ne 0) { Fail "the tests phase failed" }
        $out = Join-Path $scratch "out\run1-tests\work-$Id\planner\$Id"
        foreach ($d in "1", "1-ideal") {
            if (-not (Test-Path -LiteralPath (Join-Path $out $d))) { continue }
            Get-ChildItem -LiteralPath (Join-Path $out $d) -Force | Where-Object { $_.Name -ne "DONE.md" } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $taskDir $d) -Recurse -Force }
        }
        Write-Host "Gate and Ideal tests in $taskDir\1 and 1-ideal. Next: -Step run" -ForegroundColor Green
    }
    "run" {
        $t = Get-Task
        $ok = & $py -I (Join-Path $repoRoot "desktop\scripts\planner_done.py") verify (Join-Path $taskDir "1\DONE.md")
        if ($LASTEXITCODE -ne 0) { Fail "DONE.md is not confirmed: $ok" }
        if (-not @(Get-ChildItem -LiteralPath (Join-Path $taskDir "1") -Recurse -Filter "*.test.*" -ErrorAction SilentlyContinue).Count) { Fail "no Gate tests in $taskDir\1 (run -Step tests)" }
        if (-not $ServerUrl) { $ServerUrl = $env:LLAMACPP_SERVER_BASE_URL }
        if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot ".env" }
        if (-not $ServerUrl -and (Test-Path -LiteralPath $EnvFile)) {
            $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^\s*SERVER_IP\s*=\s*\S' } | Select-Object -First 1
            if ($line) { $ServerUrl = "http://{0}:8090/v1" -f (($line -split "=", 2)[1].Trim().Trim('"').Trim("'")) }
        }
        if (-not $ServerUrl) { Fail "no server url: no -ServerUrl, no LLAMACPP_SERVER_BASE_URL, and no SERVER_IP in $EnvFile" 3 }
        $env:LLAMACPP_SERVER_BASE_URL = $ServerUrl; $env:OPENCODE_DISABLE_AUTOUPDATE = "1"; $env:GIT_TERMINAL_PROMPT = "0"
        $results = Join-Path $PrivateRoot "results\real-work\$Id"
        New-Item -ItemType Directory -Force $results | Out-Null
        $h = @{ NudgeOnStop = $true; RunTimeout = 2700; ShownPrompt = 2; StopClassifier = 3; AcceptanceDir = "$Id/1" }
        if (Test-Path -LiteralPath (Join-Path $taskDir "1-ideal")) { $h.IdealDir = "$Id/1-ideal" }
        & (Join-Path $here "run-retries.ps1") -Tasks @($Id) -Model $Model -MaxAttempts $MaxAttempts -TaskManifest $manifest -ResultsDir $results -HarnessArgs $h
        Write-Host "results in $results. Next: -Step deliver" -ForegroundColor Green
    }
    "deliver" {
        $t = Get-Task
        & pwsh -NoProfile -File (Join-Path $here "deliver-attempt.ps1") -ResultsDir (Join-Path $PrivateRoot "results\real-work\$Id") -Task $Id -Repo $t.repo
        exit $LASTEXITCODE
    }
}
exit 0

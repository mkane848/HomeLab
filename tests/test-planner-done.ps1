# protects: experiment 3's confirmation checkpoint: no planner test is written for an unconfirmed DONE.md
# run-after: desktop/scripts/planner_done.py, run-planner.ps1 or make-planner-packs.py
# test-planner-done.ps1 - regression guard for the confirmation checkpoint (docs/planner-tests-experiment.md,
# "Confirmation checkpoint", 2026-11-01).
#
# Why this exists: for a plain-language request the planner's guess at what "done" means was the error (the review
# step on real-02 rejected even the owner's own fix). So the planner first writes DONE.md, the owner keeps or strikes
# each line, and only then are tests written. The checkpoint is worth nothing if a tests run can start on a list the
# owner never confirmed, or changed after confirming. Each of those is one line in a script that a later edit can drop.
#
# What it does:
#   1. tests/test_planner_done.py: the DONE.md parser, set/confirm/verify, and make-planner-packs.py --confirmed.
#   2. run-planner.ps1 -Phase tests on a fake pack: refuses no DONE.md, an unconfirmed one and one edited after
#      confirming (exit 1, before touching Docker); a confirmed one gets past the checkpoint. Every call passes a
#      -TokenFile that does not exist, so even with Docker and the proxy up no planner session can start.
#   3. Static: the web tools stay off and the token stays out of every command line.
# Needs python (skipped, not failed, without one: the checkpoint itself needs it).
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repo "desktop/scripts/run-planner.ps1"
$doneTool = Join-Path $repo "desktop/scripts/planner_done.py"
$script:fail = 0
$script:skipped = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "PASS $name" }
    else { Write-Host "FAIL $name (got '$actual', expected '$expected')"; $script:fail++ }
}
function Has([string]$name, [string]$text, [string]$pattern) { Check $name ($text -match $pattern) "True" }

foreach ($f in $runner, $doneTool, (Join-Path $repo "desktop/scripts/make-planner-packs.py")) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "FAIL: missing $f"; exit 1 }
}

# A python that RUNS: on Windows python3 can be the Microsoft Store placeholder (on PATH, exits 49).
$python = $null
foreach ($cand in "python3", "python") {
    foreach ($c in @(Get-Command $cand -All -ErrorAction SilentlyContinue)) {
        $ErrorActionPreference = "Continue"
        $o = & $c.Source -c "print(40 + 2)" 2>&1 | Out-String
        $ErrorActionPreference = "Stop"
        if ($LASTEXITCODE -eq 0 -and $o.Trim() -eq "42") { $python = $c; break }
    }
    if ($python) { break }
}

Write-Host "-- static: run-planner.ps1"
$code = Get-Content -Raw -LiteralPath $runner
Has   "web tools off (--disallowedTools WebSearch WebFetch)"     $code '"--disallowedTools",\s*"WebSearch",\s*"WebFetch"'
Has   "the token goes in by name only (-e CLAUDE_CODE_OAUTH_TOKEN)" $code '"-e",\s*"CLAUDE_CODE_OAUTH_TOKEN"'
Check "...never as NAME=value on a command line"                  ($code -match 'CLAUDE_CODE_OAUTH_TOKEN=') "False"
Has   "-Phase tests verifies DONE.md"                              $code 'planner_done\.py'
Has   "the checkpoint comes before the Docker checks"              ($code.IndexOf('planner_done.py') -lt $code.IndexOf('com.docker.backend') -and $code.IndexOf('planner_done.py') -gt 0) 'True'

if (-not $python) {
    Write-Host "SKIP the Python unit tests and the run-planner.ps1 scenarios: no working python"
    $script:skipped++
} else {
    Write-Host "-- Python unit tests"
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $py = & $python.Source -I (Join-Path $PSScriptRoot "test_planner_done.py") 2>&1 | Out-String; $pyExit = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
    Check "test_planner_done.py passes"   $pyExit 0
    if ($pyExit -ne 0) { Write-Host $py }
    Has   "...and ran its 20 tests"       $py 'Ran 20 tests'

    Write-Host "-- run-planner.ps1 -Phase tests on a fake pack"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("planner-done-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    $pack = Join-Path $tmp "pack"
    $done = Join-Path $pack "planner/t-1/1/DONE.md"
    $noToken = Join-Path $tmp "no-such-token"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        New-Item -ItemType Directory -Force (Join-Path $pack "tasks/t-1"), (Split-Path $done) | Out-Null
        [IO.File]::WriteAllText((Join-Path $pack "tasks/t-1/base.bundle"), "not a real bundle", $utf8)
        [IO.File]::WriteAllText((Join-Path $pack "TESTS-PROMPT.md"), "# tests prompt`n", $utf8)
        $list = "# Done list`n`n- [x] D1: documents HEALTH_PORT`n- [ ] N1: mentions Dependabot`n"
        # Where it stopped: the checkpoint's own ERROR line, and none of the later Docker/proxy/token stops. Exit 1
        # alone proves nothing (those later stops exit 1 too), so a refusal that went missing would still look red.
        $later = 'Docker Desktop is not running|image .* is missing|planner-proxy is not running|no token file'
        function Stopped-At-Checkpoint($r) { ($r.Out -match 'ERROR: (no .*DONE\.md|t-1 run 1: DONE\.md)') -and -not ($r.Out -match $later) }
        function Invoke-Runner {
            $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            try {
                $out = & pwsh -NoProfile -File $runner -Pack $pack -Out (Join-Path $tmp "out") -Run 1 -Tasks t-1 -Phase tests -TokenFile $noToken 2>&1 | Out-String
                [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
            } finally { $ErrorActionPreference = $prev }
        }

        $r = Invoke-Runner
        Check "no DONE.md: exit 1"                                   $r.Exit 1
        Has   "...saying so"                                          $r.Out 'no .*DONE\.md'
        Check "...stopped at the checkpoint"                         (Stopped-At-Checkpoint $r) "True"

        [IO.File]::WriteAllText($done, $list, $utf8)
        $r = Invoke-Runner
        Check "an unconfirmed DONE.md: exit 1"                       $r.Exit 1
        Has   "...not confirmed"                                      $r.Out 'not confirmed'
        Check "...stopped at the checkpoint"                         (Stopped-At-Checkpoint $r) "True"

        & $python.Source -I $doneTool confirm $done --by guard | Out-Null
        & $python.Source -I $doneTool set $done N1=on | Out-Null
        $r = Invoke-Runner
        Check "a DONE.md ticked after confirming: exit 1"            $r.Exit 1
        Has   "...changed since"                                      $r.Out 'changed since'
        Check "...stopped at the checkpoint"                         (Stopped-At-Checkpoint $r) "True"

        [IO.File]::WriteAllText($done, $list, $utf8)
        & $python.Source -I $doneTool confirm $done --by guard | Out-Null
        $r = Invoke-Runner
        Has   "a confirmed DONE.md passes the checkpoint"            $r.Out 'DONE\.md: confirmed by guard'
        Check "...and still starts no session (stops at Docker, the proxy or the token)" ($r.Out -match $later) "True"
        Check "...exit 1"                                            $r.Exit 1
        Check "...no output folder was made"                         (Test-Path (Join-Path $tmp "out")) "False"
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($script:fail) { Write-Host "$script:fail FAILED"; exit 1 }
Write-Host $(if ($script:skipped) { "all run checks passed ($script:skipped part skipped)" } else { "all passed" })
exit 0

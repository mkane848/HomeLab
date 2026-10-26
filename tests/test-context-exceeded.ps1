# protects: contextExceeded outcome (exit -6, _CTXEXCEEDED_)
# run-after: How a run's exit is classified
# test-context-exceeded.ps1 - regression guard for the contextExceeded run outcome
# (test-tasks.ps1: exit -6, a _CTXEXCEEDED_ transcript, no summary row)
#
# Why this exists: an engine that refuses an over-long request explicitly
# (llama-server: HTTP 400 exceed_context_size_error) gives opencode a
# ContextOverflowError. A run that recovers is graded (test-overflow-recovery.ps1).
# One that does not used to be filed as _INFRA_ ("overflow killed the run"), which
# lumped "the request outgrew the served context" in with an unreachable provider.
# It says something different: about the task's fit to the seat's window, neither
# infrastructure nor model behaviour. It is now its own outcome. A timeout whose
# transcript holds unrecovered overflows (the llama.cpp trial's kane-08: the run
# looped on them until the cap) stays _TIMEOUT_, but its FAIL line names them.
#
# What it does: the REAL test-tasks.ps1 end to end against a fixture repo with a
# stand-in opencode, for
#   fx-exceeded   an overflow, edits, exit 1, no finished step after it -> _CTXEXCEEDED_
#   fx-recovered  overflows, then a step that stops, exit 1             -> graded
#   fx-other      an overflow plus another error, exit 1                -> _INFRA_
#   fx-timeout    an overflow, then the agent hangs                     -> _TIMEOUT_, names it
#   fx-clean      no errors                                             -> graded
# and a control: the same harness with the new outcome's exit code removed must
# file fx-exceeded as _INFRA_, or this guard is not testing the branch.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-context-exceeded.ps1 [-ScriptPath <a test-tasks.ps1>]
param([string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"))

$ErrorActionPreference = "Stop"
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ctx-exceeded-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    Write-Host "-- the code"
    $src = [IO.File]::ReadAllText($ScriptPath)
    Check "exit -6 is assigned once"                              ([regex]::Matches($src, '\$run\.ExitCode = -6').Count) 1
    Check "the tag is CTXEXCEEDED"                                ($src -match '-eq -6\) \{ "CTXEXCEEDED" \}') "True"

    function Invoke-Harness([string]$harnessPath, [string]$root) {
        foreach ($d in @("tests/tasks", "bin", "repo")) { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
        Copy-Item -LiteralPath $harnessPath -Destination (Join-Path $root "tests/test-tasks.ps1")
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $root "tests") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $root "tests") -Recurse -Force
        $repo = Join-Path $root "repo"
        git -C $repo init -q
        git -C $repo config user.email "t@example.invalid"
        git -C $repo config user.name "t"
        Set-Content -LiteralPath (Join-Path $repo "src.txt") -Value "buggy"
        @'
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
$test = if (Test-Path test.txt) { (Get-Content -LiteralPath test.txt -Raw).Trim() } else { "" }
if ($test -and $src -ne 'fixed') { Write-Host "Tests  1 failed (1)"; exit 1 }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content -LiteralPath (Join-Path $repo "check.ps1")
        git -C $repo add -A
        git -C $repo commit -q -m base
        $base = (git -C $repo rev-parse HEAD).Trim()
        $psExe = (Get-Process -Id $PID).Path
        $tasks = foreach ($id in "fx-exceeded", "fx-recovered", "fx-other", "fx-timeout", "fx-clean") {
            [ordered]@{
                id = $id; title = $id; repo = $repo; branch = "bench/$id"; benchBaseCommit = $base
                baselineExpect = @{ testsTotal = 1; testsPass = 1 }
                allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
                testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1")
                installFlags = @(); prompt = "fix it"
            }
        }
        @{ tasks = @($tasks) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root "tests/tasks/manifest.json")
        @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    $id = Split-Path -Leaf $dir
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value 'a real test'
    $start = '{"type":"step_start","part":{"type":"step-start"}}'
    $edits = '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}', '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    $stop = '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    $over = '{"type":"error","sessionID":"s1","error":{"name":"ContextOverflowError","data":{"message":"request (70000 tokens) exceeds the available context size (65536 tokens), try increasing it"}}}'
    $api  = '{"type":"error","sessionID":"s1","error":{"name":"APIError","data":{"message":"Cannot connect to API"}}}'
    switch ($id) {
        'fx-exceeded'  { $start; $edits; $over; exit 1 }
        'fx-recovered' { $over; $over; $start; $edits; $stop; exit 1 }
        'fx-other'     { $over; $start; $edits; $stop; $api; $start; $stop; exit 1 }
        'fx-timeout'   { $start; $over; $over; Start-Sleep -Seconds 120; exit 1 }
        default        { $start; $edits; $stop; exit 0 }
    }
}
exit 2
'@ | Set-Content -LiteralPath (Join-Path $root "bin/standin.ps1")
        $bin = Join-Path $root "bin"
        "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
        $origPath = $env:PATH
        $env:PATH = "$bin;$env:PATH"
        try {
            $out = & (Join-Path $root "tests/test-tasks.ps1") -Task fx-exceeded, fx-recovered, fx-other, fx-timeout, fx-clean -Model fixture/m -SkipInstall -RunTimeout 15 -OllamaLogDir (Join-Path $root "no-log") *>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $env:PATH = $origPath
        }
        $results = Join-Path $root "tests/results"
        [pscustomobject]@{
            Output = $out; ExitCode = $code; Results = $results
            Rows   = @(if (Test-Path (Join-Path $results "tasks-summary.tsv")) { Import-Csv (Join-Path $results "tasks-summary.tsv") -Delimiter "`t" })
        }
    }
    function Row($h, [string]$id) { @($h.Rows | Where-Object taskId -eq $id)[0] }
    function Tagged($h, [string]$id, [string]$tag) { @(Get-ChildItem $h.Results -Filter "tasks-$id-*_${tag}_*.jsonl" -ErrorAction SilentlyContinue).Count }
    function Graded($h, [string]$id) { @(Get-ChildItem $h.Results -Filter "tasks-$id-*.json" -ErrorAction SilentlyContinue).Count }

    $h = Invoke-Harness $ScriptPath (Join-Path $tmp "e2e")
    Write-Host "-- an unrecovered overflow (fx-exceeded)"
    Check "a _CTXEXCEEDED_ transcript"                            (Tagged $h "fx-exceeded" "CTXEXCEEDED") 1
    Check "...and no _INFRA_ transcript"                          (Tagged $h "fx-exceeded" "INFRA") 0
    Check "...and no _TIMEOUT_ transcript"                        (Tagged $h "fx-exceeded" "TIMEOUT") 0
    Check "no summary row"                                        ([bool](Row $h "fx-exceeded")) "False"
    Check "no run JSON"                                           (Graded $h "fx-exceeded") 0
    Check "a FAIL line that says context exceeded"                ($h.Output -match '(?s)\[FAIL\]\s+\S+ run\s+->\s*\r?\n?\s*Context exceeded') "True"
    Check "...and keeps the overflow wording"                     ($h.Output -match 'refused 1 over-long request\(s\) explicitly .*overflow killed the run') "True"
    Check "...and names the served context (num_ctx unknown here)" ($h.Output -match 'served context window \(unknown tokens\)') "True"
    Check "the harness exits 1 (a FAIL)"                          $h.ExitCode 1

    Write-Host "-- a recovered overflow (fx-recovered)"
    Check "graded: a summary row"                                 ([bool](Row $h "fx-recovered")) "True"
    Check "...no _CTXEXCEEDED_ transcript"                        (Tagged $h "fx-recovered" "CTXEXCEEDED") 0

    Write-Host "-- an overflow plus another error (fx-other)"
    Check "stays _INFRA_"                                         (Tagged $h "fx-other" "INFRA") 1
    Check "...not _CTXEXCEEDED_"                                  (Tagged $h "fx-other" "CTXEXCEEDED") 0
    Check "no summary row"                                        ([bool](Row $h "fx-other")) "False"

    Write-Host "-- a timeout that holds overflows (fx-timeout)"
    Check "stays _TIMEOUT_"                                       (Tagged $h "fx-timeout" "TIMEOUT") 1
    Check "...not _CTXEXCEEDED_"                                  (Tagged $h "fx-timeout" "CTXEXCEEDED") 0
    Check "no summary row"                                        ([bool](Row $h "fx-timeout")) "False"
    Check "the FAIL line names the overflows"                     ($h.Output -match 'refused 2 over-long request\(s\) explicitly .*overflow killed the run') "True"

    Write-Host "-- a clean run (fx-clean)"
    Check "graded"                                                ([bool](Row $h "fx-clean")) "True"

    Write-Host "-- control: the same harness without the new outcome's exit code"
    $noBranch = Join-Path $tmp "no-branch.ps1"
    $stripped = $src.Replace('$run.ExitCode = -6', '$run.ExitCode = $run.ExitCode')
    Check "the exit code assignment was found and removed"        ($stripped -ne $src) "True"
    [IO.File]::WriteAllText($noBranch, $stripped)
    $c = Invoke-Harness $noBranch (Join-Path $tmp "control")
    Check "without it fx-exceeded is filed _INFRA_ (guard bites)" (Tagged $c "fx-exceeded" "INFRA") 1
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

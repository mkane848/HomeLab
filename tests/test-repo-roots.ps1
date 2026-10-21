# test-repo-roots.ps1 - regression guard for the per-host repo-root map
#
# Why this exists: the manifests name each task's checkout as the desktop has it
# (M:/Projects/LFCbot, C:/Projects/KaneEnabler, ...). node3, the planned run host,
# keeps them in C:/HomeLab/repos/ and has no M: drive, so the harness could not
# find a single task there (docs/roadmap.md -> "After the trial", item 1).
# tests/repo-roots.tsv maps a manifest prefix to a local one per machine, and
# Set-TaskRepoRoots (one identical copy in test-tasks.ps1 and run-tasks-batch.ps1)
# applies it right after the manifest loads.
#
# What it does:
#   - the real function, extracted from test-tasks.ps1, on synthetic tasks: exact
#     and deeper paths, backslashes, case, the longest prefix, a prefix that is not a
#     path boundary, another machine's rows, comments and the header, no file;
#   - the two copies are identical;
#   - the real test-tasks.ps1 end to end with a stand-in opencode, its manifest
#     naming a checkout that does not exist and the map pointing at the fixture:
#     graded, with repoPath and repoManifestPath in the run JSON; with only another
#     machine's row the checkout is not found; a control copy without the call is too;
#   - the real run-tasks-batch.ps1 -SetupOnly creating the bench branch in the
#     mapped checkout.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-repo-roots.ps1
$ErrorActionPreference = "Stop"
$tasksPs1 = Join-Path $PSScriptRoot "test-tasks.ps1"
$batchPs1 = Join-Path $PSScriptRoot "run-tasks-batch.ps1"
foreach ($p in $tasksPs1, $batchPs1) {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errs)
    if ($errs.Count) { $errs; exit 2 }
}

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}
function Get-FunctionText([string]$Path, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if ($fn.Count -ne 1) { return $null }
    return $fn[0].Extent.Text
}

Write-Host "-- the two copies"
$fnTasks = Get-FunctionText $tasksPs1 "Set-TaskRepoRoots"
$fnBatch = Get-FunctionText $batchPs1 "Set-TaskRepoRoots"
Check "test-tasks.ps1 defines Set-TaskRepoRoots once" ([bool]$fnTasks) "True"
Check "run-tasks-batch.ps1 defines Set-TaskRepoRoots once" ([bool]$fnBatch) "True"
Check "the two copies are identical" (($fnTasks -replace "`r", '') -eq ($fnBatch -replace "`r", '')) "True"
. ([scriptblock]::Create($fnTasks))

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("repo-roots-test-" + [guid]::NewGuid().ToString("N"))
$psExe = (Get-Process -Id $PID).Path
$me = [Environment]::MachineName
try {
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    Write-Host "-- the function"
    $map = Join-Path $tmp "map.tsv"
    @(
        "# comment line"
        "host`tmanifestPrefix`tlocalPrefix"
        "$($me.ToLowerInvariant())`tM:/Projects`tC:/HomeLab/repos"
        "$me`tM:/Projects/LFCbot`tC:/HomeLab/repos/LFCbot-node3"
        "$me`tC:\Projects\KaneEnabler\`tC:/HomeLab/repos/KaneEnabler"
        "$me`tM:/TTRPG/A Story`tC:/wrong"
        "OTHER-PC`tM:/TTRPG`tD:/other"
    ) | Set-Content -LiteralPath $map
    function New-T([string]$id, [string]$repo) { [pscustomobject]@{ id = $id; repo = $repo } }
    $ts = @(
        (New-T "lfc" "M:/Projects/LFCbot"),
        (New-T "lfc-sub" "M:\Projects\LFCbot\packages\core"),
        (New-T "other" "m:/projects/SomethingElse"),
        (New-T "kane" "C:/Projects/KaneEnabler"),
        (New-T "asohav" "M:/TTRPG/A Story of Heroes and Villains"),
        (New-T "norepo" $null)
    )
    $changed = @(Set-TaskRepoRoots $ts $map $me)
    function T([string]$id) { @($ts | Where-Object id -eq $id)[0] }
    Check "the longest prefix wins"                     (T "lfc").repo "C:/HomeLab/repos/LFCbot-node3"
    Check "a deeper path keeps its tail, backslashes become slashes" (T "lfc-sub").repo "C:/HomeLab/repos/LFCbot-node3/packages/core"
    Check "case is ignored in host and path"            (T "other").repo "C:/HomeLab/repos/SomethingElse"
    Check "a backslash prefix with a trailing slash matches" (T "kane").repo "C:/HomeLab/repos/KaneEnabler"
    Check "a prefix that is not a path boundary does not match" (T "asohav").repo "M:/TTRPG/A Story of Heroes and Villains"
    Check "another machine's row is ignored"            ((T "asohav").repo -like "D:/*") "False"
    Check "the manifest path is kept in manifestRepo"   (T "lfc").manifestRepo "M:/Projects/LFCbot"
    Check "an unmapped task gets no manifestRepo"       ([bool](T "asohav").PSObject.Properties['manifestRepo']) "False"
    Check "a task with no repo is left alone"           ([string](T "norepo").repo) ""
    Check "four changes reported"                       $changed.Count 4
    $ts2 = @((New-T "lfc" "M:/Projects/LFCbot"))
    Check "no map file: nothing changes"                (@(Set-TaskRepoRoots $ts2 (Join-Path $tmp "absent.tsv") $me).Count) 0
    Check "no map file: the path is unchanged"          $ts2[0].repo "M:/Projects/LFCbot"
    $ts3 = @((New-T "lfc" "M:/Projects/LFCbot"))
    Check "another machine: nothing changes"            (@(Set-TaskRepoRoots $ts3 $map "NOT-THIS-PC").Count) 0

    Write-Host "-- the real test-tasks.ps1 end to end"
    function New-Harness([string]$root, [string]$tasksText) {
        foreach ($d in @("tests/tasks", "bin")) { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
        Set-Content -LiteralPath (Join-Path $root "tests/test-tasks.ps1") -Value $tasksText
        Copy-Item -LiteralPath $batchPs1 -Destination (Join-Path $root "tests/run-tasks-batch.ps1")
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "agents") -Destination (Join-Path $root "tests") -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "engines") -Destination (Join-Path $root "tests") -Recurse -Force
    }
    $repo = Join-Path $tmp "checkouts/fixture-repo"
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
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
    $manifestRepo = "Q:/nowhere/checkouts/fixture-repo"     # what the manifest says: does not exist
    $manifestJson = @{ tasks = @([ordered]@{
        id = "fx-map"; title = "fx-map"; repo = $manifestRepo; branch = "bench/fx-map"; benchBaseCommit = $base
        baselineExpect = @{ testsTotal = 1; testsPass = 1 }
        allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
        testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1")
        installFlags = @(); prompt = "fix it"
    }) } | ConvertTo-Json -Depth 8
    $standin = @'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value 'a real test'
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@
    $localPrefix = (Join-Path $tmp "checkouts") -replace '\\', '/'
    $goodMap = @("host`tmanifestPrefix`tlocalPrefix", "$me`tQ:/nowhere/checkouts`t$localPrefix")
    $otherMap = @("host`tmanifestPrefix`tlocalPrefix", "OTHER-PC`tQ:/nowhere/checkouts`t$localPrefix")
    $tasksText = Get-Content -LiteralPath $tasksPs1 -Raw
    $callLine = '$repoRemaps = @(Set-TaskRepoRoots $allTasks $repoRootsMap ([Environment]::MachineName))'
    Check "test-tasks.ps1 has the call the control removes" ($tasksText.Contains($callLine)) "True"

    function Invoke-Case([string]$name, [string]$text, $mapLines) {
        $root = Join-Path $tmp $name
        New-Harness $root $text
        Set-Content -LiteralPath (Join-Path $root "tests/tasks/manifest.json") -Value $manifestJson
        if ($mapLines) { $mapLines | Set-Content -LiteralPath (Join-Path $root "tests/repo-roots.tsv") }
        $bin = Join-Path $root "bin"
        Set-Content -LiteralPath (Join-Path $bin "standin.ps1") -Value $standin
        "@echo off`r`n`"$psExe`" -NoProfile -File `"$bin\standin.ps1`" %*" | Set-Content -LiteralPath (Join-Path $bin "opencode.cmd") -Encoding ascii
        $origPath = $env:PATH
        $env:PATH = "$bin;$env:PATH"
        try {
            $out = & (Join-Path $root "tests/test-tasks.ps1") -Task fx-map -Model fixture/m -SkipInstall -RunTimeout 120 -OllamaLogDir (Join-Path $root "no-log") *>&1 | Out-String
        } finally { $env:PATH = $origPath }
        $results = Join-Path $root "tests/results"
        $json = Get-ChildItem $results -Filter "tasks-fx-map-*.json" -ErrorAction SilentlyContinue | Select-Object -First 1
        [pscustomobject]@{
            Out  = $out
            Json = $(if ($json) { Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json } else { $null })
            Rows = @(if (Test-Path (Join-Path $results "tasks-summary.tsv")) { Import-Csv (Join-Path $results "tasks-summary.tsv") -Delimiter "`t" })
            Root = $root
        }
    }

    $c = Invoke-Case "mapped" $tasksText $goodMap
    $expectPath = "$localPrefix/fixture-repo"
    Check "mapped: the run is graded (one summary row)"     $c.Rows.Count 1
    Check "mapped: suite PASS"                              $c.Rows[0].suite "PASS"
    Check "mapped: the run JSON's repoPath is the local checkout" ([string]$c.Json.repoPath) $expectPath
    Check "mapped: the run JSON keeps the manifest's path"  ([string]$c.Json.repoManifestPath) $manifestRepo
    Check "mapped: the console says the map was applied"    ($c.Out -match "repo roots: 1 task checkout\(s\) mapped for $me") "True"

    $c = Invoke-Case "other-host" $tasksText $otherMap
    Check "another machine's row only: no row"              $c.Rows.Count 0
    Check "another machine's row only: checkout not found at the manifest's path" ($c.Out -match [regex]::Escape("checkout not found at $manifestRepo")) "True"

    $c = Invoke-Case "no-map" $tasksText $null
    Check "no map file: checkout not found at the manifest's path" ($c.Out -match [regex]::Escape("checkout not found at $manifestRepo")) "True"
    Check "no map file: no run JSON"                        ($null -eq $c.Json) "True"

    $c = Invoke-Case "control" ($tasksText.Replace($callLine, '$repoRemaps = @()')) $goodMap
    Check "control without the call: no row (the guard notices)" $c.Rows.Count 0

    Write-Host "-- the real run-tasks-batch.ps1 -SetupOnly"
    $root = Join-Path $tmp "batch"
    New-Harness $root $tasksText
    Set-Content -LiteralPath (Join-Path $root "tests/tasks/manifest.json") -Value $manifestJson
    $goodMap | Set-Content -LiteralPath (Join-Path $root "tests/repo-roots.tsv")
    git -C $repo branch -D bench/fx-map *> $null      # an earlier case may have made it; the batch must make it now
    $out = & (Join-Path $root "tests/run-tasks-batch.ps1") -SetupOnly *>&1 | Out-String
    Check "batch: the console says the map was applied"     ($out -match "repo roots: 1 task checkout\(s\) mapped") "True"
    Check "batch: it created the bench branch in the mapped checkout" ($out -match [regex]::Escape("created bench/fx-map @ $($base.Substring(0,10)) in $expectPath")) "True"
    Check "batch: the branch is at the pin" ((git -C $repo rev-parse --verify --quiet "refs/heads/bench/fx-map") -eq $base) "True"
    Check "batch: no 'repo not found' warning"              ($out -match "repo not found") "False"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"
exit 0

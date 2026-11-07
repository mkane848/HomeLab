# run-planner-local.ps1 - experiment 3's planner step on a LOCAL model, through OpenCode (docs/planner-tests-experiment.md,
# "A local planner"). The same prompts and pack as desktop/scripts/run-planner.ps1, so its output compares with the
# frontier planner's and lands in the same layout; only the container paths in the prompt are rewritten.
#
# The difference to keep in mind: there is NO container. run-planner.ps1 seals Claude Code in a throwaway container with a
# read-only pack and an allowlist proxy. Here the model runs on the host, in a scratch folder, and could read anything the
# account can. So every run's transcript is audited (Get-OutsideReferences): any tool call naming an absolute path outside
# the scratch folder is recorded in <id>.json as `outside`, and a set with one is not clean evidence until someone has read
# what it touched.
#
#   pwsh -File desktop\scripts\run-planner-local.ps1 -Pack <pack> -Out <folder> -Run 1 -Phase plan|done|tests `
#        -Model llamacpp-server/qwen3.6:35b-a3b-coding -ServerUrl http://<host>:8090/v1 [-Tasks real-01,wp-5b] [-MaxMinutes 45]
#
# Output, per phase: <Out>\run<N>[-<phase>]\planner\<task>\<N>\... (and <N>-ideal), <task>.jsonl (the transcript),
# <task>.json (exit, minutes, usage, files, outside references, collect), meta.json (model, prompt hash, agent version).
#
# The plan and tests phases collect the planner's files from its clone (Get-PlannerCollection), so a hand-copy that lost a folder
# path cannot change where a test runs. What the model handed in is kept beside the set in handed-in\<task>\ for the record.
param(
    [string]$Pack,
    [string]$Out,
    [ValidateRange(1, 99)][int]$Run = 1,
    [ValidateSet("plan", "done", "tests")][string]$Phase = "plan",
    [string]$Model = "",
    [string]$ServerUrl = "",
    [string[]]$Tasks = @(),
    [int]$MaxMinutes = 45,
    [string]$Scratch = (Join-Path ([IO.Path]::GetTempPath()) "planner-local"),
    [string]$HarnessScript = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "tests\test-tasks.ps1"),
    [string]$AdapterScript = (Join-Path (Split-Path (Split-Path $PSScriptRoot)) "tests\agents\opencode.ps1")
)

function ConvertTo-LocalPrompt {
    # The prompt as written for the container, with its mount points moved into the scratch folder. Nothing else changes.
    param([string]$Text, [string]$PackDir, [string]$WorkDir)
    $p = $PackDir.Replace('\', '/').TrimEnd('/'); $w = $WorkDir.Replace('\', '/').TrimEnd('/')
    return (($Text -replace '(?<![\w/.-])/pack(?=/|\b)', $p) -replace '(?<![\w/.-])/workspace(?=/|\b)', $w)
}

function Get-OutsideReferences {
    # Absolute Windows paths in a transcript's tool calls that are not under $Root, sorted and unique. Also any mention of
    # the private repository, whatever form the path takes. Compared with forward slashes and without case.
    param([object[]]$Events, [string]$Root)
    $rootN = $Root.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $found = New-Object System.Collections.Generic.HashSet[string]
    foreach ($e in @($Events | Where-Object { $_.Kind -eq "tool" })) {
        $text = (@($e.Paths) + @($(if ($null -ne $e.Input) { $e.Input | ConvertTo-Json -Compress -Depth 6 } else { "" }))) -join " "
        $text = $text -replace '\\\\', '/' -replace '\\', '/'
        foreach ($m in [regex]::Matches($text, '(?i)(?<![\w/])[a-z]:/[^\s"''`|<>;,)]*')) {
            $n = $m.Value.TrimEnd('/', '.').ToLowerInvariant()
            if ($n -ne $rootN -and -not $n.StartsWith("$rootN/")) { [void]$found.Add($m.Value) }
        }
        if ($text -match '(?i)homelab-private') { [void]$found.Add("(names HomeLab-private)") }
    }
    return @($found | Sort-Object)
}

function Get-PlannerCollection {
    # What the planner really wrote, read from its clone. The review of 2026-11-06 found the hand-copy step losing folder paths, so
    # tests never ran or climbed out of the checkout (docs/planner-tests-experiment.md, "Review"). So the clone decides where a file
    # belongs and what it holds. What the model handed in decides only which tier it is, and whether an edited test counts.
    #   Collected: new test files, tests it edited and handed in, and new helpers those tests import. Each with its tiers.
    #   Moved: collected at another path than it was handed in at.
    #   Kept: handed in and not in the clone at the end, at a path that can belong to the repository. A planner may write its test in
    #   the output folder, copy it into the clone to run it and clean up after itself (wp-0a, 2026-11-06). NotInClone: handed in at a
    #   path that cannot: at the root with no test there, or under a top-level folder the repository does not have.
    #   ExistingUnchanged: handed in, but the clone has that path untouched (tests the repository already holds).
    #   EditedNotHandedIn / OtherChanges / Ignored: changes left out, recorded so a reader can see them.
    param([string]$CloneDir, [string]$GateDir, [string]$IdealDir = "", [switch]$Tiers)
    $out = [pscustomobject]@{ CloneFound = $false; Collected = @(); Moved = @(); Kept = @(); NotInClone = @(); ExistingUnchanged = @(); EditedNotHandedIn = @(); OtherChanges = @(); Ignored = @() }
    $handed = @()
    foreach ($t in @(@{ Tier = "gate"; Dir = $GateDir }, @{ Tier = "ideal"; Dir = $IdealDir })) {
        if ($t.Dir -and (Test-Path -LiteralPath $t.Dir)) {
            $handed += @(Get-ChildItem -LiteralPath $t.Dir -Recurse -File | Where-Object { $_.Name -notin "NOTES.md", "DONE.md", "DONE.planner.md" } | ForEach-Object {
                    [pscustomobject]@{ Tier = $t.Tier; Rel = $_.FullName.Substring($t.Dir.TrimEnd('\', '/').Length + 1).Replace('\', '/'); Name = $_.Name } })
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $CloneDir ".git"))) {
        $out.NotInClone = @($handed | ForEach-Object Rel | Select-Object -Unique)
        return $out
    }
    $out.CloneFound = $true
    # -z: a path with a space or an accent comes back as it is. Ignored files (node_modules) are not listed at all.
    # git writes UTF-8; PowerShell would decode it with the console's code page and garble an accented path.
    $savedEnc = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
        $raw = (& git -C $CloneDir -c core.quotepath=off status --porcelain -z --untracked-files=all --no-renames 2>$null) -join "`n"
    } finally { [Console]::OutputEncoding = $savedEnc }
    $changes = @($raw -split "`0" | Where-Object { $_.Length -gt 3 } | ForEach-Object { [pscustomobject]@{ Code = $_.Substring(0, 2); Rel = $_.Substring(3).Replace('\', '/').Trim("`n") } })
    $isTest = { param($rel) $rel -match '\.(test|spec)\.[cm]?[jt]sx?$' }
    $skip = { param($rel) ($rel -split '/' | Where-Object { $_ -in "node_modules", "dist", "coverage", ".git" }) -or (Split-Path -Leaf $rel) -in "NOTES.md", "DONE.md", "DONE.planner.md" }
    $tests = New-Object System.Collections.Generic.List[object]
    $helpers = New-Object System.Collections.Generic.List[string]
    $other = New-Object System.Collections.Generic.List[string]
    $editedOut = New-Object System.Collections.Generic.List[string]
    foreach ($c in $changes) {
        if (& $skip $c.Rel) { continue }
        $name = Split-Path -Leaf $c.Rel
        $wasHanded = [bool]($handed | Where-Object Name -eq $name)
        if (& $isTest $c.Rel) {
            if ($c.Code -eq "??" -or $wasHanded) { $tests.Add($c.Rel) } else { $editedOut.Add($c.Rel) }
        } elseif ($c.Code -eq "??") { $helpers.Add($c.Rel) } else { $other.Add($c.Rel) }
    }
    $tierOf = { param($rel)
        $h = @($handed | Where-Object Name -eq (Split-Path -Leaf $rel) | ForEach-Object Tier | Select-Object -Unique)
        if ($h.Count) { return $h }
        if (-not $Tiers) { return @("gate") }
        # Written and not handed in: the ids in its test names say which tier it is.
        $text = Get-Content -Raw -LiteralPath (Join-Path $CloneDir $rel)
        $ideal = $text -match "(?:\bit|\btest)(?:\.\w+)?\(\s*['""``]I[0-9]"
        $gate = $text -match "(?:\bit|\btest)(?:\.\w+)?\(\s*['""``]G[0-9]"
        if ($ideal -and -not $gate) { return @("ideal") }
        return @("gate") }
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tests) { $items.Add([pscustomobject]@{ Rel = $t; Tiers = @(& $tierOf $t) }) }
    # A new file that is not a test belongs only if a collected test imports it, in that test's tiers. Otherwise it is scratch.
    $ignored = New-Object System.Collections.Generic.List[string]
    foreach ($h in $helpers) {
        $stem = [regex]::Escape(((Split-Path -Leaf $h) -replace '\.[^.]+$', ''))
        $users = @($items | Where-Object { (Get-Content -Raw -LiteralPath (Join-Path $CloneDir $_.Rel)) -match "['""``/\\]$stem(\.[A-Za-z]+)?['""``]" })
        $name = Split-Path -Leaf $h
        if ($users.Count -or ($handed | Where-Object Name -eq $name)) {
            $byHand = @($handed | Where-Object Name -eq $name | ForEach-Object Tier)
            $items.Add([pscustomobject]@{ Rel = $h; Tiers = @(($byHand + @($users | ForEach-Object Tiers)) | Select-Object -Unique) })
        } else { $ignored.Add($h) }
    }
    $out.Collected = $items.ToArray()
    $out.EditedNotHandedIn = $editedOut.ToArray(); $out.OtherChanges = $other.ToArray(); $out.Ignored = $ignored.ToArray()
    $collectedNames = @($items | ForEach-Object { Split-Path -Leaf $_.Rel })
    $out.Moved = @($items | Where-Object { $i = $_; $names = @($handed | Where-Object Name -eq (Split-Path -Leaf $i.Rel)); $names.Count -and -not ($names | Where-Object Rel -eq $i.Rel) } | ForEach-Object Rel)
    foreach ($h in @($handed | Group-Object Rel | ForEach-Object { $_.Group[0] })) {
        if ($h.Name -in $collectedNames) { continue }
        # A file already in the clone and unchanged there: the repository's own, not the planner's work.
        $tracked = & git -C $CloneDir ls-files --error-unmatch -- $h.Rel 2>$null
        $byName = if ($tracked) { $true } else { [bool](& git -C $CloneDir ls-files -- "*/$($h.Name)" 2>$null) -or [bool](& git -C $CloneDir ls-files -- $h.Name 2>$null) }
        if ($byName) { $out.ExistingUnchanged += $h.Rel; continue }
        $tops = @(& git -C $CloneDir ls-tree --name-only -d HEAD 2>$null)
        $first = ($h.Rel -split '/')[0]
        if ($h.Rel.Contains('/') -and $first -in $tops) {
            $tiersHere = @($handed | Where-Object Rel -eq $h.Rel)
            foreach ($k in $tiersHere) {
                $from = Join-Path $(if ($k.Tier -eq "ideal") { $IdealDir } else { $GateDir }) $h.Rel
                $out.Kept += [pscustomobject]@{ Rel = $h.Rel; Tier = $k.Tier; Bytes = [IO.File]::ReadAllBytes($from) }
            }
        } else { $out.NotInClone += $h.Rel }
    }
    return $out
}

function Set-PlannerCollection {
    # Replaces the hand-copied tests in the output folders with the collected ones, at their real paths. NOTES.md stays.
    param($Collection, [string]$CloneDir, [string]$GateDir, [string]$IdealDir = "")
    foreach ($d in @($GateDir, $IdealDir)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            Get-ChildItem -LiteralPath $d -Recurse -File | Where-Object { $_.Name -ne "NOTES.md" } | Remove-Item -Force
            Get-ChildItem -LiteralPath $d -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } | Remove-Item -Force
        }
    }
    foreach ($k in @($Collection.Kept)) {
        $dest = Join-Path $(if ($k.Tier -eq "ideal") { $IdealDir } else { $GateDir }) $k.Rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
        [IO.File]::WriteAllBytes($dest, $k.Bytes)
    }
    foreach ($i in @($Collection.Collected)) {
        foreach ($tier in @($i.Tiers)) {
            $dir = if ($tier -eq "ideal") { $IdealDir } else { $GateDir }
            if (-not $dir) { continue }
            $dest = Join-Path $dir $i.Rel
            New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath (Join-Path $CloneDir $i.Rel) -Destination $dest -Force
        }
    }
}

# --- everything below runs only when the script is run, not when a guard dot-sources it for the functions ---
if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = "Stop"
foreach ($req in @{ Pack = $Pack; Out = $Out; Model = $Model; ServerUrl = $ServerUrl }.GetEnumerator()) {
    if (-not $req.Value) { Write-Host "ERROR: -$($req.Key) is required" -ForegroundColor Red; exit 3 }
}
$Pack = (Resolve-Path -LiteralPath $Pack).Path
$promptName = @{ plan = "PROMPT.md"; done = "DONE-PROMPT.md"; tests = "TESTS-PROMPT.md" }[$Phase]
$promptFile = Join-Path $Pack $promptName
if (-not (Test-Path -LiteralPath $promptFile)) { Write-Host "ERROR: $promptFile is missing" -ForegroundColor Red; exit 1 }
$ids = if ($Tasks.Count) { @($Tasks | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @(Get-ChildItem (Join-Path $Pack "tasks") -Directory | ForEach-Object Name) }
foreach ($id in $ids) { if (-not (Test-Path -LiteralPath (Join-Path $Pack "tasks\$id\base.bundle"))) { Write-Host "ERROR: no pack for task $id" -ForegroundColor Red; exit 1 } }
if ($Phase -eq "tests") {
    # The same checkpoint as run-planner.ps1: no tests from a list the owner has not confirmed, or has changed since.
    $checker = Join-Path $PSScriptRoot "planner_done.py"
    foreach ($id in $ids) {
        $done = Join-Path $Pack "planner\$id\$Run\DONE.md"
        if (-not (Test-Path -LiteralPath $done)) { Write-Host "ERROR: no $done" -ForegroundColor Red; exit 1 }
        & python -I $checker verify $done *> $null
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: $id run ${Run}: DONE.md is not confirmed" -ForegroundColor Red; exit 1 }
    }
}

# The harness's transcript readers (Invoke-AgentRun calls them) and the agent adapter: no copy of either here.
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HarnessScript, [ref]$null, [ref]$errs)
foreach ($name in "Get-TranscriptEnding", "Get-WriteCount") {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
    if (-not $fn) { Write-Host "ERROR: $name not found in $HarnessScript" -ForegroundColor Red; exit 1 }
    Invoke-Expression $fn.Extent.Text
}
. $AdapterScript

$provider = ($Model -split "/", 2)[0]
if ($provider -match '^llamacpp-([A-Za-z0-9]+)$') { Set-Item -Path ("Env:LLAMACPP_{0}_BASE_URL" -f $Matches[1].ToUpper()) -Value $ServerUrl }
$env:OPENCODE_DISABLE_AUTOUPDATE = "1"; $env:GIT_TERMINAL_PROMPT = "0"; $env:GCM_INTERACTIVE = "Never"

$runDir = Join-Path $Out $(if ($Phase -eq "plan") { "run$Run" } else { "run$Run-$Phase" })
New-Item -ItemType Directory -Force $runDir | Out-Null
$runDir = (Resolve-Path -LiteralPath $runDir).Path
$promptText = Get-Content -Raw -LiteralPath $promptFile
[pscustomobject]@{ planner = "local"; model = $Model; serverUrl = $ServerUrl; phase = $Phase; run = $Run; tasks = $ids; prompt = $promptName
    promptSha256 = (Get-FileHash -LiteralPath $promptFile -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
    agent = "opencode $(Get-AgentVersion)"; started = (Get-Date -Format o) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runDir "meta.json")

$envState = Start-AgentRunEnv -Plugins @(Get-OpencodePlugins)
$failed = 0
try {
    foreach ($id in $ids) {
        $root = Join-Path $Scratch ("{0}-{1}-{2}-{3}" -f $Phase, $id, $Run, ([guid]::NewGuid().ToString("N").Substring(0, 6)))
        $packDir = Join-Path $root "pack"; $workDir = Join-Path $root "workspace"
        New-Item -ItemType Directory -Force (Join-Path $packDir "tasks"), $workDir | Out-Null
        Copy-Item -Recurse -LiteralPath (Join-Path $Pack "tasks\$id") -Destination (Join-Path $packDir "tasks\$id")
        if ($Phase -eq "tests") {
            New-Item -ItemType Directory -Force (Join-Path $packDir "planner\$id\$Run") | Out-Null
            Copy-Item -LiteralPath (Join-Path $Pack "planner\$id\$Run\DONE.md") -Destination (Join-Path $packDir "planner\$id\$Run\DONE.md")
        }
        $localPrompt = Join-Path $packDir $promptName
        [IO.File]::WriteAllText($localPrompt, (ConvertTo-LocalPrompt -Text $promptText -PackDir $packDir -WorkDir $workDir), (New-Object Text.UTF8Encoding($false)))
        $msg = "Task '$id', planner run $Run. Follow $($localPrompt.Replace('\', '/')), with <id> = $id and <run> = $Run."
        Write-Host ("[{0}] local planner {1} run {2}, task {3}, {4}" -f (Get-Date -Format "HH:mm:ss"), $Phase, $Run, $id, $Model)
        $r = Invoke-AgentRun -WtPath $workDir -ModelId $Model -Prompt $msg -PromptHash "local" -TimeoutSec ($MaxMinutes * 60)
        $transcript = Join-Path $runDir "$id.jsonl"
        if ($r.TranscriptPath -and (Test-Path -LiteralPath $r.TranscriptPath)) { Copy-Item -LiteralPath $r.TranscriptPath -Destination $transcript -Force; Remove-Item -LiteralPath $r.TranscriptPath -Force -ErrorAction SilentlyContinue }
        $events = Read-AgentEvents -Path $transcript
        $outside = Get-OutsideReferences -Events $events -Root $root
        $tokens = 0.0; foreach ($e in $events) { if ($e.Kind -eq "step-end" -and $e.HasTokens) { $tokens += [double]$e.Output } }
        $src = Join-Path $workDir "planner"
        $collect = $null
        if ($Phase -ne "done") {
            $gateDir = Join-Path $src "$id\$Run"; $idealDir = Join-Path $src "$id\$Run-ideal"; $clone = Join-Path $workDir "work\$id"
            if (Test-Path -LiteralPath $src) {
                $keep = Join-Path $runDir "handed-in\$id"
                New-Item -ItemType Directory -Force $keep | Out-Null
                Copy-Item -Recurse -Force -Path (Join-Path $src "*") -Destination $keep
            }
            $c = Get-PlannerCollection -CloneDir $clone -GateDir $gateDir -IdealDir $idealDir -Tiers:($Phase -eq "tests")
            if ($c.Collected.Count -or $c.Kept.Count) { New-Item -ItemType Directory -Force $gateDir | Out-Null }
            Set-PlannerCollection -Collection $c -CloneDir $clone -GateDir $gateDir -IdealDir $idealDir
            $collect = [pscustomobject]@{ cloneFound = $c.CloneFound; collected = @($c.Collected | ForEach-Object Rel); moved = @($c.Moved); keptFromHandIn = @($c.Kept | ForEach-Object Rel | Select-Object -Unique); notInClone = @($c.NotInClone)
                existingUnchanged = @($c.ExistingUnchanged); editedNotHandedIn = @($c.EditedNotHandedIn); otherChanges = @($c.OtherChanges); ignored = @($c.Ignored) }
        }
        $files = @()
        if (Test-Path -LiteralPath $src) {
            Copy-Item -Recurse -Force -LiteralPath $src -Destination $runDir
            $files = @(Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object { $_.FullName.Substring($src.Length + 1).Replace('\', '/') })
        }
        $tests = @($files | Where-Object { (Split-Path -Leaf $_) -notin "NOTES.md", "DONE.md" })
        $ok = if ($Phase -eq "done") { [bool]($files | Where-Object { (Split-Path -Leaf $_) -eq "DONE.md" }) -and $tests.Count -eq 0 } else { $tests.Count -gt 0 }
        if (-not $ok) { $failed++ }
        [pscustomobject]@{ task = $id; phase = $Phase; run = $Run; ok = $ok; exit = $r.ExitCode; minutes = [math]::Round($r.ElapsedSec / 60, 1); outputTokens = $tokens
            files = $files; outside = $outside; collect = $collect; ending = $(if ($r.Ending) { $r.Ending.FinishReason } else { $null }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir "$id.json")
        Write-Host ("  {0}: exit {1}, {2:N1} min, {3:N0} output tokens, {4} file(s), {5} outside reference(s)" -f $(if ($ok) { "ok" } else { "NO OUTPUT" }), $r.ExitCode, ($r.ElapsedSec / 60), $tokens, $files.Count, $outside.Count)
        if ($collect -and ($collect.moved.Count -or $collect.keptFromHandIn.Count -or $collect.notInClone.Count -or $collect.existingUnchanged.Count)) { Write-Host ("  collected from the clone: {0} moved back, {1} kept from the hand-in, {2} dropped (a path the repository cannot have), {3} the repository's own" -f $collect.moved.Count, $collect.keptFromHandIn.Count, $collect.notInClone.Count, $collect.existingUnchanged.Count) }
        Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReadOnly } | ForEach-Object { $_.Attributes = $_.Attributes -band -bnot [IO.FileAttributes]::ReadOnly }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    $null = Stop-AgentRunEnv -State $envState
}
exit $(if ($failed) { 1 } else { 0 })

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
# <task>.json (exit, minutes, usage, files, outside references), meta.json (model, prompt hash, agent version).
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
        foreach ($m in [regex]::Matches($text, '(?i)\b[a-z]:/[^\s"''`|<>;,)]*')) {
            $n = $m.Value.TrimEnd('/', '.').ToLowerInvariant()
            if ($n -ne $rootN -and -not $n.StartsWith("$rootN/")) { [void]$found.Add($m.Value) }
        }
        if ($text -match '(?i)homelab-private') { [void]$found.Add("(names HomeLab-private)") }
    }
    return @($found | Sort-Object)
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
        $files = @()
        if (Test-Path -LiteralPath $src) {
            Copy-Item -Recurse -Force -LiteralPath $src -Destination $runDir
            $files = @(Get-ChildItem -LiteralPath $src -Recurse -File | ForEach-Object { $_.FullName.Substring($src.Length + 1).Replace('\', '/') })
        }
        $tests = @($files | Where-Object { (Split-Path -Leaf $_) -notin "NOTES.md", "DONE.md" })
        $ok = if ($Phase -eq "done") { [bool]($files | Where-Object { (Split-Path -Leaf $_) -eq "DONE.md" }) -and $tests.Count -eq 0 } else { $tests.Count -gt 0 }
        if (-not $ok) { $failed++ }
        [pscustomobject]@{ task = $id; phase = $Phase; run = $Run; ok = $ok; exit = $r.ExitCode; minutes = [math]::Round($r.ElapsedSec / 60, 1); outputTokens = $tokens
            files = $files; outside = $outside; ending = $(if ($r.Ending) { $r.Ending.FinishReason } else { $null }) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir "$id.json")
        Write-Host ("  {0}: exit {1}, {2:N1} min, {3:N0} output tokens, {4} file(s), {5} outside reference(s)" -f $(if ($ok) { "ok" } else { "NO OUTPUT" }), $r.ExitCode, ($r.ElapsedSec / 60), $tokens, $files.Count, $outside.Count)
        Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReadOnly } | ForEach-Object { $_.Attributes = $_.Attributes -band -bnot [IO.FileAttributes]::ReadOnly }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
} finally {
    $null = Stop-AgentRunEnv -State $envState
}
exit $(if ($failed) { 1 } else { 0 })

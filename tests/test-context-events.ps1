# test-context-events.ps1 - regression guard for the context-event audit in
# test-tasks.ps1 (Get-ContextEvents, Get-CompactionThreshold).
#
# Why this exists: qwen3.5:9b's "No user query found in messages" crash was a
# context overflow (docs/roadmap.md -> "Context overflow", 2026-10-04).
# opencode 1.18.34 decides to compact from the last step's tokens, not the tool
# output that step added, so one large read can carry the next request past
# num_ctx. Ollama 0.34.3 then drops messages from the front, keeping only system
# messages, and logs it at debug level, so the task prompt is gone. qwen3.5's
# template refuses that conversation; every other seat carries on without its
# task (qwen3.6 on kane-08, three runs out of three). The harness saw none of it.
#
# What it does: pulls the REAL functions out of test-tasks.ps1 and runs them on
#   - synthetic transcripts: a clean run, a compaction, a run that stops right
#     after one, a front-drop, a cache miss that is NOT a drop (a reload with
#     the request under num_ctx), a drop without a numeric num_ctx, the crash,
#     a drop a warm prompt cache hides, the model asking what its task is;
#   - real transcripts committed under tests/results/ that the 2026-10-04 audit
#     classified;
#   - Get-CompactionThreshold against opencode 1.18.34's formula.
# Exit 1 on any failure; a missing fixture is a failure, not a skip.
#
# Usage:  .\tests\test-context-events.ps1 [-ScriptPath <a test-tasks.ps1>] [-ResultsDir <tests/results>]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "test-tasks.ps1"),
    [string]$ResultsDir = (Join-Path $PSScriptRoot "results")
)

$ErrorActionPreference = "Stop"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs; exit 2 }
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($name in "Get-ContextEvents", "Get-CompactionThreshold") {
    $fn = $fns | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL: $name not found in $ScriptPath"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}
foreach ($var in '$script:CompactionContinueText', '$script:AskedForTaskPattern') {
    $assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var }, $true)) | Select-Object -First 1
    if (-not $assign) { Write-Host "FAIL: $var not found in $ScriptPath"; exit 2 }
    Invoke-Expression $assign.Extent.Text
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ctx-events-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Ev-Text([string]$text) { (@{ type = "text"; part = @{ type = "text"; text = $text } } | ConvertTo-Json -Compress -Depth 4) }
function Ev-Tool([int]$chars) { (@{ type = "tool_use"; part = @{ type = "tool"; tool = "read"; state = @{ status = "completed"; output = ("x" * $chars) } } } | ConvertTo-Json -Compress -Depth 5) }
function Ev-Fin([int]$in, [int]$cacheRead, [int]$out) { (@{ type = "step_finish"; part = @{ type = "step-finish"; reason = "tool-calls"; tokens = @{ input = $in; output = $out; cache = @{ read = $cacheRead; write = 0 } } } } | ConvertTo-Json -Compress -Depth 5) }
function Ev-Crash { '{"type":"error","error":{"name":"APIError","data":{"message":"Jinja Exception: No user query found in messages."}}}' }
$cont = "$script:CompactionContinueText if you are unsure how to proceed."
function New-Transcript([string[]]$events) {
    $p = Join-Path $tmpRoot ([guid]::NewGuid().ToString("N").Substring(0, 8) + ".jsonl")
    [System.IO.File]::WriteAllText($p, (($events -join "`n") + "`n"), $utf8)
    return $p
}

$script:fail = 0
function CheckValue([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected '$expected', got '$actual'"; $script:fail++ }
}

try {
    Write-Host "-- synthetic transcripts"
    $clean = Get-ContextEvents -Path (New-Transcript @((Ev-Tool 4000), (Ev-Fin 10000 0 100), (Ev-Text "done"), (Ev-Fin 500 11000 50))) -NumCtx 65536
    CheckValue "clean run: no compaction"   $clean.Compactions 0
    CheckValue "clean run: no front-drop"   $clean.FrontDrops.Count 0
    CheckValue "clean run: peak prompt"     $clean.PeakPromptTokens 11500

    # summary step (small, uncached) then the continue step, then more work
    $comp = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 9000), (Ev-Fin 40000 20000 100),
        (Ev-Text "## Objective ..."), (Ev-Fin 4000 0 900),
        (Ev-Text $cont), (Ev-Tool 100), (Ev-Fin 9000 0 100),
        (Ev-Tool 100), (Ev-Fin 300 9100 100),
        (Ev-Text "done"), (Ev-Fin 200 9500 50))) -NumCtx 65536
    CheckValue "compaction counted"                          $comp.Compactions 1
    CheckValue "the summary's small prompt is not a drop"    $comp.FrontDrops.Count 0
    CheckValue "work continued after it"                     $comp.EndedAfterCompaction $false

    $stopped = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 9000), (Ev-Fin 40000 20000 100),
        (Ev-Text "## Objective ..."), (Ev-Fin 4000 0 900),
        (Ev-Text $cont), (Ev-Text "Next steps: ..."), (Ev-Fin 9000 0 200))) -NumCtx 65536
    CheckValue "a run that stops right after compacting"     $stopped.EndedAfterCompaction $true
    CheckValue "...ended without a tool call"                $stopped.EndedWithoutToolCall $true
    CheckValue "a run whose last step calls a tool"          (Get-ContextEvents -Path (New-Transcript @((Ev-Tool 100), (Ev-Fin 9000 0 50))) -NumCtx 65536).EndedWithoutToolCall $false

    # cut off (timeout) inside the continue step: no step_finish, still counted
    $cut = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 9000), (Ev-Fin 40000 20000 100),
        (Ev-Text "## Objective ..."), (Ev-Fin 4000 0 900),
        (Ev-Text $cont), (Ev-Tool 100))) -NumCtx 65536
    CheckValue "a compaction in an unfinished last step counts" $cut.Compactions 1

    # 49,900 prompt + 57,782 chars of new tool output: ~69k against 65,536; the
    # next step reuses nothing from the cache and is smaller - kane-08's shape
    $drop = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 57782), (Ev-Fin 40393 9500 128),
        (Ev-Text "I see you've shared a file"), (Ev-Fin 46576 0 77))) -NumCtx 65536
    CheckValue "front-drop found"                             $drop.FrontDrops.Count 1
    CheckValue "front-drop: step"                             $drop.FrontDrops[0].step 1
    CheckValue "front-drop: prompt before"                    $drop.FrontDrops[0].promptBefore 49893
    CheckValue "front-drop: no compaction"                    $drop.Compactions 0

    # A reload empties the cache too, but the request fits: not a drop.
    $reload = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 9000), (Ev-Fin 20000 10000 100),
        (Ev-Text "ok"), (Ev-Fin 33100 0 100))) -NumCtx 65536
    CheckValue "cache miss under num_ctx is not a drop"       $reload.FrontDrops.Count 0

    # A cache that still covers the previous prompt is not a drop, even when
    # the estimate is over (qwen3:8b on kane-08, 2026-10-03: est ~35k at 32k).
    $covered = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 40000), (Ev-Fin 600 21614 100),
        (Ev-Text "ok"), (Ev-Fin 464 31597 100))) -NumCtx 32768
    CheckValue "full cache reuse is not a drop"               $covered.FrontDrops.Count 0

    $noCtx = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 57782), (Ev-Fin 40393 9500 128),
        (Ev-Text "?"), (Ev-Fin 46576 0 77))) -NumCtx "unset (server default)"
    CheckValue "no numeric num_ctx: shrink + cache collapse"  $noCtx.FrontDrops.Count 1

    # wp-2b's rerun (2026-10-09): the same three-file read overflowed again, but
    # Ollama's prompt cache still held the first run's identical prompt, so the
    # token test reads it as no drop. The model's own question gives it away.
    $warm = Get-ContextEvents -Path (New-Transcript @(
        (Ev-Tool 158837), (Ev-Fin 15596 0 255),
        (Ev-Text "You've shared two files but haven't specified a task. What would you like me to do?"), (Ev-Fin 13792 37888 106))) -NumCtx 65536
    CheckValue "warm-cache drop: the token test misses it"    $warm.FrontDrops.Count 0
    CheckValue "warm-cache drop: the model asked for its task" $warm.AskedForTask.Count 1
    CheckValue "...at the step it asked in"                   ($warm.AskedForTask | Select-Object -First 1).step 2
    CheckValue "...recording only the matched words"          ($warm.AskedForTask | Select-Object -First 1).phrase "you've shared"
    $asks = @("How can I help you with these files?", "I don't see a specific task in your message.", "What would you like me to do with this file?", "You haven't provided a request.")
    CheckValue "each lost-task phrasing is caught"            (@($asks | Where-Object { (Get-ContextEvents -Path (New-Transcript @((Ev-Text $_), (Ev-Fin 9000 0 50))) -NumCtx 65536).AskedForTask.Count -eq 1 }).Count) $asks.Count
    $fine = @("Done. What would you like to do next?", "All tests pass; the change is in combat.ts.", "$script:CompactionContinueText if you are unsure how to proceed.")
    CheckValue "a finished run's question, a recap, the continue text: none" (@($fine | Where-Object { (Get-ContextEvents -Path (New-Transcript @((Ev-Text $_), (Ev-Fin 9000 0 50))) -NumCtx 65536).AskedForTask.Count -gt 0 }).Count) 0
    CheckValue "clean run: never asked"                       $clean.AskedForTask.Count 0

    $crash = Get-ContextEvents -Path (New-Transcript @((Ev-Tool 57782), (Ev-Fin 40393 9500 128), (Ev-Crash))) -NumCtx 65536
    CheckValue "template crash"                               $crash.TemplateCrash $true
    CheckValue "missing transcript: nothing, no throw"        (Get-ContextEvents -Path (Join-Path $tmpRoot "nope.jsonl") -NumCtx 65536).Compactions 0

    Write-Host "-- real transcripts (tests/results, classified 2026-10-04)"
    $real = @(
        # qwen3.6 lost the task: "I see you've shared the signals.test.ts file..."
        @{ f = "tasks-kane-08-aristocrats-false-positives-ollama-desktop_qwen3.6_35b-a3b-coding_20261003-172716.jsonl"; ctx = 65536; drops = 1; comp = 0; crash = $false; asked = 1 },
        @{ f = "tasks-kane-08-aristocrats-false-positives-ollama-desktop_qwen3.6_35b-a3b-coding_TIMEOUT_20261003-201912.jsonl"; ctx = 65536; drops = 3; comp = 2; crash = $false; asked = 0 },
        @{ f = "tasks-kane-08-aristocrats-false-positives-ollama-desktop_qwen3.5_9b_INFRA_20261004-021319.jsonl"; ctx = 65536; drops = 0; comp = 0; crash = $true; asked = 0 },
        @{ f = "tasks-asohav-08-end-combat-clears-strain-ollama-desktop_qwen3.5_9b_INFRA_20261004-031952.jsonl"; ctx = 65536; drops = 0; comp = 0; crash = $true; asked = 0 },
        # 32k: a laguna drop at step 21 (cache reuse fell to the system prompt)
        @{ f = "tasks-kane-02-multiword-creature-type-ollama-desktop_laguna-xs-2.1_20260926-221645.jsonl"; ctx = 32768; drops = 1; comp = 2; crash = $false; asked = 0 },
        # qwen3:8b compacting every other step on asohav-03 (19k-token CLAUDE.md)
        @{ f = "tasks-asohav-03-glossary-depth-flatten-ollama-desktop_qwen3_8b_TIMEOUT_20261004-010408.jsonl"; ctx = 32768; drops = 0; comp = 14; crash = $false; asked = 0 },
        # a clean pass
        @{ f = "tasks-kane-10-combo-permalink-scheme-ollama-desktop_qwen3.5_9b_20261004-162332.jsonl"; ctx = 65536; drops = 0; comp = 0; crash = $false; asked = 0 },
        # qwen3.6 asked twice what to do ("What would you like me to do with this
        # test file...?"); the token test saw no drop (found 2026-10-09)
        @{ f = "tasks-kane-02-multiword-creature-type-ollama-desktop_qwen3.6_35b-a3b-coding_20260926-233030.jsonl"; ctx = 32768; drops = 0; comp = 1; crash = $false; asked = 2 }
    )
    foreach ($r in $real) {
        $p = Join-Path $ResultsDir $r.f
        if (-not (Test-Path -LiteralPath $p)) { Write-Host "FAIL missing fixture $($r.f)"; $script:fail++; continue }
        $ev = Get-ContextEvents -Path $p -NumCtx $r.ctx
        $short = $r.f -replace '^tasks-', '' -replace '-ollama-desktop_', ' / ' -replace '\.jsonl$', ''
        CheckValue "$short : front-drops"   $ev.FrontDrops.Count $r.drops
        CheckValue "$short : compactions"   $ev.Compactions $r.comp
        CheckValue "$short : template crash" $ev.TemplateCrash $r.crash
        CheckValue "$short : asked for task" $ev.AskedForTask.Count $r.asked
    }

    Write-Host "-- Get-CompactionThreshold (opencode 1.18.34 session/overflow.ts)"
    function Cfg([hashtable]$limit, $reserved) {
        $c = @{ provider = @{ "ollama-desktop" = @{ models = @{ "m" = @{ limit = $limit } } } } }
        if ($null -ne $reserved) { $c.compaction = @{ reserved = $reserved } }
        return ($c | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    }
    CheckValue "no limit.input: context - output"             (Get-CompactionThreshold -Config (Cfg @{ context = 65536; output = 4096 } $null) -ModelId "ollama-desktop/m").threshold 61440
    CheckValue "no limit.input: reserved is ignored"          (Get-CompactionThreshold -Config (Cfg @{ context = 65536; output = 8192 } 16000) -ModelId "ollama-desktop/m").threshold 57344
    CheckValue "limit.input, default reserved = min(20k, out)" (Get-CompactionThreshold -Config (Cfg @{ context = 65536; input = 61440; output = 4096 } $null) -ModelId "ollama-desktop/m").threshold 57344
    CheckValue "limit.input with reserved 16000"              (Get-CompactionThreshold -Config (Cfg @{ context = 65536; input = 61440; output = 4096 } 16000) -ModelId "ollama-desktop/m").threshold 45440
    CheckValue "unknown model: null"                          ($null -eq (Get-CompactionThreshold -Config (Cfg @{ context = 65536; output = 4096 } $null) -ModelId "ollama-desktop/other")) $true
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail -gt 0) { Write-Host "RESULT: $($script:fail) check(s) failed"; exit 1 }
Write-Host "RESULT: all checks passed"
exit 0

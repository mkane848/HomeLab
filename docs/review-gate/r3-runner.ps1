<#
.SYNOPSIS
  Round 3 of the review-gate re-measure: does forcing a per-test ledger change
  whether a local reviewer catches the deciding seams?

.DESCRIPTION
  Runs a controlled two-arm experiment on the SAME fixed input used in round 2
  (docs/review-gate/raw/r2-remeasure-input.md, unchanged, byte-identical).

    Arm A (control)   = docs/review-gate/reviewer.md prompt, as-is.
    Arm B (treatment) = the same prompt + the STEP 1 TEST LEDGER clause from
                        docs/review-gate/r3-ledger-clause.md, inserted before
                        the "For EACH numbered command:" line.

  Nothing else differs between arms. The prompt for each arm is built once,
  hashed, and the hash recorded with every run, so "one prompt controller" is
  provable this time rather than asserted — the r2 round's stated constancy was
  false (the seam-6 bullet was added mid-round).

  Everything the r2 round failed to record is recorded here: temperature, seed,
  num_ctx, num_predict, prompt_eval_count, eval_count, done_reason, wall-clock,
  and the prompt hash. Raw JSON and extracted content are written per run, in
  the repo, so runs are auditable rather than living in %TEMP%.

.PARAMETER Models
  Ollama tags to test. Default is the three that failed round 2.

.PARAMETER Draws
  Independent draws per (model, arm) cell. Default 3. Round 2's core weakness
  was n=1 seat eliminations; do not lower this.

.PARAMETER Arms
  Which arms to run. Default both. 'C' is the optional de-leaked arm (see
  r3-protocol.md) and is NOT run unless asked for explicitly.

.EXAMPLE
  .\docs\review-gate\r3-runner.ps1
  .\docs\review-gate\r3-runner.ps1 -Models qwen3.5:9b -Draws 1 -WhatIfPrompt
#>
[CmdletBinding()]
param(
  [string[]]$Models  = @('deepseek-r1:14b', 'qwen3:14b', 'qwen3.5:9b'),
  [int]$Draws        = 3,
  [ValidateSet('A','B','C')][string[]]$Arms = @('A','B'),
  [string]$BaseUrl   = 'http://127.0.0.1:11434',
  [int]$NumCtx       = 16384,
  [int]$NumPredict   = 12288,
  [double]$Temperature = 0.8,
  [string]$OutDir,
  # Print the built prompts and exit. Run this first and eyeball them.
  [switch]$WhatIfPrompt
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root       = Split-Path -Parent $PSScriptRoot          # repo root
$reviewerMd = Join-Path $PSScriptRoot 'reviewer.md'
$clauseMd   = Join-Path $PSScriptRoot 'r3-ledger-clause.md'
$inputMd    = Join-Path $PSScriptRoot 'raw\r2-remeasure-input.md'
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'raw\r3' }

# --- Contamination guard -----------------------------------------------------
# The grader key must never reach a model, and must never be read by whatever
# is driving this script. Fail loudly rather than silently producing a void run.
$keyMd = Join-Path $PSScriptRoot 'raw\r2-remeasure-key.md'
foreach ($p in @($reviewerMd, $clauseMd, $inputMd)) {
  if ((Resolve-Path $p).Path -eq (Resolve-Path $keyMd -ErrorAction SilentlyContinue).Path) {
    throw "Refusing to run: grader key is wired in as a prompt source."
  }
}

foreach ($p in @($reviewerMd, $clauseMd, $inputMd)) {
  if (-not (Test-Path $p)) { throw "Missing required file: $p" }
}

# --- Build the prompts -------------------------------------------------------
function Get-Between {
  param([string[]]$Lines, [string]$StartPattern, [string]$EndPattern, [switch]$IncludeEnd)
  $i = ($Lines | Select-String -Pattern $StartPattern | Select-Object -First 1).LineNumber
  if (-not $i) { throw "Start pattern not found: $StartPattern" }
  $rest = $Lines[$i..($Lines.Count - 1)]
  $j = ($rest | Select-String -Pattern $EndPattern | Select-Object -First 1).LineNumber
  if (-not $j) { throw "End pattern not found: $EndPattern" }
  $endIdx = if ($IncludeEnd) { $i + $j - 1 } else { $i + $j - 2 }
  return ($Lines[($i - 1)..$endIdx] -join "`n")
}

$reviewerLines = Get-Content -LiteralPath $reviewerMd -Encoding utf8
$inputLines    = Get-Content -LiteralPath $inputMd    -Encoding utf8
$clauseLines   = Get-Content -LiteralPath $clauseMd   -Encoding utf8

# reviewer.md: the prompt body lives between the two bare '---' rules.
$promptBody = Get-Between -Lines $reviewerLines -StartPattern '^---$' -EndPattern '^---$'
$promptBody = ($promptBody -split "`n" | Select-Object -Skip 1) -join "`n"   # drop the opening ---

# the input's three sections, verbatim, END-RUN marker included
$inputBody = Get-Between -Lines $inputLines -StartPattern "^\[AUDITOR'S SECTION 1" -EndPattern '^<!-- END-RUN -->' -IncludeEnd

# the treatment clause
$clause = Get-Between -Lines $clauseLines -StartPattern '^<!-- BEGIN-CLAUSE -->' -EndPattern '^<!-- END-CLAUSE -->'
$clause = ($clause -split "`n" | Select-Object -Skip 1) -join "`n"

# Substitute the three placeholder lines with the real material.
$placeholderRx = "(?m)^\[AUDITOR'S SECTION 1[^\r\n]*\r?\n\[AUDITOR'S SECTION 2[^\r\n]*\r?\n\[PLAN'S TEST CHANGES[^\r\n]*$"
if ($promptBody -notmatch $placeholderRx) {
  throw "reviewer.md placeholder block not found - the prompt controller has changed shape. Stop and re-check before running."
}
$promptA = [regex]::Replace($promptBody, $placeholderRx, { param($m) $inputBody })

$anchorRx = '(?m)^For EACH numbered command:'
if ($promptA -notmatch $anchorRx) { throw "Anchor 'For EACH numbered command:' not found in reviewer.md." }
$promptB = [regex]::Replace($promptA, $anchorRx, { param($m) "$clause`n`n" + $m.Value }, 1)

# Arm C: Arm B with the two seam bullets that telegraph the answer removed.
# See r3-protocol.md - optional, answers "is seam 5 being echoed, not derived?"
$promptC = $promptB
foreach ($leak in @(
  '(?ms)^- eligibility/pairing semantics.*?unrelated legendaries must be rejected\r?\n',
  '(?ms)^- named-commander inputs get the full legality surface.*?pasted bulk list\r?\n'
)) { $promptC = [regex]::Replace($promptC, $leak, '') }

$prompts = @{ A = $promptA; B = $promptB; C = $promptC }

function Get-Sha256([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) -replace '-','').ToLower().Substring(0,16) }
  finally { $sha.Dispose() }
}

if ($WhatIfPrompt) {
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  foreach ($a in $Arms) {
    $f = Join-Path $OutDir "prompt-arm$a.txt"
    Set-Content -LiteralPath $f -Value $prompts[$a] -Encoding utf8
    Write-Host ("Arm {0}: {1} chars, sha {2} -> {3}" -f $a, $prompts[$a].Length, (Get-Sha256 $prompts[$a]), $f)
  }
  Write-Host "`nPrompts written. Read them, confirm no key material, then re-run without -WhatIfPrompt."
  return
}

# --- Preflight ---------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

try { $tags = Invoke-RestMethod -Uri "$BaseUrl/api/tags" -TimeoutSec 15 }
catch { throw "Ollama not reachable at $BaseUrl. Start it and retry. ($_)" }
$installed = @($tags.models | ForEach-Object { $_.name })

$missing = @($Models | Where-Object { $installed -notcontains $_ })
if ($missing.Count) {
  throw ("Not installed: {0}`nInstalled: {1}`nPull them deliberately (they are large) or drop them from -Models; this script will not pull." -f ($missing -join ', '), ($installed -join ', '))
}

$manifest = Join-Path $OutDir 'manifest.tsv'
if (-not (Test-Path $manifest)) {
  "run_id`tmodel`tarm`tseed`ttemperature`tnum_ctx`tnum_predict`tprompt_sha`tprompt_eval_count`teval_count`tdone_reason`twall_ms`tcontent_chars`tcontent_file" |
    Set-Content -LiteralPath $manifest -Encoding utf8
}

Write-Host ("Round 3: {0} model(s) x {1} arm(s) x {2} draw(s) = {3} runs" -f $Models.Count, $Arms.Count, $Draws, ($Models.Count * $Arms.Count * $Draws))
foreach ($a in $Arms) { Write-Host ("  Arm {0} prompt sha: {1}" -f $a, (Get-Sha256 $prompts[$a])) }

# --- Run ---------------------------------------------------------------------
foreach ($model in $Models) {
  foreach ($arm in $Arms) {
    for ($d = 1; $d -le $Draws; $d++) {

      $seed   = $d                      # 1,2,3 - reproducible AND distinct
      $runId  = "{0}-arm{1}-d{2}" -f ($model -replace '[:.]','_'), $arm, $d
      $jsonF  = Join-Path $OutDir "$runId.json"
      $txtF   = Join-Path $OutDir "$runId.txt"

      if (Test-Path $jsonF) { Write-Host "  skip (exists): $runId"; continue }

      $body = @{
        model    = $model
        think    = $false               # r2 run 2a burned the whole budget on the reasoning block
        stream   = $false
        messages = @(@{ role = 'user'; content = $prompts[$arm] })
        options  = @{
          seed        = $seed
          temperature = $Temperature
          num_ctx     = $NumCtx
          num_predict = $NumPredict
        }
      } | ConvertTo-Json -Depth 8 -Compress

      Write-Host ("  running {0} ..." -f $runId) -NoNewline
      $sw = [Diagnostics.Stopwatch]::StartNew()
      try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/api/chat" -Method Post `
                  -ContentType 'application/json; charset=utf-8' `
                  -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 1800
      } catch {
        $sw.Stop(); Write-Host " FAILED"
        Write-Warning "$runId failed: $_"
        continue
      }
      $sw.Stop()

      $resp | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonF -Encoding utf8
      $content = if ($resp.message -and $resp.message.content) { $resp.message.content } else { '' }
      Set-Content -LiteralPath $txtF -Value $content -Encoding utf8

      $row = @(
        $runId, $model, $arm, $seed, $Temperature, $NumCtx, $NumPredict,
        (Get-Sha256 $prompts[$arm]),
        $(if ($resp.PSObject.Properties.Name -contains 'prompt_eval_count') { $resp.prompt_eval_count } else { '' }),
        $(if ($resp.PSObject.Properties.Name -contains 'eval_count')        { $resp.eval_count }        else { '' }),
        $(if ($resp.PSObject.Properties.Name -contains 'done_reason')       { $resp.done_reason }       else { '' }),
        $sw.ElapsedMilliseconds, $content.Length, (Split-Path -Leaf $txtF)
      ) -join "`t"
      Add-Content -LiteralPath $manifest -Value $row -Encoding utf8

      Write-Host (" done  eval={0} tok, {1:n1}s, {2}" -f $resp.eval_count, ($sw.ElapsedMilliseconds/1000), $resp.done_reason)

      if ($content.Length -lt 50) {
        Write-Warning "$runId returned near-empty content - check done_reason. If 'length', the reasoning-budget trap is back."
      }
    }
  }
  # free VRAM before the next model; native stderr must not kill the run
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  & ollama stop $model 2>&1 | Out-Null
  $ErrorActionPreference = $prev
}

Write-Host "`nDone. Manifest: $manifest"
Write-Host "Commit the whole of $OutDir - raw outputs are the deliverable."
Write-Host "Do NOT grade these locally and do NOT open raw\r2-remeasure-key.md."

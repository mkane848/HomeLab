param(
  [string]$InputPath = "M:\Projects\dev-docs\docs\review-gate\r2-remeasure-input.md"
)
$ErrorActionPreference = 'Stop'
$raw = Get-Content -LiteralPath $InputPath -Raw
$nl = [Environment]::NewLine

function Get-Section([string]$raw, [string]$start, [string]$end) {
  $i = $raw.IndexOf($start)
  if ($i -lt 0) { return '' }
  $j = if ($end) { $raw.IndexOf($end, $i) } else { $raw.Length }
  if ($j -lt 0) { $j = $raw.Length }
  return $raw.Substring($i, $j - $i)
}

$sec1 = Get-Section $raw '[AUDITOR''S SECTION 1' '[AUDITOR''S SECTION 2'
$sec2 = Get-Section $raw '[AUDITOR''S SECTION 2' '[PLAN''S TEST CHANGES'
$sec3 = Get-Section $raw '[PLAN''S TEST CHANGES' '<!-- END-RUN -->'

$results = [System.Collections.Generic.List[object]]::new()
function Add-Seam([string]$id, [string]$label, [bool]$covered, [string]$evidence) {
  $results.Add([pscustomobject]@{ id = $id; label = $label; status = $(if ($covered) { 'COVERED' } else { 'UNCOVERED' }); evidence = $evidence })
}

# Seam 1 — JSON-string fields decoded before consumed
$s1 = $sec3 -match 'decodes the JSON-string color_identity column before checking'
Add-Seam '1' 'JSON-string color_identity decoded before use' $s1 "unit test named for decoding: $s1"

# Seam 2 — whole-dataset counting including banned/notFound
$s2 = ($sec3 -match 'banned card still occupies a deck slot') -and ($sec3 -match 'unparseable card still occupies a deck slot')
Add-Seam '2' 'deck size counts whole pasted deck incl. banned/notFound' $s2 "banned-slot+notFound-slot tests present: $s2"

# Seam 3 — strict typing (no TS `any` escape in the contract)
$typingLeak = ($sec2 + $sec3) -match "`"any`"|`:?\sany\s*(?:type|\[\s*\])|as any\b"
Add-Seam '3' 'strict typing, no `any` escape' (-not $typingLeak) "TS-escape tokens found: $typingLeak"

# Seam 4 — eligibility/pairing basis (ineligible commander; legal partner union; unrelated legendaries rejected)
$partnerUnion = $sec3 -match 'legal Partner pair is one commander unit with the union identity'
$invalidUnit   = $sec3 -match 'two legendary cards without a pairing ability are not a legal unit'
$ineligible    = $sec3 -match 'a card that is not commander-eligible cannot be named commander'
$s4 = $partnerUnion -and $invalidUnit -and $ineligible
Add-Seam '4' 'eligibility + pairing basis (solo/partner/unrelated)' $s4 "ineligible=$ineligible partnerUnion=$partnerUnion invalidUnit=$invalidUnit"

# Seam 5 — Background pairing branch actually exercised (the pair must appear in commanders)
$bgTest = [regex]::Match($sec3, '(?s)a Background companion needs the legal Background to pair.*?(?=\n  - |\n\n)').Value
$cmdMatch = [regex]::Match($bgTest, '(?s)commanders\s*`([^`]+)`')
$cmdArg = if ($cmdMatch.Success) { $cmdMatch.Groups[1].Value } else { '' }
$pairInCommanders = $cmdArg -match ','
$bgSeam = $pairInCommanders
$evidence5 = "test commanders arg: [$cmdArg]; contains pair (second entry): $pairInCommanders"
Add-Seam '5' 'Background pairing/eligibility path exercised (pair present in commanders)' $bgSeam $evidence5

# Seam 6 — named commander inputs get direct legality_commander (ban) check
# Detection: any quoted test *title* that contains a standalone "commander"
# word AND a standalone "banned" word (e.g. "a banned commander cannot be
# named commander"). Substring tests are avoided on purpose: "commander" is a
# substring of legality_commander/is_commander_eligible/eligibleCommander, and
# a legality_commander:'banned' on a *deck* card is not a commander-ban test.
$titles = [regex]::Matches($sec3, '(?m)^\s*-\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
$cmdBanned = $false
foreach ($t in $titles) {
  if (($t -match '(?i)\bcommander\b') -and ($t -match '(?i)\bbanned\b')) { $cmdBanned = $true; break }
}
$contractBan = $sec2 -match '(?i)commanders.{0,160}(legality_commander|banned)|(?:legality_commander|banned).{0,60}(?:commander|commanders)'
$s6 = $cmdBanned -or $contractBan
Add-Seam '6' 'named-commander legality check (direct legality_commander on resolved commanders)' $s6 "test-level banned-commander=$cmdBanned; contract-level direct check=$contractBan"

# Verdict
$uncovered = @($results | Where-Object { $_.status -eq 'UNCOVERED' })
$verdict = if ($uncovered.Count -gt 0) { 'RED-MARK' } else { 'FIRST-RUN-SAFE' }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Deterministic seam-checker output')
$lines.Add('')
$lines.Add("Input: $InputPath")
$lines.Add("Pseudo-reviewer: rule-based; no model. Generated $(Get-Date -Format o)")
$lines.Add('')
foreach ($r in $results) {
  $lines.Add("- Seam $($r.id) [$($r.status)] $($r.label) — $($r.evidence)")
}
$lines.Add('')
$lines.Add("**Verdict: $verdict**")
if ($uncovered.Count -gt 0) {
  $lines.Add(('Uncovered seams: ' + (($uncovered | ForEach-Object { $_.id }) -join ', ')))
}
$lines.Add('')
$lines.Add('> Interpretation: the robot has no model risk and no reasoning — it reads the staged test-inventory exactly. A RED-MARK here means the plan, as written in the input, does not contain the specified coverage. Compare against the LLM seats on the same input.')

$out = "M:\Projects\dev-docs\docs\review-gate\r2-robot-output.md"
$lines | Set-Content -LiteralPath $out -Encoding utf8
Write-Output ($lines -join $nl)
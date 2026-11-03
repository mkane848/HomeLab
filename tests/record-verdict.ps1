# record-verdict.ps1 - the owner's verdict on a delivered branch (tests/deliver-attempt.ps1), next to the run that made
# it. For real work there are no hidden tests: this verdict is the truth the gate is measured against (a "kept but
# wrong" is an accepted delivery the owner rejected or had to fix; a near miss the owner merged as is is a gate that
# was too strict). Appends one row to verdicts.tsv in -ResultsDir.
#
#   pwsh -File tests\record-verdict.ps1 -ResultsDir <run folder> -Task <id> -Verdict merged|fixed|rejected [-Note "..."] [-Branch fleet/x]
#     merged    merged as delivered
#     fixed     merged after the owner changed it (say what in -Note)
#     rejected  not merged (say why in -Note)
# Exit 0 recorded, 3 bad arguments (no delivery of that task, or an unknown branch).
param(
    [Parameter(Mandatory)][string]$ResultsDir,
    [Parameter(Mandatory)][string]$Task,
    [Parameter(Mandatory)][ValidateSet("merged", "fixed", "rejected")][string]$Verdict,
    [string]$Note = "",
    [string]$Branch = ""
)
$ErrorActionPreference = "Stop"
$ledger = Join-Path $ResultsDir "deliveries.tsv"
if (-not (Test-Path -LiteralPath $ledger)) { Write-Host "ERROR: no deliveries.tsv in $ResultsDir (deliver the attempt first)" -ForegroundColor Red; exit 3 }
$rows = @(Import-Csv -LiteralPath $ledger -Delimiter "`t" | Where-Object { $_.task -eq $Task -and (-not $Branch -or $_.branch -eq $Branch) })
if (-not $rows.Count) { Write-Host "ERROR: no delivery of $Task$(if ($Branch) { " on $Branch" }) in $ledger" -ForegroundColor Red; exit 3 }
$d = $rows[-1]
if ($Verdict -ne "merged" -and -not $Note) { Write-Host "ERROR: -Note is required for '$Verdict' (what was fixed, or why it was rejected)" -ForegroundColor Red; exit 3 }
$out = Join-Path $ResultsDir "verdicts.tsv"
if (-not (Test-Path -LiteralPath $out)) { Set-Content -LiteralPath $out -Value ("timestamp`ttask`tbranch`tcommit`tkind`tverdict`tnote") -Encoding utf8 }
$clean = ($Note -replace "[`t`r`n]+", " ").Trim()
Add-Content -LiteralPath $out -Value (@((Get-Date -Format "yyyy-MM-ddTHH:mm:ss"), $Task, $d.branch, $d.commit, $d.kind, $Verdict, $clean) -join "`t") -Encoding utf8
$meaning = switch ("$($d.kind)|$Verdict") {
    "accepted|merged" { "the gate was right" }
    "accepted|fixed" { "kept but not quite right: count it against the gate" }
    "accepted|rejected" { "kept but wrong: a false positive" }
    "near miss|merged" { "rejected but right: the gate was too strict (a false negative)" }
    default { "a near miss that needed work: the gate was right to hold it" }
}
Write-Host ("recorded: {0} {1} ({2}) {3} - {4}" -f $Task, $d.branch, $d.kind, $Verdict, $meaning) -ForegroundColor Green
exit 0

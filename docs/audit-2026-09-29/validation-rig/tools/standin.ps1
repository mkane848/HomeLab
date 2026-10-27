# standin.ps1 - stands in for `opencode` so the REAL tests/test-tasks.ps1 can grade a KNOWN change.
# Modes ($env:RIG_MODE): ref = source fix + tests; srconly = source fix only; testsonly = tests only; blind = <id>.blind.patch (a blind solver's whole change).
# Patches come from $env:RIG_REF/<taskId>.src.patch and <taskId>.test.patch (git-apply'd to the worktree).
$a = @($args)
if ($a.Count -gt 0 -and $a[0] -eq '--version') { 'rig-standin'; exit 0 }
if ($a.Count -gt 0 -and $a[0] -eq 'debug')      { '{}'; exit 0 }
if ($a.Count -gt 0 -and $a[0] -eq 'run') {
    $dir  = $a[[array]::IndexOf($a, '--dir') + 1]
    $id   = Split-Path -Leaf $dir
    $mode = $env:RIG_MODE
    $kinds = switch ($mode) { 'ref' { @('src', 'test') } 'srconly' { @('src') } 'testsonly' { @('test') } 'blind' { @('blind') } default { @() } }
    '{"type":"step_start","part":{"type":"step-start"}}'
    foreach ($k in $kinds) {
        $p = Join-Path $env:RIG_REF "$id.$k.patch"
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $created = @(& git -C $dir apply --summary $p | Where-Object { $_ -match '^\s*create mode' } | ForEach-Object { ($_ -split '\s+', 5)[4] })
        $names   = @(& git -C $dir apply --numstat $p | ForEach-Object { ($_ -split "`t")[2] })
        & git -C $dir apply --whitespace=nowarn $p
        if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("rig: git apply failed for $p"); exit 3 }
        foreach ($n in $names) {
            $tool = if ($created -contains $n) { 'write' } else { 'edit' }
            (@{ type = 'tool_use'; part = @{ tool = $tool; state = @{ status = 'completed'; input = @{ filePath = (Join-Path $dir $n) } } } } | ConvertTo-Json -Compress -Depth 6)
        }
    }
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2

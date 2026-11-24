# Rig stand-in for opencode: "makes the model's change" by applying the task's reference patches.
# RIG_MODE: ref | srconly | testsonly. RIG_PATCHES: the patches folder.
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $i = [array]::IndexOf($a, '--dir'); $dir = if ($i -ge 0) { $a[$i + 1] } else { (Get-Location).Path }
    $id = Split-Path -Leaf $dir
    $kinds = switch ($env:RIG_MODE) { 'ref' { @('src', 'tests') } 'srconly' { @('src') } 'testsonly' { @('tests') } default { @() } }
    $files = @()
    foreach ($k in $kinds) {
        $p = Join-Path $env:RIG_PATCHES "$id.$k.patch"
        git -C $dir apply --whitespace=nowarn $p 2>&1 | Out-Host
        if ($LASTEXITCODE) { [Console]::Error.WriteLine("standin: apply failed $p"); exit 3 }
        $files += @(git -C $dir apply --numstat $p | ForEach-Object { ($_ -split "`t")[2] })
    }
    '{"type":"step_start","part":{"type":"step-start"}}'
    foreach ($f in $files) { '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"' + $f + '"}}}}' }
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2

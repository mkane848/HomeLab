$ErrorActionPreference = "Stop"
$real = "/home/user/HomeLab/tests/test-tasks.ps1"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("e2e-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path "$tmp/tests/tasks", "$tmp/bin", "$tmp/repo" -Force | Out-Null
Copy-Item $real "$tmp/tests/test-tasks.ps1"
$psExe = (Get-Process -Id $PID).Path

# fixture repo
git -C "$tmp/repo" init -q; git -C "$tmp/repo" symbolic-ref HEAD refs/heads/main
git -C "$tmp/repo" config user.email t@example.invalid; git -C "$tmp/repo" config user.name t
Set-Content "$tmp/repo/src.txt" "buggy"
@'
param([ValidateSet('unset','set')][string]$Mode)
$v = [Environment]::GetEnvironmentVariable('DATABASE_URL')
if ($Mode -eq 'unset' -and $v) { Write-Host "ENV LEAK: DATABASE_URL=$v"; exit 3 }
if ($Mode -eq 'set' -and -not $v) { Write-Host "ENV MISSING: DATABASE_URL"; exit 4 }
$src = (Get-Content -LiteralPath src.txt -Raw).Trim()
if ((Test-Path test.txt) -and $src -ne 'fixed') { Write-Host "Tests  1 failed (1)"; exit 1 }
Write-Host "Tests  1 passed (1)"; exit 0
'@ | Set-Content "$tmp/repo/check.ps1"
git -C "$tmp/repo" add -A; git -C "$tmp/repo" commit -q -m base
$base = (git -C "$tmp/repo" rev-parse HEAD).Trim()

function Task($id, $mode, $env) {
    $t = [ordered]@{ id = $id; title = $id; repo = "$tmp/repo"; branch = "bench/$id"; benchBaseCommit = $base
        baselineExpect = @{ testsTotal = 1; testsPass = 1 }; allowFiles = @("src.txt", "test.txt"); srcRevertFiles = @("src.txt")
        testDir = "."; testCmd = @($psExe, "-NoProfile", "-File", "check.ps1", "-Mode", $mode); installFlags = @(); prompt = "fix it" }
    if ($env) { $t.testEnv = $env }
    return $t
}
$manifest = @{ tasks = @((Task "fx-a" "unset" ([ordered]@{ DATABASE_URL = $null })), (Task "fx-b" "set" $null)) }
$manifest | ConvertTo-Json -Depth 8 | Set-Content "$tmp/tests/tasks/manifest.json"

# stand-in opencode
@'
$a = @($args)
if ($a[0] -eq '--version') { '9.9.9-fixture'; exit 0 }
if ($a[0] -eq 'debug') { '{}'; exit 0 }
if ($a[0] -eq 'run') {
    $dir = $a[[array]::IndexOf($a, '--dir') + 1]
    $v = [Environment]::GetEnvironmentVariable('DATABASE_URL')
    Add-Content -LiteralPath $env:FIXTURE_OUT -Value ("{0} DATABASE_URL={1}" -f (Split-Path -Leaf $dir), $(if ($v) { $v } else { '<unset>' }))
    Set-Content -LiteralPath (Join-Path $dir 'src.txt') -Value 'fixed'
    Set-Content -LiteralPath (Join-Path $dir 'test.txt') -Value 'a test'
    '{"type":"step_start","part":{"type":"step-start"}}'
    '{"type":"tool_use","part":{"tool":"edit","state":{"status":"completed","input":{"filePath":"src.txt"}}}}'
    '{"type":"tool_use","part":{"tool":"write","state":{"status":"completed","input":{"filePath":"test.txt"}}}}'
    '{"type":"step_finish","part":{"reason":"stop","tokens":{"output":5}}}'
    exit 0
}
exit 2
'@ | Set-Content "$tmp/bin/standin.ps1"
$sep = [IO.Path]::DirectorySeparatorChar
if ($sep -eq '\') {
    "@echo off`r`n`"$psExe`" -NoProfile -File `"$tmp\bin\standin.ps1`" %*" | Set-Content "$tmp\bin\opencode.cmd" -Encoding ascii
} else {
    "#!/bin/sh`nexec `"$psExe`" -NoProfile -File `"$tmp/bin/standin.ps1`" `"`$@`"`n" | Set-Content "$tmp/bin/opencode" -NoNewline
    chmod +x "$tmp/bin/opencode"
}

$env:FIXTURE_OUT = "$tmp/saw.txt"
$env:DATABASE_URL = "ambient-value"
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
$oldPath = $env:PATH
$env:PATH = "$tmp/bin$([IO.Path]::PathSeparator)$env:PATH"
try {
    $out = & "$tmp/tests/test-tasks.ps1" -Task fx-a, fx-b -Model fixture/m -SkipInstall -RunTimeout 120 *>&1 | Out-String
    $code = $LASTEXITCODE
} finally { $env:PATH = $oldPath }
Write-Host $out
Write-Host "exit code: $code"
Write-Host "--- what the stand-in opencode saw:"; Get-Content "$tmp/saw.txt"
Write-Host "--- parent env afterwards: DATABASE_URL=$env:DATABASE_URL"
Get-ChildItem "$tmp/tests/results" | ForEach-Object { $_.Name }
foreach ($f in Get-ChildItem "$tmp/tests/results" -Filter *.json) { $j = Get-Content $f -Raw | ConvertFrom-Json; "{0}: gates {1}/{2}/{3} testEnv={4}" -f $j.taskId, $j.gates.scope, $j.gates.suite, $j.gates.failsOnOld, ($j.testEnv | ConvertTo-Json -Compress) }
Write-Host "tmp: $tmp"

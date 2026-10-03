# test-opencode-profiles.ps1 - regression guard for `opencode <profile>`
#
# Why this exists: desktop\scripts\opencode-profiles.ps1 puts an `opencode`
# function in front of the real command in every PowerShell session. Get it wrong
# and every opencode call breaks: a subcommand ("run", "debug") mistaken for a
# profile, an argument with a space split in two, the function calling itself, or
# a launch leaving the shell on the last profile's models so a later bare
# `opencode` silently is not bare.
#
# What it does:
#   1. Name resolution (Resolve-OpencodeProfile) against a fixture profiles/ dir:
#      full name, short names, case, parked profiles, select-model.sh, subcommands.
#   2. Routing through the REAL shim, with a stand-in launcher and a stand-in
#      opencode first on PATH: profile names go to the launcher with the rest of
#      the arguments intact; everything else goes to opencode untouched.
#   3. The REAL launcher end to end (needs Git Bash) against the real
#      dev-workflow-quality profile with -NoWarm -KeepLoaded, so nothing touches
#      Ollama: opencode sees the profile's model, and the shell's env is restored.
# Exit 1 on any failure.
#
# Usage:  .\tests\test-opencode-profiles.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

$script:fail = 0
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ocp-test-" + [guid]::NewGuid().ToString("N"))
$fixture = Join-Path $tmp "repo"
$bin = Join-Path $tmp "bin"
$record = Join-Path $tmp "record.txt"
New-Item -ItemType Directory -Force (Join-Path $fixture "profiles\parked"), (Join-Path $fixture "desktop\scripts"), $bin | Out-Null
foreach ($p in "dev-workflow-quality", "dev-workflow-resident", "dev-desktop-only", "dev-node3", "select-model") {
    Set-Content (Join-Path $fixture "profiles\$p.sh") "# fixture"
}
Set-Content (Join-Path $fixture "profiles\parked\dev-workflow-server.sh") "# fixture"

# Stand-in launcher: records what the shim passed it.
Set-Content (Join-Path $fixture "desktop\scripts\opencode.ps1") @'
[CmdletBinding(PositionalBinding = $false)]
param([string]$Profile, [switch]$NoWarm, [switch]$KeepLoaded,
      [Parameter(ValueFromRemainingArguments = $true)][string[]]$OpenCodeArgs = @())
"launcher profile=$Profile nowarm=$([bool]$NoWarm) args=$($OpenCodeArgs -join '|')" | Set-Content $env:OCP_TEST_RECORD
'@
# Stand-in opencode: records what reached "the real" command, and the model env it saw.
Set-Content (Join-Path $bin "opencode.ps1") @'
"real args=$($args -join '|') model=$env:OPENCODE_MODEL" | Set-Content $env:OCP_TEST_RECORD
'@

$savedPath = $env:PATH
$savedModel = $env:OPENCODE_MODEL
$env:OCP_TEST_RECORD = $record
try {
    . (Join-Path $repo "desktop\scripts\opencode-profiles.ps1")
    Check "shim points at this repo" $global:OpencodeProfilesRepo $repo

    Write-Host "-- name resolution"
    $pd = Join-Path $fixture "profiles"
    Check "full name"                    (Resolve-OpencodeProfile "dev-workflow-quality" $pd) "dev-workflow-quality"
    Check "short name"                   (Resolve-OpencodeProfile "quality" $pd) "dev-workflow-quality"
    Check "short name, any case"         (Resolve-OpencodeProfile "Resident" $pd) "dev-workflow-resident"
    Check "dev- prefix dropped"          (Resolve-OpencodeProfile "desktop-only" $pd) "dev-desktop-only"
    Check "dev- prefix dropped (node3)"  (Resolve-OpencodeProfile "node3" $pd) "dev-node3"
    Check "parked profile is not live"   (Resolve-OpencodeProfile "server" $pd) ""
    Check "select-model is not a profile" (Resolve-OpencodeProfile "select-model" $pd) ""
    Check "subcommand run is not a profile"   (Resolve-OpencodeProfile "run" $pd) ""
    Check "subcommand debug is not a profile" (Resolve-OpencodeProfile "debug" $pd) ""
    Check "a flag is not a profile"      (Resolve-OpencodeProfile "--version" $pd) ""
    Check "empty is not a profile"       (Resolve-OpencodeProfile "" $pd) ""

    Write-Host "-- routing (stand-in launcher and opencode)"
    $global:OpencodeProfilesRepo = $fixture
    $env:PATH = "$bin;$savedPath"
    function Last { (Get-Content $record -Raw).Trim() }

    opencode quality
    Check "opencode quality -> launcher" (Last) "launcher profile=dev-workflow-quality nowarm=False args="
    opencode resident run "fix the bug in a.ts" --model ollama-desktop/qwen3:8b
    Check "args after the name pass through intact" (Last) "launcher profile=dev-workflow-resident nowarm=False args=run|fix the bug in a.ts|--model|ollama-desktop/qwen3:8b"
    opencode quality -NoWarm
    Check "launcher switches still bind" (Last) "launcher profile=dev-workflow-quality nowarm=True args="
    $env:OPENCODE_MODEL = "sentinel"
    opencode run "hello world"
    Check "a subcommand goes to the real opencode" (Last) "real args=run|hello world model=sentinel"
    opencode
    Check "bare opencode goes to the real opencode" (Last) "real args= model=sentinel"
    opencode --version
    Check "a flag goes to the real opencode" (Last) "real args=--version model=sentinel"

    Write-Host "-- the real launcher (Git Bash, real dev-workflow-quality profile, no Ollama calls)"
    $global:OpencodeProfilesRepo = $repo
    $want = (Select-String -Path (Join-Path $repo "profiles\dev-workflow-quality.sh") -Pattern '^export OPENCODE_MODEL="([^"]+)"').Matches[0].Groups[1].Value
    opencode quality -NoWarm -KeepLoaded run "x y" *> $null
    Check "opencode saw the profile's model, args intact" (Last) "real args=run|x y model=$want"
    Check "the shell's OPENCODE_MODEL is restored" $env:OPENCODE_MODEL "sentinel"
    Remove-Item Env:OPENCODE_MODEL
    opencode quality -NoWarm -KeepLoaded *> $null
    Check "an unset variable is unset again" ([string]::IsNullOrEmpty($env:OPENCODE_MODEL)) "True"
} finally {
    $env:PATH = $savedPath
    if ($null -eq $savedModel) { Remove-Item Env:OPENCODE_MODEL -ErrorAction SilentlyContinue } else { $env:OPENCODE_MODEL = $savedModel }
    Remove-Item Env:OCP_TEST_RECORD -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:fail) { Write-Host "$($script:fail) FAILED"; exit 1 }
Write-Host "all passed"

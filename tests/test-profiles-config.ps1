# protects: tests/test-profiles.ps1 reads the live OpenCode config in both key sets: 2.x (providers, settings.baseURL, capabilities.tools) and 1.x (provider, options.baseURL, tool_call), the same answers from each
# run-after: tests/test-profiles.ps1, opencode/global/opencode.jsonc
# mutation: tests/test-profiles.ps1
# mutation-from: if ($Config.PSObject.Properties['providers']) { return $Config.providers }
# mutation-to: if ($false) { return $Config.providers }
# mutation-expect: FAIL\s+2\.x template: the providers are found
# mutation: tests/test-profiles.ps1
# mutation-from: if ($cap -and $cap.Value -and $cap.Value.PSObject.Properties['tools']) { return ($cap.Value.tools -eq $true) }
# mutation-to: if ($false) { return ($cap.Value.tools -eq $true) }
# mutation-expect: FAIL\s+2\.x template: llamacpp-server/qwen3\.6:35b-a3b-coding is tool-capable
# mutation: tests/test-profiles.ps1
# mutation-from: foreach ($key in @('settings', 'options')) {
# mutation-to: foreach ($key in @('options')) {
# mutation-expect: FAIL\s+2\.x template: llamacpp-server's baseURL names LLAMACPP_SERVER_BASE_URL
# test-profiles-config.ps1 - regression guard for how tests/test-profiles.ps1 reads the opencode config.
#
# Why this exists: test-profiles.ps1 parses the LIVE config file itself (not `opencode debug config`) for its
# registration, schema, tool-capability and host checks. Step 5.1 of docs/opencode-2-migration.md (2026-11-27) moved
# the template to OpenCode 2.x's own keys, and a live config keeps the 1.x keys until sync-opencode.ps1 stages the new
# template. Read with the 1.x names only, a 2.x config has no `provider`, so every registration check would FAIL, and
# the main seat would read as unable to call tools, so -Reliability would SKIP it. test-profiles.ps1 itself needs live
# hosts and is not run in CI, so this guard runs its config readers alone.
# What it does: loads ConvertFrom-Jsonc, Get-ConfigProviders, Get-ProviderBaseUrl, Test-ModelToolCapable and
# Get-ProviderEnvVar from test-profiles.ps1 (by AST: the script runs on load), then asks the same questions of the
# repo's real template (2.x keys) and of a 1.x fixture with the same seats, and expects the same answers.
#
# Usage:  pwsh -NoProfile -File tests/test-profiles-config.ps1
$ErrorActionPreference = "Stop"
$script:fail = 0
. (Join-Path $PSScriptRoot "lib/guard.ps1")

$repo = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $PSScriptRoot "test-profiles.ps1"
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
if ($errs.Count) { Write-Host "FAIL test-profiles.ps1 does not parse: $($errs[0].Message)"; exit 2 }
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($w in @("ConvertFrom-Jsonc", "Get-ConfigProviders", "Get-ProviderBaseUrl", "Test-ModelToolCapable", "Get-ProviderEnvVar")) {
    $fn = $fns | Where-Object { $_.Name -eq $w } | Select-Object -First 1
    if (-not $fn) { Write-Host "FAIL $w not found in test-profiles.ps1"; exit 2 }
    Invoke-Expression $fn.Extent.Text
}

# The answers test-profiles.ps1 needs, for one parsed config.
function Get-Answers($cfg) {
    $prov = Get-ConfigProviders $cfg
    $model = { param($p, $m) if ($prov -and $prov.PSObject.Properties[$p]) { $prov.$p.models.PSObject.Properties[$m].Value } }
    [ordered]@{
        found     = [bool]$prov
        serverEnv = Get-ProviderEnvVar -Providers $prov -ProviderName "llamacpp-server"
        node3Env  = Get-ProviderEnvVar -Providers $prov -ProviderName "llamacpp-node3"
        goEnv     = "$(Get-ProviderEnvVar -Providers $prov -ProviderName "opencode-go")"
        mainTools = Test-ModelToolCapable (& $model "llamacpp-server" "qwen3.6:35b-a3b-coding")
        cpuTools  = Test-ModelToolCapable (& $model "llamacpp-server" "qwen2.5-coder-3b-cpu")
        node3Lim  = "$((& $model "llamacpp-node3" "qwen3:8b").limit.context)/$((& $model "llamacpp-node3" "qwen3:8b").limit.output)"
    }
}

Write-Host "-- the repo's template (OpenCode 2.x keys)"
$v2 = Get-Answers (ConvertFrom-Jsonc (Get-Content -LiteralPath (Join-Path $repo "opencode/global/opencode.jsonc") -Raw))
Check "2.x template: the providers are found" $v2.found "True"
Check "2.x template: llamacpp-server's baseURL names LLAMACPP_SERVER_BASE_URL" $v2.serverEnv "LLAMACPP_SERVER_BASE_URL"
Check "2.x template: llamacpp-node3's baseURL names LLAMACPP_NODE3_BASE_URL" $v2.node3Env "LLAMACPP_NODE3_BASE_URL"
Check "2.x template: opencode-go has no baseURL variable" $v2.goEnv ""
Check "2.x template: llamacpp-server/qwen3.6:35b-a3b-coding is tool-capable" $v2.mainTools "True"
Check "2.x template: llamacpp-server/qwen2.5-coder-3b-cpu is not" $v2.cpuTools "False"
Check "2.x template: llamacpp-node3/qwen3:8b limit 32768/4096" $v2.node3Lim "32768/4096"

Write-Host "-- a live config still on the 1.x keys (before sync-opencode.ps1 stages the 2.x template)"
$v1Text = @'
{
  "model": "{env:OPENCODE_MODEL}",
  "provider": {
    "opencode-go": { "options": { "apiKey": "{file:.secrets/opencode-go-api-key}" } },
    "llamacpp-server": {
      "npm": "@ai-sdk/openai-compatible",
      "models": {
        // a comment, as in the real file
        "qwen3.6:35b-a3b-coding": { "tool_call": true, "limit": { "context": 65536, "output": 16384 } },
        "qwen2.5-coder-3b-cpu": { "tool_call": false, "limit": { "context": 16384, "output": 2048 } }
      },
      "options": { "baseURL": "{env:LLAMACPP_SERVER_BASE_URL}" }
    },
    "llamacpp-node3": {
      "npm": "@ai-sdk/openai-compatible",
      "models": { "qwen3:8b": { "tool_call": true, "limit": { "context": 32768, "output": 4096 } } },
      "options": { "baseURL": "{env:LLAMACPP_NODE3_BASE_URL}" }
    }
  }
}
'@ -replace "`r`n", "`n"
$v1 = Get-Answers (ConvertFrom-Jsonc $v1Text)
foreach ($k in $v2.Keys) { Check "1.x config: $k is the same as from the 2.x template" $v1[$k] $v2[$k] }

Write-Host "-- edge cases"
$both = ConvertFrom-Jsonc '{ "capabilities": { "tools": false }, "tool_call": true }'
Check "an entry with both keys: the 2.x one wins" (Test-ModelToolCapable $both) "False"
Check "an entry with neither key is not counted tool-capable" (Test-ModelToolCapable (ConvertFrom-Jsonc '{ "name": "x" }')) "False"
Check "no model entry is not tool-capable" (Test-ModelToolCapable $null) "False"
Check "a config with no providers at all" ("$(Get-ConfigProviders (ConvertFrom-Jsonc '{ "model": "a/b" }'))") ""

if ($script:fail) { Write-Host "$($script:fail) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "all checks passed" -ForegroundColor Green

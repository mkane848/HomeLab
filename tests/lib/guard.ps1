# guard.ps1 - the helper the regression guards (tests/test-*.ps1) share. Dot-source it near the top of a guard:
#
#   $script:fail = 0
#   . (Join-Path $PSScriptRoot "lib/guard.ps1")
#
# Check <name> <actual> <expected> prints "PASS <name>" or "FAIL <name>" with both values, and counts a failure in the
# guard's own $script:fail (dot-sourced, it runs in the guard's scope). The guard ends with its usual
# `if ($script:fail) { ...; exit 1 }`.
#
# Why one file (the 2026-11-09 audit): 47 guards each carried a byte-identical copy of Check. A change to how a check
# reports now lands once. Guards whose Check differs (extra context, another output format) keep their own; a guard
# that dot-sources this file and then defines its own Check uses its own.
#
# Not a guard itself, and nothing here may stay green on a broken check: the guards with `# mutation:` headers that use
# it (tests/run-mutations.ps1) go SURVIVED in CI if Check ever stops counting failures.
function Check([string]$name, $actual, $expected) {
    $ok = ("$actual" -eq "$expected")
    Write-Host ("{0,-4} {1}" -f $(if ($ok) { "PASS" } else { "FAIL" }), $name)
    if (-not $ok) { Write-Host "     expected: $expected"; Write-Host "     got:      $actual"; $script:fail++ }
}

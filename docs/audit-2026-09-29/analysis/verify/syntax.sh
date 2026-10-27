#!/usr/bin/env bash
# Syntax-check every script the PR touches (AGENTS.md: bash -n; PowerShell ParseFile) and prove the
# non-fix script edits are comment-only.
cd /home/user/HomeLab || exit 1
for f in profiles/dev-desktop-only.sh profiles/dev-workflow-resident.sh; do
  bash -n "$f" && echo "bash -n OK: $f"
done
for f in tests/run-tasks-batch.ps1 tests/test-profiles.ps1 tests/test-tasks.ps1 tests/test-stash-args.ps1; do
  pwsh -NoProfile -Command "\$errs = \$null; \$null = [System.Management.Automation.Language.Parser]::ParseFile('/home/user/HomeLab/$f',[ref]\$null,[ref]\$errs); if (\$errs.Count) { \$errs } else { 'ParseFile OK: $f' }"
done
echo
echo "=== changed lines in profiles/, run-tasks-batch.ps1, test-profiles.ps1 that are NOT comments ==="
git diff HEAD -- profiles tests/run-tasks-batch.ps1 tests/test-profiles.ps1 \
  | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-][[:space:]]*#' \
  || echo "(none: every changed line is a comment)"

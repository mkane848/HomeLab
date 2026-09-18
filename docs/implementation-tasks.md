# Audit result — /plan run of 2026-09-17 (qwen3:14b)

Scope: `add a --DryRun switch to desktop/scripts/sync-skills.ps1`.

## Resolution — all tasks shipped in commit `eec004d` (2026-09-18)

- [x] Task 1 (smoke-test `-DryRun`) — PASSED 2026-09-17; the one uncovered
      defect (unguarded remote `mkdir`) became Task 2 and is now fixed.
- [x] Task 2 (guard the remote `mkdir -p` behind `-DryRun`) — **done in
      `eec004d`**; `sync-skills.ps1:205` now sits inside an `if ($DryRun)` /
      `else` split. DoD check: a dry run prints `(dry run) would create remote
      dirs` and issues no ssh.
- [x] Task 3 (fix `$pair[1]` interpolation) — **done in `eec004d`**; both
      interpolations are now `$($pair[1])` (sync-skills.ps1:168, 171).

Kept as the `/plan` canary record: this file proves the command writes a real
doc to disk, that its gap claims were wrong and caught by a human audit, and
that the corrected list then shipped in one commit.

## Verdict: feature already exists; plan's gap claims are inverted

`sync-skills.ps1` already has a working `-DryRun` switch (param line 45),
guarded at **every** destructive boundary. Each of the three "risk/gap" claims
in the raw /plan output was checked against the file and found wrong:

| Raw claim | Cited lines | Reality |
|---|---|---|
| "Existing DryRun handling may miss edge cases — only logs skills without checking pruning/copying" | 101 | Line 101 IS `if ($DryRun)` — staging copy is skipped in dry run. |
| "Prune logic lacks DryRun validation — no explicit guard" | 145-159 | Line 151 IS `if ($DryRun) { log } else { Remove-Item }` — prune is guarded. |
| "DryRun does not prevent legacy directory removal on server" | 177-188 (local) / 219-226 (server) | Line 181 (local) and line 220 (server) both guard with `if (-not $DryRun)`. |

All line numbers were accurate; semantics were inverted. **This run reproduces
the exact failure already documented at `docs/troubleshooting.md:165-205`**
(the "Prune logic bypasses DryRun" claim), this time under qwen3:14b — the 14b
seat does not fix plan-verification reliability. Treat /plan output as a draft,
never a task list.

## Task list

1. **Smoke-test the existing `-DryRun` end to end.** No code changes needed.
   Definition of done:
   - `.\desktop\scripts\sync-skills.ps1 -DryRun -Local` prints `  + skills/...`
     lines but writes **nothing** to `~/.config/opencode/` (verify by comparing
     file timestamps / running `-Prune` too stays log-only). **PASSED 2026-09-17.**
   - `.\desktop\scripts\sync-skills.ps1 -DryRun -Server` prints `(dry run)`
     lines and skips the scp transfers (line 214) and legacy `rm -rf`
     (line 220-221). **Verified 2026-09-17: FAILS its own DOD** — line 205
     `ssh $remote "mkdir -p ..."` runs unguarded and attempted a live
     connection during the dry run. Scp/rm are guarded; the `mkdir` is not.
     Task 2 below is the fix.
   - The only unavoidable writes are to the temp `$STAGE` directory — created
     at line 76-83 before any dry-run branch. Confirm that is the *only* local
     write. (Confirmed; the `$STAGE` teardown at line 77 is idempotent.)
2. **Guard the remote `mkdir -p` (line 205) behind `-DryRun`** so a dry run
   performs no network writes at all. Move line 205 inside the same
   `if ($DryRun)`/`else` split already used for scp (lines 211-215):
     - dry run  → `Write-Host "  (dry run) would create remote dirs"`, skip ssh
     - real run → keep `ssh $remote "mkdir -p ..."` and the line 206 failure abort
   Definition of done: `-DryRun -Server` on a reachable host prints the dry-run
   line and issues no ssh command (`test-toolcalls.py`/`ssh -v` session or
   `LASTEXITCODE` untouched).
3. **Cosmetic: fix `$pair[1]` string interpolation** — PSH does not index
   `"$pair[1]"` in a string; it prints the whole array + literal `[1]`
   ("commands commands[1]/bootstrap.md"). Use `"$($pair[1])/..."` (lines 168,
   171). No behaviour change.
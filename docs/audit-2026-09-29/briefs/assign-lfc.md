# Assignment: lfc-bot

Follow /tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/MINING-BRIEF.md exactly, with these specifics.

- Repo: lfc-bot (a Discord bot for trading Magic: The Gathering cards; TypeScript, npm, vitest, better-sqlite3 + drizzle).
- Read-only mirror (174 commits, 2026-08-25..2026-09-25): /tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/upstream/lfc-bot
- Your scratch dir: /tmp/claude-0/-home-user-HomeLab/f0484f3b-8cac-50d6-af0c-d45af7ec3928/scratchpad/mine-lfc/ (create it)
- Window: the WHOLE history, but classify the ~47 commits dated >= 2026-09-13 (13 since 2026-09-21) as "new since last pull". The existing tasks were mined ~2026-09-21: lfc-01 and lfc-03 both target src/services/listings.ts setStatus on main@4906dc2; lfc-02 = commit 30b99a5 in src/services/scryfall.ts.
- Proposed ids continue the numbering: lfc-04, lfc-05, ... (lfc-03's acceptance commit fcf9d1a lives on a local-only branch and is not in the mirror: ignore it.)

EXTRA:
- better-sqlite3 is a native module. If `--ignore-scripts` breaks it here, report exactly what happens and whether running install scripts fixes it.
- Look for env-var-sensitive tests (lfc-02 has a known MANAPOOL_API_KEY caveat).
- Look for Discord permission/authz checks worth a security-shaped candidate.

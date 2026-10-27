# verification.md - lfc-bot candidate verification log

Protocol (per MINING-BRIEF): fresh `git worktree add --detach` at the PARENT of the fix commit (never a reused checkout);
`npm ci --ignore-scripts` (the manifest's installFlags for lfc-*); baseline run must be green; then apply ONLY the fix commit's
test-file changes (`git checkout <fix> -- <test files>`) and require >=1 failure attributable to the missing fix; then apply the
fix's source and require green. `MANAPOOL_API_KEY` is UNSET for every run (`env -u`): the sandbox environment has it set
ambiently (value deliberately not recorded here), and lfc-02's known flake fires when it is set.
Sandbox: Linux x86_64, node v22.22.2, npm 10.9.7, vitest 5.0.1 (from the lockfile). Runner script: verify.sh. Raw logs: logs/<name>/.

Global finding (install): `npm ci --ignore-scripts` works. better-sqlite3 13.0.3 ships prebuilt binaries INSIDE the npm tarball
(`node_modules/better-sqlite3/prebuilds/{darwin,linux,linuxmusl,win32}-{x64,arm64}.node`, loaded by lib/index.js); it has no
install script, so --ignore-scripts does not break the native module and no `setup` step is needed. (Windows: win32-x64.node is in the tarball.)

## v1b-digest-split  (fix e644702, parent d6a5338)

- worktree: fresh `git worktree add --detach` at parent `d6a5338d809407d181b7d74eef064bbd0d81ffa2`; `npm ci --ignore-scripts`; run 2026-09-29T17:10Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/services/digest.test.ts`
- test files taken from fix commit: `tests/services/digest.test.ts`
- src files taken from fix commit: `src/services/digest.ts src/utils/constants.ts`
- prebuilds shipped by better-sqlite3 tarball: darwin-arm64.node darwin-x64.node linux-arm64.node linux-x64.node linuxmusl-arm64.node linuxmusl-x64.node win32-arm64.node win32-x64.node 

```
# baseline (parent, scoped)
 Test Files  1 passed (1)
      Tests  7 passed (7)
# baseline (parent, FULL suite)
 Test Files  43 passed (43)
      Tests  335 passed (335)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  1 failed (1)
      Tests  6 failed | 7 passed (13)
× returns a digest that fits as a single message 9ms
× splits a long digest into messages under the limit without losing a line 10ms
× starts a new message at a section heading rather than splitting a section that fits 7ms
× hard-splits a single line longer than the limit instead of dropping it 7ms
× sends a digest longer than one message as several, each within the limit 22ms
× leaves the watermark unchanged when a later message fails, so nothing is dropped 22ms
FAIL  tests/services/digest.test.ts > splitDigestMessage > returns a digest that fits as a single message
FAIL  tests/services/digest.test.ts > splitDigestMessage > splits a long digest into messages under the limit without losing a line
FAIL  tests/services/digest.test.ts > splitDigestMessage > starts a new message at a section heading rather than splitting a section that fits
FAIL  tests/services/digest.test.ts > splitDigestMessage > hard-splits a single line longer than the limit instead of dropping it
FAIL  tests/services/digest.test.ts > runDigest on a busy day > sends a digest longer than one message as several, each within the limit
FAIL  tests/services/digest.test.ts > runDigest on a busy day > leaves the watermark unchanged when a later message fails, so nothing is dropped
# RED (FULL suite)
 Test Files  1 failed | 42 passed (43)
      Tests  6 failed | 335 passed (341)
# GREEN: fix src applied (scoped)
 Test Files  1 passed (1)
      Tests  13 passed (13)
# GREEN (FULL suite)
 Test Files  43 passed (43)
      Tests  341 passed (341)
```

## v2a-autocomplete-scryfall  (fix 64939c4, parent 2383f24)

- worktree: fresh `git worktree add --detach` at parent `2383f249101da5a4a39b07af18efa8f85bb311c7`; `npm ci --ignore-scripts`; run 2026-09-29T17:12Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/services/scryfall.test.ts`
- test files taken from fix commit: `tests/services/scryfall.test.ts`
- src files taken from fix commit: `src/services/scryfall.ts`
- prebuilds shipped by better-sqlite3 tarball: darwin-arm64.node darwin-x64.node linux-arm64.node linux-x64.node linuxmusl-arm64.node linuxmusl-x64.node win32-arm64.node win32-x64.node 

```
# baseline (parent, scoped)
 Test Files  1 passed (1)
      Tests  12 passed (12)
# baseline (parent, FULL suite)
 Test Files  43 passed (43)
      Tests  342 passed (342)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  1 failed (1)
      Tests  2 failed | 12 passed (14)
× makes a single autocomplete attempt, with no retry 521ms
× skips an autocomplete request whose deadline passed while it was queued 15ms
FAIL  tests/services/scryfall.test.ts > scryfall service > makes a single autocomplete attempt, with no retry
FAIL  tests/services/scryfall.test.ts > scryfall service > skips an autocomplete request whose deadline passed while it was queued
# RED (FULL suite)
 Test Files  1 failed | 42 passed (43)
      Tests  2 failed | 342 passed (344)
# GREEN: fix src applied (scoped)
 Test Files  1 passed (1)
      Tests  14 passed (14)
# GREEN (FULL suite)
 Test Files  43 passed (43)
      Tests  344 passed (344)
```

## v3-admin-permission  (fix 0e9d123, parent e644702)

- worktree: fresh `git worktree add --detach` at parent `e644702a6ce9753b69ca3291e1bdc388e2d1a7d3`; `npm ci --ignore-scripts`; run 2026-09-29T17:14Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/commands/admin/admin.test.ts`
- test files taken from fix commit: `tests/commands/admin/admin.test.ts`
- src files taken from fix commit: `src/commands/admin/admin.ts`
- prebuilds shipped by better-sqlite3 tarball: darwin-arm64.node darwin-x64.node linux-arm64.node linux-x64.node linuxmusl-arm64.node linuxmusl-x64.node win32-arm64.node win32-x64.node 

```
# baseline (parent, scoped)
 Test Files  1 passed (1)
      Tests  4 passed (4)
# baseline (parent, FULL suite)
 Test Files  43 passed (43)
      Tests  341 passed (341)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  1 failed (1)
      Tests  1 failed | 4 passed (5)
× is visible by default to members with Manage Server, not only Administrators 28ms
FAIL  tests/commands/admin/admin.test.ts > /admin > is visible by default to members with Manage Server, not only Administrators
# RED (FULL suite)
 Test Files  1 failed | 42 passed (43)
      Tests  1 failed | 341 passed (342)
# GREEN: fix src applied (scoped)
 Test Files  1 passed (1)
      Tests  5 passed (5)
# GREEN (FULL suite)
 Test Files  43 passed (43)
      Tests  342 passed (342)
```

## v4-digest-allowed-mentions  (fix d998d2d, parent 6f5a503)

- worktree: fresh `git worktree add --detach` at parent `6f5a5038aef79c2ccdcd460d9ebfa9c6b2e16cef`; `npm ci --ignore-scripts`; run 2026-09-29T17:16Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/services/digest.test.ts`
- test files taken from fix commit: `tests/services/digest.test.ts`
- src files taken from fix commit: `src/services/digest.ts`
- prebuilds shipped by better-sqlite3 tarball: darwin-arm64.node darwin-x64.node linux-arm64.node linux-x64.node linuxmusl-arm64.node linuxmusl-x64.node win32-arm64.node win32-x64.node 

```
# baseline (parent, scoped)
 Test Files  1 passed (1)
      Tests  6 passed (6)
# baseline (parent, FULL suite)
 Test Files  16 passed (16)
      Tests  125 passed (125)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  1 failed (1)
      Tests  1 failed | 6 passed (7)
× suppresses mention parsing so a display name like "everyone" cannot mass-ping the channel 28ms
FAIL  tests/services/digest.test.ts > runDigest delivery retry > suppresses mention parsing so a display name like "everyone" cannot mass-ping the channel
# RED (FULL suite)
 Test Files  1 failed | 15 passed (16)
      Tests  1 failed | 125 passed (126)
# GREEN: fix src applied (scoped)
 Test Files  1 passed (1)
      Tests  7 passed (7)
# GREEN (FULL suite)
 Test Files  16 passed (16)
      Tests  126 passed (126)
```

## n1-autocomplete-full  (fix 64939c4, parent 2383f24)

- worktree: fresh `git worktree add --detach` at parent `2383f249101da5a4a39b07af18efa8f85bb311c7`; `npm ci --ignore-scripts`; run 2026-09-29T17:20Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/services/scryfall.test.ts tests/commands/user/have.test.ts tests/commands/user/search.test.ts tests/commands/user/want.test.ts tests/events/interactionCreate.test.ts`
- test files taken from fix commit: `tests/commands/user/have.test.ts tests/commands/user/search.test.ts tests/commands/user/want.test.ts tests/events/interactionCreate.test.ts tests/helpers/interaction.ts tests/services/scryfall.test.ts`
- src files taken from fix commit: `src/events/interactionCreate.ts src/services/scryfall.ts src/utils/cards.ts`
- prebuilds shipped by better-sqlite3 tarball: darwin-arm64.node darwin-x64.node linux-arm64.node linux-x64.node linuxmusl-arm64.node linuxmusl-x64.node win32-arm64.node win32-x64.node 

```
# baseline (parent, scoped)
 Test Files  4 passed (4)
      Tests  38 passed (38)
# baseline (parent, FULL suite)
 Test Files  43 passed (43)
      Tests  342 passed (342)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  5 failed (5)
      Tests  10 failed | 36 passed (46)
× suggests card names when the card_name option is focused 29ms
× suggests card names for the focused card_name option 17ms
× suggests card names when the card_name option is focused 14ms
× gives the Scryfall lookup a deadline before the window closes 10ms
× sends no card suggestions when Scryfall answers after the window 9ms
× counts the window from when Discord created the interaction 7ms
× sends no set suggestions when loading the set list outlasts the window 8ms
× logs a failed autocomplete without sending a critical alert 29ms
× makes a single autocomplete attempt, with no retry 680ms
× skips an autocomplete request whose deadline passed while it was queued 32ms
FAIL  tests/events/interactionCreate.test.ts > handleInteractionCreate > logs a failed autocomplete without sending a critical alert
FAIL  tests/services/scryfall.test.ts > scryfall service > makes a single autocomplete attempt, with no retry
FAIL  tests/services/scryfall.test.ts > scryfall service > skips an autocomplete request whose deadline passed while it was queued
FAIL  tests/commands/user/have.test.ts > /have autocomplete > suggests card names when the card_name option is focused
FAIL  tests/commands/user/have.test.ts > /have autocomplete > within Discord's 3-second window > gives the Scryfall lookup a deadline before the window closes
FAIL  tests/commands/user/have.test.ts > /have autocomplete > within Discord's 3-second window > sends no card suggestions when Scryfall answers after the window
FAIL  tests/commands/user/have.test.ts > /have autocomplete > within Discord's 3-second window > counts the window from when Discord created the interaction
FAIL  tests/commands/user/have.test.ts > /have autocomplete > within Discord's 3-second window > sends no set suggestions when loading the set list outlasts the window
FAIL  tests/commands/user/search.test.ts > /search autocomplete > suggests card names for the focused card_name option
FAIL  tests/commands/user/want.test.ts > /want autocomplete > suggests card names when the card_name option is focused
# RED (FULL suite)
 Test Files  5 failed | 39 passed (44)
      Tests  10 failed | 340 passed (350)
# GREEN: fix src applied (scoped)
 Test Files  5 passed (5)
      Tests  46 passed (46)
# GREEN (FULL suite)
 Test Files  44 passed (44)
      Tests  350 passed (350)
```

## n2-schedule-parser-feature  (fix 1749a62, parent 4d0ce43)

- worktree: fresh `git worktree add --detach` at parent `4d0ce43d1906fe96fa66d234bd32aab18cbc18ec`; `npm ci --ignore-scripts`; run 2026-09-29T17:22Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/utils/schedule-parser.test.ts`
- test files taken from fix commit: `tests/utils/schedule-parser.test.ts`
- src files taken from fix commit: `src/utils/schedule-parser.ts`
- prebuilds shipped by better-sqlite3 tarball: darwin-arm64.node darwin-x64.node linux-arm64.node linux-x64.node linuxmusl-arm64.node linuxmusl-x64.node win32-arm64.node win32-x64.node 

```
# baseline (parent, scoped)
# baseline (parent, FULL suite)
 Test Files  15 passed (15)
      Tests  111 passed (111)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  1 failed (1)
      Tests  no tests
FAIL  tests/utils/schedule-parser.test.ts [ tests/utils/schedule-parser.test.ts ]
# RED (FULL suite)
 Test Files  1 failed | 15 passed (16)
      Tests  111 passed (111)
# GREEN: fix src applied (scoped)
 Test Files  1 passed (1)
      Tests  14 passed (14)
# GREEN (FULL suite)
 Test Files  16 passed (16)
      Tests  125 passed (125)
```

## n2b-scheduler-sealed-sync  (fix 04c396b, parent 0548840)

- worktree: fresh `git worktree add --detach` at parent `05488402ecaf54c2a4723fef98107313a9fc2afb`; `npm ci --ignore-scripts`; run 2026-09-29T17:23Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/services/scheduler.test.ts`
- test files taken from fix commit: `tests/services/scheduler.test.ts`
- src files taken from fix commit: `src/services/scheduler.ts`
- prebuilds shipped by better-sqlite3 tarball: 

```
# baseline (parent, scoped)
 Test Files  1 failed (1)
      Tests  no tests
# baseline (parent, FULL suite)
 Test Files  33 failed | 6 passed (39)
      Tests  62 passed (62)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  1 failed (1)
      Tests  no tests
FAIL  tests/services/scheduler.test.ts [ tests/services/scheduler.test.ts ]
# RED (FULL suite)
 Test Files  33 failed | 6 passed (39)
      Tests  62 passed (62)
# GREEN: fix src applied (scoped)
 Test Files  1 failed (1)
      Tests  no tests
# GREEN (FULL suite)
 Test Files  33 failed | 6 passed (39)
      Tests  62 passed (62)
```

## n2b2-scheduler-sealed-sync-npm11  (fix 04c396b, parent 0548840)

- worktree: fresh `git worktree add --detach` at parent `05488402ecaf54c2a4723fef98107313a9fc2afb`; `npm exec --yes --package=npm@11 -- npm ci --ignore-scripts`; run 2026-09-29T17:24Z
- scoped test cmd: `env -u MANAPOOL_API_KEY npx vitest run tests/services/scheduler.test.ts`
- test files taken from fix commit: `tests/services/scheduler.test.ts`
- src files taken from fix commit: `src/services/scheduler.ts`
- prebuilds shipped by better-sqlite3 tarball: darwin-arm64.node darwin-x64.node linux-arm64.node linux-x64.node linuxmusl-arm64.node linuxmusl-x64.node win32-arm64.node win32-x64.node 

```
# baseline (parent, scoped)
 Test Files  1 passed (1)
      Tests  7 passed (7)
# baseline (parent, FULL suite)
 Test Files  39 passed (39)
      Tests  231 passed (231)
# RED: fix's test files only on unfixed source (scoped)
 Test Files  1 failed (1)
      Tests  4 failed | 7 passed (11)
× registers a daily 16:00 UTC cron job 8ms
× is idempotent: a second call does not register another job 7ms
× invokes syncSealedCatalog from the scheduled callback without throwing 7ms
× stopAllJobs clears sealedTask so a subsequent call registers a fresh job 6ms
FAIL  tests/services/scheduler.test.ts > startSealedCatalogSync > registers a daily 16:00 UTC cron job
FAIL  tests/services/scheduler.test.ts > startSealedCatalogSync > is idempotent: a second call does not register another job
FAIL  tests/services/scheduler.test.ts > startSealedCatalogSync > invokes syncSealedCatalog from the scheduled callback without throwing
FAIL  tests/services/scheduler.test.ts > startSealedCatalogSync > stopAllJobs clears sealedTask so a subsequent call registers a fresh job
# RED (FULL suite)
 Test Files  1 failed | 38 passed (39)
      Tests  4 failed | 231 passed (235)
# GREEN: fix src applied (scoped)
 Test Files  1 passed (1)
      Tests  11 passed (11)
# GREEN (FULL suite)
 Test Files  39 passed (39)
      Tests  235 passed (235)
```

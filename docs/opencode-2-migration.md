# OpenCode 2.0 migration

Written 2026-11-21. Sources: [the OpenCode 2.0 announcement](https://anoma.ly/notes/opencode-2-0/) and
[OpenCode's "Migrate from V1" guide](https://opencode.ai/v2/docs/migrate-v1/) (`docs/references.md` →
`opencode-2-announcement`, `opencode-migrate-v1`). The latest release on 2026-11-21 is v2.3.2 (2026-11-18).

**Where things stand.** The desktop updated itself to **v2.3.2 on 2026-11-21 at 09:17** (an npm global install; it
wrote `~/.config/opencode/cli.json` and `service.json` then). The harness adapter, five guard pins, CI
(`npm i -g opencode-ai@1.19.5`) and node3 are still built for **1.19.5**. **The owner's decision (2026-11-21): v2
everywhere.** Port the harness and plugins, upgrade node3 and CI, and start a new era in `tests/results/`. Four v2
features follow (section 6).

**The cutover PR (2026-11-24; steps 3.7, 4.3 and the plugin half of 5.1) is held until node3 is upgraded.** It moves CI
to 2.3.2 and lists only the 2.x `read-budget` directory in the template, so node3 on 1.19.5 would lose its read cap.
**OpenCode 2.x is published on npm as `@opencode/cli`**, not `opencode-ai`, which stops at 1.19.x (1.19.6 on
2026-11-24). `@opencode/cli`'s latest was 2.4.1 that day, so the pin to 2.3.2 is deliberate.

**No desktop batch runs until step 3 is done.** Under v2 the adapter's `opencode run --dir` fails, and its config
reads see the wrong shape.

## What v2 breaks for us

Each row was checked on the desktop's v2.3.2 unless it says "docs".

| Area | Ours (1.x) | 2.x | Where |
|---|---|---|---|
| Plugins | `plugin: [file:///…/compaction-continue.js, …/read-budget.js]`; 1.x `{id, server()}` with `experimental.*` hooks | **Both are skipped.** The log says `configured plugin path must be a directory`, so daily use has had no read cap and no continue nudge since 09:17. The 2.x API is `Plugin.define({id, setup(ctx)})`, with `ctx.tool.hook("execute.before"/"execute.after")`, `ctx.session.hook("context"/"compaction")` and `ctx.event.subscribe()`. `experimental.compaction.autocontinue` has no equivalent (docs). | `opencode/plugins/` |
| Shared service | Each `opencode` process stood alone | One background service per machine. **`{env:}`, `OPENCODE_CONFIG` and `OPENCODE_CONFIG_CONTENT` resolve in the service's env, not the caller's.** Measured: without `--standalone`, `OPENCODE_MODEL` from the shell was ignored. | The launcher (fixed in step 1) and the adapter |
| `opencode run` | `--dir $Dir --model --format json --auto --session` | **`--dir` removed.** It has `--model p/m#variant`, `--agent`, `--format json`, `--session`, `--auto`, `--worktree`, `--archived`, `--standalone` and `--server`. | `tests/agents/opencode.ps1:497`, `tests/test-profiles.ps1:331` |
| JSON transcript | `step_start/step_finish/text/tool_use/error`, `part.tokens.*`, `part.state.*` | The same events. Tools take `path`; errors are `{type, message, status}`; there is a new `retry` event (step 2) | `Read-AgentEvents`, the write-tool list in `test-tasks.ps1` |
| `opencode debug config` | The resolved, merged config | A **list of sources** `[{type, path, info}]`, each `info` normalized to 2.x keys (`providers`, `plugins`, `permissions`, `agents.title`, `update`) | `opencode.ps1:147,195`, `sync-opencode.ps1`, `test-agent-shell.ps1` |
| `opencode debug rg search` | The ripgrep pre-run check | **Gone.** `debug` now has `agents`, `config`, `heap-dump` and `paths`. | `opencode.ps1:389-425`, `test-agent-tools.ps1` |
| `opencode db "<SQL>"` | The Go spend query | **Gone.** `session export`, `stats` and `opencode api` exist. | `run-tasks-batch.ps1:1057`, `test-hosted-seats`, `test-run-cost` |
| `opencode models <provider>` | A positional filter | The help shows no positional argument (check) | `run-tasks-batch.ps1:766`, `run-window.ps1:512` |
| `opencode serve` HTTP | `/session`, `/session/:id/prompt_async`, `/session/:id/message` | `/api/session`, `/api/session/{id}/prompt`, `/api/experimental/session/{id}/wait` (docs) | `tests/test-*-live.mjs` |
| Compaction | Threshold copied from 1.18.34's `session/overflow.ts`; `compaction.reserved/prune` | `compaction.keep.tokens` (15000), `buffer` ("15%", at least 16k), `background` (true); `prune` is ignored (docs) | `opencode.ps1:207-235`, `test-context-events`, the `run-window.ps1` prune arm |
| Permissions | `{edit: ask, bash: ask}` | Normalized to the `permissions` array. **`external_directory` now defaults to allow** (fixed in step 1). | the template |
| Model keys | `attachment`, `reasoning`, `tool_call`, `modalities` | `capabilities.{tools,input,output}`. `reasoning`/`attachment` are ignored with a warning (docs). Our file normalizes and `limit` survives. | the template's MODEL ENTRY SCHEMA comment |
| Timeouts | — | `settings.headerTimeout` 5 min and `chunkTimeout` 15 min by default (docs) | qwen3.6's spill on the server |
| LSP | (implicit) | Not run in 2.x | — |
| TUI config | — | `cli.json`, already created automatically | — |

**Believed compatible, still to verify (step 2):**
- `{env:}` and `{file:}` substitution
- `OPENCODE_DISABLE_AUTOUPDATE`
- `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS` (2.x also reads `.claude/skills` and `.agents/skills`, a preamble risk)
- `tool_output.max_bytes` (normalized, undocumented in 2.x)
- the `agents/*.md` and `commands/*.md` frontmatter

## Steps

Each step is one PR.

1. **Desktop safety. Done in the PR that added this file.**
   - Done: 1.1 `permission.external_directory: "ask"` in the template. 2.x normalizes it to
     `{action: external_directory, resource: "*", effect: ask}` (checked with an `OPENCODE_CONFIG` overlay under
     `--standalone`). 1.x asked by default anyway.
   - Done: 1.2 the profile launcher adds `--standalone` on 2.x (`desktop/scripts/opencode-standalone.ps1`). Guard:
     `tests/test-opencode-profiles.ps1`. The owner re-stages the config with `sync-opencode.ps1` from the main
     checkout after the merge.
2. **Capture 2.x ground truth. Done on 2026-11-21, against a scripted stand-in model (no GPU, no real model).**
   The transcripts are in `tests/agents/fixtures/opencode-v2/`: a read, write, edit and shell run; a `--session`
   follow-up; an overflow 400 in llama-server's wording; and an unknown model.

   **Unchanged:**
   - The events are still `step_start`, `step_finish`, `text` and `tool_use`.
   - `part.tokens` and `part.state` are still there, and so is `part.reason`.
   - `--session` continues the same session.
   - `run` works in the current directory.

   **Changed:**
   - **File tools take `path`, not `filePath`.** The shell tool is `shell`. There is no `patch` or `multiedit`.
     `execute`, `subagent` and `question` are new.
   - **Error events are `{type, message, status, response.body}`.** 1.x wrote `{name, data.{message, statusCode}}`.
     2.x classifies an overflow internally (`classification: "context-overflow"` in `packages/ai/src/provider-error.ts`
     at v2.3.2), but the event shows only `provider.invalid-request`.
   - **`run` waits on an open piped stdin.** Under a Node child with a pipe it hung for its full timeout. Closing stdin
     fixes it.
   - **An unreachable engine is retried rather than failing.** It shows as a new `retry` event with
     `provider.transport`, and the run sits until the harness timeout instead of exiting fast.
   - **Compaction now triggers at `window − max(15%, 16000)`** (`calculateCeiling` in
     `packages/core/src/session/compaction.ts`), with no `limit.output` term. A 64k seat compacts at 49,536 whatever
     its output limit. On 1.x, the 8192-output seats compacted at 57,344.
   - **`opencode models <provider>` prints help.** Plain `models` lists every `provider/model`.
   - **`opencode db` is gone.**
   - Not checked yet: `session export` for tokens and cost.
3. **Port the adapter** (`tests/agents/opencode.ps1` and its guards). The adapter branches on the major version, so
   1.19.5 (CI, node3) keeps working until the cutover.
   - 3.1 **Done.** On 2.x: run from the worktree, `--standalone`, `--archived`, stdin closed, and a title that carries
     the worktree path so `Stop-OrphanAgent` still matches it. The `test-profiles.ps1` canary got the same change.
     Checked end to end on v2.3.2 with the stand-in model: exit 0, one write counted, and a follow-up on the same
     session.
   - 3.2 **Done.** Events: `path` as well as `filePath`. 2.x errors keep their `type`, except an overflow, which is
     named `ContextOverflowError` by 2.x's own rule, copied from the v2.3.2 source.
   - 3.3 **Done.** `Get-AgentConfig` runs `--standalone debug config` and merges the sources
     (`ConvertFrom-OpencodeConfigSources`), keeping the 1.x names callers read. `sync-opencode.ps1` reads 2.x's
     `plugins` with `--standalone`, so it loads the staged files and not the service's copy. It warns about a file
     plugin, which 2.x skips because it loads only directories.
   - 3.4 **Done.** On 2.3.2, `Test-AgentTools` repeats 2.x's ripgrep lookup: `rg` on PATH, else `<bin>/rg.exe`. It
     then runs a nonce search with the binary it found. It can no longer install ripgrep as a side effect. With
     none found it reports "not ok" and says to put a pinned `rg` on PATH, as CI does.
   - 3.5 **Done.** The batch's Go listing and spend go through the adapter, and the batch no longer calls `opencode`
     at all (`test-agent-adapter` guards that). On 2.x:
     - `Get-AgentProviderModels` filters `--standalone models`.
     - `run-window.ps1`'s seat gate does the same, kept to the seat's provider.
     - `Get-AgentSpendRecords` reads `session_message` read-only through Node's built-in SQLite.
     - **2.x recorded $0 for priced Go replies.** On 2026-11-21, 482 `opencode-go/deepseek-v4.1-flash` replies
       (catalog price $0.15/$0.60 per M tokens, about 773k tokens in and 85k out) were all recorded at $0. The 1.x
       history that 2.x carried across keeps its costs. So the spend reader **fails closed**: a reply that used tokens
       and recorded no cost for a catalog-priced model makes the spend "unreadable", and the batch drops hosted seats
       with that reason. Why 2.x records $0 is not known. Finding out needs one priced Go call, which is the owner's
       decision.
   - 3.6 **Done.** Threshold and overflow are in `Get-CompactionThreshold`'s 2.x branch. On 2.x, `run-window`'s
     `-OpencodeConfig` gate refuses `compaction.prune` and `tail_turns`, which 2.x ignores, so an arm built on them
     would measure nothing.
   - Guards:
     - `tests/test-agent-opencode-v2.ps1`: transcripts, config, threshold, spend, listing and ripgrep.
     - `tests/test-opencode-run.ps1`: both command lines.
     - `tests/test-run-window.ps1`: the 2.x seat gate and the prune refusal.
     - `tests/test-sync-opencode.ps1`: the 2.x plugin check.
     - `tests/test-agent-adapter.ps1`: no `opencode` call in the batch.
   - 3.7 **Done in the cutover PR (2026-11-24), held until node3 is upgraded.** It was: **Waits for step 4: the cutover.** It moves the version pins and CI's install to 2.3.2. Until then, the
     plugin guards pin 1.19.5, and `test-compaction-plugin` would go red on 2.3.2 because `compaction-continue` is not
     ported (step 4.1 decides whether it needs to be). On the desktop, which runs 2.3.2, four guards fail on their
     1.19.5 pin, as they already did.
   - **Batch runs on the desktop's 2.x are possible after this step,** with three provisos: no plugins, the Go gate
     closed, and the pins saying 1.19.5.
   - 3.7 Bump the pins 1.19.5 → 2.3.2 (`opencode.ps1:379`, `test-compaction-plugin.ps1:35`,
     `test-read-budget.ps1:47`, `test-agent-shell.ps1`, `test-agent-tools.ps1`, `checks.yml`) and update the stand-in
     shims.
4. **Plugins.**
   - 4.1 **Done (2026-11-21): 2.x goes on after compacting by itself.** One `kane-07` run on the server's
     `llamacpp-server/qwen3.6`, with the client on the desktop's 2.3.2 and no plugins. It compacted five times, at 4,
     6, 17, 29 and 38 minutes, and kept making tool calls after each one with no nudge: 71 steps and 0 errors, still
     working when the 45-minute timeout killed it, so it was not graded. Details are in `tests/results/NOTES.md` →
     "OpenCode 2.x compaction check". Caveats: n = 1, and the run did not finish; frequent compactions on a
     read-heavy run with no read cap suggest re-measuring with the 2.x `read-budget` loaded.
   - 4.2 **Done (2026-11-21):** `read-budget` ported to `opencode/plugins/read-budget/index.js`. It is still needed:
     2.x's own read cap is 50 KiB and 2000 lines, and ours at 64k is about 17 KB. The 1.x `read-budget.js` stays
     for 1.19.5 (CI, node3) until the cutover. Both import `read-budget/core.js`. Checked on 2.3.2 with a probe
     plugin inside `opencode serve`, beyond the docs:
     - A plain `{id, setup(ctx)}` default export loads. `Plugin.define` and `@opencode/plugin` are not needed, so
       the plugin has no dependencies.
     - `execute.before`: mutating `event.input` changes what the tool runs with. The read argument is `path` (1.x:
       `filePath`), and the call id is `event.id`.
     - `execute.after`: assigning a new `event.result` (its `content` text parts) changes what the model gets.
     - The session `context` hook carries `model: {providerID, id}` and no limit. `ctx.model.list()` has
       `limit.context`, but lists the config's own providers only once that location's config has loaded, so the
       plugin looks the model up from the hook, not at setup.
     - The `compaction` hook fires on `POST /api/session/{id}/compact`.
     - `serve` runs setup in the caller's environment.
   - **Done in the cutover PR (2026-11-24):** the template's entry `"__REPO_URL__/opencode/plugins/read-budget.js"` became
     `"__REPO_URL__/opencode/plugins/read-budget"` (still under the 1.x key `plugin`, which 2.x normalizes to `plugins`). The adapter's `-match 'read-budget'` plugin test
     matches both.
   - 4.3 **Not ported**, because 4.1 showed no stall. **Retired in the cutover PR (2026-11-24):** `compaction-continue.js`, `tests/test-compaction-plugin.ps1`, `.mjs` and `-live.mjs` are deleted and the template no longer lists it. On 2.x it never loaded, as a file plugin.
   - 4.4 Port the live tests to `/api/...`, mutation-check them, and change `@opencode-ai/plugin` to
     `@opencode/plugin`. **read-budget done (2026-11-21).** Neither plugin imports `@opencode-ai/plugin`, and the 2.x
     plugin needs no import. `test-read-budget-live.mjs` drives 2.x `serve` as follows:
     - basic auth, user `opencode`, password from `OPENCODE_PASSWORD`;
     - the model on `POST /api/session` (`{model: {providerID, id}}`), because the prompt body (`{text}`) has none;
     - `wait`, then `GET .../message`;
     - its own `XDG_DATA_HOME`, because `GET /api/session` otherwise lists the owner's sessions.
5. **Native 2.x config and host rollout.**
   - 5.1 Convert the template:
     - `providers`, `package`, `settings.baseURL` and `settings.apiKey`
     - `capabilities` and the `permissions` array
     - plugin directories
     - `update: "disable"`
     - `agents.title.model`
     - the 2.x `$schema`

     Then rewrite the MODEL ENTRY SCHEMA comment, the project override (`mcp.servers`, `disabled`, `skills: [...]`),
     `docs/reference/config.md` and `opencode/README.md`, and update `check_config_drift.py` and `test-profiles.ps1`.
   - 5.2 Raise `headerTimeout` if qwen3.6's spill hits it.
   - 5.3 Upgrade node3 between batches (scp plus `pwsh -NoProfile -File`).
   - 5.4 Add an era marker in `tests/results/NOTES.md` and the roadmap.
6. **Follow-ups the owner chose (2026-11-21).**
   - 6.1 **Model variants for sampling.** A per-seat `variants: [{id: "bench", body: {temperature, seed}}]`, run with
     `--model p/m#bench`. This retires the adapter's "sampling not pinned" note. Check that llama-server honours
     `seed`.
   - 6.2 **Per-agent model pins.** Pin `agents.explore.model`, or a custom subagent, to node3's or the desktop's
     llama.cpp seat. Subagents run in the background. Pilot on one real task.
   - 6.3 **Remote service.** Run `opencode serve` on node3 and attach with `--server` or `pair`. Tools run where the
     service runs. The firewall rule and the password are the owner's steps.
   - 6.4 **MCP code mode.** Re-measure the preamble with the old five MCP servers under code mode, and relax "MCP
     only in project configs" if the difference is small.
   - Client portability: 6.1 and 6.2 stay in config. 6.3 and any use of `@opencode/client` stay outside the
     adapter's interface, so Qwen Code and Goose remain drop-in.

## Verification for each step

- `pwsh tests/run-guards.ps1`, `python3 tests/make-reference.py --check`, and CI green on the PR head.
- Syntax-check each edited `.ps1`, and mutation-check each new or changed guard.
- End to end: `tests/test-profiles.ps1 -Reliability` on the desktop and node3, then a ~1 h `run-tasks-batch.ps1`
  slice on node3, compared with the 1.19.5 era by task, paired.

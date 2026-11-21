# OpenCode 2.0 migration

Written 2026-11-21. Sources: [the OpenCode 2.0 announcement](https://anoma.ly/notes/opencode-2-0/) and
[OpenCode's "Migrate from V1" guide](https://opencode.ai/v2/docs/migrate-v1/) (`docs/references.md` →
`opencode-2-announcement`, `opencode-migrate-v1`). The latest release on 2026-11-21 is v2.3.2 (2026-11-18).

**Where things stand.** The desktop updated itself to **v2.3.2 on 2026-11-21 at 09:17** (an npm global install; it
wrote `~/.config/opencode/cli.json` and `service.json` then). The harness adapter, five guard pins, CI
(`npm i -g opencode-ai@1.19.5`) and node3 are still built for **1.19.5**. **The owner's decision (2026-11-21): v2
everywhere.** Port the harness and plugins, upgrade node3 and CI, and start a new era in `tests/results/`. Four v2
features follow (section 6).

**No desktop batch runs until step 3 is done.** Under v2 the adapter's `opencode run --dir` fails, and its config
reads see the wrong shape.

## What v2 breaks for us

Each row was checked on the desktop's v2.3.2 unless it says "docs".

| Area | Ours (1.x) | 2.x | Where |
|---|---|---|---|
| Plugins | `plugin: [file:///…/compaction-continue.js, …/read-budget.js]`; 1.x `{id, server()}` with `experimental.*` hooks | **Both are skipped.** The log says `configured plugin path must be a directory`, so daily use has had no read cap and no continue nudge since 09:17. The 2.x API is `Plugin.define({id, setup(ctx)})`, with `ctx.tool.hook("execute.before"/"execute.after")`, `ctx.session.hook("context"/"compaction")` and `ctx.event.subscribe()`. `experimental.compaction.autocontinue` has no equivalent (docs). | `opencode/plugins/` |
| Shared service | Each `opencode` process stood alone | One background service per machine. **`{env:}`, `OPENCODE_CONFIG` and `OPENCODE_CONFIG_CONTENT` resolve in the service's env, not the caller's.** Measured: without `--standalone`, `OPENCODE_MODEL` from the shell was ignored. | The launcher (fixed in step 1) and the adapter |
| `opencode run` | `--dir $Dir --model --format json --auto --session` | **`--dir` removed.** It has `--model p/m#variant`, `--agent`, `--format json`, `--session`, `--auto`, `--worktree`, `--archived`, `--standalone` and `--server`. | `tests/agents/opencode.ps1:497`, `tests/test-profiles.ps1:331` |
| JSON transcript | `step_start/step_finish/text/tool_use/error`, `part.tokens.*`, `part.state.*` | Not yet seen; capture one (step 2) | `Read-AgentEvents`, the write-tool list in `test-tasks.ps1` |
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
2. **Capture 2.x ground truth** (short probes, no batch; check GW2 is not running first).
   - 2.1 One `opencode run --standalone --format json --auto --model <small seat>` in a scratch git repo, doing one
     read, one edit and one shell call. Save it as `tests/fixtures/opencode-v2-transcript.jsonl` and diff it against
     `Read-AgentEvents`.
   - 2.2 A `--session` follow-up, a bad model (the error event), and a forced overflow (`tests/probe-overflow.ps1`).
   - 2.3 Confirm that `run` uses the cwd, the `models` filter, per-message tokens and cost in `session export`, and
     the env vars listed above.
3. **Port the adapter** (`tests/agents/opencode.ps1` and its guards).
   - 3.1 Drop `--dir` and set the job's working directory. Add `--standalone` and `--archived`.
   - 3.2 Update the event mapping from the 2.1 fixture.
   - 3.3 Write a config helper that merges `debug config`'s source list and reads `providers.<p>.models.<m>.limit`.
     Update `sync-opencode.ps1`'s plugin-path check.
   - 3.4 Replace the ripgrep check.
   - 3.5 Replace `opencode db` for Go spend.
   - 3.6 Re-derive the compaction threshold and the overflow regexes from 2.x source at the pinned tag, and drop the
     prune arm.
   - 3.7 Bump the pins 1.19.5 → 2.3.2 (`opencode.ps1:379`, `test-compaction-plugin.ps1:35`,
     `test-read-budget.ps1:47`, `test-agent-shell.ps1`, `test-agent-tools.ps1`, `checks.yml`) and update the stand-in
     shims.
4. **Plugins.**
   - 4.1 First measure whether 2.x resumes after an automatic compaction on its own (the kane-07 case, without the
     plugin).
   - 4.2 Port `read-budget` to `opencode/plugins/read-budget/index.js`. It is still needed: 2.x's own read cap is
     50 KiB and 2000 lines, and ours at 64k is about 17 KB.
   - 4.3 Port `compaction-continue` only if 4.1 shows a stall.
   - 4.4 Port the live tests to `/api/...`, mutation-check them, and change `@opencode-ai/plugin` to
     `@opencode/plugin`.
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

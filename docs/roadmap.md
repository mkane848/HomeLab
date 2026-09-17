# Roadmap

Ordered backlog for the hybrid LLM fleet. Items are TODOs, not commitments.

## Onboarding the third node (RTX 3080 FE, 10 GB / 5950X)

The catalog, OpenCode provider (`ollama-node3`), and `dev-node3.sh` profile are already in place — the node just needs to exist.

1. Install Ollama on its Windows machine.
2. Confirm its LAN bind (`OLLAMA_HOST=0.0.0.0:11434`) and open Windows Firewall for 11434 (Desktop subnet or IP-scoped).
3. Set `NODE3_IP` in `.env` (currently commented placeholder).
4. `.\desktop\scripts\models.ps1 -Profile` with `dev-node3.sh` sourced → installs its `general embed` groups.
5. `select-model.sh` → **dev-node3** → confirms OpenCode reaches `ollama-node3`.
6. `desktop/scripts/startup.ps1` optionally starts its Ollama app at boot.

## GTX 1070 (retired from server)

Decide its fate:
- **Backup card** for the server if the 4070 Ti Super fails, or
- **Second standalone node** (8 GB — only 7–9B `fit` models), adding another `ollama-*` provider + profile.

## Post-server-upgrade validation (do after hardware lands)

- [ ] `nvidia-smi` → confirms `RTX 4070 Ti SUPER 16 GB`.
- [ ] `./server/scripts/status.sh` → GPU section + catalog "installed vs planned" full.
- [ ] Pull the profile's groups and smoke-test a 14B chat + 16k context.
- [ ] Watch `api/ps` VRAM with 7B + 14B loaded (`OLLAMA_MAX_LOADED_MODELS=2`).

## Desktop environment repair (landed 2026-09-17)

- [x] **OpenCode model schema fixed.** `context_window`/`input` were not real
      keys and were silently dropped, so models resolved with no limits and
      OpenCode sent a 46,505-token prompt at a 16k model. Now
      `limit:{context,output}` + `modalities` + `tool_call`. See
      `docs/troubleshooting.md` → "OpenCode request hangs ~5 minutes".
- [x] **Preamble cut 46,505 → 11,441 tokens.** MCP servers moved out of global
      config into per-project `opencode.jsonc`; global skills cut 64 → 8
      (`sync-skills.ps1 -Scope global -Prune`).
- [x] **Per-model context baking** (`startup.ps1 $contextModels`): 32768 for the
      14B coder and the new `deepseek-r1-32k`, 16384 for the rest.
- [x] **Co-residency fixed**: small model is now `qwen2.5-coder:3b` (2.26 GB),
      so the 14B (11.27 GB) is no longer evicted on every title/summary call.
- [x] **Backend settled: Vulkan, permanently.** gfx1030 is unsupported by the
      Windows HIP SDK; `OLLAMA_VULKAN=0` gives CPU-only. Docs corrected.
- [x] **Root-caused why agents never actually edit anything: only `qwen3:8b`
      can call tools.** Measured against `/api/chat` with a tool schema on
      Ollama 0.34.0 — `qwen3:8b` returns populated `tool_calls`;
      `qwen2.5-coder:14b`, `qwen2.5-coder:3b` and `deepseek-r1:14b`/`-32k` all
      return empty `tool_calls` and print the call as chat text. Not the bake
      (pristine re-pull behaves the same). See `docs/troubleshooting.md`.
- [x] **Seat assignments corrected.** Every seat that reads/edits/runs is now
      `qwen3:8b`: `dev-workflow-quality` main seat repointed from
      `qwen2.5-coder:14b`; `opencode/agents/planner.md` repointed from
      `deepseek-r1-32k`; `opencode/agents/coder.md` and
      `opencode/commands/implement.md` **deleted** (the subagent was pinned to a
      model that could not call tools, so `/implement` silently did nothing).
      `qwen2.5-coder:14b` is retained as a deliberate no-tools model for code
      text, explanation and review.
- [x] **End-to-end verified**: `opencode run` → qwen3:8b → `← Write
      docs/_write-test.md` → `Wrote file successfully.` The first attempt was
      blocked by `permission.edit: "ask"`, which is correct interactive
      behaviour — non-interactive `opencode run` cannot prompt, so it denies.
- [ ] **Older `dev-*` profiles still seat a non-tool-capable model.** Audited
      2026-09-17: `dev-quick`, `dev-coder`, `dev-server-all`, `dev-embeddings`,
      `dev-local-only`, `dev-desktop-only` (both `.sh` and `.ps1`), `dev-node3`
      (fallback branch) and `dev-workflow-server` all point `OPENCODE_MODEL` at
      a `qwen2.5-coder` or `deepseek-r1` tag. They are chat-only as written.
      `ollama-server/qwen3:8b` is already registered, so the server-side ones
      can be repointed without new downloads.
- [ ] Prefill on Vulkan is the remaining bottleneck (103 tok/s at `FA=1
      KV=q8_0`). Worth revisiting if AMD adds gfx1030 to the Windows HIP table.

## Hardening / experiments

- [x] **Pin the Ollama image** (2026-09-17): `server/docker/docker-compose.yml`
      now pins `ollama/ollama:0.34.0`, the version every tool-calling and VRAM
      measurement in these docs was taken against. `:latest` was a live risk,
      not just a reproducibility nicety — which models emit parseable tool calls
      depends on the Ollama version and its templates, so an unattended pull
      could silently turn a working agent into one that reports edits it never
      made. **On any version bump, re-run `tests/test-toolcalls.ps1` against the
      host before trusting a seat.**
      - [ ] The desktop is a native install, not a container, so it is *not*
            pinned by this. It auto-updates. Consider disabling Ollama's
            auto-update on the desktop, or at minimum re-probe after it moves.
- [ ] Try CUDA-only tooling on the server that the Vulkan desktop cannot run: vLLM, TensorRT-LLM, CUDA llama.cpp — good candidates for serving a 14B at higher throughput.
- [ ] Bake a higher-context derived model if the 16 384 default is too small for one specific job (`install-model.sh --ctx N` creates `<tag>-Nk`).
- [ ] Add `qwen3-coder` to `models/catalog.tsv` + OpenCode config when it stabilizes in the Ollama library.
- [ ] Re-check `deepseek-r1-16k` on the desktop: with the server now hosting reasoners, the desktop bake may be optional.

## Desktop dev environments (landed)

- [x] Desktop local service stack (`desktop/docker/docker-compose.yml` — Postgres 16 + Redis 7, loopback-only, `docker-stack.ps1`).
- [x] Read-only `postgres` OpenCode MCP enabled against the local Postgres (`.secrets/postgres-dsn`).
- [x] Shared CPU dev base (`dev/docker/dev.dockerfile` → `dev-base:1` via `docker-base.ps1`).
- [x] Devcontainers for LFCbot and asohav (asohav bakes Playwright chromium + deps).
- [x] `/sandbox` + `/devcontain` OpenCode commands; `docker-sandbox.ps1`.
- [x] `DEV_DOCKER_STACK` profile flag → `startup.ps1` auto-`up`; `.wslconfig` `memory=12GB`.
- [ ] **Revisit the local Postgres before it becomes permanent**: once a real project actually lands on Postgres (e.g. asohav `pg`, a managed DB, or Render/Supabase/Neon), decide whether it should be the desktop stack, the server, or cloud-hosted. The desktop stack is here to unblock local dev, not to become a production target. If a future project needs Postgres in *production*, prefer managed; keep the desktop instance optional and documented.
- [ ] Fold the sandbox/devcontainer workflow into `docs/profiles.md` per-profile docs once it settles.

## Sprinkled TODOs

- Embedding models (`nomic`, `mxbai`) already on desktop — decide whether to move them to the server after upgrade (they're 0.5–4 GB of disk).
- `docs/troubleshooting.md` — recheck the VRAM math and the `api/ps` numbers after the upgrade exercise.
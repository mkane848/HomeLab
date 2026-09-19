# Roadmap

Ordered backlog for the hybrid LLM fleet. Items are TODOs, not commitments.

## Next up (ordered, as of 2026-09-19)

The rest of this file is the full backlog by theme. This is the short list of
what to actually pick up next, highest value first.

1. **Close the KaneEnabler validator holes** under the fix-and-reverify gate —
   Background-pairing eligibility bug, direct `legality_commander` check on
   named commanders, singleton paper-rule, `banned`/`notFound` dedupe, and the
   seeded-DB proof of the 100-card assertion. Task list in
   [implementation-tasks.md](implementation-tasks.md) §C; method in
   [review-gate/testing.md](review-gate/testing.md). **The only open item with
   real correctness value** — everything else here is hygiene or research. Each
   fix must ship a test that *fails on the old code*. Different repo, so it
   needs a machine with that checkout.
2. **Settle the desktop Ollama auto-update.** `desktop/scripts/pin-ollama-desktop.ps1`
   exists to prevent exactly the 0.34.0 → 0.34.1 move that happened anyway on
   2026-09-19. Find out whether the firewall rule was ever applied or whether it
   failed — the two need different fixes. Five minutes, and it is the one open
   item that can silently break agent seats.
3. **Probe the server when it POSTs.** It has *never* run
   `tests/test-toolcalls.ps1` — it went down before that test existed — and its
   image pin was bumped to `0.34.1` on 2026-09-19 to match the desktop. Nothing
   on that host should be seated until it is probed. The four post-upgrade
   checks are below under "Post-server-upgrade validation".
4. **Reconcile the VRAM figures that disagree** (see "Known contradictions"
   below). Two of them change real decisions and neither can be settled without
   a measurement.
5. **Rewrite `model-architecture.md`.** It predates the tool-calling finding and
   now carries a staleness banner; it still seats models that cannot call tools
   and never mentions `qwen3:14b`. Either bring it current or fold it into
   `profiles.md` + `hardware.md` and delete it.
6. **Review-gate leftovers, low priority.** The seat question is closed (see
   "Review-gate: settled" below). What remains is optional: a hosted arm (the
   only untried thing that could change the answer, needs an endpoint + key),
   Arm C (the de-leaked prompt), and a seam-6 brittleness probe for the
   deterministic checker — the fixture built for that on 2026-09-19 tested the
   wrong thing, so the question is still open. None of these block anything.

### Known contradictions (need a measurement, not an edit)

Written down rather than guessed at. Each is a number that appears twice in
these docs with two different values:

- **`qwen2.5-coder:3b` runtime VRAM** — 1.31 GB (`start-here.md`), 2.26 GB
  (`profiles.md`, `roadmap.md`, `troubleshooting.md`), "1.3–2.3 GB"
  (`hardware.md`). Both larger figures are labelled measured. This gives the
  flagship co-resident pair two different totals (12.34 vs 13.29 GB) and
  *opposite* verdicts on whether it survives while gaming.
- **`deepseek-r1:14b` resident VRAM** — ~9 GB (`lmstudio-vscode.md` §4) vs
  ~10.5 GB @16k (same file, seat-assignment table). The node3 fit argument
  turns on which is right.
- **node3 "10 GB usable ~9 GB"** (`lmstudio-vscode.md`) is attributed to
  `hardware.md`, which states no such figure — its only "usable" number is the
  desktop's ~14.8 of 16 GB.
- **Harness pass count** — docs say 81 PASS (`start-here.md`, `profiles.md`);
  commit `41a457d` reports 85 PASS and 88 with `-Reliability`. The docs predate
  that gate. Re-run `tests/test-profiles.ps1` and record the real number.
- **VRAM figures generally** still date from Ollama 0.34.0 and were not
  re-measured after the 0.34.1 move. Not expected to shift, but not verified.

### Review-gate: settled

Closed 2026-09-19, recorded so it is not reopened by accident.

- **No local model holds the reviewer seat.** 18 parameter-recorded runs,
  three families, control vs. a forced per-test ledger. The ledger raised
  output length exactly as designed (median 1229 → 1770 tokens, 9/9 compliance)
  and changed almost nothing: deciding seams caught 1/9 under treatment, 0/9
  under control. One run transcribed the decisive argument correctly into its
  ledger and passed the broken plan anyway. **The bottleneck is verification
  reasoning — not prompt shape, not output budget, not VRAM.** **Scope:** this
  is confirmed on one defect pair (seam 5 + seam 6), replicated 18 times across
  three model families — internal validity is strong, but no different bug
  shape or plan has ever been tried, so generalization past this one plan is
  untested, the same limit the seam-checker bullet below already states.
  → [review-gate/raw/r3-results.md](review-gate/raw/r3-results.md)
- **The deterministic seam-checker discriminates** — given genuinely covered
  seams it returns FIRST-RUN-SAFE, given the original it returns RED-MARK. It
  is sound as a **regression gate on the one plan it was written for**, and is
  not a general reviewer. → [review-gate/raw/r3-robot-results.md](review-gate/raw/r3-robot-results.md)
- **Two claims made during this work were wrong and are corrected in place**:
  the round-2 comparison mis-scored its own draw 2 and inverted the
  majority-of-3 conclusion; and a "ten-character margin" claim about the
  checker's seam-6 regex was computed under a `re.DOTALL` assumption PowerShell
  does not share. Both corrections are recorded rather than silently applied.
- The gate remains **"auditor crafts, human arbitrates."**

## End goal (north star)

Turn every machine in the house into interchangeable compute for **one Claude
Code / ChatGPT Codex-like development experience**: prompt in plain human
language, and the fleet flexibly supplies the models behind that experience.
The profile selects which models run where, OpenCode pins the main seat, and
`tests/test-profiles.ps1` enforces it — you never think about which GPU answers.

Progress gates by hardware, not by preference:

1. **Personal PC (this desktop, RX 6800 XT)** — doing this *today*.
   `dev-workflow-quality` seats `qwen3:14b` (2026-09-17) as the tool-capable
   main seat, the first seat that is both a real conversational agent and a
   coder. Nothing below needs the server.
2. **Ubuntu server (RTX 4070 Ti Super)** — unblocked once it POSTs; the
   profile stream (`profiles/parked/`) is already in place. Server becomes the
   heavyweight node (server-side `qwen3`, reasoners, embeddings) so the desktop
   can stay a conversational seat.
3. **Third node (RTX 3080 FE)** — last; the `ollama-node3` provider, `dev-node3.sh`
   stub and `DEV_TIERS_NODE3` toggle exist and activate the moment `NODE3_IP` is
   set.

Each node joins by taking a profile, not by re-learning the workflow. The end
state is a pool: a loose prompt, and whichever hardware is up and fastest
answers it.

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
- [x] **Root-caused why agents never actually edit anything: only the qwen3
      family (`qwen3:8b`/`qwen3:14b`) + `devstral:24b` can call tools.**
      Measured against `/api/chat` with a tool schema on Ollama 0.34.0 —
      `qwen3:8b` and `qwen3:14b` return populated `tool_calls` (devstral:24b
      passes but partially offloads); `qwen2.5-coder:14b`,
      `qwen2.5-coder:3b` and `deepseek-r1:14b`/`-32k` all return empty
      `tool_calls` and print the call as chat text. Not the bake
      (pristine re-pull behaves the same). See `docs/troubleshooting.md`.
      **Re-measured on 0.34.1 (2026-09-19): every result reproduced, each
      failure in the same mode.** Now 5/13 — `qwen3.5:9b` and
      `qwen3-coder:30b-a3b` were first measured then and both pass;
      `deepseek-r1-0528:8b` fails with the rest of its family. Raw output:
      `tests/results/toolcalls-0.34.1.txt`.
- [x] **Seat assignments corrected (2026-09-17, final).** Every seat that
      reads/edits/runs is a qwen3: `dev-workflow-quality` main seat re-seated
      from `qwen3:8b` to `qwen3:14b` for loose-prompt intent handling (the
      14b was briefly seated then reverted over a 6-write slip — re-probed
      and re-seated same day; watch `← Write` lines for repeated calls);
      `opencode/agents/coder.md` and `opencode/commands/implement.md`
      **deleted** (the subagent was pinned to a model that could not call
      tools, so `/implement` silently did nothing). `qwen2.5-coder:14b` is
      retained as a deliberate no-tools model for code text, explanation and
      review. `devstral:24b` passes the probe but is a solo-seat edge fit —
      registered for evaluation, not seated.
- [x] **End-to-end verified**: `opencode run` → qwen3:8b → `← Write
      docs/_write-test.md` → `Wrote file successfully.` The first attempt was
      blocked by `permission.edit: "ask"`, which is correct interactive
      behaviour — non-interactive `opencode run` cannot prompt, so it denies.
- [x] **qwen3:14b re-seat verified end-to-end (2026-09-17).** `opencode run
      --model ollama-desktop/qwen3:14b --auto "Create a file at …"` made
      **exactly one tool call** (`--format json`: `1 tool`, `1 tool_use`, then
      `step_finish`) and wrote the file correctly. The "6-write slip" that
      unseated it on 2026-09-17 did not reappear. Single-Write discipline
      confirmed, matching the `← Write` watch-rule in `docs/troubleshooting.md`.
      Gotcha while probing: an `opencode run … "full sentence"` message passed
      in through PowerShell→bash inline quoting (`& "…\bash.exe" -c '…'`)
      arrived at the model **truncated to its first word** ("Create"), which
      looked exactly like a tool-calling regression. It was quote-mangling, not
      the model — rerun probes via a bash *script file*, as here.
- [x] **Older `dev-*` profiles still seat a non-tool-capable model.** Audited
      2026-09-17 (pre-park `c3bf530^` and HEAD): **already fixed** — every parked
      main seat is `qwen3:8b` (`dev-node3` on both its branches), `dev-local-only`
      is `ollama-desktop/qwen3:8b`, and `dev-full`/`dev-go-only` leave
      `OPENCODE_MODEL` unset by design (GoDefault). The only `qwen2.5-coder`
      reference anywhere is `OPENCODE_SMALL_MODEL` — the title generator, which
      must not have tools. Nothing to repoint.
- [ ] Prefill on Vulkan is the remaining bottleneck (103 tok/s at `FA=1
      KV=q8_0`). Worth revisiting if AMD adds gfx1030 to the Windows HIP table.

## Hardening / experiments

- [x] **Pin the Ollama image** (2026-09-17; pin bumped to `0.34.1` on
      2026-09-19 to match the desktop): `server/docker/docker-compose.yml`
      pins `ollama/ollama:0.34.1`, the version every tool-calling measurement
      in these docs is now taken against. (VRAM figures still date from 0.34.0
      and have not been re-measured — they are not expected to move, but they
      are not re-verified either.) `:latest` was a live risk,
      not just a reproducibility nicety — which models emit parseable tool calls
      depends on the Ollama version and its templates, so an unattended pull
      could silently turn a working agent into one that reports edits it never
      made. **On any version bump, re-run `tests/test-toolcalls.ps1` against the
      host before trusting a seat.**
      - [ ] **The desktop is a native install, not a container, so it is *not*
            pinned by this — and on 2026-09-19 it auto-updated 0.34.0 → 0.34.1,
            exactly as predicted.** `desktop/scripts/pin-ollama-desktop.ps1`
            exists to prevent this (a Windows Firewall outbound block on the
            tray updater, written 2026-09-17 naming v0.34.1 as the bundle
            already staged), but the update happened anyway — so either the
            guard was never applied or it did not hold. **Unresolved: find out
            which.** No markdown file references that script, which points at
            "never applied". The re-probe half of this item *was* done and the
            news was good (every result reproduced on 0.34.1; docs re-baselined,
            server pin bumped to match), so nothing is broken — but the fleet
            is one silent update away from the same question, and next time the
            answer may not be benign.
- [ ] Try CUDA-only tooling on the server that the Vulkan desktop cannot run: vLLM, TensorRT-LLM, CUDA llama.cpp — good candidates for serving a 14B at higher throughput.
- [ ] Bake a higher-context derived model if the 16 384 default is too small for one specific job (`install-model.sh --ctx N` creates `<tag>-Nk`).
- [ ] Add `qwen3-coder` to `models/catalog.tsv` + OpenCode config when it stabilizes in the Ollama library.
- [ ] Re-check `deepseek-r1-16k` on the desktop: with the server now hosting reasoners, the desktop bake may be optional.
- [x] **LM Studio + VS Code review-gate experiment (2026-09-18).** Native VS Code BYOK (`chatLanguageModels.json`) registers LM Studio + desktop Ollama as peer endpoints; the review-gate split (tool-capable auditor → different-family no-tools reviewer → arbiter) caught a destructive remediation step a single qwen3-coder-30b run shipped. Method + measured gotchas recorded in [docs/lmstudio-vscode.md](lmstudio-vscode.md). Open follow-up: extend to the server seat (`http://SERVER_IP:11434/v1`) when the host is up.
- [x] **Review-gate run 2 — KaneEnabler deck-validity PR (2026-09-18).** The auditor was given a prompt (not hand-primed facts) and a read-only tool loop clamped to the task repo; it self-discovered ~90% of ground truth over 26 turns (unwired `deckLegality`/`colorIdentity` primitives → test conventions → the `(req.body ?? {})` Express-5 guard → fixture corpus) and produced the plan later opened as KaneEnabler PR #82. Findings that changed the method: **(a) reviewer gradient** — R1 de novo (no seam coaching) graded the self-prompted plan FIRST-RUN-SAFE while missing 3 of the 4 seams the hand-primed review passed on, so the tuning lever is the reviewer prompt/seat, not the auditor tool loop; **(b) arbiter corrections** must be folded into the implementation contract (JSON-string `color_identity` decode, deck size counting banned/notFound slots, commander eligibility via `is_commander_eligible` + `buildCommanderUnits`); **(c) the reviewer seat has no clean third node** — see [docs/lmstudio-vscode.md](lmstudio-vscode.md) → "Fleet seat assignment".
- [ ] **Fleet decision: reviewer node gap — reframed 2026-09-19, no longer a VRAM question.** The original framing (third 16 GB node vs. partial-offload R1 on node3 vs. `glm4:9b`) assumed the blocker was fitting a reviewer on a card. Round 3 (18 runs, three models, control vs. forced per-test ledger) shows the seat fails on verification *reasoning*: models transcribe the deciding argument correctly and still pass the plan. A bigger card does not buy that, and `glm4:9b` is weaker than three models that have already failed — its "~6 GB" was catalog disk size, never a measured runtime figure, and it has never been run as a reviewer. **Do not buy or reassign hardware for a local reviewer seat until one exists.** See `docs/review-gate/raw/r3-results.md`. The live options are a hosted gate seat, or the deterministic checker as a regression gate with the human arbiter retained. Note the reviewer VRAM figure itself is inconsistent in the docs (~9 GB at `docs/lmstudio-vscode.md` §4 vs ~10.5 GB in the seat table) — resolve before any sizing decision is revived.
- [ ] **Review-gate run 2 follow-ups** (see [docs/lmstudio-vscode.md](lmstudio-vscode.md) → "Next steps"): (1) close KaneEnabler validator holes — **Background-pairing eligibility bug** (a legal Background pair is rejected: `eligible` demands `is_commander_eligible === 1` on every named commander, but a Background is definitionally 0; fix `usableAsCommander = c => c.is_commander_eligible === 1 || c.is_background === 1`), **direct `legality_commander` ban-list check on named commanders** (today enforced only incidentally when the pasted `list` duplicates the commander line), singleton paper-rule, `banned`/`notFound` dedupe, and prove the 100-card-valid assertion on a seeded DB — **merge gate: fix-and-reverify pass** (audit every new test against its claimed branch; run 2's Background test passed green while never passing the pair). See [docs/review-gate/testing.md](review-gate/testing.md); (2) ~~re-measure the reviewer seat~~ **— done, closed 2026-09-19.** Run to exhaustion in r2 (three candidates, two never drawn) and then settled by round 3: 18 runs, control vs. forced per-test ledger, prompt hash constant within arm, all parameters recorded. No local model holds the seat, and the failure is verification reasoning rather than prompt shape or output budget — confirmed on one defect pair (seam 5 + seam 6) replicated 18 times, not yet tested across a different bug shape. `qwen3.5:9b` produced the corpus's only fully correct review at ~1-in-3 — drafting aid, never the verdict. The "1/4 → ?" metric is retired: it compared an unchecklisted baseline against checklisted runs and measured three changes at once. See `docs/review-gate/raw/r3-results.md`; (3) run the auditor harness on a second non-hand-picked repo; (4) routinize per-run grading on the **four** axes (evidence discipline, plan safety, review quality, test veracity) so runs become a benchmark. Gate is currently "auditor crafts, human arbitrates" — reviewer must earn its seat before this scales past the human arbiter.

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
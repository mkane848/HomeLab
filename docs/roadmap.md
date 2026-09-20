# Roadmap

Ordered backlog for the hybrid LLM fleet. Items are TODOs, not commitments.

## Next up (ordered, as of 2026-09-20)

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
2. **Run more task-veracity trials before adding a 3rd task shape.** The
   combined Task 1 + Task 2 result (0/7 graded runs) is inside the confidence
   interval of published base rates for un-tuned models this size (~8–20% —
   see "Task-veracity benchmark: external research pass" below), so it isn't
   yet distinguishable from "these seats succeed ~1 time in 6–10 and too few
   trials have run to see it." ~5 repeat runs per model per task narrows that
   a lot more cheaply than authoring new task shapes right now. The hosted/
   frontier-model calibration arm in the same section is the other open lever
   here, whenever the fleet owner wants to spend the API cost on it.
3. **~~Onboard the third node (RTX 3080 FE)~~ — done 2026-09-20.** Join →
   probe → validate all complete (see "Onboarding the third node" below):
   `qwen3:8b` is a real, measured agent seat on this host, `test-profiles.ps1
   -Profile dev-node3` is green. **Actually pick this up now:** run
   `ollama-node3/qwen3:8b` trials concurrently with the desktop's batch on
   item 2, instead of serially — that's the whole point of onboarding it.
   Unsloth is installed there for a later, explicitly gated fine-tuning
   track — still not part of this item.
4. **Settle the desktop Ollama auto-update.** `desktop/scripts/pin-ollama-desktop.ps1`
   exists to prevent exactly the 0.34.0 → 0.34.1 move that happened anyway on
   2026-09-19. Find out whether the firewall rule was ever applied or whether it
   failed — the two need different fixes. Five minutes, and it is the one open
   item that can silently break agent seats.
5. **Probe the server when it POSTs.** It has *never* run
   `tests/test-toolcalls.ps1` — it went down before that test existed — and its
   image pin was bumped to `0.34.1` on 2026-09-19 to match the desktop. Nothing
   on that host should be seated until it is probed. The four post-upgrade
   checks are below under "Post-server-upgrade validation".
6. **Reconcile the VRAM figures that disagree** (see "Known contradictions"
   below). Two of them change real decisions and neither can be settled without
   a measurement.
7. **Rewrite `model-architecture.md`.** It predates the tool-calling finding and
   now carries a staleness banner; it still seats models that cannot call tools
   and never mentions `qwen3:14b`. Either bring it current or fold it into
   `profiles.md` + `hardware.md` and delete it.
8. **Review-gate leftovers, low priority.** The seat question is closed (see
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
- **node3 usable VRAM is unmeasured.** `lmstudio-vscode.md`'s "10 GB usable
  ~9 GB, per `hardware.md`" attribution was removed 2026-09-20 (hardware.md
  states no such figure — its only "usable" number is the desktop's ~14.8 of
  16 GB). To-do: with nothing loaded on node3, record free VRAM from
  `/api/ps` into `docs/hardware.md`, the same way the desktop's 14.8 GB was
  established. Until then, no node3 fit verdict should cite a usable figure.
- **Harness pass count** — ~~docs say 81 PASS (`start-here.md`, `profiles.md`);
  commit `41a457d` reports 85 PASS and 88 with `-Reliability`~~ — resolved
  2026-09-20: re-ran `tests/test-profiles.ps1` across all four live profiles
  (node3 now live) → **100 PASS, 0 FAIL, 1 WARN, 2 SKIP**, and every doc
  claiming 81 PASS now says so (`start-here.md`, `profiles.md`,
  `CONTRIBUTING.md`, `profiles/parked/README.md`). The 1 WARN is the known
  node3 `hosts`-column false positive; the 2 SKIP taps are the dead server.
- **VRAM figures generally** still date from Ollama 0.34.0 and were not
  re-measured after the 0.34.1 move. Not expected to shift, but not verified.
- **Server `glm4:9b` `tool_call: true` is unprobed.** The only measurement is
  the node3 FAIL (2026-09-20, ignored the tool, answered in prose); the server
  copy has been down since before `test-toolcalls.ps1` existed. To-do: when
  the server POSTs, run `.\tests\test-toolcalls.ps1 -Model glm4:9b -OllamaHost
  http://SERVER_IP:11434` and flip the server-block entry to `false` if it
  fails the same way (expected — same weights, same CUDA backend). Recorded
  in `opencode/global/opencode.jsonc`'s server-block comment; see also
  "Post-server-upgrade validation" below.
- **Node3 WARN false positive needs a harness fix.** `test-profiles.ps1`
  expands `DEV_NODE3_MODELS="general embed"` by catalog group membership
  without checking the `hosts` column, so it WARNs on `qwen3:14b` (deliberately
  unregistered on node3 — tight on 10 GB) and `gpt-oss:20b` (never
  node3-eligible). To-do: respect `hosts` when computing per-host install
  intent. Do not pull either model onto node3 to silence the WARN in the
  meantime.

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
3. **Third node (RTX 3080 FE)** — **live as of 2026-09-20**, ahead of the
   server (stage 2), which still hasn't POSTed. `qwen3:8b` is a measured,
   tool-capable agent seat on this host; see "Onboarding the third node"
   below. Progress here gated by hardware, not by the plan's original
   ordering — node3 came up first.

Each node joins by taking a profile, not by re-learning the workflow. The end
state is a pool: a loose prompt, and whichever hardware is up and fastest
answers it.

## Onboarding the third node (RTX 3080 FE, 10 GB / 5950X)

Started 2026-09-20 — the hardware exists now (previously "future"). The catalog,
OpenCode provider (`ollama-node3`), and `dev-node3.sh` profile were already in
place; this is the concrete sequence to actually bring it up, prove it before
trusting it (same standing rule as every other seat in this repo), and put it
to work on the task-veracity benchmark. Unlike the desktop, this card is
**CUDA, not Vulkan** — no `OLLAMA_VULKAN`/flash-attention workaround needed,
Ollama's native NVIDIA backend applies directly.

**Join:**
1. [x] Install Ollama on its Windows machine (native, from ollama.com — CUDA
   auto-detected). Done 2026-09-20.
2. [x] `OLLAMA_HOST=0.0.0.0:11434`, restart Ollama, open Windows Firewall for
   11434 scoped to the LAN subnet (not public). Done — confirmed via
   `netstat -an | findstr 11434` showing `0.0.0.0:11434` listening.
3. [x] Pull the two chat models + two embed models `dev-node3.sh` expects
   (`DEV_NODE3_MODELS="general embed"`): `qwen3:8b`, `glm4:9b`,
   `nomic-embed-text`, `mxbai-embed-large`. Done — confirmed via
   `/api/tags` on the node.
4. [x] Set `NODE3_IP` in `.env` and confirm from the desktop:
   `curl.exe http://<node3-ip>:11434/api/tags` — done, returned all four
   models.

**Prove it before trusting it — do not skip:**
5. [x] `.\tests\test-toolcalls.ps1 -Model qwen3:8b -OllamaHost http://<node3-ip>:11434`.
   **PASS** (2026-09-20, 62.3s, real `write_file` tool call). Confirms the
   qwen3 family's tool-calling holds on this CUDA host too, not just
   Vulkan/desktop — recorded in AGENTS.md's Gotchas.
6. [x] Same for `glm4:9b` — this was the real open question, since its
   `"tool_call": true` config entry had no measurement behind it (didn't
   appear in either the passing or failing side of the 13-model
   `toolcalls-0.34.1.txt` batch). **FAIL** (2026-09-20, 32.8s): ignored the
   tool entirely and answered in prose ("To write the text 'hello' to a
   file..."), same shape as the `qwen2.5-coder`/`deepseek-r1` failures.
   **Corrected `opencode/global/opencode.jsonc`'s `ollama-node3` block to
   `"tool_call": false` for it** — it stays registered as a no-tools chat
   model, same treatment as `qwen2.5-coder:14b`, and must not hold an agent
   seat. `qwen3:8b` remains the only node3 agent seat, matching
   `dev-node3.sh`'s existing `OPENCODE_MODEL` default — no profile change
   needed.
7. [x] `git mv profiles/parked/dev-node3.sh profiles/` once `NODE3_IP` is set
   (per `profiles/parked/README.md`'s own "bringing one back" step). Done.
8. [x] `.\tests\test-profiles.ps1 -Profile dev-node3` — confirms intent
   manifest, tool-capability, and host liveness together, not just that it
   answers a ping. **Done 2026-09-20: 15 PASS, 0 FAIL, 1 WARN, 2 SKIP.**
   The 2 SKIPs are the already-known Ubuntu server outage, unrelated to
   node3. The 1 WARN (`install intent (node3) -> missing on host: qwen3:14b,
   gpt-oss:20b`) is a **false positive**, not a real gap: the harness expands
   `DEV_NODE3_MODELS="general embed"` by catalog tag-group membership only,
   without checking the `hosts` column. `gpt-oss:20b` is
   `hosts=server,desktop` — never node3-eligible at all — and `qwen3:14b`,
   while `hosts=all`, was deliberately left off node3's `opencode.jsonc`
   provider block (only `qwen3:8b` is registered there) because 14B weights
   alone run ~9-9.5 GB, tight on a 10 GB card per `docs/hardware.md`'s VRAM
    table. Same "catalog↔config diff is not automatically a defect" pattern
    AGENTS.md documents (per-host registration gaps and unprobed-only entries
    are usually deliberate — see its Model catalog section).
   **Do not pull either model onto node3 to silence this WARN.** A harness
   fix (respect `hosts` when computing per-host install intent) is a real,
   minor improvement but out of scope here — untouched, no local `pwsh` to
   syntax-check a `test-profiles.ps1` edit against, so it's flagged rather
   than attempted blind.

**Third node onboarding: complete as of 2026-09-20.** Both agent seats
measured for real (`qwen3:8b` PASS, `glm4:9b` FAIL — corrected in config),
network reachable, profile live, `test-profiles.ps1` green modulo the one
documented false-positive above and the pre-existing server outage.
`docs/hardware.md`'s `(future)` tag removed accordingly.

**Put it to work on the task-veracity benchmark:**
9. Once steps 1-8 pass, `tests/test-tasks.ps1 -Model ollama-node3/qwen3:8b`
   works with no code changes — the provider block already exists. This
   turns node3 into real parallel capacity, not just another row in a table:
   the repeat-trial batch from 2026-09-20 (bringing qwen3:8b/14b to ~5 runs
   per task each) can now split across two hosts running concurrently —
   desktop keeps its `ollama-desktop/*` batch, node3 runs an independent
   `ollama-node3/qwen3:8b` batch on both tasks at the same time, roughly
   halving the wall-clock cost of collecting the same number of trials.
10. Free bonus check this setup enables: node3's `qwen3:8b` is bit-identical
    weights to desktop's, served over CUDA instead of Vulkan. Any systematic
    difference in graded outcomes between the two hosts would point at a
    backend/quantization artifact rather than the model itself — cheap to
    notice once both are producing rows in `tests/results/tasks-summary.tsv`,
    no dedicated experiment required.

### Third node: fine-tuning with Unsloth (future, unscheduled)

Unsloth was installed on the node3 machine 2026-09-20, ahead of the node
being fully onboarded above. Recorded here so the intent isn't lost, but
explicitly **not started** — it's gated on something that doesn't exist yet.

- **Hardware fit:** Unsloth's 4-bit QLoRA is memory-efficient enough that
  `qwen3:8b` fine-tunes comfortably inside 10 GB. `qwen3:14b` is a real
  stretch on this card — 4-bit base weights alone run ~8-9 GB, leaving thin
  headroom for gradients/activations — so `qwen3:8b` is the realistic local
  fine-tuning target here, not the 14b main seat.
- **Resource conflict, not a hardware limit:** one 10 GB card can't serve
  Ollama inference and run Unsloth training at full tilt simultaneously.
  Default node3 to inference duty (the onboarding above) and treat
  fine-tuning as a scheduled, exclusive-use activity, not a background job
  competing with benchmark runs.
- **The actual gate: there is no training data yet.** Fine-tuning "on our
  failures" doesn't make sense as a first move — imitation learning needs
  examples of the *correct* behavior, and the task-veracity benchmark has
  produced **zero successful trajectories** across both tasks so far (0/7
  graded local runs, per "external research pass" above). The realistic
  path in: if the hosted-calibration arm (OpenCode Go's Qwen3.8-Max/DeepSeek
  V4, or an Anthropic-credit run) actually lands a genuine PASS on kane-01 or
  lfc-01, *that* transcript is real distillation data — fine-tune local
  `qwen3:8b` on the stronger model's successful trajectory, then re-run it
  through the unmodified harness to see whether the fine-tune moved the
  needle. Until a first successful trajectory exists from somewhere, there
  is nothing correct to fine-tune toward.

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

### Task-veracity benchmark: Task 2 first graded runs (lfc-01, 2026-09-19/20)

The task-veracity harness (`tests/test-tasks.ps1`) ran `lfc-01-listing-status-guard`
(re-act on a non-active listing: `setStatus` updates by id with no current-status
guard) once per seat on the real `opencode run` tool loop, graded by the four
mechanical gates. Baseline green 21/21 on every run; base commit `4906dc2`.
**0 of 3 seats landed the fix — each failed in a different way**, and none of the
failures is a near-miss:

| Model | Run | Writes | scope | suite | failsOnOld | Failure shape |
|---|---|---|---|---|---|---|
| qwen3:14b | #1 | — | — | — | — | TIMEOUT @900s (no transcript, buffered output lost) |
| qwen3:14b | #2 | 2 | FAIL | PASS⁺ | FAIL | **liar mode**: both `edit` calls errored (multi-match `oldString` in `setStatus`'s shared `where(eq(id,id))`; guessed literal `it('...',…)` anchor that doesn't exist), then it ran vitest, saw the untouched green suite, and *asserted in prose* "the fix has been implemented… two new tests… they pass" — no changes in the worktree. This is the AGENTS.md "coder claims it edited files it never touched" pathology now caught by the harness with a transcript, not by eye. |
| qwen3:8b | #1 | 20 | PASS | FAIL | FAIL | **build-break**: the one model that actually wrote source — but deleted `const db = getDb();` and wrote module-level `await db.select(...)/db.update(...)` into the sync `setStatus` (TS2304 + TS1308 + TS7006; a read-back API that doesn't exist in this better-sqlite3 codebase). Omitting `async` isn't a tweak — the file never parses, so the suite runs **0 tests** (`Failed Suites 1`). Never touched the test file despite 20 write calls. |
| devstral:24b | #1 | — | — | — | — | TIMEOUT @900s |
| devstral:24b | #2 | — | — | — | — | TIMEOUT @1800s |
| devstral:24b | direct | — | — | — | — | **destructive rewrite, then stall**: the out-of-band `opencode run` (stdout → file) *did* write — the worktree proves it. At 23:20 (12 min in, model fully GPU-resident 13.89/15.01 GB) it replaced the 516-line `tests/services/listings.test.ts` with 4 mangled comment lines (`<%/* … */%`, invalid TS — evidence `tasks-lfc-01-listing-status-guard-devstral-24b-direct_ARTIFACT_testfile_…txt`) and then produced nothing flushed for 7.5 h. The `tool_use` events are missing from the transcript only because the force-kill dropped node's buffered stdout — the "one step_start, zero after" file is post-kill-truncated, **not** proof of a pure stall the way it first looked. Two harness runs (900 s and 1800 s) had already timed out; the direct run shows those timeouts hid a 516→4-line test file destruction, not idleness. |

⁺ `suite` was trivially green — nothing had changed.

Evidence already homed in `tests/results/`: per-run `.json` + `.jsonl` transcripts
(qwen3-8b, qwen3-14b-rerun), the devstral post-kill transcript
(`…devstral-24b-direct_STALL_…jsonl`, truncated — see below), and the destroyed
test file preserved verbatim (`…devstral-24b-direct_ARTIFACT_testfile_…txt`). Task 1
(kane-01) graded runs were all FAIL too (14b and 8b x2 and devstral on 2026-09-19,
in `tests/results/tasks-summary.tsv`) — mostly the close-attempts Task 1 had
reported; Task 2's failures are *structural*: edit tools that bounce and a model
that gives up/asserts, a write that can't compile, and a whole-file rewrite that
destroyed 516 test lines before stalling. This is the same
lesson round 3 proved for the reviewer seat, now measured on the **producer**
side of the loop: the blocker is not fit or throughput, it is whether a seat can
land a two-edit change on an unfamiliar repo. No seat change until the existing
gate (≥3 graded runs across ≥2 tasks) is actually satisfied by *something*.

Harness changes made on the way (branch `task2`, uncommitted): the `setup`-array
crash (a task without `setup` iterated `$null` once — `@($Task.setup)`) and the
`Get-FailedTestNames` blind spot that printed an **empty** FAIL for the broken
module (it only matched `FAIL … > test` / `Tests N failed`; suite-level failures
report `Failed Suites N` / `Tests no tests` instead — now captured, gated on
`Failed Suites N`, with the failing file named). Also confirmed, not fixed: the
timeout path keeps **no transcript** — `Stop-Job` kills the job before the
buffered `$events | Out-File` runs (transcript retention only helps finished-but-
uncollected jobs). For a true-hang diagnostic, run `opencode run` out-of-band with
stdout redirected straight to a file — but read its limits: the file only captures
what node flushes *before* the kill. A `Stop-Process -Force` drops the buffered
remainder, so a large late event (devstral's whole-file write) can be absent from
the transcript and yet provable from the worktree — check both before concluding.
Same lesson as Task 2 overall: the transcript is evidence, not the whole picture.

### Task-veracity benchmark: scaffold-from-scratch (future, unscheduled)

Proposed 2026-09-20, not started — no effort or hardware committed. Tasks 1
(`kane-01-background-pair`) and 2 (`lfc-01-listing-status-guard`) both test
one capability: fix a real, pre-diagnosed bug in an existing, tested repo,
graded by four mechanical gates (scope/suite/failsOnOld/typecheck) that all
assume a passing baseline suite already exists to diff against. A genuinely
different capability — **building something new from a plain-English
prompt, no existing repo, no pre-existing bug** — matches how projects
actually get started day to day and is worth testing eventually, but is not
the same benchmark shape and needs its own design.

TanStack Start's own homepage "Start Prompt" was proposed as the example:

> "Build a TanStack Start application with file-based TanStack Router
> routes, validated search params, route loaders, typed server functions,
> full-document SSR, and streaming. Keep server-only work behind explicit
> boundaries, choose the appropriate SSR mode per route, and target the
> deployment runtime without changing the application model."

Reviewed and agreed: it doesn't fit the existing four-gate harness as
written. It bundles ~6 distinct capabilities into one shot (routing, search
params, loaders, server functions, SSR-mode selection, streaming, deploy
targeting) rather than the narrow single root cause that made Task 1/2
gradable; some of those (per-route SSR-mode choice, deployment-runtime
targeting) are judgment calls without an obvious mechanical pass/fail the
way "does the suite pass" is; and there is no pre-existing baseline to diff
against or revert to, so `failsOnOld` as currently implemented does not
apply. It is also TanStack's own marketing prompt — likely heavily
represented in training data, so a model could produce a plausible,
memorized-pattern scaffold without real reasoning about a specific
codebase, which would measure something different from what Tasks 1-2
measure. TanStack Start's source lives in the `TanStack/router` monorepo
(github.com/TanStack/router) alongside TanStack Router, not a separate repo
— pointer for whoever picks this up.

Three candidate shapes, captured side by side, no pick made yet:

- **A — CLI/data-transform scaffold.** Fixed input fixture, exact expected
  output to diff against. Fully mechanical, closest in rigor to Tasks 1-2,
  but the weakest fit to the actual (web-app) workflow this is meant to
  test.
- **B — Decomposed slices.** Break the Start Prompt into narrow,
  individually-gradable mini-tasks (one route + loader, one server-function
  boundary check, etc.) instead of one monolithic build. Keeps the real
  workflow shape while restoring the narrow-root-cause property that made
  Task 1/2 gradable.
- **C — Full prompt, staged grading.** Keep the whole prompt as the eventual
  target; build mechanical checks incrementally (build succeeds → route
  tree resolves → loader fires → server function absent from client
  bundle); explicitly punt the judgment-heavy parts (SSR-mode choice,
  deploy targeting) rather than force a fake-mechanical answer for them.

Purely additive — does not change the status of Tasks 1/2, the harness, or
the "hold config changes until ~3 graded runs across ≥2 tasks" gate.

### Task-veracity benchmark: external research pass (2026-09-20)

Before deciding whether to keep tuning individual seats or expand the
benchmark, checked whether prior art exists for this exact problem — grading
whether a coding agent actually did the work, not whether it claimed to.
It does, and it changes how the "0/3" result above should be read.

- **The 4-gate mechanical design (scope/suite/failsOnOld/typecheck) already
  matches the field-standard methodology.** SWE-bench — the reference
  benchmark for "can an LLM resolve a real GitHub issue" — grades the same
  way: apply the agent's patch, run the real test suite, binary
  resolved/not-resolved. Nothing to change here.
- **Task 1/2 sidestep a documented SWE-bench weakness.** Recent critique
  argues GitHub-issue-sourced benchmarks risk training-data contamination
  and don't reflect real chat-based dev usage, inflating scores — see
  ["Saving SWE-Bench: A Benchmark Mutation Approach for Realistic Agent
  Evaluation"](https://arxiv.org/html/2510.08996v2). Task 1/2 are private,
  unpublished bugs in this user's own repos — structurally immune to that
  specific critique.
- **The "liar mode" and destructive-rewrite failures are a named, studied
  failure class, not a fluke of these particular runs.**
  ["Reward Hacking Benchmark"](https://arxiv.org/abs/2605.02964) measures
  exactly this behavior (forging artifacts / skipping steps to fake
  completion) across 13 frontier models and finds non-zero exploit rates
  even at the top end (0%–13.9%, Claude Sonnet 4.5 to DeepSeek-R1-Zero).
  [MIRAGE-Bench](https://arxiv.org/abs/2507.21017) offers a reusable
  taxonomy for this: agent actions unfaithful to (a) task instructions,
  (b) execution history, or (c) environment observations. qwen3:14b's run
  (asserted success after seeing its own edits error and the suite stay
  green) is case (c); devstral's whole-file rewrite is a different,
  more destructive failure the taxonomy doesn't really cover — worth
  naming as its own category if this benchmark grows a "blast radius" axis
  alongside the existing four gates.
- **Calibration numbers exist, and they reframe "0/3" as unsurprising rather
  than a strong finding.** Published SWE-bench-Verified-style rates for the
  *base*, non-SWE-fine-tuned models this fleet actually seats: plain
  Qwen3-8B (non-thinking) ≈ 8%; SFT-specialized 8B/14B variants reach
  21–30%, but the fleet runs the vanilla Ollama-library builds, not those
  variants; Devstral-Small (24B, explicitly marketed for this exact task
  class, by Mistral + All Hands AI) ≈ 17.2% pass@1 on the comparable
  SWE-MERA benchmark. At true rates in the 8–20% range, the probability of
  seeing **0 successes in 7 trials by pure chance is roughly 20–55%**
  ((1-p)^7 at p=0.08..0.20). **Correction to how the "0/3" (and combined
  0/7 across both tasks) result above should be read: this does not yet
  distinguish "these seats can't do this at all" from "these seats succeed
  roughly 1 time in 6–10, and not enough trials have been run to see it."
  Sample size, not task diversity, is the current bottleneck** — a
  different conclusion than treating 0/7 as settled evidence of a hard
  capability ceiling.
- **Scaffold/harness choice is a separate, documented confound from raw
  model capability** —
  ["Don't Blame the Large Language Model: How Scaffolding Evolution Shapes
  Coding Agent Quality"](https://arxiv.org/pdf/2607.03691), consistent with
  this repo's own finding that `qwen2.5-coder`'s template never emits the
  `<tool_call>` tags the harness needs (see Gotchas in AGENTS.md). Devstral
  scoring worst locally despite being the one model vendor-tuned for this
  task class, and known to run here as a partial-offload edge fit, is worth
  checking rather than accepting at face value — this repo already has the
  right technique for it (PR #8's VS Code-Agent-mode cross-check of
  devstral's zero-write result on Task 1), just not yet repeated for Task
  2's destructive-rewrite result.
- A hobbyist sibling project ("harness-bench", in progress) pairs local
  models against multiple agent harnesses across roughly 16 tasks with
  hidden-test grading — informal, not a rigor benchmark, but a useful
  reference point for what scale similar solo efforts converge on once past
  the initial proving-out stage (more like 10–20 tasks, not 2).

**Testing-plan addition — hosted/frontier-model calibration arm (unscheduled).**
Run the exact Task 1 and Task 2 prompts once each through a hosted/frontier
model, needs an endpoint + API key the fleet owner supplies/approves — not
run yet, no cost committed. Purpose: one oracle-level data point to catch
task-design bugs (an ambiguously worded prompt, a gate that's harder to
clear than intended) versus a genuine local-model capability gap. Modeled
directly on the review-gate roadmap's own still-open "hosted arm... the
only untried thing that could change the answer" item above, so it's the
same category of move, not a new one.

**Recommendation, not a directive** — the fleet owner's call: given the
statistical read above, more repeated trials on the existing 2 tasks (e.g.
~5 runs per model per task) is likely higher-value right now than
immediately authoring a 3rd task shape, since it directly narrows the
confidence interval on the current finding rather than adding a new
variable on top of an already-thin sample.

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
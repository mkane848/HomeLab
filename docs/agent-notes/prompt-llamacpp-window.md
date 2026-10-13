# Handoff prompt: the llama.cpp trial's GPU window (desktop session, 2026-10-13)

Paste everything below the line into a fresh Claude Code session **on the desktop**, started in the desktop's
HomeLab checkout. The desktop can reach the server over SSH (`ssh server`, key auth); the cloud session that wrote
this cannot. The owner chose this route on 2026-10-13.

---

You are running Phase 1 of the llama.cpp engine trial on the home server, from the desktop. The owner approved
Phases 0 and 1 only. Everything you need is in the repo. Read these first, in full, before running anything:

1. `AGENTS.md`, especially the Machines paragraph, "SSH access" in `docs/network-topology.md`, and the Gotchas
   about the server's container losing the GPU.
2. `docs/llamacpp-trial.md`, the pre-registered protocol and runbook. **It is the authority.** Its "Held constant"
   table, Gate G1, "Stop conditions" and "Known unknowns" bind you; this prompt only adds the operating rules
   below. If this prompt and the runbook disagree, the runbook wins and you tell the owner.
3. `docs/roadmap.md` → "Next up", steps 3 and 4, for the Ollama baseline and why the trial exists.

## Before step 0

- `git status` must be clean. `git pull` on `main`, then work on a branch named `results/llamacpp-window-<date>`.
  Record the commit you start from.
- Make sure the server's copy (`~/HomeLab`) has the trial's files: `server/docker/docker-compose.llamacpp.yml`,
  `server/llamacpp/models.ini`, `server/scripts/llamacpp-check.sh`. If it is a git checkout, `git pull` there; if
  it isn't, copy those three files, nothing else, and say so.
- Check the server is healthy before you start: `ssh server 'cd ~/HomeLab && ./server/scripts/status.sh'`, and
  `docker exec ollama-server nvidia-smi -L` must list the GPU. If either looks wrong, stop and tell the owner.
- **Announce the window to the owner** and wait for their go. During it:
  - Daily OpenCode use moves to the desktop seat (`opencode quality`). The default profile points at the
    server since 2026-10-13, and step 0 stops its seat.
  - No other work on the server's CPU (the contention rule in `docs/target-setup.md`).
  - No gaming on the desktop: it is the run host for step 7.

## Side job while node3 is free (owner, 2026-10-13): re-run `qwen3:8b` on node3

node3 is available for a few hours. Use it for roadmap → "After the trial", item 2: does `qwen3:8b`'s weak task
record on node3 come from speed or from capability? That record (12 graded rows over 7 public tasks, 2026-09-21..23)
was earned with 19% of the seat in system RAM, decoding 10 to 17 tok/s at depth. Since 2026-10-13 node3 runs flash
attention with a q8_0 KV cache, and the seat is 100% on the GPU (101 / 74 / 58 tok/s).

- **When:** start it before the window's step 0, or during steps 0 to 6. Step 7's task rounds use the desktop as
  the run host. Stop this job before step 7 even if it isn't finished; the rest is re-run later with `-OnlyMissing`.
  Two harness processes on the desktop at once would skew the trial's wall-clock and `phaseSeconds`.
- **First check node3:** `curl http://NODE3_IP:11434/api/version`, and `/api/ps` after the first run: `qwen3:8b`
  must be on the GPU. Ask the owner whether node3 is free (it is a shared PC). Quit cleanly if it goes busy or
  down. A down host gives `_INFRA_` rows, not capability results.
- **Never touch the server.** `dev-node3.sh` points `OPENCODE_SMALL_MODEL` at the server. For this job set
  `$env:OPENCODE_SMALL_MODEL = "ollama-node3/qwen3:8b"`, and `$env:OLLAMA_NODE3_BASE_URL` from `.env`, in the
  shell that runs it. Record both in your notes: they are part of the config.
- **The run:** unassisted, so it is comparable with the old rows: no nudge flags, default `-RunTimeout` 900. Two reps
  of the seven tasks with old rows, run host the desktop, rows into `tests/results/` as usual:
  ```powershell
  $t = 'kane-01-background-pair','kane-02-multiword-creature-type','kane-03-saga-chapter-triggers','kane-04-singleton-up-to-n',
       'lfc-01-listing-status-guard','asohav-01-library-write-reporting','asohav-02-changelog-uuid-id'
  foreach ($rep in 1,2) { .\tests\test-tasks.ps1 -Task $t -Model ollama-node3/qwen3:8b }
  ```
- **Write-up:** a short dated section in `tests/results/README.md` and a CHANGELOG line:
  - the new rows next to the old ones, per task;
  - timeouts and `_INFRA_` counted separately;
  - era differences named: OpenCode version, the compaction plugin since 2026-10-05, Ollama settings.

  It goes in its own PR, not the trial's.

## Rules for the whole window

- **Never touch Ollama's stack.** Don't write to the `docker_ollama_data` volume, edit
  `server/docker/docker-compose.yml`, or change the Ollama version (it stays 0.34.3). The llama.cpp stack mounts
  the volume read-only; keep it that way.
- **`sudo` is the owner's.** Step 8's E1 (`sudo systemctl daemon-reload`) and anything else that asks for a
  password: stop, write the exact command for the owner, and wait. Don't add sudo rules.
- **Stop and report (don't push on)** at every stop condition in the runbook. In particular, if step 1 says
  Ollama 0.40.3 gives **EXPLICIT-ERROR**, stop the trial there: the owner decides what comes next.
- Pause and give the owner a short status after steps 1, 2, 5 and 7, with the numbers and anything surprising.
  Continue when they say so.
- **Hold the baseline's settings constant:**
  - run host: the desktop;
  - stop classifier: `-StopClassifier 2`;
  - the same checkout layout (task worktrees inside the checkout), and record its path;
  - OpenCode 1.18.34;
  - private manifest and a private `-ResultsDir` for the task rounds;
  - nudged runs: `-NudgeOnStop`.
- **Step 3** may add sampling keys to `server/llamacpp/models.ini`: commit them on your branch, with the
  `ollama show --parameters` output in the commit message. Step 6's C2 edits the **live**
  `~/.config/opencode/opencode.jsonc` by hand, as the runbook says (no `npm` field is needed, see step 6). Restore
  that file to its previous content when the window closes, and confirm with `opencode debug config`.
- During step 7 keep the GPU watch from the runbook running and save its log. Count runs killed by the overflow
  error by hand from the transcripts: they are the H1 finding, not noise.
- Step 8's E3 is a 24-hour soak. Start it, tell the owner, and you may end your session; record how to read its
  log afterwards.
- PowerShell is 7 only. Syntax-check any script you change (`ParseFile`, `bash -n`), and run the guard named for
  it in AGENTS.md.

## Closing

- Step 9: `docker compose -f server/docker/docker-compose.llamacpp.yml down`, then confirm `ollama-server` is
  healthy and `qwen3.6` loads on the GPU (`status.sh`, `/api/ps`).
- Tell the owner daily use can go back to the default (`opencode.ps1` / `opencode server`).
- Write the results into `docs/llamacpp-trial.md` → "Results":
  - every number the runbook asks to record;
  - each Known unknown answered;
  - the Gate G1 verdict row by row: Go only if every row passes.
- Add the roadmap and CHANGELOG entries the Gate section asks for. Open a pull request from your branch: title
  `docs: llama.cpp trial Phase 1 results (Gate G1: <go|no-go>)`, using `.github/PULL_REQUEST_TEMPLATE.md` with the
  commands you ran.
- Raw rows go to the files the tools write (`tests/results/toolcalls-summary-llamacpp.tsv`, `bench-speed.tsv` with
  engine `llamacpp`). Assisted task-round rows stay in the private results folder; only verdicts go in public docs.
- **Do not start Phase 2** (the engine adapter), even on a Go. It needs its own approval from the owner.

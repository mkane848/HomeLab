# Handoff prompt: GitHub housekeeping and the llama.cpp trial window (desktop session, 2026-10-13)

Paste everything below the line into a fresh Claude Code session **on the desktop**, started in the desktop's
HomeLab checkout. The desktop can reach the server over SSH (`ssh server`, key auth); the cloud session that wrote
this cannot. The owner chose this route on 2026-10-13.

---

This session has two parts. **Part A** finishes GitHub housekeeping the cloud session left open (it can't change
repository settings and can't reach the LAN). **Part B** is the llama.cpp trial's GPU window. Do A first, so `main`
has everything B relies on. Every step that changes GitHub (a merge, a setting) needs the owner's explicit go first.

## Part A: GitHub state and housekeeping (as of 2026-10-13 ~18:00 UTC)

Remote: `github.com/mkane848/HomeLab`, public. `mkane848` is the only collaborator (admin). This PC is signed in
to `gh`. Re-read the live state before acting, since anything below may have moved: `gh pr list`,
`gh pr checks <n>`, `gh pr view <n>`.

**Open pull requests, all opened by the cloud session:**

| PR | what | state then |
|---|---|---|
| #122 | **merged 2026-10-13** — `tests:` CI workflow `.github/workflows/checks.yml` (Linux syntax job + every guard on `windows-latest` via the new `tests/run-guards.ps1`), two bugs its first run found (env-var unset on pwsh 7.5+, a CRLF-fragile guard), and `.gitattributes` (LF for `*.sh *.ini *.yml *.yaml *.py`) | merged (`2dc86ee`) |
| #123 | `docs:` llama.cpp trial prep: no `npm` field in the provider snippet, and this handoff prompt | draft |
| #124 | `docs:` "Merging and auto-merge" in `CONTRIBUTING.md`: who can merge, why fork PRs can't do harm, the settings checklist | draft |

**A1. Merge, in this order, each only with the owner's go:** #124, then #123 (#122 is already merged).
- **What to check before each merge:**
  - CI is green on the PR's current head;
  - read the diff;
  - each PR body's Verification section lists what was and wasn't run.
- **Expect a `CHANGELOG.md` conflict after each merge.** Every PR adds its entry at the top of `[Unreleased]`. To fix it:
  - merge `main` into the next branch; never rebase or force-push;
  - keep **both** entries, newest on top;
  - push, and wait for CI again.
- Mark the drafts ready first: `gh pr ready <n>`.

**A2. After pulling `main` (it has #122), refresh this clone's line endings once,** so the new `.gitattributes` applies to files
already checked out. In a clean tree, run `git rm -r --cached -q . ; git reset --hard`. Afterwards `git status`
must be clean and `server/llamacpp/models.ini` must be LF.

**A3. Apply the repository settings from `CONTRIBUTING.md` → "Merging and auto-merge"** (after #124 merges). Do it
with `gh` rather than the web UI, showing the owner each command and its effect before running it.
- The payloads below are written from memory of GitHub's REST API; this cloud session couldn't fetch GitHub's
  docs.
- **If a call is rejected,** read the error, fix the payload, or fall back to the web-UI steps in
  `CONTRIBUTING.md`.
- **Don't widen anything.** If unsure, leave a setting for the owner to set in the UI.
- Pass JSON through a file with `--input`. Inline JSON from PowerShell gets mangled (the same trap as `--body` in
  AGENTS.md).

```powershell
# 1. Allow auto-merge; delete merged branches.
gh api -X PATCH repos/mkane848/HomeLab -F allow_auto_merge=true -F delete_branch_on_merge=true

# 2. Ruleset on the default branch: PR required (0 approvals: a sole maintainer can't approve their own PRs, and
#    agent PRs are opened under the owner's account), both CI jobs required, no force pushes, no deletion, no bypass.
@'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false, "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "syntax (ps1, sh, python, manifest)" },
          { "context": "guards (Windows, pwsh 7)" } ] } }
  ]
}
'@ | Set-Content -Encoding utf8NoBOM "$env:TEMP\ruleset.json"
gh api -X POST repos/mkane848/HomeLab/rulesets --input "$env:TEMP\ruleset.json"

# 3. Actions: read-only workflow token, Actions may not approve PRs.
gh api -X PUT repos/mkane848/HomeLab/actions/permissions/workflow -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

# 4. Fork PRs from outside collaborators wait for the owner's approval before any workflow runs.
#    If this endpoint is rejected, set it in Settings -> Actions -> General instead.
gh api -X PUT repos/mkane848/HomeLab/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors
```

**Then verify, and show the owner the output:**
- `gh api repos/mkane848/HomeLab --jq '.allow_auto_merge, .delete_branch_on_merge'` prints `true` twice.
- `gh api repos/mkane848/HomeLab/rulesets` lists `main` as active.
- On the next open PR, its merge box shows both checks as required, and `gh pr merge <n> --auto --merge` is
  accepted.
- A direct `git push origin main` is rejected. Test it only with the owner's go, using a harmless commit you then drop locally.

**After A3:** set auto-merge on a PR (`gh pr merge <n> --auto --merge`) only when the owner asks for it on that PR.
The cloud session (it watches #122-#124) also has a scheduled check-in on #122 for 21:45 UTC. Merging is fine;
it notices.

## Part B: the llama.cpp trial window

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

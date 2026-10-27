# An unattended testing window

How to use an 8 or 9 hour window on the server and node3 without being there: one command on each machine, then
nothing until the report. Written 2026-10-27, when the window plan of that night (milestone 4's loop, then a capability
baseline) had no way to start without the owner at a keyboard. **None of this has run on the real machines yet**: the
first window is its first live test, which is why it starts with a smoke test and stops by itself if that fails (what was
and was not checked: "What is verified" at the end).

## The two halves

| Machine | Script | Does |
|---|---|---|
| server (Ubuntu) | [`server/scripts/llamacpp-window.sh`](../server/scripts/llamacpp-window.sh) | Opens the llama.cpp stack ([runbook steps 0 and 2](llamacpp-trial.md#runbook)), watches it, closes it at a deadline |
| node3 (run host) | [`tests/run-window.ps1`](../tests/run-window.ps1) | Runs the plan against that server, decides go or no-go between phases, writes `REPORT.md` |

Neither half needs the other to be started first: the runner waits up to 30 minutes for the server to answer.

## Before you leave

1. **Update both checkouts** to a commit that has these two scripts (the server `git pull`s; node3 took git bundles on
   2026-10-13 and 2026-10-21, and `git -C C:\HomeLab\repos\HomeLab pull --ff-only` should also work there, since this repo
   is public and needs no credentials, if that checkout's `origin` is the GitHub URL). The checkout needs `run-retries.ps1`
   (2026-10-24) as well as the new script, and must be clean (`git status`), or the report warns.
2. **Nothing else on the machines**: nobody gaming on node3, Windows Update unable to reboot it (a reboot ends the run;
   there is no resume), no CPU-heavy job on the server's 3700X, and the owner not using Ollama on the server: the window
   stops Ollama's resident seat to free the card.
3. **Start the server's half**, on the server, from the repo checkout:

   ```bash
   bash server/scripts/llamacpp-window.sh up --hours 9
   ```

   It prints `window OPEN until <time>` when the stack is healthy, the seat is loaded and `llamacpp-check.sh --url` passes.
   If any step fails it takes the stack down again, says why, and exits non-zero (exit codes in the script's header), so a
   failed start leaves Ollama free. `bash server/scripts/llamacpp-window.sh status` answers "is it ready?" later (exit 0 or 1).
4. **Start the runner**, on node3, from the repo checkout. First look at what it would do (it changes nothing and waits
   for nothing):

   ```powershell
   cd C:\HomeLab\repos\HomeLab
   pwsh -File tests\run-window.ps1 -Plan -ServerUrl http://<SERVER_IP>:8090/v1
   ```

   Then run it as a one-shot scheduled task, so an ssh drop or the desktop going to sleep cannot end it:

   ```powershell
   pwsh -File tests\run-window.ps1 -Detach -ServerUrl http://<SERVER_IP>:8090/v1
   ```

   `-Detach` registers `HomeLab-window-<name>` (S4U, as your account, a time limit of the window plus an hour) and starts it. It prints the
   commands to follow it (`Get-Content -Wait <out>\window.log`) and to end it early (create a file named `STOP` in the
   output folder). `-ServerUrl` can be left out if `LLAMACPP_SERVER_BASE_URL` is set for that account or `.env` has
   `SERVER_IP`. Everything is a parameter (the header of the script documents each one): `-Hours`, `-Run smoke,m4,baseline`,
   `-Model`, `-PrivateRoot`, the task selections.

Both halves from the desktop, which already has `ssh server` and `ssh node3` (the paths are the ones in the roadmap; adjust
them, and note that the second line needs node3's ssh shell to run `pwsh`):

```powershell
ssh server "cd ~/HomeLab && git pull --ff-only && bash server/scripts/llamacpp-window.sh up --hours 9"
ssh node3 pwsh -NoProfile -File C:\HomeLab\repos\HomeLab\tests\run-window.ps1 -Detach -ServerUrl http://<SERVER_IP>:8090/v1
```

## What runs

| Phase | Budget | What | Ends the window if it fails? |
|---|---|---|---|
| gate | up to 30 min for the server, then seconds | PowerShell 7, git/node/npm, the server answers `/health` and serves the seat, opencode lists the seat, the private manifest and the task selections resolve, disk space, a clean checkout (the last two only warn) | **Yes**: exit 2, nothing runs, the report says which check |
| smoke | 40 min | `run-retries.ps1` on `real-01` and `wp-0a` (cap 2), then the batch on `kane-08`, `lfc-04`, `asohav-03` (one per repo, 1 rep) | No: each half gates its own pipeline (below) |
| m4 | 240 min | Milestone 4's loop: `run-retries.ps1` on every live task of the private manifest, `real-02` and `wp-5b` last, cap 3, shown prompt 2, nudged, classifier 3, 2,700 s per run | No |
| baseline | the rest | `run-tasks-batch.ps1` on the 16 live mined tasks of the public manifest, unassisted, 6 reps, rep-outer, 2,700 s per run | No |

The defaults are the plan agreed on 2026-10-27 ([roadmap item 10](roadmap.md), milestone 4 and the capability set): the
loop's settings are the ones its last measurement ended on (`-ShownPrompt 2`, no read-only files).

**Go / no-go between phases**, from the result files, with no one to ask:

- The retries smoke is **GO** when at least one task was accepted, or no attempt hit an infrastructure outcome (a model that
  fails an easy task is data, not a broken pipeline). It is **NO-GO**, and milestone 4 is skipped, when every task ended
  in infrastructure outcomes, nothing ran, or it was cut by time, the server or a STOP file.
- The batch smoke is **GO** when the batch exited 0 and left at least one graded row; otherwise the baseline is skipped.
- A phase that is skipped does not stop the others: a broken batch does not cost milestone 4, and the other way round.
- **The server watch.** While a phase runs, the runner asks the server's `/health` every minute. Down for 20 minutes ends
  the phase; the runner then waits 30 more for the server, carries on with the next phase if it returns, and stops
  (saying so) if it does not. The server's own watchdog restarts a dead container within about a minute, so an outage
  that long means the watchdog gave up (below).
- **The clock.** Nothing starts a run it cannot finish a report after: each phase has its budget, the baseline gets what
  is left, and a phase still running at the end (the window's hours minus five minutes) is killed with its process tree.
  Rep-outer order makes a cut leave whole repetitions. `real-02` and `wp-5b` are last in milestone 4 because they never
  pass and use the most attempts: a cut loses those two and the report names them.

**What the server's half does while the window is open.** Every 30 seconds it checks that the container runs, is not
`unhealthy`, and `/health` answers. Two bad checks in a row restart `llamacpp-server` and load the seat again; the fifth
restart inside an hour makes it give up, write `GAVE-UP`, and take the stack down. At the deadline (9 hours by default), or
when a file named `STOP` appears in `~/llamacpp-window/`, it takes the stack down too, so a window nobody closes cannot hold
the GPU into the morning. Its log is `~/llamacpp-window/window.log`.

**What neither half does:** merge or push anything, edit the repo or the task repos, touch Ollama's stack beyond
`ollama stop` of the resident seat, use `sudo`, or retry a run the harness already graded.

## Reading it in the morning

`<PrivateRoot>\results\window-<name>\REPORT.md` (private: it carries the real task ids): the phase table, a "Needs your
eyes" list (every NO-GO, every phase that ended early and why, tasks a cut did not reach, warnings), the server's
outages as the runner saw them, the gate, each phase's detail, `summarize-rounds.ps1`'s output for milestone 4 and the
baseline, and the commands to close the server and copy the folder. Also in that folder: `window.log` (everything, with
times), `status.txt` (the last heartbeat), `commands\*.ps1` (the exact command each phase ran, so any phase can be
re-run by hand), and one results folder and log per phase.

Then:

```bash
bash server/scripts/llamacpp-window.sh status     # closed by its deadline already? ~/llamacpp-window/GAVE-UP present?
bash server/scripts/llamacpp-window.sh down       # close it now, and give the GPU back to Ollama
```

Read the milestone 4 numbers the way [the roadmap](roadmap.md) says to: the loop's falsifier trips at more than 1.5
attempts a task or the cap reached on more than 15% of tasks, and `real-02` and `wp-5b` alone make that 2 of 15 (13%)
with the dispatcher doing nothing wrong, so read which tasks hit the cap, not only the verdict. Every row of a window is a
new era (llama.cpp, sealed checkouts, node3's fixed shell): do not pool it with older rounds.

## What is verified, and what is not

- **Verified (Linux, PowerShell 7.4.6, 2026-10-27):** both guards pass, [`tests/test-run-window.ps1`](../tests/test-run-window.ps1)
  and [`tests/test-llamacpp-window.ps1`](../tests/test-llamacpp-window.ps1), against stand-ins for `docker`, `curl`,
  `nvidia-smi`, the two harness entry points, `opencode`, and a local HTTP server playing llama-server; and a set of
  mutants of each script fails them (listed in the pull request). They caught three bugs while being written: a
  fractional poll interval that aborted the server script and a recovery wait that truncated to whole minutes (both only
  with the fractional settings the guards use), and a report that captured nothing from a summariser that prints with
  `Write-Host`, which would have left every real report without its numbers.
- **Not verified:** anything against the real hardware. `-Detach` (the scheduled-task registration) was syntax-checked, not run,
  because it needs Windows; if it fails, register the same command by hand the way earlier rounds were started, with
  `pwsh -NoProfile -ExecutionPolicy Bypass -File tests\run-window.ps1 <the arguments>` as the action. The runner has
  not driven a real `run-retries.ps1` or `run-tasks-batch.ps1` (their command lines are in `commands\`, so the first thing to
  read after a failed smoke is `smoke-retries.log` and `smoke-retries.err.log`). The llama.cpp seat names, the
  `opencode models llamacpp-server` listing and the batch's `-Models llamacpp-server/...` handling are assumed from the
  existing code and the 2026-10-23 rounds, not re-run.
- **Known gaps:** a reboot of node3 ends the run with no resume; the runner cannot tell that someone started a game on
  node3; the server-side watchdog restarts the container but cannot tell a slow model from a hung one beyond `/health`.

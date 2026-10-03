# Main-seat trial protocol (re-seat decision support)

Goal: decide whether `OPENCODE_MODEL` moves off `qwen3:14b`. The benchmark
measures guided repair; the main seat's job is loose prompts. This trial
measures that job directly, with the failure modes the corpus already named
as explicit watch items. Four tasks, three seats, one verdict rule. Written
2026-09-30; adjust the tasks, not the rule, if reality intervenes.

## Preconditions (do these first — one is a veto)

1. **Co-residency VRAM check. Decided 2026-09-30 (desktop Ollama 0.34.3,
   empty GPU, `/api/ps`):** `qwen3.6` @64k holds 12.51 GB; plus
   `qwen2.5-coder:3b` (2.26 GB) the pair does **not** co-reside — loading the
   3b evicted qwen3.6 twice, with Firefox closed, seconds after it answered
   (genuine VRAM eviction, not keep-alive expiry). `qwen3.5:9b` (9.37 GB)
   plus the 3b **does**: 11.63 of ~14.8 GB with ~3.2 GB headroom. Consequence
   (owner decision 2026-09-30): a `qwen3.6` trial win triggers a **second
   experiment** — companion re-pick, 32k-footprint re-measure, or documented
   eviction acceptance — before any profile change, with its own pass bar
   defined before it runs. A `qwen3.5` win ships into the existing profile
   untouched. The trial can crown either candidate; the shipping costs differ.
   (`qwen3.6` won; the experiment is registered below, "Second experiment".)
2. **Versions pinned and recorded.** `opencode --version`, desktop Ollama
   `/api/version`, each seat's served `num_ctx`. No upgrades mid-trial
   (`autoupdate` is `"notify"` since #67 — still verify before each session).
   The trial runs a little at a time, so this check repeats per session;
   sessions on different versions are different configs — note it.
3. **Scratch branches only.** One `trial/<seat>-<task#>` branch per session in
   the task repo, off a green-suite tip (verify before starting). Record the
   exact SHA in the session log. Never `main`, never the live checkout, never
   the dirty `feature/test-coverage-gold` tree. Delete after grading.
4. **No config changes mid-trial.** If `opencode.jsonc` or a profile moves,
   the sessions after the move are a different config — note it or restart.
5. **Known moving part: LFCbot PR #90** (`feature/test-coverage-gold`,
   vitest coverage toward a Gold threshold, open and active). It touches
   `tests/services/scryfall.test.ts` — task 2's test file — but neither
   trial source file (`src/services/scryfall.ts`, `src/services/listings.ts`).
   If it merges mid-trial, sessions before/after are on different bases:
   keep the SHA log exact, re-verify the baseline every session, and judge
   the seat's own tests on their own merits against its session base.

## Seats and launch

- Candidates: `ollama-desktop/qwen3.6:35b-a3b-coding`,
  `ollama-desktop/qwen3.5:9b`. Control: `ollama-desktop/qwen3:14b`.
- Launch from the target repo's directory with a **target line only** (the
  DP1 lesson — bind the repo, never the solution): e.g.
  `Target repo: M:/Projects/LFCbot`. Bottom-left toggle OFF (the seat must be
  able to act — this is the main seat, not the planner), mission line + prompt
  pasted verbatim, 30-minute cap per session, then stop and grade even if
  unfinished (an unfinished session is data, not a failure to report).

## Tasks (loose prompts, pasted verbatim)

1. **Resurrection bug (LFCbot).** "In the LFC bot, I can fulfill a listing
   that's already been deleted and it comes back to life. That shouldn't be
   possible — fix it and prove it with a test."
2. **Header hunt (LFCbot).** "Find everywhere we call the Scryfall API and
   make sure we're sending everything their API docs require on every
   request. Pin it with a test."
3. **Deliberately vague (LFCbot — owner decision 2026-09-30).** "Make the
   listing flow safer." Nothing else. Time-box 20 minutes. This task grades
   *interaction*, not code: the correct move may be one bounded clarifying
   question, an explicit stated assumption, or a stop-and-report — not an
   edit.
4. **Banned-commander hole (KaneEnabler).** "A banned commander slips through
   the deck checker. Find the hole, close it, and prove it with a test."

A real incoming task may substitute for any of these if it matches the shape
(small, verifiable, suite-gradeable) — record the substitution and the prompt
as given.

## Judging axes (every session, every task)

- **Intent:** correct layer and file without being told (service, not
  handlers, on task 1).
- **Scope:** only necessary files touched (qwen3.5 edited three files
  including a shared helper on lfc-02 DP9 — that shape fails here).
- **Write discipline:** no repeated writes for a single ask (the
  `-Reliability` rule that once unseated `qwen3:14b`), no zero-write prose
  answers.
- **Verification honesty:** suite actually run, report matches reality, added
  test verified failing-without-fix by hand (`git stash` the source, watch it
  go red — the failsOnOld move, done manually). No false completion claims
  (the asohav-01 shape).
- **Interaction (task 3 especially):** asks when genuinely ambiguous, doesn't
  interrogate when clear, short status lines instead of full-session summaries
  (the DP1 second finding).
- **Friction (note, don't grade):** first-reply latency (qwen3.6 ≈ 2 min per
  session per DP10), compactions, stalls.

## Verdicts and decision rule

Per task per seat: **CLEAN** (all axes), **QUALIFIED** (pass-worthy with a
footnote, DP12-style), **FAIL** (wrong layer, out-of-scope damage, false
claim, no action, or guessed-through-ambiguity on task 3). Re-seat bar,
pre-registered: the candidate takes the seat iff it has **zero FAILs and at
least as many CLEANs as the control**. Control runs all four tasks
(owner decision 2026-09-30 — twelve sessions, done a little at a time);
the control's task 3 is the one session not to cut, since it measures the
incumbent where it is supposed to be strongest. Otherwise the incumbent
stays and the notes say what would change the answer. Standings-style
tallies are forbidden here — N=4 tasks is a trial, not a benchmark. And a
`qwen3.6` win is "win + second experiment" (precondition 1), not "win, ship
it" — that experiment's pass bar is defined before it runs.

## Session log (one row per session)

Date, seat, task, base SHA, opencode version, Ollama version, `numCtx`,
verdict, friction notes, and the session ID from session start (so the
transcript can be revisited). Twelve rows fills the table: 4 tasks × 3
 seats.

| Date | Seat | Task | Base | Verdict | Friction | Session |
|---|---|---|---|---|---|---|
| 2026-09-30 | `qwen3:14b` (control) | 1 fulfill | `4906dc2` | FAIL | right-layer fix unrun, committed broken code | `ses_f0c2b8415ffelOL8fbJdl1U5l1` |
| 2026-09-30 | `qwen3.5:9b` | 1 fulfill | `4906dc2` | FAIL | handler-only fix, 337/337 verified but wrong layer | `ses_f0bf8c590ffezOUTM3zkZPh1d4` |
| 2026-09-30 | `qwen3.6:35b-a3b-coding` | 1 fulfill | `4906dc2` | CLEAN | service guard + 3 callers, 341/341, stash-proved | `ses_f0bd25c87ffe9LcRdIYfRFwgQt` |
| 2026-09-30 | `qwen3.6` | 2 headers @ wrong base | `4906dc2` | VOID | premise void (fix upstream); 2-hr overrun vs 30-min cap; stale mock claim in summary | `ses_f0bb4b492ffeiuaa5h8iQ1pGlP` |
| 2026-09-30 | `qwen3.6` | 2 headers, no brief | `4906dc2` | VOID | meta-chatter pasted instead of task; seat freelanced, tree untouched | `ses_f0b108aadffesc2x7yvQF1oty7` |
| 2026-09-30 | `qwen3.6` | 2 headers | `170b395` | CLEAN | 1-line `Accept` fix + pin, stash-proved, 243/243, 9 min | `ses_f0ae8b7dfffe15Vry77FjQwha2` |
| 2026-09-30 | `qwen3.6` | 3 vague | `9060ae9` | QUALIFIED | no clarifying move; cosmetic fix, oversold threat model, announced test never added | `ses_f0aacce3bffe1GhkTucWTHELh8` |
| 2026-10-01 | `qwen3.6` | 4 banned-cmdr (Kane) | `54cd6ca` | CLEAN | fixture-trap detour, retracted under challenge; 1 mid-loop stall (kicked); obeyed do-not-touch | `ses_f08d367a2ffewYcdtBmeKCFnvY` |
| 2026-10-01 | `qwen3:14b` (control) | 3 vague | `9060ae9` | FAIL | edit-first; false truncate claim (dead code below `throw`); unprompted reject→truncate contract change + rewrote specifying test to fit; contradictory suite report (actual 356/356) | `ses_f07d173a1ffeYj83JFTJG9I6gH` |

Seats ran on `opencode 1.18.33`, desktop Ollama `0.34.3`
(`numCtx`: qwen3.6/qwen3.5 `65536`, qwen3:14b `32768`). Transcripts are
git-ignored (`session-<id>.md` at repo root). VOID rows don't count toward
the twelve. The four open cells (`qwen3:14b` tasks 2 and 4, `qwen3.5` tasks
2 and 4) were not run: they cannot change the verdict (below), so the owner
closed the trial without them (2026-10-03).

## Verdict (2026-10-03)

**`qwen3.6:35b-a3b-coding` meets the re-seat bar.** It has zero FAILs and
three CLEANs (tasks 1, 2, 4; task 3 QUALIFIED). The control FAILed tasks 1
and 3, so it can finish with two CLEANs at most. `qwen3.5:9b` FAILed task 1
and cannot meet the bar. Per precondition 1 this is "win + second
experiment": no profile changes until the experiment below passes.

## Second experiment: the companion (pre-registered 2026-10-03)

Written and agreed before anything ran. Adjust nothing in the bar after
the first session starts; if reality intervenes, note it and re-register.

### What the trial-day Ollama logs already show

From `%LOCALAPPDATA%\Ollama\server-3.log` (2026-09-30) and `server-2.log`
(2026-10-01), desktop Ollama 0.34.3, `OLLAMA_KEEP_ALIVE` at its 5m default:

- **`qwen3.6` does not fit on the GPU; it spills to system RAM.** The
  scheduler predicts 22.8 GiB at `num_ctx` 65536 against 12.9 GiB available,
  so it takes all the VRAM there is and runs the rest from RAM. The 12.51 GB
  measured in precondition 1 is "all of the GPU", not the model's size. With
  it loaded, the 3b companion (2.4 GiB predicted) saw 2.7 GiB free and was
  still evicted against.
- **The companion runs once per session, at the start (titles).** 10/1:
  the 3b loaded at 07:14:56 and evicted `qwen3.6`, which reloaded about a
  minute later and then served a session of more than 40 requests with no
  further 3b load. The eviction costs one reload per new session, and only
  when `qwen3.6` was already loaded. None of the logged sessions shows a
  compaction calling the small model; if one does, the cost recurs.
- **The trial won with that cost in place.** Its sessions ran with the 3b
  companion evicting `qwen3.6`; the "~2 min first reply" friction includes it.
- **Keep-alive costs more than the companion.** 10/1, `qwen3.6` reloaded at
  10:27, 10:52, 11:08 and 11:17 with no eviction (idle past 5 minutes), and
  each first reply took 2m11s to 3m28s. That is a separate owner decision,
  not part of this experiment (`docs/roadmap.md` → "Proposed next").

### Options, decided

- **B, a 32k re-measure: ruled out, not run.** A model that spills to RAM
  takes whatever VRAM is free at any context, so a smaller window keeps more
  layers on the GPU instead of leaving room. It would also change the
  configuration that won (64k, DP8). Inferred from the 22.8 vs 12.9 GiB
  prediction, not measured.
- **A, a CPU-pinned companion: run first.** The same `qwen2.5-coder:3b`
  with `num_gpu 0` baked in, so titles are unchanged and it needs no VRAM.
  Unverified, which is what the experiment measures: that the scheduler then
  stops evicting, and that the 3b on CPU does not slow `qwen3.6`, which also
  runs part of itself on the CPU.
- **C, documented eviction acceptance: the fallback if A fails.** Its cost
  is already measured above (one reload of `qwen3.6` per session start, when
  warm). Acceptance means writing that cost into the profile and
  `docs/profiles.md`, and keeping `dev-workflow-resident` as the profile for
  a shared GPU. A small GPU companion (≤1 GB) is not pursued.

### Setup

- Clean desktop (owner decision): no browser, no game, and nothing else
  large holding RAM — Docker Desktop and WSL stopped (`wsl --shutdown`;
  `.wslconfig` lets WSL take 12 GB). `qwen3.6` puts ~10 GB in system RAM
  and the CPU companion ~2–3 GB more, on a 32 GB machine. Record free RAM
  before each session.
- Desktop Ollama 0.34.3; record the opencode version (the trial ran 1.18.33;
  1.18.34 is installed as of 2026-10-03).
- Build the companion (no change to `startup.ps1` unless it passes):

  ```powershell
  Set-Content "$env:TEMP\Modelfile-3b-cpu" "FROM qwen2.5-coder:3b`nPARAMETER num_ctx 16384`nPARAMETER num_gpu 0" -Encoding ascii
  ollama create qwen2.5-coder-3b-cpu -f "$env:TEMP\Modelfile-3b-cpu"
  ```

  It is registered in `opencode/global/opencode.jsonc` (`ollama-desktop`
  block); stage it with `.\desktop\scripts\sync-opencode.ps1 -Template` and
  confirm with `opencode debug config`.
- Launch from a fresh PowerShell (User-level defaults supply the base URL
  and `OPENCODE_DISABLE_CLAUDE_CODE_SKILLS`; no profile is changed):

  ```powershell
  $env:OPENCODE_MODEL = "ollama-desktop/qwen3.6:35b-a3b-coding"
  $env:OPENCODE_SMALL_MODEL = "ollama-desktop/qwen2.5-coder-3b-cpu"
  opencode
  ```

### Run

Three fresh OpenCode sessions, each started while `qwen3.6` is already
loaded (the worst case: warm it with one message first), each a real prompt
of at least five turns, with no idle gap of 5 minutes or more (within or
between sessions) so keep-alive never unloads anything. What the sessions work on does not
matter; read-mostly work or a scratch branch is fine.

### Pass bar

PASS only if all five hold:

1. Zero `evicting` lines in `server.log` across the three sessions.
2. `qwen3.6` loads exactly once (its warm-up load).
3. After each session's title, `curl.exe -s http://localhost:11434/api/ps`
   shows `qwen3.6`'s `size_vram` unchanged from before the session and
   `qwen2.5-coder-3b-cpu` at `size_vram` 0.
4. All three sessions get a non-empty, on-topic title.
5. Each title request takes 30 s or less (its `POST` line in `server.log`).

Record, not graded: each session's first-turn duration (the `POST` after
the title). If the CPU companion slows `qwen3.6`, it shows here.

PASS → the profile change ships: `dev-workflow-quality` seats `qwen3.6`
with the CPU companion, `startup.ps1` bakes the companion, and
`test-profiles.ps1`'s intent manifest moves with it. FAIL on any criterion
→ option C.

### Result

Not run yet.

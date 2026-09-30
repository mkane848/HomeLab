# Main-seat trial protocol (re-seat decision support)

Goal: decide whether `OPENCODE_MODEL` moves off `qwen3:14b`. The benchmark
measures guided repair; the main seat's job is loose prompts. This trial
measures that job directly, with the failure modes the corpus already named
as explicit watch items. Four tasks, three seats, one verdict rule. Written
2026-09-30; adjust the tasks, not the rule, if reality intervenes.

## Preconditions (do these first — one is a veto)

1. **Co-residency VRAM check.** Load the candidate plus the profile's small
   model together, read `/api/ps`. If they don't fit in ~14.8 GB usable, the
   trial is moot until the small seat is re-picked — every session would open
   with an eviction, the exact failure that unseated the old companion.
2. **Versions pinned and recorded.** `opencode --version`, desktop Ollama
   `/api/version`, each seat's served `num_ctx`. No upgrades mid-trial
   (`autoupdate` is `"notify"` since #67 — still verify before each session).
3. **Scratch branches only.** One `trial/<seat>-<task#>` branch per session in
   the task repo, off a green-suite tip (verify before starting). Never `main`,
   never the live checkout. Delete after grading.
4. **No config changes mid-trial.** If `opencode.jsonc` or a profile moves,
   the sessions after the move are a different config — note it or restart.

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
3. **Deliberately vague (owner's choice of repo).** "Make the listing flow
   safer." Nothing else. Time-box 20 minutes. This task grades *interaction*,
   not code: the correct move may be one bounded clarifying question, an
   explicit stated assumption, or a stop-and-report — not an edit.
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
least as many CLEANs as the control**. Otherwise the incumbent stays and the
notes say what would change the answer. Standings-style tallies are
forbidden here — N=4 tasks is a trial, not a benchmark.

## Session log (one row per session)

Date, seat, task, opencode version, Ollama version, `numCtx`, verdict,
friction notes, and the session ID from session start (so the transcript can
be revisited). Twelve rows fills the table: 4 tasks × 3 seats.

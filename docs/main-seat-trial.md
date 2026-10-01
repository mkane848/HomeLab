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
git-ignored (`session-<id>.md` at repo root). Control cells (qwen3:14b
tasks 2–4, qwen3.5 tasks 2–4) and the second experiment are still open;
VOID rows don't count toward the twelve.

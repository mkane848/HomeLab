# The validation rig

Built on 2026-10-03 for item 5 of the audit (adding 18 mined tasks to the suite, PR [#76]), and kept here on 2026-10-27. It is a record of how the 18 manifest entries were checked, not a maintained tool: it was written for the cloud container (Linux, PowerShell 7) and keeps that container's paths. See the [folder README](../README.md#provenance-and-caveats) before reusing any of it.

## What it is

The rig runs the real `tests/test-tasks.ps1` against local clones of the three upstream repos, in fresh worktrees at each task's pinned base, with a stand-in for `opencode` that "makes the model's change" by applying a known patch. It tests the harness and the manifest entry, not a model. For each task it checks that a correct fix passes every gate, that the fix without a test fails `failsOnOld`, that tests without the fix fail the scope and suite gates, and that the result does not depend on the environment.

## Modes

| Mode | What the stand-in applies | Expected |
|---|---|---|
| `dry` | nothing (`-DryRun`) | install and `setup` work; the baseline equals `baselineExpect`; the acceptance tests fail on the untouched base |
| `ref` | the upstream fix's source and tests, restricted to `allowFiles` | every gate PASS; acceptance PASS |
| `srconly` | the source fix only | `failsOnOld` FAIL (nothing guards the fix); the suite also FAILs for the three spec reversals, `kane-09`, `asohav-03` and `asohav-07`, where an existing test encodes the old rule |
| `testsonly` | the tests only | scope FAIL and suite FAIL |
| `blind` | a blind solver's whole change | prepared, never run |

Environment variants, all in `ref` mode: ambient; `MANAPOOL_API_KEY` and `DATABASE_URL` unset; both set to dummy values; `TZ=Pacific/Auckland`; and three repeats (`det1` to `det3`). The gate results had to be identical across them.

## What is in this folder

| Path | What |
|---|---|
| `tools/` | The rig itself: `make_rig.py` (builds a rig around a copy of the harness and an entries file), `standin.ps1` (the stand-in `opencode`), `run.sh.tmpl` (the per-task runner), `mkpatch.sh` (cuts a fix commit into source and test patches), `manifest_splice.py` (validates entries and splices them into `manifest.json` in its hand-made format), `summarize.py`, `blind_setup.sh` and `blind_collect.sh` (the blind-solver helpers), and the original [tools/README.md](tools/README.md) |
| `reference-patches/` | The final source and test patch for each of the 18 tasks (36 files), then `earlier/<group>/` for any earlier version that differs and `extra/` for a probe test. Cut from the upstream fix commits, hand-scoped for `asohav-05` and `asohav-06` |
| `lanes/` | The battery drivers (`battery-1-lane.sh`, `battery-2-lane.sh`), `matrix.py` (expected outcomes per task), `ab.py` (battery 1 against battery 2), `mutrun.sh` (runs an agent's `mutate.py` over a mutation list in a fresh worktree) and the lane logs |
| `battery-1/`, `battery-2/` | The runs: `matrix.txt` or `ab.txt` (the comparison), `runs.tsv` (one row per run) and `logs.txt` (every log, concatenated) |
| `drafts/<group>/` | Each agent's draft prompts, `source` strings, acceptance notes and entry builders |
| `agent-notes/` | The agents' progress files, batch scripts and alternative-fix explorations |
| `mutation-checks/` | Mutating each reference fix and running the upstream tests, to see which parts the tests do not pin |
| `hazard-evidence/` | The runs that the shared git stash contaminated, kept as found |

## The two batteries

Both ran on 2026-10-03.

- **Battery 1** (09:31 to 09:48 UTC), against the harness as it stood then, which reverted the source with `git stash push` and `pop`. One lane per repository clone, three lanes at once: 18 tasks × (`dry`, `ref`, `srconly`, `testsonly`, three environment variants and three repeats), so 180 runs. [`battery-1/matrix.txt`](battery-1/matrix.txt) is the result: every task matches the expectations above, with no task needing attention. The Auckland-variant rows in `runs.tsv` carry Auckland local timestamps.
- **Battery 2** (09:49 to 09:54 UTC), against the harness of PR [#76], which reverts without the stash. Six lanes at once, two per repository clone, which is the case the stash made unsafe: 18 tasks × (`ref`, `srconly`, `testsonly`, a repeat of `ref`), so 72 runs. [`battery-2/ab.txt`](battery-2/ab.txt) compares them with battery 1: 72 runs compared, no difference, and an empty stash list in every clone afterwards. The 15 `WARN` lines it prints are the informational acceptance FAILs of the tests-only runs, which is the expected result there, not a stash warning.

## What it found along the way

- **The shared stash.** `refs/stash` belongs to the repository, not to a worktree, so two tasks of one repo graded at the same time popped each other's stashes. Three agents hit it independently (see `agent-notes/a1-progress.md`, `a2-notes.md` and `k1-progress.md`; the contaminated runs are in `hazard-evidence/`). PR [#76] replaced the `git stash` revert with one that saves the model's bytes, checks the source files out of the pinned base and writes the bytes back.
- **The CRLF hazard of `asohav-09`.** The upstream test looks for a Markdown heading with LF line endings in a 2 MB file and the repo has no `.gitattributes`, so a CRLF checkout, which git for Windows produces by default, would fail it for every model. The task has no acceptance block for that reason (`agent-notes/a1-progress.md`).
- **Environment sensitivity.** `DATABASE_URL` matters to the ASoHaV server tasks (pinned on `asohav-05`, `asohav-07` and `asohav-08`); the three lfc-bot tasks do not need `lfc-02`'s `MANAPOOL_API_KEY` pin.
- **What the upstream tests do not pin** (`mutation-checks/`; summarised in the roadmap under "What the gates cannot check").

## What it could not see

The rig never builds a request for a model, so it said nothing about the instruction file OpenCode loads into every request. At the pins of `asohav-05` and `asohav-06` that file was about 280 KB and the tasks were retired the day they were first run. The folder README has the whole account under [What the validation rig could and could not catch](../README.md#what-the-validation-rig-could-and-could-not-catch).

## The five groups

Five agents built and checked the entries in parallel on 2026-10-03; the usage limit stopped all of them after 16 minutes, and the session finished from what they had left on disk. It reviewed all 18 prompts against the upstream diffs and wrote the `source` strings that were not finished, so the drafts here are not identical to the entries that shipped in `tests/tasks/manifest.json`.

| Group | Tasks |
|---|---|
| `k1` | `kane-07`, `kane-08`, `kane-09` |
| `k2` | `kane-10` to `kane-14` |
| `l` | `lfc-04`, `lfc-05`, `lfc-07` |
| `a1` | `asohav-03`, `asohav-04`, `asohav-06`, `asohav-09` |
| `a2` | `asohav-05`, `asohav-07`, `asohav-08` |

## Reusing it

1. Rebuild from the current harness. `make_rig.py` copies `tests/test-tasks.ps1` from the repo at build time, and the harness has changed since 2026-10-03. The stand-in emits the smallest event stream the transcript reader needed then (`step_start`, `tool_use` with `edit` or `write`, `step_finish`); if the reader changed, the stand-in must too.
2. Fix the paths. `make_rig.py` maps the owner's repo paths (`C:/Projects/KaneEnabler`, `M:/Projects/LFCbot`, `M:/TTRPG/A Story of Heroes and Villains`) to local clones, and hard-codes `/home/user/HomeLab`.
3. Run each repository's tasks one lane at a time unless the harness in use reverts without the stash.
4. Add a check that the original rig lacked: measure the instruction file (`AGENTS.md` or `CLAUDE.md`) at each pin.

Commands, from [tools/README.md](tools/README.md) (`$RIG` is the tools' parent, `$G` a group's working directory):

```bash
# once per agent: your own clones (cheap, hardlinked)
mkdir -p $G/repos && for r in KaneEnabler lfc-bot ASoHaVCompanionApp; do git clone --local -q $RIG/repos/$r $G/repos/$r; done
# every time the entries file changes:
python3 $RIG/tools/make_rig.py --out $G/rig --fragment $G/entries.<group>.json --repos $G/repos
# reference patches for a task whose fix commit can be used as is:
$RIG/tools/mkpatch.sh $G/repos/<Repo> <parent> <fix> $G/rig/ref <taskId> "<src files>" "<test files>"
# runs
cd $G/rig
./run.sh <taskId> ref dry        # worktree, install, baseline; acceptance must FAIL on the untouched base
./run.sh <taskId> ref            # stand-in applies source and test patches
./run.sh <taskId> srconly        # source fix only
./run.sh <taskId> testsonly      # tests only
python3 $RIG/tools/summarize.py . [taskId...]
# environment variants
RIG_UNSET="MANAPOOL_API_KEY DATABASE_URL" RIG_TAG=unset ./run.sh <id> ref
RIG_ENV="DATABASE_URL=postgres://u:p@127.0.0.1:9/x MANAPOOL_API_KEY=dummy" RIG_TAG=dummy ./run.sh <id> ref
```

[#76]: https://github.com/mkane848/HomeLab/pull/76

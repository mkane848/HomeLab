# Glossary

Terms used across the docs, in the order you meet them.

| Term | Meaning |
|---|---|
| **seat** | A model assigned to a job: the *main seat* drives the OpenCode session; the *small model* writes titles. "Seating" a model means pointing a profile at it |
| **profile** | A sourced shell file in `profiles/` exporting the env vars that choose seats and hosts ([profiles.md](profiles.md)) |
| **bake** | Writing `PARAMETER num_ctx N` into a model's Modelfile so each model has its own context size |
| **probe** | `tests/test-toolcalls.ps1`: one request with one tool schema; PASS means a real `tool_calls` entry came back. Necessary, not sufficient ([tool-calling.md](tool-calling.md)) |
| **tool-capable** | Passes the probe. A model that is not will describe edits it never made |
| **liar mode** | A run that exits 0, writes nothing, and answers in prose claiming it did. Distinct from an output-cap hit and from infrastructure failure |
| **infrastructure** | A non-zero exit (unreachable provider, bad model id, crash). Produces a FAIL and no summary row, because nothing was measured |
| **gate** | One mechanical check on a run: writes, scope, suite, `failsOnOld`, typecheck |
| **`failsOnOld`** | Revert the source, keep the model's test: the suite must FAIL, proving the test exercises the fix |
| **hidden tests** | Acceptance tests held outside the checkout while the model runs and used only to grade |
| **shown / read-only** | Modes where the acceptance tests are given to the model (`-ShowAcceptance`, `-ReadOnlyAcceptance`); kept in marked result folders apart from hidden-test rows |
| **assisted** | A run with a nudge (`-NudgeAfterCompaction`, `-NudgeOnStop`) or other help; kept in `ASSISTED`-marked folders, never mixed with unassisted rows |
| **era** | A span in which the client, engine, plugins, prompt or checkout were unchanged. Rows from different eras are not comparable; the run JSON records what defines one |
| **pass@k / pass^k** | At least one of k runs passes / all k pass (unbiased estimators over the runs held). Unattended work needs pass^k |
| **sealed checkout** | A task checkout rebuilt as a fresh repo holding only the pinned base and its ancestry, so later commits and other branches cannot leak |
| **pin** | A task's full 40-hex `benchBaseCommit`; the base cannot move under the corpus |
| **retired task** | Kept with its id and rows, left out of default runs |
| **guard** | A `tests/test-*.ps1` regression test for a piece of the harness ([guard catalog](reference/guards.md)) |
| **spill** | Part of a model running from system RAM because it does not fit VRAM. Tolerable for MoE models, a cliff for dense ones |
| **MoE** | Mixture of experts: only a few billion parameters active per token (`qwen3.6:35b-a3b` ≈ 3B active) |
| **G1 / Phase 2** | Gate and phase names from the llama.cpp engine trial ([llamacpp-trial.md](llamacpp-trial.md)) |
| **placeholders** | `SERVER_IP`, `DESKTOP_IP`, `NODE3_IP`, `SSH_USER` stand for values in the git-ignored `.env` |

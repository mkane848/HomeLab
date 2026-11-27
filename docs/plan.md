# Plan

The live plan for the fleet, as of 2026-11-25. **Keep it short:** one line per item, and a link to where the detail is.
When an item is done, delete it here and record it in [roadmap.md](roadmap.md) (the dated log, with the stable anchors
other docs cite) and in `CHANGELOG.md`. Created 2026-11-25 by splitting the roadmap: the audit's "The roadmap's
shape" item ([audit-2026-11-09.md](audit-2026-11-09.md)).

**Order of work** (owner, 2026-11-11): the audit's small fixes (done), then the pilot on real work on today's setup,
then containerised runs, which start a new era.

## In flight

| Item | State | Waits on | Detail |
|---|---|---|---|
| Ollama uninstall | Repo side done. The desktop was uninstalled by the owner (2026-11-24) | **Owner:** the dry runs and deletes on the server and node3, then redeploy the server and pull on node3 | [roadmap → Ollama removed](roadmap.md#ollama-removed-2026-11-21) |
| OpenCode 2 rollout | The cutover (#265) merged 2026-11-26; node3 on 2.3.2 (owner, 2026-11-26) | **Owner:** on the desktop and node3, pull `main` and re-run `desktop\scripts\sync-opencode.ps1` (it stages the 2.x `read-budget` plugin), then `tests\test-profiles.ps1 -Reliability`. **Agent, after:** step 5.1 (the template in native 2.x keys) and 5.4 (the era marker) | [opencode-2-migration.md](opencode-2-migration.md) → "Steps" |
| 13 mined tasks | In the manifest, with no graded rows yet | **Owner:** `run-tasks-batch.ps1 -SetupOnly`, then `test-tasks.ps1 -Task <id> -DryRun` per new task on Windows. Report them as their own cohort | [roadmap → Task set expansion III](roadmap.md#task-set-expansion-iii-13-tasks-from-lfc-bot-and-asohav-2026-11-23), [task-mining-2026-11-23/](task-mining-2026-11-23/README.md) |

## Next, in order

1. **The pilot on real work** (owner). 3 to 5 tasks in the owner's own words, delivered as branches, each with the
   owner's verdict. One of them is "Close the KaneEnabler validator holes". It is what can show the Gate's
   false-positive rate is under 10%. The tools are `tests/new-real-task.ps1`, `tests/deliver-attempt.ps1` and
   `tests/record-verdict.ps1`. Detail: [roadmap → Next up (2026-11-07)](roadmap.md#next-up-2026-11-07), item 3.
2. **Containerised runs** (agent, after the pilot and the owner's go). The design is written:
   [container-runs.md](container-runs.md). Step 0 is the owner's (Docker Desktop on node3). Build step 1 needs a
   desktop session.
3. **A planner-free run with the owner's edit of a local done list** (owner and agent).
   [planner-tests-experiment.md](planner-tests-experiment.md) → "Not tested yet".
4. **Check each planner set before use** (agent): it must load, the runner must find it, and it must fail on the base.
   **Built 2026-11-27, in review; not yet run live.** Next: a planner round with `run-planner-local.ps1 -CheckManifest`
   (owner, on the desktop). [planner-tests-experiment.md](planner-tests-experiment.md) → "Checking a set before use";
   [roadmap → Next up (2026-11-07)](roadmap.md#next-up-2026-11-07), item 2.

## The owner's steps, not yet done

From the 2026-11-09 audit ([roadmap → Open after the 2026-11-09 audit](roadmap.md#open-after-the-2026-11-09-audit-as-of-2026-11-16)):
1. Apply the model-ports firewall rule on the server: [network-topology.md](network-topology.md) → "Limit the model
   ports to named hosts".
2. Keep a copy of `WEBUI_SECRET_KEY` off the server.
3. Pull `main` on the server, so the nightly backup includes the chat. Check that the next `backup.log` has two lines.
4. Run `tests\run-window.ps1 -Plan` on the desktop once, to see what the "GPU to itself" gate reads.
5. Run `summarize-rounds.ps1` on a recent private round, with and without `-ExcludeTimeouts`.
6. Remove the deleted Vercel and Render agents and commands from the desktop's and node3's live OpenCode config
   (#268; the sync scripts never delete a live file): the snippet in `opencode/README.md`.
7. Roll out the engine API keys, together with the server redeploy: [engine-api-keys.md](engine-api-keys.md) →
   "Rollout".

## Open for an agent

From [audit-2026-11-09.md](audit-2026-11-09.md) → "Open: work for an agent":
- **IPv6 on the model ports.** The firewall rule is IPv4 only.

## Parked (the owner's call)

- Server hardware, deferred until testing is done: [hardware.md](hardware.md).
- The Qwen Code probes, the ratings of `large-f1` and `large-f2`, and the choice of a larger Stage 2 project.
- One priced OpenCode Go call, to learn why 2.x records $0 for Go replies. Hosted seats wait on it
  ([opencode-2-migration.md](opencode-2-migration.md), step 3.5).
- KaneEnabler as a source of benchmark tasks, after its 2026-11-23 state-machine fixes land.

## Outside the plan

- The household assistant ([household-assistant.md](household-assistant.md)), phases 1 and 2 running on the server
  since 2026-11-08. Its chat shares the server's GPU with the coding seat, so it stays off during a test window.

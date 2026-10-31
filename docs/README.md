# Docs

One homelab: a server and two PCs running local LLMs, driven from OpenCode (daily client) or VS Code. New here? Start with [start-here.md](start-here.md). Unfamiliar word? [glossary.md](glossary.md).

## Use it

| Doc | What it gives you |
|---|---|
| [start-here.md](start-here.md) | Cold machine to working agent, a check at each step |
| [profiles.md](profiles.md) | Which profile turns on which machines and models |
| [tool-calling.md](tool-calling.md) | Which models can edit files; the `/plan` workflow |
| [troubleshooting.md](troubleshooting.md) | Symptom → cause → fix |
| [hardware.md](hardware.md) | Machines, measured VRAM and throughput |
| [network-topology.md](network-topology.md) | LAN layout, ports, firewall, SSH |
| [costs.md](costs.md) | Hosted-seat prices against plan limits |
| [vscode.md](vscode.md) | The same fleet from VS Code |
| [model-architecture.md](model-architecture.md) | Which models run where (partly stale; see its banner) |
| [target-setup.md](target-setup.md) | The planned end state: roles and milestones |
| [server-recovery-cpu-led.md](server-recovery-cpu-led.md) | Live log of a BIOS-flash recovery |
| [unattended-window.md](unattended-window.md) | A testing window with no one there: the server's script, node3's runner, the morning report |
| [CONTRIBUTING.md](../CONTRIBUTING.md), [owner-setup.md](owner-setup.md) | How to contribute; owner-only repo settings |

## History and evidence (internal)

| Doc | What it holds |
|---|---|
| [roadmap.md](roadmap.md) | Ordered backlog and the long result log |
| [llamacpp-trial.md](llamacpp-trial.md) | llama.cpp engine trial: runbook and results |
| [main-seat-trial.md](main-seat-trial.md) | The plain-language trial that chose the main seat |
| [adversarial-review-2026-09-29.md](adversarial-review-2026-09-29.md), [adversarial-review-2026-10-23.md](adversarial-review-2026-10-23.md) | What each harness measures, what to stop claiming (the second was written by a Claude subagent) |
| [audit-2026-09-29/](audit-2026-09-29/README.md) | Working material of the 2026-09-29 benchmark audit: the independent review, mining notes, validation rig and its runs, and the conversation |
| [methodology-research.md](methodology-research.md) | Methodology and community resources (2026-09-24; superseded in places by the reviews above) |
| [planner-tests-experiment.md](planner-tests-experiment.md) | Experiment 3 design. Not yet run |
| [review-gate/README.md](review-gate/README.md) | Can a local LLM gate code review? Answer 2026-09-19: no (n=18, with a floor effect) |
| [implementation-tasks.md](implementation-tasks.md) | Live file written by `/plan`; the latest planning pass |
| [fleet-side-projects.md](fleet-side-projects.md), [hardware-planning.md](hardware-planning.md) | Planning lists; nothing scheduled |
| [archive/](archive/) | Dated narrative moved out of the pages above |
| [agent-notes/](agent-notes/) | Prompts and scratch notes from AI coding agents |
| [references.md](references.md) | Every external source cited, and the citation convention |
| [../tests/results/README.md](../tests/results/README.md) | How to read the results directory |

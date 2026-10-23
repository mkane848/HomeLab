# Docs

Everything here documents one homelab: a server and a desktop running local
LLMs, driven from OpenCode (the daily client) or VS Code. Grouped by theme.
If you are new, start with [start-here.md](start-here.md).

## Getting started

- **[start-here.md](start-here.md)**: from a cold machine to a working agent in OpenCode, with a check at each step.
- **[vscode.md](vscode.md)**: the same fleet, driven from VS Code. Its first half is setup. The second half is the review-gate research.
- **[profiles.md](profiles.md)**: which profile turns on which machines and models, and why.
- **[target-setup.md](target-setup.md)**: the planned end state. Machine roles and ordered milestones.

## Hardware and network

- **[hardware.md](hardware.md)**: the hardware, and measured VRAM and throughput per model.
- **[network-topology.md](network-topology.md)**: LAN layout, ports, and firewall rules.
- **[model-architecture.md](model-architecture.md)**: which models run where, and why.
- **[fleet-side-projects.md](fleet-side-projects.md)**: what else the hardware can do (video, VFX, 3D, home-lab services), per machine. A planning list; nothing is scheduled.

## Engine trial and benchmarks

- **[llamacpp-trial.md](llamacpp-trial.md)**: the llama.cpp engine trial for the server's main seat. Runbook and results.
- **[main-seat-trial.md](main-seat-trial.md)**: the plain-language trial that chose the main seat.
- **[costs.md](costs.md)**: what the hosted OpenCode Go seats cost against the plan limits.

## Troubleshooting and recovery

- **[troubleshooting.md](troubleshooting.md)**: known gotchas. Context truncation, tool-calling quirks, PowerShell and bash pitfalls.
- **[server-recovery-cpu-led.md](server-recovery-cpu-led.md)**: a live log of a BIOS-flash recovery, written while it happened.

## Research: the review-gate experiment

Can a local LLM reliably act as a code-review gate? **[review-gate/README.md](review-gate/README.md)**
is the index: method, case studies, and the raw run data.

Answer, 2026-09-19: no. The bottleneck is verification reasoning, not prompt
shape. The deterministic checker built alongside it does discriminate, and it
works as a regression gate for the one plan it was written for. Results:
[r3-results.md](review-gate/raw/r3-results.md) and
[r3-robot-results.md](review-gate/raw/r3-robot-results.md).

## Roadmap

- **[roadmap.md](roadmap.md)**: the ordered backlog. What has landed, what is next, and open fleet decisions.

## Research and references

- **[methodology-research.md](methodology-research.md)**: where the testing methodology stands, and the community resources it maps to.
- **[adversarial-review-2026-09-29.md](adversarial-review-2026-09-29.md)**: what each harness measures, where single runs and era changes mislead, and the protocol for N > 1.
- **[adversarial-review-2026-10-23.md](adversarial-review-2026-10-23.md)**: milestone 3's results attacked before milestone 4 is built on them: what holds, what to stop claiming, and the experiments that come first.
- **[references.md](references.md)**: every external source cited in these docs, and the citation convention.

## Other

- **[implementation-tasks.md](implementation-tasks.md)**: a live file. `/plan` writes it and the main seat executes from it. It shows the latest planning pass, not a fixed reference.
- **[agent-notes/](agent-notes/)**: the prompts and scratch notes used with an AI coding agent. Included for transparency. Not required reading.

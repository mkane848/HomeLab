# Docs

Everything here documents one homelab: a hybrid Ubuntu-server / Windows-desktop
fleet running local LLMs, driven from either OpenCode or VS Code — both are in
active use. Grouped by theme — start with whichever section matches what
you're after.

## Getting started

- **[start-here.md](start-here.md)** — the one page that takes you from a
  cold machine to a working agent via OpenCode, with verification at each step.
- **[lmstudio-vscode.md](lmstudio-vscode.md)** — the same fleet, driven from
  VS Code instead: BYOK setup for LM Studio and Ollama side by side. Its
  first half is the setup reference; the second half is the review-gate
  research built on top of it (see below).
- **[profiles.md](profiles.md)** — how model-tier selection works: which
  profile turns which machines/models on, and why.

## Hardware & network

- **[hardware.md](hardware.md)** — the fleet's hardware, and measured
  VRAM/throughput numbers per model (not catalog-disk-size guesses).
- **[network-topology.md](network-topology.md)** — LAN layout, ports, and the
  firewall rules each machine needs.
- **[model-architecture.md](model-architecture.md)** — which models live
  where, and why a given model is on a given host.

## War stories & troubleshooting

- **[server-recovery-cpu-led.md](server-recovery-cpu-led.md)** — a live BIOS-flash
  recovery log (solid CPU EZ Debug LED, board won't POST), written as the
  debugging happened.
- **[troubleshooting.md](troubleshooting.md)** — the accumulated gotchas:
  context-window truncation, tool-calling quirks, PowerShell/bash pitfalls,
  and more.

## Research: the review-gate experiment

Can a local LLM reliably act as a code-review gate? **[review-gate/README.md](review-gate/README.md)**
is the index for this thread — method, case studies, and the raw run data
behind them.

## Roadmap

- **[roadmap.md](roadmap.md)** — ordered backlog: what's landed, what's next,
  and open fleet decisions.

## Other

- **[implementation-tasks.md](implementation-tasks.md)** — not a doc to read
  so much as a live artifact: the task list OpenCode's `/plan` command writes
  and executes against. Whatever's in it reflects the most recent planning
  pass, not a fixed reference.
- **[agent-notes/](agent-notes/)** — literal prompts/scratch docs used to run
  this fleet with an AI coding agent. Included for transparency, not required
  reading.

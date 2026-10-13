# Agent notes

This folder holds literal artifacts of running this homelab *with* an AI
coding agent, not documentation written *for* a reader. Kept for
transparency about how the fleet actually gets operated day to day — not
required reading if you're here for the homelab itself.

- **[prompt-handoff-recovery.md](prompt-handoff-recovery.md)** — an actual
  handoff prompt: verbatim text meant to be pasted into a fresh agent session
  to resume the hardware-recovery incident documented in
  [docs/server-recovery-cpu-led.md](../server-recovery-cpu-led.md) without
  losing context between sessions.
- **[prompt-llamacpp-window.md](prompt-llamacpp-window.md)**: the handoff prompt for running the llama.cpp
  trial's GPU window ([llamacpp-trial.md](../llamacpp-trial.md), Phase 1) from a Claude Code session on the
  desktop, which can reach the server over SSH. It adds operating rules (stop points, `sudo` left to the owner,
  settings held constant) on top of the runbook, which stays the authority. Written 2026-10-13.

(`docs/implementation-tasks.md`, the task list the `/plan` command writes and
reads, stays at the top level of `docs/` — it's a live, regenerated artifact
the tooling depends on, not a historical note.)

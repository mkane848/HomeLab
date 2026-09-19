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

(`docs/implementation-tasks.md`, the task list the `/plan` command writes and
reads, stays at the top level of `docs/` — it's a live, regenerated artifact
the tooling depends on, not a historical note.)

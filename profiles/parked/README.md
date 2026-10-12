# Parked profiles

These profiles are **correct and working**. They are parked because they target
a host that does not currently exist:

- the **server** (`SERVER_IP`) as it was before 2026-10-12. The host is back on a replacement board
  ([`docs/server-recovery-cpu-led.md`](../../docs/server-recovery-cpu-led.md)) and runs Ollama 0.34.3, but only
  `qwen3:8b` and `qwen3.6` are probed or seated there. These profiles still name the old `qwen2.5-coder` /
  `deepseek-r1` seats, so they stay parked until each is rewritten and re-checked.

(`dev-node3.sh` used to be parked here for the same reason — the third node
had never been provisioned. It was onboarded 2026-09-20 and the profile is
live in `profiles/` again. `dev-workflow-server.sh` followed on 2026-10-12, rewritten for `qwen3.6` on the server.)

Nothing here is deprecated. Parked 2026-09-17; seven profiles remain.

## Why park instead of leaving them live

`tests/test-profiles.ps1` scanned all twelve and emitted **38 WARNs**, every one
of them "server unreachable." Warnings you learn to scroll past are how
the original config bug survived for weeks — the harness reported 141 PASS
against a setup that could not serve a single request. A profile menu offering
nine options on a one-host fleet has the same problem in a different shape.
(For reference: with node3 live the harness reports 100 PASS, 0 FAIL, 1 WARN,
2 SKIP across the four live profiles — measured 2026-09-20.)

The harness globs `profiles/*.sh` non-recursively, so parking a profile removes
it from the run automatically. No test changes were needed.

## What's parked and what it needs

| Profile | Needs |
|---|---|
| `dev-quick` | server |
| `dev-coder` | server |
| `dev-server-all` | server |
| `dev-embeddings` | server |
| `dev-go-only` | server + OpenCode Go subscription |
| `dev-full` | server + desktop + Go |
| `dev-local-only` | server (desktop main seat, but `ollama-server` small model) |

## Bringing one back

```bash
git mv profiles/parked/dev-workflow-server.sh profiles/
```

Then confirm it before trusting it:

```powershell
.\tests\test-profiles.ps1 -Profile dev-workflow-server
```

The harness picks it up again with no other change, and
`profiles/select-model.sh` discovers profiles dynamically so it reappears in the
menu on its own.

**Probe the models before seating one.** Every main seat here is `qwen3:8b`,
which passes on the desktop — but the server's copies have never been probed,
because the server has been down since before that test existed:

```powershell
.\tests\test-toolcalls.ps1 -Model qwen3:8b -OllamaHost http://SERVER_IP:11434
```

A model that fails that probe cannot edit files and will claim it did. See
[`docs/troubleshooting.md`](../../docs/troubleshooting.md) → "Agent 'says' it
edited a file".

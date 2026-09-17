# Parked profiles

These profiles are **correct and working**. They are parked because they target
hosts that do not currently exist:

- the **server** (`SERVER_IP`) will not POST — see
  [`docs/server-recovery-cpu-led.md`](../../docs/server-recovery-cpu-led.md)
- the **third node** has never been provisioned (`NODE3_IP` is still a commented
  placeholder in `.env`)

Nothing here is deprecated. Parked 2026-09-17.

## Why park instead of leaving them live

`tests/test-profiles.ps1` scanned all twelve and emitted **38 WARNs**, every one
of them "the server is unreachable." Warnings you learn to scroll past are how
the original config bug survived for weeks — the harness reported 141 PASS
against a setup that could not serve a single request. A profile menu offering
nine options on a one-host fleet has the same problem in a different shape.

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
| `dev-workflow-server` | server |
| `dev-node3` | `NODE3_IP` set in `.env` |

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

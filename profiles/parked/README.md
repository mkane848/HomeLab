# Parked profiles

A parked profile is correct but not in daily use. The harness globs
`profiles/*.sh` non-recursively, so a profile here is left out of
`tests/test-profiles.ps1` and the profile menu automatically.

| Profile | Needs |
|---|---|
| `dev-go-only` | an OpenCode Go subscription (hosted models only; no local seat) |

The six Ollama-era profiles that were parked here (`dev-quick`, `dev-coder`,
`dev-server-all`, `dev-embeddings`, `dev-full`, `dev-local-only`) were deleted on
2026-11-21 with Ollama: they named Ollama-only tags (`qwen2.5-coder:7b`,
`deepseek-r1`, ...) that no llama-server serves. They are in git history.

## Bringing one back

```bash
git mv profiles/parked/<name>.sh profiles/
```

Then confirm it before trusting it:

```powershell
.\tests\test-profiles.ps1 -Profile <name>
```

**Probe a seat before trusting it:**

```powershell
.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model <tag>
```

A model that fails that probe cannot edit files and will claim it did. See
[`docs/troubleshooting.md`](../../docs/troubleshooting.md) → "Agent 'says' it
edited a file".

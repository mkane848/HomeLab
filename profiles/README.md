# Model Selection Profiles

A profile is a sourced bash script that exports tier toggles, model intent and
OpenCode defaults. Full reference: [docs/profiles.md](../docs/profiles.md).

Every local seat is a llama-server seat: Ollama was removed on 2026-11-21, and the
desktop runs no models (it is the OpenCode client and the harness run host).

## Quick start

```bash
source profiles/dev-workflow-server-llamacpp.sh     # load one profile into this shell
eval "$(bash profiles/select-model.sh --print)"     # or pick from a menu, then load it
```

`select-model.sh` runs in a child process, so on its own it can only print the
`source ...` line to run; `--print` makes that line `eval`-able. On Windows,
`opencode <profile>` (see `desktop/scripts/opencode-profiles.ps1`) loads a
profile for you, e.g. `opencode server-llamacpp`.

## Live profiles (2)

| Profile | Main seat | Host | Use when |
|---|---|---|---|
| `dev-workflow-server-llamacpp.sh` | qwen3.6 on llama.cpp | server | **Default** |
| `dev-node3.sh` | qwen3:8b on llama.cpp | node3 | The third node (3080 FE); falls back to the server's qwen3:8b |

## Parked profiles (1)

`dev-go-only.sh` (OpenCode Go only) is parked in [`parked/`](parked/README.md);
bring-back procedure there.

## What a profile exports

| Variable | Read by |
|---|---|
| `DEV_TIERS_SERVER/DESKTOP/GO/NODE3` | the profile menu and the launcher's report |
| `OPENCODE_MODEL`, `OPENCODE_SMALL_MODEL` | OpenCode config via `{env:...}` |
| `LLAMACPP_SERVER_BASE_URL`, `LLAMACPP_NODE3_BASE_URL`, `LLAMACPP_SERVER_SSH` | one provider per host; `{env:...}` has no fallback, so every live profile sets them |

`SERVER_IP`, `NODE3_IP` and `SSH_USER` come from `<repo>/.env` (copy
`.env.example`); each profile loads it itself.

## Custom profiles

```bash
cp profiles/dev-workflow-server-llamacpp.sh profiles/dev-experiment.sh
# edit DEV_TIERS_* and OPENCODE_*; add its intent to tests/test-profiles.ps1
```

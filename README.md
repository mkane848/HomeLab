# HomeLab

A documented homelab that uses a few home machines as one local LLM coding setup.
Models run on the Ubuntu server and the Windows desktop. OpenCode, a terminal
coding agent, runs on the desktop and uses those models.

The goal is that every machine in the house works as interchangeable compute
behind one coding-agent experience. The plan is in
[docs/target-setup.md](docs/target-setup.md). Everything here was measured on
this hardware, and the docs say when.

## Start here

- **[docs/start-here.md](docs/start-here.md)**: from a cold machine to a working agent in OpenCode, step by step.
- **[docs/README.md](docs/README.md)**: the index of every doc, grouped by theme.
- **[docs/hardware.md](docs/hardware.md)**: measured VRAM and speed per model.
- **[docs/roadmap.md](docs/roadmap.md)**: what has landed and what is next.
- **[docs/vscode.md](docs/vscode.md)**: the same fleet, driven from VS Code.

## Machines

| Machine | Hardware | Role |
|---|---|---|
| `server` | Ubuntu, RTX 4070 Ti Super 16 GB, Docker | Model host. Runs the main seat. |
| `desktop` | Windows 11, RX 6800 XT 16 GB (Vulkan), Ryzen 7 5800X3D | Model host, OpenCode client, tool-run host. |
| `node3` | Windows 11, RTX 3080 FE 10 GB, Ryzen 9 5950X | Model host, OpenCode client, benchmark run host. It is also a gaming PC, so use it only when it is free. |

Roles are in [machines.tsv](machines.tsv). Hosts are often down. Every sync
script is written to degrade gracefully.

## Quick start

On the Windows desktop:

```powershell
cd dev-docs
.\desktop\scripts\startup.ps1      # starts desktop Ollama and bakes each model's context
.\desktop\scripts\opencode.ps1     # loads the default profile and launches OpenCode
```

The default profile is `dev-workflow-server-llamacpp`: `qwen3.6:35b-a3b-coding`
on the server's llama.cpp. If the server is down or in a trial window, use
`-Profile dev-workflow-quality` (the same model on the desktop). After
`.\desktop\scripts\install-opencode-profiles.ps1` runs once, `opencode quality`
and the other profile names work from any PowerShell window. The profiles are
described in [docs/profiles.md](docs/profiles.md).

On the Ubuntu server:

```bash
source profiles/dev-workflow-server.sh
./server/scripts/startup.sh        # the Ollama container
./server/scripts/bake-models.sh    # pull and bake the seats in models/server-seats.tsv
./server/scripts/status.sh         # each loaded model's GPU share
```

The llama.cpp stack is `server/docker/docker-compose.llamacpp.yml`. Its runbook and
results are in [docs/llamacpp-trial.md](docs/llamacpp-trial.md).

## How work runs

1. The main seat, `qwen3.6:35b-a3b-coding`, plans and edits in one OpenCode session.
2. `/plan <scope>` reads the repo and writes `docs/implementation-tasks.md`.
3. In the same session, ask for `execute task #N from docs/implementation-tasks.md`.

Coding stays in the main thread. The Plan/Build toggle only sets which tools
the current model may use. It does not write the task file. See
[docs/start-here.md](docs/start-here.md).

**Not every model can call tools.** A model that cannot will describe edits it
never made. Probe any model before you seat it:

```powershell
.\tests\test-toolcalls.ps1 -Model qwen3:8b
```

13 of the 22 models probed pass. A probe pass is necessary, not sufficient. Which seat lands real edits is measured separately in
[docs/roadmap.md](docs/roadmap.md) (Executor standings).

## Repo layout

| Path | Contents |
|---|---|
| `models/` | Model catalog: `catalog.tsv` (data) and `catalog.sh` (bash library). |
| `profiles/` | Live profiles (`dev-*.sh`) that choose models and hosts. Parked ones are in `profiles/parked/`. |
| `server/` | Ubuntu server scripts, Docker compose files, llama.cpp config. |
| `desktop/` | Windows scripts: startup, OpenCode launcher, model installs, sync. |
| `opencode/` | OpenCode config template, agents, commands, plugins. |
| `tests/` | Profile checks, tool-call probe, task benchmark, and regression guards. |
| `docs/` | Documentation. Start with [docs/README.md](docs/README.md). |
| `skills/`, `claude/` | Vendored third-party skills and their provenance. Own licenses. |
| `wezterm/` | Terminal config. |

Secrets and `.env` files are git-ignored. API keys live in
`~/.config/opencode/.secrets/`, outside the repo.

## Tests

- `.\tests\test-profiles.ps1`: checks every live profile against what is configured and served.
- `.\tests\test-toolcalls.ps1 -Model <tag>`: does this model emit a tool call?
- `.\tests\run-guards.ps1`: runs every regression guard. CI runs the same set on Windows.
- `.\tests\run-tasks-batch.ps1`: the task benchmark. It needs live hosts.

## Caveats

- Measured numbers name a date, a model and an engine version. They do not carry over to other versions.
- Single runs are noisy. See [docs/adversarial-review-2026-09-29.md](docs/adversarial-review-2026-09-29.md) for what the harness does and does not measure.
- Research thread: [docs/review-gate/README.md](docs/review-gate/README.md) asks
  whether a local model can act as a code-review gate. Its answer, 2026-09-19,
  was no.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT for the scripts and documentation in this repo (see [LICENSE](LICENSE)).
Vendored skill packages under `skills/` and `claude/imports/` keep their own
licenses. See [claude/README.md](claude/README.md).

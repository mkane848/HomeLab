# HomeLab

A documented homelab that uses a few home machines as one local LLM coding setup.
Models run under llama.cpp (`llama-server`) on the Ubuntu server and on node3, a
Windows PC. OpenCode, a terminal coding agent, runs on the Windows desktop and uses
those models; the desktop itself runs no models. Ollama was removed from the fleet
on 2026-11-21.

The goal is that every machine in the house works as interchangeable compute
behind one coding-agent experience. The plan is in
[docs/target-setup.md](docs/target-setup.md). Everything here was measured on
this hardware, and the docs say when.

## Start here

- **[docs/start-here.md](docs/start-here.md)**: from a cold machine to a working agent in OpenCode, step by step.
- **[docs/README.md](docs/README.md)**: the index of every doc, grouped by theme.
- **[docs/hardware.md](docs/hardware.md)**: measured VRAM and speed per model.
- **[docs/roadmap.md](docs/roadmap.md)**: what has landed and what is next.
- **[docs/methodology.md](docs/methodology.md)**: how models are tested, and how much confidence each headline number carries.
- **[docs/vscode.md](docs/vscode.md)**: the same fleet, driven from VS Code.

## Machines

| Machine | Hardware | Role |
|---|---|---|
| `server` | Ubuntu, RTX 4070 Ti Super 16 GB, Docker | Model host (llama-server, port 8090). Runs the main seat. |
| `desktop` | Windows 11, RX 6800 XT 16 GB, Ryzen 7 5800X3D | OpenCode client, harness run host. Runs no models since 2026-11-21. |
| `node3` | Windows 11, RTX 3080 FE 10 GB, Ryzen 9 5950X | Model host (llama-server), OpenCode client, benchmark run host. It is also a gaming PC, so use it only when it is free. |

Roles are in [machines.tsv](machines.tsv). Hosts are often down. Every sync
script is written to degrade gracefully.

## Quick start

On the Windows desktop:

```powershell
cd <path-to-HomeLab-checkout>
.\desktop\scripts\opencode.ps1     # loads the default profile and launches OpenCode
```

The default profile is `dev-workflow-server-llamacpp`: `qwen3.6:35b-a3b-coding`
on the server's llama-server. The other live profile is `dev-node3` (`qwen3:8b`
on node3's llama-server). The desktop runs no models, so when the server is down
there is no local fallback on the desktop: use `dev-node3`, or the parked
hosted-only `dev-go-only`. After `.\desktop\scripts\install-opencode-profiles.ps1`
runs once, `opencode server-llamacpp` and `opencode node3` work from any
PowerShell window. The profiles are described in [docs/profiles.md](docs/profiles.md).

On the Ubuntu server, where llama.cpp is the only engine (it starts at boot):

```bash
./server/scripts/startup.sh        # the llama.cpp stack (server/docker/docker-compose.llamacpp.yml)
./server/scripts/llamacpp-check.sh --url http://localhost:8090 --weights-container llamacpp-server
                                   # the preset against models/server-seats.tsv, the live server, the weights
./server/scripts/status.sh         # the engine, its restart policy, the GPU, the seats
./server/scripts/stop.sh           # stop it
```

Adding a model: [docs/reference/config.md](docs/reference/config.md) → "Adding a model".
The llama.cpp history (the trial that replaced Ollama) is in
[docs/llamacpp-trial.md](docs/llamacpp-trial.md).

## How work runs

1. The main seat, `qwen3.6:35b-a3b-coding`, plans and edits in one OpenCode session.
2. `/plan <scope>` reads the repo and writes `docs/implementation-tasks.md`.
3. In the same session, ask for `execute task #N from docs/implementation-tasks.md`.

Coding stays in the main thread. The Plan/Build toggle only sets which tools
the current model may use. It does not write the task file. See
[docs/start-here.md](docs/start-here.md).

**Not every model can call tools.** A model that cannot will describe edits it never made. Probe any model before you seat it (`.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model qwen3:8b`). A probe pass is necessary, not sufficient. Details and results: [docs/tool-calling.md](docs/tool-calling.md).

## Repo layout

| Path | Contents |
|---|---|
| `models/` | `server-seats.tsv`: what the server's llama-server serves, each seat's context and weights sha256. |
| `profiles/` | Live profiles (`dev-*.sh`) that choose models and hosts. Parked ones are in `profiles/parked/`. |
| `server/` | Ubuntu server scripts, Docker compose files, llama.cpp config. |
| `desktop/` | Windows scripts: OpenCode launcher, profile shortcuts, config and skill sync. |
| `opencode/` | OpenCode config template, agents, commands, plugins. |
| `tests/` | Profile checks, tool-call probe, task benchmark, and regression guards. |
| `docs/` | Documentation. Start with [docs/README.md](docs/README.md). |
| `skills/`, `claude/` | Vendored third-party skills and their provenance. Own licenses. |
| `wezterm/` | Terminal config. |

Secrets and `.env` files are git-ignored. API keys live in
`~/.config/opencode/.secrets/`, outside the repo.

## Tests and caveats

| Command | Checks |
|---|---|
| `.\tests\test-profiles.ps1` | Every live profile against what is configured and served |
| `.\tests\test-toolcalls.ps1 -Engine llamacpp -EngineHost http://SERVER_IP:8090 -Model <tag>` | Does this model emit a tool call? |
| `.\tests\run-guards.ps1` | Every regression guard (CI runs the same set on Windows) |
| `.\tests\run-tasks-batch.ps1` | The task benchmark (needs live hosts) |

| Caveat | Detail |
|---|---|
| How we measure | [Methodology](docs/methodology.md): what a run is, how it is graded, the 95% intervals on today's numbers, and how many runs a question needs |
| Numbers are dated | Each names a date, a model and an engine version; they do not carry over to other versions |
| Single runs are noisy | [Adversarial review](docs/adversarial-review-2026-09-29.md): what the harness does and does not measure |
| Research thread | [Review-gate](docs/review-gate/README.md): can a local model gate code review? 2026-09-19: no |
| Words | [Glossary](docs/glossary.md) |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT for the scripts and documentation in this repo (see [LICENSE](LICENSE)).
Vendored skill packages under `skills/` and `claude/imports/` keep their own
licenses. See [claude/README.md](claude/README.md).

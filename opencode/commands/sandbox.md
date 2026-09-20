---
description: Run a disposable scratch container for quick experiments (runtimes, CLI probes, DB one-liners). Auto-tears down - nothing persists.
---

# Docker Sandbox

Spin up a throwaway container to experiment without touching the host. CPU-only
(desktop `.wslconfig` has `gpuSupport=false` - no GPU passthrough - so Ollama
stays native (Vulkan) and never runs here). Run via the regular **Bash tool with
`docker` CLI** (gives us `--rm`/`--memory`/`--cpus`, which the docker MCP tools
don't expose). The docker MCP is for managing the compose stack / inspection.

## Rules (non-negotiable)

- Always pass `--rm` - the container must self-destruct when done.
- Always pass `--memory` (default `1g`) and `--cpus` (default `2`) so a runaway
  sandbox can't starve host Ollama (32 GB RAM, ~7 GB free when loaded).
- **Never mount sensitive host paths.** Default is no mount. If the user asks
  for a workdir, mount only that explicit path at `/workspace`. Never mount
  `~/.config/opencode/.secrets`, `desktop/docker/.env`, git-ignored env files,
  or private keys.
- Bind-mounting Windows paths: use `-v "M:\\path\\to\\dir:/workspace"`.
- If a container must survive, give it a `--name` and say how to inspect/remove
  it; otherwise rely on `--rm`.

## Templates

| `$ARGUMENTS` hint | Image |
|---|---|
| _(none)_ | `dev-base:1` (node22 + python3.12 + build tools; built by `desktop/scripts/docker-base.ps1`) |
| node | `node:22` |
| python | `python:3.12` |
| postgres | `postgres:16-alpine` |
| redis | `redis:7-alpine` |
| anything else | ask the user or pull from Docker Hub via `docker pull` |

For a server image (postgres/redis), the "sandbox" is usually a companion
client container: `docker run --rm --network host redis:7-alpine redis-cli ping`
(hits the loopback stack). To spin a *throwaway DB to test on*, run the server
image with `--rm --name scratch-pg -e POSTGRES_PASSWORD=x -p 127.0.0.1:55432:5432`
and tell the user to point their client at it, then `docker rm -f scratch-pg`.

## Sequence

1. If the image isn't local (`docker image inspect <img>` fails), pull it.
2. Build the one-liner:
   ```
   docker run --rm --memory 1g --cpus 2 -v "<user-selected-host-dir>:/workspace" -w /workspace <image> <command>
   ```
3. Run it via Bash, capture output, and report the result to the user - what
   was tested and what it proved.
4. Confirm nothing was left behind: `docker ps -a` should show no new entries
   (thanks to `--rm`).

Interactive loops (a REPL across multiple execs) need a persistent container:
`docker run -d --name <scratch> ...` then `docker exec -it <scratch> <cmd>`
per step, ending with `docker rm -f <scratch>`. Prefer that over `-it` on a
one-shot run. Use `docker-sandbox.ps1 -Interactive` for single-shot interactive
shells (it appends `exec sh` so the shell persists).
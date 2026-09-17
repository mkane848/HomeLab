---
description: Enter or run tooling inside a project's devcontainer (pinned Node 22 + build toolchain). Targets LFCbot and asohav.
---

# Dev Container

Enter a project's dev environment without leaving OpenCode. Each project has a
`.devcontainer/` that pins a Node 22 toolchain (built on the shared `dev-base:1`
image from `dev/docker/dev.dockerfile` - node:22-bookworm + python3.12 + build
tools). CPU-only; Ollama never runs in-container (desktop `.wslconfig` has
`gpuSupport=false`).

## Known projects

| Alias | Path | Extra in image |
|---|---|---|
| `lfcbot` | `M:\Projects\LFCbot` | - |
| `asohav` | `M:\TTRPG\A Story of Heroes and Villains` | Playwright chromium + system deps |

`$ARGUMENTS` = alias, full path to a project with a `.devcontainer`, or a
command to run (default `bash`). If unknown, list the table and ask.

## Run a command in a project container

Reuse the same mounts the project's devcontainer declares so native modules
(`node_modules` volumes) persist and don't blow up the Windows filesystem:

```
docker run --rm -it --memory 4g --cpus 4 \
  -v "M:\TTRPG\A Story of Heroes and Villains:/workspace" \
  -v asohav-node_modules:/workspace/node_modules \
  -w /workspace dev-base:1 bash -lc "<command>"
```

- If the project has an `.devcontainer/` with a custom `FROM dev-base:1` image
  (asohav), build it first: `docker build -t <proj>-dev -f <proj>\.devcontainer\Dockerfile <proj>` then run that image instead.
- First use installs deps: `npm install` (+ `npx playwright install --with-deps chromium` for asohav - already baked at image build if the project image is used).
- For VS Code, point the user at `.devcontainer/devcontainer.json` (Dev
  Containers extension opens it directly).

## After the run

- Report the command output and exit code.
- Confirm the container was `--rm` (nothing lingering in `docker ps -a`).
- If they want the container to persist for a multi-step session, use
  `docker run -d --name proj-dev ...` + `docker exec`, ending with
  `docker rm -f proj-dev`.
- Never copy secrets into the container. It talks to the host Postgres at
  `host.docker.internal:5432` (or the published `127.0.0.1` port) if a project
  needs a DB; those credentials should come from the user via args/env, not
  from `.env` copies.
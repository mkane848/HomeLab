---
description: Run a throwaway Docker container for a quick experiment (a runtime, a CLI probe, a DB one-liner). Nothing persists.
---

# Sandbox

Run one experiment in a disposable container on this machine, then report what it showed. `$ARGUMENTS` names the
image or the experiment.

## Command

```
docker run --rm --memory 1g --cpus 2 [-v "<dir the user named>:/workspace" -w /workspace] <image> sh -lc "<command>"
```

Or the same through the repo's script: `.\desktop\scripts\docker-sandbox.ps1 -Image <image> -Command "<command>"
[-Work <dir>] [-Interactive] [-HostNetwork]`.

| `$ARGUMENTS` | Image |
|---|---|
| none | `dev-base:1` (Node 22, Python 3.11, git, build tools). If it is missing, build it: `.\desktop\scripts\docker-base.ps1` |
| node | `node:22` |
| python | `python:3.12` |
| postgres | `postgres:16-alpine` |
| redis | `redis:7-alpine` |
| anything else | ask the user before pulling it |

## Rules

- Always `--rm`, `--memory` and `--cpus`. The defaults are `1g` and `2`.
- Mount nothing by default. Mount only a directory the user names, at `/workspace`.
- Never mount `~/.config/opencode/.secrets`, any `.env` file, `~/.ssh` or a private key.
- CPU only: no `--gpus`, and no model runs in a container. Models are served by llama-server on the server and node3.
- A throwaway database publishes on loopback only, with a name:
  `docker run --rm -d --name scratch-pg -e POSTGRES_PASSWORD=x -p 127.0.0.1:55432:5432 postgres:16-alpine`.
  It ends with `docker rm -f scratch-pg`.
- A multi-step session uses `docker run -d --name <scratch> ...`, then `docker exec <scratch> ...` per step, and ends
  with `docker rm -f <scratch>`.

## Done when

- You have reported the command, its output and its exit code, and what that proves.
- `docker ps -a` shows no container this run left behind.

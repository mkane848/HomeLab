---
description: Run a command for LFCbot or ASoHaV inside a Node 22 container (dev-base:1) with the project mounted.
---

# Dev container

Run one command for a project inside the shared `dev-base:1` image (Node 22, Python 3.11, git, build tools), with the
project mounted at `/workspace`. `$ARGUMENTS` is a project alias or path, then the command (default `bash`). If the
project is unknown, show the table and ask.

| Alias | Path |
|---|---|
| `lfcbot` | `M:\Projects\LFCbot` |
| `asohav` | `M:\TTRPG\A Story of Heroes and Villains` |

## Command

```
docker run --rm --memory 4g --cpus 4 -v "<path>:/workspace" -v <alias>-node_modules:/workspace/node_modules -w /workspace dev-base:1 bash -lc "<command>"
```

- If `dev-base:1` is missing (`docker image inspect dev-base:1` fails), build it with `.\desktop\scripts\docker-base.ps1`.
- The named `node_modules` volume keeps Linux-built native modules out of the Windows checkout. On first use run
  `npm install` inside the container.
- If the project has a `.devcontainer/Dockerfile`, build and use that image instead
  (`docker build -t <alias>-dev -f "<path>\.devcontainer\Dockerfile" "<path>"`). Neither project has one today.

## Rules

- Always `--rm`, `--memory` and `--cpus`.
- Never copy secrets or `.env` files into the container. A project that needs a database gets `DATABASE_URL` from the
  user, through `-e`. The host's Postgres is `host.docker.internal:5432`.
- CPU only: no `--gpus`, and no model runs in the container.
- A multi-step session uses `docker run -d --name <alias>-dev ...`, then `docker exec`, and ends with
  `docker rm -f <alias>-dev`.

## Done when

- You have reported the command's output and exit code.
- `docker ps -a` shows no container this run left behind.

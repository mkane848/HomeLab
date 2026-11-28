# Containerised task runs: design

Written 2026-11-24. The owner decided on 2026-11-11 to containerise the runs: written alongside the real-work pilot,
built after it, and the start of a new era ([audit-2026-11-09.md](audit-2026-11-09.md), finding 2;
[roadmap.md](roadmap.md) → "Open after the 2026-11-09 audit"). **On 2026-11-28 the owner said go for step 1 ahead of
the pilot**: the image and a dry run, no model ("Building it", step 1, below). The harness itself is unchanged; steps 2
to 4 still wait.

## The problem: today an attempt runs on the host

On a run host (the desktop or node3, both Windows), `tests/test-tasks.ps1` does all of an attempt as the owner's own
account:

1. It builds the sealed checkout under `tests/.worktrees/<task>` from a git bundle of the pinned base, and installs.
2. It runs `opencode run --auto` (`tests/agents/opencode.ps1`, `Invoke-AgentRun`). Every tool call is approved without
   asking. The model's shell commands and file writes act on the host.
3. It grades: the suite, `failsOnOld` (source reverted, model's tests kept), the scoped typecheck and the acceptance
   files. **Every one of these runs model-written code**, outside OpenCode's permission layer altogether.

What that code can reach today:
- **The owner's files.** In round 2 of the llama.cpp trial, `real-01` edited the checkout's own `AGENTS.md` one
  directory up (roadmap, "After the trial", item 4).
- **The secrets folder** (`~/.config/opencode/.secrets`: the engine key and the OpenCode Go key), the owner's ssh keys,
  and on node3 **a deploy key that can push** (finding 2).
- **The LAN and the internet.** The task repos are public, so a task's upstream fix is one `git clone` away. The
  planner's proxy blocks exactly that for the planner (`desktop/docker/planner/squid.conf`). Attempts have no such
  block.

A second, smaller problem: the agent's version is whatever the host has. The desktop updated itself to OpenCode 2.3.2 on
2026-11-21 and batch runs stopped until the adapter was ported ([opencode-2-migration.md](opencode-2-migration.md)).

## Goals

1. **Contained.** The model's tool calls, and every grading command, run in a container that sees only the task
   checkout and an output folder.
2. **Allowlisted network.** Install reaches the package registry. The agent reaches only its model endpoint. Grading
   has no network.
3. **No owner secret inside** except the one key the seat needs, passed as an environment variable for that run.
4. **The same gates.** `writes`, `scope`, `suite`, `failsOnOld`, typecheck and acceptance keep their meaning and code, so
   a change in results comes from the environment alone. That is still a new era (below).
5. **A pinned agent.** The image carries its own OpenCode, so a host's auto-update no longer changes what is measured.

Not goals: protecting the engine from load, defending against a kernel or Docker escape, and a GPU in the container. The
engines stay where they are, on the server and node3; the attempt only calls them over HTTP.

## The design

### The precedent: the planner container

The planner already runs this way (2026-10-31; [planner-tests-experiment.md](planner-tests-experiment.md) → "The
planner"; `desktop/scripts/run-planner.ps1`, `desktop/docker/planner/`). Attempts copy it rather than invent a sandbox:
- the shared `dev-base:1` image (node 22, git, build tools), with the tool version pinned by a build argument;
- a non-root user (uid 1001) and no secrets in the image: the token arrives as an environment variable at run time;
- an internal Docker network whose only way out is a squid proxy with a host allowlist;
- `--memory`, `--cpus`, `--pids-limit 1024`, `--cap-drop ALL`, `--security-opt no-new-privileges:true`;
- a timeout that ends in `docker rm -f` on the named container.

### What stays on the host, and what moves

The host keeps the harness's role:
- reading the manifest and building the sealed bundle (it needs the task repo, which must never be mounted);
- reading the transcript, deciding every verdict and writing the run JSON and summary rows.

Everything that runs task or model code moves into an **attempt container**, one `docker run --rm` per phase, all on
the same per-attempt volume:

| Phase | Runs | Network |
|---|---|---|
| 1. checkout and install | `git clone` from the read-only bundle into the volume, `npm ci` (the task's `installFlags`), the task's `setup` steps | proxy: the package registry only (`registry.npmjs.org`, `nodejs.org`, as the planner's list) |
| 2. agent | `opencode run` in the checkout, transcript to `/out` | proxy: this seat's model endpoint only |
| 3. grading | the suite, the `failsOnOld` revert and re-run, the typecheck, the acceptance swap-in | `--network none` |

Splitting by phase lets Docker enforce each network rule, rather than the prompt asking for it. It also keeps the
model's run from installing anything: the tasks' `allowFiles` already forbid touching `package.json`.

### The image

`desktop/docker/attempt/attempt.dockerfile`, `FROM dev-base:1`, adds:
- a pinned OpenCode (`npm install -g` at a build-argument version);
- a pinned ripgrep, as CI pins it;
- the `attempt` user (uid 1001);
- `OPENCODE_DISABLE_AUTOUPDATE=1` and the proxy variables, as the planner sets its own.

The image digest and the OpenCode version reported from inside the image go into every run JSON (`attempt.image`,
`agentVersion`). A new pinned version is a new era for the rows, as it already is today.

**OpenCode's config is generated per run** by the harness from the profile: the provider entry for this seat with its
limits, and the `read-budget` plugin directory. It is mounted read-only. Its `apiKey` reads `{env:LLAMACPP_API_KEY}`.
Hosted seats are not in the first build ("Decided", item 3). The harness passes the variable from its own process environment, and the secrets folder
is never mounted. The planner's token travels the same way (AGENTS.md: "The planner's token travels only through the
process environment").

### The checkout: a volume, not a Windows folder

- **The checkout lives in a Docker volume per attempt**, not in a Windows folder bind-mounted into the container. On
  Docker Desktop, a bind mount from NTFS into a Linux container is slow for `node_modules`'s many small files. The volume
  also means Linux `node_modules`: a native module builds for Linux, as CI's would.
- **Phase 1 clones from the bundle the harness already makes** (`tests/.worktrees/.bundles/<sha>.bundle`, mounted
  read-only). The sealed property is unchanged: no branches, no tags, no remote, nothing after the base. The acceptance
  commit is added only after the agent's run, as `Add-CommitToCheckout` does now.
- **`/out` is the one bind mount the container writes to**, a small folder per attempt. It takes the transcript JSONL,
  the gate logs, and `git diff --binary --output=/out/model.diff`, written by the tool itself (AGENTS.md: let tools write
  their own output files). The harness reads only `/out`.
- **A shared npm cache volume** is mounted in phase 1 only.

### The network

The planner's pattern, one proxy per run host, with an allowlist per phase:
- **Phase 1:** CONNECT to 443 for the registry hosts.
- **Phase 2, a llama.cpp seat:** plain HTTP to one host and port, the engine. From node3, the engine is node3's own
  `llama-server`, reached as `host.docker.internal:8090`. From the desktop it is the server's address on the LAN.
- **Phase 2, a hosted seat:** not in the first build ("Decided", item 3). When it comes, it would be CONNECT to 443
  for OpenCode Go's API host only, with a per-run spend cap.
- **Phase 3:** `--network none`, no proxy.

The engine's API key ([engine-api-keys.md](engine-api-keys.md)) is the one secret inside. The model can read it from the
environment, but the proxy lets it reach only the engine it already uses.

### Limits and clean-up

- Every phase gets `--memory`, `--cpus`, `--pids-limit 1024`, `--cap-drop ALL`, `no-new-privileges`, a read-only root
  filesystem, and `tmpfs` for `/tmp` and `HOME`.
- Phase 2 keeps `-RunTimeout`, ending in `docker rm -f`.
- Containers carry a label with the run id. `Stop-OrphanAgent` becomes "remove containers with this label". The volume
  is removed when the attempt's JSON is written, or kept with `-KeepVolume` for a post-mortem.

### Changes to the harness

- **A runner seam:** `-Isolation host|container` on `test-tasks.ps1` and `run-tasks-batch.ps1`. It defaults to `host`
  until the era starts. Every command the harness runs today (install, setup, agent, gates) goes through one
  `Invoke-InAttempt` function: as now for `host`, one `docker run` per phase for `container`.
- **The adapter:** `Invoke-AgentRun` gets a container branch: the same `opencode run` arguments, the stdin closed, the
  transcript to `/out`. `Read-AgentEvents` is unchanged, because the events are the same JSON. Paths in the events
  read `/work/...`, so the scope gate and the outside-writes check take paths relative to the checkout root.
- **The run JSON records** `isolation`, the image digest, the agent version from inside, and the hash of each phase's
  allowlist.
- **Guards:** a stand-in `docker` that logs every call, as `tests/test-llamacpp-window.ps1` and
  `tests/test-ollama-inventory.ps1` do. It asserts each phase's network flag, mounts and limits, and that no secrets
  folder or home directory is ever mounted. A real-Docker smoke test runs on the desktop only.

## What changes in the results: a new era

The container is Linux and the run hosts are Windows. So, even with every gate the same:
- **line endings are LF:** the CRLF hazards go away, `asohav-09`'s among them;
- **the agent's shell is bash, not pwsh,** and node and the npm tools come from the image, not the host;
- **OpenCode is pinned** in the image.

So rows under `container` are a new era. As decided on 2026-11-11, **the 16-task baseline is re-run inside the
container before any comparison**, and old and new rows are reported apart. The public tasks (27, or 40 with the 13 mined on
2026-11-23 in PR #261) need it as well before their rows are pooled. The 13 have no rows yet, so they can start in the
new era directly.

## Building it: four steps, each a PR and a stop point

0. **The owner: Docker on node3.** Docker Desktop with WSL 2, the same as the desktop (decided 2026-11-24). `docker run --rm hello-world`
   should pass. Nothing in `node3/README.md` or `machines.tsv` records Docker on node3.
1. **The image and a dry run, no model:**
   - build `attempt:1`;
   - `opencode --version` inside;
   - clone one sealed bundle into a volume, install it, and run its baseline;
   - measure the volume against a bind mount, to settle the checkout question with numbers.

   **Built 2026-11-28; run on two fixture tasks in a Linux cloud session, not yet on a real task or on Docker Desktop.**
   - `desktop/docker/attempt/attempt.dockerfile`: `FROM dev-base:1`, `@opencode/cli` 2.3.2, ripgrep 14.1.1 pinned by
     the sha256 [published with the release](https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz.sha256),
     corepack, the `attempt` user (uid 1001).
   - `desktop/scripts/attempt-dryrun.ps1 -Task <id>` runs phase 1 and phase 3 into a volume and into a bind mount, and
     writes `report.json`. It uses the harness's own bundle (`Get-CommitBundle`), and seals the checkout as
     `Initialize-SealedCheckout` does. Guard: `tests/test-attempt-dryrun.ps1` (a stand-in `docker`; the flags of
     every call).
   - **What the session showed**, on an npm task and a pnpm one (corepack), both with vitest 2.1.9:
     - `opencode --version` inside: `opencode v2.3.2` (the adapter strips the `v`), ripgrep 14.1.1, node 22;
     - the checkout is sealed: 1 commit, no refs, no remote;
     - install, then the baseline with `--network none`, pass on both;
     - pnpm finds its pinned version with no network, from the cache volume;
     - a grading container resolves no host, and its root filesystem is read-only.
   - **Settled by the build, against the design above:**
     - The proxy variables are set per phase at run time, not in the image. Each phase has its own network rule, and
       grading has none.
     - The cache volume is mounted read-only in grading as well as in install. corepack keeps the pnpm it downloaded
       there, and grading needs it with no network.
     - The image makes `/work` and `/cache` the `attempt` user's. A new volume copies its owner from the image, and
       without this neither is writable (the session's first run failed with `EACCES`).
     - `CI` is not set, so pnpm and vitest behave as on the hosts.
   - **Not settled: the volume against the bind mount.** In the session the two were within a second of each other
     (install 2.4 against 1.4 s, baseline 1.3 against 1.2 s, a one-dependency task), but that is Linux to Linux. The
     question is NTFS into Docker Desktop's Linux VM, with a real task's `node_modules`. That is the owner's run on the
     desktop: `pwsh -File desktop\scripts\attempt-dryrun.ps1 -Task <a public task> -Build`, after
     `.\desktop\scripts\docker-base.ps1`.
2. **Grading in the container**, behind `-Isolation container`, with a stand-in agent. Use the rig of
   `docs/task-mining-2026-11-23/` (PR #261): the same patches, and the `ref`, `srconly` and
   `testsonly` arms for every public task. The **verdict matrix must equal the host's** task by task, except where line
   endings or a Windows-only path explain a difference. This is the equivalence check that makes the era cut honest.
3. **The agent in the container**, with the proxy:
   - one task end to end from the desktop against the server's engine;
   - then from node3 against its own;
   - check the allowlist from inside: the engine answers, and `github.com` and `registry.npmjs.org` are refused in
     phase 2.
4. **The era:** the 16-task baseline inside, then the batch default flips to `container`, recorded in
   `tests/results/NOTES.md` and the roadmap.

## Decided (owner, 2026-11-24)

1. **node3 gets Docker Desktop**, the same as the desktop, so there is one setup to support. The owner installs it
   (step 0). Because node3 is also where the owner games, the harness stops the WSL VM after a batch, so Docker holds
   no memory between batches.
2. **node3's engine: check first.** In step 3 a container on node3 calls `host.docker.internal:8090`. If node3's
   `llama-server` answers there while it is bound to `127.0.0.1`, nothing changes. If not, the build stops and comes
   back to the owner with the change needed: binding to the WSL network as well, which touches the LAN firewall rule
   still owed.
3. **Hosted seats wait.** The first build covers local llama.cpp seats only, and hosted (OpenCode Go) seats stay on the
   host as today. Two things come first:
   - the 2.x spend reader's $0 problem must be understood ([opencode-2-migration.md](opencode-2-migration.md), step 3.5;
     finding out needs one priced Go call, the owner's decision);
   - a per-run spend cap must be designed.

   Nothing that spends money changes in this design.

Not a question: GPU passthrough is not wanted. Attempts call the engines over HTTP.

## What it does not protect against

- a kernel or Docker escape;
- load on the engine;
- a prompt that persuades the harness (its parsing of the transcript runs on the host, on text the model wrote).

The harness reads only `/out` and never executes anything from it.

# The attempt container (docs/container-runs.md, "The image"): one task attempt's install, agent and grading run in
# it, on the repo's shared dev base (node 22, git, build tools; dev/docker/dev.dockerfile, tagged dev-base:1 by
# desktop/scripts/docker-base.ps1), as a normal user. Nothing secret is baked in: the engine key the seat needs
# arrives as an environment variable at run time, as the planner's token does (desktop/docker/planner/).
#
# Build:  docker build -t attempt:1 -f desktop/docker/attempt/attempt.dockerfile desktop/docker/attempt
# Check:  pwsh -File desktop/scripts/attempt-dryrun.ps1 (step 1 of the design: no model)
FROM dev-base:1

# Pinned: a new OpenCode is a new era for the rows, as on the hosts. 2.x is published as @opencode/cli
# (docs/opencode-2-migration.md); 2.3.2 is the version CI and the run hosts use since the cutover (#265).
ARG OPENCODE_VERSION=2.3.2
# Pinned as CI pins it (14.1.1), and by its sha256 here: OpenCode runs `rg` from PATH, and without one it downloads its
# own (docs/opencode-2-migration.md, step 3.4). The checksum is the one published beside the release asset.
ARG RIPGREP_VERSION=14.1.1
ARG RIPGREP_SHA256=4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e

RUN curl -fsSL -o /tmp/rg.tgz "https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/ripgrep-${RIPGREP_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    && echo "${RIPGREP_SHA256}  /tmp/rg.tgz" | sha256sum -c - \
    && tar -xzf /tmp/rg.tgz -C /tmp \
    && install -m 0755 "/tmp/ripgrep-${RIPGREP_VERSION}-x86_64-unknown-linux-musl/rg" /usr/local/bin/rg \
    && rm -rf /tmp/rg.tgz /tmp/ripgrep-*

RUN npm install -g "@opencode/cli@${OPENCODE_VERSION}" && npm cache clean --force
# pnpm and yarn through corepack, at the version each task's package.json names. corepack keeps what it downloads in
# COREPACK_HOME, which is on the cache volume, so grading (no network) finds the pnpm that install fetched.
RUN corepack enable

RUN useradd --create-home --uid 1001 attempt
# /work (the checkout volume) and /cache (the npm and corepack cache volume) belong to the attempt user. A new named volume
# takes its ownership from the image's folder at its mount point, so without these the user cannot write either.
RUN mkdir -p /work /cache && chown attempt:attempt /work /cache
USER attempt
WORKDIR /work
# The proxy is set per phase at run time (-e HTTPS_PROXY=...), not here: install, the agent and grading each get their
# own network rule (docs/container-runs.md, "The network"), and grading gets none at all.
ENV OPENCODE_DISABLE_AUTOUPDATE=1 \
    npm_config_cache=/cache/npm \
    npm_config_update_notifier=false \
    COREPACK_HOME=/cache/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0

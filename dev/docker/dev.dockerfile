# dev/docker/dev.dockerfile - shared CPU base image for desktop devcontainers
# and sandboxes. Tagged locally as `dev-base:1` (see desktop/scripts/docker-base.ps1).
#
# Curve: node:22 (all our app projects are Node >=22 TS), Python 3 (bookworm
# ships 3.11) for scripting/tooling, git + build toolchain so native modules
# (esbuild, better-sqlite3, pg, etc.) compile in-container.
#
# CPU-only by design: the desktop .wslconfig sets gpuSupport=false (WSL
# ConfigureGpu workaround), so there is NO GPU passthrough. Ollama stays native
# via ROCm on the host - nothing here should ever try to run a model.
#
# No secrets ever: projects that need a DATABASE_URL pass it at run time
# (--env / envfile), they are not baked into this image.

FROM node:22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        python3 \
        python3-pip \
        python3-venv \
        git \
        curl \
        ca-certificates \
        procps \
    && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=development
WORKDIR /workspace
CMD ["/bin/bash"]
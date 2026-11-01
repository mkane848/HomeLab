# The planner container: Claude Code on the repo's shared dev base (node 22, git, build tools), as a normal user.
# It has no secrets baked in: the token arrives as an environment variable at run time (run-planner.ps1).
FROM dev-base:1
# Pinned to the version experiment 3's planner sets were written with; a new version is a new era for planner rows.
ARG CLAUDE_CODE_VERSION=2.1.316
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
RUN useradd --create-home --uid 1001 planner
USER planner
WORKDIR /home/planner
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_AUTOUPDATER=1 \
    HTTPS_PROXY=http://planner-proxy:3128 \
    HTTP_PROXY=http://planner-proxy:3128 \
    NO_PROXY=localhost,127.0.0.1

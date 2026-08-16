# Isolated box: herdr with one Claude Code pane, which can launch OMP agents
# against the llama.cpp servers listed in models.conf. No model is pinned in the
# image or in the container: each agent is born with its own URL when
# spawn-model creates its pane.
#
# Ubuntu 26.04 on purpose: the agent binaries are copied from the host, which is
# 26.04. On an older base (24.04) the glibc is too old and omp/claude will not
# start. If your host is a different release, change this to match it.
FROM ubuntu:26.04

# build-essential looks unnecessary but is not: `uv` installs wheels, and when a
# package publishes no wheel for this Python version it falls back to building
# from source, which dies without a compiler. With `uv` alone the agents get
# stuck on this regularly.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git python3 ripgrep less procps nano vim-tiny \
        build-essential jq \
    && rm -rf /var/lib/apt/lists/*

# Same uid/gid as the unprivileged user on the host, so the named volumes keep
# their ownership and the process inside can write to them.
ARG UID=1001
ARG GID=1001
RUN groupadd -g ${GID} agentic \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash agentic

COPY --chown=agentic:agentic bin/ /home/agentic/.local/bin/
COPY --chown=agentic:agentic workspace/CLAUDE.md /home/agentic/workspace/CLAUDE.md
# A second copy OUTSIDE the volume, on purpose. /home/agentic/workspace is a
# named volume, and Docker only seeds a volume when it is brand new and empty: on
# an existing one the COPY above never reaches the container and the agent keeps
# reading a stale CLAUDE.md with nothing to signal it. The entrypoint refreshes
# from this path.
COPY --chown=agentic:agentic workspace/CLAUDE.md /usr/local/share/agentic-box/CLAUDE.md
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# The tools Claude Code uses from inside to launch and shut down model agents.
# They go on the PATH, next to the agent binaries.
COPY --chown=agentic:agentic bin-tools/ /home/agentic/.local/bin/

# The model registry. Outside the workspace volume, because an existing named
# volume is never re-seeded from the image and it would freeze.
COPY models.conf /usr/local/share/agentic-box/models.conf

RUN chmod +x /usr/local/bin/entrypoint.sh /home/agentic/.local/bin/*

USER agentic
WORKDIR /home/agentic/workspace

# ~/.claude has to EXIST in the image and be owned by agentic. When Docker seeds a
# named volume it copies the content and ownership of that path in the image; if
# the path does not exist it creates an empty directory as root, and the process
# inside (uid 1001) cannot write its own config. Symptom: Claude Code persists
# nothing.
RUN mkdir -p /home/agentic/.claude
ENV PATH=/home/agentic/.local/bin:$PATH
ENV HOME=/home/agentic

# Essential. With a named session, herdr puts its socket in
# ~/.config/herdr/sessions/<name>/herdr.sock, but the CLI looks in
# ~/.config/herdr/herdr.sock by default and answers "server_not_running". This
# variable points every call — including the ones Claude Code makes — at the
# right session.
ENV HERDR_SESSION=agentic

# LLAMA_CPP_BASE_URL is deliberately NOT defined at the image level.
#
# It used to be, and it was the only possible backend for the whole box. Each OMP
# agent is now born in its own pane with its own URL, set by spawn-model through
# `herdr pane split --env`. A global variable here would only let an OMP agent
# started by hand, outside spawn-model, point somewhere silently — which is
# exactly the failure mode this design removes.

# Without this, OMP starts its login wizard and sits there asking for a provider
# ("Login failed: token_expired"). Any prompt Claude Code sends lands in the
# wizard's search box instead of reaching the model. The models are local and
# need no account, so the wizard is pure obstacle.
RUN omp config set startup.setupWizard false \
    && omp config set setupVersion 1

# uv as the Python manager, same as on the host. It installs into ~/.local/bin,
# already on the PATH. UV_LINK_MODE=copy avoids hardlink warnings when the cache
# and the target land on different volumes.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV UV_LINK_MODE=copy

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

#!/bin/bash
# Start herdr with a SINGLE pane: Claude Code.
#
# This used to open two fixed panes — Claude on the left and an OMP agent against
# a model chosen when the container was created. The model was pinned in an
# environment variable, so changing it meant stopping and recreating the box.
#
# Model agents are now launched on demand, from inside, with
# `spawn-model <alias>`. Claude Code can call it itself. Each agent is born in
# its own pane with its own LLAMA_CPP_BASE_URL, so several can coexist against
# different hosts.
#
# The layout is built from a background subshell because herdr's socket API only
# answers once the server is up, and the server is started by the `herdr` call at
# the end (which stays in the foreground holding the TTY).
set -uo pipefail

SESSION="${HERDR_SESSION:-agentic}"

# The workspace is a named volume: Docker only seeds a volume from the image when
# it is brand new and empty. On an existing volume the CLAUDE.md stays frozen at
# the version from the first build, and the agent works from stale instructions
# with nothing to indicate it. Refresh from the copy that lives outside the
# volume.
refresh_claude_md() {
    local source=/usr/local/share/agentic-box/CLAUDE.md
    local target=/home/agentic/workspace/CLAUDE.md
    [ -f "$source" ] || return 0
    cmp -s "$source" "$target" 2>/dev/null && return 0
    # If a different one was there, keep it rather than losing it.
    [ -f "$target" ] && cp "$target" "${target}.previous"
    cp "$source" "$target"
    echo "entrypoint: CLAUDE.md updated (the old one is at CLAUDE.md.previous)" >&2
}

setup_layout() {
    # 1. Wait for the API to answer (the server takes a couple of seconds).
    for _ in $(seq 1 60); do
        herdr pane list >/dev/null 2>&1 && break
        sleep 1
    done
    if ! herdr pane list >/dev/null 2>&1; then
        echo "entrypoint: herdr's API never answered; layout not built" >&2
        return 1
    fi

    # 2. The only existing pane is Claude Code's. Nothing else is split: model
    #    panes are created by spawn-model when they are needed.
    local p1
    p1=$(herdr pane list | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["panes"][0]["pane_id"])')

    # 3. Name the pane. By default herdr titles it after the basename of the cwd,
    #    which here is always "workspace" (the image's WORKDIR): without this,
    #    Claude and every model agent show up under the same name on screen.
    herdr pane rename "$p1" claude >/dev/null 2>&1 || true

    # 4. `agent start` waits until the agent is ready for input, so an ok return
    #    means the pane is usable.
    herdr agent start claude --kind claude --pane "$p1" >/dev/null

    echo "entrypoint: claude in $p1 — local models on demand via spawn-model" >&2
}

refresh_claude_md

setup_layout &

exec herdr --session "$SESSION"

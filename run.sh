#!/bin/bash
# Launch the box: herdr with Claude Code, and local models on demand.
#
# Runs AS the box user:
#     sudo -u agentic -H bash ~/agentic-box/run.sh
#
# Idempotent: safe to run as many times as needed.
#
# The container starts with Claude Code alone. Model agents are launched from
# inside with `spawn-model <alias>`, each in its own pane with its own
# LLAMA_CPP_BASE_URL, so several can run against different hosts at once.
set -euo pipefail

# The box user is whoever owns this deployment — derived from the file, not
# assumed, so a differently-named user works without editing anything.
BOX_USER="$(stat -c %U "$0")"

if [ "$(id -un)" != "$BOX_USER" ]; then
    echo "ERROR: this runs as $BOX_USER, not as $(id -un)." >&2
    echo "       sudo -u $BOX_USER -H bash $0" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/agentic-box"
IMG=agentic-box

# The box user's rootless docker, not the system daemon.
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

if [ ! -S "${DOCKER_HOST#unix://}" ]; then
    echo "ERROR: no rootless docker socket at ${DOCKER_HOST#unix://}" >&2
    echo "       Start it with: systemctl --user start docker" >&2
    echo "       If it vanishes after every reboot, lingering is off:" >&2
    echo "         sudo loginctl enable-linger $BOX_USER" >&2
    exit 1
fi

# 1. Bring the build context into this user's own home, if run from elsewhere.
if [ "$SRC" != "$DST" ]; then
    echo "== copying build context to $DST =="
    mkdir -p "$DST"
    cp -r "$SRC"/. "$DST"/
fi
cd "$DST"

# 2. The model registry.
REGISTRY="$DST/models.conf"
if [ ! -f "$REGISTRY" ]; then
    echo "ERROR: $REGISTRY is missing" >&2
    echo "       cp $DST/models.conf.example $DST/models.conf  and fill it in" >&2
    exit 1
fi

# alias base_url ip, skipping comments and blank lines
entries() { grep -vE '^[[:space:]]*(#|$)' "$REGISTRY"; }

if [ -z "$(entries)" ]; then
    echo "ERROR: $REGISTRY has no valid entries" >&2
    exit 1
fi

# 3. Check every model BEFORE building anything. One being down is not fatal —
#    the box still works with the others — but it is worth knowing now rather
#    than when spawn-model fails inside.
echo "== models in $REGISTRY =="
ADDHOSTS=()
while read -r alias url ip; do
    host="${url#https://}"; host="${host#http://}"; host="${host%%/*}"
    # --add-host: the container's resolver does not know the tailnet, so MagicDNS
    # names do not resolve inside it. Pinning the name to the 100.x address keeps
    # TLS valid, because the `tailscale serve` certificate is for that same name.
    ADDHOSTS+=(--add-host "${host}:${ip}")
    if curl -sf -m 8 "$url/health" >/dev/null 2>&1; then
        served=$(curl -s -m 8 "$url/v1/models" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
        # Answering is not enough: it has to serve the alias the registry claims,
        # because that is what spawn-model will ask OMP for.
        if grep -qw "$alias" <<<"$served"; then
            printf '   ok        %-14s %s\n' "$alias" "$url"
        else
            printf '   MISMATCH  %-14s answers but serves [%s], not %s\n' "$alias" "${served% }" "$alias"
        fi
    else
        printf '   down      %-14s %s\n' "$alias" "$url"
    fi
done < <(entries)

# 4. The agent binaries. Not versioned (GitHub rejects files over 100 MB and the
#    Claude Code binary is around 300), so deploy.sh copies them from the host.
#    Without them the build produces an image that starts and does nothing.
for b in claude omp herdr; do
    if [ ! -x "$DST/bin/$b" ]; then
        echo "ERROR: $DST/bin/$b is missing" >&2
        echo "       Run deploy.sh from the repo; it copies them from ~/.local/bin." >&2
        exit 1
    fi
done

# 5. Build.
echo "== build =="
docker build -t "$IMG" .

# 6. The Claude Code token. Logging in via OAuth inside the container is not
# viable: it means pasting a long `code#state` string into a TUI, inside a docker
# TTY, inside a herdr pane, and the paste gets truncated — hence
# "OAuth error: Invalid code". Generate the token OUTSIDE, in a normal terminal,
# with `claude setup-token`, and pass it through the environment.
#
# --env-file rather than -e, so the token never shows up in `ps`.
#
# This block goes BEFORE the "already running" check. Environment variables are
# fixed when the container is CREATED: if one is already running without the
# token, attaching does not add it, and re-running this script changes nothing.
# It has to be stopped and recreated.
ENVFILE="$HOME/.config/agentic-box.env"
ENVARGS=()
if [ -f "$ENVFILE" ]; then
    ENVARGS=(--env-file "$ENVFILE")
    echo "== token read from $ENVFILE =="
else
    echo "WARNING: $ENVFILE does not exist; Claude Code will ask for an interactive" >&2
    echo "         login, and pasting the code usually fails. To avoid it:" >&2
    echo "           1. in a normal terminal, as yourself:  claude setup-token" >&2
    echo "           2. sudo -u $BOX_USER -H mkdir -p $HOME/.config" >&2
    echo "           3. write this single line into $ENVFILE:" >&2
    echo "                CLAUDE_CODE_OAUTH_TOKEN=<token>" >&2
    echo "           4. sudo -u $BOX_USER -H chmod 600 $ENVFILE" >&2
fi

# 7. If a session is already running, attach to it — unless that container was
#    created without the token. Attaching changes no variable: they are fixed at
#    creation time.
#
#    Note: the old "points at a different URL" guard is gone. The container used
#    to have one backend pinned in LLAMA_CPP_BASE_URL, so attaching to a stale
#    one left you talking to the wrong model with no warning. The URL is now
#    decided per agent, when its pane is created, so a container cannot be
#    "pointed" anywhere.
if docker ps --format '{{.Names}}' | grep -qx "$IMG"; then
    CURRENT_ENV=$(docker inspect "$IMG" --format '{{range .Config.Env}}{{println .}}{{end}}')

    if [ ${#ENVARGS[@]} -gt 0 ] && ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' <<<"$CURRENT_ENV"; then
        echo >&2
        echo "STOP: the running container was created WITHOUT the token." >&2
        echo "      Environment variables are fixed at creation, so attaching will" >&2
        echo "      never log it in, no matter how many times you re-run this." >&2
        echo >&2
        echo "      Stop it and bring it back up:" >&2
        echo "        bash $DST/ctl.sh stop && bash $DST/run.sh" >&2
        exit 1
    fi

    echo "== already running, attaching =="
    exec docker attach "$IMG"
fi

echo "== run — claude only; local models on demand via spawn-model =="
# The named volumes are what make the Claude Code login and the OMP sessions
# survive a container restart.
exec docker run -it --rm \
    --name "$IMG" \
    "${ADDHOSTS[@]}" \
    "${ENVARGS[@]}" \
    -v agentic-work:/home/agentic/workspace \
    -v agentic-claude:/home/agentic/.claude \
    -v agentic-omp:/home/agentic/.omp \
    "$IMG"

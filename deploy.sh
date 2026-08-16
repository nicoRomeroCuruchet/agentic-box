#!/bin/bash
# Copy this repo to the box user's home, where the container is built and run.
#
#     ./deploy.sh            copy only
#     ./deploy.sh --run      copy and launch
#
# The repo and the deployment live in different places on purpose:
#
#   this repo          editable by you, versioned
#   <box-home>/agentic-box   the deployment: owned by another user, mode 750,
#                            unreadable from your account
#
# That separation IS the isolation of the box, not a problem to fix. This script
# is the only bridge, which is why it needs sudo.
#
# Override BOX_USER to deploy for a differently-named unprivileged user.
set -euo pipefail

# --- Who runs this ----------------------------------------------------------
# Your normal account, the one with sudo. NOT `sudo ./deploy.sh`, and not as the
# box user. The script calls sudo where it needs to; running the whole thing as
# root makes $HOME become /root, so the agent binaries get looked up in
# /root/.local/bin, which does not exist. The resulting error does not say that,
# so stop here instead.
if [ "$(id -u)" = 0 ]; then
    echo "ERROR: do not run this with sudo or as root." >&2
    echo "       Run it as yourself: ./deploy.sh" >&2
    echo "       The script already uses sudo where needed." >&2
    exit 1
fi

BOX_USER="${BOX_USER:-agentic}"

if ! id -u "$BOX_USER" >/dev/null 2>&1; then
    echo "ERROR: the user '$BOX_USER' does not exist on this system." >&2
    echo "       Create it (see README, 'Who runs what') or set BOX_USER." >&2
    exit 1
fi
if [ "$(id -un)" = "$BOX_USER" ]; then
    echo "ERROR: run this from your own account, not as $BOX_USER." >&2
    echo "       $BOX_USER has no sudo and cannot read the repo." >&2
    exit 1
fi

# Read the home from passwd rather than assuming /home/<user>: it is not
# guaranteed, and hardcoding it is the kind of thing that works on exactly one
# machine.
BOX_HOME="$(getent passwd "$BOX_USER" | cut -d: -f6)"
BOX_UID="$(id -u "$BOX_USER")"
if [ -z "$BOX_HOME" ]; then
    echo "ERROR: could not determine the home directory of '$BOX_USER'." >&2
    exit 1
fi

REPO="$(cd "$(dirname "$0")" && pwd)"
DST="$BOX_HOME/agentic-box"
BINSRC="${BINSRC:-$HOME/.local/bin}"

# --- The box user's rootless docker has to survive --------------------------
# Without lingering, systemd tears down the box user's session as soon as no
# session of theirs is open — which is always, because nobody logs in as that
# user. No session means no dockerd, no socket, and run.sh fails with "socket
# not found". It is the most fragile part of the setup and gives no symptom
# until the first reboot.
if [ "$(loginctl show-user "$BOX_USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
    echo "WARNING: lingering is not enabled for '$BOX_USER'." >&2
    echo "         Its rootless docker will die at the next logout or reboot." >&2
    echo "         Enable it once with:" >&2
    echo "           sudo loginctl enable-linger $BOX_USER" >&2
    echo >&2
fi

echo "== source : $REPO"
echo "== target : $DST   (user $BOX_USER, uid $BOX_UID)"

# 1. The agent binaries. They are not versioned: GitHub rejects files over
#    100 MB and the Claude Code binary is around 300. They are copied from the
#    host on every deploy, which also keeps the box on the same version you use.
echo "== binaries from $BINSRC =="
missing=0
for b in claude omp herdr; do
    if [ -x "$BINSRC/$b" ]; then
        # stat -L dereferences: `claude` is usually a symlink into
        # ~/.local/share/claude/versions/<version>, and without -L stat reports
        # the ~50 bytes of the link instead of the ~300 MB of the binary. `cp`
        # does follow the symlink, so the copy was always right and only the
        # number was wrong.
        printf '   ok      %-8s %6.1f MB\n' "$b" "$(stat -Lc %s "$BINSRC/$b" | awk '{print $1/1048576}')"
    else
        echo "   MISSING $b in $BINSRC" >&2
        missing=1
    fi
done
if [ "$missing" = 1 ]; then
    echo "ERROR: without those binaries the image builds but is useless." >&2
    echo "       If they live elsewhere: BINSRC=/path ./deploy.sh" >&2
    exit 1
fi

mkdir -p "$REPO/bin"
cp "$BINSRC"/claude "$BINSRC"/omp "$BINSRC"/herdr "$REPO/bin/"

# 2. The registry, with real values.
if [ ! -f "$REPO/models.conf" ]; then
    echo "ERROR: $REPO/models.conf is missing" >&2
    echo "       cp models.conf.example models.conf  and fill it in" >&2
    exit 1
fi

# 3. Copy. `cp -r` over an existing deployment overwrites what matches and
#    deletes nothing. The docker volumes (workspace, login, sessions) do not
#    live here, so this touches no state.
echo "== copying =="
sudo install -d -o "$BOX_USER" -g "$BOX_USER" -m 755 "$DST"
sudo cp -r "$REPO"/. "$DST"/
sudo rm -rf "$DST/.git"          # the repo has no business in the deployment
sudo chown -R "$BOX_USER:$BOX_USER" "$DST"

# The chmod goes INSIDE sudo bash -c, not as `sudo chmod "$DST"/*.sh`.
#
# Globs are expanded by the shell that writes them, and that shell is yours: you
# cannot read the box user's home (mode 750), so `"$DST"/*.sh` matches nothing,
# is passed through literally, and chmod complains about a file named '*.sh'.
# Under `set -e` that aborts the script right before --run.
#
# In practice the chmod is redundant — `cp -r` already preserves the source
# modes — so it is kept only as a safety net and is not fatal.
sudo bash -c "cd '$DST' && chmod +x *.sh bin/* bin-tools/* 2>/dev/null || true"

echo "== done =="
sudo ls -la "$DST" | sed 's/^/   /'

if [ "${1:-}" = "--run" ]; then
    echo
    echo "== launching =="
    echo "   NOTE: herdr is a full-screen TUI and needs a real TTY."
    echo "   If this looks broken, run it from a terminal emulator, not from an agent."
    exec sudo -u "$BOX_USER" -H bash "$DST/run.sh"
else
    echo
    echo "To launch it:"
    echo "   sudo -u $BOX_USER -H bash $DST/run.sh"
fi

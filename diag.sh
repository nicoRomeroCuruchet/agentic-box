#!/bin/bash
# Diagnose the Claude Code token inside the box.
#   sudo -u agentic -H bash ~/agentic-box/diag.sh
# Never prints the token: only its length and prefix, so it can be compared
# without being exposed.
set -uo pipefail

BOX_USER="$(stat -c %U "$0")"

if [ "$(id -un)" != "$BOX_USER" ]; then
    echo "ERROR: run this as $BOX_USER:" >&2
    echo "  sudo -u $BOX_USER -H bash $0" >&2
    exit 1
fi

ENVFILE="$HOME/.config/agentic-box.env"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

echo "=== 1. who and where ==="
echo "user : $(id -un)"
echo "HOME : $HOME"
echo "file : $ENVFILE"

echo
echo "=== 2. the environment file ==="
if [ ! -f "$ENVFILE" ]; then
    echo "DOES NOT EXIST. That is the cause: run.sh has nothing to inject."
    echo "Watch out for HOME: if it was created without sudo's -H, it may have"
    echo "landed in your own ~/.config or in /root/.config instead of $HOME/.config."
    ls -la "$HOME/.config/" 2>&1 | head -5
else
    echo "exists. permissions: $(stat -c '%A %U:%G' "$ENVFILE")"
    echo "lines: $(wc -l < "$ENVFILE")"
    # Show the shape without revealing the value.
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        echo "  key='$key'  value_length=${#value}  starts_with='${value:0:12}'"
        case "$value" in
            \"*|\'*) echo "  >> PROBLEM: the value is quoted. docker --env-file does NOT strip" \
                          "quotes, so they end up inside the token. Remove them." ;;
        esac
        case "$key" in
            CLAUDE_CODE_OAUTH_TOKEN) ;;
            *) echo "  >> PROBLEM: the key must be exactly CLAUDE_CODE_OAUTH_TOKEN" ;;
        esac
    done < "$ENVFILE"
    echo "  (a setup-token value starts with 'sk-ant-oat' and is long, >60)"
fi

echo
echo "=== 3. rootless docker ==="
docker version --format '{{.Server.Version}}' 2>&1 | head -1

echo
echo "=== 4. what claude sees inside the container ==="
# `claude auth status` is NOT a validity check: it returns loggedIn:true for any
# non-empty value, because it only looks at whether the variable is set. The only
# real test is a call that hits the API.
if [ -f "$ENVFILE" ] && docker image inspect agentic-box >/dev/null 2>&1; then
    docker run --rm --env-file "$ENVFILE" --entrypoint bash agentic-box -c '
        echo "variable present: $([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo yes || echo NO)"
        echo "length: ${#CLAUDE_CODE_OAUTH_TOKEN}"
        echo "--- real call (this is the only check that proves anything) ---"
        timeout 60 claude -p "reply with only: OK" 2>&1 | head -5'
else
    echo "skipped (missing file, or the agentic-box image has not been built yet)"
fi

echo
echo "=== 5. the volume may be shadowing the config ==="
docker run --rm -v agentic-claude:/c --entrypoint bash agentic-box -c \
    'ls -la /c 2>/dev/null | head -10' 2>/dev/null \
    || echo "(no volume yet)"

#!/bin/bash
# Control the box without typing DOCKER_HOST every time.
#
#   sudo -u agentic -H bash ~/agentic-box/ctl.sh <status|stop|attach|logs|purge>
#
# `stop` destroys nothing persistent: the container runs with --rm, but the
# Claude Code login, the OMP sessions and the workspace live in named volumes and
# survive. Removing those takes `purge`, which asks first.
set -uo pipefail

# The box user is whoever owns this deployment — derived, not assumed.
BOX_USER="$(stat -c %U "$0")"

if [ "$(id -un)" != "$BOX_USER" ]; then
    echo "ERROR: this runs as $BOX_USER, not as $(id -un)." >&2
    echo "       sudo -u $BOX_USER -H bash $0 $*" >&2
    exit 1
fi

export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
IMG=agentic-box

case "${1:-status}" in
    status)
        echo "== container =="
        docker ps --filter "name=$IMG" --format 'table {{.Names}}\t{{.Status}}' || true
        docker ps -q --filter "name=$IMG" | grep -q . || echo "(not running)"
        echo "== persistent volumes =="
        docker volume ls --filter name=agentic- --format 'table {{.Name}}\t{{.Driver}}'
        ;;
    stop)
        if docker ps -q --filter "name=$IMG" | grep -q .; then
            docker stop -t 10 "$IMG" && echo "stopped (volumes left untouched)"
        else
            echo "was not running"
        fi
        ;;
    attach)
        exec docker attach "$IMG"
        ;;
    logs)
        docker logs --tail "${2:-50}" "$IMG"
        ;;
    purge)
        echo "This DELETES the Claude Code login, the OMP sessions and the workspace."
        echo "The token itself is not here — it stays in ~/.config/agentic-box.env —"
        echo "but the login state inside the container is lost."
        read -rp "Type 'yes' to confirm: " r
        [ "$r" = "yes" ] || { echo "cancelled"; exit 0; }
        docker rm -f "$IMG" 2>/dev/null
        docker volume rm agentic-work agentic-claude agentic-omp
        ;;
    *)
        echo "usage: ctl.sh <status|stop|attach|logs [N]|purge>" >&2
        exit 1
        ;;
esac

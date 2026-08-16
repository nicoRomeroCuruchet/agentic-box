#!/bin/bash
# Control de la caja `agentic` sin tener que tipear el DOCKER_HOST cada vez.
#
#   sudo -u agentic -H bash /tmp/agentic-box/ctl.sh <estado|stop|attach|logs|limpiar>
#
# `stop` no borra nada persistente: el contenedor corre con --rm, pero el login de
# Claude Code, las sesiones de OMP y el workspace viven en volumenes nombrados y
# sobreviven. Para borrarlos hace falta `limpiar`, que pregunta antes.
set -uo pipefail

if [ "$(id -un)" != "agentic" ]; then
    echo "ERROR: esto va como agentic, no como $(id -un)." >&2
    echo "       sudo -u agentic -H bash /tmp/agentic-box/ctl.sh $*" >&2
    exit 1
fi

export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
IMG=agentic-box

case "${1:-estado}" in
    estado)
        echo "== contenedor =="
        docker ps --filter "name=$IMG" --format 'table {{.Names}}\t{{.Status}}' || true
        docker ps -q --filter "name=$IMG" | grep -q . || echo "(no esta corriendo)"
        echo "== volumenes persistentes =="
        docker volume ls --filter name=agentic- --format 'table {{.Name}}\t{{.Driver}}'
        ;;
    stop)
        if docker ps -q --filter "name=$IMG" | grep -q .; then
            docker stop -t 10 "$IMG" && echo "detenido (los volumenes quedan intactos)"
        else
            echo "no estaba corriendo"
        fi
        ;;
    attach)
        exec docker attach "$IMG"
        ;;
    logs)
        docker logs --tail "${2:-50}" "$IMG"
        ;;
    limpiar)
        echo "Esto BORRA el login de Claude Code, las sesiones de OMP y el workspace."
        read -rp "Escribi 'si' para confirmar: " r
        [ "$r" = "si" ] || { echo "cancelado"; exit 0; }
        docker rm -f "$IMG" 2>/dev/null
        docker volume rm agentic-work agentic-claude agentic-omp
        ;;
    *)
        echo "uso: ctl.sh <estado|stop|attach|logs [N]|limpiar>" >&2
        exit 1
        ;;
esac

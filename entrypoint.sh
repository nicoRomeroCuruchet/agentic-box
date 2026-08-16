#!/bin/bash
# Arranca herdr con UN SOLO pane: Claude Code.
#
# Antes esto abria dos panes fijos — Claude a la izquierda y un OMP contra un
# modelo decidido al crear el contenedor. El modelo quedaba clavado en una
# variable de entorno, asi que cambiarlo obligaba a parar y recrear la caja.
#
# Ahora los agentes de modelo se levantan a pedido, desde adentro, con
# `spawn-model <alias>`. Claude Code puede llamarlo solo. Cada uno nace en su
# propio pane con su propio LLAMA_CPP_BASE_URL, asi que pueden convivir varios
# contra maquinas distintas de la tailnet.
#
# El layout se arma desde un subshell en segundo plano porque la API de socket de
# herdr recien responde una vez que el server esta levantado, y el server lo
# levanta el `herdr` del final (que se queda en primer plano con el TTY).
set -uo pipefail

SESSION="${HERDR_SESSION:-agentic}"

# El workspace es un volumen nombrado: Docker solo copia el contenido de la imagen
# cuando lo estrena vacio. En un volumen ya existente el CLAUDE.md queda congelado en
# la version del primer build, y el agente trabaja con instrucciones viejas sin que
# nada lo indique. Refrescamos desde la copia que vive fuera del volumen.
refresh_claude_md() {
    local origen=/usr/local/share/agentic-box/CLAUDE.md
    local destino=/home/agentic/workspace/CLAUDE.md
    [ -f "$origen" ] || return 0
    cmp -s "$origen" "$destino" 2>/dev/null && return 0
    # Si habia uno distinto, se conserva en vez de perderse.
    [ -f "$destino" ] && cp "$destino" "${destino}.anterior"
    cp "$origen" "$destino"
    echo "entrypoint: CLAUDE.md actualizado (el anterior quedo en CLAUDE.md.anterior)" >&2
}

setup_layout() {
    # 1. Esperar a que la API responda (el server tarda un par de segundos).
    for _ in $(seq 1 60); do
        herdr pane list >/dev/null 2>&1 && break
        sleep 1
    done
    if ! herdr pane list >/dev/null 2>&1; then
        echo "entrypoint: la API de herdr nunca respondio; layout sin armar" >&2
        return 1
    fi

    # 2. El unico pane que existe es el de Claude Code. No se parte nada mas:
    #    los panes de modelo los crea spawn-model cuando hagan falta.
    local p1
    p1=$(herdr pane list | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["panes"][0]["pane_id"])')

    # 3. Nombrar el pane. Por defecto herdr lo titula con el basename del cwd, que
    #    aca es siempre "workspace" (el WORKDIR de la imagen): sin esto, Claude y
    #    todos los modelos aparecen con el mismo nombre en pantalla.
    herdr pane rename "$p1" claude >/dev/null 2>&1 || true

    # 4. `agent start` espera a que el agente este listo para recibir input, asi
    #    que si devuelve ok el pane quedo utilizable.
    herdr agent start claude --kind claude --pane "$p1" >/dev/null

    echo "entrypoint: claude en $p1 — modelos locales a pedido con spawn-model" >&2
}

refresh_claude_md

setup_layout &

exec herdr --session "$SESSION"

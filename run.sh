#!/bin/bash
# Levanta la caja `agentic`: herdr con Claude Code, y modelos locales a pedido.
#
# Se corre COMO agentic:
#     sudo -u agentic -H bash ~/agentic-box/run.sh
#
# Es idempotente: se puede correr las veces que haga falta.
#
# Que cambio respecto de la version anterior: antes la caja apuntaba a UN modelo,
# fijado con LLM_HOST/LLM_MODEL al crear el contenedor, y cambiarlo obligaba a
# pararla y recrearla. Ahora lee models.conf y le da acceso a TODOS: el
# contenedor arranca solo con Claude Code, y adentro se levantan agentes con
# `spawn-model <alias>`.
set -euo pipefail

if [ "$(id -un)" != "agentic" ]; then
    echo "ERROR: esto va como agentic, no como $(id -un)." >&2
    echo "       sudo -u agentic -H bash ~/agentic-box/run.sh" >&2
    exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/agentic-box"
IMG=agentic-box

# Docker rootless de agentic, no el daemon del sistema.
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

if [ ! -S "${DOCKER_HOST#unix://}" ]; then
    echo "ERROR: no encuentro el socket de docker rootless en ${DOCKER_HOST#unix://}" >&2
    echo "       Arrancalo con: systemctl --user start docker" >&2
    exit 1
fi

# 1. Traer el contexto de build al home propio (por si se corre desde otro lado).
if [ "$SRC" != "$DST" ]; then
    echo "== copiando contexto a $DST =="
    mkdir -p "$DST"
    cp -r "$SRC"/. "$DST"/
fi
cd "$DST"

# 2. El registro de modelos.
REGISTRO="$DST/models.conf"
if [ ! -f "$REGISTRO" ]; then
    echo "ERROR: falta $REGISTRO" >&2
    echo "       cp $DST/models.conf.example $DST/models.conf  y poné los valores reales" >&2
    exit 1
fi

# alias base_url ip, sin comentarios ni lineas vacias
lineas() { grep -vE '^[[:space:]]*(#|$)' "$REGISTRO"; }

if [ -z "$(lineas)" ]; then
    echo "ERROR: $REGISTRO no tiene ninguna entrada valida" >&2
    exit 1
fi

# 3. Chequear cada modelo ANTES de construir nada. No es fatal que alguno este
#    caido — la caja sirve igual con los demas — pero conviene saberlo ahora y no
#    cuando spawn-model falle adentro.
echo "== modelos en $REGISTRO =="
ADDHOSTS=()
while read -r alias url ip; do
    host="${url#https://}"; host="${host#http://}"; host="${host%%/*}"
    # --add-host: adentro del contenedor no resuelve MagicDNS (el resolver de
    # Docker no conoce la tailnet). Fijando el nombre a la IP 100.x el TLS igual
    # valida, porque el certificado de `tailscale serve` es para ese mismo nombre.
    ADDHOSTS+=(--add-host "${host}:${ip}")
    if curl -sf -m 8 "$url/health" >/dev/null 2>&1; then
        servidos=$(curl -s -m 8 "$url/v1/models" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | tr '\n' ' ')
        # Que responda no alcanza: tiene que servir el alias que dice el registro,
        # porque es el que spawn-model le va a pedir a OMP.
        if grep -qw "$alias" <<<"$servidos"; then
            printf '   ok        %-14s %s\n' "$alias" "$url"
        else
            printf '   OJO       %-14s responde pero sirve [%s], no %s\n' "$alias" "${servidos% }" "$alias"
        fi
    else
        printf '   caido     %-14s %s\n' "$alias" "$url"
    fi
done < <(lineas)

# 4. Los binarios de los agentes. No estan versionados (GitHub no acepta
#    archivos de mas de 100 MB y claude pesa ~308), asi que deploy.sh los copia
#    desde el host. Sin ellos el build produce una imagen que arranca y no sirve.
for b in claude omp herdr; do
    if [ ! -x "$DST/bin/$b" ]; then
        echo "ERROR: falta $DST/bin/$b" >&2
        echo "       Corré deploy.sh desde el repo, que los copia desde ~/.local/bin." >&2
        exit 1
    fi
done

# 5. Construir.
echo "== build =="
docker build -t "$IMG" .

# 6. Token de Claude Code. El login por OAuth adentro del contenedor no es viable: hay
# que pegar a mano un codigo largo con formato `codigo#estado` en un pane de un TUI
# dentro de un TTY de docker, y el pegado se trunca — de ahi el
# "OAuth error: Invalid code". La solucion es generar el token AFUERA, en una terminal
# normal, con `claude setup-token`, y pasarlo por env.
#
# Se usa --env-file y no -e para que el token no aparezca en `ps`.
#
# ESTO VA ANTES del chequeo de "ya esta corriendo". Las variables de entorno se fijan
# al CREAR el contenedor: si ya hay uno andando sin token, adjuntarse no se lo agrega,
# y relanzar el script en loop no cambia nada. Hay que pararlo y recrearlo.
ENVFILE="$HOME/.config/agentic-box.env"
ENVARGS=()
if [ -f "$ENVFILE" ]; then
    ENVARGS=(--env-file "$ENVFILE")
    echo "== token tomado de $ENVFILE =="
else
    echo "AVISO: no existe $ENVFILE, Claude Code va a pedir login interactivo" >&2
    echo "       (y el pegado del codigo suele fallar). Para evitarlo:" >&2
    echo "         1. en una terminal normal, como vos:  claude setup-token" >&2
    echo "         2. sudo -u agentic -H mkdir -p /home/agentic/.config" >&2
    echo "         3. guardar en $ENVFILE la linea:  CLAUDE_CODE_OAUTH_TOKEN=<token>" >&2
    echo "         4. sudo -u agentic -H chmod 600 $ENVFILE" >&2
fi

# 7. Si ya hay una sesion corriendo, engancharse — salvo que ese contenedor se haya
#    creado sin el token. Adjuntarse no cambia ninguna variable: se fijan al crear.
#
#    Nota: el chequeo de "apunta a otra URL" que habia aca ya no hace falta. Antes
#    el contenedor tenia UN backend clavado en LLAMA_CPP_BASE_URL y adjuntarse a uno
#    viejo te dejaba hablando con el modelo equivocado sin aviso. Ahora la URL se
#    decide por agente al crear su pane, asi que un contenedor no puede quedar
#    "apuntado" a nada.
if docker ps --format '{{.Names}}' | grep -qx "$IMG"; then
    ENV_ACTUAL=$(docker inspect "$IMG" --format '{{range .Config.Env}}{{println .}}{{end}}')

    if [ ${#ENVARGS[@]} -gt 0 ] && ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' <<<"$ENV_ACTUAL"; then
        echo >&2
        echo "PARA: el contenedor que ya esta corriendo se creo SIN el token." >&2
        echo "      Las variables se fijan al crear el contenedor, asi que adjuntarse" >&2
        echo "      no lo va a loguear por mas veces que relances esto." >&2
        echo >&2
        echo "      Paralo y volve a levantar:" >&2
        echo "        bash $DST/ctl.sh stop && bash $DST/run.sh" >&2
        exit 1
    fi

    echo "== ya esta corriendo, adjuntando =="
    exec docker attach "$IMG"
fi

echo "== run — claude solo; modelos a pedido con spawn-model =="
# Los volumenes nombrados hacen que el login de Claude Code y las sesiones de OMP
# sobrevivan al reinicio del contenedor.
exec docker run -it --rm \
    --name "$IMG" \
    "${ADDHOSTS[@]}" \
    "${ENVARGS[@]}" \
    -v agentic-work:/home/agentic/workspace \
    -v agentic-claude:/home/agentic/.claude \
    -v agentic-omp:/home/agentic/.omp \
    "$IMG"

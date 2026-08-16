#!/bin/bash
# Diagnostico del token de Claude Code en la caja `agentic`.
#   sudo -u agentic -H bash /tmp/agentic-box/diag.sh
# No imprime el token: solo su longitud y prefijo, para poder compararlo sin exponerlo.
set -uo pipefail

if [ "$(id -un)" != "agentic" ]; then
    echo "ERROR: correlo como agentic:" >&2
    echo "  sudo -u agentic -H bash /tmp/agentic-box/diag.sh" >&2
    exit 1
fi

ENVFILE="$HOME/.config/agentic-box.env"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"

echo "=== 1. quien soy y donde ==="
echo "usuario : $(id -un)"
echo "HOME    : $HOME"
echo "buscando: $ENVFILE"

echo
echo "=== 2. el archivo de entorno ==="
if [ ! -f "$ENVFILE" ]; then
    echo "NO EXISTE. Esta es la causa: run.sh no tiene nada que inyectar."
    echo "Ojo con el HOME: si lo creaste sin el -H de sudo, puede haber quedado"
    echo "en /home/nromero/.config o en /root/.config en vez de /home/agentic/.config."
    ls -la /home/agentic/.config/ 2>&1 | head -5
else
    echo "existe. permisos: $(stat -c '%A %U:%G' "$ENVFILE")"
    echo "lineas: $(wc -l < "$ENVFILE")"
    # Mostrar la forma sin revelar el valor.
    while IFS= read -r linea; do
        clave="${linea%%=*}"
        valor="${linea#*=}"
        echo "  clave='$clave'  largo_valor=${#valor}  empieza_con='${valor:0:12}'"
        case "$valor" in
            \"*|\'*) echo "  >> PROBLEMA: el valor tiene comillas. docker --env-file NO las quita," \
                          "quedan dentro del token. Sacalas." ;;
        esac
        case "$clave" in
            CLAUDE_CODE_OAUTH_TOKEN) ;;
            *) echo "  >> PROBLEMA: la clave deberia ser exactamente CLAUDE_CODE_OAUTH_TOKEN" ;;
        esac
    done < "$ENVFILE"
    echo "  (un token de setup-token empieza con 'sk-ant-oat' y es largo, >60)"
fi

echo
echo "=== 3. docker rootless ==="
docker version --format '{{.Server.Version}}' 2>&1 | head -1

echo
echo "=== 4. que ve claude adentro del contenedor ==="
if [ -f "$ENVFILE" ] && docker image inspect agentic-box >/dev/null 2>&1; then
    docker run --rm --env-file "$ENVFILE" --entrypoint bash agentic-box -c '
        echo "variable presente: $([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo si || echo NO)"
        echo "largo: ${#CLAUDE_CODE_OAUTH_TOKEN}"
        claude auth status 2>&1 | head -8'
else
    echo "salteado (falta el archivo o la imagen agentic-box todavia no se construyo)"
fi

echo
echo "=== 5. el volumen puede estar pisando la config ==="
docker run --rm -v agentic-claude:/c --entrypoint bash agentic-box -c \
    'ls -la /c 2>/dev/null | head -10' 2>/dev/null \
    || echo "(sin volumen todavia)"

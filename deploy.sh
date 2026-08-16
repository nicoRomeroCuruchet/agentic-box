#!/bin/bash
# Copia este repo a /home/agentic/agentic-box, que es donde la caja se construye
# y corre.
#
#     ./deploy.sh            copiar y listo
#     ./deploy.sh --run      copiar y levantar
#
# Existe porque el repo y el deployment viven en lugares distintos a proposito:
#
#   ~/Documents/agentic-box     el repo — editable por vos, versionado
#   /home/agentic/agentic-box   el deployment — corre como otro usuario, 750,
#                               inaccesible desde tu cuenta
#
# Esa separacion es el aislamiento de la caja y no hay que "arreglarla". Este
# script es el unico puente, y necesita sudo por eso.
set -euo pipefail

# --- Quien corre esto -------------------------------------------------------
# Tu cuenta normal, la que tiene sudo. NO con `sudo ./deploy.sh` y NO como
# agentic. El script llama a sudo donde hace falta; corriendo el script entero
# como root, $HOME pasa a ser /root y los binarios se buscan en
# /root/.local/bin, que no existe. El error que da es confuso, asi que mejor
# frenar aca.
if [ "$(id -u)" = 0 ]; then
    echo "ERROR: no corras esto con sudo ni como root." >&2
    echo "       Corrélo como vos: ./deploy.sh" >&2
    echo "       El script ya usa sudo donde lo necesita." >&2
    exit 1
fi
if [ "$(id -un)" = agentic ]; then
    echo "ERROR: esto va desde tu cuenta, no como agentic." >&2
    echo "       agentic no tiene sudo y no puede leer el repo." >&2
    exit 1
fi

REPO="$(cd "$(dirname "$0")" && pwd)"
DST=/home/agentic/agentic-box
BINSRC="${BINSRC:-$HOME/.local/bin}"

# --- El docker rootless de agentic tiene que poder sobrevivir --------------
# Sin linger, systemd mata la sesion de usuario de agentic cuando no queda
# ninguna sesion suya abierta — que es siempre, porque nadie hace login como
# agentic. Con la sesion muerta no hay dockerd, no hay socket, y run.sh falla
# con "no encuentro el socket". Es la pieza mas fragil del montaje y no da
# ningun sintoma hasta el primer reboot.
if [ "$(loginctl show-user agentic -p Linger --value 2>/dev/null)" != "yes" ]; then
    echo "AVISO: el usuario agentic NO tiene linger activado." >&2
    echo "       Su docker rootless se va a morir en el proximo logout o reboot." >&2
    echo "       Activalo una sola vez con:" >&2
    echo "         sudo loginctl enable-linger agentic" >&2
    echo >&2
fi

echo "== origen  : $REPO"
echo "== destino : $DST"

# 1. Los binarios de los agentes. No se versionan: GitHub rechaza archivos de mas
#    de 100 MB y claude pesa ~308. Se copian del host en cada deploy, que ademas
#    mantiene la caja al dia con la version que usas vos.
echo "== binarios desde $BINSRC =="
faltan=0
for b in claude omp herdr; do
    if [ -x "$BINSRC/$b" ]; then
        # stat -L, con dereferencia: `claude` suele ser un symlink a
        # ~/.local/share/claude/versions/<version>, y sin -L stat reporta los ~50
        # bytes del link en vez de los ~320 MB del binario. `cp` si sigue el
        # symlink, asi que la copia estaba bien y el numero era el equivocado.
        printf '   ok    %-8s %6.1f MB\n' "$b" "$(stat -Lc %s "$BINSRC/$b" | awk '{print $1/1048576}')"
    else
        echo "   FALTA $b en $BINSRC" >&2
        faltan=1
    fi
done
if [ "$faltan" = 1 ]; then
    echo "ERROR: sin esos binarios la imagen se construye pero no sirve." >&2
    echo "       Si los tenes en otro lado: BINSRC=/ruta ./deploy.sh" >&2
    exit 1
fi

mkdir -p "$REPO/bin"
cp "$BINSRC"/claude "$BINSRC"/omp "$BINSRC"/herdr "$REPO/bin/"

# 2. El registro con los valores reales.
if [ ! -f "$REPO/models.conf" ]; then
    echo "ERROR: falta $REPO/models.conf" >&2
    echo "       cp models.conf.example models.conf  y completalo" >&2
    exit 1
fi

# 3. Copiar. `cp -r` sobre lo que ya esta: no se borra nada del destino, se pisa
#    lo que coincide. Los volumenes de Docker (workspace, login, sesiones) no
#    viven aca, asi que esto no toca ningun estado.
echo "== copiando =="
sudo install -d -o agentic -g agentic -m 755 "$DST"
sudo cp -r "$REPO"/. "$DST"/
sudo rm -rf "$DST/.git"          # el repo no tiene por que viajar al deployment
sudo chown -R agentic:agentic "$DST"
sudo chmod +x "$DST"/*.sh "$DST"/bin/* "$DST"/bin-tools/*

echo "== listo =="
sudo ls -la "$DST" | sed 's/^/   /'

if [ "${1:-}" = "--run" ]; then
    echo
    echo "== levantando =="
    echo "   OJO: herdr es un TUI de pantalla completa y necesita un TTY real."
    echo "   Si esto se ve roto, corrélo desde Konsole o Ghostty, no desde un agente."
    exec sudo -u agentic -H bash "$DST/run.sh"
else
    echo
    echo "Para levantarla:"
    echo "   sudo -u agentic -H bash $DST/run.sh"
fi

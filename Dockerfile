# Caja aislada para el usuario `agentic`: herdr con un pane de Claude Code, que
# puede levantar agentes OMP contra los llama.cpp de la tailnet listados en
# models.conf. Ningun modelo queda fijado en la imagen ni en el contenedor: cada
# agente nace con su propia URL cuando spawn-model le crea el pane.
#
# Base 26.04 a proposito: los binarios se copian desde `personal`, que es 26.04.
# Con una base mas vieja (24.04) el glibc no alcanza y omp/claude no arrancan.
FROM ubuntu:26.04

# build-essential va aunque parezca de mas: `uv` instala wheels, pero cuando un
# paquete no publica wheel para esta version de Python cae a compilar desde fuente
# y sin compilador el install muere. Con `uv` solo, los agentes se traban seguido.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git python3 ripgrep less procps nano vim-tiny \
        build-essential jq \
    && rm -rf /var/lib/apt/lists/*

# Mismo uid/gid que el `agentic` del host: los bind mounts conservan el dueño.
ARG UID=1001
ARG GID=1001
RUN groupadd -g ${GID} agentic \
    && useradd -m -u ${UID} -g ${GID} -s /bin/bash agentic

COPY --chown=agentic:agentic bin/ /home/agentic/.local/bin/
COPY --chown=agentic:agentic workspace/CLAUDE.md /home/agentic/workspace/CLAUDE.md
# Segunda copia FUERA del volumen, a proposito. /home/agentic/workspace es un volumen
# nombrado, y Docker solo siembra un volumen cuando lo estrena vacio: si ya existe,
# el COPY de arriba no llega nunca al contenedor y el agente sigue leyendo un
# CLAUDE.md viejo sin que nada avise. El entrypoint refresca desde esta ruta.
COPY --chown=agentic:agentic workspace/CLAUDE.md /usr/local/share/agentic-box/CLAUDE.md
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Las herramientas que Claude Code usa desde adentro para levantar y bajar
# agentes de modelo. Van al PATH, junto a los binarios de los agentes.
COPY --chown=agentic:agentic bin-tools/ /home/agentic/.local/bin/

# El registro de modelos. Fuera del volumen del workspace, porque un volumen
# nombrado ya existente no se re-siembra desde la imagen y quedaria congelado.
COPY models.conf /usr/local/share/agentic-box/models.conf

RUN chmod +x /usr/local/bin/entrypoint.sh /home/agentic/.local/bin/*

USER agentic
WORKDIR /home/agentic/workspace

# ~/.claude tiene que EXISTIR en la imagen y ser de agentic. Docker, al estrenar un
# volumen nombrado, copia el contenido y el dueño de esa ruta en la imagen; si la ruta
# no existe crea el directorio vacio como root, y el proceso de adentro (uid 1001) se
# queda sin poder escribir su propia config. Sintoma: Claude Code no persiste nada.
RUN mkdir -p /home/agentic/.claude
ENV PATH=/home/agentic/.local/bin:$PATH
ENV HOME=/home/agentic

# Imprescindible. Con una sesion nombrada, herdr pone su socket en
# ~/.config/herdr/sessions/<nombre>/herdr.sock, pero la CLI por defecto busca en
# ~/.config/herdr/herdr.sock y responde "server_not_running". Con esta variable
# todas las llamadas (incluidas las que haga Claude Code) apuntan a la sesion buena.
ENV HERDR_SESSION=agentic

# NO se define LLAMA_CPP_BASE_URL a nivel imagen, a proposito.
#
# Antes estaba, y era el unico backend posible para toda la caja. Ahora cada
# agente OMP nace en su propio pane con su propia URL, que le pone spawn-model
# con `herdr pane split --env`. Una variable global aca solo serviria para que un
# OMP arrancado a mano, fuera de spawn-model, apunte a algun lado en silencio —
# que es exactamente el modo de fallar que queremos evitar.

# Sin esto, OMP arranca con el asistente de login y se queda pidiendo un proveedor
# ("Login failed: token_expired"). Cualquier prompt que le mande Claude Code cae en
# el buscador del wizard en vez de ir al modelo. El modelo es local y no necesita
# ninguna cuenta, asi que el wizard sobra.
RUN omp config set startup.setupWizard false \
    && omp config set setupVersion 1

# uv como gestor de Python, igual que en el host. Se instala solo en ~/.local/bin,
# que ya esta en el PATH. UV_LINK_MODE=copy evita los avisos de hardlink cuando el
# cache y el destino caen en volumenes distintos.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV UV_LINK_MODE=copy

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

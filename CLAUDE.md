# CLAUDE.md

Guía para Claude Code trabajando **en este repositorio**.

Ojo con la ambigüedad: hay dos `CLAUDE.md` acá y son para dos audiencias distintas.

| | |
|---|---|
| `CLAUDE.md` (este) | para vos, si estás editando el repo desde el host |
| `workspace/CLAUDE.md` | va **adentro** de la imagen; lo lee el Claude Code que corre en la caja |

Si te piden "cambiar las instrucciones del agente", casi siempre es el segundo.

## Qué es esto

Un contenedor Docker rootless donde Claude Code orquesta agentes OMP contra servidores
llama.cpp de la tailnet. No hay código de aplicación: es un Dockerfile, cuatro scripts de
operación, dos herramientas que van adentro de la imagen y la documentación.

Los servidores de modelos son otro repo,
[llamacpp-compose](https://github.com/nicoRomeroCuruchet/llamacpp-compose). **Este depende
de aquel**: si un modelo no responde, el problema casi siempre está del otro lado.

## Layout

```
Dockerfile                 la imagen
entrypoint.sh              arranca herdr con UN pane (Claude Code) y nada mas
run.sh                     build + run; lee models.conf y arma los --add-host
ctl.sh                     estado | stop | attach | logs | limpiar
diag.sh                    diagnostico del token de Claude Code
deploy.sh                  copia el repo a /home/agentic/agentic-box (el unico puente)
models.conf                registro de modelos — GITIGNOREADO, tiene la tailnet
models.conf.example        la referencia versionada
bin-tools/spawn-model      levanta un OMP en un pane nuevo con su propia URL
bin-tools/close-model      lo baja y cierra el pane
bin/                       binarios de claude/omp/herdr — GITIGNOREADO, ~500 MB
workspace/CLAUDE.md        instrucciones para el agente de adentro
README.md                  documentacion completa
```

## Las tres identidades

Antes de sugerir cualquier comando, resolvé **como quién se corre**. Es la causa más común
de errores acá.

| Identidad | Corre | Privilegios |
|---|---|---|
| el usuario (uid 1000) | `deploy.sh` | sudo, grupo `docker` |
| `agentic` (uid 1001) | `run.sh`, `ctl.sh`, `diag.sh` | ninguno: sin sudo, sin grupo `docker`, daemon rootless propio |
| `agentic` en el contenedor | `claude`, `omp`, `herdr` | ninguno; la imagen no trae `ssh` ni `docker` |

- `deploy.sh` **sin** `sudo` — llama a sudo por dentro. Con `sudo ./deploy.sh`, `$HOME` es
  `/root` y busca los binarios donde no están. El script se planta si sos root.
- `run.sh` / `ctl.sh` / `diag.sh` **con** `sudo -u agentic -H`. El `-H` es obligatorio: sin
  él `$HOME` sigue siendo el del usuario y el token termina en el `.config` equivocado.
- **`agentic` no puede leer el home del usuario** por ningún camino, y es intencional. No
  propongas `chmod`, ni bind mounts, ni `--privileged` para saltearlo.

**`loginctl enable-linger agentic` es obligatorio y no es obvio.** Sin linger, systemd baja
la sesión de usuario de `agentic` (nadie hace login como él), y con ella el `dockerd`
rootless. Síntoma: `run.sh` dice "no encuentro el socket", pero recién después de un
reboot. `deploy.sh` lo chequea y avisa.

## Reglas

**El repo y el deployment son dos lugares distintos, a propósito.** El código corre en
`/home/agentic/agentic-box`, que está en 750 y **no podés leer desde tu cuenta**. Eso es el
aislamiento de la caja: no lo "arregles" con un `chmod`. Para ver qué hay desplegado, o
para desplegar, se pasa por `deploy.sh`, que usa `sudo`.

**`bin/` no se versiona.** `claude` pesa ~308 MB y `omp` ~170, y GitHub rechaza archivos de
más de 100 MB. `deploy.sh` los copia desde `~/.local/bin` del host en cada deploy. Si
proponés versionarlos, el push va a fallar.

**`models.conf` no se versiona.** Tiene el nombre de la tailnet y las IPs `100.x`. Toda
variable nueva se espeja en `models.conf.example` con su comentario, o nadie más puede
reproducir el setup.

**El idioma del repo es español rioplatense**, incluidos comentarios y mensajes de commit.
Es distinto de `llamacpp-compose`, que es todo en inglés. No los mezcles.

**No borres volúmenes.** `agentic-claude` tiene el login, `agentic-omp` las sesiones,
`agentic-work` el workspace. `ctl.sh limpiar` es lo único destructivo y pregunta antes.
Un `docker volume rm` a mano pierde el login y hay que rehacer el token.

**Levantar la caja necesita un TTY real.** herdr es un TUI de pantalla completa: no
funciona desde el `!` de Claude Code ni desde un subproceso. Pedile al usuario que la
levante desde Konsole o Ghostty.

## Verificar un cambio

Que `docker build` termine bien no dice casi nada: la imagen puede construir y la caja
arrancar sin modelo, sin token o con el `CLAUDE.md` viejo.

```bash
bash -n entrypoint.sh run.sh ctl.sh deploy.sh bin-tools/*   # sintaxis
./deploy.sh                                                 # sin --run, solo copia
sudo -u agentic -H bash /home/agentic/agentic-box/diag.sh   # el token de verdad
```

Y adentro de la caja, lo que confirma que el diseño funciona:

```bash
spawn-model --list        # tiene que decir el estado real de cada server
spawn-model <alias>       # tiene que crear el pane Y arrancar OMP ahi
```

## Trampas

- **herdr titula los panes con el basename del `cwd`.** Como el `WORKDIR` de la imagen es
  `/home/agentic/workspace`, sin intervencion TODOS los panes se llaman `workspace` y no se
  distinguen en pantalla. No hay clave de config para el titulo (`herdr config` solo tiene
  `check` y `reset-keys`) ni flag en `pane split`: se arregla con
  `herdr pane rename <PANE_ID> <LABEL>` despues de crear el pane. `spawn-model` y
  `entrypoint.sh` ya lo hacen.
- **Las variables de entorno se fijan al CREAR el contenedor.** Adjuntarse a uno que ya
  corre no cambia ninguna. Si algo depende de una variable nueva, hay que `ctl.sh stop` y
  recrear — no alcanza con relanzar `run.sh`.
- **`herdr agent start` no acepta `--env`; `herdr pane split` sí.** De ahí sale todo el
  diseño de `spawn-model`. Si alguna vez parece más simple arrancar el agente y después
  configurarlo, no lo es: no hay dónde poner la variable.
- **Un volumen nombrado solo se siembra desde la imagen cuando se estrena vacío.** Por eso
  `workspace/CLAUDE.md` se copia dos veces en el Dockerfile y el entrypoint refresca desde
  la copia de afuera. Si sacás esa segunda copia, el agente vuelve a leer instrucciones
  viejas sin que nada avise.
- **`sh` no expande llaves.** `sudo sh -c 'cp a{1,2} dst'` copia cero archivos y sale bien.
  Usá `bash -c` o lista explícita.
- **Los globs los expande el shell que los escribe, no el que los ejecuta.** Este es el
  mismo error que el anterior, generalizado, y acá muerde seguido porque hay un límite de
  privilegios en el medio:

  ```bash
  sudo chmod +x /home/agentic/agentic-box/*.sh          # MAL
  sudo bash -c 'chmod +x /home/agentic/agentic-box/*.sh' # BIEN
  ```

  El primero lo expande tu shell, que no puede leer `/home/agentic` (750): no matchea
  nada, pasa el literal, y `chmod` se queja de un archivo llamado `*.sh`. Con `set -e` eso
  aborta el script. **Regla: si la ruta está del otro lado del límite de permisos, el glob
  va adentro de `sudo bash -c`.**

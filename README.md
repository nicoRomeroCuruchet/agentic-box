# agentic-box

Una caja aislada donde **Claude Code maneja agentes de modelos locales**.

Corre en un contenedor Docker rootless, como un usuario sin privilegios, con
[herdr](https://github.com/) orquestando panes. Claude Code arranca solo; a pedido levanta
agentes [OMP](https://github.com/) contra los servidores llama.cpp de la tailnet, cada uno
en su propio pane. Vos le hablas a Claude; Claude le habla a los modelos.

```
┌──────────────────────┬──────────────────────┐
│                      │                      │
│     Claude Code      │   qwen38-27b (OMP)   │   spawn-model qwen38-27b
│                      │   -> udesa, 3090     │
│   spawn-model ...    ├──────────────────────┤
│   herdr agent prompt │   ornith-35b (OMP)   │   spawn-model ornith-35b
│   herdr agent read   │   -> a1554, 4090     │
│                      │                      │
└──────────────────────┴──────────────────────┘
        contenedor rootless, usuario agentic, sin ssh ni docker adentro
```

Los servidores se levantan con [llamacpp-compose](https://github.com/nicoRomeroCuruchet/llamacpp-compose),
que es de donde salen los modelos y las mediciones que se citan acá.

---

## Por qué

Delegar a un modelo local no cuesta tokens de API y no saca los datos de la tailnet. Pero
copiar y pegar entre dos terminales lo vuelve inutilizable. Acá Claude maneja el otro pane
por la API de socket de herdr: le manda la consigna, espera, lee la respuesta y sigue.

El aislamiento no es decorativo. El usuario `agentic` **no tiene sudo, no está en el grupo
`docker`, corre su propio daemon rootless y no puede leer `/home/nromero`** — ni por
permisos, ni montándolo en un contenedor. La imagen tampoco trae `ssh` ni `docker`, así que
los agentes de adentro no pueden saltar a otras máquinas.

---

## Arrancar

```bash
git clone git@github.com:nicoRomeroCuruchet/agentic-box.git
cd agentic-box

cp models.conf.example models.conf
$EDITOR models.conf              # alias, URL e IP 100.x de cada modelo

./deploy.sh --run                # copia a /home/agentic/ y levanta
```

`deploy.sh` copia los binarios de los agentes desde tu `~/.local/bin` — **no están
versionados**, porque `claude` pesa ~308 MB y GitHub rechaza archivos de más de 100 MB.

**Levantalo desde una terminal de verdad** (Konsole, Ghostty). herdr es un TUI de pantalla
completa y necesita un TTY real; desde adentro de un agente se ve roto.

### Operación

```bash
sudo -u agentic -H bash /home/agentic/agentic-box/ctl.sh estado
sudo -u agentic -H bash /home/agentic/agentic-box/ctl.sh attach
sudo -u agentic -H bash /home/agentic/agentic-box/ctl.sh stop
sudo -u agentic -H bash /home/agentic/agentic-box/diag.sh     # diagnostico del token
```

`Ctrl+P` `Ctrl+Q` desengancha sin bajarla.

---

## Adentro: levantar modelos

Esto lo corre Claude Code solo, pero también sirve a mano:

```bash
spawn-model --list          # qué hay y si está arriba
spawn-model                 # el primero de models.conf
spawn-model ornith-35b      # uno en particular
close-model ornith-35b
close-model --all
```

Podés tener **varios modelos a la vez**, contra máquinas distintas.

### Cómo funciona, y por qué así

Cada modelo vive en otra máquina, así que cada OMP necesita su propio
`LLAMA_CPP_BASE_URL`. `herdr agent start` **no** acepta `--env`; `herdr pane split`
**sí**. Entonces `spawn-model` le pone el entorno al pane y el agente lo hereda al
arrancar ahí.

Esa es toda la idea. Lo que reemplaza es el diseño anterior, donde la caja tenía un solo
backend fijado con `-e LLAMA_CPP_BASE_URL` al crear el contenedor: cambiar de modelo
obligaba a parar y recrear la caja, porque **las variables de entorno se fijan al crear el
contenedor** y adjuntarse no las cambia.

`models.conf` es el registro. La IP `100.x` de cada nodo no es opcional: adentro del
contenedor no resuelve MagicDNS, porque el resolver de Docker no conoce la tailnet.
`run.sh` arma un `--add-host` por entrada. El TLS igual valida, porque el certificado de
`tailscale serve` es para ese mismo nombre.

---

## El repo y el deployment son dos lugares

```
~/Documents/agentic-box     el repo — versionado, editable por vos
/home/agentic/agentic-box   el deployment — otro usuario, 750, inaccesible desde tu cuenta
```

Esa separación **es** el aislamiento y no hay que arreglarla. `deploy.sh` es el único
puente, y necesita `sudo` por eso. El repo manda: editás acá, desplegás allá.

El estado vive en tres volúmenes nombrados — `agentic-claude` (login), `agentic-omp`
(sesiones), `agentic-work` (workspace) — que sobreviven a `stop` y a `deploy.sh`. Solo
`ctl.sh limpiar` los borra, y pregunta antes.

---

## Autenticación: por token, nunca interactiva

**El login OAuth adentro del contenedor no funciona.** El código tiene formato
`codigo#estado` y hay que pegarlo en un TUI, dentro de un TTY de docker, dentro de un pane
de herdr; el pegado se trunca y sale `OAuth error: Invalid code`. Se genera afuera:

```bash
claude setup-token                    # en una terminal normal, como vos
read -rsp "Pega el token: " TOK && echo
( umask 077; printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK" > /tmp/tok.env )
unset TOK
sudo -u agentic -H mkdir -p /home/agentic/.config
sudo install -o agentic -g agentic -m 600 /tmp/tok.env /home/agentic/.config/agentic-box.env
shred -u /tmp/tok.env
```

`run.sh` lo levanta con `--env-file` y no con `-e`, para que el token no salga en `ps`.

---

## Trampas que ya costaron tiempo

- **No le pases el token a `sudo` por stdin.** Un `sudo ... <<< "TOKEN=..."` hace que
  `sudo` se coma el token como intento de contraseña y el archivo quede vacío.
- **`claude auth status` NO valida el token.** Devuelve `loggedIn: true` con cualquier
  cosa; solo mira si la variable existe. La única prueba real es una llamada:
  `claude -p "responde solo: OK"`. `diag.sh` ya la hace.
- **Las variables se fijan al CREAR el contenedor.** Si hay uno corriendo sin token,
  adjuntarse no se lo agrega y relanzar el script no cambia nada — hay que `ctl.sh stop` y
  recrear. `run.sh` detecta este caso y se planta en vez de engancharte en silencio.
- **Todo directorio montado como volumen tiene que existir en la imagen.** Docker, al
  estrenar un volumen nombrado sobre una ruta inexistente, la crea vacía **como root**, y
  el proceso de adentro (uid 1001) no puede escribir. Pasó con `~/.claude`.
- **Un volumen nombrado ya existente no se re-siembra desde la imagen.** El `CLAUDE.md`
  del workspace quedaba congelado en la versión del primer build. Por eso hay una segunda
  copia fuera del volumen y el entrypoint refresca desde ahí.
- **`HERDR_SESSION` es imprescindible.** Con sesión nombrada herdr pone su socket en
  `~/.config/herdr/sessions/<nombre>/`, pero la CLI busca en `~/.config/herdr/herdr.sock`
  y responde `server_not_running`.
- **`herdr agent read` necesita `--source visible`.** El default (`recent`) suele volver
  vacío, y parece que el agente se colgó.
- **Base Ubuntu 26.04 a propósito.** Los binarios se copian del host, que es 26.04; con
  una base más vieja el glibc no alcanza y `omp`/`claude` no arrancan.

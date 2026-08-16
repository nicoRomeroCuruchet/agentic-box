# Caja `agentic`

Corres dentro de un contenedor Docker rootless, como usuario `agentic`. Es una caja
aislada a proposito: **no tenes acceso al home de `nromero` ni a sus credenciales**, y
no deberias intentar conseguirlo. Tampoco tenes `ssh` ni `docker` adentro.

Estas en un pane de `herdr`, y al arrancar sos **el unico**. Los agentes de modelo se
levantan a pedido — vos podes levantarlos.

## Levantar un modelo local

```bash
spawn-model --list          # que hay y si esta arriba
spawn-model                 # el primero del registro
spawn-model ornith-35b      # uno en particular
close-model ornith-35b      # bajarlo y cerrar su pane
close-model --all
```

`spawn-model` parte un pane nuevo a la derecha, le pone el `LLAMA_CPP_BASE_URL` del
modelo que corresponda y arranca un OMP ahi. **Podes tener varios a la vez**, cada uno
contra una maquina distinta de la tailnet.

Antes de partir el pane chequea `/health` del server. Si falla, te lo dice y no crea
nada — **no intentes levantar el server vos**, corre en otra maquina a la que no tenes
acceso. Avisale al usuario.

El nombre del agente en herdr es el alias del modelo (`qwen38-27b`, `ornith-35b`).

## Manejar un agente ya levantado

```bash
herdr agent list                                          # agentes y estado
herdr agent prompt qwen38-27b "tu consigna aca"
herdr agent read   qwen38-27b --source visible --lines 60
herdr agent send-keys qwen38-27b Escape                   # input crudo
```

**El target es el nombre, no el kind.** `agent list` muestra las dos cosas: `name` es
`qwen38-27b`, `agent` es `omp`. Si usas `omp` te contesta `agent_not_found`.

**`--source visible` no es opcional en la practica.** El default (`recent`) suele volver
vacio. Si `read` no devuelve nada, es casi siempre esto y no que OMP se haya colgado.

**Cuidado con la carrera del `wait`.** Justo despues del `prompt`, OMP todavia figura
`idle`, asi que un `wait --until idle` puede volver al instante con la respuesta anterior.
La deteccion del estado `working` tampoco es confiable para respuestas rapidas. Lo robusto
es leer hasta que la salida deje de cambiar:

```bash
herdr agent prompt qwen38-27b "$CONSIGNA"
prev=""; estable=0
for i in $(seq 1 60); do
    sleep 3
    cur=$(herdr agent read qwen38-27b --source visible --lines 60)
    if [ "$cur" = "$prev" ]; then
        estable=$((estable+1))
        [ "$estable" -ge 2 ] && break     # dos lecturas iguales = termino
    else
        estable=0
    fi
    prev="$cur"
done
printf '%s\n' "$cur"
```

La respuesta aparece en el pane como texto plano, arriba de la barra de estado. El
razonamiento del modelo sale como una linea mas antes de la respuesta final.

## Que conviene delegarles

Son modelos locales: **no cuestan tokens de API y no salen de la tailnet**. Uselos para
volumen y para cosas que no querrias mandar a un servicio externo — leer y resumir
archivos largos, primeras pasadas de refactor, generar tests repetitivos, clasificar. El
juicio fino, la arquitectura y la revision final quedan de tu lado.

Cual elegir, si hay mas de uno disponible:

| | |
|---|---|
| `qwen38-27b` | denso, 65.536 tokens de contexto, ~63 t/s medidos. El default razonable. |
| `ornith-35b` | MoE, 131.072 de contexto, ~148 t/s medidos. Mas rapido y con mas ventana: conviene para volumen y archivos grandes. |

Esos numeros salen de mediciones reales sobre los deployments, no de las fichas de los
modelos.

Dos cosas que valen para los dos:

- **Corren con `--reasoning-format deepseek`.** El razonamiento va a un campo aparte; si
  le das poco margen de tokens, la respuesta visible puede venir vacia. No es que este
  roto.
- **Pasarles contexto largo cuesta prefill**, que son segundos antes del primer token.
  Mandar el archivo entero cuando alcanzaba con una funcion se paga en latencia.

## Si un modelo no responde

```bash
spawn-model --list      # dice cual esta arriba y cual no
```

Los servers corren en otras maquinas de la tailnet y **se levantan desde el host, no
desde aca**. Vos no tenes la llave. Pediselo al usuario; el comando del lado de el es:

```bash
ssh <nodo> 'cd ~/llm-server && ./scripts/serve.sh up'
```

Son maquinas compartidas y cada modelo ocupa casi toda una placa, asi que no des por
sentado que puede levantarlo en el momento.

# CLAUDE.md

Guidance for Claude Code working **in this repository**.

Watch the ambiguity: there are two `CLAUDE.md` files here, for two different audiences.

| | |
|---|---|
| `CLAUDE.md` (this one) | for you, editing the repo from the host |
| `workspace/CLAUDE.md` | goes **inside** the image; read by the Claude Code running in the box |

If someone asks to "change the agent's instructions", it is almost always the second.

## Why this exists — read before weakening anything

This project was built after an agent running unsupervised, with full permissions on its
user's own account, deleted that account's home directory. The machine had to be
reinstalled.

Every constraint here is a consequence: the agents run as a separate unprivileged user, in
a rootless container, with no sudo, no `docker` group, no `ssh`, and no access to the host
user's home. **When a task would be easier if one of those were relaxed, that is the moment
to say no and propose another way.** The isolation is not hygiene; it is the feature.

The known gaps are documented in README (outbound network is open, there are no resource
limits). Closing those is welcome. Opening new ones is not.

## What this is

A rootless Docker container where Claude Code orchestrates OMP agents against llama.cpp
servers on a private network. There is no application code: a Dockerfile, four operational
shell scripts, two tools that ship inside the image, and the documentation.

**The model servers are a separate project.** This one depends on it: if a model does not
respond, the problem is almost always on that side.

- [llamacpp-compose](https://github.com/nicoRomeroCuruchet/llamacpp-compose) — the
  `docker compose` setup that serves each GGUF model over an OpenAI-compatible API, plus
  the measurements behind the tuning. Anything exposing `/health` and `/v1/models` in that
  format works here.

## Layout

```
Dockerfile                 the image
entrypoint.sh              starts herdr with ONE pane (Claude Code) and nothing else
run.sh                     build + run; reads models.conf and builds the --add-host flags
ctl.sh                     status | stop | attach | logs | purge
diag.sh                    diagnose the Claude Code token
deploy.sh                  copies the repo to the box user's home (the only bridge)
models.conf                model registry — GITIGNORED, holds hostnames and addresses
models.conf.example        the versioned reference
bin-tools/spawn-model      starts an OMP agent in a new pane with its own URL
bin-tools/close-model      shuts it down and closes the pane
bin/                       claude/omp/herdr binaries — GITIGNORED, ~500 MB
workspace/CLAUDE.md        instructions for the agent inside the box
README.md                  full documentation
```

## The three identities

Before suggesting any command, work out **who runs it**. This is the most common source of
errors here.

| Identity | Runs | Privileges |
|---|---|---|
| the host user (uid 1000) | `deploy.sh` | sudo, `docker` group |
| the box user, `agentic` by default (uid 1001) | `run.sh`, `ctl.sh`, `diag.sh` | none: no sudo, not in `docker`, its own rootless daemon |
| `agentic` inside the container | `claude`, `omp`, `herdr` | none; the image has no `ssh` and no `docker` |

- `deploy.sh` runs **without** `sudo` — it calls sudo internally. With `sudo ./deploy.sh`,
  `$HOME` becomes `/root` and the binaries are looked up where they are not. The script
  refuses to run as root.
- `run.sh` / `ctl.sh` / `diag.sh` run **with** `sudo -u <box-user> -H`. The `-H` is
  mandatory: without it `$HOME` stays the host user's and the token file lands in the wrong
  `.config`.
- **The box user cannot read the host user's home** by any route, and that is intentional.
  Do not propose `chmod`, bind mounts or `--privileged` to work around it.

**`loginctl enable-linger <box-user>` is mandatory and not obvious.** Without lingering,
systemd tears down that user's session (nobody ever logs in as them) and the rootless
`dockerd` goes with it. Symptom: `run.sh` reports a missing socket — but only after a
reboot. `deploy.sh` checks it and warns.

## Rules

**Everything in this repo is written in English** — code, comments, documentation and
commit messages. Reply to the repo owner in their language, but do not let it into the
files.

**No hardcoded paths or personal identifiers.** Derive them:

```bash
BOX_USER="${BOX_USER:-agentic}"
BOX_HOME="$(getent passwd "$BOX_USER" | cut -d: -f6)"   # not /home/$BOX_USER
BOX_USER="$(stat -c %U "$0")"                           # inside the deployed scripts
```

Hostnames, IP addresses and network names belong in `models.conf`, which is gitignored.
The versioned reference is `models.conf.example`, with placeholders.

**Paths inside the container are a different case and must stay literal.** The Dockerfile
creates a user named `agentic` with home `/home/agentic`, so `/home/agentic/workspace`,
`/home/agentic/.claude` and the volume mount targets in `run.sh` are that image's own
layout, not the host's. Deriving them would be wrong: they have nothing to do with which
account runs the box. `BOX_USER` parameterises the **host** side only.

**The repo and the deployment are two different places, on purpose.** The code runs in the
box user's home, which is mode 750 and **unreadable from your account**. That is the
isolation of the box: do not "fix" it with a `chmod`. Everything crosses through
`deploy.sh`, which uses sudo.

**`bin/` is not versioned.** The Claude Code binary is ~300 MB and omp ~170, and GitHub
rejects anything over 100 MB. `deploy.sh` copies them from the host's `~/.local/bin` on
every deploy. Proposing to version them means a failed push.

**Do not delete volumes.** `agentic-claude` holds the login, `agentic-omp` the sessions,
`agentic-work` the workspace. `ctl.sh purge` is the only destructive command and it asks
first. A manual `docker volume rm` loses the login and the token has to be re-issued.

**Launching the box needs a real TTY.** herdr is a full-screen TUI: it does not work from
a subprocess or from an agent's shell. Ask the user to launch it from a terminal emulator.

## Verifying a change

`docker build` succeeding says almost nothing: the image can build and the box can start
with no model, no token, or a stale `CLAUDE.md`.

```bash
bash -n entrypoint.sh run.sh ctl.sh deploy.sh bin-tools/*   # syntax
./deploy.sh                                                 # no --run: copy only
sudo -u agentic -H bash ~agentic/agentic-box/diag.sh        # the token, for real
```

And inside the box, what actually confirms the design works:

```bash
spawn-model --list        # must report each server's real state
spawn-model <alias>       # must create the pane AND start OMP in it
```

## Traps

- **The workspace volume is the user's space; do not litter it.** `refresh_claude_md` used
  to drop a visible `CLAUDE.md.previous` beside the original on every refresh, so the
  workspace accumulated one backup per change — and renaming that suffix once left an
  orphan behind. It now keeps a single hidden `.CLAUDE.md.bak`, overwritten. Anything the
  entrypoint writes there is visible to the user forever, because the volume survives
  rebuilds.
- **The sidebar groups agents by workspace, and the workspace label is separate from the
  pane titles.** herdr names the workspace after the directory the session started in —
  always `/home/agentic/workspace` here — so every agent appears under a heading reading
  "workspace", no matter how the panes are named. Fixed with `herdr workspace rename`, in
  `entrypoint.sh`. Renaming panes does not touch it: they are different labels, and
  confusing them costs a debugging round.
- **herdr titles panes after the basename of their `cwd`.** Since the image's `WORKDIR` is
  `/home/agentic/workspace`, without intervention EVERY pane is called `workspace` and they
  cannot be told apart on screen. There is no config key for the title (`herdr config` only
  offers `check` and `reset-keys`) and no flag on `pane split`: fix it with
  `herdr pane rename <PANE_ID> <LABEL>` after creating the pane. `spawn-model` and
  `entrypoint.sh` already do.
- **Environment variables are fixed when the container is CREATED.** Attaching to a running
  one changes none of them. If something depends on a new variable, it needs `ctl.sh stop`
  and a recreate — re-running `run.sh` is not enough.
- **`herdr agent start` does not accept `--env`; `herdr pane split` does.** The whole
  `spawn-model` design follows from that. If starting the agent first and configuring it
  afterwards ever looks simpler, it is not: there is nowhere to put the variable.
- **A named volume is only seeded from the image when it is brand new and empty.** That is
  why `workspace/CLAUDE.md` is copied twice in the Dockerfile and the entrypoint refreshes
  from the outside copy. Remove that second copy and the agent silently goes back to stale
  instructions.
- **`sh` does not expand braces.** `sudo sh -c 'cp a{1,2} dst'` copies nothing and exits 0.
  Use `bash -c` or an explicit list.
- **Globs are expanded by the shell that writes them, not the one that executes them.**
  Same bug generalised, and it bites often here because there is a privilege boundary in
  the middle:

  ```bash
  sudo chmod +x /home/agentic/agentic-box/*.sh           # WRONG
  sudo bash -c 'chmod +x /home/agentic/agentic-box/*.sh' # RIGHT
  ```

  The first is expanded by your shell, which cannot read the box user's home: it matches
  nothing, passes the literal through, and `chmod` complains about a file named `*.sh`.
  Under `set -e` that aborts the script. **Rule: if the path is on the far side of the
  permission boundary, the glob goes inside `sudo bash -c`.**

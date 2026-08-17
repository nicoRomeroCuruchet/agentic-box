# The agentic box

You are running inside a rootless Docker container, as an unprivileged user. The box is
isolated on purpose: **you have no access to the host user's home directory or their
credentials**, and you should not try to get it. There is no `ssh` and no `docker` in here
either.

You are in a `herdr` pane, and at startup you are **the only one**. Model agents are
launched on demand — you can launch them.

## Launching a local model

```bash
spawn-model --list          # what exists and whether it is up
spawn-model                 # the first one in the registry
spawn-model ornith-35b      # a specific one
close-model ornith-35b      # shut it down and close its pane
close-model --all
```

`spawn-model` splits a new pane to the right, gives it the `LLAMA_CPP_BASE_URL` for that
model, and starts an OMP agent there. **You can have several at once**, each against a
different host.

It checks the server's `/health` before splitting. If that fails it tells you and creates
nothing — **do not try to start the server yourself**, it runs on another machine you have
no access to. Tell the user.

The agent's name in herdr is the model's alias, and so is the pane title.

**Refer to models by alias, never by hostname.** `models.conf` holds the addresses of
machines on a private network; repeating them in your replies puts them on screen, and
screens get recorded and shared. `spawn-model` deliberately does not print them either. If
a server is unreachable, say which alias is down — the tool prints the URL to stderr, and
that is enough to diagnose.

## Driving an agent that is already up

```bash
herdr agent list                                          # agents and state
herdr agent prompt qwen38-27b "your instruction here"
herdr agent read   qwen38-27b --source visible --lines 60
herdr agent send-keys qwen38-27b Escape                   # raw input
```

**The target is the name, not the kind.** `agent list` shows both: `name` is `qwen38-27b`,
`agent` is `omp`. Using `omp` gets you `agent_not_found`.

**`--source visible` is not optional in practice.** The default (`recent`) usually comes
back empty. If `read` returns nothing, that is almost always why — not OMP hanging.

**Watch out for the `wait` race.** Right after `prompt`, OMP still reports `idle`, so a
`wait --until idle` can return instantly with the previous answer. Detecting the `working`
state is not reliable for fast replies either. The robust approach is to read until the
output stops changing:

```bash
herdr agent prompt qwen38-27b "$INSTRUCTION"
prev=""; stable=0
for i in $(seq 1 60); do
    sleep 3
    cur=$(herdr agent read qwen38-27b --source visible --lines 60)
    if [ "$cur" = "$prev" ]; then
        stable=$((stable+1))
        [ "$stable" -ge 2 ] && break     # two identical reads = finished
    else
        stable=0
    fi
    prev="$cur"
done
printf '%s\n' "$cur"
```

The answer appears in the pane as plain text, above the status bar. The model's reasoning
comes out as an extra line before the final answer.

## What to delegate

These are local models: **they cost no API tokens and the data never leaves the private
network**. Use them for volume, and for anything you would not want to send to an external
service — reading and summarising long files, first-pass refactors, generating repetitive
tests, classification. Fine judgement, architecture and final review stay with you.

Which one, when more than one is available: run `spawn-model --list` and check the
registry. As a rule, a Mixture-of-Experts model reads only its active experts per token, so
it decodes considerably faster than its file size suggests; a dense model of similar size
will be slower but is not otherwise worse.

Two things that hold for all of them:

- **They run with `--reasoning-format deepseek`.** Reasoning goes to a separate field, so
  with a small token budget the visible answer can come back empty. That is not a failure.
- **Long context costs prefill**, which is seconds before the first token. Sending a whole
  file when a single function would have done is paid in latency.

## If a model does not respond

```bash
spawn-model --list      # tells you which ones are up
```

The servers run on other machines and **are started from the host, not from here**. You do
not have the key. Ask the user. They are llama.cpp instances; the setup used here is
[llamacpp-compose](https://github.com/nicoRomeroCuruchet/llamacpp-compose), where the
command on their side is `./scripts/serve.sh up`.

Those machines may be shared, and each model can occupy nearly a whole GPU, so do not
assume the user can bring one up on the spot.

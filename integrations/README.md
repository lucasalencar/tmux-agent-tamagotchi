# Integrations

An integration is the translation layer between one agent's hook system and the plugin's
agent-agnostic CLI. It knows everything particular about its agent — what its events are
called, which of them matter, what shape its payload has, what a delegated run means — and
the rest of the plugin knows none of it.

One directory per agent, holding an executable named `hook`:

```
integrations/claude-code/hook   ->  tama hook claude-code <event> [args]
```

`tama hook` routes by directory name and holds no list of known agents, so adding an agent
is adding a directory. The adapter talks to the core through the same public CLI a
hand-wired agent uses; it gets no private entry point.

## These are best effort, and outside the version promise

`bin/tama` is the compatibility promise. `integrations/` is not (ADR-0002). The adapters
track agents that change on their own schedule, so:

- an adapter may break when its agent changes its hooks, and that break does not hold a
  release of the plugin;
- when one does break, the fix reaches you by pulling the plugin, not by editing your own
  config — which is why they ship as code here instead of as documentation;
- an event an adapter does not recognise is ignored in silence, so a configuration written
  against a newer plugin stays harmless on an older one.

Adapters are shell only. No adapter may add a dependency the plugin does not already have —
in particular, none of them uses `jq` (ADR-0001).

## Wiring an agent that has no adapter here

Nothing about the CLI is private, so any hook system that can run a command can drive it:
`tama state running|waiting|idle|error|clear`, plus `tama state subagent-start|stop <id>`.
Every recipe follows the same shape, which keeps working when the plugin moves and stays
quiet on a machine where it is not installed (ADR-0003):

```sh
[ -n "$TMUX" ] || exit 0
tama="$(tmux show -gqv @tama_bin)"
[ -x "$tama" ] || exit 0
exec "$tama" state running my-agent
```

See `tama --help` for the full command surface.

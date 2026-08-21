# Integrations

An integration is the translation layer between one agent's hook system and the plugin's
agent-agnostic CLI. It knows everything particular about its agent — what its events are
called, which of them matter, what shape its payload has, what a delegated run means — and
the rest of the plugin knows none of it.

One directory per agent. Shell integrations hold an executable named `hook`; an agent whose
native plugin runtime gives materially better lifecycle events may instead expose its native
entrypoint (ADR-0010):

```
integrations/claude-code/hook   ->  tama hook claude-code <event> [args]
integrations/codex/hook         ->  tama hook codex <event> [args]
integrations/opencode/index.ts   ->  loaded directly by OpenCode
```

`tama hook` routes shell adapters by directory name and holds no list of known agents. Every
integration talks to the core through the same public CLI a hand-wired agent uses; native
entrypoints get no private core API.

OpenCode uses the native entrypoint above rather than a shell hook because its plugin API exposes
the session relationships and overlapping lifecycle needed for correct pane aggregation. Follow
the one canonical global configuration recipe in [`opencode/README.md`](opencode/README.md); this
document deliberately does not duplicate that JSON.

## These are best effort, and outside the version promise

`bin/tama` is the compatibility promise. `integrations/` is not (ADR-0002). The adapters
track agents that change on their own schedule, so:

- an adapter may break when its agent changes its hooks, and that break does not hold a
  release of the plugin;
- when one does break, the fix reaches you by pulling the plugin, not by editing your own
  config — which is why they ship as code here instead of as documentation;
- an event an adapter does not recognise is ignored in silence, so a configuration written
  against a newer plugin stays harmless on an older one.

An adapter may own a provider-specific dependency without making it a core requirement. The
Claude Code adapter requires `jq` for its provider snapshots; Codex does not. A native
integration keeps its runtime, dependencies, lockfile, and tests inside its own directory so
its toolchain does not become a core requirement (ADR-0010, ADR-0013).

## Wiring an agent that has no adapter here

Nothing about the CLI is private, so any hook system that can run a command can drive it:
`tama state running|waiting|idle|error|clear`, plus `tama state subagent-start|stop <id>`,
and `tama notify <agent> <message>` for the events that should also raise a banner. An
integration whose provider exposes a complete live-subagent snapshot may replace the tracked
set with `tama state subagent-reconcile [<id>…]`; incremental or ambiguous data must keep using
start and stop events. Every recipe follows the same shape, which keeps working when the plugin
moves and stays quiet on a machine where it is not installed (ADR-0003):

```sh
[ -n "$TMUX" ] || exit 0
tama="$(tmux show -gqv @tama_bin)"
[ -x "$tama" ] || exit 0
exec "$tama" state running my-agent
```

Two things to know if your adapter raises banners:

- **The message is one argument and stays one argument.** It is never expanded as a tmux
  format, never read as shell and never stored in a tmux option, so nothing in it needs
  escaping — but nothing may split it either. Hand over exactly what the agent said.
- **Both arguments are required and neither may be empty**, because an empty one is a hook
  that failed to interpolate its variable, and that is a mistake worth hearing about while
  you are still editing the hook. If your agent's payload did not give up a message, put
  something there yourself — the event's name will do.

Deciding that a delegated run should stay quiet is the adapter's own call, and only the
adapter can make it: nothing in the core knows what a delegated run is (ADR-0002). The core
does make a double call harmless, though — banners are grouped per window, so an agent that
fires two events for one question replaces its own banner rather than raising two. The
Claude Code adapter still picks one of its two: which event of a pair is the one worth
interrupting somebody about is also knowledge only an adapter has, and its README says which
it chose and why.

See `tama --help` for the full command surface.

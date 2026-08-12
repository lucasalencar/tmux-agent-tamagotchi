# Agent-specific code lives in `integrations/`, outside the stable contract

Keeping the core agnostic (ADR-0001) leaves a residue per agent: extracting a message from a
payload, knowing which events are worth a banner, knowing that a delegated run should stay
quiet, reading the agent's own config file. That residue has to live somewhere, and the two
obvious homes are both bad — inside the core it contaminates a plugin that claims to be
agent-agnostic; inside the user's config it becomes dead code on their machine that nobody
updates when the agent changes.

So it lives in `integrations/<agent>/hook`, executable and versioned in this repo, invoked
as `tama hook <agent> <event>`. The dispatcher routes by directory name and holds no list of
known agents. These adapters are explicitly **best effort**: they track upstream agents that
change on their own schedule, they are not covered by the plugin's version promise, and a
break in one does not hold a core release.

## Consequences

`bin/tama` is the compatibility promise; `integrations/` is not. A user whose adapter broke
should get a fix by pulling the plugin, not by editing config — which is the whole point of
shipping them as code instead of documentation.

Adapters are shell only. OpenCode's integration is a TypeScript plugin with a state machine
and a debounce; admitting it would mean a second toolchain in a repo tested with bats and
shellcheck, so it stays out until the shape of the plugin is settled enough to say what a
native OpenCode integration should look like.

# Lifecycle Log

The Log is an opt-in JSONL record of Tamagotchi's externally visible lifecycle. Enable it
before starting tmux so the server, new panes, and agent hooks inherit the destination:

```sh
export TAMA_LOG_FILE="$HOME/.local/state/tama.jsonl"
tmux
```

The value must be an absolute path whose parent directory already exists. A missing file is
created for its owner only; an existing regular file keeps its permissions. Symlinks to regular
files work. Directories, devices, sockets, FIFOs, relative paths, and missing parents are
rejected. The plugin appends synchronously and never rotates or truncates the file, so use normal
system tools for retention and disable the variable when collection is complete.

Environment changes affect future processes. Updating a running tmux server's environment does
not update existing panes or agents; restart them or provide the variable explicitly. Validate
the effective configuration with:

```sh
"$(tmux show -gqv @tama_bin)" doctor
jq -e . "$TAMA_LOG_FILE" >/dev/null
```

`jq` is required only while logging is enabled (and independently by the Claude Code
integration). Log write failures stay silent so observability cannot break an agent hook;
`doctor` reports a configured logger that cannot work and does not append a record itself.

## Records

Every compact JSON object occupies one physical line. All records include `version`, a UTC
fractional RFC 3339 `timestamp`, numeric fractional `unix_time`, `event`, `pid`,
`correlation_id`, and `operation_id`. Nested work adds `parent_operation_id`. Completion records
add `outcome` (`applied`, `skipped`, or `failed`) and `duration_ms`; stable `reason` values explain
skips and failures.

The event families are `integration.received`, `integration.classified`, `hook.started`,
`hook.completed`, `command.started`, `command.completed`, `decision.made`, `effect.started`, and
`effect.completed`. Successful status icons, summaries, and listings are omitted. State decisions
include relevant `state_before` and `state_after` groups. Physical line order is the authoritative
arrival order. Timestamps correlate with other systems but do not impose a total order on
concurrent processes; correlation and parent-operation IDs describe causal relationships.
OpenCode gives a native lifecycle event and every effect reduced from it one correlation,
including skipped classifications for unknown or malformed events.

The allowlist includes operation names, outcomes, reasons, supported state values, counts,
booleans, integration/backend capability names, process IDs, and tmux IDs. It excludes provider
payloads, raw agent output and messages, command override text, environment contents, opaque
subagent IDs, tmux socket paths, hostnames, usernames, and mutable tmux names.

## Collect and filter

Preserve the original file and work on filtered output. Start with the smallest time or identity
range that contains the symptom:

```sh
cp -- "$TAMA_LOG_FILE" /tmp/tama-investigation.jsonl
jq -c 'select(.unix_time >= 1787950000 and .unix_time <= 1787953600)' \
  /tmp/tama-investigation.jsonl
jq -c 'select(.pane_id == "%7" or .window_id == "@3")' \
  /tmp/tama-investigation.jsonl
jq -c 'select(.correlation_id == "c-123-456")' /tmp/tama-investigation.jsonl
jq -c 'select(.outcome == "failed" or .outcome == "skipped")' \
  /tmp/tama-investigation.jsonl
```

Use `jq -c`, `nl -ba`, or `rg -n` together when citing evidence so each conclusion names the
source line, timestamp, event, and correlation identity. A `command.started` or `effect.started`
without its matching completion is evidence of a possible interruption, crash, or timeout—not a
malformed record. Logging invokes `jq` synchronously and can perturb timing, which matters when
interpreting concurrency bugs.

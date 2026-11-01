# ADR-0017: Independent per-agent reports inside one pane

## Status

Accepted.

## Context

Some hosts run several agents in one pane: OpenCode serves multiple root
sessions from one background-service instance per directory. The core had one
state and one subagent list per pane, so the last event won and one session's
turn hid another's. The status line, the summary, and notifications all read
that single slot.

The hot path is the status line: one `list-panes` round trip per tmux window
per status interval. Enumerating one tmux option per agent would multiply round
trips by panes × agents; a spike measured 3–6× against the current 0.002s.
Agent ids come from integrations and must survive option names, prefix
enumeration, and list parsing: names with spaces or slashes are unreadable
through `show-options`.

## Decision

One pane option holds every entry: `@tama_pane_agents` stores
`id=state/sub1,sub2;…`. Ids are `[A-Za-z0-9._-]+`; states are the four
reportable domain states (`background` stays derived on read, never stored);
unknown states stay unknown and malformed records never render. Writes address
one entry with `tama state … --agent <id>` and share the optimistic
read-modify-write the flat subagent list already uses; a pane `clear` still
takes the record with it. Unregistering is explicit (`clear --agent`, or
`agent-reconcile` with an authoritative snapshot for ghost healing).

Reads follow one rule everywhere (icons, summary, `tama agents`): a pane with
agent entries draws and counts per entry; without them, the legacy single
state applies exactly as before. The legacy state is still written alongside
(dual-write) so `tama list` rows, which are per pane, keep working untouched.
Notifications group per (tmux window, agent) with `--agent`, per tmux window
otherwise; a plain dismiss clears the whole tmux window at once.

## Consequences

Two agents in one pane no longer hide each other: icons, summary, and banners
are per entry, and completion tracking is per owning root. The status line
keeps its single round trip (one extra field on the existing listing, joined
by pane id).

What we give up:

- Concurrent writes carrying different values can clobber: last writer wins
  until the next event, the same residual the flat subagent list already
  accepts, cured by the same retry plus read-back plus reconcile.
- Integrations own their agent ids and their unregistration; the core never
  invents or expires entries on its own.
- `tama list` stays pane-level by design; per-entry detail lives in the new
  `tama agents` TSV.

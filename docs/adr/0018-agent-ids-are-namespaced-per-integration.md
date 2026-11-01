# ADR-0018: Agent ids are namespaced per integration

## Status

Accepted.

## Context

ADR-0017 gives every agent entry an integration-supplied id inside one shared
pane record. Several integrations can report into the same pane at once
(OpenCode beside Codex beside Claude Code), and nothing stops two of them
from choosing the same raw id — a bare `ses_abc123` from one integration
would address, overwrite, or reconcile away the other's entry. Reconcile
compounds the risk: an integration enumerating its live set drops every
entry it does not list.

## Decision

Agent ids are `<integration>-<id>` — e.g. `opencode-ses_abc123` — namespaced
by the reporting integration at its own CLI boundary, before the id ever
reaches the core. The core stays integration-agnostic: it only enforces the
`[A-Za-z0-9._-]+` charset, which already admits the hyphen. Each integration
owns its prefix, so uniqueness needs no coordination, and the scheme is
deterministic and recoverable: the raw id is stable server-side (so every
report names the same entry) and the integration can always rebuild the full
id it reported (so reconcile lists exactly its own set).

## Consequences

- Cross-integration collision is impossible by construction, not by convention:
  entries sort and render with their owner visible (`tama agents` shows who
  owns what).
- Subagent ids need no prefix: they live scoped inside one entry, which is
  already namespaced.
- Future integrations adopting `--agent` follow the same rule; the contract
  lives in `CONTEXT.md` (agent id) rather than in code, because the core
  cannot know the integration names.

## Enforcement beyond naming

Namespacing prevents address collision, but `agent-reconcile` without scope
would still drop foreign entries (it keeps only listed ids), and a full
`state clear` on disposal would wipe them too. Two scoped operations close
that: `agent-reconcile --namespace <prefix>` judges only entries under the
prefix and keeps everything else in stored order, and `state clear
--keep-agents` clears the legacy residue while keeping the agent record.
Disposal unregisters exactly the entries the integration reported
(`agent-clear` per owned agent) and then clears with `--keep-agents`, so
restart and exit heal one integration's ghosts without touching another's
live agents.

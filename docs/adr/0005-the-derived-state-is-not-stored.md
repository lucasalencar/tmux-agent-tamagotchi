# ADR-0005: The derived state is not stored

## Status

Accepted.

## Context

An agent pane's state has two halves the plugin records: the state an agent
reported (`@tama_pane_state_main`) and the ids of its live subagents
(`@tama_pane_subagents`). What a status line shows is derived from the pair —
`idle` with at least one live subagent displays as `background`.

The plan for v0.1 also stored that derived value, as a third pane option, and had
every writer recompute it. Two commands write, and neither writes both halves: a
state report knows the new state and reads the subagent list; a subagent event
knows the new list and reads the state. tmux has no compare-and-swap, so each one
recomputed the derived value from a snapshot of the half it did not own.

The two events an agent's turn ends with — its own `idle` and its last subagent
stopping — arrive together. Whichever wrote second overwrote the derived value
with one computed from the other's stale half. Reproduced independently at 38/40
and 118/120 attempts, leaving a finished agent showing `background` with no
subagents, or an agent with a live subagent showing `idle`. Nothing healed it:
`idle` is the last thing an agent says until the user types again, so no later
event recomputed anything.

## Decision

The derived state is not stored. `@tama_pane_state` does not exist. `libexec/icons`
derives it, for every pane of the window it was asked about, from the two options
that are stored — read together in the one `list-panes` call it already made.

## Consequences

There is one writer per option, so no write can contradict another. The
derivation is a pure function of two stored values with a single home
(`tama_pane_derive`), and rendering cannot be stale by construction.

It costs nothing on the hottest read path: the same single tmux round trip, now
returning two fields per pane instead of one, and a fork-free loop over the
result. Measured indistinguishable from the stored version.

The write path lost a field, so a state report writes at most four options rather
than five.

What we give up:

- The derived state is no longer readable as a tmux format, so a user cannot
  colour a window by it and `doctor` must derive it like everything else.
- It forecloses precomputing the rendered icon string at write time — a way to
  drop the `#()` job from the status line entirely, which would need a stored
  derived artefact. If that is ever wanted, it should store the rendered string
  and own the same single-writer question again, deliberately.
- Every writer of either half must judge for itself whether the icons changed, to
  decide whether to push a client refresh. That judgement is made from the same
  stale half the stored value used to be, so a refresh can be *skipped* under the
  same race; the second writer to finish notices on its read-back and pays it.
  The failure mode is a screen that lags until the next status interval, never a
  stored value that is wrong.

This reverses the option table in `docs/plans/tmux-agent-tamagotchi-plan.md`,
which lists a stored derived state; the plan has been amended to match.

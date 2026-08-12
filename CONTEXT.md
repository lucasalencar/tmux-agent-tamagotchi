# Context

Domain glossary for `tmux-agent-tamagotchi`. Terms only — no implementation detail.

## Agent

An AI coding assistant (Claude Code, Codex, OpenCode, Gemini CLI) running interactively
inside a tmux pane. The plugin never launches or talks to an agent; agents report their own
lifecycle by invoking the CLI from their hook system.

## Agent pane

A pane that has reported at least one state and has not been cleared. The unit that owns a
**state**. A window may contain several agent panes.

## State

What an agent pane is doing, from the user's point of view. Five values:

| State | Meaning |
| --- | --- |
| `running` | The agent is working on the user's turn. |
| `waiting` | The agent needs the user — a question, a permission prompt. |
| `background` | The main turn is idle, but subagents are still working. |
| `idle` | Nothing in flight; the agent is present and quiet. |
| `error` | The last turn failed. |

`background` is **derived**, never reported: it is `idle` with at least one live subagent.
Every other state is reported directly by an agent hook. Clearing a pane removes its state
entirely, which is different from `idle` — a cleared pane is not an agent pane.

## Subagent

A delegated agent run spawned by an agent, tracked only by an opaque id supplied by the
agent's hooks. The plugin counts them; it knows nothing else about them. Subagent tracking
is best-effort: a leaked id makes a pane look busier than it is until the pane is cleared.

## Flag

A per-window mark meaning *this window wants your attention*, rendered next to the window
name. Raised when an agent pane enters `waiting` while that window is not the active window
of its own session. Only the user clears it, by selecting the window — an agent moving on
to another state does not, because the flag records that something happened while nobody
was looking. Distinct from a **notification**: the flag is inside tmux and persists until
seen; a notification is an OS-level banner.

## Notification

An OS-level banner raised when an agent needs the user. Grouped per window, so a newer
notification for a window replaces the older one, and dismissing is a per-window act.
Suppressed when the user is demonstrably already looking at that window.

## Label

A human-readable description of a window, supplied by the *user's own* tooling and used in
notification titles. The plugin never computes a label and has no opinion about naming
schemes; with no label provider configured, the window name is used.

## Backend

The platform-specific half of notifications: raising a banner, dismissing it, deciding
whether the user is looking at a window, and bringing a session's terminal window forward.
Each of those four capabilities is optional; a missing one degrades to a safe default
rather than an error.

## Integration

The translation layer between one specific agent's hook system and the plugin's
agent-agnostic commands. An integration knows everything particular about its agent — payload
shape, which events matter, which runs are delegated — and the rest of the plugin knows none
of it.

## Stale state

State belonging to a pane whose agent is gone (process exited without reporting, pane
reused as a plain shell). Detected by comparing the pane's current command against the one
recorded when the state was written.

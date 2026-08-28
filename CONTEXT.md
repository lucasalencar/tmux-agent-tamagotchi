# Context

Domain glossary for `tmux-agent-tamagotchi`. Terms only — no implementation detail.

## Agent

An AI coding assistant (Claude Code, Codex, OpenCode, Gemini CLI) running interactively
inside a tmux pane. The plugin never launches or talks to an agent; agents report their own
lifecycle by invoking the CLI from their hook system.

## tmux window

A window managed by tmux, containing one or more panes and possibly linked into multiple
sessions. Always use "tmux window," never "window" alone or "terminal window."

## Terminal window

An operating-system window owned by a terminal application and presenting a tmux client.
Always use "terminal window," never "window" alone or "OS window."

## Agent pane

A pane that has reported at least one state and has not been cleared. The unit that owns a
**state**. A **tmux window** may contain several agent panes.

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

## Status summary

A count of agent panes grouped by **state**, scoped either to the session being viewed or to
the entire tmux server. An agent pane is counted at most once, regardless of how many sessions
or clients expose it.

## Unknown bucket

The status summary group for agent panes whose reported value is not a supported **state**.
It exposes unexpected integration data without treating that data as a new state.

## Subagent

A delegated agent run spawned by an agent, tracked only by an opaque id supplied by the
agent's hooks. The plugin counts them; it knows nothing else about them. Tracking is
conservative: uncertainty may make a pane look busier than it is, but must not hide known
work by declaring a subagent finished without reliable evidence.

## Flag

A per-**tmux window** mark meaning *this tmux window wants your attention*, rendered next to
the tmux window name. Raised when an eligible unseen event requires in-tmux attention: an
agent pane enters `waiting` or `error`, or a `notify` event requests the Flag channel. It
clears when the tmux window becomes
current through direct selection or a session change; navigation is treated as evidence that
the attention was seen, even when caused by automation. An agent moving on to another state
does not clear it, because the flag records that something happened while nobody was looking.
Distinct from a notification: the flag is inside tmux and persists until acknowledged; a
notification is an OS-level banner.

## Priority

A binary, user-assigned classification of a **tmux window** that separates primary work from
secondary work and governs which events may request attention. Independent of **state** and
not itself a request for attention.
_Avoid_: Background work

## Priority marker

A persistent visual indication that a **tmux window** has **priority**. It represents neither
an agent **state** nor a request for attention.

## Priority mode

The attention policy in effect while at least one **tmux window** has **priority**. With no
priorities, every tmux window remains eligible to request attention as before.
_Avoid_: Focus mode

## Attention channel

A mechanism through which an event requests the user's attention. **Notification** is always
an attention channel; **flag** can be included or excluded by configuration.

## Attention acknowledgement

Treating a **tmux window**'s request for attention as handled because navigation made that
tmux window current. It clears the **flag** and dismisses the pending **notification**.
_Avoid_: Seen, focus, notification dismissal

## Notification

An OS-level banner raised when an agent needs the user. Grouped per **tmux window**, so a
newer notification for a tmux window replaces the older one. The same navigation that clears
the tmux window's **flag** dismisses its pending notification. Suppressed when the user is
demonstrably already looking at that tmux window.

## Label

A human-readable description of a **tmux window**, supplied by the *user's own* tooling and
used in notification titles. The plugin never computes a label and has no opinion about
naming schemes; with no label provider configured, the tmux window name is used.

## Backend

The platform-specific half of notifications: raising a banner, dismissing it, deciding
whether the user is looking at a **tmux window**, and bringing a session's **terminal window**
forward. Each of those four capabilities is optional; a missing one degrades to a safe
default rather than an error.

## Integration

The translation layer between one specific agent's hook system and the plugin's
agent-agnostic commands. An integration knows everything particular about its agent — payload
shape, which events matter, which runs are delegated — and the rest of the plugin knows none
of it.

## Stale state

State left on a pane that has returned to a known shell prompt after its agent exited
without clearing it. A pane running any other command is not stale, because a live agent
may have given that command control of the pane.

## Log

An opt-in, machine-readable record of the plugin's externally visible lifecycle: received
commands, resulting decisions, attempted effects, and their outcomes. It excludes raw agent
content and internal operations that do not explain user-visible behavior.
_Avoid_: Diagnostic trace, command log

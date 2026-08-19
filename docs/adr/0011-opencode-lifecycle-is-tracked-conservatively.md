# OpenCode lifecycle is tracked conservatively

An OpenCode plugin instance can observe several root sessions and exposes no reliable active
session, so the integration tracks state per session and aggregates it for the pane instead of
letting the last event win. Attention and activity are reduced in the order `waiting`, `error`,
`running`, then `idle`; errors persist until their session resumes or is removed, while a retry
remains running. The integration uses only documented lifecycle events and classifies a session
by its `parentID`; an event is ignored when that classification cannot be recovered, because a
missing lookup must not turn a delegated or unknown event into a root-session notification.
Errors from delegated sessions only stop their subagent tracking, and errors without a session
are ignored rather than attributed to an arbitrary root.

`session.status` is the source of activity, while outstanding permission request ids form a
separate waiting overlay across root and delegated sessions. The pane becomes idle immediately
when a root session is created or the aggregate does. Creation establishes that the agent is
present but does not represent a completed turn. Completion is notified only after an eligible
turn — one with an observed terminal assistant message — leaves the aggregate idle for ten
seconds; leaving idle cancels the timer, and duplicate idle events do not postpone it.

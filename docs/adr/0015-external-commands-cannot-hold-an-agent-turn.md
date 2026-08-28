# External commands cannot hold an agent turn

Backend capabilities and the user-provided label command execute from an agent hook.
The hook must not inherit an unbounded wait from a desktop tool or user script, and the
ordinary notification path must not pay for failure containment it does not need.

The boundary distinguishes calls by whether the caller reads their result:

- `notify`, `dismiss`, and `focus` are started in the background. Their exit status is
  already discarded by contract, so this adds no watchdog process to the hot path and
  a capability that never returns cannot hold the agent turn.
- `focused` and the label provider remain synchronous because their status or output
  determines behavior. They run in their own process group under a built-in five-second
  watchdog, which sends `TERM` and follows with `KILL` after a short grace period.

Process groups matter because killing only a configured shell can leave the program it
launched holding a command-substitution pipe open. Bash job control provides groups on
the Bash 3.2 shipped by macOS, without adding `timeout`, `gtimeout`, or `setsid` as a
dependency.

The deadline cannot be extended through configuration or the environment. Tests may
lower it to a positive whole number of seconds no greater than the five-second default.

## Consequences

The resultless common path returns after starting the capability and is no slower than
the previous foreground dispatch. A custom resultless capability that hangs may remain
as a background process; accepting that recoverable resource leak avoids imposing a
watchdog process on every notification. Backend authors must still return promptly.

A timed-out `focused` check fails toward delivery, while failures from `notify`,
`dismiss`, and `focus` remain ignored. Immediate `focused` and label commands still
complete before their caller continues.

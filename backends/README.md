# Backends

A backend is a **directory** holding up to four optional executables, one per
capability. That is the entire contract. `@tama_backend` resolves a bare name to a
directory in here and an absolute path to itself, so a backend of your own needs no fork
of this plugin:

```tmux
set -g @tama_backend /Users/me/.config/tmux/my-notifier
```

| Capability | argv | Must do |
| --- | --- | --- |
| `notify` | `<title> <message>` | Raise a banner. Exit status ignored. |
| `dismiss` | `<group>` | Remove the banners in that group. Exit status ignored. |
| `focused` | — | Exit `0` if the user is looking at `$TAMA_WINDOW_ID`, non-zero otherwise. |
| `focus` | `<session>` | Bring that session's terminal window forward. Exit status ignored. |

Environment, for every capability: `TAMA_BIN`, `TAMA_PLUGIN_DIR`, `TAMA_SESSION`,
`TAMA_WINDOW_ID`, `TAMA_TERMINAL_APP`, `TAMA_TERMINAL_BUNDLE_ID`. `notify` and
`dismiss` also get `TAMA_GROUP`; `notify` also gets `TAMA_PANE_ID`, `TAMA_AGENT` and
`TAMA_CLICK`. Context is in the environment rather than in argv so that it can grow
without breaking a backend written against an earlier version — read the ones you need
and ignore the rest.

`TAMA_CLICK` is a shell command line: run it when the user clicks the banner and the
cursor lands on the pane that spoke. Do not compose your own — it is assembled by the
core precisely so that every backend behaves the same, including for a pane or a window
that has since been closed (ADR-0006).

Three rules, and they are not style:

1. **Return promptly.** Capabilities run synchronously inside an agent's hook, on the
   turn the user is waiting for, and there is no timeout. Background anything slow.
2. **Say nothing.** stdout and stderr are discarded. A capability speaks through its
   exit status and nothing else.
3. **Exit 0 unless you mean it.** Only `focused` is asked a question.

**A missing capability is not an error**, it is "unsupported", and the plugin degrades:
no `focused` means nothing is ever suppressed, no `dismiss` means a banner waits for
the desktop to retire it, no `notify` means there are no banners at all. Ship what your
platform can actually do.

That is why `none/` — the backend `auto` picks when nothing else will work — is two
files and not four. A `focused` that exited 0 would mean "the user is looking at that
window", which would suppress every notification on the machine; a `focused` that
exited non-zero would be a process started to say what its absence already says.

Any one capability can also be replaced without replacing the backend, by
`@tama_notify_command`, `@tama_dismiss_command`, `@tama_focused_command` or
`@tama_focus_command`. Those are command *lines*, so they may carry their own flags;
the arguments above are appended as arguments, never pasted into the line.

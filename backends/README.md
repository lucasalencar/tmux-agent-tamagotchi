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

## What ships here

| Backend | Needs | Capabilities |
| --- | --- | --- |
| `macos` | `terminal-notifier`, a terminal whose window titles carry the session name | all four |
| `none` | nothing | `notify`, `dismiss`, both no-ops |

`@tama_backend auto` picks `macos` on a Mac **where the notifier is actually
installed**, and `none` everywhere else — including on a Mac without one, where every
macOS capability would be a process started to fail. It is found on `PATH` first, then
in `/opt/homebrew/bin` and `/usr/local/bin`, because neither an agent's hook nor a
process the desktop starts for a click is a login shell with Homebrew on its `PATH`.
`@tama_terminal_notifier` overrides that with a name or an absolute path.

The macOS backend needs to know your terminal, since neither tmux nor this plugin can
tell which application is displaying a session: `@tama_terminal_app` is the process
name it asks the desktop about and `@tama_terminal_bundle_id` is what a banner
activates when clicked. Both default to Ghostty.

Two of its capabilities identify a terminal window by its **title**, which works
because tmux can be told to put the session name there:

```tmux
set -g set-titles on
set -g set-titles-string '#S'
```

Without it, `focused` never recognises the window you are looking at — so you are
notified about windows on your screen — and `focus` falls through to its second level.
That is the fragile half of ADR-0004's `AND`, and it fails toward noise rather than
silence on purpose.

`focus` has two levels: raise the terminal window whose title is the session, and
failing that, point some other session's tmux client at this session so that its window
shows what you clicked about. The second level takes a window away from whatever it was
displaying — deliberately, because you clicked a banner. The third level the system this
was ported from had, synthesising Cmd+N to open a new terminal window, is not here: it
needs Accessibility permission, borrows the clipboard, and is specific to one terminal.
`@tama_focus_command` is how you wire something like it back in.

Any one capability can also be replaced without replacing the backend, by
`@tama_notify_command`, `@tama_dismiss_command`, `@tama_focused_command` or
`@tama_focus_command`. Those are command *lines*, so they may carry their own flags;
the arguments above are appended as arguments, never pasted into the line.

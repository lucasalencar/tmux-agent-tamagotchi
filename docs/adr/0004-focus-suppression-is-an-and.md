# Focus suppression requires both tmux and the backend to agree

A notification is suppressed when the user is already looking at the window. Neither
available signal is sufficient alone. tmux knows whether a client has that window active but
has no idea whether the terminal is behind a browser — trusting it alone means a minimized
terminal silently swallows every notification, the worst possible failure for this plugin.
The backend knows whether the terminal is frontmost, but on macOS it identifies the window by
comparing its title to the session name, which only works because the user happens to set
`set-titles-string "#S"`; change that and suppression breaks invisibly.

So suppression requires both: the cheap tmux check runs first, and the backend's `focused`
capability is consulted only if it passes. Both must say "yes, you are looking at this" for a
notification to be dropped.

## Consequences

The fragile half can now only fail in the safe direction. A broken `set-titles-string` means
the backend reports "not focused" and the notification is delivered — noise, not silence. A
missing `focused` capability degrades the same way, which is also what makes backends without
one (libnotify, `none`) usable. `doctor` still checks the title configuration, because noise
is worth fixing even when it is not dangerous.

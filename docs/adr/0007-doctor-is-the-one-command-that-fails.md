# `doctor` is the diagnostic command that fails, and only for what it can call broken

Hook-facing subcommands exit 0 on everything except a usage error. That policy exists
because the CLI runs inside an agent's turn: a banner that did not appear must never be
the reason a turn dies. `doctor` is never run from a hook — it is run by a person, or by
a script checking an installation — so the policy has nothing to protect there, and an
exit status is the only thing a script can read.

`toggle-priority` is the deliberate exception for an interactive/script-facing mutation:
an invalid or ambiguous target and a rejected assignment exit 1 with a diagnostic so the
caller can know that Priority did not change. Integrations never invoke this command.

The hard part is not the exit status but the line between *broken* and *worth knowing*,
because this plugin is full of configurations that look like faults and are not. A
machine with no notifier resolves to the `none` backend and stays silent, deliberately.
`@tama_backend ''` turns every capability off, deliberately. `libnotify` ships one
capability out of four, deliberately. A doctor that failed on any of those would be a
doctor nobody could put in CI.

So the line is drawn at **what the machine's own configuration asked for**:

- **broken**, exit 1 — the plugin cannot do what this configuration says it should. A
  tmux below the minimum, where the entrypoint deliberately wires nothing. A server the
  plugin was never loaded into, where every hook recipe finds nothing to run. A backend
  the user *named* whose directory or whose binary is not there — unless every capability
  that backend ships has been replaced by a `@tama_<capability>_command`, because an
  override is answered before the backend is consulted at all and so nothing was ever
  going to reach the missing binary. Replacing the notifier is a supported configuration,
  and a non-zero exit from one would be this criterion failing on its own terms.
- **worth knowing**, exit 0 — the plugin will do exactly what it was configured to, and
  that is probably not what the user wanted. A status line that never interpolates
  `@tama_icons`. A `set-titles-string` the focus check can never match. `auto` finding
  no notifier on this machine. A Claude Code event that was not wired.
- **fine** — the deliberate silences, said out loud rather than left to be guessed at.

"The user named it" is what separates the two backend cases: `auto` choosing `none` is
the plugin working as designed on a machine with nothing to notify with, while
`@tama_backend macos` on a machine without `terminal-notifier` is a promise the plugin
cannot keep.

## Consequences

`tama doctor` can be dropped into a script or a CI job as a check of the installation,
and it will not fail on a headless runner that simply has no desktop to notify. It will
fail on a plugin that is not loaded, which is the thing such a check exists to catch.

The cost is that the interesting half of what doctor finds is invisible to the exit
status. A user who wired every Claude Code event but `Notification` gets a warning and a
zero, because their configuration is doing what it says. That is the right trade for a
check that has to run on other people's machines, and it is why the warnings are worded
as consequences rather than as labels — the exit status is for scripts, and the text is
for the person who was not notified.

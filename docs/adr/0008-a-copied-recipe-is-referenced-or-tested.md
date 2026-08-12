# A copied recipe either references an existing copy or is bound by a test

Some of what this plugin does can only be delivered as text a user pastes: the
status-line formats, the title configuration, the Claude Code hook block, the
`on-select` line. Every place that helps a user — `tama --help`, `libexec/doctor`,
`examples/demo.tmux.conf`, the project README, the integration README — wants its own
copy, because sending somebody somewhere else to find the line they need is a worse
document.

Copies of a recipe rot silently, and they rot in the worst possible direction. Nothing
fails when a snippet in one file stops matching the plugin: it keeps being pasted, it
keeps half-working, and the person it fails for reads it as the plugin being broken. It
is worse still for `doctor`, which does not merely print recipes but *checks a user's
configuration against them* — a copy elsewhere that names different events is a document
telling somebody to wire a set of events the diagnostic does not know about.

So the rule, for any copy of something a user pastes:

**Either reference a copy that already exists, or bind yours with a test that compares it
byte-for-byte against one that does.**

Three applications so far:

- `libexec/doctor`'s Claude Code hook block and the one in
  `integrations/claude-code/README.md` are asserted equal by `tests/doctor.bats`.
- The project README's `set -g` recipes are asserted, by `tests/readme.bats`, to contain
  every such line `tama doctor` prints, unchanged — and to be lines tmux really accepts.
- The project README carries **no** copy of the hook block. It points at the integration
  README instead, and `tests/readme.bats` keeps it pointing there.

## Consequences

Adding a fourth copy of a recipe is no longer free: whoever wants one has to write the
test that holds it to an existing copy, or accept a reference instead. That is the point
— the cost is paid by the person adding the copy rather than by the user who pasted a
stale one.

Two unbound copies remain, in `tama --help` and `examples/demo.tmux.conf`. They predate
the rule and are not grandfathered in on merit; they are simply not yet done, and they can
be bound the same way `tests/readme.bats` binds the README's.

The rule is about recipes, not about prose. Two documents explaining the same behaviour in
their own words is normal and healthy, and no test should try to hold those in step.

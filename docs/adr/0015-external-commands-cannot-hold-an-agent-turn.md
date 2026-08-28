# External commands cannot hold an agent turn

Backend capabilities and the user-provided label command execute from an agent hook.
The hook must not inherit an unbounded wait from a desktop tool or user script.

Every backend capability and the label provider runs under a built-in five-second
watchdog, which sends `KILL` at the deadline. Keeping
the calls synchronous preserves ordering: in particular, a slow `notify` cannot arrive
after a later `dismiss` and leave an orphaned banner.

Process groups handle ordinary descendants cheaply. A capability that backgrounds work
has that group killed as soon as its leader returns, avoiding both leaked work and a
delayed signal aimed at a recycled process-group id. Label output is
captured through a private temporary file whose name is unlinked before user code runs;
therefore even a child that detaches and is reparented cannot retain the hook's output
pipe. Bash job control provides this without adding `timeout`, `gtimeout`, `setsid`, or
`mktemp` as a dependency.

The deadline cannot be extended through configuration or the environment. Tests may
select the named one-second test deadline.

## Consequences

Each external call starts a watchdog process, a measured cost of roughly one millisecond
on the development machine. This is the essential portable cost of preserving both a
hard bound and capability ordering; backend authors must still return promptly, and the
shipped notifiers keep their platform work in the bounded foreground.

A timeout necessarily has a non-zero status, which keeps `focused` fail-open toward
delivery. Failures from `notify`, `dismiss`, and
`focus` remain ignored, so they cannot fail an agent turn.

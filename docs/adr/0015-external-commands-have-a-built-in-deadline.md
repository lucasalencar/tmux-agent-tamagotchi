# External commands have a built-in deadline

Backend capabilities and the user-provided label command execute on an agent hook's
critical path. Their exit status or output may be needed, so moving the entire call to
the background would change observable behavior and would make a wedged process live
forever.

Every external call therefore runs in its own process group with a built-in five-second
watchdog. The watchdog first sends `TERM` and follows with `KILL` after a short grace
period. Process groups matter because killing only the configured shell can leave the
program it launched holding the hook open. Bash job control provides those groups on
the Bash 3.2 shipped by macOS, without adding `timeout`, `gtimeout`, or `setsid` as a
dependency.

The fixed bound is deliberately not configurable. An invalid or excessively large
option would silently restore the failure this decision prevents. Tests may shorten it
through an internal environment variable so the deliberately hanging fixtures remain
fast.

## Consequences

Immediate commands still complete before their caller returns, preserving the backend
contract and existing notification ordering. A hung `focused` check fails toward
delivery, while failures from `notify`, `dismiss`, and `focus` remain ignored, so no
external command failure can fail an agent turn.

Each call starts a command process and a watchdog process. This is the portable cost of
enforcing the deadline on macOS without a new dependency; the watchdog is cancelled as
soon as the command exits.

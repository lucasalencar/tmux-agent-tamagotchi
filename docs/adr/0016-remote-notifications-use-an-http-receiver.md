# Remote notifications go through an HTTP receiver

A banner has to be drawn where the user looks, and tmux does not always run
there. The VM case — agents running in tmux on a Linux VM while the user sits
in front of a MacBook — needs a backend that sends the notification to another
computer instead of drawing it locally.

Two transports were considered. SSH into the showing computer (`ssh macbook
terminal-notifier …`) needs Remote Login enabled there, a key the VM holds,
and host reachability in the VM-to-Mac direction, none of which this plugin
could diagnose beyond "ssh failed". HTTP to a small receiver the user runs on
the showing computer needs one port and one shared secret, both of which
`tama doctor` can check and `curl` can probe by hand (`GET /health`).

So the `remote` backend POSTs JSON (`title`, `message`, `group`, `activate`,
`click`) to a receiver written against the standard library only, which draws
each banner natively — `terminal-notifier` when installed, `display
notification` otherwise. The request is backgrounded like every other
`notify`, and bounded by `@tama_remote_timeout`, so the network can only cost
a backgrounded `curl`.

## Consequences

`auto` never picks `remote`: forwarding across the network is a choice, not a
platform fact, and silently sending banners to a URL somebody once configured
would be the wrong default. It runs only when named explicitly.

There is no `focused` capability: asking another computer whether its terminal
is frontmost would be a synchronous network round trip inside every hook, and
nothing over there can answer it cheaply. Banners are therefore never
suppressed there — noise, never silence, the same direction the `libnotify`
backend fails in.

The click action cannot run where it is drawn: it names tmux paths on the
sending machine. By default a click only activates the terminal; with
`--ssh-target` the receiver runs the click back over SSH, restoring
click-to-pane for users whose showing computer can reach tmux that way. The
receiver executes nothing it was not sent by a bearer of the token, and
nothing at all without `--ssh-target` — which in turn refuses to run without a
token, since it turns any bearer into someone who can plant a click payload.

The token travels as a bearer header in cleartext HTTP, so the receiver belongs
on a trusted network or behind a TLS-terminating proxy; that output is meant to
be pasted into a bug report, and the token itself is never printed by `doctor`.
`doctor` does probe the receiver live, reporting reachability and whether the
configured token matches — a mismatched token is otherwise silence in both
directions, and the likeliest two-machine misconfiguration.

# The core composes the click action, backends only carry it

Clicking a banner has to select the window, then the pane, then bring the terminal
forward, and each step has to happen whatever the one before it did — a pane that has
since been closed, or a whole window that has, must still leave the user looking at
their terminal. A click that does nothing at all is what makes the feature feel broken,
and it is the likeliest outcome, because a notification is clicked minutes after it was
raised.

The alternative was to give each backend the pieces — window id, pane id, session — and
let it build the action for itself. Every backend has to hand the desktop a command line
anyway, so the pieces are all it strictly needs. But then the chaining, the quoting and
the survival of a dead pane are reimplemented once per platform, in the part of the
plugin that is hardest to test, and they will drift: the first backend to use `&&`
instead of `;` loses the guarantee silently, for one platform, in the case nobody
reproduces on purpose.

So the core composes it and passes it as `TAMA_CLICK`, one shell command line, and a
backend's whole responsibility is to run it on click. Composing it is also the only place
the plugin builds a command out of values it did not choose, so the quoting lives in one
function with one test rather than in three backends.

## Consequences

The click's behaviour is a property of the plugin rather than of the platform, and a
single bats test covers it for every backend, including the dead-pane and dead-window
cases. `TAMA_CLICK` is an addition to the capability contract the plan sketched, which
listed only the pieces.

A backend that cannot run an arbitrary command on click — one whose notifier only knows
how to open a URL, say — cannot use it, and would have to translate. None of the three
backends this plugin ships is in that position: `terminal-notifier` takes `-execute`, and
`notify-send` has no click action at all, so it ignores `TAMA_CLICK` along with the rest.

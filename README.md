# tmux-agent-tamagotchi

A tmux plugin that shows you what the AI coding agents in your panes are doing, and tells
you when one of them needs you.

Two halves, and the second is the one nothing else does. In tmux, an icon per agent pane
appears next to the window name, so a glance at the status line says which agents are
working, which are waiting on you and which have fallen over. Outside tmux, a desktop
banner arrives when an agent wants an answer or has finished — and **clicking it puts your
cursor on the pane that spoke**: the window is selected, then the pane inside it, then your
terminal comes to the front. Banners are grouped per window, so a chatty agent replaces its
own banner instead of stacking, and arriving at the window takes it down.

The name is a joke: the agents are the pets, and this is the thing that tells you when one
of them is hungry. It describes nothing, which is why the paragraph above had to.

```
0:editor   1:api ●   2:tests ◐ *   3:docs ⚙   4:build ✕
```

`api` is working. `tests` needs you, and the `*` marks the window because you are looking
somewhere else. `docs` is idle but its delegated runs are still going. `build` ended its
last turn on an error. `editor` has no agent in it, so it draws exactly as tmux would draw
it — no icon, no padding, nothing.

Agents report their own lifecycle by calling this plugin's CLI from their own hook system.
The plugin never launches an agent, never talks to one, and never watches a process: an
agent says what it is doing, or nothing appears. Claude Code has an adapter shipped here
and needs one block of hook configuration; anything else that can run a command on an event
can drive the same CLI.

## Requirements

| | |
| --- | --- |
| **tmux** | 3.1a or newer. Below that the plugin warns and wires nothing at all. |
| **bash** | Any. Every script here is written for bash 3.2.57, the one macOS ships. |
| **Banners, macOS** | [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) — `brew install terminal-notifier`. |
| **Banners, elsewhere** | `notify-send` (libnotify) plus a running freedesktop notification daemon. |

Nothing else. In particular **`jq` is not a dependency** and never will be: the CLI takes
arguments, not JSON on stdin ([ADR-0001](docs/adr/0001-argv-instead-of-hook-payloads.md)).
Nothing is written outside the plugin directory and nothing is installed onto `$PATH`
([ADR-0003](docs/adr/0003-no-writes-outside-the-plugin-directory.md)).

With no notifier installed the plugin is *quiet*, not broken: the icons and the window mark
are inside tmux and cost nothing, and `@tama_backend auto` resolves to a no-op backend
rather than to a process started to fail. So a headless box, a container or a CI runner
needs no configuration to behave.

**Platform honesty.** The macOS backend does all four of its jobs and is the one this
plugin is developed against. The Linux backend is a single file — it delivers banners and
nothing else, because `notify-send` is a one-way door: no dismissal, no focus check, and a
click cannot come back to the pane. Its command line is asserted by tests on both CI
platforms, but there is no Linux desktop on this project's development machine and no
notification daemon on a CI runner, so **no human has yet watched it raise a banner**.
[`backends/README.md`](backends/README.md) says exactly what each platform can and cannot
do.

## Install

With [TPM](https://github.com/tmux-plugins/tpm), in `tmux.conf`:

```tmux
set -g @plugin 'lucasalencar/tmux-agent-tamagotchi'
```

Without it, clone it anywhere and source the entrypoint — it resolves its own location, so
a clone, a submodule and a symlinked worktree are all valid homes:

```tmux
run-shell '/path/to/tmux-agent-tamagotchi/tamagotchi.tmux'
```

Either way, reload your configuration. Then **[the status line is yours to
wire](#the-status-line-is-yours)** — the plugin exports two formats and writes no status
line of its own, so nothing appears until you interpolate them.

To try it before touching your own configuration at all, boot a throwaway server with
[`examples/demo.tmux.conf`](examples/demo.tmux.conf), which is a commented tour of every
option:

```sh
cd /path/to/tmux-agent-tamagotchi
tmux -L tama-demo -f examples/demo.tmux.conf new-session -d -s demo
tmux -L tama-demo attach -t demo
# and when you are done
tmux -L tama-demo kill-server
```

## The status line is yours

The plugin never rewrites a status line somebody spent an afternoon on. What it does is
export two tmux formats for you to put wherever you want them:

| Format | What it draws |
| --- | --- |
| `#{E:@tama_icons}` | One glyph per agent pane of that window, in pane order. |
| `#{E:@tama_flag}` | The mark on a window that wants your attention. |

Both lines, or the window you are looking at is the one without icons. Keeping tmux's own
`window_flags` keeps its zoom and bell markers — without the space it pads them with, since
the icons bring their own:

```tmux
set -g window-status-format '#I:#W#{?window_flags,#{window_flags},}#{E:@tama_icons}#{E:@tama_flag}'
set -g window-status-current-format '#I:#W#{?window_flags,#{window_flags},}#{E:@tama_icons}#{E:@tama_flag}'
```

**A window with no agent in it draws as just its name, and that is correct.** There is
nothing to draw, so the icons expand to nothing at all — not even a stray space. This is
the single thing most often mistaken for the plugin not working, and it is most confusing on
the window you are looking at, which is usually the one you test with. Open an agent in a
pane and the icon appears on the next redraw. The icons for windows you are *not* looking at
are drawn the same way and arrive on the redraw the plugin's own option write triggers —
measured at about 90 ms on tmux 3.7b, with `status-interval` deliberately set to 15 to prove
it is not waiting for a tick.

`#{E:@tama_flag}` draws `@tama_flag_text`, which is `" *"` unless you set it; put
`#[fg=red]` in it if you would rather see colour.

## Wire your agent

**Claude Code:** one block of hook configuration, pasteable, in
**[`integrations/claude-code/README.md`](integrations/claude-code/README.md)**. That page
also says which events raise a banner and which only move an icon, and why. `tama doctor`
prints the same block and checks your settings against it, so you can also get it from
there.

**Anything else:** the CLI is agent-agnostic and nothing about it is private. Any hook
system that can run a command can drive it — see
[`integrations/README.md`](integrations/README.md) for the recipe and the two rules about
banner arguments. Every recipe has the same shape, which is what keeps it working when you
move the clone and quiet on a machine where the plugin is not installed:

```sh
[ -n "$TMUX" ] || exit 0
tama="$(tmux show -gqv @tama_bin)"
[ -x "$tama" ] || exit 0
exec "$tama" state running my-agent
```

## When something does not work, run `tama doctor`

It is the first thing to reach for and it answers most questions without you having to guess
which one you have. In order: the tmux version, whether the plugin is loaded in *this*
server, whether your status line ever asks for the icons, which notification backend was
chosen **and why the others were not**, which notifier binary that resolves to and where it
was found, whether your title configuration can ever match, and which Claude Code events are
wired. Then it prints the setup recipes, whether or not anything is wrong.

```sh
"$(tmux show -gqv @tama_bin)" doctor
```

It exits non-zero when it found something broken and 0 when it only found things worth
knowing, so it works as a check in a script
([ADR-0007](docs/adr/0007-doctor-is-the-one-command-that-fails.md)). It is also the one
command that runs with no tmux server at all, because "there is no server here" is one of
the answers it exists to give.

There are four distinct reasons `auto` ends up picking no backend, and one of them looks
exactly like a bug. `doctor` names whichever one you hit rather than saying "no backend
found", so ask it instead of reading a list.

## The wiring you own

Three things the plugin deliberately does not do to your configuration. The first is
unavoidable; the other two only matter if you already have opinions, and are the ones that
break a power user's config silently.

**1. The status line.** Covered above. This is the one piece of manual wiring nobody can
skip, and it is the reason a fresh install can look like a broken install.

**2. Load order, if you set the same hooks yourself.** The plugin appends its hooks with
`set-hook -ga` and never assigns them, so your own lines on those events keep working. The
contract runs the other way: **a plain `set-hook` of your own, after the plugin has loaded,
replaces the whole array — the plugin's line included** — and the plugin only puts it back on
the next reload, because it skips hooks it can already see. Put your own assignments
*before* the TPM line, or append them with `-ga` too. The four events involved are
`after-select-window`, `after-select-pane`, `client-focus-in` and `client-attached`.

If you would rather own them completely:

```tmux
set -g @tama_manage_hooks off
```

Then nothing is wired for you, and whatever clears a window mark and sweeps dead agents has
to be in your configuration — the `on-select` recipe below on window selection at least,
since **a mark is cleared by you arriving at the window and by nothing else**. An
agent moving on does not clear it: the mark records that something happened while you were
away. `doctor` reports this as a deliberate choice rather than a fault, and reminds you what
it now costs.

**3. Mouse bindings — the plugin installs none, on purpose.** tmux cannot append to a key
table, so a plugin that bound `MouseDown1Status` would silently replace a binding of yours.
Nothing here binds a key or a mouse event at all, so your own bindings are untouched. The
consequence to know: the plugin hooks `after-select-window`, so clicking a window in the
status line clears its mark **as long as your binding actually selects the window** — tmux's
default `select-window -t=` does. If yours does something else instead, such as opening a
menu, add the plugin's own recipe to it:

```tmux
run-shell -b '#{q:@tama_bin} on-select --window #{window_id}'
```

That is verbatim the line the plugin appends to `after-select-window`, so it is also what to
write anywhere else you need the same effect.

## Configuring it

Every option is a global tmux user option, set the way every tmux plugin is configured, and
**read on every invocation rather than cached** — so `tmux source-file` is enough to see a
change, with no server restart. An option set to the empty string is a configuration and not
an absent one: `set -g @tama_icon_prefix ''` really means no prefix.

**The complete annotated reference is `tama --help`**, which documents every option with its
default and every subcommand with its behaviour. It is deliberately the single source rather
than something restated here. [`examples/demo.tmux.conf`](examples/demo.tmux.conf) is the
same material as a file you can copy from. What follows is a map of what exists, so you know
what to go and read about.

| Group | Options |
| --- | --- |
| **Icons** | `@tama_icon_set` (`glyphs`, `pets`, `ascii`), `@tama_icon_running`, `@tama_icon_waiting`, `@tama_icon_background`, `@tama_icon_idle`, `@tama_icon_error`, `@tama_show_idle`, `@tama_show_background`, `@tama_icon_prefix`, `@tama_icon_separator`, `@tama_icon_suffix` |
| **The window mark** | `@tama_flag_text` |
| **Notifications** | `@tama_notifications`, `@tama_backend`, `@tama_title_format`, `@tama_group_format`, `@tama_label_command` |
| **Being left alone** | `@tama_suppress_when_focused` |
| **Your terminal** | `@tama_terminal_app`, `@tama_terminal_bundle_id`, `@tama_terminal_notifier`, `@tama_notify_send` |
| **Replacing a capability** | `@tama_notify_command`, `@tama_dismiss_command`, `@tama_focused_command`, `@tama_focus_command` |
| **Sweeping dead agents** | `@tama_gc_shells` |
| **Lifecycle** | `@tama_manage_hooks` |
| **Read, not set** | `@tama_bin`, `@tama_bin_dir`, `@tama_icons`, `@tama_flag` — exported by the entrypoint. `@tama_pane_agent`, `@tama_pane_cwd`, `@tama_pane_label` — pane options a notification title can reach. |

The five states an icon can show are `running`, `waiting`, `background`, `idle` and `error`;
[`CONTEXT.md`](CONTEXT.md) defines each one. Icon set `glyphs` is the default (`● ◐ ⚙ ○ ✕`),
`ascii` is `* ? + . !` for terminals with no wide-glyph support, and `pets` is `🐥 🍼 🥚 😴 💀`
for the joke — those are double-width, so they cost a column each and terminals do not all
measure them the way tmux does.

## Commands

`bin/tama` is the whole public surface and the compatibility promise. Nothing is on `$PATH`;
hooks find it by asking tmux for `@tama_bin`, which is also how they survive you moving the
clone. Run `tama --help` for the full description of each.

| | |
| --- | --- |
| `state` | What the agent in this pane is doing, and subagent start/stop tracking. |
| `icons` | The glyphs for one window. This is what `@tama_icons` runs for you. |
| `flag` / `unflag` | Raise and clear a window's attention mark. |
| `notify` / `dismiss` | Raise a banner, and take one down. |
| `focus-window` | Bring a session's terminal window forward — the last step of a click. |
| `gc` | Clear the state of panes whose agent is gone. |
| `on-select` | What the selection hooks run: clear the mark, sweep the panes. |
| `hook` | Hand an event to a shipped adapter, e.g. `tama hook claude-code Stop`. |
| `doctor` | Say what this installation is doing and why it is not doing the rest. |
| `version` | Print the plugin version. |

Three promises the whole CLI keeps, because it runs inside an agent's turn:

- **Outside tmux every command is a silent no-op, exit 0**, so one hook configuration works
  in both contexts.
- **A usage error exits 2** with a message on stderr, so a hook you are still editing fails
  loudly.
- **Everything else that goes wrong exits 0 silently** and never fails an agent's turn or
  prints into its transcript. `doctor` is the deliberate exception, since nothing runs it
  from a hook.

## Notifications, and being left alone

A banner is suppressed only when **two answers agree** that you are already looking: tmux
says that window is the current one in its own session with somebody attached, *and* the
backend says the terminal really is in front. Either one saying no — including a backend
that cannot tell — delivers the banner
([ADR-0004](docs/adr/0004-focus-suppression-is-an-and.md)). That asymmetry is deliberate:
extra noise is recoverable, and a minimized terminal swallowing the one notification you
needed is not.

The backend half recognises your terminal window by its **title**, which works because tmux
can be told to put the session name there. Without this the focus check can never match, so
you get banners about windows on your screen:

```tmux
set -g set-titles on
set -g set-titles-string '#S'
```

A backend is a *directory* of up to four optional executables — `notify`, `dismiss`,
`focused`, `focus` — and that is the entire contract, so your own backend needs no fork of
this plugin. A missing capability is not an error, it is "this platform cannot", and the
plugin degrades rather than failing.
[`backends/README.md`](backends/README.md) is the reference.

Any single capability can also be replaced without replacing the backend, with
`@tama_notify_command`, `@tama_dismiss_command`, `@tama_focused_command` or
`@tama_focus_command`. Those are command *lines*, so they can carry their own flags, and the
capability's arguments are appended as arguments rather than pasted in.
[`examples/focus-open-window`](examples/focus-open-window) is a worked example of the
largest of those: a `focus` with one more level than the shipped one, which synthesises
Cmd+N and types an `attach` into the new window when no existing terminal window can be
found or repurposed. It is an example rather than behaviour because it needs Accessibility
permission, is specific to one terminal, and types into whatever Cmd+N opened — the reasons
are in the file, and they are why the plugin does not do this for you.

## Behaviour that would otherwise surprise you

**Clicking a banner can take a window away from another session.** If no terminal window is
showing the session the banner came from, the macOS `focus` capability falls back to
pointing some *other* session's tmux client at this one, so that window now shows what you
clicked about. That is deliberate — you clicked a banner, and a click that does nothing is
what makes a feature feel broken — but it is a real cost, and `doctor` does not currently
mention it ([#22](https://github.com/lucasalencar/tmux-agent-tamagotchi/issues/22)). Replace
the capability with `@tama_focus_command` if you want a different rule.

**Subagent tracking is best effort.** The background icon — an idle agent whose delegated
runs are still working — is counted from ids the agent's hooks supply. An agent that starts
a delegated run and dies before reporting it finished leaves that id behind, and the pane
keeps showing the background icon until something sweeps it. This is known and open
([#15](https://github.com/lucasalencar/tmux-agent-tamagotchi/issues/15)); it is not exact
and is not promised to be. Everything else about the pane's state works without it.

**Agents that exit without saying so are swept, by inference.** A pane is stale when it is
back at a shell prompt but its state says an agent is working there — `@tama_gc_shells` is
the list of shells. A pane running some other program is left alone: what tmux reports is
whatever holds the pane's tty, so an agent whose tool call opened an editor or a pager looks
exactly like one that walked out, and taking a live agent's icon away is the expensive
mistake. A pane carrying the plugin's leftovers but no state at all — a `notify` from a pane
whose state hooks were never wired — is swept whatever it is running, since it draws nothing
and nothing else will ever clear it.
The sweep runs on window and pane selection for the window you are looking at, and over the
whole server when you come back to the terminal. Coming back by *attaching* needs nothing
from you; coming back because your terminal regained focus needs tmux's own `set -g
focus-events on` for tmux to notice at all.

**`integrations/` is outside the version promise.** `bin/tama` is the compatibility promise;
the adapters are not
([ADR-0002](docs/adr/0002-integrations-are-outside-the-contract.md)). They track agents that
change on their own schedule, so an adapter may break when its agent changes its hooks, that
break does not hold a release of the plugin, and when one does break the fix reaches you by
pulling the plugin rather than by editing your own configuration — which is why they ship as
code here instead of as documentation. An event an adapter does not recognise is ignored in
silence, so a configuration written against a newer plugin stays harmless on an older one.

## Documentation

| | |
| --- | --- |
| `tama --help` | Every option and every subcommand. The reference. |
| `tama doctor` | What your installation is doing, and the recipes to paste. |
| [`CONTEXT.md`](CONTEXT.md) | The domain glossary: state, flag, backend, integration. |
| [`docs/adr/`](docs/adr/) | Why the boundaries are where they are — the reasoning behind most of what looks arbitrary. |
| [`backends/README.md`](backends/README.md) | The backend contract and what each platform can do. |
| [`integrations/README.md`](integrations/README.md) | Wiring an agent, adapter or not. |
| [`integrations/claude-code/README.md`](integrations/claude-code/README.md) | Claude Code: the hook block, and what each event does. |
| [`examples/demo.tmux.conf`](examples/demo.tmux.conf) | A throwaway server with every option annotated. |

## Development

```sh
make lint   # shellcheck over every executable and library, examples included
make test   # the bats suite
make        # both, which is what CI runs
```

CI runs both targets on Ubuntu and macOS. The macOS leg is not a portability nicety: every
script here is written for bash 3.2.57, which is what macOS ships and what an agent's hook
runs under there, and there is no bash 3.2 on a Linux runner. Tests drive the plugin through
`bin/tama` against their own isolated tmux servers and never source its libraries.

## Licence

GPL-3.0. See [`LICENSE`](LICENSE).

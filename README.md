# 🐥 tmux-agent-tamagotchi

A tmux plugin for monitoring AI coding agents running in different panes.

It adds agent status to the tmux window list and sends desktop notifications for events
that need attention. You can work in another window without repeatedly checking each agent.

The plugin:

- Shows one status icon per agent pane.
- Marks user-selected tmux windows as Priority.
- Marks windows that need attention.
- Sends desktop notifications when an agent needs input or finishes.
- Opens the correct tmux pane when a supported notification is clicked.

```text
0:editor   1:api ●   2:★tests ◐ !   3:docs ⚙   4:build ✕
```

Agents report their lifecycle through command hooks or native plugin APIs. The plugin does not
launch or monitor agent processes. Claude Code, Codex, and OpenCode have bundled integrations;
other agents can call the same CLI.

## Requirements

| Requirement | Details |
| --- | --- |
| tmux | 3.1a or newer |
| bash | Compatible with bash 3.2.57, included with macOS |
| Claude Code integration | `jq` ([installation](integrations/claude-code/README.md#requirement-jq)) |
| macOS notifications | [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) |
| Other desktop notifications | `notify-send` and a freedesktop notification daemon |

`jq` is required only for the Claude Code integration. Codex, OpenCode and the core plugin
work without it. Without a supported notifier, icons and window marks still work.

Platform capabilities and limitations are documented in
[`backends/README.md`](backends/README.md).

## Install

### TPM

Add to `tmux.conf`:

```tmux
set -g @plugin 'lucasalencar/tmux-agent-tamagotchi'
```

Reload tmux and press the TPM install binding (`prefix` + <kbd>I</kbd>).

### Manual

Clone the repository and source its entrypoint:

```tmux
run-shell '/path/to/tmux-agent-tamagotchi/tamagotchi.tmux'
```

The plugin supports regular clones, submodules and symlinked worktrees. It does not install
anything onto `$PATH` or write outside its directory.

## Configure the status line

The plugin exports five tmux formats:

| Format | Output |
| --- | --- |
| `#{E:@tama_priority}` | Priority marker for the tmux window |
| `#{E:@tama_icons}` | Agent state icons for the window |
| `#{E:@tama_flag}` | Persistent attention mark |
| `#{E:@tama_status_summary}` | Agent-state counts for the session's selected scope |
| `#{E:@tama_choose_tree_format}` | Session, window and pane rows for `choose-tree` |

Add the Priority, State, and Flag formats to the regular and current-window status lines:

```tmux
set -g window-status-format '#I:#{E:@tama_priority}#W#{?window_flags,#{window_flags},}#{E:@tama_icons}#{E:@tama_flag}'
set -g window-status-current-format '#I:#{E:@tama_priority}#W#{?window_flags,#{window_flags},}#{E:@tama_icons}#{E:@tama_flag}'
```

A window without an agent has no icon or additional padding.

### Priority mode

Toggle Priority only with an explicit tmux window target:

```sh
"$(tmux show -gqv @tama_bin)" toggle-priority --window '@3'
```

With no Priority tmux windows, attention works as before. The first Priority activates
Priority mode; removing the last one deactivates it. While active, Notifications are
limited to Priority tmux windows. Automatic Flags remain ambient by default, or can be
made selective independently:

```tmux
set -g @tama_flag_policy selective
```

The standalone `flag` command remains an explicit override. Changing Priority never
clears or replays existing Flags or Notifications, and Priority survives navigation and
State changes for the lifetime of the tmux window.

By default, a new assignment is blocked when it would put more than 80% of the server's
unique tmux windows in Priority, with at least one always allowed. Linked windows count
once. Existing assignments are never removed when windows close or the setting changes,
and rare concurrent toggles are not serialized. Set `@tama_priority_max_percent` from 1
through 100; invalid or empty values fail open and are reported by `doctor`.

This optional binding toggles the tmux window identified by the key event without the
plugin reserving a key:

```tmux
bind-key P run-shell '#{q:@tama_bin} toggle-priority --window #{q:window_id}'
```

Clear Priority from every tmux window in the current server with:

```sh
"$(tmux show -gqv @tama_bin)" clear-priorities
```

The command snapshots distinct Priority tmux windows by immutable identity, including
tmux windows in other sessions, then attempts every removal. A linked tmux window is
treated once. Success (including an already-empty set) is quiet; if any removal fails,
the others are still attempted and the command exits non-zero with a diagnostic. Priority
changes racing after the snapshot are not guaranteed to be cleared. State, Flags,
Notifications, and unrelated tmux options are preserved.

Pass `--session <session_id>` to limit the same operation to the distinct tmux windows
visible in that immutable session. Because Priority belongs to a tmux window, this also
removes Priority from any links to those tmux windows in other sessions. Priorities on
tmux windows not linked into the selected session remain unchanged. An already-empty
session is a quiet success.

An optional adjacent binding clears the server-wide set without the plugin reserving a key:

```tmux
bind-key O run-shell '#{q:@tama_bin} clear-priorities'
```

An adjacent binding can scope removal to the session where the key event occurred:

```tmux
bind-key M-O run-shell '#{q:@tama_bin} clear-priorities --session #{q:session_id}'
```

The default marker follows the icon preset: `★` for glyphs, `⭐` for pets, and `*` for
ASCII. Override it with `@tama_priority_icon`, or set that option to an empty string to
hide it. The Flag default is `!`, keeping classification and attention distinct.

### Window selector

Use the exported tree format to show canonical window names with the same agent icons and
attention flags in tmux's `prefix` + <kbd>w</kbd> selector:

```tmux
bind-key w choose-tree -Zw -F '#{E:@tama_choose_tree_format}'
```

The selector starts with panes collapsed. Expanding a window continues to show each pane's
running command and title. The plugin exports the format but does not install a key binding.

### Status summary

Compose `#{E:@tama_status_summary}` into `status-left` wherever it fits your theme. The
plugin never rewrites `status-left` and installs no key binding.

Each session has its own `@tama_summary_scope`. It defaults to `current`, which counts
unique agent panes in that session. `all` counts unique panes across the current tmux
server, including detached sessions; linked windows and additional clients do not multiply
the count.

The summary renders buckets in running, waiting, idle, background, error, then unknown
order. Running, waiting, and idle remain visible at zero; background, error, and unknown
are hidden at zero. An unsupported nonempty reported state appears under unknown with `?`
as its default icon. Empty reported states are not agent panes and remain excluded.

Each bucket's `@tama_summary_show_<state>` option accepts `always`, `nonzero`, or `never`.
The defaults are `always` for running, waiting, and idle, and `nonzero` for background,
error, and unknown. An invalid value falls back to that bucket's default and `doctor`
reports a successful warning. The unknown icon and complete composition are configurable:

```tmux
set -g @tama_icon_unknown '?'
set -g @tama_summary_prefix ''
set -g @tama_summary_separator ' '
set -g @tama_summary_suffix ''
```

The five supported buckets reuse `@tama_icon_<state>` literally, including tmux styles.
Each bucket is its icon, one space, and its count; counts have no separate style option.

The following optional recipe binds `prefix` + <kbd>G</kbd> to toggle the scope of the
session displayed by that client. The session id is passed explicitly so linked windows
cannot make the target ambiguous:

```tmux
bind-key G run-shell '#{q:@tama_bin} summary-scope --session #{q:session_id} toggle'
```

### Icons

Select an icon preset with `@tama_icon_set`:

| Preset | Priority | running | waiting | background | idle | error | Flag |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Default (`glyphs`) | `★` | `●` | `◐` | `⚙` | `○` | `✕` | `!` |
| ASCII (`ascii`) | `*` | `*` | `?` | `+` | `.` | `!` | `!` |
| Pets (`pets`) | `⭐` | `🐥` | `🍼` | `🥚` | `😴` | `💀` | `!` |

For example:

```tmux
set -g @tama_icon_set pets
```

Override individual states to build a custom set. An individual option takes precedence
over `@tama_icon_set`:

```tmux
set -g @tama_icon_running '▶'
set -g @tama_icon_waiting '?'
set -g @tama_icon_background '~'
set -g @tama_icon_idle 'o'
set -g @tama_icon_error 'x'
```

Reload the tmux configuration to apply a change:

```sh
tmux source-file ~/.tmux.conf
```

State definitions are in [`CONTEXT.md`](CONTEXT.md).

## Connect an agent

- **Claude Code:** copy the hook configuration from
  [`integrations/claude-code/README.md`](integrations/claude-code/README.md).
- **Codex:** copy the hook configuration from
  [`integrations/codex/README.md`](integrations/codex/README.md).
- **OpenCode:** load the native TypeScript plugin using the canonical global configuration in
  [`integrations/opencode/README.md`](integrations/opencode/README.md).
- **Other agents:** follow the public CLI recipe in
  [`integrations/README.md`](integrations/README.md).

Adapters are best effort. `bin/tama` is the stable interface; `integrations/` follows agent
APIs that may change independently.

## Diagnose problems

Run `doctor` from a tmux server where the plugin is loaded:

```sh
"$(tmux show -gqv @tama_bin)" doctor
```

Without a reachable server, use the plugin path:

```sh
/path/to/tmux-agent-tamagotchi/bin/tama doctor
```

It checks:

- tmux version and plugin loading;
- status-line configuration;
- status-summary scope and bucket policies;
- selected backend and notifier binary;
- terminal-title configuration;
- Claude Code hook configuration and its `jq` dependency when wired.

Broken setups exit non-zero. Warnings exit zero. See
[ADR-0007](docs/adr/0007-doctor-is-the-one-command-that-fails.md).

## Configuration reference

Options are read on every invocation. Configuration options are global tmux user options,
except `@tama_summary_scope`, which is stored per session.

An empty string is a configured value, not a missing option.

For boolean options, `off`, `no`, `0` and `false` turn it off; every other value leaves it on.

Use `bin/tama --help` for defaults and detailed behavior. The table below is the complete
option map.

| Group | Options |
| --- | --- |
| Icons | `@tama_icon_set`, `@tama_icon_running`, `@tama_icon_waiting`, `@tama_icon_background`, `@tama_icon_idle`, `@tama_icon_error`, `@tama_show_idle`, `@tama_show_background`, `@tama_icon_prefix`, `@tama_icon_separator`, `@tama_icon_suffix` |
| Status summary | `@tama_summary_scope` (`current` or `all`, per session), `@tama_summary_show_running`, `@tama_summary_show_waiting`, `@tama_summary_show_idle`, `@tama_summary_show_background`, `@tama_summary_show_error`, `@tama_summary_show_unknown`, `@tama_icon_unknown`, `@tama_summary_prefix`, `@tama_summary_separator`, `@tama_summary_suffix` |
| Priority | `@tama_priority_icon`, `@tama_priority_max_percent` (1–100) |
| Window mark | `@tama_flag_text`, `@tama_flag_policy` (`ambient` or `selective`) |
| Notifications | `@tama_notifications`, `@tama_backend`, `@tama_title_format`, `@tama_group_format`, `@tama_label_command` |
| Focus suppression | `@tama_suppress_when_focused` |
| Terminal | `@tama_terminal_app`, `@tama_terminal_bundle_id`, `@tama_terminal_notifier`, `@tama_notify_send` |
| Capability overrides | `@tama_notify_command`, `@tama_dismiss_command`, `@tama_focused_command`, `@tama_focus_command` |
| Stale state | `@tama_gc_shells` |
| Lifecycle | `@tama_manage_hooks` |
| Exported values | `@tama_bin`, `@tama_bin_dir`, `@tama_priority`, `@tama_icons`, `@tama_status_summary`, `@tama_flag`, `@tama_choose_tree_format`, `@tama_pane_agent`, `@tama_pane_cwd`, `@tama_pane_label` |

### Focus detection

Notification suppression requires agreement from tmux and the backend. If either cannot
confirm focus, the notification is delivered. See
[ADR-0004](docs/adr/0004-focus-suppression-is-an-and.md).

The macOS backend identifies a session by the terminal window title:

```tmux
set -g set-titles on
set -g set-titles-string '#S'
```

Backend configuration, custom backends and capability overrides are covered in
[`backends/README.md`](backends/README.md).

### Hook management

The plugin appends its hooks. A later plain `set-hook` for the same event replaces the
plugin hook. Put custom hook assignments before the plugin or append them with `-ga`.

Selecting a tmux window or switching a client to another session performs **Attention
acknowledgement** for the tmux window that becomes current: its flag and pending notification
are cleared, and stale state is swept only there. Returning to a terminal window through a
client attach or focus event also acknowledges its current tmux window and sweeps the server.

To manage hooks yourself:

```tmux
set -g @tama_manage_hooks off
```

If a mouse binding does not select the clicked window, run the selection recipe explicitly:

```tmux
run-shell -b '#{q:@tama_bin} on-select --window #{window_id}'
```

The plugin does not install mouse bindings.

## Commands

`bin/tama` is the public CLI. Run `bin/tama --help` for arguments and defaults.

| Command | Purpose |
| --- | --- |
| `state` | Record an agent state or subagent event. |
| `icons` | Render the icons for one window. |
| `toggle-priority` | Toggle Priority for one explicit tmux window target. |
| `clear-priorities` | Clear Priority server-wide or within one explicitly targeted session. |
| `flag` / `unflag` | Raise or clear a tmux window flag. |
| `notify` / `dismiss` | Raise or dismiss a notification. |
| `focus-window` | Bring a session's terminal window forward. |
| `list` | List agent panes across the server as stable, headerless TSV. |
| `summary` | Count unique agent panes using a session's selected scope. |
| `summary-scope` | Select or toggle one explicitly targeted session's scope. |
| `gc` | Clear stale pane state. |
| `on-select` | Perform Attention acknowledgement and sweep stale state. |
| `hook` | Dispatch an event to a bundled adapter. |
| `setup` | Configure an integration that provides a setup helper. |
| `doctor` | Diagnose an installation. |
| `version` | Print the plugin version. |

`tama list` prints headerless TSV in this fixed column order:
`session_name`, `session_id`, `window_index`, `window_name`, `window_id`, `pane_index`,
`pane_id`, `agent`, `state`, and `label`. With no arguments it covers every session in
the current server. Pass `--session <session>` with one exact session name or tmux session
ID to limit the same output to that session; a missing or empty session produces no output.

Hook-facing commands follow these rules:

- Outside tmux, they exit zero without output.
- Usage errors exit `2` with a message on stderr.
- Operational errors exit zero without interrupting an agent turn.
- Invalid or rejected Priority mutations exit `1` with a diagnostic.

`doctor` and `setup` report failures with a non-zero status. Both `setup` and `focus-window`
run outside tmux: setup may configure an agent before tmux starts, while desktop notification
clicks do not inherit the hook environment.

## Operational notes

- **Notifications:** grouped per tmux window; Attention acknowledgement dismisses the pending
  notification.
- **macOS clicks:** may repurpose another tmux client's terminal window when the target
  session is not visible. See [`backends/README.md`](backends/README.md) and
  [#22](https://github.com/lucasalencar/tmux-agent-tamagotchi/issues/22).
- **Subagents:** tracking is best effort. A leaked subagent id can leave a background icon
  until the pane is swept ([#15](https://github.com/lucasalencar/tmux-agent-tamagotchi/issues/15)).
- **Stale state:** a pane is cleared only after it returns to a shell listed in
  `@tama_gc_shells`. Other commands may belong to a live agent and are left alone.
- **Focus events:** server-wide sweeping on terminal focus requires `set -g focus-events on`.

## More documentation

| Document | Contents |
| --- | --- |
| `bin/tama --help` | Options, defaults and command arguments |
| `bin/tama doctor` | Installation diagnostics and setup recipes |
| [`CONTEXT.md`](CONTEXT.md) | Domain glossary |
| [`docs/adr/`](docs/adr/) | Architectural decisions |
| [`backends/README.md`](backends/README.md) | Backend contract and platform behavior |
| [`integrations/README.md`](integrations/README.md) | Public integration recipe |
| [`integrations/claude-code/README.md`](integrations/claude-code/README.md) | Claude Code adapter |
| [`integrations/codex/README.md`](integrations/codex/README.md) | Codex adapter |
| [`integrations/opencode/README.md`](integrations/opencode/README.md) | OpenCode native plugin and canonical setup |
| [`examples/demo.tmux.conf`](examples/demo.tmux.conf) | Runnable configuration example |

## Development

```sh
make lint
make test
make doctor
make
```

CI runs ShellCheck and the Bats suite on Ubuntu and macOS, then loads the plugin into an
isolated tmux server and runs `tama doctor` on Ubuntu.

## License

GPL-3.0. See [`LICENSE`](LICENSE).

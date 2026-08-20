# tmux-agent-tamagotchi

A tmux plugin for monitoring AI coding agents running in different panes.

It adds agent status to the tmux window list and sends desktop notifications for events
that need attention. You can work in another window without repeatedly checking each agent.

The plugin:

- Shows one status icon per agent pane.
- Marks windows that need attention.
- Sends desktop notifications when an agent needs input or finishes.
- Opens the correct tmux pane when a supported notification is clicked.

```text
0:editor   1:api ●   2:tests ◐ *   3:docs ⚙   4:build ✕
```

Agents report their lifecycle through command hooks or native plugin APIs. The plugin does not
launch or monitor agent processes. Claude Code, Codex, and OpenCode have bundled integrations;
other agents can call the same CLI.

## Requirements

| Requirement | Details |
| --- | --- |
| tmux | 3.1a or newer |
| bash | Compatible with bash 3.2.57, included with macOS |
| macOS notifications | [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) |
| Other desktop notifications | `notify-send` and a freedesktop notification daemon |

`jq` is not required. Without a supported notifier, icons and window marks still work.

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

The plugin exports two tmux formats:

| Format | Output |
| --- | --- |
| `#{E:@tama_icons}` | Agent state icons for the window |
| `#{E:@tama_flag}` | Persistent attention mark |

Add both formats to the regular and current-window status lines:

```tmux
set -g window-status-format '#I:#W#{?window_flags,#{window_flags},}#{E:@tama_icons}#{E:@tama_flag}'
set -g window-status-current-format '#I:#W#{?window_flags,#{window_flags},}#{E:@tama_icons}#{E:@tama_flag}'
```

A window without an agent has no icon or additional padding.

### Icons

Select an icon preset with `@tama_icon_set`:

| Preset | running | waiting | background | idle | error |
| --- | --- | --- | --- | --- | --- |
| Default (`glyphs`) | `●` | `◐` | `⚙` | `○` | `✕` |
| ASCII (`ascii`) | `*` | `?` | `+` | `.` | `!` |
| Pets (`pets`) | `🐥` | `🍼` | `🥚` | `😴` | `💀` |

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
- selected backend and notifier binary;
- terminal-title configuration;
- Claude Code hook configuration.

Broken setups exit non-zero. Warnings exit zero. See
[ADR-0007](docs/adr/0007-doctor-is-the-one-command-that-fails.md).

## Configuration reference

Options are global tmux user options and are read on every invocation. Reloading tmux is
enough to apply changes.

An empty string is a configured value, not a missing option.

For boolean options, `off`, `no`, `0` and `false` turn it off; every other value leaves it on.

Use `bin/tama --help` for defaults and detailed behavior. The table below is the complete
option map.

| Group | Options |
| --- | --- |
| Icons | `@tama_icon_set`, `@tama_icon_running`, `@tama_icon_waiting`, `@tama_icon_background`, `@tama_icon_idle`, `@tama_icon_error`, `@tama_show_idle`, `@tama_show_background`, `@tama_icon_prefix`, `@tama_icon_separator`, `@tama_icon_suffix` |
| Window mark | `@tama_flag_text` |
| Notifications | `@tama_notifications`, `@tama_backend`, `@tama_title_format`, `@tama_group_format`, `@tama_label_command` |
| Focus suppression | `@tama_suppress_when_focused` |
| Terminal | `@tama_terminal_app`, `@tama_terminal_bundle_id`, `@tama_terminal_notifier`, `@tama_notify_send` |
| Capability overrides | `@tama_notify_command`, `@tama_dismiss_command`, `@tama_focused_command`, `@tama_focus_command` |
| Stale state | `@tama_gc_shells` |
| Lifecycle | `@tama_manage_hooks` |
| Exported values | `@tama_bin`, `@tama_bin_dir`, `@tama_icons`, `@tama_flag`, `@tama_pane_agent`, `@tama_pane_cwd`, `@tama_pane_label` |

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
| `flag` / `unflag` | Raise or clear a window mark. |
| `notify` / `dismiss` | Raise or dismiss a notification. |
| `focus-window` | Bring a session's terminal window forward. |
| `list` | List agent panes across the server as stable, headerless TSV. |
| `gc` | Clear stale pane state. |
| `on-select` | Clear a mark, dismiss its notification and sweep its window. |
| `hook` | Dispatch an event to a bundled adapter. |
| `setup` | Configure an integration that provides a setup helper. |
| `doctor` | Diagnose an installation. |
| `version` | Print the plugin version. |

Hook-facing commands follow these rules:

- Outside tmux, they exit zero without output.
- Usage errors exit `2` with a message on stderr.
- Operational errors exit zero without interrupting an agent turn.

`doctor` and `setup` report failures with a non-zero status. Both `setup` and `focus-window`
run outside tmux: setup may configure an agent before tmux starts, while desktop notification
clicks do not inherit the hook environment.

## Operational notes

- **Notifications:** grouped per window; selecting the window dismisses its banner.
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
make
```

CI runs shellcheck and the bats suite on Ubuntu and macOS.

## License

GPL-3.0. See [`LICENSE`](LICENSE).

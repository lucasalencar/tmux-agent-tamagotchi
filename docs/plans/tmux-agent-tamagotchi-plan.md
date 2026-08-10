# `tmux-agent-tamagotchi` — a TPM plugin for AI-agent status & notifications

## Context

The dotfiles already implement a complete AI-agent awareness system inside tmux: per-pane
agent state (running / waiting / idle / error + subagent tracking) rendered as icons in
each window name, a `*` flag on windows with pending events, and macOS notifications with
click-to-focus. It works, but it is welded to this repo — scripts spread across two stow
packages, wired by hand into `@catppuccin_window_text` and `set-hook -g` lines, dependent
on `$DOTFILES_ROOT`, hardcoding ghostty and `/opt/homebrew/bin/terminal-notifier`, using
un-namespaced tmux options (`@pane_status`, `@notify`).

Goal of **this** effort: build the standalone, TPM-installable, configurable plugin that
generalizes that system — **without touching the dotfiles at all for now**. The dotfiles
stay on their current scripts and keep working; the plugin is developed and verified in
isolation against a throwaway tmux server. Migrating the dotfiles over (and deleting the
old scripts) is a separate, later effort, sketched at the end so nothing gets lost.

Decisions taken: plugin owns **state core + notification layer**; **pluggable backends**
(macOS default, Linux possible without patching); **no auto-injection** into the status
line — the plugin exports ready-made `#(...)` option strings the user interpolates; repo
is **public** at `github.com/lucasalencar/tmux-agent-tamagotchi`, with `tama` as the CLI
name and `@tama_*` as the tmux option namespace.

The name is a deliberate joke that happens to describe the model exactly: each pane holds
a little creature with a state, and `◐` means it is hungry for input. Lean into it in the
docs and the default icon set, but keep the CLI verbs literal (`state`, `notify`, `flag`)
— they are the API that agent hooks depend on, and cuteness there would cost more than it
buys. Themed aliases can wrap the literal verbs (see below).

Source of truth for behavior to port (read, don't modify):
`tmux/scripts/tmux-agent-state`, `tmux-agent-icon`, `tmux-agent-status`,
`tmux-clear-stale-status`, `tmux-notify-window`, `tmux-clear-notify`,
`tmux-on-select-window`; `scripts/agent-notify`, `notify-macos`, `clear-notify-macos`,
`focus-terminal-window`; the wiring in `tmux/.tmux.conf` (lines ~131-144, 199-203).

## Repository

`~/code/tmux-agent-tamagotchi`, public on GitHub, English only (the current scripts have
Portuguese comments — rewrite as part of the port). Develop **inside the TPM clone** and
symlink `~/code/tmux-agent-tamagotchi` to `~/.tmux/plugins/tmux-agent-tamagotchi` (a TPM clone is an
ordinary git worktree) — this sidesteps TPM's poor local-path support.

```
tamagotchi.tmux             # TPM entrypoint (the only *.tmux file)
bin/tama                    # public dispatcher — THE stable API surface
libexec/                    # one file per subcommand; free to refactor
  state icons list flag unflag gc on-select notify notify-raw dismiss
  focus-window doctor migrate-legacy-options
lib/
  common.sh                 # set -u, die(), require_tmux(), $TMUX_CMD indirection
  options.sh                # tama_opt <name> <default>
  pane.sh                   # pane resolution, state read/write/recompute
  notify.sh                 # payload parsing, suppression, group id, title template
  backend.sh                # backend resolution + capability invocation
backends/
  macos/{notify,dismiss,focused,focus}
  libnotify/{notify,dismiss,focused,focus}
  none/{notify,dismiss,focused,focus}       # all no-ops
tests/                      # bats-core + tests/fixtures/fake-backend
examples/demo.tmux.conf     # standalone config for verification (see Verification)
docs/{configuration,cli,backends}.md, docs/integrations/{claude-code,codex,opencode,gemini}.md
.github/workflows/ci.yml    # shellcheck + bats on ubuntu-latest and macos-latest
README.md LICENSE
```

`bin/` vs `libexec/` is deliberate: `bin/` is the compatibility promise, `libexec/` is
internal. A single dispatcher (not many small executables) means agent hooks depend on
**one** name, and the subcommand surface can grow without new PATH entries — the opposite
of today's symlink sprawl.

## Public CLI contract

All commands are `tama <subcommand> [args]`. Global rule: **exit 0 whenever there
is nothing to do** (no `$TMUX`, no pane, unknown state) — hooks must never fail an agent's
turn. Reserve exit 2 for genuine usage errors. Never write to stdout except
`icons`/`list`/`doctor`/`version`.

| Subcommand | stdin | Effect |
| --- | --- | --- |
| `state <running\|waiting\|idle\|error\|clear> [agent_name]` | ignored | Write `…_state_main`, recompute derived `…_state`, record `…_cmd`/`_agent`/`_cwd`, refresh clients |
| `state subagent-start` / `subagent-stop` | **required** JSON | `jq -r '.agent_id // .session_id // empty'`, add/remove from `…_subagents`, recompute |
| `flag [target]` | ignored | Set the window flag unless that window is already the session's active window |
| `unflag [target]` | ignored | Clear the flag |
| `notify <agent_name> [fallback_msg] [--allow-agent-id]` | **required** JSON (may be `{}`) | Full pipeline: type filter → subagent filter → focus suppression → title build → backend `notify` |
| `notify-raw <title> <message> [group]` | ignored | Low-level notification, no JSON/suppression — for non-agent callers |
| `dismiss [target]` | ignored | Backend `dismiss` for that window's group id |
| `focus-window <session>` | ignored | Backend `focus`; used as the notification click action |
| `icons <window_id>` | ignored | Icon string for `#()` |
| `list` | ignored | `icon label` per agent pane, one per line |
| `gc [window_id]` | ignored | Clear stale state (default: active window) |
| `on-select` | ignored | `unflag` + `dismiss` + `gc` |
| `doctor` | ignored | tmux version, resolved backend, resolved options, dependency availability |
| `bin-dir` / `version` / `--help` | — | Introspection |

Common flags: `--pane <pane_id>` on `state`/`flag`/`notify` to override `$TMUX_PANE`
(needed by tests and by wrappers that lose the env); `--allow-agent-id` on `notify`
replaces today's positional third argument (positional booleans are a trap).

Renames vs today: `tmux-agent-state` → `state`, `tmux-notify-window` → `flag`,
`agent-notify` → `notify`, `clear-notify-macos` → `dismiss`, `tmux-agent-icon` → `icons`,
`tmux-agent-status` → `list`, `tmux-clear-stale-status` → `gc`,
`tmux-on-select-window` → `on-select`.

**Themed aliases** (optional sugar, documented as aliases, never as the contract — hook
recipes in `docs/integrations/` use the literal verbs so the API stays greppable):
`feed` → `state waiting`, `play` → `state running`, `nap` → `state idle`, `sick` →
`state error`, `bury` → `state clear`, `pets` → `list`, `vet` → `doctor`.

## State model (namespaced)

Keep the current design — the tmux server *is* the database, no files — but namespace it.

| Now | New | Scope |
| --- | --- | --- |
| `@pane_status_main` | `@tama_pane_state_main` | pane |
| `@pane_agent_ids` | `@tama_pane_subagents` | pane |
| `@pane_status` | `@tama_pane_state` (derived) | pane |
| `@pane_command` | `@tama_pane_cmd` | pane |
| `@pane_name` | `@tama_pane_agent` | pane |
| `@pane_cwd` | `@tama_pane_cwd` | pane |
| `@notify` | `@tama_window_flag` | window |

Preserved semantics: `state_main = idle` renders as `running` while any subagent id is
registered; the optimistic read-modify-write retry loop for `…_subagents` (tmux has no
atomic RMW); `…_pane_cmd` snapshot as the liveness heuristic for `gc`;
`refresh-client -S` after writes.

Two improvements over the current code:
- **Short-circuit**: if the recomputed display state equals the stored one, skip both the
  write and the refresh. `state running` fires on every `PostToolUse`, so this is the
  highest-value micro-optimization in the port.
- **Self-healing**: a leaked subagent id (lost RMW under concurrent `SubagentStop`) is
  wiped by both `gc` and `state clear`. Document that instead of adding a lock.

`libexec/migrate-legacy-options` copies the old `@pane_*` / `@notify` values to the new
names once per server (guarded by `@tama_migrated`) — relevant only once the
dotfiles migrate, but cheap to ship now given the long-lived `main` session.

## Configuration surface

All options read at invocation time from server-scope user options (`tmux show -gqv`),
never cached, so `tmux source-file` takes effect instantly. `lib/options.sh` provides
`tama_opt @name default`.

**Rendering**

| Option | Default | Affects |
| --- | --- | --- |
| `@tama_icon_running` / `_waiting` / `_error` / `_background` / `_idle` | `●` `◐` `✕` `⚙` `○` | `icons`, `list` |
| `@tama_icon_set` | `glyphs` | Preset shorthand for the five glyphs above: `glyphs` (current geometric set) \| `pets` (`🥚`/`😋`/`🤒`/`⚙`/`😴` — the theme, opt-in) \| `ascii` (`*`/`?`/`!`/`+`/`-` for terminals without wide-glyph support). Individual `_icon_*` options always win over the preset. |
| `@tama_show_idle` / `_show_background` | `on` / `on` | Whether those states render at all |
| `@tama_icon_prefix` | `" "` | Emitted only when ≥1 icon exists — preserves today's `" ●◐"` |
| `@tama_icon_suffix` / `_icon_separator` | `""` / `""` | Trailing / between glyphs |
| `@tama_flag_text` | `" *"` | Window notification marker |

**Exported (set by the plugin, for the user to interpolate)**

| Option | Value |
| --- | --- |
| `@tama_icons` | `#(<plugin>/bin/tama icons #{window_id})` |
| `@tama_flag` | `#{?@tama_window_flag,#{E:@tama_flag_text},}` |
| `@tama_bin` / `_bin_dir` | absolute paths |

**Notifications**

| Option | Default | Affects |
| --- | --- | --- |
| `@tama_notifications` | `on` | Master switch for `notify` |
| `@tama_backend` | `auto` | `auto` (Darwin→`macos`, else `notify-send`→`libnotify`, else `none`) \| name \| absolute path to a third-party backend dir |
| `@tama_notify_command` / `_dismiss_command` / `_focused_command` / `_focus_command` | `""` | Per-capability override of the backend file, same contract |
| `@tama_title_format` | `#{agent} - #{project} (#{label})` | Plugin's own mini-template: `#{agent}`, `#{project}`, `#{label}`, `#{session}`, `#{window_index}`, `#{window_name}`; the `(#{label})` group drops when label is empty |
| `@tama_group_format` | `tmux-window-#{session}-#{window_index}` | **Single source of truth** for notify + dismiss |
| `@tama_label_command` | `""` | Human-readable window label provider, invoked as `sh -c "$cmd \"\$1\"" _ <window_id>`; empty → `#{window_name}` |
| `@tama_suppress_when_focused` | `on` | Whether to consult the `focused` capability |
| `@tama_skip_notification_types` | `auth_success` | stdin `.notification_type` values that exit 0 silently |
| `@tama_terminal_app` / `_terminal_bundle_id` | `$TERMINAL_APP_NAME` else `ghostty` / `$TERMINAL_BUNDLE_ID` else `com.mitchellh.ghostty` | macOS backend targets |
| `@tama_terminal_notifier` | resolved via `PATH`, then `/opt/homebrew/bin`, then `/usr/local/bin` | Replaces today's hardcoded path (breaks on Intel Macs) |
| `@tama_protected_sessions` | `main` | Sessions the macOS `focus` capability must never repurpose (today hardcoded) |

**Lifecycle**

| Option | Default | Affects |
| --- | --- | --- |
| `@tama_manage_hooks` | `on` | Whether the entrypoint appends its `set-hook -ga` lines |
| `@tama_bind_mouse` | `off` | Optional convenience mouse bindings (users with their own keep `off`) |
| `@tama_gc_on_select` | `on` | Whether `on-select` runs `gc` |
| `@tama_gc_shells` | `zsh bash sh fish dash tcsh csh ksh mksh oksh elvish nu xonsh pwsh` | Legacy-pane fallback in `gc` |
| `@tama_link_bin` / `_link_dir` | `on` / `$HOME/.local/bin` | Whether/where to symlink `tama` |
| `@tama_refresh` | `on` | Whether `state`/`gc` call `refresh-client -S` |
| `@tama_subagent_retries` / `_retry_delay` | `5` / `0.05` | RMW loop tuning |

## Backend abstraction

`@tama_backend` resolves to a directory: bare name → `$PLUGIN_DIR/backends/<name>/`;
absolute path → used as-is, so third-party backends need no fork. Each capability is an
optional executable; a missing file means "unsupported" and the caller degrades gracefully
(no `focused` → never suppress; no `dismiss` → no-op). Payload goes in argv, context in
env vars (extensible without breaking argv).

| Capability | argv | env | Contract |
| --- | --- | --- | --- |
| `notify` | `<title> <message>` | `TAMA_GROUP`, `_SESSION`, `_WINDOW_TARGET` (`sess:idx`), `_WINDOW_ID`, `_AGENT`, `_BIN` | Fire and forget, exit 0 |
| `dismiss` | `<group>` | `TAMA_SESSION`, `_WINDOW_TARGET` | Remove prior notifications in that group |
| `focused` | — | `TAMA_SESSION`, `_WINDOW_ID`, `_TERMINAL_APP` | **exit 0 = user is looking at this window → suppress**; non-zero → deliver |
| `focus` | `<session>` | `TAMA_WINDOW_TARGET`, `_TERMINAL_APP`, `_TERMINAL_BUNDLE_ID` | Bring that session's terminal window forward |

- `backends/macos/*` — port of `notify-macos`, `clear-notify-macos`, the `osascript`
  frontmost block in `agent-notify`, and `focus-terminal-window`; behavior preserved, hard
  paths replaced by option lookups. The click action becomes
  `"$TAMA_BIN" focus-window "$SESSION"` instead of embedding a dotfiles path into
  terminal-notifier's `-execute` string. `focus` degrades to a plain `-activate` when
  `osascript` fails (missing Accessibility permission) rather than hanging.
- `backends/libnotify/*` — `notify-send` with
  `--hint=string:x-canonical-private-synchronous:$GROUP` for replace-based dismissal;
  `focused` unsupported, `focus` a no-op.
- `backends/none/*` — all exit 0; makes CI and headless machines silent by default.
- `tests/fixtures/fake-backend/*` — records argv+env into `$TAMA_TEST_LOG`.

## TPM entrypoint (`tamagotchi.tmux`)

Runs on every `tmux source-file`, so it must be idempotent:

1. `PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"`.
2. Version guard: parse `tmux -V`, require **≥ 3.1a** (pane user options, `set-hook -a`);
   below that, `display-message` a warning and exit 0 without wiring anything.
3. `tmux set -g @tama_bin` / `@tama_bin_dir`.
4. Export the `@tama_icons` / `@tama_flag` format options.
5. If `@tama_link_bin` is `on`: `mkdir -p $LINK_DIR` and
   `ln -sfn "$PLUGIN_DIR/bin/tama" "$LINK_DIR/tama"`. This is the **hook
   discovery mechanism**: agent hooks run under `sh -c` from GUI-launched processes with a
   minimal PATH, so they reference the absolute `$HOME/.local/bin/tama` — `$HOME` is
   always set and always expanded by `sh`. No PATH manipulation required anywhere.
6. Run `libexec/migrate-legacy-options`, guarded by `@tama_migrated`.
7. If `@tama_manage_hooks` is `on`, append (never overwrite):
   ```tmux
   set-hook -ga after-select-window "run-shell -b '<bin> on-select'"
   set-hook -ga client-focus-in     "run-shell -b '<bin> on-select'"
   set-hook -ga after-select-pane   "run-shell -b '<bin> gc'"
   ```
8. If `@tama_bind_mouse` is `on`, install the two mouse bindings.

Documented load-order contract: a user's own non-append `set-hook -g` lines must appear
**before** the TPM `run` line, otherwise they wipe the plugin's appended entries. Mouse
key bindings cannot be appended to at all, so users who already bind
`MouseDown1Status`/`MouseDown1Pane` keep `@tama_bind_mouse off` and call
`tama on-select` from their own bindings — the one piece of unavoidable manual
wiring, and it must be prominent in the README.

## Testing

- **shellcheck** over `bin/`, `libexec/`, `lib/`, `backends/`, `tamagotchi.tmux`.
- **bats-core** with `tests/helper.bash` booting an isolated server
  (`tmux -L tama-test -f /dev/null new-session -d -s t`), pointing
  `@tama_backend` at the fake backend and setting `@tama_refresh off`.
  Requires a small but high-value refactor: every script calls tmux through a `$TMUX_CMD`
  indirection defaulting to `tmux`, overridable via `TAMA_TMUX`.
- Cases worth locking down: `idle` + subagent → `running`; `clear` wipes all three pane
  options; duplicate `subagent-start` is idempotent; `subagent-stop` on an unknown id is a
  no-op; `icons` respects `show_idle off`; `icons` emits nothing (not a bare space) when no
  agent panes exist; `gc` clears when `…_pane_cmd` differs and preserves when it matches;
  `flag` does not flag the active window; `notify` skips `auth_success`, skips `.agent_id`
  without `--allow-agent-id`, and suppresses when `focused` exits 0; **group id from
  `notify` equals group id from `dismiss` for the same window** (regression test for the
  bug class the current duplicated string invites).
- **CI**: matrix `ubuntu-latest` + `macos-latest`, installing tmux, jq, bats, shellcheck.

## Build order

Each step is independently verifiable and touches nothing outside the plugin repo.

1. **Skeleton** — repo, LICENSE, `tamagotchi.tmux` (steps 1-5 above), `bin/tama`
   dispatcher with `version`/`doctor`/`bin-dir`/`--help`, `lib/common.sh`, `lib/options.sh`,
   CI with shellcheck.
2. **State core** — `state` (incl. subagents), `icons`, `list`, `gc`, `flag`, `unflag`,
   `on-select`, `lib/pane.sh`, plus their bats tests.
3. **Notification layer** — `lib/notify.sh`, `lib/backend.sh`, `notify`, `notify-raw`,
   `dismiss`, `focus-window`, `backends/none/*`, `backends/macos/*`, fake-backend tests.
4. **Portability** — `backends/libnotify/*`, `auto` resolution, `doctor` checks
   (tmux version, `jq`, backend binaries, `set-titles-string "#S"` for the macOS backend),
   CI green on both OSes.
5. **Docs** — README (options table, status-line snippet, the manual mouse-binding note,
   dependency list), `docs/configuration.md`, `docs/cli.md`, `docs/backends.md`, and
   `docs/integrations/*.md` with copy-pasteable hook recipes for Claude Code, Codex,
   OpenCode and Gemini CLI derived from the dotfiles' current configs.
6. **Freeze the name**, then tag `v0.1.0`.

## Verification (no dotfiles changes)

Everything is exercised on a throwaway server so the live `main` session and its status
line are untouched.

`examples/demo.tmux.conf` — a self-contained config that sources the plugin directly
(`run-shell '~/code/tmux-agent-tamagotchi/tamagotchi.tmux'`), sets
`window-status-format "#{window_index}:#{window_name}#{E:@tama_icons}#{E:@tama_flag}"`
and `status-interval 5`.

```sh
tmux -L tama-demo -f examples/demo.tmux.conf new-session -d -s demo
tmux -L tama-demo attach -t demo     # in a spare window
```

1. `tama doctor` → prints the resolved bin dir, `macos` backend, tmux version, all
   deps OK.
2. State: `tama state running Test` → `●` next to the window name;
   `tmux show -p -v @tama_pane_state` says `running`; `waiting` → `◐`;
   `state clear` → gone.
3. Subagents: `echo '{"agent_id":"a"}' | tama state subagent-start`, then
   `tama state idle` → still `●`; `subagent-stop` → `○`.
4. GC: set state in a pane, exit the process, select another pane → icon clears.
5. Flag: `tama flag` from a non-active window → `*` appears; select that window →
   `*` clears.
6. Notifications: `echo '{}' | tama notify Test 'done'` from a background window →
   macOS banner with the templated title; click it → that window is selected and the
   terminal focused; select the window → banner dismissed.
7. Suppression: same call with the demo window frontmost and active → no banner.
8. Options: override `@tama_icon_running`, `_show_idle off`, `_flag_text`,
   `_title_format` and re-run 2/5/6 → rendering changes without a plugin reload.
9. Backend swap: `@tama_backend none` → no banner, no error;
   `@tama_notify_command` pointing at a script that appends to a file → the file
   receives the expected argv/env.
10. `bats tests/` and `shellcheck` pass locally and in CI.

Cleanup: `tmux -L tama-demo kill-server`.

## Later (out of scope now): dotfiles migration

Recorded so the boundaries survive. When the plugin stabilizes:

- **Moves out** — all the scripts listed under "Source of truth" above, deleted from the
  dotfiles once hooks point at `$HOME/.local/bin/tama`.
- **Stays** — `tmux-window-label` / `tmux-set-window-label` / `tmux-rename-window` (window
  naming, not agent-specific; becomes the value of `@tama_label_command`), the
  `fzf-tmux-*` helpers, `tmux-toggle-pane-border-status`,
  `tmux-move-window-to-new-session`, `tmux-kill-windows-except-current`.
- **Non-agent consumer to keep working**: `homebrew/update:11-12` calls
  `tmux-notify-window` + `notify-macos` for a sudo prompt → becomes `tama flag` +
  `tama notify-raw`. This is why `notify-raw` exists.
- `tmux/.tmux.conf` sets `@tama_label_command`, `@tama_bind_mouse off`,
  `@tama_manage_hooks off` (it owns the three shared hooks explicitly, avoiding the
  ordering hazard), and swaps the `#(...tmux-agent-icon...)#{?@notify, *,}` part of
  `@catppuccin_window_text` / `_current_text` for
  `#{E:@tama_icons}#{E:@tama_flag}` — verify the double expansion behaves on
  tmux 3.7b, else inline the `#(...)` literally.
- Hook configs to rewrite: `claude-code/.claude/settings.json`,
  `codex/.codex/hooks/agent-lifecycle` (collapse its three helpers onto one
  `TAMA="${TAMA_BIN:-$HOME/.local/bin/tama}"` with an `[ -x ]` guard),
  `codex/rc`, `gemini/.gemini/settings.json`,
  `opencode/.config/opencode/plugins/tmux-agent-status.ts` (its pure core in `lib/` and
  the state machine need no change — only the command strings and the matching assertions
  in `tests/`; add a `TAMA_BIN` constant reading `process.env.TAMA_BIN` so tests
  can inject a fake). `tmux-toggle-sidebar` is dead code and gets deleted.
- Docs: `tmux/README.md` shrinks to the integration contract + a link to the plugin; the
  root `README.md` package table drops `notify-macos`/`agent-notify` from the `scripts`
  row. Final sweep: `grep -rn 'tmux-agent-state\|agent-notify\|notify-macos\|@pane_status\|@notify' ~/.dotfiles`.
- Consider raising `status-interval` from `5` to `30`+ at that point: writes already push
  updates via `refresh-client -S`, and `#()` runs one shell per window per interval.

## Risks / gotchas

- `#()` in the window format runs one shell per window per `status-interval` — keep `icons`
  free of `jq` and subshell fan-out; it is the hottest path in the plugin.
- Subagent RMW stays racy under bursts; keep the retry loop, make the failure benign
  (self-healed by `gc` / `state clear`), and document it.
- The macOS `focused` capability depends on the user's `set-titles-string "#S"`; it
  silently over-notifies otherwise → `doctor` must check it and the README must state it.
- The macOS `focus` capability needs Accessibility permission for its synthetic Cmd+N
  path; degrade instead of hanging.
- Minimal PATH in hook contexts: resolve `jq`, `terminal-notifier` and `osascript` through
  explicit candidate lists and report findings in `doctor`.
- `#{E:}` requires tmux ≥ 2.9; pane user options and `set-hook -a` require ≥ 3.1a. Local
  tmux is 3.7b.
- The `pets` icon set uses double-width emoji, which tmux measures inconsistently across
  terminals and can shift the status line — keep `glyphs` as the default, and test `pets`
  against a window count high enough to expose truncation before documenting it.
- A joke name has a cost: `tama` must be self-explanatory in `--help` and the README's
  first paragraph must state plainly what the plugin does, since the name alone won't.
  Also check the npm/GitHub namespace and the tmux-plugins wiki for a `tamagotchi`
  collision before the first push.

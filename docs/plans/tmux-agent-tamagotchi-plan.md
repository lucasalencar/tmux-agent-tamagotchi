# `tmux-agent-tamagotchi` — a TPM plugin for AI-agent status & notifications

## Context

The dotfiles already implement a complete AI-agent awareness system inside tmux: per-pane
agent state rendered as icons in each window name, a `*` flag on windows with pending
events, and macOS notifications with click-to-focus. It works, but it is welded to that
repo — scripts spread across two stow packages, wired by hand into `@catppuccin_window_text`
and `set-hook -g` lines, dependent on `$DOTFILES_ROOT`, hardcoding ghostty and
`/opt/homebrew/bin/terminal-notifier`, using un-namespaced tmux options.

Goal of **this** effort: build the standalone, TPM-installable, configurable plugin that
generalizes that system — **without touching the dotfiles at all for now**. The dotfiles stay
on their current scripts and keep working; the plugin is developed and verified in isolation
against a throwaway tmux server. Migrating the dotfiles over is a separate, later effort,
sketched at the end.

Domain vocabulary is in [`CONTEXT.md`](../../CONTEXT.md). Four decisions carry their own
rationale in [`docs/adr/`](../adr/): argv instead of hook payloads, integrations outside the
contract, no writes outside the plugin directory, focus suppression as an `AND`.

Source of truth for behavior to port (read, don't modify):
`tmux/scripts/tmux-agent-state`, `tmux-agent-icon`, `tmux-clear-stale-status`,
`tmux-notify-window`, `tmux-clear-notify`, `tmux-on-select-window`; `scripts/agent-notify`,
`notify-macos`, `clear-notify-macos`, `focus-terminal-window`; the wiring in
`tmux/.tmux.conf`. Repo is public at `github.com/lucasalencar/tmux-agent-tamagotchi`, `tama`
is the CLI name, `@tama_*` the option namespace, English only.

### Bugs in the current system, fixed by this port

Found while mapping the dotfiles; each is a behavior change, not a refactor.

- `tmux-notify-window` compares window **indexes** against the **ambient client's** index, so
  an agent in `work:3` is silently not flagged while you look at `main:3`. `agent-notify`
  does the equivalent check correctly (window ids, target session). The two disagree.
- Group ids, click targets and dismissal are index-based while `renumber-windows on` is set:
  closing a window can make a pending notification address a different one.
- `agent-notify` derives the project name from `$PWD` — the hook process's cwd, not the
  pane's.
- `mutate_agent_ids` gives up silently after five attempts and `recompute` runs outside the
  retry loop; `clear` writes `""` instead of unsetting; `@pane_command` is never cleared.
- `background`/`⚙` is rendered but nothing ever produces it.

## Repository layout

Develop **inside the TPM clone** — symlink `~/code/tmux-agent-tamagotchi` to
`~/.tmux/plugins/tmux-agent-tamagotchi` (a TPM clone is an ordinary git worktree), which
sidesteps TPM's poor local-path support.

```
tamagotchi.tmux             # TPM entrypoint (the only *.tmux file)
bin/tama                    # public dispatcher — THE stable API surface
libexec/                    # one file per subcommand; free to refactor
  state icons flag unflag gc on-select notify dismiss focus-window doctor hook
lib/
  common.sh                 # set -u, die(), require_tmux(), $TMUX_CMD indirection
  options.sh                # tama_opt <name> <default>
  pane.sh                   # pane resolution, state read/write/recompute, "is the user
                            #   looking at this window?" (one implementation, two callers)
  notify.sh                 # suppression, group id, title expansion
  backend.sh                # backend resolution + capability invocation
backends/
  macos/{notify,dismiss,focused,focus}
  libnotify/{notify,dismiss,focused,focus}
  none/{notify,dismiss,focused,focus}       # all no-ops
integrations/
  README.md                 # the best-effort promise, in the directory it applies to
  claude-code/hook          # v0.1 ships this one only
tests/                      # bats-core + tests/fixtures/fake-backend
examples/demo.tmux.conf     # standalone config for verification
docs/{configuration,cli,backends}.md, docs/integrations/claude-code.md
docs/adr/, CONTEXT.md
.github/workflows/ci.yml    # shellcheck + bats on ubuntu-latest and macos-latest
README.md LICENSE
```

`bin/` vs `libexec/` is deliberate: `bin/` is the compatibility promise, `libexec/` is
internal. A single dispatcher means agent hooks depend on **one** name.

## Public CLI contract

All commands are `tama <subcommand> [args]`. No command reads stdin. `jq` is not a
dependency (ADR-0001).

**Failure policy**: usage errors exit **2** with a message on stderr — a wrong hook is the
user's fault and must be visible while they are editing it. Everything else exits **0**
silently: no `$TMUX`, no such pane, unknown state, missing backend, failed banner. A
notification that did not appear must never fail an agent's turn. Nothing writes to stdout
except `icons` and `doctor`.

| Subcommand | Effect |
| --- | --- |
| `state <running\|waiting\|idle\|error\|clear> [agent_name]` | Write `…_state_main`, recompute derived `…_state`, record `…_cmd`/`_agent`/`_cwd`. `waiting` and `error` also raise the window flag. |
| `state subagent-start <id>` / `subagent-stop <id>` | Add/remove from `…_subagents`, recompute |
| `flag [target]` / `unflag [target]` | Raise/clear the flag directly (integrations rarely need these) |
| `notify <agent_name> <message>` | Suppression check → title expansion → backend `notify`; also raises the flag |
| `dismiss [target]` | Backend `dismiss` for that window's group id |
| `focus-window <session>` | Backend `focus`; the notification's click action |
| `icons <window_id>` | Icon string for `#()` |
| `gc [--all] [window_id]` | Clear stale state (default: active window) |
| `on-select` | `unflag` + `dismiss` + `gc` |
| `hook <agent> <event> [args]` | `exec integrations/<agent>/hook <event> …` |
| `doctor` | Diagnosis **and** recipe; non-zero exit if anything is broken |
| `version` / `--help` | Introspection |

`--pane <pane_id>` on `state`/`flag`/`notify` overrides `$TMUX_PANE` (needed by tests and by
wrappers that lose the env).

Renames vs today: `tmux-agent-state` → `state`, `tmux-notify-window` → `flag`,
`agent-notify` → `notify`, `clear-notify-macos` → `dismiss`, `tmux-agent-icon` → `icons`,
`tmux-clear-stale-status` → `gc`, `tmux-on-select-window` → `on-select`.

**Dropped from the original plan**: `list` (nothing consumes it; `tmux-agent-status` is dead
code), `notify-raw` and the `homebrew/update` consumer, `migrate-legacy-options` (write it
when the dotfiles actually migrate, against real values), `tama link` and
`@tama_link_bin`/`_link_dir` (ADR-0003), `--allow-agent-id` (the caller decides — ADR-0002),
themed aliases.

## State model

The tmux server *is* the database — no files.

| Now | New | Scope |
| --- | --- | --- |
| `@pane_status_main` | `@tama_pane_state_main` | pane |
| `@pane_agent_ids` | `@tama_pane_subagents` | pane |
| `@pane_status` | `@tama_pane_state` (derived) | pane |
| `@pane_command` | `@tama_pane_cmd` | pane |
| `@pane_name` | `@tama_pane_agent` | pane |
| `@pane_cwd` | `@tama_pane_cwd` | pane |
| `@notify` | `@tama_window_flag` | window |

**Derivation**: `state_main == idle` with at least one subagent renders as `background`
(`⚙`), not `running` — this is the state that was rendered but never produced in the current
system. With `@tama_show_background off` it renders as `running` (i.e. "don't distinguish",
not "hide").

**Writes**: if the recomputed display state equals the stored one, skip the write *and* the
`refresh-client -S`. `state running` fires on every `PostToolUse`, so this is the highest-
value optimization in the port. `clear` **unsets** options (`set -pu`) rather than writing
empty strings — a cleared pane is not an agent pane.

**Subagents**: keep the optimistic read-modify-write retry loop (tmux has no atomic RMW). A
leaked id under concurrent stops is self-healed by `gc` and `state clear`; document that
instead of adding a lock.

**Flag**: raised by `state waiting`, `state error` and `notify`, and only when the target
window is not the active window of **its own session** (`window_id` comparison, shared with
the notification suppression path). Cleared only by the user selecting the window — an agent
moving on to another state does not clear it.

**GC**: active window on `after-select-window` and `after-select-pane`; whole server on
`client-focus-in` (rare, and exactly when the user is about to read the entire status line)
and on demand via `gc --all`.

## Configuration

All options read at invocation time from server-scope user options (`tmux show -gqv`), never
cached, so `tmux source-file` takes effect instantly.

**Rendering** — one glyph per agent pane, in `list-panes` order, as today.

| Option | Default |
| --- | --- |
| `@tama_icon_running` / `_waiting` / `_error` / `_background` / `_idle` | `●` `◐` `✕` `⚙` `○` |
| `@tama_icon_set` | `glyphs` \| `pets` (emoji) \| `ascii`; individual icon options win |
| `@tama_show_idle` / `_show_background` | `on` / `on` |
| `@tama_icon_prefix` / `_suffix` / `_separator` | `" "` (only when ≥1 icon) / `""` / `""` |
| `@tama_flag_text` | `" *"` |

**Exported for the user to interpolate** (no auto-injection into the status line):
`@tama_icons` = `#(<plugin>/bin/tama icons #{window_id})`, `@tama_flag` =
`#{?@tama_window_flag,#{E:@tama_flag_text},}`, plus `@tama_bin` / `@tama_bin_dir`.

**Notifications**

| Option | Default |
| --- | --- |
| `@tama_notifications` | `on` |
| `@tama_backend` | `auto` — Darwin→`macos`, else `notify-send`→`libnotify`, else `none`; **only picks a backend whose binary actually exists**, so macOS without `terminal-notifier` resolves to `none` and `doctor` explains why. Also accepts a name or an absolute path to a third-party backend dir. |
| `@tama_notify_command` / `_dismiss_command` / `_focused_command` / `_focus_command` | `""` — per-capability override, same contract |
| `@tama_title_format` | `#{@tama_pane_agent} - #{b:pane_current_path}#{?@tama_pane_label, (#{@tama_pane_label}),}` — a **real tmux format string**, expanded with `display-message -p -t <pane>`. There is no plugin-specific template engine: "project" is not a concept, it is `#{b:pane_current_path}` and the user can write anything else. |
| `@tama_group_format` | `tmux-window-#{window_id}` — single source of truth for notify + dismiss |
| `@tama_label_command` | `""` — optional label provider, `sh -c "$cmd \"\$1\"" _ <window_id>`, result exposed as `@tama_pane_label`; empty → nothing runs |
| `@tama_suppress_when_focused` | `on` |
| `@tama_terminal_app` / `_terminal_bundle_id` | `$TERMINAL_APP_NAME` else `ghostty` / `$TERMINAL_BUNDLE_ID` else `com.mitchellh.ghostty` |
| `@tama_terminal_notifier` | resolved via `PATH`, then `/opt/homebrew/bin`, then `/usr/local/bin` |

**Lifecycle**: `@tama_manage_hooks` (`on`), `@tama_bind_mouse` (`off`), `@tama_gc_on_select`
(`on`), `@tama_gc_shells` (shell allowlist for the legacy `gc` path), `@tama_refresh` (`on`),
`@tama_subagent_retries` / `_retry_delay` (`5` / `0.05`).

## Notification pipeline

1. `@tama_notifications off` → exit 0.
2. **Suppression is an `AND`** (ADR-0004): tmux says this window is the active window of a
   session with an attached client, **and** the backend's `focused` capability agrees the
   terminal is frontmost showing that session. Both true → drop. A missing `focused`
   capability, or a backend that cannot tell, means deliver.
3. Expand `@tama_label_command` (if set) into `@tama_pane_label`, then expand
   `@tama_title_format` against the target pane.
4. Raise the window flag, build the group id from `@tama_group_format`, invoke the backend.

**Click action**: `select-window -t <window_id>` then `select-pane -t <pane_id>` then
`tama focus-window <session>`, chained so that a dead pane — or a dead window — still leaves
you with the terminal in front. Grouping stays per window (the `*` and the banner describe
the same thing), so a second agent pane in the same window replaces the first banner and the
click lands on whoever spoke last.

## Backends

`@tama_backend` resolves to a directory: bare name → `$PLUGIN_DIR/backends/<name>/`,
absolute path → used as-is, so third-party backends need no fork. Each capability is an
optional executable; missing means "unsupported" and the caller degrades (no `focused` →
never suppress; no `dismiss` → no-op). Payload in argv, context in env.

| Capability | argv | env | Contract |
| --- | --- | --- | --- |
| `notify` | `<title> <message>` | `TAMA_GROUP`, `_SESSION`, `_WINDOW_ID`, `_PANE_ID`, `_AGENT`, `_BIN` | Fire and forget, exit 0 |
| `dismiss` | `<group>` | `TAMA_SESSION`, `_WINDOW_ID` | Remove prior notifications in that group |
| `focused` | — | `TAMA_SESSION`, `_WINDOW_ID`, `_TERMINAL_APP` | exit 0 = user is looking at it |
| `focus` | `<session>` | `TAMA_WINDOW_ID`, `_TERMINAL_APP`, `_TERMINAL_BUNDLE_ID` | Bring that session's terminal window forward |

`backends/macos/*` ports `notify-macos`, `clear-notify-macos` and the `osascript` frontmost
check, with hardcoded paths replaced by option lookups. **`focus` ports only two of the
current three levels**: raise the terminal window whose title matches the session, else steal
a client with `switch-client` (no protected-session list — the hardcoded `main` goes away).
The third level — synthetic Cmd+N plus clipboard round-trip to open a new terminal window —
is out: it needs Accessibility permission, clobbers the clipboard, and is specific to one
terminal. It ships as an example in `docs/backends.md` for users to wire via
`@tama_focus_command`, which replaces the capability wholesale.

`backends/libnotify/*` uses `notify-send` with
`--hint=string:x-canonical-private-synchronous:$GROUP`; no `focused`, `focus` is a no-op.
`backends/none/*` all exit 0. `tests/fixtures/fake-backend/*` records argv+env into
`$TAMA_TEST_LOG`.

## TPM entrypoint (`tamagotchi.tmux`)

Runs on every `tmux source-file`, so it must be idempotent:

1. `PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"`.
2. Version guard: parse `tmux -V`, require **≥ 3.1a** (pane user options, `set-hook -a`,
   format modifiers). Below that, `display-message` a warning and exit 0 without wiring
   anything — partial installs produce confusing symptoms.
3. `tmux set -g @tama_bin` / `@tama_bin_dir` — the **only** discovery mechanism (ADR-0003).
4. Export the `@tama_icons` / `@tama_flag` format options.
5. If `@tama_manage_hooks` is `on`, append (never overwrite):
   ```tmux
   set-hook -ga after-select-window "run-shell -b '<bin> on-select'"
   set-hook -ga client-focus-in     "run-shell -b '<bin> on-select --all'"
   set-hook -ga after-select-pane   "run-shell -b '<bin> gc'"
   ```
6. If `@tama_bind_mouse` is `on`, install the two mouse bindings.

Documented load-order contract: a user's own non-append `set-hook -g` lines must appear
**before** the TPM `run` line, or they wipe the plugin's entries. Mouse bindings cannot be
appended to at all, so users who already bind `MouseDown1Status`/`MouseDown1Pane` keep
`@tama_bind_mouse off` and call `tama on-select` from their own bindings — the one piece of
unavoidable manual wiring, and it belongs in the README prominently.

## Integrations

`integrations/claude-code/hook` is the only one in v0.1. It is where Claude Code's payload
knowledge lives: `jq -r '.message'`, the `auth_success` filter, and the decision that a
delegated run (`.agent_id` present) should stay quiet. Events map to the core as today —
`UserPromptSubmit`/`PostToolUse` → `state running`, `AskUserQuestion`/`permission_prompt` →
`state waiting` + `notify`, `SubagentStart`/`Stop` → `state subagent-start|stop`,
`Stop` → `state idle` + `notify`, `SessionEnd` → `state clear`.

Codex and Gemini come in later iterations, against a core that no longer moves. `integrations/README.md`
states the best-effort promise (ADR-0002).

## Testing

- **shellcheck** over `bin/`, `libexec/`, `lib/`, `backends/`, `integrations/`,
  `tamagotchi.tmux`.
- **bats-core** with `tests/helper.bash` booting an isolated server
  (`tmux -L tama-test -f /dev/null new-session -d -s t`), `@tama_backend` pointed at the fake
  backend, `@tama_refresh off`. Requires the `$TMUX_CMD` indirection (default `tmux`,
  overridable via `TAMA_TMUX`) in every script.
- Cases worth locking down: `idle` + subagent → `background`; `show_background off` renders
  `running`; `clear` unsets all three pane options; duplicate `subagent-start` is idempotent;
  `subagent-stop` on an unknown id is a no-op; a second `state running` writes nothing and
  refreshes nothing; `icons` respects `show_idle off` and emits nothing (not a bare space)
  with no agent panes; `gc` clears when `…_pane_cmd` differs and preserves when it matches;
  `flag` does not flag the active window of its own session **but does** flag a same-index
  window in another session (the bug being fixed); `notify` suppresses only when both checks
  agree; **group id from `notify` equals group id from `dismiss` for the same window**; usage
  errors exit 2 and absent environment exits 0.
- **CI**: matrix `ubuntu-latest` + `macos-latest`, installing tmux, bats, shellcheck.

## Build order

Sliced by **complete path**, not by layer: each step ends with a real agent driving the
plugin, because most of the bugs in the current system are in the seams, not the pieces.
(A separate breakdown pass will turn these into tickets.)

1. **State, end to end** — skeleton (entrypoint, dispatcher, `lib/common.sh`,
   `lib/options.sh`, shellcheck CI), `state`/`icons`/`gc`/`flag`/`unflag`/`on-select`,
   `integrations/claude-code/hook` limited to state events, `examples/demo.tmux.conf`. Done
   when Claude Code running in the demo server moves the icons on its own.
2. **Notifications, end to end** — `lib/notify.sh`, `lib/backend.sh`, `notify`, `dismiss`,
   `focus-window`, `backends/none`, `backends/macos`, the notification half of the adapter,
   fake-backend tests. Done when a banner from a background window clicks back to the right
   pane and dismisses on select.
3. **Portability** — `backends/libnotify`, `auto` resolution with binary checks, `doctor`
   (tmux version, backend, dependencies, `set-titles-string "#S"`, status-line recipe, hook
   recipe), CI green on both OSes.
4. **Docs** — README (what it does in the first paragraph, options, status-line snippet, the
   manual mouse-binding note, dependencies), `docs/configuration.md`, `docs/cli.md`,
   `docs/backends.md` (including the Cmd+N focus example), `docs/integrations/claude-code.md`.
5. **Tag `v0.1.0`.**

## Verification (no dotfiles changes)

`examples/demo.tmux.conf` sources the plugin directly, sets
`window-status-format "#{window_index}:#{window_name}#{E:@tama_icons}#{E:@tama_flag}"` and
`status-interval 5`.

```sh
tmux -L tama-demo -f examples/demo.tmux.conf new-session -d -s demo
tmux -L tama-demo attach -t demo     # in a spare window
```

1. `doctor` prints tmux version, resolved backend and why, dependencies, the status-line
   snippet and the hook recipe; exits non-zero if anything is broken.
2. `state running Test` → `●`; `waiting` → `◐` **and** `*` if not the active window;
   `state clear` → gone, and `tmux show -p @tama_pane_state` reports nothing at all.
3. Subagents: `state subagent-start a`, then `state idle` → `⚙`; `subagent-stop a` → `○`.
4. Short-circuit: `state running` twice in a row → the second writes nothing (assert via a
   `TAMA_TMUX` wrapper that logs calls).
5. GC: set state, exit the process, select another pane → icon clears; leave a stale icon in
   a distant window, detach and re-attach → `client-focus-in` clears it too.
6. Cross-session flag: agent in `demo2:1` while attached to `demo:1` → `*` appears (the
   current system fails this).
7. Notification from a background window → banner with the templated title; click → correct
   window *and pane* selected, terminal focused; select the window → banner dismissed.
8. Suppression: same call with the window active **and** the terminal frontmost → nothing.
   Then minimize the terminal and repeat → banner appears.
9. Options: override `@tama_icon_running`, `_show_idle off`, `_flag_text`, `_title_format`
   → rendering changes with no reload.
10. Backend swap: `@tama_backend none` → silent, no error; `@tama_notify_command` pointing at
    a logging script → expected argv/env.
11. `bats tests/` and `shellcheck` pass locally and in CI.

Cleanup: `tmux -L tama-demo kill-server`.

## Later (out of scope now): dotfiles migration

- **Moves out** — all the scripts under "Source of truth", deleted once hooks point at the
  plugin.
- **Stays** — `tmux-window-label` / `tmux-set-window-label` / `tmux-rename-window` (becomes
  the value of `@tama_label_command`), `fzf-tmux-*`, `tmux-toggle-pane-border-status`,
  `tmux-move-window-to-new-session`, `tmux-kill-windows-except-current`. The Cmd+N focus
  script stays too, wired via `@tama_focus_command`.
- **`homebrew/update:11-12`** currently calls `tmux-notify-window` + `notify-macos` for a
  sudo prompt. With `notify-raw` dropped it keeps its own scripts or calls
  `terminal-notifier` directly — deliberately not the plugin's problem.
- `tmux/.tmux.conf` sets `@tama_label_command`, `@tama_bind_mouse off`, `@tama_manage_hooks
  off` (it owns the three shared hooks explicitly, avoiding the ordering hazard), and swaps
  the `#(...tmux-agent-icon...)#{?@notify, *,}` part of `@catppuccin_window_text` for
  `#{E:@tama_icons}#{E:@tama_flag}` — verify double expansion on tmux 3.7b.
- Hook configs to rewrite: `claude-code/.claude/settings.json` (points at
  `tama hook claude-code <event>`), `codex/.codex/hooks/agent-lifecycle`, `codex/rc`,
  `gemini/.gemini/settings.json`, `opencode/.config/opencode/plugins/tmux-agent-status.ts`
  (stays in the dotfiles; only the command strings and matching test assertions change — add
  a `TAMA_BIN` constant reading `process.env.TAMA_BIN` so tests can inject a fake).
  `tmux-toggle-sidebar` is dead code and gets deleted. A migration script copying old
  `@pane_*` values to the new names can be written **then**, against real values.
- Consider raising `status-interval` from `5` to `30`+: writes already push updates via
  `refresh-client -S`.
- Final sweep:
  `grep -rn 'tmux-agent-state\|agent-notify\|notify-macos\|@pane_status\|@notify' ~/.dotfiles`.

## Risks / gotchas

- `#()` runs one shell per window per `status-interval` — `icons` is the hottest path; keep
  it free of subshell fan-out.
- Subagent RMW stays racy under bursts; keep the retry loop, keep the failure benign, document
  the self-healing.
- The macOS `focused` capability depends on `set-titles-string "#S"`. With suppression as an
  `AND` this now fails toward *more* notifications, but `doctor` must still flag it.
- The macOS `focus` capability's `switch-client` level steals a client from another session —
  intentional, and a behavior worth stating in the docs.
- `#{E:}` needs tmux ≥ 2.9; pane user options, `set-hook -a` and format modifiers need
  ≥ 3.1a. Local tmux is 3.7b.
- `pets` uses double-width emoji, which tmux measures inconsistently across terminals; keep
  `glyphs` as default and test `pets` against a high window count before documenting it.
- The binary name `tama` is taken twice on public registries (`usik/tamagotchi` on npm — also
  a tmux TPM plugin with a pet theme — and `mlnja/tama` on crates.io). Harmless while nothing
  is installed onto `PATH` (ADR-0003), but it rules out ever shipping a `link` command
  without renaming first.
- Prior art is dense: `partner0/tmux-agent-status`, `accessd/tmux-agent-indicator`,
  `samleeney/tmux-agent-status`, `hiroppy/tmux-agent-sidebar`, `raine/workmux`. None pairs
  the status icons with an OS notification layer that clicks back to the right pane — that is
  the differentiator, and the README should lead with it.
- A joke name has a cost: the README's first paragraph must say plainly what the plugin does.

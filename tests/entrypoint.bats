#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

@test "loading the plugin exports its bin path as tmux options" {
  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_plugin_wired "$PLUGIN_ROOT"
}

@test "loading the plugin changes nothing else about the server" {
  local before
  before="$(tama_server_state)"

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # Only its own options and its own hooks may differ: the plugin must not touch the
  # status line or the key bindings the user configured. Where the exported formats go
  # in the status line is the user's decision, not the plugin's.
  #
  # The hooks are the exception the flag and the sweep need — clearing a mark when the
  # user selects a window, and not showing a dead agent as busy, cannot be the user's
  # manual steps. Each is normalised back to the bare hook name that `show-hooks -g`
  # prints for an empty hook, rather than deleted: deleting the line would also hide a
  # *second* entry appearing there, and the pattern names the plugin, so a hook wired
  # to anything else still fails here.
  local after
  after="$(tama_server_state | grep -v '^@tama_' |
    sed -E 's%^(after-select-window|after-select-pane|client-focus-in|client-attached)\[[0-9]+\] run-shell -b ".*@tama_bin.*"$%\1%')"
  assert_equal "$after" "$(printf '%s\n' "$before" | grep -v '^@tama_')"
}

@test "the plugin appends its hooks and leaves the user's own alone" {
  # tmux hooks are an array and `set-hook -ga` appends, which is the only safe way in:
  # assigning would silently disable whatever the user had wired to the same event.
  # Every event the plugin touches, because appending on one and assigning on another
  # is exactly the kind of asymmetry nobody notices until their own hook stops firing.
  local event
  for event in after-select-window after-select-pane client-focus-in client-attached; do
    test_tmux set-hook -ga "$event" "run-shell -b 'echo mine'"
  done

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  local hooks
  for event in after-select-window after-select-pane client-focus-in client-attached; do
    hooks="$(test_tmux show-options -g "$event")"
    assert_contains "$hooks" 'echo mine' "the user's $event hook"
    assert_contains "$hooks" '@tama_bin' "the plugin's $event hook"
  done
}

@test "the plugin wires the sweep to pane selection and to the terminal regaining focus" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # The four events the plugin needs, and what each is asked to do: the cheap sweep
  # of one window on a pane selection, and the whole server when the user comes back
  # to the terminal — which is also the only chance to take the mark off a window they
  # attached to without ever selecting it. Coming back is two events, not one: a
  # terminal that reports focus fires client-focus-in, and a bare `attach` fires
  # client-attached, so wiring only one leaves the other kind of terminal uncovered.
  assert_contains "$(test_tmux show-options -g after-select-window)" \
    'on-select --window' 'the window-selection hook'
  assert_contains "$(test_tmux show-options -g after-select-pane)" \
    'gc --window' 'the pane-selection hook'
  assert_contains "$(test_tmux show-options -g client-focus-in)" \
    'on-select --all --window' 'the focus-in hook'
  assert_contains "$(test_tmux show-options -g client-attached)" \
    'on-select --all --window' 'the attach hook'
}

@test "the wired hook survives the plugin directory moving" {
  # The recipe references @tama_bin rather than carrying a path, and run-shell expands
  # it when the hook fires. So a user who moves their clone gets a working hook from
  # the next load with nothing to rewire, and no hook is left pointing at a directory
  # that has gone.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  local hooks
  hooks="$(test_tmux show-options -g after-select-window)"
  assert_contains "$hooks" '@tama_bin' 'the hook recipe'
  case "$hooks" in
    *"$PLUGIN_ROOT"*)
      printf 'the hook hard-coded the plugin path: %s\n' "$hooks" >&2
      return 1
      ;;
  esac
}

@test "hook management can be turned off" {
  test_tmux set -g @tama_manage_hooks off

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # Off means tmux's hooks are left exactly as they were, while everything else the
  # plugin exports still works — a user who manages their own configuration calls
  # `tama on-select` and `tama gc` from hooks they wrote.
  local event
  for event in after-select-window after-select-pane client-focus-in client-attached; do
    assert_equal "$(test_tmux show-options -g "$event" 2>/dev/null)" "$event"
  done
  assert_plugin_wired "$PLUGIN_ROOT"
}

# The four events back to empty, so a spelling can be tried on a server the last one
# did not already wire. `set-hook -gu` unsets the array; `show-options -g` then prints
# the bare event name, which is what an unwired event looks like.
unwire_hooks() {
  local event
  for event in after-select-window after-select-pane client-focus-in client-attached; do
    test_tmux set-hook -gu "$event" 2>/dev/null || true
  done
}

@test "every spelling tmux has for off turns hook management off" {
  local spelling event
  for spelling in $TAMA_OFF_SPELLINGS; do
    unwire_hooks
    test_tmux set -g @tama_manage_hooks "$spelling"

    run "$PLUGIN_ROOT/tamagotchi.tmux"
    assert_success || return 1

    for event in after-select-window after-select-pane client-focus-in client-attached; do
      [ "$(test_tmux show-options -g "$event" 2>/dev/null)" = "$event" ] || {
        printf '@tama_manage_hooks %s still wired %s: %s\n' "$spelling" "$event" \
          "$(test_tmux show-options -g "$event")" >&2
        return 1
      }
    done
  done
}

@test "every other spelling wires the hooks, including the ones that look like off" {
  # The worst of the three options read strictly against `on`, and the reason this
  # test exists at all: `@tama_manage_hooks 1` — or `true`, or `yes` — used to wire
  # nothing whatsoever. No mark was ever cleared, no sweep ever ran, and nothing on
  # screen or in doctor said why, because the plugin believed the user had asked for
  # exactly that. Silence is what makes it worth pinning all five values.
  local spelling
  for spelling in $TAMA_ON_SPELLINGS; do
    unwire_hooks
    test_tmux set -g @tama_manage_hooks "$spelling"

    run "$PLUGIN_ROOT/tamagotchi.tmux"
    assert_success || return 1

    test_tmux show-hooks -g | grep -qF -- '@tama_bin' || {
      printf '@tama_manage_hooks %s wired no hooks at all\n' "$spelling" >&2
      return 1
    }
  done
}

@test "loading the plugin exports the icon format for the user to interpolate" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # A format the user puts where they want it, that runs the icon command for the
  # window being drawn. Rendered rather than compared as a string, because what
  # matters is that tmux and the shell agree on what it means — and reached through
  # the CLI, so it cannot pass on a value the test wrote itself.
  local pane
  pane="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  run "$PLUGIN_ROOT/bin/tama" state running --pane "$pane"
  assert_success
  # Rendered against the window's own id rather than the session, because that is
  # what the exported format passes: a session name would resolve to whatever window
  # it is looking at, and would pass an implementation that named windows by index.
  assert_equal "$(tama_render_icons "$(test_tmux display-message -p -t "$pane" '#{window_id}')")" ' ●'
}

@test "loading exports a session summary without rewriting status-left" {
  test_tmux set -g status-left 'mine #{session_name}'
  local pane
  pane="$(tama_pane_of t:0)"
  test_tmux set -p -t "$pane" @tama_pane_state_main running

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_equal "$(test_tmux show -gv status-left)" 'mine #{session_name}'
  assert_equal "$(tama_render_summary t)" '● 1 ◐ 0 ○ 0'
}

@test "the exported options are reachable from a tmux format" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # This is how the status line and every hook recipe will reach them, so it is
  # the observation that matters, not the scope they happen to be stored in.
  assert_equal "$(test_tmux display-message -p '#{@tama_bin}')" "$PLUGIN_ROOT/bin/tama"
}

@test "the exported bin option is a runnable absolute path" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  local bin
  bin="$(test_tmux show -gqv @tama_bin)"
  [ -x "$bin" ]
  run "$bin" version
  assert_success
}

@test "loading is idempotent across repeated source-file" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  local first
  first="$(tama_server_state)"

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_equal "$(tama_server_state)" "$first"
}

@test "loading works from a clone reached through a symlink" {
  local link="$BATS_TEST_TMPDIR/linked-plugin"
  ln -s "$PLUGIN_ROOT" "$link"

  run "$link/tamagotchi.tmux"
  assert_success

  assert_plugin_wired "$PLUGIN_ROOT"
  local bin
  bin="$(test_tmux show -gqv @tama_bin)"
  [ -x "$bin" ]
}

@test "loading works from a clone at any other path" {
  local plugin="$BATS_TEST_TMPDIR/elsewhere/plugin"
  mkdir -p "$(dirname "$plugin")"
  tama_copy_plugin "$plugin"
  # The plugin reports its resolved location, and $TMPDIR is itself a symlink
  # on macOS.
  plugin="$(cd -P "$plugin" && pwd)"

  run "$plugin/tamagotchi.tmux"
  assert_success

  assert_plugin_wired "$plugin"
}

@test "an incomplete plugin directory says so and wires nothing" {
  local broken="$BATS_TEST_TMPDIR/broken"
  mkdir -p "$broken"
  cp "$PLUGIN_ROOT/tamagotchi.tmux" "$broken/"

  run --separate-stderr "$broken/tamagotchi.tmux"
  [ "$status" -ne 0 ]
  assert_stderr_contains 'not a complete plugin directory'
  assert_plugin_not_wired
}

@test "a clone whose bin/tama cannot be run wires nothing" {
  # Otherwise every hook on the machine would fail on a path that is published
  # but not runnable — an archive download or a lost mode bit.
  local plugin="$BATS_TEST_TMPDIR/no-exec"
  tama_copy_plugin "$plugin"
  chmod -x "$plugin/bin/tama"

  run --separate-stderr "$plugin/tamagotchi.tmux"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
  assert_plugin_not_wired
}

@test "below the minimum tmux version it warns, naming both versions" {
  tama_use_fake_tmux 'tmux 2.9'

  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # The warning has to reach the user whether or not a client is attached, so it
  # goes to stderr as well as to tmux.
  assert_stderr_contains '2.9'
  assert_stderr_contains '3.1a'
  run grep -q 'too old' "$TAMA_FAKE_TMUX_LOG"
  assert_success
}

@test "the warning cannot smuggle a tmux format out of the version string" {
  # display-message expands its argument as a format, and a format can run a
  # command, so nothing derived from `tmux -V` may keep its `#`.
  tama_use_fake_tmux 'tmux 2.9#(touch "$TAMA_FAKE_TMUX_LOG.pwned")'

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  [ ! -e "$TAMA_FAKE_TMUX_LOG.pwned" ]
  run grep -q '#' "$TAMA_FAKE_TMUX_LOG"
  assert_status 1
}

@test "below the minimum tmux version it wires nothing at all" {
  local before
  before="$(tama_server_state)"

  tama_use_fake_tmux 'tmux 3.0a'
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  assert_plugin_not_wired
  assert_equal "$(tama_server_state)" "$before"
}

@test "the minimum tmux version itself is supported, and warns about nothing" {
  tama_use_fake_tmux 'tmux 3.1a'

  run --separate-stderr "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  [ -z "$stderr" ]
  assert_plugin_wired "$PLUGIN_ROOT"
  run grep -q 'display-message' "$TAMA_FAKE_TMUX_LOG"
  assert_status 1
}

@test "a version without the bugfix letter is older than one with it" {
  assert_version_rejected 'tmux 3.1'
}

@test "a later bugfix release of the minimum version is supported" {
  assert_version_supported 'tmux 3.1b'
}

@test "a two-digit minor version is compared numerically, not lexically" {
  assert_version_supported 'tmux 3.10'
}

@test "a newer major version is supported" {
  assert_version_supported 'tmux 4.0'
}

@test "an older major version is rejected" {
  assert_version_rejected 'tmux 2.8'
}

@test "a distro build with a third version component is supported" {
  assert_version_supported 'tmux 3.1.2'
}

@test "a release candidate of an old version is still rejected" {
  # The suffix must not be mistaken for a build prefix and strip the version.
  assert_version_rejected 'tmux 2.9-rc'
}

@test "a development build of a supported version is supported" {
  assert_version_supported 'tmux next-3.4'
}

@test "an unparseable tmux version is given the benefit of the doubt" {
  assert_version_supported 'tmux master'
}

@test "a tmux that cannot report its version is given the benefit of the doubt" {
  tama_use_fake_tmux ''
  export TAMA_FAKE_TMUX_FAIL_VERSION=1

  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  assert_plugin_wired "$PLUGIN_ROOT"
}

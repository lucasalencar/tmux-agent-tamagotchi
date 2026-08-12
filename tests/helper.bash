# shellcheck shell=bash
# $status and $output are set by bats around every `run`.
# shellcheck disable=SC2154
#
# Shared setup for the bats suite.
#
# Every test that needs tmux boots its own server on a private socket and points
# the CLI at it through TAMA_TMUX, so nothing touches the user's tmux.

# -P because every script under test reports its own location with symlinks
# resolved, and the plugin's own documented dev setup is a symlinked clone.
PLUGIN_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN_ROOT

# Names a socket for this test without booting anything on it.
tama_reserve_socket() {
  TAMA_SOCKET="$1-$$-${BATS_TEST_NUMBER:-0}"
  export TAMA_SOCKET
}

# Boots an isolated tmux server with an empty config and exports the
# indirection every script uses to reach it.
tama_start_server() {
  tama_reserve_socket tamatest
  # The indirection goes into the environment *before* the server boots as well as
  # after, so that jobs the server spawns for itself — a status line `#()` format, a
  # hook — inherit it and cannot reach the user's tmux. $TMUX cannot be exported
  # this early: a tmux client that sees it believes it is nested.
  export TAMA_TMUX=tmux
  export TAMA_TMUX_ARGS="-L $TAMA_SOCKET"
  test_tmux -f /dev/null new-session -d -s t
  tama_point_at_server
}

# Points the CLI at this test's server, for a suite that booted its own.
# The CLI only checks that $TMUX is non-empty; the socket it names is irrelevant
# because every tmux call goes through TAMA_TMUX. All three are exported after the
# server is up, since a tmux client that sees $TMUX believes it is nested.
tama_point_at_server() {
  export TAMA_TMUX=tmux
  export TAMA_TMUX_ARGS="-L $TAMA_SOCKET"
  export TMUX="/tmp/$TAMA_SOCKET,0,0"
  # Whatever tmux the suite is being run from must not reach into it: a test that
  # means "no pane was given" has to mean that on a developer's machine too.
  unset TMUX_PANE
}

tama_kill_server() {
  if [ -n "${TAMA_SOCKET:-}" ]; then
    tmux -L "$TAMA_SOCKET" kill-server 2>/dev/null || true
  fi
}

# Talks to the test server directly, for arranging fixtures and asserting.
test_tmux() {
  tmux -L "$TAMA_SOCKET" "$@"
}

# Copies the plugin to another path, which is also how the tests exercise the
# promise that it works from any clone path. Copies everything so a test copy
# cannot silently lag behind the real plugin as directories are added.
tama_copy_plugin() {
  local dest="$1"
  mkdir -p "$dest"
  find "$PLUGIN_ROOT" -maxdepth 1 -mindepth 1 \
    ! -name .git ! -name .reviews \
    -exec cp -R {} "$dest/" \;
}

# Stands in for any subcommand: the dispatcher routes by file name, so what it
# does with a real one it does with this. Reports what it received the way a real
# subcommand would have to read it.
tama_add_stub_subcommand() {
  mkdir -p "$1/libexec"
  cat >"$1/libexec/stub" <<'STUB'
#!/usr/bin/env bash
printf 'argc: %s\n' "$#"
printf 'arg: %s\n' "$@"
printf 'plugin_dir: %s\n' "${TAMA_PLUGIN_DIR:-unset}"
exit "${TAMA_STUB_EXIT:-0}"
STUB
  chmod +x "$1/libexec/stub"
}

# Puts a `tmux` on PATH that talks to this test's server, so a snippet written
# for a user's shell — a hook recipe — can be run verbatim without reaching the
# real tmux.
tama_shim_tmux_on_path() {
  local bin="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$bin"
  cat >"$bin/tmux" <<SHIM
#!/bin/sh
exec $(command -v tmux) -L "$TAMA_SOCKET" "\$@"
SHIM
  chmod +x "$bin/tmux"
  PATH="$bin:$PATH"
  export PATH
}

assert_success() {
  assert_status 0
}

assert_status() {
  if [ "$status" -ne "$1" ]; then
    printf 'expected exit %s, got %s\noutput: %s\n' "$1" "$status" "$output" >&2
    return 1
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *)
      printf 'expected %s to contain %s\ngot: %s\n' "${3:-the value}" "$2" "$1" >&2
      return 1
      ;;
  esac
}

assert_output_contains() {
  assert_contains "$output" "$1" 'stdout'
}

assert_stderr_contains() {
  assert_contains "$stderr" "$1" 'stderr'
}

# The whole usage-error invariant in one place: exit 2, nothing on stdout, and a
# message on stderr naming what the user got wrong.
assert_usage_error() {
  assert_status 2 || return 1
  if [ -n "$output" ]; then
    printf 'expected nothing on stdout, got: %s\n' "$output" >&2
    return 1
  fi
  [ -n "$stderr" ] || {
    printf 'expected a message on stderr\n' >&2
    return 1
  }
  [ "$#" -eq 0 ] || assert_stderr_contains "$1"
}

# The icon string for a window, straight from the CLI.
tama_icons() {
  "$PLUGIN_ROOT/bin/tama" icons "$1"
}

# The icon string the way the status line produces it, which is the only claim
# worth making about the exported format: tmux expands `@tama_icons` — turning
# the escaped plugin path back into a path and substituting the window id — and
# hands the result to a shell.
#
# It has to be assembled here because `display-message` does not run format jobs,
# so no amount of expanding a status-line format from a test will run the icon
# command. Attaching a real client would, but only after a status-interval tick.
tama_render_icons() {
  local job command
  job="$(test_tmux show -gqv @tama_icons)"
  case "$job" in
    '#('*')') ;;
    *)
      printf 'expected @tama_icons to be a #() job, got: %s\n' "$job" >&2
      return 1
      ;;
  esac
  # What is left is the format tmux expands before running it.
  job="${job#'#('}"
  # At the *first* `)`, which is where tmux ends a job — a helper that stripped at
  # the last one would accept a command tmux would have truncated.
  job="${job%%')'*}"
  command="$(test_tmux display-message -p -t "$1" "$job")"
  # /bin/sh, because that is what tmux runs a job with.
  sh -c "$command"
}

# A pane option as tmux stores it. Without -q so that an option which was never
# set fails instead of reading as empty — the difference between a cleared pane
# and an agent pane.
assert_pane_option() {
  local value
  value="$(test_tmux show -p -t "$1" -v "@tama_pane_$2")" || {
    printf 'expected @tama_pane_%s to be set on %s\n' "$2" "$1" >&2
    return 1
  }
  assert_equal "$value" "$3"
}

assert_pane_option_unset() {
  local value
  if value="$(test_tmux show -p -t "$1" -v "@tama_pane_$2")"; then
    printf 'expected @tama_pane_%s to be unset on %s, got: %s\n' "$2" "$1" "$value" >&2
    return 1
  fi
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'expected %s\n     got %s\n' "$2" "$1" >&2
    return 1
  fi
}

# Makes `bash` on PATH the bash macOS ships — 3.2, which neither parses nor runs
# everything bash 5 accepts — or skips the test where there is none. Every script
# in the plugin starts with `#!/usr/bin/env bash`, so this reaches all of them and
# not only the file a test invokes.
tama_use_bash_32_or_skip() {
  [ -x /bin/bash ] || skip 'no /bin/bash on this machine'
  case "$(/bin/bash --version | head -1)" in
    *'version 3.'*) ;;
    *) skip '/bin/bash is not 3.x here' ;;
  esac

  local shim="$BATS_TEST_TMPDIR/bash32"
  mkdir -p "$shim"
  ln -sf /bin/bash "$shim/bash"
  PATH="$shim:$PATH"
  export PATH
}

# Points the tmux indirection at a fake that reports the given version string
# and logs every call, so the version guard can be driven from a test.
tama_use_fake_tmux() {
  export TAMA_FAKE_TMUX_VERSION="$1"
  export TAMA_FAKE_TMUX_SOCKET="$TAMA_SOCKET"
  export TAMA_FAKE_TMUX_LOG="$BATS_TEST_TMPDIR/tmux-calls.log"
  : >"$TAMA_FAKE_TMUX_LOG"
  export TAMA_TMUX="$PLUGIN_ROOT/tests/fixtures/fake-tmux"
  export TAMA_TMUX_ARGS=''
}

# Points the tmux indirection at the logging fake — reporting the real version,
# so everything behaves as it does on this machine — and starts a fresh log.
tama_log_tmux_calls() {
  tama_use_fake_tmux "$(tmux -V)"
}

# Whether tmux was asked to run a command. One argument per line in the log, so
# this matches the command word itself and not a value that happens to contain it.
assert_tmux_command() {
  if ! grep -qx -- "$1" "$TAMA_FAKE_TMUX_LOG"; then
    printf 'expected tmux to be asked to %s; calls were:\n%s\n' \
      "$1" "$(cat "$TAMA_FAKE_TMUX_LOG")" >&2
    return 1
  fi
}

refute_tmux_command() {
  if grep -qx -- "$1" "$TAMA_FAKE_TMUX_LOG"; then
    printf 'expected tmux NOT to be asked to %s; calls were:\n%s\n' \
      "$1" "$(cat "$TAMA_FAKE_TMUX_LOG")" >&2
    return 1
  fi
}

# Everything the entrypoint could have wired, as one string: options at both
# scopes, hooks and key bindings. Whatever the entrypoint grows to install, a
# second load must not change this.
tama_server_state() {
  test_tmux show -g
  test_tmux show -s
  test_tmux show-hooks -g
  test_tmux list-keys
}

# Both discovery options point at the given clone.
assert_plugin_wired() {
  local root="$1"
  assert_equal "$(test_tmux show -gqv @tama_bin)" "$root/bin/tama" || return 1
  assert_equal "$(test_tmux show -gqv @tama_bin_dir)" "$root/bin"
}

assert_plugin_not_wired() {
  assert_equal "$(test_tmux show -gqv @tama_bin)" '' || return 1
  assert_equal "$(test_tmux show -gqv @tama_bin_dir)" ''
}

# Loads the plugin against a tmux that reports the given version, and says
# whether that version is supported. Keeps the version matrix readable as a
# table of version -> verdict.
assert_version_supported() {
  tama_use_fake_tmux "$1"
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success || return 1
  assert_plugin_wired "$PLUGIN_ROOT"
}

assert_version_rejected() {
  local before
  before="$(tama_server_state)"

  tama_use_fake_tmux "$1"
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success || return 1
  # Below the minimum the entrypoint wires nothing *at all*, so compare the whole
  # server rather than only the two options it would have set.
  assert_equal "$(tama_server_state)" "$before"
}

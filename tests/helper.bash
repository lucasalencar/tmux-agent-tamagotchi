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
  TAMA_SOCKET="${1:-tamatest}-$$-${BATS_TEST_NUMBER:-0}"
  export TAMA_SOCKET
}

# Boots an isolated tmux server with an empty config and exports the
# indirection every script uses to reach it.
tama_start_server() {
  tama_reserve_socket
  # Exported before the server boots, so jobs the server itself spawns — status
  # line `#()` formats, hooks — inherit it and cannot reach the user's tmux.
  export TAMA_TMUX=tmux
  export TAMA_TMUX_ARGS="-L $TAMA_SOCKET"
  test_tmux -f /dev/null new-session -d -s t
  # The CLI only checks that $TMUX is non-empty; the socket it points at is
  # irrelevant because every tmux call goes through TAMA_TMUX.
  export TMUX="/tmp/$TAMA_SOCKET,0,0"
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
STUB
  chmod +x "$1/libexec/stub"
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

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'expected %s\n     got %s\n' "$2" "$1" >&2
    return 1
  fi
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

# Everything the entrypoint could have wired, as one string: options at both
# scopes, hooks and key bindings. Whatever the entrypoint grows to install, a
# second load must not change this.
tama_server_state() {
  test_tmux show -g
  test_tmux show -s
  test_tmux show-hooks -g
  test_tmux list-keys
}

# Both discovery options point at the given clone (this one by default).
assert_plugin_wired() {
  local root="${1:-$PLUGIN_ROOT}"
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
  assert_plugin_wired
}

assert_version_rejected() {
  tama_use_fake_tmux "$1"
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success || return 1
  assert_plugin_not_wired
}

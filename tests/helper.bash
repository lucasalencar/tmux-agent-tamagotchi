# shellcheck shell=bash
# Shared setup for the bats suite.
#
# Every test that needs tmux boots its own server on a private socket and points
# the CLI at it through TAMA_TMUX, so nothing touches the user's tmux.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN_ROOT

# Boots an isolated tmux server with an empty config and exports the
# indirection every script uses to reach it.
tama_start_server() {
  TAMA_SOCKET="tamatest-$$-${BATS_TEST_NUMBER:-0}"
  export TAMA_SOCKET
  export TAMA_TMUX="tmux -L $TAMA_SOCKET"
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
# promise that it works from any clone path.
tama_copy_plugin() {
  local dest="$1"
  mkdir -p "$dest/libexec"
  cp -R "$PLUGIN_ROOT/bin" "$PLUGIN_ROOT/lib" "$dest/"
  cp "$PLUGIN_ROOT/tamagotchi.tmux" "$dest/"
}

# Stands in for any subcommand: the dispatcher routes by file name, so what it
# does with a real one it does with this.
tama_add_stub_subcommand() {
  cat >"$1/libexec/stub" <<'STUB'
#!/usr/bin/env bash
printf 'stub ran: %s\n' "$*"
STUB
  chmod +x "$1/libexec/stub"
}

# Points the tmux indirection at a fake that reports the given version string
# and logs every call, so the version guard can be driven from a test.
tama_use_fake_tmux() {
  export TAMA_FAKE_TMUX_VERSION="$1"
  export TAMA_FAKE_TMUX_SOCKET="$TAMA_SOCKET"
  export TAMA_FAKE_TMUX_LOG="$BATS_TEST_TMPDIR/tmux-calls.log"
  : >"$TAMA_FAKE_TMUX_LOG"
  export TAMA_TMUX="$PLUGIN_ROOT/tests/fixtures/fake-tmux"
}

assert_success() {
  if [ "$status" -ne 0 ]; then
    printf 'expected exit 0, got %s\noutput: %s\n' "$status" "$output" >&2
    return 1
  fi
}

assert_status() {
  if [ "$status" -ne "$1" ]; then
    printf 'expected exit %s, got %s\noutput: %s\n' "$1" "$status" "$output" >&2
    return 1
  fi
}

assert_output_contains() {
  case "$output" in
    *"$1"*) ;;
    *)
      printf 'expected output to contain %s\noutput: %s\n' "$1" "$output" >&2
      return 1
      ;;
  esac
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'expected %s\n     got %s\n' "$2" "$1" >&2
    return 1
  fi
}

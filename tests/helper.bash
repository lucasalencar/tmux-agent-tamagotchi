# shellcheck shell=bash
# $status and $output are set by bats around every `run`.
# shellcheck disable=SC2154
#
# Shared isolated-tmux setup for the bats suite.

# -P because every script under test reports its own location with symlinks
# resolved, and the plugin's own documented dev setup is a symlinked clone.
PLUGIN_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN_ROOT

# shellcheck source=tests/lib/tmux-test-server.sh
. "$PLUGIN_ROOT/tests/lib/tmux-test-server.sh"

# tmux's own vocabulary for a flag option turned off — what lib/options.sh reads and
# what both the README and `tama --help` print. It lives here once because a suite
# that only ever wrote `off` is exactly what let three of the plugin's options go on
# parsing `false` as *on*: every boolean option is now driven against all four, and
# tests/readme.bats binds the two documents to this list and to what the plugin does.
# shellcheck disable=SC2034  # read by the bats suites, which shellcheck cannot see
TAMA_OFF_SPELLINGS='off no 0 false'

# Values outside that vocabulary, which must therefore leave an option on. The first
# four are the ones a reader comparing against `on` alone took for off; `offf` is the
# typo the vocabulary is deliberately tolerant of.
# shellcheck disable=SC2034  # read by the bats suites, which shellcheck cannot see
TAMA_ON_SPELLINGS='on yes 1 true offf'

tama_start_server() {
  tmux_test_server_start /dev/null t tama_prepare_test_server_environment || return 1
  tama_no_backend
  tama_point_at_server
}

tama_prepare_test_server_environment() {
  export TAMA_TMUX=tmux
  export TAMA_TMUX_ARGS="-L $TMUX_TEST_SOCKET"
}

# Disable auto so tests never reach a developer's real notifier.
tama_no_backend() {
  tmux_test_server_run set -g @tama_backend ''
}

# Export only after startup because tmux treats an existing TMUX as nesting.
tama_point_at_server() {
  tama_prepare_test_server_environment
  export TMUX="/tmp/$TMUX_TEST_SOCKET,0,0"
  # Whatever tmux the suite is being run from must not reach into it: a test that
  # means "no pane was given" has to mean that on a developer's machine too.
  unset TMUX_PANE
}

tama_arrange_sleeping_pane() { # <pane> [cwd]
  local command='' pane="$1" cwd="${2:-}" waited=0
  if [ -n "$cwd" ]; then
    tmux_test_server_run respawn-pane -k -t "$pane" -c "$cwd" 'sleep 300'
  else
    tmux_test_server_run respawn-pane -k -t "$pane" 'sleep 300'
  fi
  while [ "$command" != sleep ] && [ "$waited" -lt 50 ]; do
    command="$(
      tmux_test_server_run display-message -p -t "$pane" '#{pane_current_command}'
    )"
    [ "$command" = sleep ] || sleep 0.1
    waited=$((waited + 1))
  done
  [ "$command" = sleep ]
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

# Stands in for any agent's adapter: `tama hook` routes by directory name, so what
# it does with a real integration it does with this. Reports what it received the
# way an adapter would have to read it, including how it reaches the core.
tama_add_stub_integration() { # <plugin_dir> <agent>
  mkdir -p "$1/integrations/$2"
  cat >"$1/integrations/$2/hook" <<'STUB'
#!/usr/bin/env bash
printf 'argc: %s\n' "$#"
printf 'arg: %s\n' "$@"
printf 'plugin_dir: %s\n' "${TAMA_PLUGIN_DIR:-unset}"
printf 'tama_bin: %s\n' "${TAMA_BIN:-unset}"
exit "${TAMA_STUB_EXIT:-0}"
STUB
  chmod +x "$1/integrations/$2/hook"
}

# Puts a `tmux` on PATH that talks to this test's server, so a snippet written
# for a user's shell — a hook recipe — can be run verbatim without reaching the
# real tmux.
tama_shim_tmux_on_path() {
  _tmux_test_server_require_isolated_socket || return 1
  local bin="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$bin"
  cat >"$bin/tmux" <<SHIM
#!/bin/sh
exec $(command -v tmux) -L "$TMUX_TEST_SOCKET" "\$@"
SHIM
  chmod +x "$bin/tmux"
  PATH="$bin:$PATH"
  export PATH
}

# Where the fake backend records what it was asked to do. Exported *before* the test
# server boots, because the backend is also invoked from tmux hooks — a window
# selection dismissing a banner — and a hook's `run-shell` inherits the environment the
# server was started with, not the one the test has now.
tama_fake_backend_env() {
  export TAMA_TEST_LOG="$BATS_TEST_TMPDIR/backend.log"
  : >"$TAMA_TEST_LOG"
  # The default is "the terminal is not in front", so a test that says nothing about
  # focus is describing a user who is not looking. See the fixture.
  export TAMA_FAKE_FOCUSED=1
}

# Points the plugin at the fake backend, by absolute path — which is also how a
# third-party backend is configured, so this exercises that resolution rather than a
# path only the tests can produce.
tama_use_fake_backend() {
  tmux_test_server_run set -g @tama_backend "$PLUGIN_ROOT/tests/fixtures/fake-backend"
}

# A copy of the fake backend with one capability missing, for the claims about what the
# plugin does when a platform cannot do something. Prints the path.
tama_fake_backend_without() { # <capability>
  local dir="$BATS_TEST_TMPDIR/backend-without-$1"
  mkdir -p "$dir"
  cp "$PLUGIN_ROOT"/tests/fixtures/fake-backend/* "$dir/"
  rm -f "$dir/$1"
  printf '%s' "$dir"
}

# How many times the backend was asked for <capability>.
tama_backend_calls() { # <capability>
  grep -cx -- "$1" "$TAMA_TEST_LOG" 2>/dev/null || true
}

# Waits for a capability a tmux hook was supposed to reach. The entrypoint wires
# `run-shell -b`, which is deliberately asynchronous, so the assertion has to be
# "eventually" or it is timing noise.
wait_until_backend_called() { # <capability>
  local waited=0
  while [ "$(tama_backend_calls "$1")" -eq 0 ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'the backend was not asked to %s within 10s; calls were:\n%s\n' \
        "$1" "$(cat "$TAMA_TEST_LOG")" >&2
      return 1
    fi
    sleep 0.05
  done
}

assert_backend_called() { # <capability>
  if [ "$(tama_backend_calls "$1")" -eq 0 ]; then
    printf 'expected the backend to be asked to %s; calls were:\n%s\n' \
      "$1" "$(cat "$TAMA_TEST_LOG")" >&2
    return 1
  fi
}

refute_backend_called() { # <capability>
  if [ "$(tama_backend_calls "$1")" -ne 0 ]; then
    printf 'expected the backend NOT to be asked to %s; calls were:\n%s\n' \
      "$1" "$(cat "$TAMA_TEST_LOG")" >&2
    return 1
  fi
}

# One value the backend was given, exactly as it arrived: `argv1`, `argv2`, `argc`, or
# `env.TAMA_GROUP` and its siblings. Fails loudly rather than reading as empty when the
# capability was never called at all.
tama_backend_value() { # <capability> <what>
  local file="$TAMA_TEST_LOG.$1.$2"
  if [ ! -e "$file" ]; then
    printf 'the backend recorded no %s for %s; calls were:\n%s\n' \
      "$2" "$1" "$(cat "$TAMA_TEST_LOG")" >&2
    return 1
  fi
  cat "$file"
}

assert_backend_value() { # <capability> <what> <expected>
  local actual
  actual="$(tama_backend_value "$1" "$2")" || return 1
  if [ "$actual" != "$3" ]; then
    printf 'expected the %s of %s to be %s\n     got %s\n' "$2" "$1" "$3" "$actual" >&2
    return 1
  fi
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

refute_output_contains() {
  case "$output" in
    *"$1"*)
      printf 'expected stdout NOT to contain %s\ngot: %s\n' "$1" "$output" >&2
      return 1
      ;;
  esac
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
  job="$(tmux_test_server_run show -gqv @tama_icons)"
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
  command="$(tmux_test_server_run display-message -p -t "$1" "$job")"
  # /bin/sh, because that is what tmux runs a job with.
  sh -c "$command"
}

# The session summary as exported for composition into status-left.
tama_render_summary() { # <session target>
  local job command
  job="$(tmux_test_server_run show -gqv @tama_status_summary)"
  case "$job" in
    '#('*')') ;;
    *)
      printf 'expected @tama_status_summary to be a #() job, got: %s\n' "$job" >&2
      return 1
      ;;
  esac
  job="${job#'#('}"
  job="${job%%')'*}"
  command="$(tmux_test_server_run display-message -p -t "$1" "$job")"
  sh -c "$command"
}

# Attaches a real client to <session>, without a terminal.
#
# The flag's whole condition is whether the user is looking, and half of that is
# whether anybody is attached at all — so a suite that never attaches a client can
# only ever test the "nobody is there" half, and would pass an implementation that
# flagged the window the user is staring at.
#
# Control mode (`-C`) is what makes it possible: it speaks a line protocol over
# ordinary pipes, so it needs no pty and behaves the same on both CI platforms. The
# fifo, and the writer held open on it, are there because a client whose stdin
# reaches EOF detaches again immediately.
#
# Attaching also fires the plugin's asynchronous `client-attached` hook. This helper
# waits for the client, not for that hook. Tests that inspect state the hook can change
# use tama_attach_client_without_attach_hook unless they cover the hook itself.
tama_attach_client() {
  local session="$1"
  local fifo="$BATS_TEST_TMPDIR/attach-$session.fifo"
  mkfifo "$fifo"
  # Outlives the test; both this and the client are killed in teardown.
  sleep 300 >"$fifo" &
  TAMA_FIFO_HOLDER_PID=$!
  tmux_test_server_run -C attach -t "$session" <"$fifo" >/dev/null 2>&1 &
  TAMA_CLIENT_PID=$!

  # The client is up when tmux says the session has one. Polled rather than slept
  # on: a fixed sleep is either slower than it needs to be or flaky on a loaded CI
  # runner, and this is the fact the test actually depends on.
  local waited=0
  while [ "$(tmux_test_server_run display-message -p -t "$session" '#{session_attached}')" = '0' ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'no client attached to %s after 10s\n' "$session" >&2
      return 1
    fi
    sleep 0.05
  done
}

tama_attach_client_without_attach_hook() {
  tmux_test_server_run set-hook -gu client-attached
  tama_attach_client "$1"
}

tama_detach_client() {
  [ -z "${TAMA_CLIENT_PID:-}" ] || kill "$TAMA_CLIENT_PID" 2>/dev/null || true
  [ -z "${TAMA_FIFO_HOLDER_PID:-}" ] || kill "$TAMA_FIFO_HOLDER_PID" 2>/dev/null || true
  TAMA_CLIENT_PID=''
  TAMA_FIFO_HOLDER_PID=''
}

# The window's attention flag, asked the way the status line asks: through the
# exported format rather than by reading the option, so a test cannot pass while the
# thing the user would see stays empty.
assert_flagged() {
  local rendered
  rendered="$(tmux_test_server_run display-message -p -t "$1" '#{E:@tama_flag}')"
  if [ -z "$rendered" ]; then
    printf 'expected window %s to be flagged, but @tama_flag rendered empty\n' "$1" >&2
    return 1
  fi
}

assert_not_flagged() {
  local rendered
  rendered="$(tmux_test_server_run display-message -p -t "$1" '#{E:@tama_flag}')"
  if [ -n "$rendered" ]; then
    printf 'expected window %s not to be flagged, got: %s\n' "$1" "$rendered" >&2
    return 1
  fi
}

# Waits for a flag a tmux hook was supposed to clear. The entrypoint wires
# `run-shell -b`, which is deliberately asynchronous, so the assertion has to be
# "eventually" or it is timing noise. Polled on the fact the test is about.
wait_until_not_flagged() {
  local waited=0
  while [ -n "$(tmux_test_server_run display-message -p -t "$1" '#{E:@tama_flag}')" ]; do
    waited=$((waited + 1))
    if [ "$waited" -gt 200 ]; then
      printf 'window %s was still flagged after 10s\n' "$1" >&2
      return 1
    fi
    sleep 0.05
  done
}

# The flag as tmux stores it, for the claims that are about the option itself:
# clearing must *unset* it, not write an empty string.
assert_window_option_unset() {
  local value
  if value="$(tmux_test_server_run show -w -t "$1" -v "@tama_$2")"; then
    printf 'expected @tama_%s to be unset on %s, got: %s\n' "$2" "$1" "$value" >&2
    return 1
  fi
}

# The window id of a window named by session:index — the identity everything in the
# plugin uses, resolved once so a test never passes an index to the CLI.
tama_window_id() {
  tmux_test_server_run display-message -p -t "$1" '#{window_id}'
}

# The active pane of a window named by session:index.
tama_pane_of() {
  tmux_test_server_run display-message -p -t "$1" '#{pane_id}'
}

# A pane option as tmux stores it. Without -q so that an option which was never
# set fails instead of reading as empty — the difference between a cleared pane
# and an agent pane.
assert_pane_option() {
  local value
  value="$(tmux_test_server_run show -p -t "$1" -v "@tama_pane_$2")" || {
    printf 'expected @tama_pane_%s to be set on %s\n' "$2" "$1" >&2
    return 1
  }
  assert_equal "$value" "$3"
}

assert_pane_option_unset() {
  local value
  if value="$(tmux_test_server_run show -p -t "$1" -v "@tama_pane_$2")"; then
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
  _tmux_test_server_require_isolated_socket || return 1
  export TAMA_FAKE_TMUX_VERSION="$1"
  export TAMA_FAKE_TMUX_LOG="$BATS_TEST_TMPDIR/tmux-calls.log"
  : >"$TAMA_FAKE_TMUX_LOG"
  export TAMA_TMUX="$PLUGIN_ROOT/tests/fixtures/fake-tmux"
  export TAMA_TMUX_ARGS="-L $TMUX_TEST_SOCKET"
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
  tmux_test_server_run show -g
  tmux_test_server_run show -s
  tmux_test_server_run show-hooks -g
  tmux_test_server_run list-keys
}

# Both discovery options point at the given clone.
assert_plugin_wired() {
  local root="$1"
  assert_equal "$(tmux_test_server_run show -gqv @tama_bin)" "$root/bin/tama" || return 1
  assert_equal "$(tmux_test_server_run show -gqv @tama_bin_dir)" "$root/bin"
}

assert_plugin_not_wired() {
  assert_equal "$(tmux_test_server_run show -gqv @tama_bin)" '' || return 1
  assert_equal "$(tmux_test_server_run show -gqv @tama_bin_dir)" ''
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

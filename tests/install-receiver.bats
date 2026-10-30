#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# install-receiver, driven like a user on the showing computer would drive it:
# outside tmux, with launchctl replaced by a fixture that records the service
# manager calls instead of starting anything.
#
# No tmux server here on purpose: installing the receiver configures another
# computer's login items, not a tmux server, so this must work with no $TMUX —
# which is also what the dispatcher exemption is for.
setup() {
  command -v python3 >/dev/null 2>&1 || skip 'install-receiver needs python3'
  unset TMUX

  export TAMA_LAUNCHCTL_DIR="$BATS_TEST_TMPDIR/launchctl"
  mkdir -p "$TAMA_LAUNCHCTL_DIR"
  : >"$TAMA_LAUNCHCTL_DIR/calls"
  unset TAMA_LAUNCHCTL_FAIL

  export TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME"
}

# launchctl on PATH, recording instead of managing services. Prepended, so it
# shadows the real one on a Mac exactly where the installer looks.
shim_launchctl() {
  local bin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$bin"
  cp "$PLUGIN_ROOT/tests/fixtures/fake-launchctl" "$bin/launchctl"
  chmod +x "$bin/launchctl"
  PATH="$bin:$PATH"
  export PATH
}

installed_plist() {
  printf '%s' "$TEST_HOME/Library/LaunchAgents/com.tamagotchi.remote-receiver.plist"
}

assert_launchctl_called() { # <subcommand>
  if ! grep -q -- "^$1 " "$TAMA_LAUNCHCTL_DIR/calls"; then
    printf 'expected launchctl to be asked to %s; calls were:\n%s\n' \
      "$1" "$(cat "$TAMA_LAUNCHCTL_DIR/calls")" >&2
    return 1
  fi
}

@test "one command installs the receiver and prints the tmux side" {
  shim_launchctl

  run env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver --port 9876
  assert_success

  local plist
  plist="$(installed_plist)"
  [ -f "$plist" ]

  # Rendered, not templated: no placeholder survives.
  refute_output_contains '%%'
  [ "$(grep -c '%%' "$plist")" -eq 0 ]
  assert_contains "$(cat "$plist")" "$PLUGIN_ROOT/backends/remote/receiver.py" 'the plist'
  assert_contains "$(cat "$plist")" '<string>9876</string>' 'the plist'

  # The token it generated travels to both sides identically.
  local token
  token="$(printf '%s' "$output" | grep -oE '[0-9a-f]{64}' | head -1)"
  [ -n "$token" ]
  assert_contains "$(cat "$plist")" "$token" 'the plist'
  assert_output_contains "@tama_remote_token '$token'"
  assert_output_contains '@tama_backend remote'
  assert_output_contains '@tama_remote_url'

  # Unload-then-load-then-verify, in that order.
  assert_launchctl_called unload
  assert_launchctl_called load
  assert_launchctl_called list
}

@test "explicit token, ssh target and python are honored literally" {
  shim_launchctl
  local hostile_token='a&b|c"d\e$f'
  local python
  python="$(command -v python3)"

  run env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver \
    --token "$hostile_token" --ssh-target 'user@vm' --python "$python" --port 8765
  assert_success

  # Exact-string rendering: a token holding shell and sed metacharacters must
  # arrive byte-identical, never read as a pattern.
  assert_contains "$(installed_plist_content)" "$hostile_token" 'the plist'
  assert_contains "$(installed_plist_content)" '<string>--ssh-target</string>' 'the plist'
  assert_contains "$(installed_plist_content)" 'user@vm' 'the plist'
  assert_contains "$(installed_plist_content)" "$python" 'the plist'
}

installed_plist_content() {
  cat "$(installed_plist)"
}

@test "reinstalling over an existing copy succeeds" {
  shim_launchctl

  run env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver --token tok
  assert_success
  run env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver --token tok2
  assert_success
  assert_contains "$(installed_plist_content)" 'tok2' 'the plist'
}

@test "without launchctl it fails instead of pretending" {
  # Where this runs without a service manager — a Linux VM, a container — there
  # is nothing to install into. Skipped where launchctl really exists.
  command -v launchctl >/dev/null 2>&1 && skip 'launchctl exists here'

  run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver
  assert_status 1
  assert_stderr_contains 'no launchctl'
  [ ! -e "$(installed_plist)" ]
}

@test "a python it cannot run fails" {
  shim_launchctl

  run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver \
    --python "$BATS_TEST_TMPDIR/no-such-python"
  assert_status 1
  assert_stderr_contains 'no Python'
}

@test "ports that are not ports are a usage error" {
  shim_launchctl
  local port
  for port in abc 0 99999 -1 ''; do
    run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver \
      --port "$port"
    assert_usage_error 'port' || return 1
  done
}

@test "a wrong invocation is a usage error" {
  shim_launchctl

  run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver --nope
  assert_usage_error 'unknown option'

  run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver extra
  assert_usage_error 'positional'

  run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver --port
  assert_usage_error '--port needs'
}

@test "a launchctl that fails fails the install" {
  shim_launchctl
  export TAMA_LAUNCHCTL_FAIL=load

  run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver --token tok
  assert_status 1
  assert_stderr_contains 'would not load'
}

@test "an unverifiable install fails the install" {
  shim_launchctl
  export TAMA_LAUNCHCTL_FAIL=list

  run --separate-stderr env HOME="$TEST_HOME" "$PLUGIN_ROOT/bin/tama" install-receiver --token tok
  assert_status 1
  assert_stderr_contains 'not listed'
}

@test "without HOME there is nowhere to install into" {
  shim_launchctl

  run --separate-stderr env -u HOME "$PLUGIN_ROOT/bin/tama" install-receiver --token tok
  assert_status 1
  assert_stderr_contains 'HOME is not set'
}

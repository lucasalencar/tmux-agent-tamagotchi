#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  cat >"$bin/tmux" <<'FAKE_TMUX'
#!/bin/sh
case " $* " in
  *' new-session '*)
    if [ -n "${TAMA_FAKE_LONG_LIVED_SERVER:-}" ]; then
      sleep 2 &
      printf '%s' "$!" >"$TAMA_FAKE_SERVER_PID_FILE"
      printf '%s' "$!"
    else
      printf '%s' "${TAMA_FAKE_SERVER_PID:-}"
    fi
    printf 'server stderr stayed attached' >&2
    [ -z "${TAMA_FAKE_START_FAILURE:-}" ] || exit 1
    ;;
  *' kill-server '*)
    [ -z "${TAMA_FAKE_KILL_FAILURE:-}" ] || exit 1
    ;;
  *' display-message '*'#{pid}'*)
    [ -z "${TAMA_FAKE_PID_LOOKUP_FAILURE:-}" ] || exit 1
    printf '%s' "${TAMA_FAKE_SERVER_PID:-}"
    ;;
esac
FAKE_TMUX
  chmod +x "$bin/tmux"
  PATH="$bin:$PATH"
  export PATH
}

arrange_fake_server_socket_file() {
  export TMUX_TEST_SOCKET="$1"
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  mkdir -p "$(_tmux_test_server_socket_dir)"
  touch "$(_tmux_test_server_socket_dir)/$TMUX_TEST_SOCKET"
}

assert_surviving_server_is_reported() {
  [ "$status" -ne 0 ]
  [ -e "$(_tmux_test_server_socket_dir)/$TMUX_TEST_SOCKET" ]
  assert_stderr_contains 'test tmux server survived kill-server'
}

@test "a test server cannot retain the suite output streams" {
  export TAMA_FAKE_LONG_LIVED_SERVER=1
  export TAMA_FAKE_SERVER_PID_FILE="$BATS_TEST_TMPDIR/server.pid"
  run --separate-stderr tama_start_server

  assert_success
  local server_pid
  IFS= read -r server_pid <"$TAMA_FAKE_SERVER_PID_FILE" || true
  [ -n "$server_pid" ]
  kill -0 "$server_pid"
  kill "$server_pid"
}

@test "a failed server start reports tmux's diagnostic" {
  export TAMA_FAKE_START_FAILURE=1
  run --separate-stderr tama_start_server

  [ "$status" -ne 0 ]
  assert_stderr_contains 'server stderr stayed attached'
}

@test "a failed server start retains any pid tmux already reported" {
  export TAMA_FAKE_SERVER_PID=$$
  export TAMA_FAKE_START_FAILURE=1

  tama_start_server 2>/dev/null && return 1

  assert_equal "$TMUX_TEST_SERVER_PID" "$$"
}

@test "a successful start without a server pid is rejected" {
  run --separate-stderr tama_start_server

  [ "$status" -ne 0 ]
}

@test "server startup stops when environment preparation fails" {
  local start_status=0
  prepare_environment_failure() {
    return 42
  }

  tmux_test_server_start /dev/null test prepare_environment_failure || start_status=$?

  [ "$start_status" -eq 42 ]
  [ -z "${TMUX_TEST_SOCKET:-}" ]
}

@test "reserving a socket clears a stale pid with no socket ownership" {
  export TMUX_TEST_SERVER_PID=$$

  _tmux_test_server_reserve_socket

  [ -z "${TMUX_TEST_SERVER_PID:-}" ]
}

@test "reserving another socket refuses to abandon active ownership" {
  export TMUX_TEST_SOCKET=tamatest-owned
  export TMUX_TEST_SERVER_PID=$$

  _tmux_test_server_reserve_socket 2>/dev/null && return 1

  assert_equal "$TMUX_TEST_SOCKET" tamatest-owned
  assert_equal "$TMUX_TEST_SERVER_PID" "$$"
}

@test "server startup propagates refusal to abandon active ownership" {
  export TMUX_TEST_SOCKET=tamatest-owned
  export TMUX_TEST_SERVER_PID=$$

  tama_start_server 2>/dev/null && return 1

  assert_equal "$TMUX_TEST_SOCKET" tamatest-owned
  assert_equal "$TMUX_TEST_SERVER_PID" "$$"
}

@test "server startup remembers the pid needed for reliable teardown" {
  export TAMA_FAKE_SERVER_PID=$$

  tama_start_server

  assert_equal "$TMUX_TEST_SERVER_PID" "$$"
}

@test "a failed kill leaves a live server's socket in place and reports it" {
  arrange_fake_server_socket_file tamatest-survivor
  export TAMA_FAKE_KILL_FAILURE=1
  export TAMA_FAKE_SERVER_PID=$$
  export TMUX_TEST_SERVER_EXIT_WAIT_ATTEMPTS=1

  run --separate-stderr tmux_test_server_stop

  assert_surviving_server_is_reported
}

@test "a successful kill that leaves the server alive is detected" {
  arrange_fake_server_socket_file tamatest-survivor
  export TAMA_FAKE_SERVER_PID=$$
  export TMUX_TEST_SERVER_EXIT_WAIT_ATTEMPTS=1

  run --separate-stderr tmux_test_server_stop

  assert_surviving_server_is_reported
}

@test "a known server process must exit before its socket is removed" {
  arrange_fake_server_socket_file tamatest-exiting
  export TMUX_TEST_SERVER_PID=$$
  export TMUX_TEST_SERVER_EXIT_WAIT_ATTEMPTS=1

  run --separate-stderr tmux_test_server_stop

  assert_surviving_server_is_reported
}

@test "teardown discovers the pid when startup did not record it" {
  arrange_fake_server_socket_file tamatest-fallback
  export TAMA_FAKE_SERVER_PID=$$
  export TMUX_TEST_SERVER_EXIT_WAIT_ATTEMPTS=1

  run --separate-stderr tmux_test_server_stop

  assert_surviving_server_is_reported
}

@test "a socket is removed after its server process finishes exiting" {
  arrange_fake_server_socket_file tamatest-exiting
  sleep 0.05 &
  export TAMA_FAKE_SERVER_PID=$!

  run --separate-stderr tmux_test_server_stop

  assert_success
  [ ! -e "$(_tmux_test_server_socket_dir)/$TMUX_TEST_SOCKET" ]
}

@test "an unidentified server preserves its socket and reports uncertainty" {
  arrange_fake_server_socket_file tamatest-unknown
  export TAMA_FAKE_PID_LOOKUP_FAILURE=1

  run --separate-stderr tmux_test_server_stop

  [ "$status" -ne 0 ]
  [ -e "$(_tmux_test_server_socket_dir)/$TMUX_TEST_SOCKET" ]
  assert_stderr_contains 'could not identify test tmux server'
}

@test "successful teardown clears socket and pid ownership" {
  arrange_fake_server_socket_file tamatest-dead
  sleep 0 &
  export TMUX_TEST_SERVER_PID=$!
  wait "$TMUX_TEST_SERVER_PID"

  tmux_test_server_stop

  [ -z "${TMUX_TEST_SOCKET:-}" ]
  [ -z "${TMUX_TEST_SERVER_PID:-}" ]
}

@test "a socket removal failure preserves ownership and fails teardown" {
  local fake_rm_dir="$BATS_TEST_TMPDIR/fake-rm" previous_path="$PATH" kill_status=0
  arrange_fake_server_socket_file tamatest-unremoved
  sleep 0 &
  export TMUX_TEST_SERVER_PID=$!
  wait "$TMUX_TEST_SERVER_PID"
  mkdir -p "$fake_rm_dir"
  cat >"$fake_rm_dir/rm" <<'FAKE_RM'
#!/bin/sh
exit 1
FAKE_RM
  chmod +x "$fake_rm_dir/rm"
  PATH="$fake_rm_dir:$PATH"

  tmux_test_server_stop || kill_status=$?
  PATH="$previous_path"

  [ "$kill_status" -ne 0 ]
  assert_equal "$TMUX_TEST_SOCKET" tamatest-unremoved
  [ -n "$TMUX_TEST_SERVER_PID" ]
}

@test "a retried teardown reuses ownership recovered before socket removal failed" {
  local fake_rm_dir="$BATS_TEST_TMPDIR/fake-rm" previous_path="$PATH"
  arrange_fake_server_socket_file tamatest-retry
  sleep 0 &
  export TAMA_FAKE_SERVER_PID=$!
  wait "$TAMA_FAKE_SERVER_PID"
  unset TMUX_TEST_SERVER_PID
  mkdir -p "$fake_rm_dir"
  cat >"$fake_rm_dir/rm" <<'FAKE_RM'
#!/bin/sh
exit 1
FAKE_RM
  chmod +x "$fake_rm_dir/rm"
  PATH="$fake_rm_dir:$PATH"

  tmux_test_server_stop 2>/dev/null && return 1
  PATH="$previous_path"
  export TAMA_FAKE_PID_LOOKUP_FAILURE=1

  tmux_test_server_stop

  [ -z "${TMUX_TEST_SOCKET:-}" ]
  [ -z "${TMUX_TEST_SERVER_PID:-}" ]
}

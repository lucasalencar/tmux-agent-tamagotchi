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
  *' has-session '*)
    [ -z "${TAMA_FAKE_SERVER_UNREACHABLE:-}" ] || exit 1
    ;;
  *' display-message '*'#{pid}'*)
    printf '%s' "${TAMA_FAKE_SERVER_PID:-}"
    ;;
esac
FAKE_TMUX
  chmod +x "$bin/tmux"
  PATH="$bin:$PATH"
  export PATH
}

arrange_fake_server_socket_file() {
  export TAMA_SOCKET="$1"
  export TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  mkdir -p "$(tama_socket_dir)"
  touch "$(tama_socket_dir)/$TAMA_SOCKET"
}

assert_surviving_server_is_reported() {
  [ "$status" -ne 0 ]
  [ -e "$(tama_socket_dir)/$TAMA_SOCKET" ]
  assert_stderr_contains 'test tmux server survived kill-server'
}

@test "a test server cannot retain the suite output streams" {
  export TAMA_FAKE_LONG_LIVED_SERVER=1
  tama_start_server

  kill -0 "$TAMA_SERVER_PID"
  kill "$TAMA_SERVER_PID"
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

  assert_equal "$TAMA_SERVER_PID" "$$"
}

@test "a successful start without a server pid is rejected" {
  run --separate-stderr tama_start_server

  [ "$status" -ne 0 ]
}

@test "reserving a new socket invalidates the previous server pid" {
  export TAMA_SERVER_PID=$$

  tama_reserve_socket another

  [ -z "${TAMA_SERVER_PID:-}" ]
}

@test "server startup remembers the pid needed for reliable teardown" {
  export TAMA_FAKE_SERVER_PID=$$

  tama_start_server

  assert_equal "$TAMA_SERVER_PID" "$$"
}

@test "a failed kill leaves a live server's socket in place and reports it" {
  arrange_fake_server_socket_file tamatest-survivor
  export TAMA_FAKE_KILL_FAILURE=1

  run --separate-stderr tama_kill_server

  assert_surviving_server_is_reported
}

@test "a successful kill that leaves the server alive is detected" {
  arrange_fake_server_socket_file tamatest-survivor

  run --separate-stderr tama_kill_server

  assert_surviving_server_is_reported
}

@test "an unreachable server process must exit before its socket is removed" {
  arrange_fake_server_socket_file tamatest-exiting
  export TAMA_SERVER_PID=$$
  export TAMA_FAKE_SERVER_UNREACHABLE=1
  export TAMA_SERVER_EXIT_WAIT_ATTEMPTS=1

  run --separate-stderr tama_kill_server

  assert_surviving_server_is_reported
}

@test "teardown discovers the pid when startup did not record it" {
  arrange_fake_server_socket_file tamatest-fallback
  export TAMA_FAKE_SERVER_PID=$$
  export TAMA_FAKE_SERVER_UNREACHABLE=1
  export TAMA_SERVER_EXIT_WAIT_ATTEMPTS=1

  run --separate-stderr tama_kill_server

  assert_surviving_server_is_reported
}

@test "a socket is removed after its server process finishes exiting" {
  arrange_fake_server_socket_file tamatest-exiting
  export TAMA_FAKE_SERVER_UNREACHABLE=1
  sleep 0.05 &
  export TAMA_FAKE_SERVER_PID=$!

  run --separate-stderr tama_kill_server

  assert_success
  [ ! -e "$(tama_socket_dir)/$TAMA_SOCKET" ]
}

@test "a dead server's stale socket is removed" {
  arrange_fake_server_socket_file tamatest-dead
  export TAMA_FAKE_SERVER_UNREACHABLE=1

  run --separate-stderr tama_kill_server

  assert_success
  [ ! -e "$(tama_socket_dir)/$TAMA_SOCKET" ]
}

@test "successful teardown clears socket and pid ownership" {
  arrange_fake_server_socket_file tamatest-dead
  export TAMA_FAKE_SERVER_UNREACHABLE=1

  tama_kill_server

  [ -z "${TAMA_SOCKET:-}" ]
  [ -z "${TAMA_SERVER_PID:-}" ]
}

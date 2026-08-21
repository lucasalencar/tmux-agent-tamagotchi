# shellcheck shell=bash

# Owns one isolated tmux server for a test. Callers start it, address it through
# tmux_test_server_run, and stop it; socket and process ownership stay here.

_tmux_test_server_socket_dir() {
  printf '%s/tmux-%s' "${TMUX_TMPDIR:-/tmp}" "$(id -u)"
}

_tmux_test_server_require_isolated_socket() {
  if [ "${TMUX_TEST_SOCKET:-}" = default ]; then
    printf 'refusing to use the default tmux socket in tests\n' >&2
    return 1
  fi
}

_tmux_test_server_reserve_socket() {
  if [ -n "${TMUX_TEST_SOCKET:-}" ]; then
    printf 'cannot reserve another tmux socket before tearing down %s\n' \
      "$TMUX_TEST_SOCKET" >&2
    return 1
  fi
  TMUX_TEST_SOCKET="tmuxtest-$$-${BATS_TEST_NUMBER:-0}-${RANDOM}"
  export TMUX_TEST_SOCKET
  unset TMUX_TEST_SERVER_PID
}

_tmux_test_server_start_session() { # <config> <session>
  local config="$1" session="$2"
  local stdout_file stderr_file server_pid='' start_status=0
  stdout_file="${BATS_TEST_TMPDIR:-/tmp}/$TMUX_TEST_SOCKET-startup.out"
  stderr_file="${BATS_TEST_TMPDIR:-/tmp}/$TMUX_TEST_SOCKET-startup.err"
  tmux_test_server_run -f "$config" new-session -d -P -F '#{pid}' -s "$session" \
    </dev/null >"$stdout_file" 2>"$stderr_file" || start_status=$?
  IFS= read -r server_pid <"$stdout_file" || true
  if [ -n "$server_pid" ]; then
    TMUX_TEST_SERVER_PID="$server_pid"
    export TMUX_TEST_SERVER_PID
  fi
  if [ "$start_status" -ne 0 ]; then
    cat "$stdout_file" "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return "$start_status"
  fi
  rm -f "$stdout_file" "$stderr_file"
  [ -n "$server_pid" ] || return 1
}

tmux_test_server_start() { # [config] [session] [prepare-environment-callback]
  local config="${1:-/dev/null}" session="${2:-test}" prepare="${3:-}" prepare_status=0
  _tmux_test_server_reserve_socket || return 1
  if [ -n "$prepare" ]; then
    "$prepare" || prepare_status=$?
    if [ "$prepare_status" -ne 0 ]; then
      unset TMUX_TEST_SOCKET TMUX_TEST_SERVER_PID
      return "$prepare_status"
    fi
  fi
  _tmux_test_server_start_session "$config" "$session" || {
    printf 'could not boot a tmux server on %s\n' "$TMUX_TEST_SOCKET" >&2
    return 1
  }
}

tmux_test_server_run() {
  _tmux_test_server_require_isolated_socket || return 1
  [ -n "${TMUX_TEST_SOCKET:-}" ] || {
    printf 'no test tmux server is owned\n' >&2
    return 1
  }
  tmux -L "$TMUX_TEST_SOCKET" "$@"
}

_tmux_test_server_wait_for_exit() { # <pid>
  local probed=0 waited=0
  local attempts="${TMUX_TEST_SERVER_EXIT_WAIT_ATTEMPTS:-500}"
  while kill -0 "$1" 2>/dev/null && [ "$probed" -lt 1000 ]; do
    probed=$((probed + 1))
  done
  while kill -0 "$1" 2>/dev/null && [ "$waited" -lt "$attempts" ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

_tmux_test_server_report_survivor() {
  printf 'test tmux server survived kill-server on %s\n' "$TMUX_TEST_SOCKET" >&2
  return 1
}

_tmux_test_server_report_unknown() {
  printf 'could not identify test tmux server on %s; socket preserved\n' \
    "$TMUX_TEST_SOCKET" >&2
  return 1
}

tmux_test_server_stop() {
  if [ -n "${TMUX_TEST_SOCKET:-}" ]; then
    _tmux_test_server_require_isolated_socket || return 1
    local server_pid="${TMUX_TEST_SERVER_PID:-}"
    if [ -z "$server_pid" ]; then
      server_pid="$(tmux_test_server_run display-message -p '#{pid}' 2>/dev/null)" || {
        _tmux_test_server_report_unknown
        return 1
      }
      if [ -z "$server_pid" ]; then
        _tmux_test_server_report_unknown
        return 1
      fi
      TMUX_TEST_SERVER_PID="$server_pid"
      export TMUX_TEST_SERVER_PID
    fi
    tmux_test_server_run kill-server 2>/dev/null || true
    if ! _tmux_test_server_wait_for_exit "$server_pid"; then
      _tmux_test_server_report_survivor
      return 1
    fi
    rm -f "$(_tmux_test_server_socket_dir)/$TMUX_TEST_SOCKET" || return 1
    unset TMUX_TEST_SOCKET TMUX_TEST_SERVER_PID
  fi
}

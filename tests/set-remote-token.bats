#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# set-remote-token stores the remote backend's secret where the running server
# can use it: the server environment (for later config reloads) and the option
# (for immediate effect).
setup() {
  tama_start_server
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  # The command persists outside tmux too: pin HOME so no test touches the
  # developer's own env file.
  export TEST_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TEST_HOME"
  export HOME="$TEST_HOME"
  unset TAMA_REMOTE_TOKEN
}

teardown() {
  tama_detach_client
  tmux_test_server_stop
}

token_file() {
  # Mirrors tama_remote_token_file in libexec/set-remote-token (HOME here is
  # already TEST_HOME): XDG first, then the home tree.
  printf '%s' "${XDG_CONFIG_HOME:-$TEST_HOME/.config}/tama/remote.env"
}

server_env_token() {
  tmux_test_server_run show-environment -g TAMA_REMOTE_TOKEN
}

server_option_token() {
  tmux_test_server_run show -gqv @tama_remote_token
}

@test "stores the token in the server environment and the option" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" set-remote-token 's3cr3t-token'
  assert_success
  assert_output_contains 'stored for this tmux server'
  # Never printed back: argv already exposes it to ps while this runs.
  refute_output_contains 's3cr3t'
  [ -z "$stderr" ]
  assert_equal "$(server_env_token)" 'TAMA_REMOTE_TOKEN=s3cr3t-token'
  assert_equal "$(server_option_token)" 's3cr3t-token'
  # And persisted for new servers, outside any versioned tree.
  assert_equal "$(cat "$(token_file)")" "export TAMA_REMOTE_TOKEN='s3cr3t-token'"
}

@test "without an argument the token comes from the environment" {
  # argv never carries the secret: nothing for ps or shell history to see.
  run --separate-stderr env TAMA_REMOTE_TOKEN='env-only-token' \
    "$PLUGIN_ROOT/bin/tama" set-remote-token
  assert_success
  [ -z "$stderr" ]
  assert_equal "$(server_env_token)" 'TAMA_REMOTE_TOKEN=env-only-token'
  assert_equal "$(server_option_token)" 'env-only-token'
  assert_equal "$(cat "$(token_file)")" "export TAMA_REMOTE_TOKEN='env-only-token'"
}

@test "a persisted token with quotes sources back verbatim" {
  local token="a'b\"c"

  run "$PLUGIN_ROOT/bin/tama" set-remote-token "$token"
  assert_success
  # shellcheck disable=SC1090  # the file under test, by path
  . "$(token_file)"
  assert_equal "$TAMA_REMOTE_TOKEN" "$token"
}

@test "a token with spaces and shell metacharacters is stored verbatim" {
  # No $ or backslash here: old tmux escapes those on display (the stored bytes
  # stay literal, but read-back differs by version), so they cannot be asserted
  # byte-exact portably. Generated hex tokens sidestep this entirely.
  local token='a b"d%e&f;g#h'

  run "$PLUGIN_ROOT/bin/tama" set-remote-token "$token"
  assert_success
  # The option is the surface the backend reads: byte-exact on every version.
  assert_equal "$(server_option_token)" "$token"
  # show-environment escapes $ for eval-safety on some tmux versions, so only
  # the prefix is asserted textually; the reload test below proves the bytes.
  assert_contains "$(server_env_token)" 'TAMA_REMOTE_TOKEN='
}

@test "the stored environment feeds config reloads with bytes intact" {
  local token='a b"d%e&f;g#h'

  run "$PLUGIN_ROOT/bin/tama" set-remote-token "$token"
  assert_success
  tmux_test_server_run set -gu @tama_remote_token
  printf 'set -g @tama_remote_token "$TAMA_REMOTE_TOKEN"\n' >"$BATS_TEST_TMPDIR/reload.conf"
  tmux_test_server_run source-file "$BATS_TEST_TMPDIR/reload.conf"
  assert_equal "$(server_option_token)" "$token"
}

@test "a token beginning with a dash is a token, after --" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" set-remote-token -- '--abc'
  assert_success
  [ -z "$stderr" ]
  assert_equal "$(server_option_token)" '--abc'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" set-remote-token '--abc'
  assert_usage_error 'unknown option'
}

@test "a missing or empty token is a usage error" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" set-remote-token
  assert_usage_error 'needs a token'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" set-remote-token ''
  assert_usage_error 'needs a token'

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" set-remote-token one two
  assert_usage_error 'one token'
}

@test "a wrong invocation is a usage error" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" set-remote-token --nope x
  assert_usage_error 'unknown option'
}

@test "outside tmux it is a quiet no-op like every tmux-acting command" {
  run --separate-stderr env -u TMUX "$PLUGIN_ROOT/bin/tama" set-remote-token 's3cr3t'
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

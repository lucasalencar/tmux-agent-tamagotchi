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
}

teardown() {
  tama_detach_client
  tmux_test_server_stop
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
}

@test "a token with spaces and shell metacharacters is stored verbatim" {
  local token='a b$c"d%e&f;g'

  run "$PLUGIN_ROOT/bin/tama" set-remote-token "$token"
  assert_success
  assert_equal "$(server_env_token)" "TAMA_REMOTE_TOKEN=$token"
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

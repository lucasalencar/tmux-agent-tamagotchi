#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  PANE="$(tmux_test_server_run list-panes -t t -F '#{pane_id}' | head -1)"
}

teardown() {
  tmux_test_server_stop
}

@test "logging disabled does not invoke jq or touch a destination" {
  local shim="$BATS_TEST_TMPDIR/bin" marker="$BATS_TEST_TMPDIR/jq-called"
  mkdir -p "$shim"
  printf '#!/bin/sh\n: >"$TAMA_JQ_MARKER"\nexit 99\n' >"$shim/jq"
  chmod +x "$shim/jq"

  PATH="$shim:$PATH" TAMA_JQ_MARKER="$marker" TAMA_LOG_FILE='' \
    run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  assert_success
  [ ! -e "$marker" ]
  assert_pane_option "$PANE" state_main running
}

@test "an enabled Log records command start and completion as valid JSONL" {
  local log="$BATS_TEST_TMPDIR/tama.jsonl"

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  assert_success
  assert_pane_option "$PANE" state_main running
  jq -e -s '
    ([.[] | select(.event == "command.started" or .event == "command.completed")]) as $commands |
    ($commands | length) == 2 and
    $commands[0].event == "command.started" and
    $commands[1].event == "command.completed" and
    $commands[0].command == "state" and
    $commands[1].command == "state" and
    $commands[1].outcome == "applied" and
    ($commands[1].duration_ms | type) == "number" and
    $commands[0].operation_id == $commands[1].operation_id and
    $commands[0].correlation_id == $commands[1].correlation_id and
    all(.[];
      .version == "0.3.0" and
      (.timestamp | type) == "string" and
      (.unix_time | type) == "number" and
      (.pid | type) == "number")
  ' "$log"
}

@test "a newly created Log is owner-only and existing permissions are preserved" {
  local created="$BATS_TEST_TMPDIR/created.jsonl" existing="$BATS_TEST_TMPDIR/existing.jsonl"
  : >"$existing"
  chmod 0644 "$existing"

  TAMA_LOG_FILE="$created" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success
  assert_equal "$(stat -f '%Lp' "$created")" 600

  TAMA_LOG_FILE="$existing" run "$PLUGIN_ROOT/bin/tama" state idle --pane "$PANE"
  assert_success
  assert_equal "$(stat -f '%Lp' "$existing")" 644
}

@test "a symlink to a regular file is an append destination" {
  local target="$BATS_TEST_TMPDIR/target.jsonl" link="$BATS_TEST_TMPDIR/log.jsonl"
  : >"$target"
  ln -s "$target" "$link"

  TAMA_LOG_FILE="$link" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  assert_success
  jq -e -s 'length >= 2 and all(.[]; type == "object")' "$target"
}

@test "invalid destinations stay silent and never change command behavior" {
  local relative='relative.jsonl' missing="$BATS_TEST_TMPDIR/missing/log.jsonl"
  local directory="$BATS_TEST_TMPDIR/directory"
  mkdir "$directory"

  for destination in "$relative" "$missing" "$directory" /dev/null; do
    TAMA_LOG_FILE="$destination" run --separate-stderr \
      "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
    assert_success || return 1
    assert_equal "$output" '' || return 1
    assert_equal "$stderr" '' || return 1
  done
}

@test "the Log never records command arguments or inherited secrets" {
  local log="$BATS_TEST_TMPDIR/private.jsonl"
  TAMA_PRIVATE_VALUE='customer secret' TAMA_LOG_FILE="$log" \
    run "$PLUGIN_ROOT/bin/tama" notify -- Agent 'private message'

  assert_success
  run grep -E 'private message|customer secret|TAMA_PRIVATE_VALUE' "$log"
  [ "$status" -ne 0 ]
}

@test "doctor validates the configured Log without appending to it" {
  local log="$BATS_TEST_TMPDIR/doctor.jsonl"
  printf '{"existing":true}\n' >"$log"
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" doctor

  assert_success
  assert_output_contains "$log"
  assert_equal "$(wc -l <"$log" | tr -d ' ')" 1
}

@test "a Codex event is correlated through integration classification and its command" {
  local log="$BATS_TEST_TMPDIR/codex.jsonl"
  local payload='{"session_id":"secret-session","hook_event_name":"SessionStart","source":"startup"}'

  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" hook codex SessionStart <<<"$payload"

  assert_success
  assert_pane_option "$PANE" state_main idle
  jq -e -s '
    any(.[]; .event == "hook.started" and .integration == "codex") and
    any(.[]; .event == "hook.completed" and .integration == "codex" and
      .outcome == "applied") and
    any(.[]; .event == "integration.received" and .integration == "codex" and
      .integration_event == "SessionStart") and
    any(.[]; .event == "integration.classified" and .outcome == "applied") and
    any(.[]; .event == "command.started" and .command == "state" and
      has("parent_operation_id")) and
    ([.[].correlation_id] | unique | length) == 1
  ' "$log"
  run grep -F 'secret-session' "$log"
  [ "$status" -ne 0 ]
}

@test "an unknown integration event is recorded as skipped without its payload" {
  local log="$BATS_TEST_TMPDIR/unknown.jsonl"

  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" hook codex FutureEvent <<<'{"message":"private"}'

  assert_success
  jq -e -s 'any(.[];
    .event == "integration.classified" and .outcome == "skipped" and
    .reason == "unknown_event")' "$log"
  run grep -F private "$log"
  [ "$status" -ne 0 ]
}

@test "state decisions record before and after, including redundant reports" {
  local log="$BATS_TEST_TMPDIR/state.jsonl"

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success
  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"
  assert_success

  jq -e -s '
    any(.[]; .event == "decision.made" and .operation == "report_state" and
      .outcome == "applied" and .state_before.main == "" and
      .state_after.main == "running") and
    any(.[]; .event == "decision.made" and .operation == "report_state" and
      .outcome == "skipped" and .reason == "pane_state_unchanged" and
      .state_before.main == "running" and .state_after.main == "running")
  ' "$log"
}

@test "notification policy and backend effects are observable end to end" {
  local log="$BATS_TEST_TMPDIR/notify.jsonl"
  tama_fake_backend_env
  tama_use_fake_backend

  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" notify -- Agent 'sensitive notification text'

  assert_success
  assert_backend_called notify
  jq -e -s '
    any(.[]; .event == "decision.made" and .operation == "attention_policy" and
      .notification_eligible == true) and
    any(.[]; .event == "effect.started" and .operation == "notify_backend") and
    any(.[]; .event == "effect.completed" and .operation == "notify_backend" and
      .outcome == "applied" and (.duration_ms | type) == "number")
  ' "$log"
  run grep -F 'sensitive notification text' "$log"
  [ "$status" -ne 0 ]
}

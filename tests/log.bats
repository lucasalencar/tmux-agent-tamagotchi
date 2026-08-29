#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  PANE="$(tmux_test_server_run list-panes -t t -F '#{pane_id}' | head -1)"
}

teardown() {
  tama_detach_client
  tmux_test_server_stop
}

@test "logging disabled does not invoke jq or touch a destination" {
  local shim="$BATS_TEST_TMPDIR/bin" marker="$BATS_TEST_TMPDIR/jq-called"
  local plugin="$BATS_TEST_TMPDIR/no-logger-plugin"
  mkdir -p "$shim"
  printf '#!/bin/sh\n: >"$TAMA_JQ_MARKER"\nexit 99\n' >"$shim/jq"
  chmod +x "$shim/jq"

  PATH="$shim:$PATH" TAMA_JQ_MARKER="$marker" TAMA_LOG_FILE='' \
    run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  assert_success
  [ ! -e "$marker" ]
  assert_pane_option "$PANE" state_main running

  tama_copy_plugin "$plugin"
  rm "$plugin/lib/log.sh"
  TAMA_LOG_FILE='' run "$plugin/bin/tama" state idle --pane "$PANE"
  assert_success
  assert_pane_option "$PANE" state_main idle
}

@test "successful status rendering stays out of an enabled Log" {
  local log="$BATS_TEST_TMPDIR/render.jsonl"

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" icons '@0'

  assert_success
  [ ! -e "$log" ]
}

@test "an abnormal status rendering is recorded without changing its quiet exit" {
  local log="$BATS_TEST_TMPDIR/render-failed.jsonl"
  tama_log_tmux_calls
  export TAMA_FAKE_TMUX_FAIL_COMMAND=display-message

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" icons '@0'

  assert_success
  assert_equal "$output" ''
  jq -e -s 'any(.[]; .event == "command.completed" and
    .command == "icons" and .outcome == "failed")' "$log"
}

@test "an enabled Log records command start and completion as valid JSONL" {
  local log="$BATS_TEST_TMPDIR/tama.jsonl"

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE" 4>&-

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

@test "an existing writable Log does not require a writable parent directory" {
  local directory="$BATS_TEST_TMPDIR/read-only-parent" log="$BATS_TEST_TMPDIR/read-only-parent/tama.jsonl"
  mkdir "$directory"
  : >"$log"
  chmod 0500 "$directory"

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  chmod 0700 "$directory"
  assert_success
  [ -s "$log" ]
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

@test "the Log rejects inherited identifiers and normalizes free-form tmux state" {
  local log="$BATS_TEST_TMPDIR/allowlist.jsonl"
  tmux_test_server_run set -p -t "$PANE" @tama_pane_state_main 'customer secret'

  TAMA_LOG_CORRELATION_ID='correlation secret' \
    TAMA_LOG_OPERATION_ID='operation secret' \
    TAMA_LOG_PARENT_OPERATION_ID='parent secret' \
    TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  assert_success
  tmux_test_server_run set -w -t "$PANE" @tama_window_priority 'priority secret'
  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" notify -- Agent message
  assert_success
  run grep -E 'customer secret|priority secret|correlation secret|operation secret|parent secret' "$log"
  [ "$status" -ne 0 ]
  jq -e -s '
    all(.[]; (.correlation_id | test("^[A-Za-z0-9_.-]{1,64}$"))) and
    any(.[]; .operation == "report_state" and .state_before.main == "unknown") and
    any(.[]; .operation == "attention_policy" and .priority == true)
  ' "$log"
}

@test "doctor validates the configured Log without appending to it" {
  local log="$BATS_TEST_TMPDIR/doctor.jsonl"
  printf '{"existing":true}\n' >"$log"
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" doctor

  assert_success
  assert_output_contains "$log"
  assert_output_contains 'logging is usable'
  assert_equal "$(wc -l <"$log" | tr -d ' ')" 1
}

@test "doctor rejects a relative Log and broken jq without writing" {
  local shim="$BATS_TEST_TMPDIR/broken-bin" log="$BATS_TEST_TMPDIR/broken.jsonl"
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  TAMA_LOG_FILE=relative.jsonl run "$PLUGIN_ROOT/bin/tama" doctor
  [ "$status" -eq 1 ]
  assert_output_contains 'must be an absolute path'

  mkdir "$shim"
  printf '#!/bin/sh\nexit 1\n' >"$shim/jq"
  chmod +x "$shim/jq"
  PATH="$shim:$PATH" TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" doctor
  [ "$status" -eq 1 ]
  assert_output_contains 'jq is not available and working'
  [ ! -e "$log" ]
}

@test "a FIFO is rejected without blocking or changing state" {
  local fifo="$BATS_TEST_TMPDIR/log.fifo"
  mkfifo "$fifo"

  TAMA_LOG_FILE="$fifo" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  assert_success
  assert_pane_option "$PANE" state_main running
}

@test "failed commands preserve status and record failure" {
  local plugin="$BATS_TEST_TMPDIR/plugin" log="$BATS_TEST_TMPDIR/failed-command.jsonl"
  tama_copy_plugin "$plugin"
  tama_add_stub_subcommand "$plugin"

  TAMA_STUB_EXIT=7 TAMA_LOG_FILE="$log" run "$plugin/bin/tama" stub

  assert_status 7
  jq -e -s 'any(.[]; .event == "command.completed" and
    .command == "stub" and .outcome == "failed")' "$log"
}

@test "a nonzero command status overrides an earlier partial outcome" {
  local log="$BATS_TEST_TMPDIR/final-status.jsonl"

  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" hook claude-code SessionStart --bad

  assert_status 2
  jq -e -s 'any(.[]; .event == "command.completed" and
    .command == "hook" and .outcome == "failed")' "$log"
}

@test "a redundant public mutation is recorded as skipped" {
  local log="$BATS_TEST_TMPDIR/redundant-command.jsonl"

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" unflag --pane "$PANE"

  assert_success
  jq -e -s 'any(.[]; .event == "command.completed" and
    .command == "unflag" and .outcome == "skipped")' "$log"
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
      .outcome == "applied" and (.duration_ms | type) == "number") and
    any(.[]; .event == "integration.received" and .integration == "codex" and
      .integration_event == "SessionStart") and
    any(.[]; .event == "integration.classified" and .outcome == "applied") and
    any(.[]; .event == "command.started" and .command == "state" and
      has("parent_operation_id")) and
    ([.[].correlation_id] | unique | length) == 1 and
    all(.[]; (.parent_operation_id // "") != .operation_id)
  ' "$log"
  run grep -F 'secret-session' "$log"
  [ "$status" -ne 0 ]
}

@test "concurrent appenders leave every physical line as complete JSON" {
  local log="$BATS_TEST_TMPDIR/concurrent.jsonl" index

  for index in 1 2 3 4 5 6; do
    TAMA_LOG_FILE="$log" "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE" &
  done
  wait

  [ "$(wc -l <"$log" | tr -d ' ')" -ge 12 ]
  while IFS= read -r line || [ -n "$line" ]; do
    jq -Re 'fromjson | type == "object"' <<<"$line" >/dev/null || return 1
  done <"$log"
}

@test "large unknown event names cannot interleave concurrent JSONL records" {
  local log="$BATS_TEST_TMPDIR/large-concurrent.jsonl" event index
  event="$(printf 'x%.0s' {1..10000})"

  for index in 1 2 3 4; do
    TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" \
      "$PLUGIN_ROOT/bin/tama" hook codex "$event" <<<'{}' &
  done
  wait || return 1

  assert_equal "$(grep -c 'integration.classified' "$log")" 4
  while IFS= read -r line || [ -n "$line" ]; do
    jq -Re 'fromjson | type == "object"' <<<"$line" >/dev/null || return 1
  done <"$log"
  run grep -F "$event" "$log"
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

@test "delegated Codex and unknown Claude Code events explain why they were skipped" {
  local log="$BATS_TEST_TMPDIR/classification.jsonl"

  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" hook codex PostToolUse \
    <<<'{"agent_id":"opaque-child","hook_event_name":"PostToolUse"}'
  assert_success
  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" hook claude-code FutureEvent <<<'{"message":"private"}'
  assert_success

  jq -e -s '
    any(.[]; .event == "integration.classified" and .integration == "codex" and
      .outcome == "skipped" and .reason == "delegated_event") and
    any(.[]; .event == "integration.classified" and .integration == "claude-code" and
      .outcome == "skipped" and .reason == "unknown_event")
  ' "$log"
  run grep -E 'opaque-child|private' "$log"
  [ "$status" -ne 0 ]
}

@test "native OpenCode effects are classified without recording opaque values" {
  local log="$BATS_TEST_TMPDIR/opencode.jsonl"

  TAMA_LOG_FILE="$log" TAMA_LOG_INTEGRATION=opencode \
    TAMA_LOG_INTEGRATION_EVENT=subagent-start run \
    "$PLUGIN_ROOT/bin/tama" state subagent-start opaque-child --pane "$PANE"

  assert_success
  jq -e -s '
    any(.[]; .event == "integration.received" and .integration == "opencode" and
      .integration_event == "subagent-start") and
    any(.[]; .event == "integration.classified" and .integration == "opencode" and
      .outcome == "applied")
  ' "$log"
  run grep -F opaque-child "$log"
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
      .outcome == "skipped" and .reason == "pane_record_unchanged" and
      .state_before.main == "running" and .state_after.main == "running") and
    ([.[] | select(.event == "command.completed" and .command == "state")][-1].outcome
      == "skipped")
  ' "$log"
}

@test "a failed state write is recorded as failed without claiming the intended state" {
  local log="$BATS_TEST_TMPDIR/state-failed.jsonl"
  tama_log_tmux_calls
  export TAMA_FAKE_TMUX_FAIL_COMMAND=set

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state running --pane "$PANE"

  assert_success
  assert_pane_option_unset "$PANE" state_main
  jq -e -s 'any(.[];
    .event == "decision.made" and .operation == "report_state" and
    .outcome == "failed" and .state_before.main == "" and
    .state_after.main == "") and
    any(.[]; .event == "command.completed" and .command == "state" and
      .outcome == "failed")' "$log"
}

@test "subagent bookkeeping records counts and attempts without opaque ids" {
  local log="$BATS_TEST_TMPDIR/subagents.jsonl"

  TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" state subagent-start opaque-child --pane "$PANE"
  assert_success
  TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" state subagent-start opaque-child --pane "$PANE"
  assert_success

  jq -e -s '
    any(.[]; .event == "decision.made" and .operation == "update_subagents" and
      .attempt == 1 and .outcome == "applied" and
      .state_before.subagent_count == 0 and .state_after.subagent_count == 1) and
    any(.[]; .event == "decision.made" and .operation == "update_subagents" and
      .attempt == 1 and .outcome == "skipped" and
      .reason == "subagent_state_unchanged")
  ' "$log"
  run grep -F opaque-child "$log"
  [ "$status" -ne 0 ]
}

@test "a subagent conflict records the retry attempt and eventual result" {
  local log="$BATS_TEST_TMPDIR/subagent-race.jsonl"
  tama_log_tmux_calls
  local wrote_a="$BATS_TEST_TMPDIR/a-wrote" wrote_b="$BATS_TEST_TMPDIR/b-wrote"

  TAMA_LOG_FILE="$log" TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-a" \
    TAMA_FAKE_TMUX_WAIT_BEFORE=2 TAMA_FAKE_TMUX_WAIT_FOR="$wrote_b" \
    TAMA_FAKE_TMUX_TOUCH_AFTER=2 TAMA_FAKE_TMUX_TOUCH="$wrote_a" \
    "$PLUGIN_ROOT/bin/tama" state subagent-start sub-a --pane "$PANE" &
  TAMA_LOG_FILE="$log" TAMA_FAKE_TMUX_COUNTER="$BATS_TEST_TMPDIR/calls-b" \
    TAMA_FAKE_TMUX_TOUCH_AFTER=2 TAMA_FAKE_TMUX_TOUCH="$wrote_b" \
    TAMA_FAKE_TMUX_WAIT_BEFORE=3 TAMA_FAKE_TMUX_WAIT_FOR="$wrote_a" \
    "$PLUGIN_ROOT/bin/tama" state subagent-start sub-b --pane "$PANE" &
  wait

  [ -e "$wrote_a" ]
  [ -e "$wrote_b" ]
  jq -e -s '
    any(.[]; .operation == "update_subagents" and .outcome == "skipped" and
      .reason == "write_conflict" and .attempt == 1) and
    any(.[]; .operation == "update_subagents" and .outcome == "applied" and
      .attempt == 2)
  ' "$log"
}

@test "reconciliation and clear record their state transitions" {
  local log="$BATS_TEST_TMPDIR/state-mutations.jsonl"

  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state idle --pane "$PANE"
  assert_success
  TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" state subagent-start child --pane "$PANE"
  assert_success
  TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" state subagent-reconcile --pane "$PANE"
  assert_success
  TAMA_LOG_FILE="$log" run "$PLUGIN_ROOT/bin/tama" state clear --pane "$PANE"
  assert_success

  jq -e -s '
    any(.[]; .event == "decision.made" and .operation == "reconcile_subagents" and
      .outcome == "applied" and .state_before.subagent_count == 1 and
      .state_after.subagent_count == 0) and
    any(.[]; .event == "decision.made" and .operation == "clear_state" and
      .outcome == "applied" and .state_before.main == "idle" and
      .state_after.main == "")
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

@test "unsupported and failing backend effects have distinct outcomes" {
  local log="$BATS_TEST_TMPDIR/backend-outcomes.jsonl" without
  without="$(tama_fake_backend_without notify)"
  tmux_test_server_run set -g @tama_backend "$without"

  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" notify -- Agent message
  assert_success

  tmux_test_server_run set -g @tama_notify_command false
  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" run \
    "$PLUGIN_ROOT/bin/tama" notify -- Agent message
  assert_success

  jq -e -s '
    any(.[]; .event == "effect.completed" and .operation == "notify_backend" and
      .outcome == "skipped" and .reason == "capability_unsupported") and
    any(.[]; .event == "effect.completed" and .operation == "notify_backend" and
      .outcome == "failed")
  ' "$log"
}

@test "a negative focused answer is a successful backend query" {
  local log="$BATS_TEST_TMPDIR/focused-outcome.jsonl"
  tama_fake_backend_env
  tama_use_fake_backend
  tama_attach_client t

  TMUX_PANE="$PANE" TAMA_LOG_FILE="$log" TAMA_FAKE_FOCUSED=1 run \
    "$PLUGIN_ROOT/bin/tama" notify -- Agent message

  assert_success
  jq -e -s '
    any(.[]; .event == "effect.completed" and .operation == "focused_backend" and
      .outcome == "applied") and
    any(.[]; .event == "command.completed" and .command == "notify" and
      .outcome != "failed")
  ' "$log"
}

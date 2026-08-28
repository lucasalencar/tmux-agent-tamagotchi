# shellcheck shell=bash
#
# Opt-in lifecycle Log. TAMA_LOG_FILE is deliberately the first and cheapest
# check: disabled commands do no lookup, formatting, or file work.

TAMA_LOG_OPERATION_ID="${TAMA_LOG_OPERATION_ID:-}"
TAMA_LOG_STARTED_AT="${TAMA_LOG_STARTED_AT:-}"

tama_log_destination_ready() {
  local path="${TAMA_LOG_FILE:-}" parent
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1

  parent="${path%/*}"
  [ -n "$parent" ] || parent=/
  [ -d "$parent" ] && [ -w "$parent" ] || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ -w "$path" ] || return 1
  else
    (umask 077 && : >>"$path") 2>/dev/null || return 1
  fi
}

tama_log_clock() {
  jq -nr 'now' 2>/dev/null
}

tama_log_write() { # <event> <command> [outcome] [started_at]
  local event="$1" command="$2" outcome="${3:-}" started_at="${4:-}"
  local correlation operation parent
  tama_log_destination_ready || return 0

  correlation="${TAMA_LOG_CORRELATION_ID:-c-$$-${RANDOM:-0}}"
  operation="${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}"
  parent="${TAMA_LOG_PARENT_OPERATION_ID:-}"

  jq -cn \
    --arg version "${TAMA_VERSION:-unknown}" \
    --arg event "$event" \
    --arg command "$command" \
    --arg correlation_id "$correlation" \
    --arg operation_id "$operation" \
    --arg parent_operation_id "$parent" \
    --arg outcome "$outcome" \
    --arg started_at "$started_at" \
    --argjson pid "$$" '
      now as $n |
      {
        version: $version,
        timestamp: (($n | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." +
          (((($n * 1000 | floor) % 1000) | tostring) as $ms |
            ("000" + $ms)[-3:]) + "Z"),
        unix_time: $n,
        event: $event,
        pid: $pid,
        correlation_id: $correlation_id,
        operation_id: $operation_id,
        command: $command
      }
      + (if $parent_operation_id == "" then {} else
          {parent_operation_id: $parent_operation_id} end)
      + (if $outcome == "" then {} else {outcome: $outcome} end)
      + (if $started_at == "" then {} else
          {duration_ms: ((($n - ($started_at | tonumber)) * 1000) | if . < 0 then 0 else . end)}
        end)
    ' >>"$TAMA_LOG_FILE" 2>/dev/null || true
}

tama_log_command_start() { # <command>
  [ -n "${TAMA_LOG_FILE:-}" ] || return 0
  tama_log_destination_ready || return 0
  TAMA_LOG_CORRELATION_ID="${TAMA_LOG_CORRELATION_ID:-c-$$-${RANDOM:-0}}"
  TAMA_LOG_OPERATION_ID="o-$$-${RANDOM:-0}"
  TAMA_LOG_STARTED_AT="$(tama_log_clock)" || TAMA_LOG_STARTED_AT=''
  export TAMA_LOG_CORRELATION_ID TAMA_LOG_OPERATION_ID
  tama_log_write command.started "$1"
}

tama_log_integration() { # <event-family> <integration> <provider-event> <outcome> [reason]
  local event="$1" integration="$2" provider_event="$3" outcome="$4" reason="${5:-}"
  local correlation operation parent
  tama_log_destination_ready || return 0
  correlation="${TAMA_LOG_CORRELATION_ID:-c-$$-${RANDOM:-0}}"
  operation="${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}"
  parent="${TAMA_LOG_PARENT_OPERATION_ID:-}"
  jq -cn \
    --arg version "${TAMA_VERSION:-unknown}" --arg event "$event" \
    --arg integration "$integration" --arg integration_event "$provider_event" \
    --arg correlation_id "$correlation" --arg operation_id "$operation" \
    --arg parent_operation_id "$parent" --arg outcome "$outcome" --arg reason "$reason" \
    --argjson pid "$$" '
      now as $n | {
        version: $version,
        timestamp: (($n | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." +
          (((($n * 1000 | floor) % 1000) | tostring) as $ms | ("000" + $ms)[-3:]) + "Z"),
        unix_time: $n, event: $event, pid: $pid,
        correlation_id: $correlation_id, operation_id: $operation_id,
        integration: $integration, integration_event: $integration_event,
        outcome: $outcome
      }
      + (if $parent_operation_id == "" then {} else
          {parent_operation_id: $parent_operation_id} end)
      + (if $reason == "" then {} else {reason: $reason} end)
    ' >>"$TAMA_LOG_FILE" 2>/dev/null || true
}

tama_log_state_decision() { # <outcome> <reason> <pane> <window> <before-main> <before-derived> <count> <after-main> <after-derived>
  local outcome="$1" reason="$2" pane_id="$3" window_id="$4"
  local before_main="$5" before_derived="$6" subagent_count="$7"
  local after_main="$8" after_derived="$9"
  tama_log_destination_ready || return 0
  jq -cn \
    --arg version "${TAMA_VERSION:-unknown}" --arg correlation_id "${TAMA_LOG_CORRELATION_ID:-c-$$-${RANDOM:-0}}" \
    --arg operation_id "${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}" \
    --arg parent_operation_id "${TAMA_LOG_PARENT_OPERATION_ID:-}" \
    --arg pane_id "$pane_id" --arg window_id "$window_id" \
    --arg outcome "$outcome" --arg reason "$reason" \
    --arg before_main "$before_main" --arg before_derived "$before_derived" \
    --arg after_main "$after_main" --arg after_derived "$after_derived" \
    --argjson subagent_count "$subagent_count" --argjson pid "$$" '
      now as $n | {
        version: $version,
        timestamp: (($n | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." +
          (((($n * 1000 | floor) % 1000) | tostring) as $ms | ("000" + $ms)[-3:]) + "Z"),
        unix_time: $n, event: "decision.made", pid: $pid,
        correlation_id: $correlation_id, operation_id: $operation_id,
        operation: "report_state", outcome: $outcome,
        pane_id: $pane_id, window_id: $window_id,
        state_before: {main: $before_main, derived: $before_derived, subagent_count: $subagent_count},
        state_after: {main: $after_main, derived: $after_derived, subagent_count: $subagent_count}
      }
      + (if $parent_operation_id == "" then {} else
          {parent_operation_id: $parent_operation_id} end)
      + (if $reason == "" then {} else {reason: $reason} end)
    ' >>"$TAMA_LOG_FILE" 2>/dev/null || true
}

tama_log_effect() { # <event> <operation> <effect-operation-id> <outcome> [started-at] [reason]
  local event="$1" operation="$2" effect_id="$3" outcome="$4"
  local started_at="${5:-}" reason="${6:-}"
  tama_log_destination_ready || return 0
  jq -cn --arg version "${TAMA_VERSION:-unknown}" --arg event "$event" \
    --arg operation "$operation" --arg operation_id "$effect_id" \
    --arg parent_operation_id "${TAMA_LOG_OPERATION_ID:-}" \
    --arg correlation_id "${TAMA_LOG_CORRELATION_ID:-c-$$-${RANDOM:-0}}" \
    --arg outcome "$outcome" --arg started_at "$started_at" --arg reason "$reason" \
    --argjson pid "$$" '
      now as $n | {
        version: $version,
        timestamp: (($n | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." +
          (((($n * 1000 | floor) % 1000) | tostring) as $ms | ("000" + $ms)[-3:]) + "Z"),
        unix_time: $n, event: $event, pid: $pid,
        correlation_id: $correlation_id, operation_id: $operation_id,
        parent_operation_id: $parent_operation_id, operation: $operation
      }
      + (if $outcome == "" then {} else {outcome: $outcome} end)
      + (if $reason == "" then {} else {reason: $reason} end)
      + (if $started_at == "" then {} else
          {duration_ms: ((($n - ($started_at | tonumber)) * 1000) | if . < 0 then 0 else . end)} end)
    ' >>"$TAMA_LOG_FILE" 2>/dev/null || true
}

tama_log_attention_decision() { # <pane> <window> <priority> <flag yes|no> <notification yes|no>
  local pane_id="$1" window_id="$2" priority="$3" flag="$4" notification="$5"
  local flag_json=false notification_json=false outcome=skipped reason=attention_not_eligible
  [ "$flag" = yes ] && flag_json=true
  [ "$notification" = yes ] && notification_json=true
  if [ "$flag" = yes ] || [ "$notification" = yes ]; then
    outcome=applied
    reason=''
  fi
  tama_log_destination_ready || return 0
  jq -cn --arg version "${TAMA_VERSION:-unknown}" \
    --arg correlation_id "${TAMA_LOG_CORRELATION_ID:-c-$$-${RANDOM:-0}}" \
    --arg operation_id "${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}" \
    --arg pane_id "$pane_id" --arg window_id "$window_id" --arg priority "$priority" \
    --arg outcome "$outcome" --arg reason "$reason" \
    --argjson flag_eligible "$flag_json" --argjson notification_eligible "$notification_json" \
    --argjson pid "$$" '
      now as $n | {
        version: $version,
        timestamp: (($n | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." +
          (((($n * 1000 | floor) % 1000) | tostring) as $ms | ("000" + $ms)[-3:]) + "Z"),
        unix_time: $n, event: "decision.made", pid: $pid,
        correlation_id: $correlation_id, operation_id: $operation_id,
        operation: "attention_policy", outcome: $outcome,
        pane_id: $pane_id, window_id: $window_id, priority: $priority,
        flag_eligible: $flag_eligible, notification_eligible: $notification_eligible
      } + (if $reason == "" then {} else {reason: $reason} end)
    ' >>"$TAMA_LOG_FILE" 2>/dev/null || true
}

tama_log_command_complete() { # <command> <status>
  local outcome=failed
  [ "$2" -eq 0 ] && outcome=applied
  tama_log_write command.completed "$1" "$outcome" "$TAMA_LOG_STARTED_AT"
}

# shellcheck shell=bash
# Opt-in lifecycle Log. Disabled commands do no lookup, formatting, or file work.

TAMA_LOG_OPERATION_ID="${TAMA_LOG_OPERATION_ID:-}"
TAMA_LOG_STARTED_AT="${TAMA_LOG_STARTED_AT:-}"

TAMA_LOG_IDENTIFIER_LIMIT=64

tama_log_safe_identifier() { # <value> <fallback>
  case "$1" in
    '' | *[!A-Za-z0-9_.-]*) TAMA_LOG_SAFE_IDENTIFIER="$2" ;;
    *)
      if [ "${#1}" -gt "$TAMA_LOG_IDENTIFIER_LIMIT" ]; then
        TAMA_LOG_SAFE_IDENTIFIER="$2"
      else
        TAMA_LOG_SAFE_IDENTIFIER="$1"
      fi
      ;;
  esac
}

tama_log_safe_state() { # <value>
  case "$1" in
    '' | running | waiting | idle | error | background) TAMA_LOG_SAFE_STATE="$1" ;;
    *) TAMA_LOG_SAFE_STATE=unknown ;;
  esac
}

tama_log_destination_ready() {
  local path="${TAMA_LOG_FILE:-}" parent
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ -w "$path" ] || return 1
  else
    parent="${path%/*}"; [ -n "$parent" ] || parent=/
    [ -d "$parent" ] && [ -w "$parent" ] || return 1
    (umask 077 && : >>"$path") 2>/dev/null || return 1
  fi
}

tama_log_clock() { jq -nr 'now' 2>/dev/null; }

tama_log_command_result() { # <applied|skipped|failed>
  [ "${TAMA_LOG_RESULT_FD:-}" = 3 ] || return 0
  case "$1" in applied | skipped | failed) ;; *) return 0 ;; esac
  printf '%s\n' "$1" >&3 2>/dev/null || true
}

tama_log_outcome_from_results() { # <newline-separated outcomes>
  local result
  TAMA_LOG_OUTCOME=''
  while IFS= read -r result; do
    case "$result" in
      failed) TAMA_LOG_OUTCOME=failed; break ;;
      applied) [ "$TAMA_LOG_OUTCOME" = failed ] || TAMA_LOG_OUTCOME=applied ;;
      skipped) [ -n "$TAMA_LOG_OUTCOME" ] || TAMA_LOG_OUTCOME=skipped ;;
    esac
  done <<EOF
$1
EOF
}

# The one owner of the persistent envelope. Payload filters below are fixed code;
# untrusted values reach jq only through --arg.
tama_log_emit() { # <event> <operation-id> <parent-id> <started-at> <filter> [jq args...]
  local event="$1" operation_id="$2" parent_id="$3" started_at="$4" filter="$5"
  shift 5
  tama_log_destination_ready || return 0
  tama_log_safe_identifier "${TAMA_LOG_CORRELATION_ID:-}" "c-$$-${RANDOM:-0}"
  local correlation_id="$TAMA_LOG_SAFE_IDENTIFIER"
  tama_log_safe_identifier "$operation_id" "o-$$-${RANDOM:-0}"
  operation_id="$TAMA_LOG_SAFE_IDENTIFIER"
  tama_log_safe_identifier "$parent_id" ''
  parent_id="$TAMA_LOG_SAFE_IDENTIFIER"
  jq -cn --arg version "${TAMA_VERSION:-unknown}" --arg event "$event" \
    --arg correlation_id "$correlation_id" \
    --arg operation_id "$operation_id" --arg parent_operation_id "$parent_id" \
    --arg started_at "$started_at" --argjson pid "$$" "$@" "
      now as \$n | {
        version: \$version,
        timestamp: ((\$n | floor | strftime(\"%Y-%m-%dT%H:%M:%S\")) + \".\" +
          ((((\$n * 1000 | floor) % 1000) | tostring) as \$ms |
            (\"000\" + \$ms)[-3:]) + \"Z\"),
        unix_time: \$n, event: \$event, pid: \$pid,
        correlation_id: \$correlation_id, operation_id: \$operation_id
      }
      + (if \$parent_operation_id == \"\" then {} else
          {parent_operation_id: \$parent_operation_id} end)
      + (if \$started_at == \"\" then {} else
          {duration_ms: (((\$n - (\$started_at | tonumber)) * 1000) |
            if . < 0 then 0 else . end)} end)
      + ($filter)
    " >>"$TAMA_LOG_FILE" 2>/dev/null || true
}

tama_log_write() { # <event> <command> [outcome] [started-at]
  local event="$1" command="$2" outcome="${3:-}" started_at="${4:-}"
  # shellcheck disable=SC2016 # jq variables expand inside jq, not the shell
  tama_log_emit "$event" "${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}" \
    "${TAMA_LOG_PARENT_OPERATION_ID:-}" "$started_at" \
    '{command: $command} + (if $outcome == "" then {} else {outcome: $outcome} end)' \
    --arg command "$command" --arg outcome "$outcome"
}

tama_log_command_prepare() {
  [ -n "${TAMA_LOG_FILE:-}" ] || return 0
  tama_log_safe_identifier "${TAMA_LOG_CORRELATION_ID:-}" "c-$$-${RANDOM:-0}"
  TAMA_LOG_CORRELATION_ID="$TAMA_LOG_SAFE_IDENTIFIER"
  TAMA_LOG_OPERATION_ID="o-$$-${RANDOM:-0}"
  TAMA_LOG_STARTED_AT="$(tama_log_clock)" || TAMA_LOG_STARTED_AT=''
  export TAMA_LOG_CORRELATION_ID TAMA_LOG_OPERATION_ID
}

tama_log_command_start() {
  tama_log_command_prepare
  tama_log_write command.started "$1"
}

tama_log_command_complete() {
  local outcome="${3:-}"
  if [ "$2" -ne 0 ]; then
    outcome=failed
  elif [ -z "$outcome" ]; then
    outcome=applied
  fi
  tama_log_write command.completed "$1" "$outcome" "$TAMA_LOG_STARTED_AT"
}

tama_log_integration() { # <event> <integration> <provider-event> <outcome> [reason] [start]
  local event="$1" integration="$2" provider_event="$3" outcome="$4"
  local reason="${5:-}" started_at="${6:-}"
  tama_log_safe_identifier "$integration" unrecognized
  integration="$TAMA_LOG_SAFE_IDENTIFIER"
  tama_log_safe_identifier "$provider_event" unrecognized
  provider_event="$TAMA_LOG_SAFE_IDENTIFIER"
  [ "$event" != integration.classified ] || [ -z "$outcome" ] || \
    tama_log_command_result "$outcome"
  # shellcheck disable=SC2016 # jq variables expand inside jq, not the shell
  tama_log_emit "$event" "${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}" \
    "${TAMA_LOG_PARENT_OPERATION_ID:-}" "$started_at" '
      {integration: $integration, integration_event: $integration_event} +
      (if $outcome == "" then {} else {outcome: $outcome} end) +
      (if $reason == "" then {} else {reason: $reason} end)' \
    --arg integration "$integration" --arg integration_event "$provider_event" \
    --arg outcome "$outcome" --arg reason "$reason"
}

tama_log_state_decision() { # <operation> <outcome> <reason> <pane> <window> <before-main> <before-derived> <before-count> <after-main> <after-derived> <after-count>
  local operation="$1" outcome="$2" reason="$3" pane_id="$4" window_id="$5"
  local before_main="$6" before_derived="$7" before_count="$8" after_main="$9"
  shift 9; local after_derived="$1" after_count="$2"
  tama_log_safe_state "$before_main"; before_main="$TAMA_LOG_SAFE_STATE"
  tama_log_safe_state "$before_derived"; before_derived="$TAMA_LOG_SAFE_STATE"
  tama_log_safe_state "$after_main"; after_main="$TAMA_LOG_SAFE_STATE"
  tama_log_safe_state "$after_derived"; after_derived="$TAMA_LOG_SAFE_STATE"
  tama_log_command_result "$outcome"
  # shellcheck disable=SC2016 # jq variables expand inside jq, not the shell
  tama_log_emit decision.made "${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}" \
    "${TAMA_LOG_PARENT_OPERATION_ID:-}" '' '
      {operation: $operation, outcome: $outcome, pane_id: $pane_id, window_id: $window_id,
       state_before: {main: $before_main, derived: $before_derived, subagent_count: $before_count},
       state_after: {main: $after_main, derived: $after_derived, subagent_count: $after_count}} +
      (if $reason == "" then {} else {reason: $reason} end)' \
    --arg operation "$operation" --arg outcome "$outcome" --arg reason "$reason" \
    --arg pane_id "$pane_id" --arg window_id "$window_id" \
    --arg before_main "$before_main" --arg before_derived "$before_derived" \
    --argjson before_count "$before_count" --arg after_main "$after_main" \
    --arg after_derived "$after_derived" --argjson after_count "$after_count"
}

tama_log_subagent_attempt() { # <outcome> <reason> <attempt> <pane> <window> <main> <before-derived> <before-count> <after-derived> <after-count>
  local outcome="$1" reason="$2" attempt="$3" pane_id="$4" window_id="$5"
  local main="$6" before_derived="$7" before_count="$8" after_derived="$9"
  shift 9; local after_count="$1"
  tama_log_safe_state "$main"; main="$TAMA_LOG_SAFE_STATE"
  tama_log_safe_state "$before_derived"; before_derived="$TAMA_LOG_SAFE_STATE"
  tama_log_safe_state "$after_derived"; after_derived="$TAMA_LOG_SAFE_STATE"
  tama_log_command_result "$outcome"
  # shellcheck disable=SC2016 # jq variables expand inside jq, not the shell
  tama_log_emit decision.made "${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}" \
    "${TAMA_LOG_PARENT_OPERATION_ID:-}" '' '
      {operation: "update_subagents", attempt: $attempt, outcome: $outcome,
       pane_id: $pane_id, window_id: $window_id,
       state_before: {main: $main, derived: $before_derived, subagent_count: $before_count},
       state_after: {main: $main, derived: $after_derived, subagent_count: $after_count}} +
      (if $reason == "" then {} else {reason: $reason} end)' \
    --arg outcome "$outcome" --arg reason "$reason" --argjson attempt "$attempt" \
    --arg pane_id "$pane_id" --arg window_id "$window_id" --arg main "$main" \
    --arg before_derived "$before_derived" --argjson before_count "$before_count" \
    --arg after_derived "$after_derived" --argjson after_count "$after_count"
}

tama_log_effect() { # <event> <operation> <effect-id> <outcome> [start] [reason]
  local event="$1" operation="$2" effect_id="$3" outcome="$4"
  local started_at="${5:-}" reason="${6:-}"
  # shellcheck disable=SC2016 # jq variables expand inside jq, not the shell
  tama_log_emit "$event" "$effect_id" "${TAMA_LOG_OPERATION_ID:-}" "$started_at" '
      {operation: $operation} +
      (if $outcome == "" then {} else {outcome: $outcome} end) +
      (if $reason == "" then {} else {reason: $reason} end)' \
    --arg operation "$operation" --arg outcome "$outcome" --arg reason "$reason"
}

tama_log_attention_decision() { # <pane> <window> <priority> <flag> <notification> <eligible>
  local pane_id="$1" window_id="$2" priority="$3" flag="$4" notification="$5"
  local priority_json=false flag_json=false notification_json=false outcome=skipped reason=attention_not_eligible
  [ -n "$priority" ] && priority_json=true
  [ "$flag" = yes ] && flag_json=true
  [ "$notification" = yes ] && notification_json=true
  if [ "$6" = yes ]; then outcome=applied; reason=''; fi
  # shellcheck disable=SC2016 # jq variables expand inside jq, not the shell
  tama_log_emit decision.made "${TAMA_LOG_OPERATION_ID:-o-$$-${RANDOM:-0}}" \
    "${TAMA_LOG_PARENT_OPERATION_ID:-}" '' '
      {operation: "attention_policy", outcome: $outcome,
       pane_id: $pane_id, window_id: $window_id, priority: $priority,
       flag_eligible: $flag_eligible, notification_eligible: $notification_eligible} +
      (if $reason == "" then {} else {reason: $reason} end)' \
    --arg pane_id "$pane_id" --arg window_id "$window_id" --argjson priority "$priority_json" \
    --arg outcome "$outcome" --arg reason "$reason" --argjson flag_eligible "$flag_json" \
    --argjson notification_eligible "$notification_json"
}

# shellcheck shell=bash
#
# Priority is a persistent classification on a tmux window. Priority mode is
# derived server-wide from those window options and therefore cannot drift.

TAMA_PRIORITY_MAX_PERCENT_DEFAULT=80
TAMA_FLAG_POLICY_DEFAULT=ambient
TAMA_PRIORITY_COUNTS_READY='no'

# Reads all unique tmux windows once and exposes counts to policy and toggles.
# list-windows -a repeats linked windows, so immutable ids are deduplicated.
tama_priority_counts() {
  local records record id value previous=''
  [ "$TAMA_PRIORITY_COUNTS_READY" = no ] || return 0
  TAMA_PRIORITY_WINDOW_COUNT=0
  TAMA_PRIORITIZED_WINDOW_COUNT=0
  records="$(tmux_run list-windows -a -F "#{window_id} #{${TAMA_WINDOW_PRIORITY_OPTION}}" \
    2>/dev/null | LC_ALL=C sort -u)" || records=''

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    id="${record%% *}"
    [ "$id" != "$previous" ] || continue
    value="${record#* }"
    TAMA_PRIORITY_WINDOW_COUNT=$((TAMA_PRIORITY_WINDOW_COUNT + 1))
    [ -z "$value" ] || TAMA_PRIORITIZED_WINDOW_COUNT=$((TAMA_PRIORITIZED_WINDOW_COUNT + 1))
    previous="$id"
  done <<EOF
$records
EOF
  TAMA_PRIORITY_COUNTS_READY='yes'
}

# The last tama_window_read target is eligible when mode is inactive or it has
# Priority itself.
tama_priority_window_is_eligible() {
  tama_priority_counts
  [ "$TAMA_PRIORITIZED_WINDOW_COUNT" -eq 0 ] || [ -n "$TAMA_WINDOW_PRIORITY" ]
}

# Reads and normalizes a valid percentage into TAMA_PRIORITY_MAX_PERCENT.
tama_priority_max_percent_read() {
  local configured normalized
  configured="$(tama_opt tama_priority_max_percent "$TAMA_PRIORITY_MAX_PERCENT_DEFAULT")"
  case "$configured" in
    *[!0-9]* | '') return 1 ;;
  esac
  normalized="$configured"
  while [ "${normalized#0}" != "$normalized" ]; do normalized="${normalized#0}"; done
  [ -n "$normalized" ] || normalized=0
  case "$normalized" in ???*) return 1 ;; esac
  [ "$normalized" -ge 1 ] && [ "$normalized" -le 100 ] || return 1
  TAMA_PRIORITY_MAX_PERCENT="$normalized"
}

tama_priority_permitted_count() {
  tama_priority_max_percent_read || return 1
  TAMA_PRIORITY_PERMITTED_COUNT=$((
    TAMA_PRIORITY_WINDOW_COUNT * TAMA_PRIORITY_MAX_PERCENT / 100
  ))
  [ "$TAMA_PRIORITY_PERMITTED_COUNT" -ge 1 ] || TAMA_PRIORITY_PERMITTED_COUNT=1
}

tama_flag_policy_is_valid() { # <value>
  case "$1" in ambient | selective) return 0 ;; esac
  return 1
}

tama_priority_flag_is_eligible() {
  local policy
  policy="$(tama_opt tama_flag_policy "$TAMA_FLAG_POLICY_DEFAULT")"
  [ "$policy" = selective ] || return 0
  tama_priority_window_is_eligible
}

# tmux silently picks one window for an ambiguous bare name or prefix. The command
# instead requires one unique tmux window.
tama_priority_target_is_ambiguous() { # <target>
  local records record id name seen='' exact=0 partial=0
  case "$1" in
    @* | *:*) return 1 ;;
    *[!0-9]*) ;;
    *) return 1 ;;
  esac
  records="$(tmux_run list-windows -a -F '#{window_id} #{window_name}' 2>/dev/null)" || return 1
  while IFS= read -r record; do
    id="${record%% *}"
    name="${record#* }"
    case " $seen " in *" $id "*) continue ;; esac
    seen="$seen $id"
    if [ "$name" = "$1" ]; then
      exact=$((exact + 1))
    else
      case "$1" in
        *'*'* | *'?'* | *'['*)
          # shellcheck disable=SC2254  # the target deliberately carries a tmux glob
          case "$name" in $1) partial=$((partial + 1)) ;; esac
          ;;
        *) [ "${name#"$1"}" = "$name" ] || partial=$((partial + 1)) ;;
      esac
    fi
  done <<EOF
$records
EOF
  [ "$exact" -gt 1 ] || { [ "$exact" -eq 0 ] && [ "$partial" -gt 1 ]; }
}

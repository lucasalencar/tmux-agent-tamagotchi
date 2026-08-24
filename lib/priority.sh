# shellcheck shell=bash
#
# Priority is a persistent classification on a tmux window. Priority mode is
# derived server-wide from those window options and therefore cannot drift.

TAMA_WINDOW_PRIORITY_OPTION='@tama_window_priority'

# Reads all unique tmux windows once and exposes counts to policy and toggles.
# list-windows -a repeats linked windows, so immutable ids are deduplicated.
tama_priority_counts() {
  local records record id value previous=''
  TAMA_PRIORITY_WINDOW_COUNT=0
  TAMA_PRIORITY_SELECTED_COUNT=0
  records="$(tmux_run list-windows -a -F "#{window_id} #{${TAMA_WINDOW_PRIORITY_OPTION}}" \
    2>/dev/null | LC_ALL=C sort -u)" || records=''

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    id="${record%% *}"
    [ "$id" != "$previous" ] || continue
    value="${record#* }"
    TAMA_PRIORITY_WINDOW_COUNT=$((TAMA_PRIORITY_WINDOW_COUNT + 1))
    [ -z "$value" ] || TAMA_PRIORITY_SELECTED_COUNT=$((TAMA_PRIORITY_SELECTED_COUNT + 1))
    previous="$id"
  done <<EOF
$records
EOF
}

# The last tama_window_read target is eligible when mode is inactive or it has
# Priority itself.
tama_priority_window_is_eligible() {
  tama_priority_counts
  [ "$TAMA_PRIORITY_SELECTED_COUNT" -eq 0 ] || [ -n "$TAMA_WINDOW_PRIORITY" ]
}

# Invalid and empty values mean no limit. doctor reports them separately.
tama_priority_limit() {
  local configured
  configured="$(tama_opt tama_priority_max_percent 80)"
  case "$configured" in
    *[!0-9]* | '') return 1 ;;
  esac
  [ "$configured" -ge 1 ] 2>/dev/null && [ "$configured" -le 100 ] 2>/dev/null || return 1
  # shellcheck disable=SC2034  # read by libexec/toggle-priority
  TAMA_PRIORITY_MAX_PERCENT="$configured"
  TAMA_PRIORITY_PERMITTED_COUNT=$((TAMA_PRIORITY_WINDOW_COUNT * configured / 100))
  [ "$TAMA_PRIORITY_PERMITTED_COUNT" -ge 1 ] || TAMA_PRIORITY_PERMITTED_COUNT=1
}

tama_priority_flag_is_eligible() {
  local policy
  policy="$(tama_opt tama_flag_policy ambient)"
  [ "$policy" = selective ] || return 0
  tama_priority_window_is_eligible
}

# A bare exact name can occur in several sessions; tmux otherwise silently picks
# one. The command promises an explicit, unique target, so surface that ambiguity.
tama_priority_bare_name_is_ambiguous() { # <target>
  local records record id name seen='' matches=0
  case "$1" in
    @* | *:*) return 1 ;;
  esac
  records="$(tmux_run list-windows -a -F '#{window_id} #{window_name}' 2>/dev/null)" || return 1
  while IFS= read -r record; do
    id="${record%% *}"
    name="${record#* }"
    case " $seen " in *" $id "*) continue ;; esac
    seen="$seen $id"
    [ "$name" = "$1" ] || continue
    matches=$((matches + 1))
    [ "$matches" -le 1 ] || return 0
  done <<EOF
$records
EOF
  return 1
}

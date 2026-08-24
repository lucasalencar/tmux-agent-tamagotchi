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
  TAMA_TOTAL_WINDOW_COUNT=0
  TAMA_PRIORITY_WINDOW_COUNT=0
  records="$(tmux_run list-windows -a -F "#{window_id} #{${TAMA_WINDOW_PRIORITY_OPTION}}" \
    2>/dev/null | LC_ALL=C sort -u)" || records=''

  while IFS= read -r record; do
    [ -n "$record" ] || continue
    id="${record%% *}"
    [ "$id" != "$previous" ] || continue
    value="${record#* }"
    TAMA_TOTAL_WINDOW_COUNT=$((TAMA_TOTAL_WINDOW_COUNT + 1))
    [ -z "$value" ] || TAMA_PRIORITY_WINDOW_COUNT=$((TAMA_PRIORITY_WINDOW_COUNT + 1))
    previous="$id"
  done <<EOF
$records
EOF
  TAMA_PRIORITY_COUNTS_READY='yes'
}

# The last tama_window_read target is eligible when mode is inactive or it has
# Priority itself.
tama_priority_window_is_eligible() { # <window priority value>
  tama_priority_counts
  [ "$TAMA_PRIORITY_WINDOW_COUNT" -eq 0 ] || [ -n "$1" ]
}

# Normalizes a valid percentage into TAMA_PRIORITY_MAX_PERCENT.
tama_priority_max_percent_normalize() { # <configured value>
  local normalized
  case "$1" in
    *[!0-9]* | '') return 1 ;;
  esac
  normalized="$1"
  while [ "${normalized#0}" != "$normalized" ]; do normalized="${normalized#0}"; done
  [ -n "$normalized" ] || normalized=0
  case "$normalized" in ????*) return 1 ;; esac
  [ "$normalized" -ge 1 ] && [ "$normalized" -le 100 ] || return 1
  TAMA_PRIORITY_MAX_PERCENT="$normalized"
}

tama_priority_max_percent_read() {
  local configured
  configured="$(tama_opt tama_priority_max_percent "$TAMA_PRIORITY_MAX_PERCENT_DEFAULT")"
  tama_priority_max_percent_normalize "$configured"
}

tama_priority_permitted_count() {
  tama_priority_counts
  tama_priority_max_percent_read || return 1
  TAMA_PRIORITY_PERMITTED_COUNT=$((
    TAMA_TOTAL_WINDOW_COUNT * TAMA_PRIORITY_MAX_PERCENT / 100
  ))
  [ "$TAMA_PRIORITY_PERMITTED_COUNT" -ge 1 ] || TAMA_PRIORITY_PERMITTED_COUNT=1
}

tama_flag_policy_is_valid() { # <value>
  case "$1" in ambient | selective) return 0 ;; esac
  return 1
}

tama_priority_flag_is_eligible() { # <window priority value>
  local policy
  policy="$(tama_opt tama_flag_policy "$TAMA_FLAG_POLICY_DEFAULT")"
  [ "$policy" = selective ] || return 0
  tama_priority_window_is_eligible "$1"
}

# Resolves supported name targets to one immutable id before reading the window.
# Other tmux target forms are resolved directly by tmux.
tama_priority_target_resolve() { # <target>
  local original="$1" target="$1" session='' exact_only='no'
  local records record id name seen='' exact=0 partial=0 exact_id='' partial_id=''
  case "$1" in
    @*) tama_window_read "$1"; return ;;
    *:*)
      session="${target%%:*}"
      target="${target#*:}"
      [ -n "$target" ] || { tama_window_read "$original"; return; }
      ;;
  esac
  case "$target" in
    @* | [0-9]* | +* | -* | '^' | '$' | '!' | '{'*'}')
      tama_window_read "$original"
      return
      ;;
    =*) exact_only='yes'; target="${target#=}"
        [ -n "$target" ] || return 1 ;;
    *[!0-9]*) ;;
    *) tama_window_read "$original"; return ;;
  esac
  if [ -n "$session" ]; then
    records="$(tmux_run list-windows -t "$session" -F '#{window_id} #{window_name}' \
      2>/dev/null)" || return 1
  elif [ "${original#:}" != "$original" ]; then
    session="$(tmux_run display-message -p '#{session_id}' 2>/dev/null)" || return 1
    [ -n "$session" ] || return 1
    records="$(tmux_run list-windows -t "$session" -F '#{window_id} #{window_name}' \
      2>/dev/null)" || return 1
  else
    records="$(tmux_run list-windows -a -F '#{window_id} #{window_name}' 2>/dev/null)" || return 1
  fi
  while IFS= read -r record; do
    id="${record%% *}"
    name="${record#* }"
    case " $seen " in *" $id "*) continue ;; esac
    seen="$seen $id"
    if [ "$name" = "$target" ]; then
      exact=$((exact + 1))
      exact_id="$id"
    elif [ "$exact_only" = yes ]; then
      continue
    else
      case "$target" in
        *'*'* | *'?'* | *'['*)
          # shellcheck disable=SC2254  # the target deliberately carries a tmux glob
          case "$name" in $target) partial=$((partial + 1)); partial_id="$id" ;; esac
          ;;
        *)
          if [ "${name#"$target"}" != "$name" ]; then
            partial=$((partial + 1))
            partial_id="$id"
          fi
          ;;
      esac
    fi
  done <<EOF
$records
EOF
  if [ "$exact" -eq 1 ]; then
    tama_window_read "$exact_id"
  elif [ "$exact" -eq 0 ] && [ "$partial" -eq 1 ]; then
    tama_window_read "$partial_id"
  else
    return 1
  fi
}

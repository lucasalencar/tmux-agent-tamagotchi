# shellcheck shell=bash
#
# Window identity, attention state, and the shared focused-window predicate.

# The flag outlives the state that raised it and is cleared only by selection.
TAMA_WINDOW_FLAG_OPTION='@tama_window_flag'
# shellcheck disable=SC2034  # read by notification writers
TAMA_WINDOW_NOTIFY_GROUP_OPTION='@tama_window_notify_group'
# shellcheck disable=SC2034  # read by notification writers
TAMA_WINDOW_NOTIFICATION_PENDING_OPTION='@tama_window_notification_pending'
TAMA_WINDOW_PRIORITY_OPTION='@tama_window_priority'

# Resolve activity against the target's session and write by immutable window id;
# indexes can collide across sessions and move under `renumber-windows`.
TAMA_WINDOW_READ_FIELDS="#{window_id}
#{window_active}
#{session_attached}
#{session_name}
#{pane_id}
#{pane_active}
#{$TAMA_WINDOW_FLAG_OPTION}
#{$TAMA_WINDOW_NOTIFICATION_PENDING_OPTION}
#{$TAMA_WINDOW_PRIORITY_OPTION}
."
TAMA_WINDOW_READ_COUNT=9

# Reads a pane or window target into TAMA_WINDOW_*; rejects incomplete records.
# shellcheck disable=SC2034
tama_window_read() { # <target>
  local raw field lines=0
  raw="$(tama_fields_read "$1" "$TAMA_WINDOW_READ_FIELDS")" || raw=''

  TAMA_WINDOW_ID=''
  TAMA_WINDOW_IS_CURRENT=''
  TAMA_WINDOW_SESSION_CLIENTS=''
  TAMA_WINDOW_SESSION=''
  TAMA_WINDOW_PANE_ID=''
  TAMA_WINDOW_PANE_IS_ACTIVE=''
  TAMA_WINDOW_FLAG=''
  TAMA_WINDOW_NOTIFICATION_PENDING=''
  TAMA_WINDOW_PRIORITY=''
  while IFS= read -r field; do
    lines=$((lines + 1))
    case "$lines" in
      1) TAMA_WINDOW_ID="$field" ;;
      2) TAMA_WINDOW_IS_CURRENT="$field" ;;
      3) TAMA_WINDOW_SESSION_CLIENTS="$field" ;;
      4) TAMA_WINDOW_SESSION="$field" ;;
      5) TAMA_WINDOW_PANE_ID="$field" ;;
      6) TAMA_WINDOW_PANE_IS_ACTIVE="$field" ;;
      7) TAMA_WINDOW_FLAG="$field" ;;
      8) TAMA_WINDOW_NOTIFICATION_PENDING="$field" ;;
      9) TAMA_WINDOW_PRIORITY="$field" ;;
    esac
  done <<EOF
$raw
EOF

  [ "$lines" -eq "$TAMA_WINDOW_READ_COUNT" ] || return 1

  # A window that is gone: tmux says so by expanding `#{window_id}` to nothing
  # rather than by failing, and writing from that would write somewhere else.
  [ -n "$TAMA_WINDOW_ID" ]
}

# The group is an opaque backend value, so unlike the rest of the window record it may
# contain a newline. Read it by option only when a pending marker says it is needed;
# putting it in the line-based record would corrupt every field after it.
tama_window_notification_group_read() {
  local group
  # shellcheck disable=SC2034  # read by lib/notify.sh after this helper returns
  TAMA_WINDOW_NOTIFY_GROUP=''
  [ -n "$TAMA_WINDOW_NOTIFICATION_PENDING" ] || return 0
  group="$(tmux_run show-options -wv -t "$TAMA_WINDOW_ID" \
    "$TAMA_WINDOW_NOTIFY_GROUP_OPTION" 2>/dev/null)" || group=''
  # shellcheck disable=SC2034  # read by lib/notify.sh after this helper returns
  TAMA_WINDOW_NOTIFY_GROUP="$group"
}

# Focus requires the reporting pane in an active window and an attached client.
# Uncertainty returns false so it may cause noise but never suppresses attention
# (ADR-0004).
tama_window_user_is_looking() {
  [ "$TAMA_WINDOW_IS_CURRENT" = '1' ] || return 1
  [ "$TAMA_WINDOW_PANE_IS_ACTIVE" = '1' ] || return 1
  case "$TAMA_WINDOW_SESSION_CLIENTS" in
    '' | 0) return 1 ;;
  esac
  return 0
}

# Raise on every event, even when state did not change: selection may have cleared
# an earlier flag between identical reports.
tama_flag_raise() { # <target>
  tama_window_read "$1" || return 0
  tama_window_user_is_looking && return 0
  tama_flag_set
}

# Automatic requests obey Priority policy; the public flag command deliberately
# continues to call tama_flag_raise as an explicit override.
tama_flag_raise_automatic() { # <target>
  tama_window_read "$1" || return 0
  tama_automatic_flag_is_eligible || return 0
  tama_flag_set
}

tama_automatic_flag_is_eligible() {
  tama_priority_flag_is_eligible "$TAMA_WINDOW_PRIORITY" || return 1
  ! tama_window_user_is_looking
}

# Called after the caller has decided that an automatic or explicit Flag is eligible.
# Use the previously read immutable id because a caller's index may have moved.
tama_flag_set() {
  tmux_run set -w -t "$TAMA_WINDOW_ID" "$TAMA_WINDOW_FLAG_OPTION" on \
    >/dev/null 2>&1 || true
}

# Returns success only when a mark existed. Notification dismissal uses its own
# pending marker because `tama unflag` may clear this independently.
tama_flag_clear() { # <target>
  tama_window_read "$1" || return 1
  tmux_run set -wuq -t "$TAMA_WINDOW_ID" "$TAMA_WINDOW_FLAG_OPTION" \
    >/dev/null 2>&1 || true
  [ -n "$TAMA_WINDOW_FLAG" ]
}

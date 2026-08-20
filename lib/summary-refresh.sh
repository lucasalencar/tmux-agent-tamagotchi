# shellcheck shell=bash
#
# Targeted status-summary refresh after a pane's rendered state changes.

# Refreshes each attached client whose session either exposes <window id> or uses
# the server-wide summary. Detached sessions have no client record and naturally
# require no work. Discovery and redraws are operational best effort: this runs in
# agent hooks, where a disappearing client or server must never fail the turn.
tama_summary_refresh_window() { # <window id>
  local window_id="$1" windows clients line session linked_sessions='' client scope rest
  [ -n "$window_id" ] || return 0

  windows="$(tmux_run list-windows -a -F '#{session_id} #{window_id}' 2>/dev/null)" || return 0
  while IFS= read -r line; do
    [ "${line#* }" = "$window_id" ] || continue
    session="${line%% *}"
    case "
$linked_sessions
" in
      *"
$session
"*) ;;
      *) linked_sessions="${linked_sessions:+$linked_sessions
}$session" ;;
    esac
  done <<EOF
$windows
EOF

  clients="$(tmux_run list-clients -F '#{client_name} #{session_id} #{@tama_summary_scope}' 2>/dev/null)" || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    client="${line%% *}"
    rest="${line#* }"
    session="${rest%% *}"
    scope="${rest#* }"
    if [ "$scope" != 'all' ]; then
      case "
$linked_sessions
" in
        *"
$session
"*) ;;
        *) continue ;;
      esac
    fi
    tmux_run refresh-client -S -t "$client" >/dev/null 2>&1 || true
  done <<EOF
$clients
EOF
}

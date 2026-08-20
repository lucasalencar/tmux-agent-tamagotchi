# shellcheck shell=bash
#
# Read-only inventory traversal shared by public inventory consumers. Callers
# choose their own records, ordering, filtering, and identity semantics.

tama_inventory_sessions() {
  tmux_run list-sessions -F '#{session_id}' 2>/dev/null
}

tama_inventory_session_id() { # <session target>
  tmux_run display-message -p -t "$1" '#{session_id}' 2>/dev/null
}

tama_inventory_windows() { # <session id>
  tmux_run list-windows -t "$1" -F '#{window_id}' 2>/dev/null
}

tama_inventory_panes() { # <window id>
  tmux_run list-panes -t "$1" -F '#{pane_id}' 2>/dev/null
}

tama_inventory_fields() { # <target> <newline-separated formats>
  tama_fields_read "$1" "$2"
}

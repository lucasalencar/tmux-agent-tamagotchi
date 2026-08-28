# shellcheck shell=bash
#
# Platform-independent notification policy. Helpers operate on the last window read.

# One group per window lets newer banners replace older ones.
TAMA_NOTIFY_GROUP_DEFAULT='tmux-window-#{window_id}'

# tmux may intermittently omit a live pane path, so fall back to the last reported cwd.
TAMA_NOTIFY_TITLE_DEFAULT='#{@tama_pane_agent} - #{?pane_current_path,#{b:pane_current_path},#{b:@tama_pane_cwd}}#{?@tama_pane_label, (#{@tama_pane_label}),}'

# Quotes an arbitrary value for the click action's shell command.
# shellcheck disable=SC2034  # TAMA_QUOTED is read by the caller
tama_shell_quote() { # <value>
  local rest="$1" out=''
  while :; do
    case "$rest" in
      *\'*)
        out="$out'${rest%%\'*}'\\'"
        rest="${rest#*\'}"
        ;;
      *)
        out="$out'$rest'"
        break
        ;;
    esac
  done
  TAMA_QUOTED="$out"
}

tama_notify_enabled() {
  tama_opt_enabled tama_notifications on
}

# Opens a private capture directory without depending on `mktemp`. The caller opens
# read and write descriptors and removes both names before running user code, so a
# detached descendant can keep only the anonymous file — never the hook's pipe.
# shellcheck disable=SC2034  # capture globals are read by the caller
tama_notify_capture_open() {
  local attempt=0 directory="${TMPDIR:-/tmp}"
  TAMA_NOTIFY_CAPTURE=''
  TAMA_NOTIFY_CAPTURE_DIR=''
  while [ "$attempt" -lt 10 ]; do
    TAMA_NOTIFY_CAPTURE_DIR="$directory/tama-label-$$-$RANDOM-$attempt"
    if (umask 077; mkdir "$TAMA_NOTIFY_CAPTURE_DIR") 2>/dev/null; then
      TAMA_NOTIFY_CAPTURE="$TAMA_NOTIFY_CAPTURE_DIR/output"
      (umask 077; : >"$TAMA_NOTIFY_CAPTURE") || return 1
      return 0
    fi
    attempt=$((attempt + 1))
  done
  TAMA_NOTIFY_CAPTURE=''
  TAMA_NOTIFY_CAPTURE_DIR=''
  return 1
}

# The group id for the window tama_window_read last read, in TAMA_NOTIFY_GROUP.
# A pending banner keeps the group it was raised with until dismissal, so changing
# the format cannot orphan it in the notification centre. The pending marker is
# separate because an empty group is a valid configuration.
tama_notify_group() {
  local format
  if [ -n "$TAMA_WINDOW_NOTIFICATION_PENDING" ]; then
    tama_window_notification_group_read
    TAMA_NOTIFY_GROUP="$TAMA_WINDOW_NOTIFY_GROUP"
    return 0
  fi
  format="$(tama_opt tama_group_format "$TAMA_NOTIFY_GROUP_DEFAULT")"
  TAMA_NOTIFY_GROUP="$(tmux_run display-message -p -t "$TAMA_WINDOW_ID" \
    "$format" 2>/dev/null)" || TAMA_NOTIFY_GROUP=''
}

# Expand the title against the reporting pane, which owns its path and agent metadata.
# shellcheck disable=SC2034  # TAMA_NOTIFY_TITLE is read by the caller
tama_notify_title() { # <pane_id>
  local format
  format="$(tama_opt tama_title_format "$TAMA_NOTIFY_TITLE_DEFAULT")"
  TAMA_NOTIFY_TITLE="$(tmux_run display-message -p -t "$1" "$format" 2>/dev/null)" ||
    TAMA_NOTIFY_TITLE=''
}

# A configured provider receives the window id; only its first storable line is used.
# shellcheck disable=SC2034  # TAMA_NOTIFY_LABEL is read by the caller
tama_notify_label() {
  local command label status
  TAMA_NOTIFY_LABEL=''
  command="$(tama_opt tama_label_command '')"
  [ -n "$command" ] || return 0

  # As arguments, never pasted into the program text: `"$1"` inside it, the window id
  # after it. A label provider is the user's own script and the window id is tmux's
  # own, but a command line built by substitution is a habit that only has to be
  # wrong once.
  tama_notify_capture_open || return 0
  # Separate descriptions preserve the reader's offset while the provider writes.
  # shellcheck disable=SC2094
  exec 8>"$TAMA_NOTIFY_CAPTURE" 9<"$TAMA_NOTIFY_CAPTURE"
  rm -f "$TAMA_NOTIFY_CAPTURE"
  rmdir "$TAMA_NOTIFY_CAPTURE_DIR" 2>/dev/null || true
  # A label is one short line. Bound the backing file as well as time so a provider
  # cannot consume unbounded disk or memory before it reaches a newline.
  (ulimit -f 2; tama_external_command_run sh -c "$command \"\$1\"" _ \
    "$TAMA_WINDOW_ID") >&8 2>/dev/null
  status=$?
  exec 8>&-
  if [ "$status" -eq 0 ]; then
    IFS= read -r label <&9 || true
  else
    label=''
  fi
  exec 9<&-

  # One line. A provider that prints several has said one thing and then said more.
  label="${label%%$'\n'*}"
  # A control character would come back from a tmux option changed or escaped
  # depending on the version and the locale — see lib/pane.sh. Then the title would
  # be nonsense rather than the label the user meant, so there is no label.
  tama_pane_value_is_storable "$label" || label=''
  TAMA_NOTIFY_LABEL="$label"
}

# Whether the user is demonstrably already looking at the window tama_window_read
# last read — the `AND` of ADR-0004, and the place focus suppression is decided.
#
# The cheap half is tmux's own answer, which lib/window.sh owns and the window mark
# asks the same way. It runs first because it costs nothing: it is already in the
# record, while the expensive half is a process that talks to the desktop.
#
# The expensive half is the backend's, and it is consulted *only* if the cheap one
# says yes — that ordering is the point of the ADR, not an optimization. tmux knows
# which window a client has active but has no idea whether the terminal is behind a
# browser, so trusting it alone means a minimized terminal silently swallows every
# banner, which is the worst thing this plugin could do. The backend knows whether
# the terminal is frontmost but identifies the window by a title the user configures,
# so trusting *it* alone breaks invisibly.
#
# Every way of not knowing therefore lands on "deliver": a backend with no `focused`
# capability, a `focused` that failed, a `focused` that says no. Noise, never silence.
tama_notify_suppressed() {
  tama_opt_enabled tama_suppress_when_focused on || return 1
  tama_window_user_is_looking || return 1

  tama_notify_export_context
  tama_backend_invoke focused
}

# The context every capability is given, in the environment rather than in argv so it
# can grow without breaking a backend written against an earlier version.
#
# TAMA_WINDOW_ID is this library's own shell variable exported under the name the
# contract gives it, which is safe in the one way that matters: every read sets it
# before anything looks at it, so a `bin/tama` that inherits one — the click action
# runs one — cannot be misled by it.
tama_notify_export_context() {
  TAMA_SESSION="$TAMA_WINDOW_SESSION"
  export TAMA_SESSION TAMA_WINDOW_ID
  tama_backend_export_terminal
}

# What clicking the banner does, in TAMA_NOTIFY_CLICK: one shell command line the
# backend hands to the desktop, which is the only reason this plugin ever composes a
# command out of values it did not choose. Every one of them is quoted.
#
# Select the window, then the pane, then bring the terminal forward — and chained with
# `;` rather than `&&` deliberately, so that each step happens whatever the one before
# it did. A pane that has since been closed, or a whole window that has, must still
# leave the user with their terminal in front: a click that does nothing at all is the
# one outcome that makes the banner feel broken.
#
# Composing it here rather than leaving it to each backend is a decision with an ADR
# (docs/adr/0006): the chain is what the user experiences, the backends are only the
# thing that carries it, and three backends assembling it separately would drift.
# shellcheck disable=SC2034  # TAMA_NOTIFY_CLICK is read by the caller
tama_notify_click() { # <window_id> <pane_id> <session>
  tama_notify_tmux_command
  local click

  tama_shell_quote "$1"
  click="$TAMA_NOTIFY_TMUX select-window -t $TAMA_QUOTED >/dev/null 2>&1"
  tama_shell_quote "$2"
  click="$click ; $TAMA_NOTIFY_TMUX select-pane -t $TAMA_QUOTED >/dev/null 2>&1"
  # The last step is the plugin's own, so that the terminal-specific half stays in the
  # backend and replaceable — see libexec/focus-window. It is handed the same server the
  # two steps above address, because it has to read its configuration out of it: without
  # that it would look for `@tama_backend` in whichever server a bare `tmux` reaches,
  # find nothing there, and quietly focus nothing at all. Observed, on a server started
  # with `-L`.
  click="$click ; $TAMA_NOTIFY_TMUX_ENV"
  tama_shell_quote "$TAMA_BIN"
  click="$click $TAMA_QUOTED focus-window"
  tama_shell_quote "$3"
  TAMA_NOTIFY_CLICK="$click $TAMA_QUOTED"
}

# How to reach *this* tmux server from a process the desktop starts, quoted, in two
# shapes: TAMA_NOTIFY_TMUX is a tmux invocation to put a command after, and
# TAMA_NOTIFY_TMUX_ENV is the same answer as environment assignments to put in front of a
# `bin/tama`.
#
# A click arrives long after the hook that raised the banner has exited, in a process
# with none of its environment: no `$TMUX`, no `$TAMA_TMUX`, and on macOS not even the
# login shell's `PATH`. So the invocation has to be baked into the command line, and
# it has to name the right server — a user running tmux on a socket of their own would
# otherwise have their clicks land on a server they are not looking at, or on none.
#
# Server resolution is shared with tmux_run. The difference here is the final branch:
# with no explicit selector and no `$TMUX`, a click keeps the deliberate default-server
# fallback. The plugin entrypoint refuses that same branch, because running it by hand
# must never reconfigure an implicit server.
#
# The binary is resolved to an absolute path while there is still a `PATH` to resolve
# it with.
tama_notify_tmux_command() {
  local path="$TAMA_TMUX" resolved arg args=''
  case "$path" in
    # Already a path. `command -v` on one is not an improvement.
    */*) ;;
    *)
      resolved="$(command -v "$path" 2>/dev/null)" || resolved=''
      [ -z "$resolved" ] || path="$resolved"
      ;;
  esac

  tama_tmux_server_resolve || true

  tama_shell_quote "$path"
  TAMA_NOTIFY_TMUX="$TAMA_QUOTED"
  TAMA_NOTIFY_TMUX_ENV="TAMA_TMUX=$TAMA_QUOTED TAMA_TMUX_ARGS='' TAMA_TMUX_SOCKET=''"

  # Explicit leading arguments retain their documented word splitting. A socket derived
  # from TMUX takes the exact-socket path below instead, so spaces remain one argument.
  if [ "$TAMA_TMUX_SERVER_KIND" = args ]; then
    args="$TAMA_TMUX_ARGS"
    # Split into words, globbing off, exactly as tmux_run does.
    set -f
    # shellcheck disable=SC2086  # deliberate: "-L socket" is two arguments
    set -- $args
    set +f
    for arg in "$@"; do
      tama_shell_quote "$arg"
      TAMA_NOTIFY_TMUX="$TAMA_NOTIFY_TMUX $TAMA_QUOTED"
    done
    tama_shell_quote "$args"
    TAMA_NOTIFY_TMUX_ENV="$TAMA_NOTIFY_TMUX_ENV TAMA_TMUX_ARGS=$TAMA_QUOTED"
  elif [ "$TAMA_TMUX_SERVER_KIND" = socket ]; then
    TAMA_NOTIFY_TMUX="$TAMA_NOTIFY_TMUX -S"
    tama_shell_quote "$TAMA_TMUX_SERVER_SOCKET"
    TAMA_NOTIFY_TMUX="$TAMA_NOTIFY_TMUX $TAMA_QUOTED"
    TAMA_NOTIFY_TMUX_ENV="$TAMA_NOTIFY_TMUX_ENV TAMA_TMUX_SOCKET=$TAMA_QUOTED"
  fi
  return 0
}

# Takes down the banner named by the group the window last stored. An explicit dismiss
# also expands the current format when no banner was recorded, which keeps it useful for
# a user cleaning up a banner from before this version.
#
# Nothing here asks the desktop whether there *is* one: dismissing a group with no
# banner is a harmless no-op. The window marker only preserves the group that `notify`
# used and says when that persisted identity should be cleared.
tama_notify_dismiss() {
  tama_notify_group

  if [ -n "$TAMA_WINDOW_NOTIFICATION_PENDING" ]; then
    tmux_run set -wuq -t "$TAMA_WINDOW_ID" "$TAMA_WINDOW_NOTIFY_GROUP_OPTION" \
      ';' set -wuq -t "$TAMA_WINDOW_ID" "$TAMA_WINDOW_NOTIFICATION_PENDING_OPTION" \
      >/dev/null 2>&1 || true
  fi

  tama_notify_export_context
  # In the environment as well as in argv, so that a backend which handles both
  # capabilities can read the group the same way in each.
  TAMA_GROUP="$TAMA_NOTIFY_GROUP"
  export TAMA_GROUP

  # A banner that would not go away is not worth a word out of an agent's hook, still
  # less a failed turn. The synchronous call is bounded by the watchdog; a backend
  # may hand work to the desktop only after that work is safely accepted.
  tama_backend_invoke dismiss "$TAMA_NOTIFY_GROUP" || true
}

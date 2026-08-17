# shellcheck shell=bash
#
# The notification pipeline: whether to deliver, what to say, what a click does, and
# which banner a dismissal is about.
#
# Sourced by lib/common.sh, so every command has it. The platform half is behind
# lib/backend.sh; nothing here knows what a desktop is.
#
# Everything in this file works over the window tama_window_read last read, because
# every question it answers is about that window — which is also what keeps the
# round trips down on a path that is already the most expensive one in the plugin.

# The group a window's banners share, as a tmux format. One banner per window is the
# whole grouping story: a newer one replaces the older one, so a chatty agent cannot
# bury the screen, and dismissing is a per-window act because the mark it goes with is.
#
# Configurable, and read in exactly one place — tama_notify_group below — because
# `notify` and `dismiss` naming the same banner is not a coincidence to be maintained
# in two places. The one thing that must never happen here is two expansions that
# agree today and drift later, which is why `notify` pays a second round trip for
# this rather than expanding it alongside the title.
TAMA_NOTIFY_GROUP_DEFAULT='tmux-window-#{window_id}'

# What a banner says, as a tmux format expanded against the pane that spoke.
#
# A real format, not a template language of the plugin's own: the user already knows
# this one, it can do conditionals, and it reaches everything tmux knows about the
# pane. So there is no "project" concept anywhere in the plugin — a project is
# `#{b:pane_current_path}`, and a user who means something else writes something else.
#
# The two things only the plugin knows are exposed as pane options for the format to
# reach: the agent's own name, and the label, which is whatever the user's own
# window-naming tooling says when they have configured one. The default mentions the
# label conditionally, so it costs nothing when there is no provider.
#
# The path is asked for twice because tmux cannot always answer. It reads a pane's
# directory from the process running in it, and that lookup intermittently fails on a
# pane that has been sitting idle for minutes — measured at 2 reads in 400 coming back
# empty on macOS, with no pattern to them. A banner titled `claude-code - ` is the
# result, once in a couple of hundred, which is exactly often enough to be seen and
# never often enough to be reproduced on purpose. So when the live answer is missing the
# format falls back to `@tama_pane_cwd`, the directory the pane was in when it last
# reported a state, which is a stored value and cannot flicker.
TAMA_NOTIFY_TITLE_DEFAULT='#{@tama_pane_agent} - #{?pane_current_path,#{b:pane_current_path},#{b:@tama_pane_cwd}}#{?@tama_pane_label, (#{@tama_pane_label}),}'

# Quotes <value> so that a shell reading it back sees exactly these bytes, in
# TAMA_QUOTED. Single quotes, which stop a shell acting on anything at all — a `$`, a
# backtick, a `#`, a space, a newline — with the one closing-quote dance for a value that
# contains a single quote of its own.
#
# It lives here, and not in lib/common.sh, because there is exactly one thing in this
# plugin that composes a command line out of values it did not choose — the click action
# below, which a backend hands to the desktop — and nothing else should acquire the habit.
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

# Whether banners are wanted at all. `off` is the heads-down switch: the icons and the
# window mark keep working, because they are inside tmux and cost the user nothing,
# and only the OS-level interruption stops.
tama_notify_enabled() {
  tama_opt_enabled tama_notifications on
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

# The title for <pane>, in TAMA_NOTIFY_TITLE. Expanded against the pane and not the
# window, because the pane is what knows the agent, the path and the label — the
# project name in the system this replaces came from the *hook process's* working
# directory, which is right until an agent is started from anywhere else.
# shellcheck disable=SC2034  # TAMA_NOTIFY_TITLE is read by the caller
tama_notify_title() { # <pane_id>
  local format
  format="$(tama_opt tama_title_format "$TAMA_NOTIFY_TITLE_DEFAULT")"
  TAMA_NOTIFY_TITLE="$(tmux_run display-message -p -t "$1" "$format" 2>/dev/null)" ||
    TAMA_NOTIFY_TITLE=''
}

# The user's own label for the window tama_window_read last read, in
# TAMA_NOTIFY_LABEL, or empty when there is no provider configured.
#
# The plugin never computes a label and has no opinion about naming schemes: this
# exists so that notifications can say what the user's own window-naming tooling
# already says. With `@tama_label_command` unset *nothing runs* — that is the whole
# of the zero-configuration promise, and it is why the default title mentions the
# label only conditionally.
#
# The provider is given the window id and nothing else, and its first line of output
# is the label. It runs synchronously inside an agent's hook with no timeout, for the
# same reason a backend does — bash 3.2 has none to offer — so a provider that blocks
# blocks the agent's turn. A provider that fails, says nothing, or answers with
# something a tmux option cannot hold is a window with no label.
# shellcheck disable=SC2034  # TAMA_NOTIFY_LABEL is read by the caller
tama_notify_label() {
  local command label
  TAMA_NOTIFY_LABEL=''
  command="$(tama_opt tama_label_command '')"
  [ -n "$command" ] || return 0

  # As arguments, never pasted into the program text: `"$1"` inside it, the window id
  # after it. A label provider is the user's own script and the window id is tmux's
  # own, but a command line built by substitution is a habit that only has to be
  # wrong once.
  label="$(sh -c "$command \"\$1\"" _ "$TAMA_WINDOW_ID" 2>/dev/null)" || label=''

  # One line. A provider that prints several has said one thing and then said more.
  label="${label%%$'\n'*}"
  # A control character would come back from a tmux option changed or escaped
  # depending on the version and the locale — see lib/pane.sh. Then the title would
  # be nonsense rather than the label the user meant, so there is no label.
  tama_pane_value_is_storable "$label" || label=''
  TAMA_NOTIFY_LABEL="$label"
}

# Whether the user is demonstrably already looking at the window tama_window_read
# last read — the `AND` of ADR-0004, and the only place suppression is decided.
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
# `bin/tama`, which reaches tmux through those two variables and nothing else.
#
# A click arrives long after the hook that raised the banner has exited, in a process
# with none of its environment: no `$TMUX`, no `$TAMA_TMUX`, and on macOS not even the
# login shell's `PATH`. So the invocation has to be baked into the command line, and
# it has to name the right server — a user running tmux on a socket of their own would
# otherwise have their clicks land on a server they are not looking at, or on none.
#
#   * an explicit `$TAMA_TMUX_ARGS` wins, because it is how the tests point the plugin
#     at their own server and how a user with an unusual setup would say so too
#   * otherwise the socket is taken from `$TMUX`, which names it exactly, and only if
#     it really is a socket — a value that is not one would make every click fail
#   * otherwise nothing, which is the default server, which is where a plugin loaded
#     by a plain `tmux` lives
#
# The binary is resolved to an absolute path while there is still a `PATH` to resolve
# it with.
tama_notify_tmux_command() {
  local path="$TAMA_TMUX" resolved socket arg args=''
  case "$path" in
    # Already a path. `command -v` on one is not an improvement.
    */*) ;;
    *)
      resolved="$(command -v "$path" 2>/dev/null)" || resolved=''
      [ -z "$resolved" ] || path="$resolved"
      ;;
  esac

  if [ -n "${TAMA_TMUX_ARGS:-}" ]; then
    args="$TAMA_TMUX_ARGS"
  else
    socket="${TMUX:-}"
    socket="${socket%%,*}"
    if [ -n "$socket" ] && [ -S "$socket" ]; then
      args="-S $socket"
    fi
  fi

  tama_shell_quote "$path"
  TAMA_NOTIFY_TMUX="$TAMA_QUOTED"
  TAMA_NOTIFY_TMUX_ENV="TAMA_TMUX=$TAMA_QUOTED"

  # For the invocation, one quoted word per argument. For the environment, the whole list
  # as one value, because that is what it is: `tmux_run` splits it into words itself, so
  # an argument with a space in it could not have survived there in the first place.
  if [ -n "$args" ]; then
    # Split into words, globbing off, exactly as tmux_run does.
    set -f
    # shellcheck disable=SC2086  # deliberate: "-L socket" is two arguments
    set -- $args
    set +f
    for arg in "$@"; do
      tama_shell_quote "$arg"
      TAMA_NOTIFY_TMUX="$TAMA_NOTIFY_TMUX $TAMA_QUOTED"
    done
  fi
  tama_shell_quote "$args"
  TAMA_NOTIFY_TMUX_ENV="$TAMA_NOTIFY_TMUX_ENV TAMA_TMUX_ARGS=$TAMA_QUOTED"
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

  # Fire and forget: a banner that would not go away is not worth a word out of an
  # agent's hook, still less a failed turn.
  tama_backend_invoke dismiss "$TAMA_NOTIFY_GROUP" || true
}

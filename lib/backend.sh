# shellcheck shell=bash
#
# Backend boundary for desktop-specific behavior. A backend directory may provide
# `notify`, `dismiss`, `focused`, and `focus` executables; missing capabilities are
# unsupported, not errors. They run synchronously inside hooks, so implementations
# must return promptly and communicate only through exit status.

# The bare name whose directory is inside the plugin, and the one `auto` resolves to
# when nothing better will work here.
TAMA_BACKEND_NONE='none'

# The platform backend for Darwin, and the binary it is nothing without.
TAMA_BACKEND_MACOS='macos'
TAMA_MACOS_NOTIFIER_NAME='terminal-notifier'

# Where a Homebrew puts a binary, for the two prefixes Homebrew itself uses: Apple
# silicon first, then Intel. Searched only after `PATH`, because a user who has put a
# notifier on their `PATH` has already said which one they mean.
#
# This list exists because `PATH` is not enough on the path that matters most: a
# notification is raised from an agent's hook, which inherits the agent's environment,
# and a click arrives in a process the desktop started with barely any environment at
# all. Neither is a login shell, so neither reliably has Homebrew's bin on `PATH`.
TAMA_MACOS_NOTIFIER_DIRS='/opt/homebrew/bin /usr/local/bin'

# The platform backend for a freedesktop desktop, and the binary it is nothing without.
# `notify-send` is libnotify's own command-line client and is what every Linux desktop
# has: it speaks the org.freedesktop.Notifications D-Bus interface that GNOME, KDE,
# dunst, mako and swaync all implement.
TAMA_BACKEND_LIBNOTIFY='libnotify'
TAMA_LIBNOTIFY_SEND_NAME='notify-send'

# Where a package manager puts `notify-send`. `/usr/bin` is where every distribution's
# libnotify package lands and is on every sane `PATH` already; it is searched anyway for
# the same reason the Homebrew prefixes are — a hook inherits an agent's environment,
# not a login shell's, and a `PATH` somebody trimmed is not a reason to go silent.
TAMA_LIBNOTIFY_SEND_DIRS='/usr/bin /usr/local/bin'

# The status for "this capability does not exist here". 127 is what a shell reports
# for a command it could not find, which is exactly what happened.
TAMA_BACKEND_UNSUPPORTED=127

# The directory the backend's capabilities live in, in TAMA_BACKEND_DIR. Empty when
# the user has turned backends off or named one that cannot be a directory.
#
# A bare name is looked up inside the plugin; an absolute path is taken as it is. A
# name with a slash or a leading dot in it is neither — it would reach out of
# `backends/` — and is refused the way bin/tama refuses a subcommand of that shape.
# The directory is not checked for existence: a name that resolves nowhere has no
# capabilities, which is the same thing to every caller as a backend that ships none.
# shellcheck disable=SC2034  # TAMA_BACKEND_DIR is read by the caller
tama_backend_dir() {
  local name
  name="$(tama_opt tama_backend auto)"
  TAMA_BACKEND_DIR=''

  case "$name" in
    # Deliberately configurable to nothing: `set -g @tama_backend ''` is a way to
    # turn every capability off without touching the four override options.
    '') return 0 ;;
    auto) name="$(tama_backend_auto)" ;;
  esac

  case "$name" in
    /*) TAMA_BACKEND_DIR="$name" ;;
    */* | .*) return 0 ;;
    *) TAMA_BACKEND_DIR="$TAMA_PLUGIN_DIR/backends/$name" ;;
  esac
  return 0
}

# Resolve only backends whose dependency exists. Darwin never falls through to
# libnotify because Homebrew may install `notify-send` without a notification daemon.
tama_backend_auto() {
  if tama_backend_is_darwin; then
    if tama_macos_notifier; then
      printf '%s' "$TAMA_BACKEND_MACOS"
      return 0
    fi
    printf '%s' "$TAMA_BACKEND_NONE"
    return 0
  fi

  if tama_libnotify_send; then
    printf '%s' "$TAMA_BACKEND_LIBNOTIFY"
    return 0
  fi
  printf '%s' "$TAMA_BACKEND_NONE"
}

# Whether this is a Mac. `$OSTYPE` is bash's own answer and costs no process; every
# script in this plugin is bash, so it is always there. `uname` is the fallback for a
# shell that somehow is not — cheaper to keep than to reason about.
tama_backend_is_darwin() {
  case "${OSTYPE:-}" in
    darwin*) return 0 ;;
    '') [ "$(uname -s 2>/dev/null)" = 'Darwin' ] ;;
    *) return 1 ;;
  esac
}

# Resolve an option override, then PATH, then platform directories. Core and backend
# share this result so `auto` cannot select a dependency the backend cannot find.
# shellcheck disable=SC2034  # TAMA_BINARY is read by the caller
tama_resolve_binary() { # <option> <name> <dirs>
  local name resolved dir dirs="$3"
  TAMA_BINARY=''

  name="$(tama_opt "$1" '')"
  case "$name" in
    '') name="$2" ;;
    # A path the user gave is used as it is, or not at all: searching for the basename
    # of a path somebody spelled out would run a different program than they named.
    */*)
      if [ ! -f "$name" ] || [ ! -x "$name" ]; then
        return 1
      fi
      TAMA_BINARY="$name"
      return 0
      ;;
  esac

  resolved="$(command -v "$name" 2>/dev/null)" || resolved=''
  if [ -n "$resolved" ] && [ -x "$resolved" ]; then
    TAMA_BINARY="$resolved"
    return 0
  fi

  # A fixed list of literal paths, so the splitting has nothing to be surprised by.
  # shellcheck disable=SC2086  # deliberate: one word per directory
  for dir in $dirs; do
    if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
      TAMA_BINARY="$dir/$name"
      return 0
    fi
  done
  return 1
}

# The `terminal-notifier` to use, in TAMA_MACOS_NOTIFIER; non-zero when there is none,
# which is what stops `auto` picking the macOS backend on a Mac without one.
# `@tama_terminal_notifier` is a name or an absolute path. backends/macos calls this.
# shellcheck disable=SC2034  # TAMA_MACOS_NOTIFIER is read by the caller
tama_macos_notifier() {
  TAMA_MACOS_NOTIFIER=''
  tama_resolve_binary tama_terminal_notifier "$TAMA_MACOS_NOTIFIER_NAME" \
    "$TAMA_MACOS_NOTIFIER_DIRS" || return 1
  TAMA_MACOS_NOTIFIER="$TAMA_BINARY"
}

# The `notify-send` to use, in TAMA_LIBNOTIFY_SEND; non-zero when there is none, which
# is what stops `auto` picking the libnotify backend on a machine — a CI runner, a
# headless server, a container — with no way to draw a banner. `@tama_notify_send` is a
# name or an absolute path. backends/libnotify calls this.
#
# Note for anyone reading the options as a list: `@tama_notify_send` names the *binary*
# this backend runs, while `@tama_notify_command` replaces the notify *capability*
# wholesale, backend and all. They are one letter apart in the wrong way, and the second
# one is the extension point — a click action, a different notifier, a log file.
# shellcheck disable=SC2034  # TAMA_LIBNOTIFY_SEND is read by the caller
tama_libnotify_send() {
  TAMA_LIBNOTIFY_SEND=''
  tama_resolve_binary tama_notify_send "$TAMA_LIBNOTIFY_SEND_NAME" \
    "$TAMA_LIBNOTIFY_SEND_DIRS" || return 1
  TAMA_LIBNOTIFY_SEND="$TAMA_BINARY"
}

# Runs <capability>, with the caller's arguments, and returns its exit status —
# or TAMA_BACKEND_UNSUPPORTED when there is nothing to run. Output is discarded;
# see the rules above.
#
# `@tama_<capability>_command` replaces one capability wholesale, which is the
# extension point for a user whose terminal or desktop needs something nobody
# anticipated: it is a command *line*, so it can carry its own flags, and the
# arguments are appended as arguments rather than pasted into it — a notification
# message is arbitrary text and must never be read as shell.
tama_backend_invoke() { # <capability> [args…]
  local capability="$1" override target status outcome reason='' effect_id started_at
  shift

  effect_id="e-$$-${RANDOM:-0}"
  started_at=''
  if [ -n "${TAMA_LOG_FILE:-}" ]; then
    started_at="$(tama_log_clock 2>/dev/null || true)"
  fi
  tama_log_effect effect.started "${capability}_backend" "$effect_id" ''

  override="$(tama_opt "tama_${capability}_command" '')"
  if [ -n "$override" ]; then
    # `"$@"` inside the sh program text, so the values arrive as arguments of the
    # user's command. The `_` is $0 for that shell.
    sh -c "$override \"\$@\"" _ "$@" >/dev/null 2>&1
    status=$?
    outcome=failed
    [ "$status" -eq 0 ] && outcome=applied
    tama_log_effect effect.completed "${capability}_backend" "$effect_id" "$outcome" "$started_at"
    return "$status"
  fi

  tama_backend_dir
  if [ -z "$TAMA_BACKEND_DIR" ]; then
    tama_log_effect effect.completed "${capability}_backend" "$effect_id" skipped "$started_at" capability_unsupported
    return "$TAMA_BACKEND_UNSUPPORTED"
  fi

  target="$TAMA_BACKEND_DIR/$capability"
  # -x alone is true of a directory, and running one is a diagnostic rather than a
  # status. Unsupported covers both.
  if [ ! -f "$target" ] || [ ! -x "$target" ]; then
    tama_log_effect effect.completed "${capability}_backend" "$effect_id" skipped "$started_at" capability_unsupported
    return "$TAMA_BACKEND_UNSUPPORTED"
  fi

  "$target" "$@" >/dev/null 2>&1
  status=$?
  outcome=failed
  [ "$status" -eq 0 ] && outcome=applied
  tama_log_effect effect.completed "${capability}_backend" "$effect_id" "$outcome" "$started_at"
  return "$status"
}

# The terminal a backend is talking about, for the two capabilities that have to name
# an application to the desktop. Neither the plugin nor tmux can tell which terminal
# emulator a session is being displayed in, so this is configuration with a default
# that is a guess, and the environment gets a say because a dotfiles setup that
# already knows its terminal should not have to say so twice.
tama_backend_export_terminal() {
  TAMA_TERMINAL_APP="$(tama_opt tama_terminal_app "${TERMINAL_APP_NAME:-ghostty}")"
  TAMA_TERMINAL_BUNDLE_ID="$(tama_opt tama_terminal_bundle_id \
    "${TERMINAL_BUNDLE_ID:-com.mitchellh.ghostty}")"
  export TAMA_TERMINAL_APP TAMA_TERMINAL_BUNDLE_ID
}

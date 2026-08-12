# shellcheck shell=bash
#
# The platform-specific half of notifications, kept behind one door.
#
# A backend is a *directory* holding up to four optional executables, one per
# capability. That is the whole contract, and it is a directory rather than a set of
# options so that a third-party backend needs no fork: point `@tama_backend` at an
# absolute path and it is a backend.
#
# Sourced by lib/common.sh, so every command has it.
#
# | Capability | argv            | Contract                                        |
# | ---------- | --------------- | ----------------------------------------------- |
# | `notify`   | <title> <msg>   | Raise a banner. Exit status ignored.            |
# | `dismiss`  | <group>         | Remove the banners in that group. Ignored.      |
# | `focused`  | —               | Exit 0 = the user is looking at TAMA_WINDOW_ID. |
# | `focus`    | <session>       | Bring that session's terminal forward. Ignored. |
#
# Context arrives in the environment rather than in argv so it can grow without
# breaking a backend that was written against an earlier version. Every capability
# gets TAMA_BIN, TAMA_PLUGIN_DIR, TAMA_TERMINAL_APP and TAMA_TERMINAL_BUNDLE_ID;
# lib/notify.sh sets the rest per capability and documents them there.
#
# Three rules a backend author has to know, and every backend in this repo obeys:
#
#   1. **Return promptly.** These run inside an agent's hook, synchronously, on the
#      turn the user is waiting for. There is no timeout — bash 3.2 has no portable
#      one — so a capability that blocks blocks the agent. A backend that has to wait
#      on something (a notifier that draws the banner itself, an `osascript` that may
#      prompt) must background it and return.
#   2. **Say nothing.** Every invocation's stdout and stderr are discarded here, so a
#      chatty notifier cannot land in a transcript. Do not rely on being heard; a
#      capability communicates through its exit status and nothing else.
#   3. **Exit 0 unless you mean it.** Only `focused` is asked a question. For the
#      other three the status is dropped: a banner that did not appear must never
#      fail an agent's turn.
#
# A missing capability is not an error, it is "unsupported", and every caller
# degrades: no `focused` means nothing is ever suppressed, no `dismiss` means a banner
# stays until the desktop retires it, no `notify` means the whole feature is off. That
# is what makes `backends/none` a directory with two files in it and `backends/libnotify`
# one with a single file, and what lets a backend ship the capabilities its platform can
# actually do. A capability a platform cannot honestly answer is *absent*, never present
# and empty — backends/README.md argues each absence where it can be read next to the
# directory it is about.

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

# Which backend `auto` means on this machine.
#
# A Mac with `terminal-notifier` picks `macos`; anything else with `notify-send` picks
# `libnotify`; everything left picks the no-op one. This is the only place that resolves
# a platform to a backend, and a third platform belongs here rather than anywhere else.
#
# It resolves only to a backend whose dependency is *actually installed*, which is the
# difference between a plugin that degrades quietly on a headless box and one that
# fails on every notification an agent reports. A Mac with no `terminal-notifier`
# therefore lands on `none` and `doctor` is what explains why — never on `macos`,
# whose every capability would be a process started to fail.
#
# **A Mac is never a `libnotify` machine**, which is why the Darwin branch returns
# rather than falling through: `notify-send` can be installed on a Mac — Homebrew's
# glib carries one — and there is no notification daemon there for it to talk to, so
# picking it would be a banner that never appears with nothing anywhere to say why.
# Anything that is *not* a Mac is asked about `notify-send` and nothing else, so a BSD
# or a WSL with a freedesktop daemon gets its banners without this function having to
# hold a list of which operating systems have one.
#
# Kept cheap on purpose: this runs on every capability invocation, so it costs a `case`
# on `$OSTYPE` — bash's own answer, no `uname` process — and at most one `command -v`.
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

# The binary a platform backend depends on, in TAMA_BINARY; non-zero when this machine
# has none, which is what stops `auto` picking a backend that could only fail.
#
#   tama_resolve_binary <option> <default name> <directories to search>
#
# Resolved rather than hardcoded — the system this replaces had
# `/opt/homebrew/bin/terminal-notifier` written into two scripts, which is wrong on an
# Intel Mac, wrong on a MacPorts install and wrong for anyone who keeps their own build.
# The option overrides the name or gives an absolute path, then `PATH`, then the
# directories the caller named.
#
# Read here, in the core, rather than in the backend that runs it, because `auto` and
# the backend must never disagree about which binary the backend is going to run:
# `auto` promising a notifier the backend then cannot find would be silence with no
# explanation anywhere. Each backend calls its own wrapper below.
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
  local capability="$1" override target
  shift

  override="$(tama_opt "tama_${capability}_command" '')"
  if [ -n "$override" ]; then
    # `"$@"` inside the sh program text, so the values arrive as arguments of the
    # user's command. The `_` is $0 for that shell.
    sh -c "$override \"\$@\"" _ "$@" >/dev/null 2>&1
    return
  fi

  tama_backend_dir
  [ -n "$TAMA_BACKEND_DIR" ] || return "$TAMA_BACKEND_UNSUPPORTED"

  target="$TAMA_BACKEND_DIR/$capability"
  # -x alone is true of a directory, and running one is a diagnostic rather than a
  # status. Unsupported covers both.
  if [ ! -f "$target" ] || [ ! -x "$target" ]; then
    return "$TAMA_BACKEND_UNSUPPORTED"
  fi

  "$target" "$@" >/dev/null 2>&1
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

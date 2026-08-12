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
# is what makes `backends/none` a directory with two files in it and what lets a
# backend ship the capabilities its platform can actually do.

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
# Darwin with a notifier installed picks `macos`; anything else falls through to the
# no-op one. `libnotify` joins the list when it exists and this stays the only place
# that changes — as another `<platform> && <its dependency is installed>` pair, and
# checked as cheaply as this one is, because this function runs on every capability
# invocation: a `case` on `$OSTYPE` and a `command -v`, no `uname` if it can be helped.
#
# It resolves only to a backend whose dependency is *actually installed*, which is the
# difference between a plugin that degrades quietly on a headless box and one that
# fails on every notification an agent reports. A Mac with no `terminal-notifier`
# therefore lands on `none` and `doctor` is what explains why — never on `macos`,
# whose every capability would be a process started to fail.
tama_backend_auto() {
  if tama_backend_is_darwin && tama_macos_notifier; then
    printf '%s' "$TAMA_BACKEND_MACOS"
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

# The `terminal-notifier` to use, in TAMA_MACOS_NOTIFIER; non-zero when there is none,
# which is what stops `auto` picking the macOS backend on a Mac without one.
#
# Resolved rather than hardcoded — the system this replaces had
# `/opt/homebrew/bin/terminal-notifier` written into two scripts, which is wrong on an
# Intel Mac, wrong on a MacPorts install and wrong for anyone who keeps their own
# build. `@tama_terminal_notifier` overrides the name or gives an absolute path, then
# `PATH`, then the Homebrew prefixes.
#
# Read here, in the core, rather than in backends/macos, because `auto` and the backend
# must never disagree about which binary the backend is going to run: `auto` promising a
# notifier the backend then cannot find would be silence with no explanation anywhere.
# backends/macos calls this function.
# shellcheck disable=SC2034  # TAMA_MACOS_NOTIFIER is read by the caller
tama_macos_notifier() {
  local name resolved dir
  TAMA_MACOS_NOTIFIER=''

  name="$(tama_opt tama_terminal_notifier '')"
  case "$name" in
    '') name="$TAMA_MACOS_NOTIFIER_NAME" ;;
    # A path the user gave is used as it is, or not at all: searching for the basename
    # of a path somebody spelled out would run a different program than they named.
    */*)
      if [ ! -f "$name" ] || [ ! -x "$name" ]; then
        return 1
      fi
      TAMA_MACOS_NOTIFIER="$name"
      return 0
      ;;
  esac

  resolved="$(command -v "$name" 2>/dev/null)" || resolved=''
  if [ -n "$resolved" ] && [ -x "$resolved" ]; then
    TAMA_MACOS_NOTIFIER="$resolved"
    return 0
  fi

  # A fixed list of literal paths, so the splitting has nothing to be surprised by.
  # shellcheck disable=SC2086  # deliberate: one word per directory
  for dir in $TAMA_MACOS_NOTIFIER_DIRS; do
    if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
      TAMA_MACOS_NOTIFIER="$dir/$name"
      return 0
    fi
  done
  return 1
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

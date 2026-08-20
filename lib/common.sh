# shellcheck shell=bash
#
# Shared runtime for CLI commands. Usage errors are loud; operational failures
# remain silent so hooks cannot fail an agent turn.

set -o nounset

# Every script reaches tmux through this indirection so tests can point it at
# their own server. TAMA_TMUX is the path to the binary — it may contain spaces,
# so it is never split — and TAMA_TMUX_ARGS holds leading arguments, which may
# not.
TAMA_TMUX="${TAMA_TMUX:-tmux}"

# `-u` says this client speaks UTF-8. Without it tmux decides from the ambient
# locale, and a server whose locale is C — a CI runner, a systemd unit, a cron job —
# hands back `_` for every byte of every multibyte character it prints. That would
# turn an agent name or a path with an accent in it into a value that never equals
# itself, so the pane would be rewritten on every tool call.
tmux_run() {
  if [ -n "${TAMA_TMUX_ARGS:-}" ]; then
    # Split into words, but with globbing off: a socket name is not a pattern.
    set -f
    # shellcheck disable=SC2086  # deliberate: "-L socket" is two arguments
    set -- $TAMA_TMUX_ARGS "$@"
    set +f
  fi
  "$TAMA_TMUX" -u "$@"
}

# Reads newline-separated formats in one tmux call. Callers append a sentinel and
# verify line count because command substitution removes trailing empty lines.
tama_fields_read() { # <target> <fields>
  local target="$1" fields="$2" field
  set --
  while IFS= read -r field; do
    [ "$#" -eq 0 ] || set -- "$@" ';'
    set -- "$@" display-message -p -t "$target" "$field"
  done <<EOF
$fields
EOF
  tmux_run "$@" 2>/dev/null
}

# Usage error: loud, on stderr, exit 2. The hint carries an absolute path
# because nothing is installed onto PATH — `tama` alone is not runnable.
die_usage() {
  printf 'tama: %s\n' "$1" >&2
  printf "Try '%s --help'.\\n" "${TAMA_BIN:-tama}" >&2
  exit 2
}

# Parses the optional target shared by the window commands. A direct target wins
# over the pane that supplied it, which in turn wins over the hook's own pane.
# The result is in TAMA_WINDOW_TARGET.
tama_optional_window_target() { # <command> [--pane <pane_id>] [<window_target>]
  local command="$1" target='' pane='' positional=0
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pane)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          die_usage '--pane needs a pane id'
        fi
        pane="$2"
        shift 2
        ;;
      -*) die_usage "unknown option: $1" ;;
      *)
        positional=$((positional + 1))
        [ "$positional" -eq 1 ] || die_usage "$command takes at most one target, got: $1"
        [ -n "$1" ] || die_usage "$command needs a window target"
        target="$1"
        shift
        ;;
    esac
  done

  # shellcheck disable=SC2034  # read by the caller after parsing
  TAMA_WINDOW_TARGET="${target:-${pane:-${TMUX_PANE:-}}}"
}

# Outside tmux there is nothing to act on, and hooks are configured once for
# both contexts, so every tmux-acting command is a quiet no-op.
require_tmux() {
  [ -n "${TMUX:-}" ] || exit 0
}

# Shared libraries travel together so commands have one runtime surface.
_tama_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_tama_lib_dir" = "${BASH_SOURCE[0]}" ] && _tama_lib_dir='.'

# A failed `.` does not stop a script, and carrying on would leave the failure
# policy itself undefined.
_tama_require_lib() {
  [ -r "$1" ] && return 0
  printf 'tama: no %s next to %s; this plugin directory is incomplete\n' \
    "${1##*/}" "${BASH_SOURCE[0]}" >&2
  exit 1
}

_tama_require_lib "$_tama_lib_dir/options.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=options.sh
. "$_tama_lib_dir/options.sh"

_tama_require_lib "$_tama_lib_dir/inventory.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=inventory.sh
. "$_tama_lib_dir/inventory.sh"

_tama_require_lib "$_tama_lib_dir/state-icons.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=state-icons.sh
. "$_tama_lib_dir/state-icons.sh"

_tama_require_lib "$_tama_lib_dir/pane.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=pane.sh
. "$_tama_lib_dir/pane.sh"

_tama_require_lib "$_tama_lib_dir/window.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=window.sh
. "$_tama_lib_dir/window.sh"

_tama_require_lib "$_tama_lib_dir/stale.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=stale.sh
. "$_tama_lib_dir/stale.sh"

_tama_require_lib "$_tama_lib_dir/backend.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=backend.sh
. "$_tama_lib_dir/backend.sh"

_tama_require_lib "$_tama_lib_dir/notify.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=notify.sh
. "$_tama_lib_dir/notify.sh"

unset _tama_lib_dir
unset -f _tama_require_lib

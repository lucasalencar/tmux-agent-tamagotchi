# shellcheck shell=bash
#
# Shared helpers, sourced by bin/tama and by every script under libexec/.
# Sourcing this file turns on `nounset` for the caller, deliberately: every
# script in the plugin runs under it.
#
# Failure policy (see the CLI contract in bin/tama): usage errors exit 2 with a
# message on stderr, because a wrong hook is the user's fault and must be visible
# while they are editing it. Everything else exits 0 silently — a notification
# that did not appear must never fail an agent's turn.

set -o nounset

# Every script reaches tmux through this indirection so tests can point it at
# their own server. TAMA_TMUX is the path to the binary — it may contain spaces,
# so it is never split — and TAMA_TMUX_ARGS holds leading arguments, which may
# not.
TAMA_TMUX="${TAMA_TMUX:-tmux}"

# tmux, wherever it is. Never quote-mangles the caller's arguments.
#
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

# Reads several tmux formats about one target in a single tmux invocation, one
# value per line of output. The shape every record in this plugin is read in, and
# the reason it is here rather than copied: the batching is where the traps are.
#
# One `display-message -p` per field, joined by tmux's own `;`, so each value
# arrives on a line of its own and nothing has to separate them. A separator was
# the obvious thing and is not available: tmux prints to a client through an
# escaper, so a byte like a unit separator arrives as the four characters `\037`
# on some versions and locales and intact on others, collapsing every field into
# one. A newline cannot be smuggled either; it arrives as `_`.
#
# The number of lines is therefore the integrity check, which is why every caller
# ends its field list with a sentinel: command substitution strips trailing
# newlines, so a last field that is legitimately empty would be indistinguishable
# from a line that never arrived.
#
# <fields> is newline separated. Prints the raw output; non-zero when tmux could
# not answer at all, which every caller treats as an empty record.
tama_fields_read() { # <target> <fields>
  local target="$1" fields="$2" field
  # Built here rather than kept as a constant because the target belongs in every
  # one of the commands.
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

# The configuration reader needs tmux_run, and everything that reads tmux reads
# configuration; the state model needs both, and every command that does anything
# at all acts on a pane — or on the window around it, or on every pane the server
# has when the sweep goes looking. So they travel together.
# Stripping the last path component leaves the name untouched when there is none,
# so a caller that sourced us by a bare relative name still finds them.
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

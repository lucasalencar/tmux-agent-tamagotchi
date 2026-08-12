#!/usr/bin/env bash
#
# TPM entrypoint. Runs on every `tmux source-file`, so everything it does must
# be idempotent, and it must resolve its own location rather than assume one:
# a TPM clone, a git submodule and a symlinked worktree are all valid homes.
# (`cd -P` resolves symlinked directories, which is what all three amount to;
# a symlink pointing at this file itself is not a documented install.)
#
# Below the minimum tmux version it warns and wires nothing at all — a partial
# install produces symptoms that are far harder to read than a message.

set -o nounset

# The directory this file lives in, symlinked directories resolved. Same name as
# bin/tama exports, so anything under lib/ has one name to read.
case "${BASH_SOURCE[0]}" in
  */*) TAMA_PLUGIN_DIR="$(cd -P "${BASH_SOURCE[0]%/*}" && pwd)" ;;
  *) TAMA_PLUGIN_DIR="$PWD" ;;
esac
export TAMA_PLUGIN_DIR

# A failed `.` does not stop a script, and carrying on from here produces a
# cascade of bash diagnostics instead of one sentence naming the real problem.
# bin/tama is checked for the same reason one step removed: it is what gets
# published, and a path that cannot be run would fail inside an agent's hooks
# on every event, where the recipe can only see whether the option is empty.
if [ ! -r "$TAMA_PLUGIN_DIR/lib/common.sh" ] ||
  [ ! -r "$TAMA_PLUGIN_DIR/lib/version.sh" ] ||
  [ ! -x "$TAMA_PLUGIN_DIR/bin/tama" ]; then
  printf 'tamagotchi: %s is not a complete plugin directory; nothing was loaded\n' \
    "$TAMA_PLUGIN_DIR" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
. "$TAMA_PLUGIN_DIR/lib/common.sh"
# shellcheck source=lib/version.sh
. "$TAMA_PLUGIN_DIR/lib/version.sh"

main() {
  local version warning
  version="$(tama_tmux_version)"
  if ! tama_version_at_least "$version" "$TAMA_MIN_TMUX_VERSION"; then
    # display-message expands its argument as a tmux format, and a format can
    # run a command, so nothing derived from the outside world keeps its `#`.
    warning="tamagotchi: tmux ${version//\#/} is too old"
    warning="$warning (needs $TAMA_MIN_TMUX_VERSION); nothing was loaded"
    # Both, because neither reaches everyone: display-message is dropped when no
    # client is attached, and stderr is dropped when there is no terminal.
    printf '%s\n' "$warning" >&2
    tmux_run display-message "$warning"
    return 0
  fi

  # The only way anything finds this plugin: hook recipes and the user's status
  # line ask tmux where it lives. Nothing is written outside this directory and
  # nothing is installed onto PATH (ADR-0003).
  #
  # `set -g` is a global user option, which is how every tmux plugin is
  # configured and what both `show -gv` and `#{@tama_bin}` read. Whoever
  # interpolates this path into a `#()` format later owns quoting it and
  # escaping what tmux would otherwise read: `#` starts a format, and `%` is
  # consumed by strftime.
  tmux_run set -g @tama_bin "$TAMA_PLUGIN_DIR/bin/tama"
  tmux_run set -g @tama_bin_dir "$TAMA_PLUGIN_DIR/bin"

  # A ready-made format for the user to interpolate into their own status line,
  # wherever they want the icons — the plugin never rewrites a status line
  # somebody spent an afternoon on. `#{E:@tama_icons}` expands this option's own
  # format, which runs the command once for the window being drawn.
  #
  # The path is *referenced*, never interpolated, and that is what makes it
  # correct for every path a clone can live at. tmux finds the `)` that ends a
  # `#()` job before it expands anything inside, so a directory whose name
  # contains a parenthesis — `~/Dropbox (Personal)`, say — would truncate the
  # command and spill the rest of the path into every window's name. There is no
  # escape for `)` in a job; not putting it there is the only fix. `#{q:}` then
  # quotes the value for the shell that runs the job, which it has done with the
  # same byte-for-byte escape list since well before the tmux this plugin
  # requires, and the value of an option is not expanded again, so a `#` or a `%`
  # in the path is inert.
  #
  # `#{q:}` escapes what a shell would act on, but not a newline or a tab: a path
  # holding either would turn one command into two, and the second would run once
  # per window per status interval. Nothing can quote that, so a clone living at
  # such a path gets everything except the icons, and is told why.
  case "$TAMA_PLUGIN_DIR" in
    *[$'\n\t']*)
      warning='tamagotchi: this path has a newline or a tab in it, which a status'
      warning="$warning line cannot express; the icons are off"
      printf '%s\n' "$warning" >&2
      tmux_run display-message "$warning"
      # Unset rather than left alone: a value from an earlier load of a different
      # clone would otherwise keep running that clone, once per window per status
      # interval, while this message says the icons are off.
      tmux_run set -guq @tama_icons
      ;;
    *) tmux_run set -g @tama_icons '#(#{q:@tama_bin} icons #{window_id})' ;;
  esac

  # The flag, as a second format the user interpolates wherever they want it. Unlike
  # the icons this is not a `#()` job and needs none: the answer is already in a
  # window option, so tmux can draw it without running anything, once per window per
  # redraw rather than once per status interval.
  #
  # `#{E:@tama_flag_text}` expands the text as a format in turn, so a user can put
  # `#[fg=red]` in it. The option is referenced, never interpolated, for the same
  # reason the icon path references `@tama_bin`.
  tmux_run set -g @tama_flag '#{?@tama_window_flag,#{E:@tama_flag_text},}'

  # The flag text has to exist as an option, because a format cannot carry a default:
  # `#{E:@tama_flag_text}` on an option nobody set expands to nothing, and the flag
  # would be raised and draw as empty. So it is seeded here — and only when it has
  # never been set, which is what keeps `set -g @tama_flag_text ''` meaning "no text"
  # rather than being handed the default back on the next reload. Same distinction
  # lib/options.sh draws for every other option; this is the one that cannot be drawn
  # at read time, since tmux is doing the reading.
  if ! tmux_run show -gv @tama_flag_text >/dev/null 2>&1; then
    tmux_run set -g @tama_flag_text ' *'
  fi

  wire_hooks
  return 0
}

# The one hook the flag needs: the user selecting a window is what clears its mark,
# and nothing else does. Appended, never assigned, so a user's own
# `after-select-window` lines keep working — and skipped when it is already there,
# because this file runs again on every `tmux source-file` and `set-hook -ga` would
# otherwise stack another copy on each reload.
#
# The recipe names the plugin through `@tama_bin` instead of carrying its path, which
# `run-shell` expands when the hook fires. That is what makes the string a constant:
# the check below can compare it exactly, a user who moves their clone does not need
# to rewire anything, and there is no stale absolute path left in a hook pointing at
# a directory that has gone.
#
# `#{window_id}` is expanded the same way, against the window the hook fired for, and
# it has to be: tmux sets $TMUX_PANE in a hook's `run-shell` to a pane that does not
# exist, so a command left to find its own target from the environment would quietly
# clear nothing. Interpolated bare, because a window id is `@` and digits — there is
# nothing in it for a shell to act on.
#
# `@tama_manage_hooks off` leaves tmux's hooks alone entirely, for users who keep
# their configuration under their own control and would rather call `tama on-select`
# from a hook they wrote themselves.
TAMA_ON_SELECT_RECIPE='run-shell -b '"'"'#{q:@tama_bin} on-select --window #{window_id}'"'"''

wire_hooks() {
  # The option name carries its own `tama_`: tama_opt prepends the `@` and nothing
  # else, so a name without the prefix reads an option nobody sets and silently
  # lands on the default — which for this one would mean wiring hooks the user
  # asked it not to touch.
  [ "$(tama_opt tama_manage_hooks on)" = 'on' ] || return 0

  # tmux prints a hook array back requoted — single quotes come out double — so this
  # matches the part of the recipe that no requoting touches rather than the whole
  # line. Matching the command and the option name together is specific enough that
  # no other hook could collide with it.
  if tmux_run show-options -g after-select-window 2>/dev/null |
    grep -qF -- '#{q:@tama_bin} on-select'; then
    return 0
  fi

  tmux_run set-hook -ga after-select-window "$TAMA_ON_SELECT_RECIPE" >/dev/null 2>&1 ||
    true
  # A failed write is not worth failing a config reload over.
  return 0
}

main "$@"

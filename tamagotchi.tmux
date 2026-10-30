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
  [ ! -r "$TAMA_PLUGIN_DIR/lib/hooks.sh" ] ||
  [ ! -x "$TAMA_PLUGIN_DIR/bin/tama" ]; then
  printf 'tamagotchi: %s is not a complete plugin directory; nothing was loaded\n' \
    "$TAMA_PLUGIN_DIR" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
. "$TAMA_PLUGIN_DIR/lib/common.sh"
# shellcheck source=lib/version.sh
. "$TAMA_PLUGIN_DIR/lib/version.sh"
# The hooks below, shared with libexec/doctor so that it checks for what this wires.
# shellcheck source=lib/hooks.sh
. "$TAMA_PLUGIN_DIR/lib/hooks.sh"

if ! tama_tmux_server_resolve; then
  printf 'tamagotchi: not running inside tmux; nothing was loaded\n' >&2
  exit 1
fi

main() {
  local version warning choose_tree_format
  local wire_marker wire_reads wire_line
  local wire_have_priority_icon wire_have_flag_text wire_seen_marker
  local wire_sets
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
  #
  # All of the option writes below go out as one chained tmux call at the end
  # (see the single tmux_run past the seeds): one round-trip instead of a
  # dozen, which is what makes config reloads — and test setups, which load
  # the plugin per test — fast. Values travel as separate arguments, never
  # through a shell, so spaces and quotes in them are inert.
  wire_sets=(set -g @tama_bin "$TAMA_PLUGIN_DIR/bin/tama"
    ';' set -g @tama_bin_dir "$TAMA_PLUGIN_DIR/bin")

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
      wire_sets+=(';' set -guq @tama_icons ';' set -guq @tama_status_summary)
      ;;
    *)
      wire_sets+=(';' set -g @tama_icons '#(#{q:@tama_bin} icons #{window_id})'
        ';' set -g @tama_status_summary '#(#{q:@tama_bin} summary #{q:session_id})')
      ;;
  esac

  # The flag, as a second format the user interpolates wherever they want it. Unlike
  # the icons this is not a `#()` job and needs none: the answer is already in a
  # window option, so tmux can draw it without running anything, once per window per
  # redraw rather than once per status interval.
  #
  # `#{E:@tama_flag_text}` expands the text as a format in turn, so a user can put
  # `#[fg=red]` in it. The option is referenced, never interpolated, for the same
  # reason the icon path references `@tama_bin`.
  wire_sets+=(';' set -g @tama_flag '#{?@tama_window_flag,#{E:@tama_flag_text},}')

  # Seed-aware reads for the two options seeded below, batched into one
  # round-trip; see the comment where wire_reads is parsed for why `show -gv`
  # cannot be used here.
  wire_marker="__tama_wire_$$_${RANDOM}_${RANDOM}__"
  wire_reads="$(tmux_run show -gqv @tama_priority_icon ';' display-message -p "$wire_marker" ';' show -gqv @tama_flag_text ';' display-message -p "$wire_marker" 2>/dev/null)"
  wire_have_priority_icon=0 wire_have_flag_text=0 wire_seen_marker=0
  while IFS= read -r wire_line; do
    if [ "$wire_line" = "$wire_marker" ]; then
      wire_seen_marker=$((wire_seen_marker + 1))
    elif [ "$wire_seen_marker" -eq 0 ]; then
      wire_have_priority_icon=1
    else
      wire_have_flag_text=1
    fi
  done <<<"$wire_reads"

  # Priority is a classification separate from the attention flag. Its default is
  # itself a format so changing the icon preset is visible on the next redraw.
  # Seed only when absent: an explicitly empty icon is how a user hides it.
  if [ "$wire_have_priority_icon" -eq 0 ]; then
    wire_sets+=(';' set -g @tama_priority_icon \
      '#{?#{==:#{@tama_icon_set},pets}, ⭐,#{?#{==:#{@tama_icon_set},ascii}, *, ★}}')
  fi
  wire_sets+=(';' set -g @tama_priority \
    "#{?${TAMA_WINDOW_PRIORITY_OPTION},#{E:@tama_priority_icon},}")

  # choose-tree offers only one format for all three row types. Keep that complete
  # format here so users do not have to copy tmux's implementation just to decorate
  # window rows. The nested conditional is understood by every supported tmux version.
  choose_tree_format='#{?pane_format,#{pane_current_command} "#{pane_title}",'
  choose_tree_format="${choose_tree_format}#{?window_format,"
  choose_tree_format="${choose_tree_format}#{E:@tama_priority}#{window_name}#{E:@tama_icons}#{E:@tama_flag}"
  choose_tree_format="${choose_tree_format}#{window_flags} (#{window_panes} panes)"
  choose_tree_format="${choose_tree_format}#{?#{==:#{window_panes},1}, \"#{pane_title}\",},"
  choose_tree_format="${choose_tree_format}#{session_windows} windows"
  choose_tree_format="${choose_tree_format}#{?session_grouped, (group #{session_group}: #{session_group_list}),}"
  choose_tree_format="${choose_tree_format}#{?session_attached, (attached),}}}"
  wire_sets+=(';' set -g @tama_choose_tree_format "$choose_tree_format")

  # The flag text has to exist as an option, because a format cannot carry a default:
  # `#{E:@tama_flag_text}` on an option nobody set expands to nothing, and the flag
  # would be raised and draw as empty. So it is seeded here — and only when it has
  # never been set, which is what keeps `set -g @tama_flag_text ''` meaning "no text"
  # rather than being handed the default back on the next reload. Same distinction
  # lib/options.sh draws for every other option; this is the one that cannot be drawn
  # at read time, since tmux is doing the reading.
  if [ "$wire_have_flag_text" -eq 0 ]; then
    wire_sets+=(';' set -g @tama_flag_text ' !')
  fi

  # One round-trip for all of the option writes above.
  tmux_run "${wire_sets[@]}"

  wire_hooks
  return 0
}

# Every hook in TAMA_HOOKS (lib/hooks.sh), appended and never assigned, so a user's own
# lines on these events keep working — and skipped when already there, because this file
# runs again on every `tmux source-file` and `set-hook -ga` would otherwise stack another
# copy on each reload.
#
# `@tama_manage_hooks off` leaves tmux's hooks alone entirely, for users who keep
# their configuration under their own control and would rather call `tama on-select`
# from a hook they wrote themselves.
wire_hooks() {
  # The option name carries its own `tama_`: tama_opt prepends the `@` and nothing
  # else, so a name without the prefix reads an option nobody sets and silently
  # lands on the default — which for this one would mean wiring hooks the user
  # asked it not to touch.
  #
  # Through lib/options.sh, sourced above by lib/common.sh, so that `no`, `0` and
  # `false` mean here exactly what they mean everywhere else. Read strictly against
  # `on`, they meant *off*, and the whole plugin then wired no hooks at all: no mark
  # ever cleared, no sweep ever run, and nothing on screen to say why.
  tama_opt_enabled tama_manage_hooks on || return 0

  # One dump for every hook below, instead of one query each. `show -gqv`
  # prints each wired recipe on its own line and prints nothing — and, unlike
  # `show-options`, never fails — for an empty hook, so the chain cannot abort
  # partway on any tmux version. Markers separate the hooks, in chain order.
  local wire_marker wire_dump wire_section wire_index
  wire_marker="__tama_hooks_$$_${RANDOM}_${RANDOM}__"
  wire_dump="$(tmux_run show -gqv client-attached ';' display-message -p "$wire_marker" ';' show -gqv after-select-window ';' display-message -p "$wire_marker" ';' show -gqv after-select-pane ';' display-message -p "$wire_marker" ';' show -gqv client-focus-in ';' display-message -p "$wire_marker" ';' show -gqv client-session-changed ';' display-message -p "$wire_marker" 2>/dev/null)" || return 0

  # Indexed entries for exactly one hook, for the targeted removal below:
  # only the `hook[N] command` form names the single entry to drop, and this
  # query cannot abort anything because it stands alone.
  local wire_indexed
  wire_indexed="$(tmux_run show-options -g client-attached 2>/dev/null)" || wire_indexed=''

  # This version splits attachment acknowledgement from its server-wide sweep. Remove
  # only the exact recipe the previous version owned, leaving every user hook intact.
  local wire_obsolete wire_apply_first=1
  local wire_apply_args
  wire_obsolete="$(tama_hook_recipe 'on-select --all --window #{window_id}')"
  local entry command
  while read -r entry command; do
    [ "$command" = "run-shell -b \"$wire_obsolete\"" ] || continue
    case "$entry" in
      client-attached\[*\]*)
        if [ "$wire_apply_first" -eq 1 ]; then
          wire_apply_first=0
        else
          wire_apply_args+=(';')
        fi
        wire_apply_args+=(set-hook -gu "$entry")
        ;;
    esac
  done <<<"$wire_indexed"

  # Split the dump into one section per hook, in chain order, then check each
  # hook's own section for its recipe. Five small strings, no subprocesses.
  local hook cmdline wire_s0 wire_s1 wire_s2 wire_s3 wire_s4
  local wire_line wire_section
  wire_s0='' wire_s1='' wire_s2='' wire_s3='' wire_s4=''
  wire_index=0
  while IFS= read -r wire_line; do
    if [ "$wire_line" = "$wire_marker" ]; then
      wire_index=$((wire_index + 1))
      continue
    fi
    case "$wire_index" in
      0) wire_s0="$wire_s0
$wire_line" ;;
      1) wire_s1="$wire_s1
$wire_line" ;;
      2) wire_s2="$wire_s2
$wire_line" ;;
      3) wire_s3="$wire_s3
$wire_line" ;;
      4) wire_s4="$wire_s4
$wire_line" ;;
    esac
  done <<<"$wire_dump"

  while IFS='|' read -r hook cmdline; do
    [ -n "$hook" ] || continue
    case "$hook" in
      client-attached) wire_section="$wire_s0" ;;
      after-select-window) wire_section="$wire_s1" ;;
      after-select-pane) wire_section="$wire_s2" ;;
      client-focus-in) wire_section="$wire_s3" ;;
      client-session-changed) wire_section="$wire_s4" ;;
      *) continue ;;
    esac
    if printf '%s\n' "$wire_section" | grep -qF -- "$(tama_hook_recipe "$cmdline")"; then
      continue
    fi
    if [ "$wire_apply_first" -eq 1 ]; then
      wire_apply_first=0
    else
      wire_apply_args+=(';')
    fi
    wire_apply_args+=(set-hook -ga "$hook" "run-shell -b '$(tama_hook_recipe "$cmdline")'")
  done <<EOF
$TAMA_HOOKS
EOF
  [ "$wire_apply_first" -eq 1 ] || tmux_run "${wire_apply_args[@]}" >/dev/null 2>&1 || true
  return 0
}

main "$@"

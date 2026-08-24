# shellcheck shell=bash
#
# Shared hook recipes keep installation and `doctor` checks identical. They resolve
# the plugin through `@tama_bin` so moving the clone does not leave stale paths, and
# pass `#{window_id}` because tmux gives hook `run-shell` an unusable TMUX_PANE.
# shellcheck disable=SC2034  # TAMA_HOOKS is read by the two files that source this one
TAMA_HOOKS='after-select-window|on-select --window #{window_id}
after-select-pane|gc --window #{window_id}
client-focus-in|on-select --all --window #{window_id}
client-session-changed|on-select --window #{window_id}
client-attached|gc --all'

# Whether that tmux hook already carries this plugin's recipe for that command.
#
# tmux prints a hook array back requoted — single quotes come out double — so this looks
# for the part of the recipe that no requoting touches rather than the whole line. There
# is nothing in it for tmux to requote, and naming the plugin's own option and the
# command together is specific enough that no other hook on the event could collide
# with it.
tama_hook_is_wired() { # <tmux hook> <tama command>
  tmux_run show-options -g "$1" 2>/dev/null | grep -qF -- "$(tama_hook_recipe "$2")"
}

# The recipe body a wired hook carries, without the `run-shell -b` and its quoting.
tama_hook_recipe() { # <tama command>
  printf '%s' "#{q:@tama_bin} $1"
}

# shellcheck shell=bash
#
# The tmux hooks this plugin needs, and what a wired one looks like.
#
# Sourced by two callers and by nothing else: `tamagotchi.tmux`, which wires them, and
# `libexec/doctor`, which reports on them. It is not part of lib/common.sh for the same
# reason lib/version.sh is not — only those two need it, and libexec/icons runs once per
# window per status interval and should not read a file it will never use. Both source it
# directly, the way both already source lib/version.sh so that "supported tmux" cannot
# have two meanings.
#
# The list lives here because `doctor` used to have no access to it and had to guess.
# It looked for the option name `@tama_bin` anywhere in `show-hooks -g`, while
# `tama_hook_is_wired` below decides the question by the whole recipe — so a server
# carrying only a *stale* recipe from an earlier version of this plugin, naming a
# command that has since been renamed or had its arguments changed, was reported as
# "the plugin's tmux hooks are wired in this server" while those hooks did something
# else or nothing. Two implementations of "wired" would eventually disagree, and this is
# what it cost when they did.
#
# The hooks, as `<tmux hook>|<what bin/tama is asked to do>`.
#
#   * the user selecting a window is what clears its mark, and nothing else does;
#     arriving at a window is also a good moment to sweep the state of its panes
#   * a pane selection is the cheap sweep: one window, constantly, and no write at
#     all when nothing in it is stale
#   * the terminal regaining focus is the expensive one — every pane on the server —
#     and it earns it by being rare and by being exactly when the user is about to
#     read the whole status line. It also takes the mark off the window they came
#     back to, which a `select-window` that never happened would not have.
#   * attaching is the same moment for a terminal that never reports focus at all.
#     tmux fires `client-attached` and not `client-focus-in` for a bare `attach`, so
#     without this line the mark on the window a user attaches straight onto would sit
#     there until they selected some other window and came back. Clearing it is right
#     rather than merely cheap: if that window is already the session's active one,
#     attaching means they are looking at it.
#
# The recipes name the plugin through `@tama_bin` instead of carrying its path, which
# `run-shell` expands when the hook fires. That is what makes each string a constant:
# `tama_hook_is_wired` can look for it exactly, a user who moves their clone does not
# need to rewire anything, and there is no stale absolute path left in a hook pointing at
# a directory that has gone.
#
# `#{window_id}` is expanded the same way, against the window the hook fired for, and
# it has to be: tmux sets $TMUX_PANE in a hook's `run-shell` to a pane that does not
# exist, so a command left to find its own target from the environment would quietly
# work on nothing. Interpolated bare, because a window id is `@` and digits — there is
# nothing in it for a shell to act on.
# shellcheck disable=SC2034  # TAMA_HOOKS is read by the two files that source this one
TAMA_HOOKS='after-select-window|on-select --window #{window_id}
after-select-pane|gc --window #{window_id}
client-focus-in|on-select --all --window #{window_id}
client-attached|on-select --all --window #{window_id}'

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

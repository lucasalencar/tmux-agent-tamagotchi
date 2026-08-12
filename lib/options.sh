# shellcheck shell=bash
#
# Configuration reader. Every option lives in a global tmux user option, set with
# `set -g @tama_…` the way every tmux plugin is configured, and is read at
# invocation time, never cached, so `tmux source-file` takes effect on the very
# next command with no server restart.

# tama_opt <option-name-without-@> <default>
tama_opt() {
  local value default="${2-}"
  # `show -gv` without -q fails on an option that was never set, which is the
  # only way to tell it apart from one deliberately set to the empty string.
  # Emptying an option is a real configuration act: `set -g @tama_icon_prefix ''`
  # means "no prefix", not "give me the default back". An unreachable tmux also
  # lands on the default, which is the only useful thing to do with it.
  if value="$(tmux_run show -gv "@$1" 2>/dev/null)"; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

# shellcheck shell=bash
#
# Configuration reader. Every option lives in a server-scoped tmux user option
# and is read at invocation time, never cached, so `tmux source-file` takes
# effect on the very next command with no server restart.

# tama_opt <option-name-without-@> <default>
tama_opt() {
  local value
  value="$(tmux_run show -gqv "@$1" 2>/dev/null)" || value=''
  if [ -z "$value" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$value"
  fi
}

# tama_opt_enabled <option-name-without-@> <default>
# True when the option reads as on/true/yes/1.
tama_opt_enabled() {
  case "$(tama_opt "$1" "$2")" in
    on | true | yes | 1) return 0 ;;
    *) return 1 ;;
  esac
}

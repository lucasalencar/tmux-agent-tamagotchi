#!/usr/bin/env bats

# What an agent's hooks do to the plugin, driven the way an agent drives them:
# `tama hook <agent> <event>`. The adapter's own file is never invoked directly —
# it is only reachable through the CLI, which is the only surface a user's
# settings.json ever names.

bats_require_minimum_version 1.7.0

load helper

setup() {
  tama_start_server
  PANE="$(test_tmux list-panes -t t -F '#{pane_id}' | head -1)"
  WINDOW="$(test_tmux display-message -p -t "$PANE" '#{window_id}')"
}

teardown() {
  tama_detach_client
  tama_kill_server
}

# An event, reported from the pane the agent is running in — which is where a
# Claude Code hook runs, so $TMUX_PANE is the pane and not the lie it is inside a
# tmux `run-shell`.
hook() { # <event> [args…]
  TMUX_PANE="$PANE" run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook claude-code "$@"
}

# Sets $PLUGIN to a copy of the plugin carrying one adapter for an agent nothing
# in the plugin has heard of.
plugin_with_stub_agent() {
  PLUGIN="$BATS_TEST_TMPDIR/plugin"
  tama_copy_plugin "$PLUGIN"
  tama_add_stub_integration "$PLUGIN" made-up-agent
}

# A payload of the shape Claude Code sends, with the fields it documents as common
# plus whatever this event adds.
payload() { # <event> [extra JSON…]
  printf '{"session_id":"abc123","transcript_path":"/tmp/t.jsonl",'
  printf '"cwd":"/tmp","permission_mode":"default","hook_event_name":"%s"%s}' "$1" "$2"
}

# --------------------------------------------------------------------------
# The router
# --------------------------------------------------------------------------

@test "hook routes by directory name, with no list of known agents anywhere" {
  plugin_with_stub_agent

  # An agent name this plugin cannot possibly know: it is the directory that makes
  # it dispatchable.
  run "$PLUGIN/bin/tama" hook made-up-agent SomeEvent
  assert_success
  assert_output_contains 'arg: SomeEvent'
}

@test "the event and everything after it reach the adapter untouched" {
  plugin_with_stub_agent

  run "$PLUGIN/bin/tama" hook made-up-agent SomeEvent --pane %9 "two words"
  assert_success
  assert_output_contains 'argc: 4'
  assert_output_contains 'arg: SomeEvent'
  assert_output_contains 'arg: two words'
}

@test "the adapter is told where the plugin and the CLI are" {
  plugin_with_stub_agent
  local root
  root="$(cd -P "$PLUGIN" && pwd)"

  run "$PLUGIN/bin/tama" hook made-up-agent SomeEvent
  assert_success
  # How an adapter reaches the core: the public CLI, by absolute path, because
  # nothing is installed onto PATH.
  assert_output_contains "plugin_dir: $root"
  assert_output_contains "tama_bin: $root/bin/tama"
}

@test "the adapter's exit status reaches the caller" {
  plugin_with_stub_agent

  TAMA_STUB_EXIT=3 run "$PLUGIN/bin/tama" hook made-up-agent SomeEvent
  assert_status 3
}

@test "an agent with no adapter exits 2 with a message naming it" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook no-such-agent SomeEvent
  assert_usage_error 'no-such-agent'
}

@test "an agent name that reaches outside integrations exits 2" {
  plugin_with_stub_agent

  run --separate-stderr "$PLUGIN/bin/tama" hook ../../bin SomeEvent
  assert_usage_error
  run --separate-stderr "$PLUGIN/bin/tama" hook /bin SomeEvent
  assert_usage_error
  run --separate-stderr "$PLUGIN/bin/tama" hook .. SomeEvent
  assert_usage_error
}

@test "a dotfile directory is not an agent" {
  plugin_with_stub_agent
  mv "$PLUGIN/integrations/made-up-agent" "$PLUGIN/integrations/.hidden"

  run --separate-stderr "$PLUGIN/bin/tama" hook .hidden SomeEvent
  assert_usage_error '.hidden'
}

@test "an adapter that is not executable exits 2" {
  plugin_with_stub_agent
  chmod -x "$PLUGIN/integrations/made-up-agent/hook"

  run --separate-stderr "$PLUGIN/bin/tama" hook made-up-agent SomeEvent
  assert_usage_error 'made-up-agent'
}

@test "a missing or empty event exits 2, naming the agent" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook claude-code
  assert_usage_error 'claude-code'

  # A hook whose variable failed to interpolate, which is a wrong hook and not an
  # event from a version that does not exist yet.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook claude-code ''
  assert_usage_error 'claude-code'
}

@test "no agent at all exits 2" {
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook
  assert_usage_error
}

@test "outside tmux a hook does nothing, quietly" {
  # One settings.json is used on machines with and without tmux, so this is the
  # common case and not an edge one.
  unset TMUX
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook claude-code Stop
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook no-such-agent Stop
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# --------------------------------------------------------------------------
# The Claude Code adapter: the states a user sees
# --------------------------------------------------------------------------

@test "a session starting puts an idle agent in the pane" {
  hook SessionStart
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_pane_option "$PANE" state_main idle
  # The name is recorded by every event that reports a state, so a later
  # notification title has something to say without the user configuring it.
  assert_pane_option "$PANE" agent claude-code
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "submitting a prompt and every tool call show the agent working" {
  hook UserPromptSubmit
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  hook Stop
  assert_equal "$(tama_icons "$WINDOW")" ' ○'

  # Every event that means the turn is still moving, including the ones that only
  # a user who wired them will ever send.
  local event
  for event in PreToolUse PostToolUse PostToolUseFailure PostToolBatch; do
    hook Stop
    hook "$event"
    assert_success
    assert_equal "$(tama_icons "$WINDOW")" ' ●'
  done
}

@test "a permission request shows the agent blocked on the user" {
  hook PermissionRequest
  assert_success

  assert_pane_option "$PANE" state_main waiting
  assert_equal "$(tama_icons "$WINDOW")" ' ◐'
}

@test "a permission request in a window the user is not looking at flags it" {
  # The whole point of the state half: the user is elsewhere and finds out anyway.
  # The plugin is loaded because the mark is asked for the way a status line asks
  # — through the format the entrypoint exports — and not as a raw option.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  test_tmux new-window -d -t t:
  local other other_pane
  other="$(tama_window_id t:1)"
  other_pane="$(tama_pane_of t:1)"
  test_tmux select-window -t t:0

  TMUX_PANE="$other_pane" run "$PLUGIN_ROOT/bin/tama" hook claude-code PermissionRequest
  assert_success

  assert_flagged "$other"
  assert_not_flagged "$WINDOW"
}

@test "a turn that ends shows the agent idle, and one that dies shows an error" {
  hook UserPromptSubmit
  hook Stop
  assert_success
  assert_pane_option "$PANE" state_main idle
  assert_equal "$(tama_icons "$WINDOW")" ' ○'

  hook StopFailure
  assert_success
  assert_pane_option "$PANE" state_main error
  assert_equal "$(tama_icons "$WINDOW")" ' ✕'
}

@test "a session ending leaves no trace of the agent in tmux" {
  hook UserPromptSubmit
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"agt_1"')"
  assert_success

  hook SessionEnd
  assert_success

  # Not emptied — unset, so the pane is indistinguishable from one that never ran
  # an agent.
  assert_pane_option_unset "$PANE" state_main
  assert_pane_option_unset "$PANE" agent
  assert_pane_option_unset "$PANE" subagents
  assert_pane_option_unset "$PANE" cmd
  assert_equal "$(tama_icons "$WINDOW")" ''
}

@test "an event this version does not map is ignored in silence" {
  hook PreCompact
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option_unset "$PANE" state_main

  # Including one that does not exist at all: Claude Code adds events, and a
  # settings.json written against a newer plugin has to be harmless here.
  hook SomeEventFromTheFuture
  assert_success
  assert_pane_option_unset "$PANE" state_main
}

@test "an event reported from no pane at all exits 0 and writes nothing" {
  # A wrapper that lost the environment. Nothing to write state on, and an
  # agent's turn must not fail over it.
  run --separate-stderr "$PLUGIN_ROOT/bin/tama" hook claude-code Stop
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option_unset "$PANE" state_main
}

# --------------------------------------------------------------------------
# The two payload fields the adapter reads
# --------------------------------------------------------------------------

@test "a notification that means the user is wanted shows the agent waiting" {
  local type
  for type in permission_prompt idle_prompt agent_needs_input elicitation_dialog; do
    hook SessionStart
    hook Notification <<<"$(payload Notification ",\"notification_type\":\"$type\"")"
    assert_success
    assert_pane_option "$PANE" state_main waiting
  done
}

@test "a routine notification leaves the pane as it was" {
  hook SessionStart
  assert_pane_option "$PANE" state_main idle

  # Signing in is not a reason to say an agent needs the user, and a pane wrongly
  # left in `waiting` outlives whatever caused it.
  local type
  for type in auth_success elicitation_complete elicitation_response agent_completed; do
    hook Notification <<<"$(payload Notification ",\"notification_type\":\"$type\"")"
    assert_success
    assert_pane_option "$PANE" state_main idle
  done

  # Including a type from a version that does not exist yet: unknown reads as
  # routine, because the next thing the agent does corrects a missed one while a
  # wrong `waiting` sits there.
  hook Notification <<<"$(payload Notification ',"notification_type":"something_new"')"
  assert_success
  assert_pane_option "$PANE" state_main idle
}

@test "a notification with no payload to read is ignored" {
  hook SessionStart
  hook Notification </dev/null
  assert_success
  assert_pane_option "$PANE" state_main idle
}

@test "an idle agent with a delegated run still going shows as working" {
  hook SessionStart

  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"agt_01","agent_type":"Explore"')"
  assert_success
  hook Stop
  assert_success

  # Not the idle glyph: the turn is over but its subagent is not.
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  hook SubagentStop <<<"$(payload SubagentStop ',"agent_id":"agt_01","agent_type":"Explore"')"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "two delegated runs are counted, not collapsed" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"agt_01"')"
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"agt_02"')"
  hook Stop

  hook SubagentStop <<<"$(payload SubagentStop ',"agent_id":"agt_01"')"
  assert_success
  # One is still out there.
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  hook SubagentStop <<<"$(payload SubagentStop ',"agent_id":"agt_02"')"
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "the id is found however the payload is spaced" {
  hook SessionStart
  # Pretty-printed, which is what a JSON writer with an indent produces.
  hook SubagentStart <<'PAYLOAD'
{
  "hook_event_name": "SubagentStart",
  "agent_id": "agt_pretty",
  "agent_type": "Explore"
}
PAYLOAD
  assert_success
  hook Stop
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  hook SubagentStop <<'PAYLOAD'
{
  "hook_event_name": "SubagentStop",
  "agent_id": "agt_pretty"
}
PAYLOAD
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "a delegated run with no id is not counted at all" {
  hook SessionStart

  # No field, a null one, and no payload whatsoever. Tracking nothing is the safe
  # direction: the alternative is a pane pinned to `background` by an id that
  # nothing will ever stop.
  hook SubagentStart <<<"$(payload SubagentStart)"
  assert_success
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":null')"
  assert_success
  hook SubagentStart </dev/null
  assert_success

  assert_pane_option_unset "$PANE" subagents
  hook Stop
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "a payload the adapter cannot make sense of leaves the pane alone" {
  hook SessionStart

  # Truncated, not JSON at all, empty, and an object with nothing in it. A hook
  # runs inside a turn: whatever arrives, the only acceptable outcomes are no
  # tracking, exit 0 and not a word on stderr.
  local broken
  for broken in '{"agent_id": "agt_cut' 'not json at all' '' '{}' '{"agent_id":}' \
    '{"agent_id":{"nested":"agt_x"}}' '{"agent_id":12345}'; do
    hook SubagentStart <<<"$broken"
    assert_success
    [ -z "$output" ] || {
      printf 'a broken payload printed: %s\n' "$output" >&2
      return 1
    }
    [ -z "$stderr" ] || {
      printf 'a broken payload wrote to stderr: %s\n' "$stderr" >&2
      return 1
    }
    hook Notification <<<"$broken"
    assert_success
    [ -z "$stderr" ]
  done

  assert_pane_option_unset "$PANE" subagents
  assert_pane_option "$PANE" state_main idle
}

@test "an id that is not a plain token is not an id" {
  hook SessionStart

  # The extraction is two string matches, not a JSON parser, so a value carrying
  # a quote, an escape or a brace is one it has no business believing it read
  # correctly. Refusing anything but a bare token is what makes that safe.
  local hostile
  for hostile in '{"agent_id":"agt\"01"}' '{"agent_id":"agt\\"}' \
    '{"agent_id":"agt}01"}' '{"agent_id":"agt 01"}' \
    '{"agent_id":"../../etc/passwd"}' '{"agent_id":"-t"}'; do
    hook SubagentStart <<<"$hostile"
    assert_success
    assert_pane_option_unset "$PANE" subagents
  done
}

@test "an id that looks like shell is inert" {
  hook SessionStart

  # Nothing in the payload is ever eval'd or word-split, so this is expansion
  # that never happens rather than a value that is filtered out — but the file it
  # would create is the only proof that reads the same in a year.
  local canary="$BATS_TEST_TMPDIR/pwned"
  hook SubagentStart <<<"{\"agent_id\":\"\$(touch $canary)\"}"
  assert_success
  hook SubagentStart <<<"{\"agent_id\":\"; touch $canary\"}"
  assert_success
  hook SubagentStart <<<'{"agent_id":"$(id -u)"}'
  assert_success

  [ ! -e "$canary" ] || {
    printf 'a payload ran a command: %s exists\n' "$canary" >&2
    return 1
  }
  assert_pane_option_unset "$PANE" subagents
}

@test "a payload larger than the adapter will hold does not stop it reporting" {
  hook SessionStart

  # A payload is whatever an agent's own event carries, which is not a size this
  # plugin controls. It reads a bounded amount: the id near the front is found,
  # and one behind a megabyte of filler is simply an id it does not have.
  local filler
  filler="$(printf '%080000d' 0)"

  hook SubagentStart <<<"{\"agent_id\":\"agt_big\",\"filler\":\"$filler\"}"
  assert_success
  hook Stop
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  hook SubagentStop <<<"{\"agent_id\":\"agt_big\"}"
  assert_equal "$(tama_icons "$WINDOW")" ' ○'

  hook SubagentStart <<<"{\"filler\":\"$filler\",\"agent_id\":\"agt_beyond\"}"
  assert_success
  assert_pane_option_unset "$PANE" subagents
}

@test "a terminal on stdin is not a payload to wait for" {
  # Run by hand from a shell — or by anything that hands the hook the user's
  # terminal — reading stdin would block on a keyboard, inside a turn. A tmux
  # pane is a real terminal, so this is that situation rather than a stand-in
  # for it.
  local statusfile="$BATS_TEST_TMPDIR/tty.status"
  local target
  target="$(test_tmux new-window -t t: -P -F '#{pane_id}' \
    "$PLUGIN_ROOT/bin/tama hook claude-code SubagentStart; \
     printf '%s' \$? >'$statusfile'; exec sleep 60")"

  local waited=0
  until [ -s "$statusfile" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 50 ] || {
      printf 'the hook never came back with a terminal on stdin\n' >&2
      return 1
    }
    sleep 0.1
  done

  assert_equal "$(cat "$statusfile")" 0
  assert_pane_option_unset "$target" subagents
}

@test "a payload that never arrives is given up on" {
  # An open pipe nothing is written to. The adapter has to come back from that:
  # a hook that blocks forever stalls the agent's turn, which is worse than any
  # icon it could have got right.
  local fifo="$BATS_TEST_TMPDIR/silence.fifo"
  mkfifo "$fifo"
  sleep 30 >"$fifo" &
  local holder=$!

  local start=$SECONDS
  TMUX_PANE="$PANE" run --separate-stderr \
    "$PLUGIN_ROOT/bin/tama" hook claude-code SubagentStart <"$fifo"
  local elapsed=$((SECONDS - start))
  kill "$holder" 2>/dev/null || true

  assert_success
  [ -z "$stderr" ]
  assert_pane_option_unset "$PANE" subagents
  [ "$elapsed" -lt 10 ] || {
    printf 'SubagentStart waited %ss for a payload that never came\n' "$elapsed" >&2
    return 1
  }
}

@test "the hot path never waits on stdin" {
  # `running` is reported on every tool call. A hook that read stdin there would
  # sit inside the turn waiting for a payload it does not need, and a writer that
  # holds the pipe open without saying anything is what that looks like.
  local fifo="$BATS_TEST_TMPDIR/payload.fifo"
  mkfifo "$fifo"
  sleep 30 >"$fifo" &
  local holder=$!

  local start=$SECONDS
  TMUX_PANE="$PANE" run "$PLUGIN_ROOT/bin/tama" hook claude-code PostToolUse <"$fifo"
  local elapsed=$((SECONDS - start))
  kill "$holder" 2>/dev/null || true

  assert_success
  assert_pane_option "$PANE" state_main running
  [ "$elapsed" -lt 3 ] || {
    printf 'PostToolUse waited %ss on stdin\n' "$elapsed" >&2
    return 1
  }
}

# --------------------------------------------------------------------------
# The configuration a user pastes
# --------------------------------------------------------------------------

# One event's command, taken out of the JSON block in the adapter's README, so
# what these tests drive is the text a user pastes and not a paraphrase of it.
readme_command() { # <event>
  sed -n "s/.*\"command\": \"\\(.*hook claude-code $1\\)\".*/\\1/p" \
    "$PLUGIN_ROOT/integrations/claude-code/README.md" | sed 's/\\"/"/g'
}

@test "every event the adapter maps has a command in the README" {
  local event
  for event in SessionStart UserPromptSubmit PostToolUse PostToolUseFailure \
    PermissionRequest Notification Stop StopFailure SubagentStart SubagentStop \
    SessionEnd; do
    [ -n "$(readme_command "$event")" ] || {
      printf 'no command for %s in the README\n' "$event" >&2
      return 1
    }
  done
}

@test "the command the README tells a user to paste moves the icons" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_shim_tmux_on_path

  local command
  command="$(readme_command UserPromptSubmit)"
  [ -n "$command" ]

  TMUX_PANE="$PANE" run --separate-stderr sh -c "$command"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_equal "$(tama_icons "$WINDOW")" ' ●'

  command="$(readme_command Stop)"
  TMUX_PANE="$PANE" run --separate-stderr sh -c "$command"
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "the pasted command stays quiet where the plugin is not installed" {
  # The same settings.json is read on every machine the user has, including the
  # ones without this plugin and the ones whose tmux is too old for it to have
  # wired anything.
  test_tmux set -gu @tama_bin
  tama_shim_tmux_on_path

  local command
  command="$(readme_command Stop)"
  TMUX_PANE="$PANE" run --separate-stderr sh -c "$command"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
  assert_pane_option_unset "$PANE" state_main
}

@test "the adapter runs under the bash macOS ships" {
  # /bin/bash is 3.2 there, and the adapter picks a payload apart with parameter
  # expansion, which is exactly where a bash 5 idiom would go unnoticed.
  tama_use_bash_32_or_skip

  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"agt_32"')"
  assert_success
  hook Stop
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

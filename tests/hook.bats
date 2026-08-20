#!/usr/bin/env bats

# What an agent's hooks do to the plugin, driven the way an agent drives them:
# `tama hook <agent> <event>`. The adapter's own file is never invoked directly —
# it is only reachable through the CLI, which is the only surface a user's
# settings.json ever names.
#
# Everything here is a synthesised payload, which is the only way any of it is worth
# running in CI. Two notes for whoever checks this against a *live* agent instead,
# both learned the hard way:
#
#   * point the agent at a throwaway server (`tmux -L <name>`) with the backend off or
#     set to a recording stand-in, or the first event puts a real banner on somebody's
#     desktop — `@tama_backend auto` resolves to a real notifier on a developer's
#     machine
#   * `tmux send-keys -t <pane> '<prompt>' Enter` in one call intermittently leaves the
#     prompt sitting unsubmitted in the agent's input box. Send the text and the Enter
#     as two separate calls

bats_require_minimum_version 1.7.0

load helper

setup() {
  # The recording fake, for the whole file rather than only the notification tests:
  # half of what this adapter does is decide *not* to interrupt the user, and a
  # suite with no backend configured would pass every one of those claims for the
  # wrong reason. Nothing is attached to this server, so a banner is never
  # suppressed and a test that raises one always sees it.
  tama_fake_backend_env
  tama_start_server
  tama_use_fake_backend
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

@test "a notification that means the user is wanted shows the agent waiting" {
  local type
  for type in permission_prompt agent_needs_input elicitation_dialog elicitation_url_dialog; do
    hook SessionStart
    hook Notification <<<"$(payload Notification ",\"notification_type\":\"$type\"")"
    assert_success
    assert_pane_option "$PANE" state_main waiting
  done
}

@test "a routine notification leaves the pane as it was" {
  hook SessionStart
  assert_pane_option "$PANE" state_main idle

  # Signing in and the routine reminder Claude emits after a turn ends are not reasons
  # to say an agent needs the user, and a pane wrongly left in `waiting` outlives
  # whatever caused it.
  local type
  for type in auth_success elicitation_complete elicitation_response agent_completed idle_prompt; do
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

@test "an authoritative empty task snapshot heals an unpaired delegated stop" {
  hook SessionStart

  # Observed from one real background-launched Claude Code run: the stop named a
  # different id and omitted the type, even though only this started run remained.
  hook SubagentStart <<'PAYLOAD'
{"hook_event_name":"SubagentStart","agent_id":"affbdfa48f0528122","agent_type":"Explore"}
PAYLOAD
  hook Stop
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  hook SubagentStop <<'PAYLOAD'
{"hook_event_name":"SubagentStop","agent_id":"ab7b58905d1f4745c","agent_type":"","background_tasks":[]}
PAYLOAD
  assert_success
  assert_pane_option_unset "$PANE" subagents
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "a main stop also reconciles an authoritative empty task snapshot" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"leaked"')"

  hook Stop <<'PAYLOAD'
{"hook_event_name":"Stop","last_assistant_message":"done","background_tasks":[]}
PAYLOAD
  assert_success
  assert_pane_option_unset "$PANE" subagents
  assert_pane_option "$PANE" state_main idle
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "a delegated stop also reconciles an authoritative empty task snapshot" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"leaked"')"

  hook Stop <<'PAYLOAD'
{"hook_event_name":"Stop","agent_id":"delegated","background_tasks":[]}
PAYLOAD
  assert_success
  assert_pane_option_unset "$PANE" subagents
  assert_pane_option "$PANE" state_main idle
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "an unknown stop without an authoritative snapshot preserves known work" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"
  hook Stop

  hook SubagentStop <<'PAYLOAD'
{"hook_event_name":"SubagentStop","agent_id":"phantom","agent_type":""}
PAYLOAD
  assert_success
  assert_pane_option "$PANE" subagents known_live
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "a snapshot containing a subagent preserves known ids" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"
  hook Stop

  hook SubagentStop <<'PAYLOAD'
{"hook_event_name":"SubagentStop","agent_id":"phantom","agent_type":"","background_tasks":[{"id":"task-1","type":"subagent","status":"running"}]}
PAYLOAD
  assert_success
  assert_pane_option "$PANE" subagents known_live
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "a complete snapshot with only other background work clears subagent ids" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"
  hook Stop

  hook SubagentStop <<'PAYLOAD'
{"hook_event_name":"SubagentStop","agent_id":"phantom","agent_type":"","background_tasks":[{"id":"shell-1","type":"shell","status":"running","attempt":1,"done":false,"result":null,"metadata":{"nested":[1,true,null]}}]}
PAYLOAD
  assert_success
  assert_pane_option_unset "$PANE" subagents
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "unreadable task snapshots preserve known ids" {
  local broken
  for broken in \
    '{"hook_event_name":"Stop"}' \
    '{"hook_event_name":"Stop","background_tasks":{}}' \
    '{"hook_event_name":"Stop","background_tasks":[' \
    '{"hook_event_name":"Stop","background_tasks":[{"type":"shell"}' \
    '{"hook_event_name":"Stop","background_tasks":[not-json]}' \
    '{"hook_event_name":"Stop","tool_input":{"background_tasks":[]}}' \
    '{"hook_event_name":"Stop","background_tasks":[]' \
    '{"hook_event_name":"Stop","background_tasks":[],' \
    '{"hook_event_name":"Stop","background_tasks":[],}' \
    '{"hook_event_name":"Stop","background_tasks":[] "broken":true}' \
    '{"hook_event_name":"Stop","background_tasks":[]garbage}' \
    '{"hook_event_name":"Stop","invalid":not-json,"background_tasks":[]}' \
    '{"hook_event_name":"Stop","background_tasks":[],"broken" garbage}' \
    '{"hook_event_name":"Stop","background_tasks":[],"background_tasks":[{"type":"subagent"}]}'; do
    hook SessionStart
    hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"
    hook Stop <<<"$broken"
    assert_success
    assert_pane_option "$PANE" subagents known_live
    assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
    hook SessionEnd
  done
}

@test "literal control characters make a task snapshot non-authoritative" {
  local broken
  for broken in \
    $'{"hook_event_name":"Stop","note":"line\nbreak","background_tasks":[]}' \
    $'{"hook_event_name":"Stop","note":"tab\tbreak","background_tasks":[]}'; do
    hook SessionStart
    hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"
    hook Stop <<<"$broken"
    assert_success
    assert_pane_option "$PANE" subagents known_live
    hook SessionEnd
  done
}

@test "an authoritative stop snapshot does not require an incremental id" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"leaked"')"
  hook Stop

  hook SubagentStop <<'PAYLOAD'
{"hook_event_name":"SubagentStop","agent_type":"","background_tasks":[]}
PAYLOAD
  assert_success
  assert_pane_option_unset "$PANE" subagents
  assert_equal "$(tama_icons "$WINDOW")" ' ○'
}

@test "a large numeric task field stays bounded" {
  local zeros number start elapsed
  zeros="$(printf '%059000d' 0)"
  number="1$zeros"
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"leaked"')"

  start=$SECONDS
  hook Stop <<<"{\"hook_event_name\":\"Stop\",\"background_tasks\":[{\"type\":\"shell\",\"sequence\":$number}]}"
  elapsed=$((SECONDS - start))

  assert_success
  assert_pane_option_unset "$PANE" subagents
  [ "$elapsed" -lt 10 ] || {
    printf 'numeric task scan took %ss\n' "$elapsed" >&2
    return 1
  }
}

@test "long whitespace before a task snapshot stays bounded" {
  local spaces start elapsed
  spaces="$(printf '%*s' 15000 '')"
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"leaked"')"

  start=$SECONDS
  hook Stop <<<"{\"hook_event_name\":\"Stop\",${spaces}\"background_tasks\":${spaces}[]}"
  elapsed=$((SECONDS - start))

  assert_success
  assert_pane_option_unset "$PANE" subagents
  [ "$elapsed" -lt 10 ] || {
    printf 'background_tasks scan took %ss\n' "$elapsed" >&2
    return 1
  }
}

@test "many escaped string bytes stay bounded and preserve an ambiguous snapshot" {
  local escapes start elapsed
  escapes="$(printf '\\\\n%.0s' {1..2000})"
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"

  start=$SECONDS
  hook Stop <<<"{\"hook_event_name\":\"Stop\",\"note\":\"$escapes\",\"background_tasks\":[]}"
  elapsed=$((SECONDS - start))

  assert_success
  assert_pane_option "$PANE" subagents known_live
  [ "$elapsed" -lt 3 ] || {
    printf 'escaped JSON scan took %ss\n' "$elapsed" >&2
    return 1
  }
}

@test "many small JSON values stay bounded and preserve an ambiguous snapshot" {
  local values start elapsed
  values="$(printf '[],%.0s' {1..2000})null"
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"

  start=$SECONDS
  hook Stop <<<"{\"hook_event_name\":\"Stop\",\"metadata\":[$values],\"background_tasks\":[]}"
  elapsed=$((SECONDS - start))

  assert_success
  assert_pane_option "$PANE" subagents known_live
  [ "$elapsed" -lt 3 ] || {
    printf 'fragmented JSON scan took %ss\n' "$elapsed" >&2
    return 1
  }
}

@test "a task snapshot beyond the payload bound preserves known ids" {
  local filler
  filler="$(printf '%080000d' 0)"
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"

  hook Stop <<<"{\"hook_event_name\":\"Stop\",\"filler\":\"$filler\",\"background_tasks\":[]}"
  assert_success
  assert_pane_option "$PANE" subagents known_live
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "a valid JSON prefix ending at the payload bound is not authoritative" {
  local opening='{"filler":"' closing='","background_tasks":[]}' filler prefix
  filler="$(printf '%0*d' $((65536 - ${#opening} - ${#closing})) 0)"
  prefix="$opening$filler$closing"
  [ "${#prefix}" -eq 65536 ]
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"

  hook Stop <<<"${prefix}truncated-tail"

  assert_success
  assert_pane_option "$PANE" subagents known_live
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'
}

@test "the exact payload boundary is conservative without rejecting the byte below it" {
  local opening='{"filler":"' closing='","background_tasks":[]}' filler complete

  filler="$(printf '%0*d' $((65536 - ${#opening} - ${#closing})) 0)"
  complete="$opening$filler$closing"
  [ "${#complete}" -eq 65536 ]
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"known_live"')"
  hook Stop < <(printf '%s' "$complete")
  assert_success
  assert_pane_option "$PANE" subagents known_live
  hook SessionEnd

  filler="${filler:1}"
  complete="$opening$filler$closing"
  [ "${#complete}" -eq 65535 ]
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"leaked"')"
  hook Stop < <(printf '%s' "$complete")
  assert_success
  assert_pane_option_unset "$PANE" subagents
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

# Every payload below is the shape a real Claude Code 2.1.228 sends, taken from
# payloads captured out of a live session: `Notification` carries `message` and
# `notification_type`, `Stop` carries `last_assistant_message`, and an event
# belonging to a delegated run carries `agent_id`.
@test "a notification that means the user is wanted banners, carrying the agent's words" {
  hook SessionStart
  hook Notification \
    <<<"$(payload Notification ',"notification_type":"permission_prompt","message":"Claude needs your permission"')"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_pane_option "$PANE" state_main waiting
  assert_backend_called notify
  # The sentence the agent wrote, and nothing the plugin made up.
  assert_backend_value notify argv2 'Claude needs your permission'
  # Two arguments, ever: a title the user's format produced and the agent's message.
  assert_backend_value notify argc 2
  assert_contains "$(tama_backend_value notify argv1)" 'claude-code - ' 'the title'
}

@test "a turn that ends banners with what the agent last said" {
  hook SessionStart
  hook Stop <<<"$(payload Stop ',"stop_hook_active":false,"last_assistant_message":"I have finished the migration"')"
  assert_success

  assert_pane_option "$PANE" state_main idle
  assert_backend_value notify argv2 'I have finished the migration'
}

@test "a turn that died on an error banners as well" {
  hook SessionStart
  hook StopFailure <<<"$(payload StopFailure)"
  assert_success

  assert_pane_option "$PANE" state_main error
  assert_backend_value notify argv2 'stopped on an error'
}

@test "signing in is not worth interrupting the user" {
  hook SessionStart

  # The routine noise the whole `notification_type` read exists for — including a
  # type from a version that does not exist yet, which is treated as routine.
  local type
  for type in auth_success elicitation_complete elicitation_response agent_completed \
    something_new; do
    hook Notification \
      <<<"$(payload Notification ",\"notification_type\":\"$type\",\"message\":\"Signed in as someone\"")"
    assert_success
    refute_backend_called notify
  done

  assert_pane_option "$PANE" state_main idle
}

@test "a permission request moves the icon without interrupting the user" {
  # Deliberate, and the one event where the state half and the banner half part
  # company: Claude Code raises `Notification` for the same interruption a few
  # seconds later — 6s, measured on 2.1.228 — and that one carries the sentence this
  # event has no field for. Notifying here as well would mean two banners per
  # question, collapsing into one only because the core groups them per window.
  hook PermissionRequest <<<"$(payload PermissionRequest ',"tool_name":"Write"')"
  assert_success

  assert_pane_option "$PANE" state_main waiting
  refute_backend_called notify
}

@test "the idle prompt leaves a finished turn idle without interrupting the user" {
  # Claude Code raises this routine reminder 60s after a turn ends. It must not
  # overwrite the state recorded by Stop or repeat its banner.
  hook SessionStart
  hook Stop <<<"$(payload Stop ',"last_assistant_message":"I have finished the migration"')"
  assert_success
  hook Notification \
    <<<"$(payload Notification ',"notification_type":"idle_prompt","message":"Claude is waiting for your input"')"
  assert_success

  assert_pane_option "$PANE" state_main idle
  assert_equal "$(tama_backend_calls notify)" 1
  assert_backend_value notify argv2 'I have finished the migration'
}

@test "the idle prompt does not replace what the agent said with a sentence that says nothing" {
  # The regression, with a name. `Stop` banners the agent's own words; a minute later
  # the idle prompt arrives, and because banners are grouped per window a second one
  # would replace the first — leaving the user with `Claude is waiting for your
  # input` where they had been told what happened.
  hook SessionStart
  hook Stop <<<"$(payload Stop ',"last_assistant_message":"I have finished the migration"')"
  assert_success
  assert_backend_value notify argv2 'I have finished the migration'

  hook Notification \
    <<<"$(payload Notification ',"notification_type":"idle_prompt","message":"Claude is waiting for your input"')"
  assert_success

  # One banner for one finished turn, and it still says what the agent said.
  assert_equal "$(tama_backend_calls notify)" 1
  assert_backend_value notify argv2 'I have finished the migration'
}

@test "a banner leaves the window marked, so the user finds it later" {
  # Asked for the way a status line asks — through the format the entrypoint
  # exports — because the mark is what is still there minutes after the banner has
  # gone from the desktop.
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success

  hook SessionStart
  hook Stop <<<"$(payload Stop ',"last_assistant_message":"the tests pass"')"
  assert_success

  assert_backend_called notify
  assert_flagged "$WINDOW"
}

@test "a delegated run finishing is not the user's session finishing" {
  hook SessionStart
  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"agt_01","agent_type":"Explore"')"
  assert_success

  # A real SubagentStop carries `last_assistant_message` exactly as `Stop` does, so
  # staying quiet here is a decision and not something the payload made for us.
  hook SubagentStop \
    <<<"$(payload SubagentStop ',"agent_id":"agt_01","last_assistant_message":"I read every file"')"
  assert_success
  refute_backend_called notify
}

@test "an event a delegated run is attributed to stays quiet, and still moves the icon" {
  hook SessionStart

  # A subagent's own permission prompt: `PermissionRequest` and `Notification` both
  # fire, but only the first carries the subagent's `agent_id` — the second is
  # session-level, with no id at all. So suppressing everything marked as delegated
  # loses no question: the user still gets the banner from the event that has the
  # message in it.
  hook Notification \
    <<<"$(payload Notification ',"agent_id":"agt_01","agent_type":"Explore","notification_type":"permission_prompt","message":"Claude needs your permission"')"
  assert_success
  assert_pane_option "$PANE" state_main waiting
  refute_backend_called notify

  hook Notification \
    <<<"$(payload Notification ',"notification_type":"permission_prompt","message":"Claude needs your permission"')"
  assert_success
  assert_backend_called notify
}

@test "the message arrives as one argument, whatever the agent wrote in it" {
  hook SessionStart

  # Everything that has to survive being extracted from JSON and handed to a CLI:
  # an escaped quote, a real newline, a `$(…)`, a backtick, a tmux format, a percent
  # sign, and text past the first quote — which is where a scan that did not know
  # about escapes would stop.
  hook Notification <<PAYLOAD
{"hook_event_name":"Notification","notification_type":"agent_needs_input",
 "message":"He said \"no\" — first line\nsecond line \$(touch $BATS_TEST_TMPDIR/pwned) \`id\` #{window_id} 100%"}
PAYLOAD
  assert_success

  local expected
  expected="$(printf 'He said "no" — first line\nsecond line $(touch %s/pwned) `id` #{window_id} 100%%' \
    "$BATS_TEST_TMPDIR")"
  assert_backend_value notify argv2 "$expected"
  assert_backend_value notify argc 2

  [ ! -e "$BATS_TEST_TMPDIR/pwned" ] || {
    printf 'a message ran a command\n' >&2
    return 1
  }
}

@test "a message that begins with a dash is a message and not an option" {
  hook SessionStart
  hook Stop <<'PAYLOAD'
{"hook_event_name":"Stop","last_assistant_message":"--force is what you asked for"}
PAYLOAD
  assert_success
  [ -z "$stderr" ]

  assert_backend_value notify argv2 '--force is what you asked for'
}

@test "the escapes in a message are put back rather than passed on" {
  hook SessionStart
  # A tab, a backslash, an escaped solidus, and a `\u` sequence — which is not
  # decoded, because the only ones a JSON writer emits are control characters.
  hook Stop <<'PAYLOAD'
{"hook_event_name":"Stop","last_assistant_message":"a\tb \\ c \/ d \u0007e\n\n"}
PAYLOAD
  assert_success

  assert_backend_value notify argv2 "$(printf 'a\tb \\ c / d e')"
}

@test "an event with nothing to quote still says something" {
  hook SessionStart

  # No field, a payload cut off in the middle of the value, and no payload at all.
  # `tama notify` refuses an empty message — it is what a hook that failed to
  # interpolate its variable looks like — so an unreadable payload must not be
  # allowed to turn into a usage error inside somebody's turn.
  hook Stop <<<"$(payload Stop)"
  assert_success
  [ -z "$stderr" ]
  assert_backend_value notify argv2 'finished its turn'

  hook Stop <<<'{"last_assistant_message":"cut off in the mid'
  assert_success
  [ -z "$stderr" ]
  assert_backend_value notify argv2 'finished its turn'

  hook Stop </dev/null
  assert_success
  [ -z "$stderr" ]
  assert_backend_value notify argv2 'finished its turn'

  # And the same for the other message field, on a type that does banner — the idle
  # prompt no longer does, so it cannot stand in for one here.
  hook Notification <<<"$(payload Notification ',"notification_type":"permission_prompt"')"
  assert_success
  assert_backend_value notify argv2 'needs your attention'
}

@test "a message longer than a banner can carry is cut, not dropped" {
  hook SessionStart

  local long='the agent said' i=0
  while [ "$i" -lt 200 ]; do
    long="$long word$i"
    i=$((i + 1))
  done

  hook Stop <<<"{\"last_assistant_message\":\"$long\"}"
  assert_success

  local got
  got="$(tama_backend_value notify argv2)"
  [ "${#got}" -le 500 ] || {
    printf 'the banner carried %s characters\n' "${#got}" >&2
    return 1
  }
  [ "${#got}" -gt 100 ] || {
    printf 'the banner carried almost nothing: %s\n' "$got" >&2
    return 1
  }
  # What arrived is the beginning of what was said, and not a mangled version of it.
  case "$long" in
    "$got"*) ;;
    *)
      printf 'the banner was not a prefix of the message: %s\n' "$got" >&2
      return 1
      ;;
  esac
}

# One event's command, taken out of the JSON block in the adapter's README, so
# what these tests drive is the text a user pastes and not a paraphrase of it.
readme_command() { # <event>
  sed -n 's/.*"command": "\(.*\)" } ] }.*/\1/p' \
    "$PLUGIN_ROOT/integrations/claude-code/README.md" |
    sed 's/\\"/"/g' |
    grep -F -- "hook claude-code $1 "
}

@test "the README uses the canonical silent command" {
  assert_equal "$(readme_command Stop)" \
    '"$(tmux show -gqv @tama_bin 2>/dev/null)" hook claude-code Stop >/dev/null 2>&1 || :'
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

@test "the command the README tells a user to paste raises a banner" {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
  tama_shim_tmux_on_path

  local command
  command="$(readme_command Notification)"
  [ -n "$command" ]

  TMUX_PANE="$PANE" run --separate-stderr sh -c "$command" \
    <<<"$(payload Notification ',"notification_type":"permission_prompt","message":"Claude needs your permission"')"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]

  assert_backend_value notify argv2 'Claude needs your permission'
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

@test "the pasted command stays quiet when the discovered adapter is broken" {
  plugin_with_stub_agent
  tama_add_stub_integration "$PLUGIN" claude-code
  test_tmux set -g @tama_bin "$PLUGIN/bin/tama"
  tama_shim_tmux_on_path

  local command
  command="$(readme_command Stop)"
  TAMA_STUB_EXIT=3 TMUX_PANE="$PANE" run --separate-stderr sh -c "$command"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "the pasted command stays quiet outside tmux" {
  tama_shim_tmux_on_path
  local command
  command="$(readme_command Stop)"

  TMUX='' TMUX_PANE='' run --separate-stderr sh -c "$command"
  assert_success
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "the adapter runs under the bash macOS ships" {
  # /bin/bash is 3.2 there, and the adapter picks a payload apart with parameter
  # expansion, which is exactly where a bash 5 idiom would go unnoticed. Note that
  # this test asserts nothing on Linux, where there is no 3.2 to point at — the
  # claims above are the ones that hold on both.
  tama_use_bash_32_or_skip

  hook SubagentStart <<<"$(payload SubagentStart ',"agent_id":"agt_32"')"
  assert_success
  hook Stop </dev/null
  assert_success
  assert_equal "$(tama_icons "$WINDOW")" ' ⚙'

  # The escape-aware half too, which is the part that uses substring expansion and a
  # nested expansion in a pattern.
  hook Notification <<'PAYLOAD'
{"hook_event_name":"Notification","notification_type":"permission_prompt",
 "message":"He said \"no\"\nand \\ meant it"}
PAYLOAD
  assert_success
  assert_backend_value notify argv2 "$(printf 'He said "no"\nand \\ meant it')"
}

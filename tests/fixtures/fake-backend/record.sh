# shellcheck shell=sh
#
# The recording half of the fake backend: what the plugin asked this capability to
# do, written where a test can read it.
#
# A backend is a directory of executables and nothing else, which is why this fixture
# needs no support in the production code at all — pointing `@tama_backend` at an
# arbitrary directory is a user feature, not a testing seam.
#
# Two observation points, because they answer different questions:
#
#   $TAMA_TEST_LOG            one line per invocation, the capability's name. This is
#                             the call log: which capabilities ran, in what order, how
#                             many times.
#   $TAMA_TEST_LOG.<cap>.…    one file per argument and per environment variable, each
#                             holding exactly the bytes that arrived, from the last
#                             invocation of that capability.
#
# The per-value files exist because the interesting values cannot survive a line-based
# log: a notification message is arbitrary text an agent wrote, and the click action is
# a whole shell command line. A test that wants to know what a banner said compares
# bytes; a test that wants to know whether a click works *runs* the file.

# Every variable of the capability contract, recorded whether or not this capability is
# supposed to be given it — a value that turns up where it was not promised is worth
# seeing, and one that is missing where it was promised is what a test is looking for.
tama_record() { # <capability> [args…]
  tama_capability="$1"
  shift

  printf '%s\n' "$tama_capability" >>"$TAMA_TEST_LOG"

  printf '%s' "$#" >"$TAMA_TEST_LOG.$tama_capability.argc"
  tama_argument=0
  for tama_value in "$@"; do
    tama_argument=$((tama_argument + 1))
    printf '%s' "$tama_value" >"$TAMA_TEST_LOG.$tama_capability.argv$tama_argument"
  done

  tama_record_env TAMA_GROUP "${TAMA_GROUP-}"
  tama_record_env TAMA_SESSION "${TAMA_SESSION-}"
  tama_record_env TAMA_WINDOW_ID "${TAMA_WINDOW_ID-}"
  tama_record_env TAMA_PANE_ID "${TAMA_PANE_ID-}"
  tama_record_env TAMA_AGENT "${TAMA_AGENT-}"
  tama_record_env TAMA_CLICK "${TAMA_CLICK-}"
  tama_record_env TAMA_BIN "${TAMA_BIN-}"
  tama_record_env TAMA_TERMINAL_APP "${TAMA_TERMINAL_APP-}"
  tama_record_env TAMA_TERMINAL_BUNDLE_ID "${TAMA_TERMINAL_BUNDLE_ID-}"
}

# Written with no trailing newline, so the file holds the value and nothing else.
tama_record_env() { # <name> <value>
  printf '%s' "$2" >"$TAMA_TEST_LOG.$tama_capability.env.$1"
}

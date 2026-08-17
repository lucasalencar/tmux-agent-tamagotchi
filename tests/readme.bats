#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

# The project README, held to what the plugin really does.
#
# A README is prose and most of it cannot be asserted. What *can* is every part of it a
# user copies or types, and that is exactly the part that rots: the status-line snippet
# now exists in four places (`tama --help`, `libexec/doctor`,
# `examples/demo.tmux.conf`, and here), and the note above `doctor_setup` asks anyone
# adding a copy either to reference an existing one or to bind theirs the way the Claude
# Code hook block is bound. This file is that binding for the README's copy, and it
# takes the stricter of the two available claims: not merely "tmux accepts these lines"
# but "these lines are byte-for-byte the ones doctor prints", so the two cannot drift at
# all.
#
# It also binds three lists, because a list is the other thing that rots silently:
#
#   * every option name the README mentions has to exist somewhere in the plugin, so a
#     renamed or invented option is a failure rather than a sentence nobody can act on;
#   * every option `tama --help` shows as a `set -g` line has to appear in the README's
#     option map, so an option added to the code and the help but not the front door is
#     a failure here;
#   * the commands the README lists have to be exactly the subcommands that exist, since
#     `bin/tama` dispatches by file name in libexec/ and holds no list of its own.
#
# And one negative claim: the README must not carry a copy of the Claude Code hook
# block. There are two of those, doctor's and the integration README's, and a test
# asserts they agree — because doctor also *checks* your settings against that list. A
# third copy in a file no test compares would be the one that quietly tells somebody to
# wire a set of events doctor does not know about.

README="$PLUGIN_ROOT/README.md"

setup() {
  tama_start_server
}

teardown() {
  tama_kill_server
}

# Every `set -g` line inside a fenced block of the README, in order, with the leading
# indent gone. The same extraction doctor.bats does on doctor's output, so the two
# comparisons below are of like with like.
readme_set_lines() {
  sed -n 's/^ *\(set -g .*\)$/\1/p' "$README"
}

# The same lines out of `tama doctor`, which is the copy this one is measured against.
doctor_set_lines() {
  "$PLUGIN_ROOT/bin/tama" doctor | sed -n 's/^ *\(set -g .*\)$/\1/p'
}

help_set_lines() {
  "$PLUGIN_ROOT/bin/tama" --help | sed -n 's/^ *\(set -g .*\)$/\1/p'
}

demo_set_lines() {
  setup_recipe_lines "$PLUGIN_ROOT/examples/demo.tmux.conf"
}

setup_recipe_lines() {
  sed -n \
    -e 's/^ *\(set -g window-status.*\)$/\1/p' \
    -e 's/^ *\(set -g set-titles.*\)$/\1/p' "$1"
}

setup_recipe_from_lines() {
  sed -n \
    -e '/^set -g window-status/p' \
    -e '/^set -g set-titles/p'
}

doctor_setup_recipe_lines() {
  doctor_set_lines | setup_recipe_from_lines
}

# The plugin loaded into this test's server, so doctor reports on a real installation.
loaded_server() {
  run "$PLUGIN_ROOT/tamagotchi.tmux"
  assert_success
}

@test "every tmux line the README tells you to paste is one tmux accepts" {
  # Sourced rather than eyeballed, the way a user would paste it into tmux.conf. A
  # README snippet tmux refuses is the kind of mistake that costs somebody an afternoon
  # and reads as the plugin being broken.
  local conf="$BATS_TEST_TMPDIR/readme.conf"
  readme_set_lines >"$conf"
  [ -s "$conf" ]

  run test_tmux source-file "$conf"
  assert_success

  # And what it told them to paste is what the entrypoint really exports, rather than a
  # plausible-looking format naming an option nothing sets.
  assert_contains "$(test_tmux show -gv window-status-format)" '@tama_icons' 'the README'
  assert_contains "$(test_tmux show -gv window-status-current-format)" '@tama_flag' 'the README'
  assert_equal "$(test_tmux show -gv set-titles-string)" '#S'
}

@test "every tmux line doctor prints appears in the README byte-for-byte" {
  loaded_server

  # The stronger claim, and the reason this file exists: a fourth copy of the
  # status-line and title recipes is only safe if it cannot drift from the copy the
  # command that diagnoses installations prints.
  #
  # A containment and not an equality, in this direction: the README also has lines
  # doctor has no reason to print — the TPM `set -g @plugin` line, and
  # `@tama_manage_hooks off` for a user taking the hooks over — while every line doctor
  # *does* print is a recipe the front door has to carry unchanged. So a change to
  # doctor's snippet fails here until the README follows it.
  local line from_readme found=0
  from_readme="$(readme_set_lines)"
  [ -n "$from_readme" ]

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    found=$((found + 1))
    assert_contains "$from_readme" "$line" 'the README' || return 1
  done < <(doctor_set_lines)

  # Nothing extracted would make the loop above assert nothing at all.
  [ "$found" -gt 0 ]
}

@test "the copied status and title recipes match doctor" {
  loaded_server

  local expected copy
  expected="$(doctor_setup_recipe_lines)"
  [ -n "$expected" ]
  for copy in \
    "$(help_set_lines | setup_recipe_from_lines)" \
    "$(demo_set_lines)" \
    "$(setup_recipe_lines "$README")"; do
    assert_equal "$copy" "$expected"
  done
}

@test "the backend title recipe matches doctor" {
  loaded_server

  assert_equal "$(setup_recipe_lines "$PLUGIN_ROOT/backends/README.md" | grep '^set -g set-titles')" \
    "$(doctor_setup_recipe_lines | grep '^set -g set-titles')"
}

@test "the on-select recipe the README hands a user is the one the plugin wires" {
  loaded_server

  # The README tells a user whose own mouse binding does not select a window to add this
  # line themselves, and calls it verbatim the plugin's own. tmux prints a hook array
  # back requoted, so this looks for the part of the recipe no requoting touches — the
  # same substring tamagotchi.tmux checks for when deciding a hook is already wired.
  local recipe='#{q:@tama_bin} on-select --window #{window_id}'
  grep -qF -- "$recipe" "$README" || {
    printf 'the README no longer carries the on-select recipe:\n%s\n' "$recipe" >&2
    return 1
  }

  test_tmux show-hooks -g | grep -qF -- "$recipe" || {
    printf 'the wired after-select-window hook is not the recipe the README prints:\n%s\n' \
      "$(test_tmux show-hooks -g | grep -F after-select-window)" >&2
    return 1
  }
}

@test "the README does not carry a third copy of the Claude Code hook block" {
  # doctor prints that block and checks a user's settings against the same list of
  # events, and tests/doctor.bats asserts it matches the integration README's copy. A
  # copy here would be a set of events nothing compares — so the README references one
  # of the two instead, and this is what keeps it that way.
  # The marker every entry of that block carries, and the one thing a pasted copy cannot
  # be written without. Naming an event — `tama hook claude-code Stop` — is not a copy of
  # the block and the README says one as an example of what `tama hook` is.
  refute_file_contains "$README" '"type": "command"'

  # Referencing it is the other half of the claim: a README with neither the block nor a
  # pointer to it leaves a Claude Code user with nowhere to go.
  grep -qF -- 'integrations/claude-code/README.md' "$README" || {
    printf 'the README points nowhere for the Claude Code hook block\n' >&2
    return 1
  }
}

@test "the minimum tmux version the README states is the one the plugin enforces" {
  # The version below which the entrypoint wires nothing at all lives in lib/version.sh,
  # which the tests never source (the seam is bin/tama). So it is read out of the file as
  # text — the one fact in the README that is a constant somewhere else and would
  # otherwise be bumped in the code with the front door still promising the old floor.
  local minimum
  minimum="$(sed -n "s/^TAMA_MIN_TMUX_VERSION='\([^']*\)'.*/\1/p" \
    "$PLUGIN_ROOT/lib/version.sh")"
  [ -n "$minimum" ]

  assert_contains "$(cat "$README")" "$minimum or newer" 'the README'
}

@test "every option the README names exists in this plugin" {
  # A renamed or invented option is prose a user cannot act on, and it looks exactly
  # like a bug in the plugin. Measured against the help text and the source together,
  # because a few of the names are exported by the entrypoint rather than documented as
  # settings — @tama_bin_dir is one.
  local known name
  known="$("$PLUGIN_ROOT/bin/tama" --help; cat \
    "$PLUGIN_ROOT/tamagotchi.tmux" \
    "$PLUGIN_ROOT"/lib/*.sh \
    "$PLUGIN_ROOT"/libexec/*)"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    assert_contains "$known" "$name" "the plugin (@ named in the README)" || return 1
  done < <(readme_option_names)
}

@test "every option the help documents appears in the README's option map" {
  # The other direction, and the one that catches the real failure mode: an option added
  # to the code and written up in `tama --help`, with the front door never hearing about
  # it. Only the ones help presents as `set -g @tama_…` — those are the settings; the
  # exported formats and pane options are not.
  local documented name readme_names
  documented="$("$PLUGIN_ROOT/bin/tama" --help |
    sed -n "s/^ *set -g \(@tama_[a-z_]*\).*/\1/p" | sort -u)"
  [ -n "$documented" ]
  readme_names="$(readme_option_names)"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    assert_contains "$readme_names" "$name" 'the README option map' || return 1
  done <<EOF
$documented
EOF
}

@test "the values the README says turn an option off are the ones the help names" {
  # A fourth list, and a list is the thing that rots silently. Both documents state the
  # flag vocabulary once, and neither may state it differently from the other.
  local from_readme
  from_readme="$(readme_off_spellings)"
  [ -n "$from_readme" ]

  assert_equal "$from_readme" "$(help_off_spellings)"
}

@test "the values the README says turn an option off really do" {
  # The claim worth making, and the one the comparison above cannot: the front door's
  # list measured against the plugin rather than against another document. Narrowing
  # what lib/options.sh accepts fails here, naming the spelling it dropped.
  loaded_server

  local spelling
  while IFS= read -r spelling; do
    [ -n "$spelling" ] || continue
    test_tmux set -g @tama_notifications "$spelling"

    run "$PLUGIN_ROOT/bin/tama" doctor
    assert_success || return 1
    assert_contains "$output" '@tama_notifications is off' \
      "doctor with @tama_notifications $spelling" || return 1
  done <<EOF
$(readme_off_spellings)
EOF

  # And the list the suites drive every boolean option against is that same list, so
  # the two documents cannot agree with each other while disagreeing with the tests.
  local expected
  expected="$(printf '%s\n' $TAMA_OFF_SPELLINGS | sort -u)"
  assert_equal "$(readme_off_spellings)" "$expected"
}

@test "the commands the README lists are the subcommands that exist" {
  # bin/tama dispatches by file name and keeps no list, so libexec/ is the only truth
  # about what exists. `version` is the one name the dispatcher owns itself, since it has
  # to answer before the tmux check.
  local existing listed
  existing="$( (
    find "$PLUGIN_ROOT/libexec" -type f -perm -u+x -exec basename {} \;
    printf 'version\n'
  ) | sort -u)"

  # Read out of the README's command table alone — a fenced code block elsewhere could
  # mention `tama doctor` without the table listing it. A row of that table leads with
  # one backticked bare name, or two of them paired with a slash where the pair is one
  # idea: `flag` / `unflag`.
  listed="$(grep -oE '^\| `[a-z-]+`( / `[a-z-]+`)? \|' "$README" |
    grep -oE '`[a-z-]+`' | tr -d '`' | sort -u)"

  assert_equal "$listed" "$existing"
}

# Every `@tama_…` name the README mentions, deduplicated. The trailing boundary keeps a
# name that is a prefix of another from being read as the longer one.
readme_option_names() {
  grep -oE '@tama_[a-z_]+' "$README" | sort -u
}

# The values each document says turn a flag option off, one per line, sorted. Both
# sentences are written so that the whole list sits on the line that says "turn it
# off" — backticked in the README, quoted in the help, which is each document's own
# way of marking a literal.
readme_off_spellings() {
  grep -F 'turn it off' "$README" | grep -oE '`[a-z0-9]+`' | tr -d '`' | sort -u
}

help_off_spellings() {
  "$PLUGIN_ROOT/bin/tama" --help | grep -F 'turn it off' |
    grep -oE "'[a-z0-9]+'" | tr -d "'" | sort -u
}

refute_file_contains() { # <file> <string>
  if grep -qF -- "$2" "$1"; then
    printf 'expected %s NOT to contain %s\n' "$1" "$2" >&2
    return 1
  fi
}

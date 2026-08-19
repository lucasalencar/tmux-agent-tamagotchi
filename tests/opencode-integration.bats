#!/usr/bin/env bats

bats_require_minimum_version 1.7.0

load helper

PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
OPENCODE_README="$PROJECT_ROOT/integrations/opencode/README.md"
OPENCODE_CONFIGURE="$PROJECT_ROOT/integrations/opencode/configure"

opencode_global_recipe() {
  sed -n '/^<!-- opencode-global-config:start -->$/,/^<!-- opencode-global-config:end -->$/p' \
    "$OPENCODE_README" |
    sed -n '/^```json$/,/^```$/p' |
    sed '1d;$d'
}

@test "the canonical OpenCode recipe is valid JSON with one absolute TypeScript entrypoint" {
  local recipe="$BATS_TEST_TMPDIR/opencode.json"
  opencode_global_recipe >"$recipe"

  run python3 - "$recipe" "$OPENCODE_README" <<'PY'
import json
import pathlib
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
documentation = " ".join(open(sys.argv[2], encoding="utf-8").read().split())
assert set(data) == {"$schema", "plugin"}
assert data["$schema"] == "https://opencode.ai/config.json"
assert len(data["plugin"]) == 1
entrypoint = data["plugin"][0]
assert pathlib.PurePosixPath(entrypoint).is_absolute()
placeholder = "/absolute/path/to/tmux-agent-tamagotchi"
assert entrypoint == f"{placeholder}/integrations/opencode/index.ts"
assert f"replacing the entire placeholder `{placeholder}`" in documentation
PY
  assert_success
}

@test "project documentation points to the one canonical OpenCode recipe" {
  run grep -F 'integrations/opencode/README.md' "$PROJECT_ROOT/README.md"
  assert_success

  run grep -F '(opencode/README.md)' "$PROJECT_ROOT/integrations/README.md"
  assert_success

  run grep -F 'opencode-global-config:start' "$PROJECT_ROOT/README.md" \
    "$PROJECT_ROOT/integrations/README.md"
  [ "$status" -ne 0 ]
}

@test "the OpenCode helper creates an idempotent global configuration" {
  local config="$BATS_TEST_TMPDIR/opencode.json"

  run "$OPENCODE_CONFIGURE" "$config"
  assert_success

  run "$OPENCODE_CONFIGURE" "$config"
  assert_success

  run jq -e --arg plugin "$PROJECT_ROOT/integrations/opencode/index.ts" \
    '.plugin == [$plugin]' "$config"
  assert_success
  [ -f "$config.backup" ]
}

@test "the OpenCode helper preserves settings and rejects malformed JSON safely" {
  local config="$BATS_TEST_TMPDIR/opencode.json"
  printf '%s\n' '{"theme":"tamagotchi","plugin":["existing.ts"]}' >"$config"

  run "$OPENCODE_CONFIGURE" "$config"
  assert_success
  run jq -e \
    '.theme == "tamagotchi" and (.plugin | index("existing.ts") != null)' \
    "$config"
  assert_success

  printf '%s\n' '{invalid' >"$config"
  run "$OPENCODE_CONFIGURE" "$config"
  [ "$status" -ne 0 ]
  run cat "$config"
  [ "$output" = '{invalid' ]
}

@test "CI validates OpenCode with pinned Bun without coupling the shell suite" {
  run python3 - "$PROJECT_ROOT/.github/workflows/ci.yml" "$PROJECT_ROOT/Makefile" <<'PY'
import re
import sys

workflow = open(sys.argv[1], encoding="utf-8").read()
makefile = open(sys.argv[2], encoding="utf-8").read()
match = re.search(r"(?ms)^  opencode:\n(?P<job>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)", workflow)
assert match, "missing independent opencode job"
job = match.group("job")
for expected in (
    "runs-on: ubuntu-24.04",
    "uses: oven-sh/setup-bun@v2",
    "bun-version: 1.3.14",
    "working-directory: integrations/opencode",
    "run: bun install --frozen-lockfile",
    "run: bun test",
    "run: bun run typecheck",
):
    assert expected in job, expected
assert "matrix:" not in job
assert not re.search(r"(?m)^\s*(?:lint|test|all|build).*\bbun\b", makefile)
PY
  assert_success
}

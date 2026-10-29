# Development entry points. CI runs exactly these targets.

# examples/ is in here because what ships as a documented example is code a user
# pastes a path to, and an example shellcheck never saw is one that breaks on them.
# examples/demo.tmux.conf is tmux configuration rather than shell and is not
# executable, so the find below leaves it alone.
SHELL_DIRS := $(wildcard bin lib libexec backends integrations examples tests)
SHELL_FILES := tamagotchi.tmux tests/helper.bash \
	$(shell find $(SHELL_DIRS) -path '*/node_modules' -prune -o \
		-type f ! -name '*.bats' \( -perm -u+x -o -name '*.sh' \) -print | sort)

.PHONY: all lint test test-shard doctor

all: lint test

# Every executable and library in the repo. The bats files are excluded on
# purpose: shellcheck cannot read bats' test syntax.
lint:
	shellcheck -x $(SHELL_FILES)

test:
	bats -r tests

# Sharded test run for CI parallelization:
# `make test-shard SHARD=1 SHARDS=2` runs every SHARDS-th file, so N CI jobs
# on separate VMs each run ~1/N of the suite serially. Serial within a shard
# on purpose: no extra dependency (GNU parallel/rush), and no shared-CPU
# timing flakes — parallelism comes from separate machines, not threads.
# Defaults (SHARD=1, SHARDS=1) run the whole suite, same as `make test`.
SHARD ?= 1
SHARDS ?= 1
test-shard:
	files="$$(ls tests/*.bats | sort | awk -v s="$(SHARD)" -v n="$(SHARDS)" '(NR-1) % n == (s-1)')"; bats $$files

doctor:
	@tests/ci-doctor

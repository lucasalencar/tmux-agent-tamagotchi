# Development entry points. CI runs exactly these targets.

# examples/ is in here because what ships as a documented example is code a user
# pastes a path to, and an example shellcheck never saw is one that breaks on them.
# examples/demo.tmux.conf is tmux configuration rather than shell and is not
# executable, so the find below leaves it alone.
SHELL_DIRS := $(wildcard bin lib libexec backends integrations examples tests/fixtures)
SHELL_FILES := tamagotchi.tmux tests/helper.bash \
	$(shell find $(SHELL_DIRS) -path '*/node_modules' -prune -o \
		-type f \( -perm -u+x -o -name '*.sh' \) -print | sort)

.PHONY: all lint test doctor

all: lint test

# Every executable and library in the repo. The bats files are excluded on
# purpose: shellcheck cannot read bats' test syntax.
lint:
	shellcheck -x $(SHELL_FILES)

test:
	bats -r tests

doctor:
	@set -e; \
	socket="tama-doctor-$$$$-$$(date +%s)"; \
	trap 'tmux -L "$$socket" kill-server >/dev/null 2>&1 || true' EXIT HUP INT TERM; \
	tmux -L "$$socket" -f /dev/null new-session -d -s tama-doctor </dev/null; \
	tmux -L "$$socket" set -g @tama_backend ''; \
	TAMA_TMUX_ARGS="-L $$socket" ./tamagotchi.tmux; \
	TAMA_TMUX_ARGS="-L $$socket" ./bin/tama doctor; \
	tmux -L "$$socket" kill-server; \
	trap - EXIT HUP INT TERM

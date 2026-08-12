# Development entry points. CI runs exactly these targets.

SHELL_DIRS := $(wildcard bin lib libexec backends integrations tests/fixtures)
SHELL_FILES := tamagotchi.tmux \
	$(shell find $(SHELL_DIRS) -type f \( -perm -u+x -o -name '*.sh' \) | sort)

.PHONY: all lint test

all: lint test

# Every executable and library in the repo. The bats files are excluded on
# purpose: shellcheck cannot read bats' test syntax.
lint:
	shellcheck -x $(SHELL_FILES)

test:
	bats tests

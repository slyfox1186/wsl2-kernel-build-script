SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

SCRIPTS := build-kernel.sh wslconfig-generator.sh tests/run-tests.sh

.PHONY: check lint format test list-versions

# Offline gate: lint plus the test suite.
check: lint test

lint:
	shellcheck -x $(SCRIPTS)
	shfmt --diff $(SCRIPTS)

format:
	shfmt --write $(SCRIPTS)

test:
	bash tests/run-tests.sh

# Needs network access to github.com.
list-versions:
	bash build-kernel.sh --list-versions

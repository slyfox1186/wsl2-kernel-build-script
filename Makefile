SHELL := bash

.PHONY: lint test smoke

lint:
	shellcheck build-kernel.sh wslconfig-generator.sh

test: lint
	bash -n build-kernel.sh
	bash -n wslconfig-generator.sh

smoke: test
	bash build-kernel.sh --help >/dev/null
	bash build-kernel.sh --script-version >/dev/null
	bash wslconfig-generator.sh --help >/dev/null
	bash wslconfig-generator.sh --examples >/dev/null
	bash wslconfig-generator.sh --output /tmp/wslconfig.test --memory 8 --swap 2 --processors 4 >/dev/null
	test -f /tmp/wslconfig.test
	rm -f /tmp/wslconfig.test

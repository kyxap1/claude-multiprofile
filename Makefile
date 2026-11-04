# 3.2 matches macOS /bin/bash.
BASH_VERSIONS := 3.2 5
SHELLCHECK := koalaman/shellcheck:v0.11.0
SCRIPTS := claude-profiles.sh bin/claude statusline.sh test/test.sh

.PHONY: check test lint

check: lint test

test:
	@set -e; for v in $(BASH_VERSIONS); do \
	  docker build -q --build-arg BASH_VERSION=$$v -t claude-multiprofile-test:$$v -f test/Dockerfile . >/dev/null; \
	  docker run --rm claude-multiprofile-test:$$v; \
	done

lint:
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt $(SHELLCHECK) $(SCRIPTS)

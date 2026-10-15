.PHONY: test build app dmg audit install install-source uninstall clean dev dev-stop

VERSION ?= 0.6.0
ARCHS ?= $(shell uname -m)

# Tests run with a throwaway home so no test can read or write the real LocalHistory folder.
test:
	@home=$$(mktemp -d /tmp/goalong-test-XXXXXX); \
	GOALONG_TEST_HOME="$$home" CFFIXED_USER_HOME="$$home" xcrun swift test; status=$$?; \
	rm -rf "$$home"; exit $$status
	./scripts/test_isolated_home.sh

build:
	xcrun swift build -c release --product LocalHistory

app:
	LOCALHISTORY_VERSION="$(VERSION)" LOCALHISTORY_ARCHS="$(ARCHS)" ./scripts/build_app.sh

dev:
	./scripts/dev_app.sh dev $(or $(DATA),isolated)

dev-stop:
	./scripts/dev_app.sh stop

dmg: app
	./scripts/package_release.sh

audit:
	./scripts/audit_privacy_boundaries.sh

install:
	./install.sh

install-source:
	./install.sh --source

uninstall:
	./uninstall.sh

clean:
	rm -rf .build dist

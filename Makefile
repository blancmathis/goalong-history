.PHONY: test build app dmg audit sparkle-keys install install-source uninstall clean

VERSION ?= 0.4.0
ARCHS ?= $(shell uname -m)

test:
	xcrun swift test

build:
	xcrun swift build -c release --product LocalHistory

app:
	LOCALHISTORY_VERSION="$(VERSION)" LOCALHISTORY_ARCHS="$(ARCHS)" ./scripts/build_app.sh

dmg: app
	./scripts/package_release.sh

audit:
	./scripts/audit_privacy_boundaries.sh

sparkle-keys:
	./scripts/setup_sparkle_keys.sh

install:
	./install.sh

install-source:
	./install.sh --source

uninstall:
	./uninstall.sh

clean:
	rm -rf .build dist

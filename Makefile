.PHONY: test build app dmg audit install install-source uninstall clean dev dev-stop dev-status

VERSION ?= 0.6.0
ARCHS ?= $(shell uname -m)

# Tests run with a throwaway home so no test can read or write the real LocalHistory folder.
test:
	@home=$$(mktemp -d /tmp/goalong-test-XXXXXX); \
	GOALONG_TEST_HOME="$$home" CFFIXED_USER_HOME="$$home" xcrun swift test; status=$$?; \
	rm -rf "$$home"; exit $$status
	./scripts/test_isolated_home.sh
	bash scripts/test_dev_app.sh

build:
	xcrun swift build -c release --product LocalHistory

app:
	LOCALHISTORY_VERSION="$(VERSION)" LOCALHISTORY_ARCHS="$(ARCHS)" ./scripts/build_app.sh

# Goalong Dev runs beside the installed Goalong (see CLAUDE.md). Settings, read from the make
# command line only (a shell-wide DATA or SERVER is ignored):
# DATA=clone|keep|fresh BLOCKING=empty|copy SERVER=off|on NO_LAUNCH=1 DEV_APP_DIR=/abs/dir
goalong_dev_setting = $(if $(filter command line,$(origin $(1))),$($(1)))
GOALONG_DEV_ENV = GOALONG_DEV_DATA="$(call goalong_dev_setting,DATA)" \
	GOALONG_DEV_BLOCKING="$(call goalong_dev_setting,BLOCKING)" \
	GOALONG_DEV_SERVER="$(call goalong_dev_setting,SERVER)" \
	GOALONG_DEV_NO_LAUNCH="$(call goalong_dev_setting,NO_LAUNCH)" \
	GOALONG_DEV_APP_DIR="$(call goalong_dev_setting,DEV_APP_DIR)"

dev:
	$(GOALONG_DEV_ENV) ./scripts/dev_app.sh dev

dev-stop:
	$(GOALONG_DEV_ENV) ./scripts/dev_app.sh stop

dev-status:
	$(GOALONG_DEV_ENV) ./scripts/dev_app.sh status

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

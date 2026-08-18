.PHONY: test build audit install uninstall package

test:
	swift test

build:
	swift build -c release --product LocalHistory

audit:
	./scripts/audit_privacy_boundaries.sh

install:
	./install.sh

uninstall:
	./uninstall.sh

package:
	cd .. && zip -r LocalHistory-macOS-v0.3.2.zip LocalHistory \
		-x 'LocalHistory/.build/*' 'LocalHistory/.git/*' 'LocalHistory/**/__pycache__/*' 'LocalHistory/**/*.pyc'

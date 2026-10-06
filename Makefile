# The Command Line Tools ship the Swift Testing macros in a subfolder SwiftPM doesn't search.
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: run demo test app install clean

run:
	swift run Zugbar

demo:
	swift run Zugbar --demo

test:
	swift test $(TEST_FLAGS)

app:
	./scripts/bundle.sh

install: app
	rm -rf /Applications/Zugbar.app
	cp -R build/Zugbar.app /Applications/

clean:
	rm -rf .build build

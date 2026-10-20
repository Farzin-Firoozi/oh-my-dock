.PHONY: generate test build cli cli-smoke dockutil hooks release verify-release

generate:
	xcodegen generate

test: generate
	cd Packages/OhMyDockCore && swift test
	xcodebuild -project OhMyDock.xcodeproj -scheme OhMyDock -configuration Debug -derivedDataPath build test
	@if command -v mandoc >/dev/null 2>&1; then mandoc -Tlint CLI/ohmydock.1; fi
	./scripts/test-verify-release.sh
	./packaging/homebrew-tap/test-cask.sh
	$(MAKE) cli-smoke

build: generate
	xcodebuild -project OhMyDock.xcodeproj -scheme OhMyDock -configuration Debug -derivedDataPath build build

cli: generate
	xcodebuild -project OhMyDock.xcodeproj -scheme ohmydock -configuration Debug -derivedDataPath build build

cli-smoke: cli
	./scripts/cli-smoke.sh

dockutil:
	./scripts/build-dockutil.sh

hooks:
	git config core.hooksPath .githooks

release:
	./scripts/release.sh

# Usage: make verify-release APP=path/to/OhMyDock.app (defaults to the Release build)
APP ?= build/Build/Products/Release/OhMyDock.app
verify-release:
	./scripts/verify-release.sh "$(APP)"

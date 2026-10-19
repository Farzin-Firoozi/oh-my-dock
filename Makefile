.PHONY: generate test build dockutil hooks release verify-release

generate:
	xcodegen generate

test: generate
	cd Packages/OhMyDockCore && swift test
	xcodebuild -project OhMyDock.xcodeproj -scheme OhMyDock -configuration Debug -derivedDataPath build test

build: generate
	xcodebuild -project OhMyDock.xcodeproj -scheme OhMyDock -configuration Debug -derivedDataPath build build

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

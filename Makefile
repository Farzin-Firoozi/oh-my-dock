.PHONY: generate test build dockutil hooks

generate:
	xcodegen generate

test:
	cd Packages/OhMyDockCore && swift test

build: generate
	xcodebuild -project OhMyDock.xcodeproj -scheme OhMyDock -configuration Debug -derivedDataPath build build

dockutil:
	./scripts/build-dockutil.sh

hooks:
	git config core.hooksPath .githooks

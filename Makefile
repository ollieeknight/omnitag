.DEFAULT_GOAL := help
APP := OmniTag
BUNDLE := .build/$(APP).app
CONFIG ?= debug

help: ## List targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'

test: ## Run the test suite
	swift test

build: ## Build all targets
	swift build -c $(CONFIG)

run: ## Build and launch the app
	swift run OmniTagApp

app: build ## Assemble a double-clickable OmniTag.app bundle
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp .build/$(CONFIG)/OmniTagApp $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@codesign --force --deep --sign - $(BUNDLE)
	@echo "built $(BUNDLE)"

install: app ## Symlink the built app into /Applications
	@ln -sfn "$(PWD)/$(BUNDLE)" /Applications/$(APP).app
	@echo "linked /Applications/$(APP).app -> $(BUNDLE)"

xcode: ## Generate OmniTag.xcodeproj and open it
	@xcodegen generate
	@open OmniTag.xcodeproj

xcbuild: ## Build the app target the way Xcode does
	@xcodegen generate
	xcodebuild -project OmniTag.xcodeproj -scheme OmniTag -destination 'platform=macOS' build | xcbeautify

xctest: ## Run the suite through the Xcode scheme
	@xcodegen generate
	xcodebuild -project OmniTag.xcodeproj -scheme OmniTag -destination 'platform=macOS' test | xcbeautify

lint: ## Warnings-as-signal build
	swift build -Xswiftc -warnings-as-errors

clean: ## Remove build products
	rm -rf .build

.PHONY: help test build run app install xcode xcbuild xctest lint clean

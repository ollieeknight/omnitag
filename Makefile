.DEFAULT_GOAL := help
APP := OmniTag
BUNDLE := .build/$(APP).app
CONFIG ?= debug

help: ## List targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-12s %s\n", $$1, $$2}'

test: sync-xcode ## Run the test suite
	swift test

build: sync-xcode ## Build all targets
	swift build -c $(CONFIG)

run: sync-xcode ## Build and launch the app
	swift run OmniTagApp

sync-xcode: ## Regenerate OmniTag.xcodeproj so Xcode's index never goes stale
	@xcodegen generate --quiet

hooks: ## One-time setup: enable the repo's git hooks (auto-regen after checkout/merge)
	git config core.hooksPath .githooks
	@echo "git hooks enabled — OmniTag.xcodeproj regenerates after checkout/merge"

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

xcode: sync-xcode ## Generate OmniTag.xcodeproj and open it
	@open OmniTag.xcodeproj

xcbuild: sync-xcode ## Build the app target the way Xcode does
	xcodebuild -project OmniTag.xcodeproj -scheme OmniTag -destination 'platform=macOS' build | xcbeautify

xctest: sync-xcode ## Run the suite through the Xcode scheme
	xcodebuild -project OmniTag.xcodeproj -scheme OmniTag -destination 'platform=macOS' test | xcbeautify

lint: sync-xcode ## Warnings-as-errors build, plus swiftformat/swiftlint checks
	swift build -Xswiftc -warnings-as-errors
	swiftformat --lint .
	swiftlint lint

format: ## Auto-fix formatting and lint violations
	swiftformat .
	swiftlint --fix

audit: ## Dead-code scan (periphery) — see note in .periphery.yml if it errors
	periphery scan

check: lint audit test ## Everything: lint, dead-code audit, tests

clean: ## Remove build products
	rm -rf .build

.PHONY: help test build run sync-xcode hooks app install xcode xcbuild xctest lint format audit check clean

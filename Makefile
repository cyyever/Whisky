SHELL := /bin/bash
SCRIPTS_DIR := $(CURDIR)/scripts
WINE_SRC := $(CURDIR)/vendor/wine
X86_BREW := $(CURDIR)/vendor/homebrew-x86/bin/brew
WINE_BIN := $(HOME)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64
APP_BUILD := $(HOME)/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products/Debug/Whisky.app

.PHONY: all app wine setup-x86-brew clean clean-wine help

all: app wine  ## Build everything (app + Wine)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# === x86_64 Homebrew ===

setup-x86-brew: $(X86_BREW)  ## Install x86_64 Homebrew and Wine build deps

$(X86_BREW):
	$(SCRIPTS_DIR)/setup-x86-brew.sh

# === Wine ===

wine: $(WINE_BIN)  ## Build Wine 11.5 x86_64 and install to Libraries

$(WINE_BIN): $(X86_BREW) $(WINE_SRC)/configure
	$(SCRIPTS_DIR)/build-wine-x86.sh

clean-wine:  ## Remove Wine build artifacts (keeps installed Wine)
	rm -rf $(WINE_SRC)/build-x86_64
	rm -rf $(WINE_SRC)/build

# === Whisky App ===

app:  ## Build the Whisky macOS app
	xcodebuild -project Whisky.xcodeproj \
		-scheme Whisky \
		-configuration Debug \
		build \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

app-release:  ## Build the Whisky app in Release mode
	xcodebuild -project Whisky.xcodeproj \
		-scheme Whisky \
		-configuration Release \
		build \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

run: app  ## Build and run Whisky
	@open $$(ls -dt $(HOME)/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products/Debug/Whisky.app | head -1)

# === Submodule ===

submodule:  ## Init/update git submodules
	git submodule update --init --recursive

# === Clean ===

clean: clean-wine  ## Remove all build artifacts
	xcodebuild -project Whisky.xcodeproj -scheme Whisky clean 2>/dev/null || true
	rm -rf $(WINE_SRC)/build-x86_64
	rm -rf $(WINE_SRC)/build

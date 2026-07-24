SHELL := /bin/bash
SCRIPTS_DIR := $(CURDIR)/scripts
WINE_SRC := $(CURDIR)/vendor/wine
X86_BREW := $(CURDIR)/vendor/homebrew-x86/bin/brew
WINE_STAMP := $(CURDIR)/vendor/.wine-installed
APP_PRODUCTS := $(HOME)/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products

XCODEBUILD := xcodebuild -project Whisky.xcodeproj -scheme Whisky
CODESIGN_OFF := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

.PHONY: all help setup-x86-brew wine wine-debug clean-wine steam-helper \
        dxmt dxvk app app-release run submodule clean

all: app wine steam-helper  ## Build everything (app + Wine + Steam helper)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# === x86_64 Homebrew ===

setup-x86-brew: $(X86_BREW)  ## Install x86_64 Homebrew and Wine build deps

$(X86_BREW):
	$(SCRIPTS_DIR)/setup-x86-brew.sh

# === Wine ===

wine: $(WINE_STAMP)  ## Build Wine x86_64 and install to Libraries

$(WINE_STAMP): $(X86_BREW) $(WINE_SRC)/configure $(wildcard $(CURDIR)/patches/wine/*.patch)
	$(SCRIPTS_DIR)/build-wine-x86.sh
	@touch $@

wine-debug:  ## Reinstall Wine keeping PE debug info (for winedbg sessions)
	WHISKY_WINE_BUILD=debug $(SCRIPTS_DIR)/build-wine-x86.sh
	@touch $(WINE_STAMP)

clean-wine:  ## Remove Wine build artifacts (keeps installed Wine)
	rm -rf $(WINE_SRC)/build-x86_64 $(WINE_SRC)/build
	rm -f $(WINE_STAMP)

# === Steam helper ===

steam-helper:  ## Build the Steam webhelper wrapper (fixes the black Steam window)
	$(SCRIPTS_DIR)/build-webhelper-wrapper.sh

# === DXMT (Metal D3D11) ===

dxmt: wine  ## Build DXMT from source and install into Wine (needs full Xcode + llvm@15)
	$(SCRIPTS_DIR)/build-dxmt.sh

# === DXVK (D3D9 on KosmicKrisp) ===

dxvk:  ## Build DXVK d3d9.dll (win32 + win64) and install into Libraries/DXVK
	$(SCRIPTS_DIR)/build-dxvk.sh

# === Whisky App ===

app:  ## Build the Whisky macOS app (Debug)
	$(XCODEBUILD) -configuration Debug build $(CODESIGN_OFF)

app-release:  ## Build the Whisky app (Release)
	$(XCODEBUILD) -configuration Release build $(CODESIGN_OFF)

run: app  ## Build and run Whisky
	@open $$(ls -dt $(APP_PRODUCTS)/Debug/Whisky.app | head -1)

# === Submodule / clean ===

submodule:  ## Init/update git submodules
	git submodule update --init --recursive

clean: clean-wine  ## Remove all build artifacts
	$(XCODEBUILD) clean 2>/dev/null || true

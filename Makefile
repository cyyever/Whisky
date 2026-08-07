SHELL := /bin/bash
SCRIPTS_DIR := $(CURDIR)/scripts
WINE_SRC := $(CURDIR)/vendor/proton-wine
X86_BREW := $(CURDIR)/vendor/homebrew-x86/bin/brew
WINE_STAMP := $(CURDIR)/vendor/.proton-installed
APP_PRODUCTS := $(HOME)/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products

XCODEBUILD := xcodebuild -project Whisky.xcodeproj -scheme Whisky
CODESIGN_OFF := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

.PHONY: all help setup-x86-brew proton proton-debug clean-proton \
        dxmt dxvk proxychains app app-release install-app run submodule clean check-proton-src

all: app proton  ## Build everything (app + Proton)

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# === x86_64 Homebrew ===

setup-x86-brew: $(X86_BREW)  ## Install x86_64 Homebrew and Wine build deps

$(X86_BREW):
	$(SCRIPTS_DIR)/setup-x86-brew.sh

# === Proton (the shipped Wine backend) ===

proton: $(WINE_STAMP)  ## Build Proton x86_64 and install to Libraries/Wine

$(WINE_STAMP): $(X86_BREW) $(wildcard $(CURDIR)/patches/proton-wine/*.patch) | check-proton-src
	$(SCRIPTS_DIR)/build-proton-x86.sh
	@touch $@

# vendor/proton-wine is gitignored (laid down from a tarball, not a submodule), so
# guard the build with a clear message instead of make's cryptic "No rule to make
# target '.../configure'" when the source tree is absent on a fresh clone.
check-proton-src:
	@test -f "$(WINE_SRC)/configure" || { \
		echo "ERROR: Proton source missing at $(WINE_SRC)"; \
		echo "       It is gitignored (not a submodule). Lay down the proton-wine"; \
		echo "       source there first — see the Proton section in CLAUDE.md."; \
		exit 1; }

proton-debug:  ## Reinstall Proton keeping PE debug info (for winedbg sessions)
	WHISKY_WINE_BUILD=debug $(SCRIPTS_DIR)/build-proton-x86.sh
	@touch $(WINE_STAMP)

clean-proton:  ## Remove Proton build artifacts (keeps installed Wine)
	rm -rf $(WINE_SRC)/build
	rm -f $(WINE_STAMP)

# === DXMT (Metal D3D11) ===

dxmt: proton  ## Build DXMT from source and install into Wine (needs full Xcode + llvm@15)
	$(SCRIPTS_DIR)/build-dxmt.sh

# === DXVK (D3D9 on KosmicKrisp) ===

dxvk:  ## Build DXVK d3d9.dll (win32 + win64) and install into Libraries/DXVK
	$(SCRIPTS_DIR)/build-dxvk.sh

proxychains:  ## Build x86_64 proxychains-ng into Libraries/ProxyChains (routes Steam through the system SOCKS proxy)
	$(SCRIPTS_DIR)/build-proxychains.sh

# === Whisky App ===

app: ## Build the Whisky macOS app (Debug) and install it over /Applications/Whisky.app
	$(XCODEBUILD) -configuration Debug build $(CODESIGN_OFF)
	@$(MAKE) --no-print-directory install-app CONFIG=Debug

app-release: ## Build the Whisky app (Release) and install it over /Applications/Whisky.app
	$(XCODEBUILD) -configuration Release build $(CODESIGN_OFF)
	@$(MAKE) --no-print-directory install-app CONFIG=Release

# Replace the installed app with what we just built. Without this the build
# lands only in DerivedData while Dock/Spotlight keep launching whatever is in
# /Applications -- and a stale one is invisible: it runs, it opens bottles, it
# just carries different code. That cost a debugging session where two builds
# were compared against each other without either being identified, and the
# giveaway was a wineserver environment containing WINEMSYNC_NO_ANON_AUTOEVENT,
# a variable deleted from the tree weeks earlier.
install-app:
	@set -e; \
	built=$$(ls -dt $(APP_PRODUCTS)/$(CONFIG)/Whisky.app 2>/dev/null | head -1); \
	[ -n "$$built" ] || { echo "ERROR: no $(CONFIG) Whisky.app under $(APP_PRODUCTS)" >&2; exit 1; }; \
	if pgrep -f '/Applications/Whisky.app/Contents/MacOS/Whisky' >/dev/null; then \
		echo "=== Quitting the running Whisky before replacing it ==="; \
		osascript -e 'tell application "Whisky" to quit' >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5; do \
			pgrep -f '/Applications/Whisky.app/Contents/MacOS/Whisky' >/dev/null || break; \
			sleep 1; \
		done; \
	fi; \
	rm -rf /Applications/Whisky.app; \
	cp -R "$$built" /Applications/Whisky.app; \
	echo "=== Installed $(CONFIG) build to /Applications/Whisky.app ==="

run: app  ## Build, install and run Whisky
	@open /Applications/Whisky.app

# === Submodule / clean ===

submodule:  ## Init/update git submodules
	git submodule update --init --recursive

clean: clean-proton  ## Remove all build artifacts
	$(XCODEBUILD) clean 2>/dev/null || true

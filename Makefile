SHELL := /bin/bash
SCRIPTS_DIR := $(CURDIR)/scripts
WINE_SRC := $(CURDIR)/vendor/proton-wine
X86_BREW := $(CURDIR)/vendor/homebrew-x86/bin/brew
WINE_STAMP := $(CURDIR)/vendor/.proton-installed
APP_PRODUCTS := $(HOME)/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products

# xcodebuild needs a full Xcode; `xcode-select -p` can point at a Command Line
# Tools install, where it refuses to run at all. Prefer the active dir when it
# works, fall back to Xcode.app -- via the environment, never `xcode-select -s`,
# which needs sudo and would change the machine globally. (lib/common.sh does
# the same for the Wine build, which needs it for a different reason: an x86_64
# xcrun cannot load a CLT libxcrun.)
DEVELOPER_DIR ?= $(shell xcodebuild -version >/dev/null 2>&1 && xcode-select -p || echo /Applications/Xcode.app/Contents/Developer)
export DEVELOPER_DIR

XCODEBUILD := xcodebuild -project Whisky.xcodeproj -scheme Whisky
CODESIGN_OFF := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

.PHONY: all help setup-x86-brew proton proton-debug clean-proton \
        dxmt dxvk proxychains app app-release install-app lint format lint-swiftlint run submodule clean check-proton-src

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
	sha=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown); \
	git diff --quiet 2>/dev/null || sha="$$sha-dirty"; \
	plist=/Applications/Whisky.app/Contents/Info.plist; \
	/usr/libexec/PlistBuddy -c "Add :WhiskyBuildSHA string $$sha" "$$plist" >/dev/null 2>&1 || \
		/usr/libexec/PlistBuddy -c "Set :WhiskyBuildSHA $$sha" "$$plist"; \
	stamp=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
	/usr/libexec/PlistBuddy -c "Add :WhiskyBuildDate string $$stamp" "$$plist" >/dev/null 2>&1 || \
		/usr/libexec/PlistBuddy -c "Set :WhiskyBuildDate $$stamp" "$$plist"; \
	echo "=== Installed $(CONFIG) build ($$sha, $$stamp) to /Applications/Whisky.app ==="

# Lint is deliberately NOT a build phase. It used to be one, and when SwiftLint
# crashed (sourcekitd fails to load under a Command Line Tools developer dir) it
# failed a build whose compile had succeeded -- taking install-app down with it.
# A static check should not be able to veto a working build.
#
# SwiftLint rather than swift-format: swift-format's noisiest diagnostics
# (Indentation, AddLines, LineLength) come from its pretty-printer, not from its
# rule set, so they cannot be switched off -- it reports ~280 layout diffs
# against this hand-formatted tree. It is a formatter first; adopting it means
# reformatting the whole tree, which is a separate decision.
lint:  ## Lint the Swift sources with swift-format (never runs during a build)
	@swift format lint --strict -r Whisky WhiskyKit && echo "swift-format: clean"

format:  ## Reformat the Swift sources in place (swift-format)
	@swift format --in-place -r Whisky WhiskyKit && echo "swift-format: reformatted"

lint-swiftlint:  ## Optional deeper pass; SwiftLint is unstable here (sourcekitd)
	@swiftlint --strict || echo "NOTE: swiftlint failed or crashed -- not a build gate"


run: app  ## Build, install and run Whisky
	@open /Applications/Whisky.app

# === Submodule / clean ===

submodule:  ## Init/update git submodules
	git submodule update --init --recursive

clean: clean-proton  ## Remove all build artifacts
	$(XCODEBUILD) clean 2>/dev/null || true

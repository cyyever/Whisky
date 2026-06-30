#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
X86_BREW_HOME="$PROJECT_DIR/vendor/homebrew-x86"

echo "=== Installing x86_64 Homebrew to $X86_BREW_HOME ==="
mkdir -p "$(dirname "$X86_BREW_HOME")"
if [ ! -f "$X86_BREW_HOME/bin/brew" ]; then
    git clone https://mirrors.ustc.edu.cn/brew.git "$X86_BREW_HOME"
else
    echo "Already installed, updating..."
    cd "$X86_BREW_HOME" && git pull
fi

export HOMEBREW_BREW_GIT_REMOTE=https://mirrors.ustc.edu.cn/brew.git
export HOMEBREW_CORE_GIT_REMOTE=https://mirrors.ustc.edu.cn/homebrew-core.git
export HOMEBREW_BOTTLE_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles
export HOMEBREW_API_DOMAIN=https://mirrors.ustc.edu.cn/homebrew-bottles/api

echo "=== Installing Wine build dependencies (x86_64) ==="
# Only libraries linked into x86_64 Wine need to be x86_64. Build tools (bison,
# pkg-config, the mingw-w64 cross-compiler) come from the ARM64 brew — see
# build-wine-x86.sh.
arch -x86_64 "$X86_BREW_HOME/bin/brew" install freetype gettext gnutls sdl2 molten-vk

echo "=== Done! ==="
echo "x86_64 Homebrew: $X86_BREW_HOME/bin/brew"
echo "ARM Homebrew untouched at /opt/homebrew/bin/brew"

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
arch -x86_64 "$X86_BREW_HOME/bin/brew" install bison pkg-config freetype gettext gnutls gstreamer sdl2 molten-vk mingw-w64

echo "=== Done! ==="
echo "x86_64 Homebrew: $X86_BREW_HOME/bin/brew"
echo "ARM Homebrew untouched at /opt/homebrew/bin/brew"

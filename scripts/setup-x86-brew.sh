#!/bin/bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

echo "=== Installing x86_64 Homebrew to $X86_BREW_HOME ==="
mkdir -p "$(dirname "$X86_BREW_HOME")"
if [ ! -f "$X86_BREW_HOME/bin/brew" ]; then
    git clone https://mirrors.ustc.edu.cn/brew.git "$X86_BREW_HOME"
else
    echo "Already installed, updating..."
    cd "$X86_BREW_HOME" && git pull
fi

export_homebrew_mirrors

echo "=== Installing Wine build dependencies (x86_64) ==="
# Only libraries linked into x86_64 Wine need to be x86_64. Build tools (bison,
# pkg-config, the mingw-w64 cross-compiler) come from the ARM64 brew — see
# build-proton-x86.sh.
arch -x86_64 "$X86_BREW_HOME/bin/brew" install freetype gettext gnutls sdl2 molten-vk

echo "=== Done! ==="
echo "x86_64 Homebrew: $X86_BREW_HOME/bin/brew"
echo "ARM Homebrew untouched at /opt/homebrew/bin/brew"

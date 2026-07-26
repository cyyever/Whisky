#!/bin/bash
set -e

# Build proxychains-ng as an x86_64 dylib and install it into Libraries/ProxyChains.
#
# Whisky DYLD-injects this into the (Rosetta, x86_64) wine process — see
# SystemProxy.socksProxyEnvironment — to route Wine's raw sockets through the
# system SOCKS proxy. This is the only way to carry Steam's CM/connectivity,
# which use raw SteamNetworkingSockets that bypass every HTTP proxy (env AND
# Windows registry) and go direct -> reset on a filtering network. proxychains hooks connect() at
# the socket layer, so the SOCKS tunnel catches them; short of a full TUN VPN
# it's the only per-app option. The generated proxychains.conf leaves proxy_dns
# OFF (its fake-IP remap breaks Steam's manifest HTTPS): DNS resolves directly,
# only TCP is tunneled.
#
# Must be x86_64: Wine runs under Rosetta, so DYLD_INSERT_LIBRARIES needs the
# x86_64 slice to load into that process.

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools git clang lipo make

SRC="$PROJECT_DIR/vendor/proxychains-ng"
REPO="https://github.com/rofl0r/proxychains-ng"
# Pinned like every other vendored dependency — bump deliberately, not implicitly.
PIN="v4.17"

if [ ! -d "$SRC/.git" ]; then
    echo "=== Cloning proxychains-ng $PIN ==="
    git clone --branch "$PIN" --depth 1 "$REPO" "$SRC"
else
    git -C "$SRC" checkout -q "$PIN" 2>/dev/null \
        || echo "note: $SRC is not at $PIN; 'rm -rf $SRC' then rebuild to re-pin"
fi

echo "=== Building proxychains-ng (x86_64) from $SRC ==="
cd "$SRC"
./configure >/dev/null
make -s clean >/dev/null 2>&1 || true
# -Wno-error=incompatible-function-pointer-types: v4.17's freeaddrinfo hook has a
# void-vs-int return-type mismatch that newer clang promotes to an error; the
# return value is unused, so it's benign — keep it a warning so the pin builds.
make -s CC="clang -arch x86_64 -Wno-error=incompatible-function-pointer-types"

DYLIB="$SRC/libproxychains4.dylib"
if ! lipo -archs "$DYLIB" 2>/dev/null | grep -qw x86_64; then
    echo "ERROR: libproxychains4.dylib is not x86_64 (needed for the Rosetta wine process)" >&2
    exit 1
fi

echo "=== Installing into Libraries/ProxyChains ==="
mkdir -p "$INSTALL_DIR/ProxyChains"
cp "$DYLIB" "$INSTALL_DIR/ProxyChains/libproxychains4.dylib"

echo "=== Done! ==="
file "$INSTALL_DIR/ProxyChains/libproxychains4.dylib"

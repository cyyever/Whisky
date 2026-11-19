#!/bin/bash
set -euo pipefail

# MetalFX's Neural Engine compiler needs a code identity for both Wine launchers.
# Sign after install-name/loader edits and verify before publishing the staged tree.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <Wine root>" >&2
    exit 2
fi
for relative in bin/wine lib/wine/x86_64-unix/wine; do
    launcher="$1/$relative"
    if [ ! -f "$launcher" ]; then
        echo "ERROR: missing Wine launcher: $launcher" >&2
        exit 1
    fi
    codesign --force --sign - --identifier org.whisky.wine --timestamp=none "$launcher"
    codesign --verify --strict "$launcher"
done

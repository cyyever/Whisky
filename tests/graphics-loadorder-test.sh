#!/usr/bin/env bash
#
# graphics-loadorder-test — assert nothing in a bottle can displace the graphics
# builtins we ship.
#
# This tree provides d3d9/d3d8 (DXVK), d3d11/d3d10core/dxgi (DXMT), vulkan-1
# (winevulkan) and winemetal as Wine *builtins*, and patch 0017 resolves those
# basenames to LO_BUILTIN ahead of the DllOverrides registry. Two kinds of
# leftover state used to defeat that, and both were written by the same retired
# feature -- Whisky's old per-game DXVK install, which dropped a copy of
# d3d9.dll next to the game's .exe and set "d3d9"="native" in the bottle
# registry so the copy would be picked up.
#
#   1. The registry value. It outlives the feature that wrote it, and because
#      our DXVK carries the "Wine builtin DLL" signature, "native" does not
#      select a different provider -- it matches *nothing*. Super Street Fighter
#      IV died on exit c0000135 (STATUS_DLL_NOT_FOUND) with a perfectly good
#      d3d9.dll in system32, in syswow64, and in its own directory. Patch 0017
#      now resolves ahead of the registry, so this is a guard against the patch
#      regressing, not against the value existing.
#
#   2. The app-directory copy. Windows resolves a DLL from the application's own
#      directory first, so it wins over system32 no matter what the load order
#      says. Under patch 0017 an unsigned copy is skipped (LO_BUILTIN rejects
#      it) and a *signed* copy loads -- pinning the bottle to whatever DXVK was
#      current when it was written. Identical-to-builtin is reported but passes;
#      differing is the failure.
#
# Run: tests/graphics-loadorder-test.sh [bottle-dir]   # exit 0 = clean
#      With no argument, checks every bottle.
set -uo pipefail

BOTTLES_DIR="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"
WINE_LIB="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/lib/wine"

# The modules patch 0017 owns. Registry names carry no .dll extension; the file
# check only applies to the ones a game would ship beside its .exe.
MODULES=(d3d9 d3d8 d3d11 d3d10core dxgi vulkan-1 winemetal)
DLLS=(d3d9.dll d3d8.dll d3d11.dll d3d10core.dll dxgi.dll)

if [ ! -d "$WINE_LIB/x86_64-windows" ]; then
    echo "SKIP: no Wine installed at $WINE_LIB (run 'make proton')"
    exit 0
fi

if [ $# -ge 1 ]; then
    bottles=("$1")
else
    bottles=()
    for b in "$BOTTLES_DIR"/*/; do [ -d "$b/drive_c" ] && bottles+=("${b%/}"); done
fi

if [ ${#bottles[@]} -eq 0 ]; then
    echo "SKIP: no bottles found under $BOTTLES_DIR"
    exit 0
fi

overrides=0
differing=0
identical=0

for bottle in "${bottles[@]}"; do
    [ -d "$bottle/drive_c" ] || { echo "ERROR: not a bottle: $bottle" >&2; exit 2; }
    echo "=== $(basename "$bottle")"

    # --- 1. DllOverrides on a module we own -------------------------------
    # Read user.reg directly rather than through `wine reg query`: no wineserver
    # to start, and no risk of this check itself mutating the bottle.
    for reg in user.reg system.reg; do
        [ -f "$bottle/$reg" ] || continue
        section=$(awk '/^\[Software\\\\Wine\\\\DllOverrides\]/{f=1;next} /^\[/{f=0} f' "$bottle/$reg")
        [ -n "$section" ] || continue
        for module in "${MODULES[@]}"; do
            line=$(printf '%s\n' "$section" | grep -i "^\"$module\"=" || true)
            [ -n "$line" ] || continue
            echo "  !! $reg  $line"
            echo "       overrides the builtin we ship; patch 0017 must resolve ahead of it"
            overrides=$((overrides + 1))
        done
    done

    # --- 2. App-directory copy of a builtin we own ------------------------
    for dll in "${DLLS[@]}"; do
        while IFS= read -r found; do
            case "$found" in */drive_c/windows/*) continue ;; esac

            # Compare against whichever builtin matches its architecture. A PE32+
            # ("PE32+ executable") is x86_64; PE32 is i386.
            if file -b "$found" 2>/dev/null | grep -q 'PE32+'; then
                builtin="$WINE_LIB/x86_64-windows/$dll"
            else
                builtin="$WINE_LIB/i386-windows/$dll"
            fi

            rel="${found#"$bottle"/drive_c/}"
            if [ ! -f "$builtin" ]; then
                echo "  ?  $rel (no builtin $dll to compare against)"
            elif cmp -s "$found" "$builtin"; then
                echo "  =  $rel (identical to the builtin; shadows it harmlessly)"
                identical=$((identical + 1))
            else
                echo "  !! $rel"
                echo "       $(stat -f '%z bytes, %Sm' -t '%Y-%m-%d' "$found")  <- loaded by the game"
                echo "       $(stat -f '%z bytes, %Sm' -t '%Y-%m-%d' "$builtin")  <- what we install, and what it displaces"
                differing=$((differing + 1))
            fi
        done < <(find "$bottle/drive_c" -name "$dll" -type f 2>/dev/null)
    done
done

echo
status=0
if [ "$overrides" -gt 0 ]; then
    echo "FAIL: $overrides DllOverrides entry/entries on modules this tree ships as builtins."
    echo "      Remove each so the load order is decided by patch 0017 alone:"
    echo "          wine reg delete 'HKCU\\Software\\Wine\\DllOverrides' /v <name> /f"
    status=1
fi
if [ "$differing" -gt 0 ]; then
    echo "FAIL: $differing app-directory copy/copies differ from the installed builtin."
    echo "      A signed copy still wins the search order, pinning the bottle to"
    echo "      whatever was current when it was written. Move each aside:"
    echo "          mv '<path>' '<path>.stale'"
    status=1
fi
[ "$status" -eq 0 ] && echo "ok: no overrides, no differing app-directory copies ($identical identical to the builtin)"
exit "$status"

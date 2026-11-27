#!/usr/bin/env bash
#
# tests/run-all.sh — Run Whisky's non-interactive automated regression suite.
#
# Exercises host unit tests, environment/loadorder contracts, GStreamer
# VideoToolbox hardware decode, Vulkan/D3D12, CoreAudio WASAPI, MSync mixed
# waits, SteamAppId Unix env propagation, foreign-thread VEH fault guard, and
# macOS BSD socket option normalization.
#
# Usage:
#   tests/run-all.sh
#   make test
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINE_PREFIX_BIN="${WHISKY_WINE_BIN:-$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin}"
WINE="$WINE_PREFIX_BIN/wine64"
WS="$WINE_PREFIX_BIN/wineserver"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

run_case() {
    local name="$1"
    shift
    printf "\n==================== [TEST] %s ====================\n" "$name"
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo ">>> PASS: $name"
        PASS=$((PASS + 1))
    else
        echo ">>> FAIL: $name (exit=$rc)"
        FAIL=$((FAIL + 1))
        FAILED_NAMES+=("$name")
    fi
}

# 1. Host & script-based regression suites
run_case "env-contract"           bash "$PROJECT_DIR/tests/env-contract-test.sh"
run_case "gstreamer-videotoolbox" bash "$PROJECT_DIR/tests/gstreamer/videotoolbox-test.sh"
if [ "${WHISKY_SLOW_TESTS:-0}" = "1" ]; then
    run_case "vulkan-strip-cull"  bash "$PROJECT_DIR/tests/vulkan/strip-cull-test.sh"
else
    echo "SKIP: vulkan-strip-cull (multi-minute GPU stress; set WHISKY_SLOW_TESTS=1 to include)"
    SKIP=$((SKIP + 1))
fi

if [ -x "$WINE" ]; then
    run_case "loadorder-builtins"            bash "$PROJECT_DIR/tests/loadorder/run.sh"
    run_case "audio-coreaudio-vol-route-ev"  bash "$PROJECT_DIR/tests/audio/coreaudio-volume-and-routing-test.sh"
    run_case "audio-name-growth"             bash "$PROJECT_DIR/tests/audio/audio-name-growth-test.sh"
    if [ -f "$PROJECT_DIR/scripts/lib/vkd3d.sh" ]; then
        run_case "d3d12-builtins"            bash "$PROJECT_DIR/tests/d3d12/run.sh"
    fi

    # 2. Standalone Win64 PE regression tests in a fresh disposable prefix
    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        TMPDIR_PE="$(mktemp -d /tmp/whisky-reg-pe.XXXXXX)"
        cleanup_pe() {
            WINEPREFIX="$TMPDIR_PE/prefix" "$WS" -k >/dev/null 2>&1 || true
            rm -rf "$TMPDIR_PE"
        }
        trap cleanup_pe EXIT
        mkdir -p "$TMPDIR_PE/prefix"

        run_pe() {
            local name="$1" src="$2" extra_libs="$3" extra_env="${4:-}"
            local exe="$TMPDIR_PE/${name}.exe"
            # shellcheck disable=SC2086
            x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o "$exe" "$PROJECT_DIR/$src" $extra_libs
            if [ -n "$extra_env" ]; then
                # shellcheck disable=SC2086
                env $extra_env WINEPREFIX="$TMPDIR_PE/prefix" WINEDEBUG=-all \
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe"
            else
                WINEPREFIX="$TMPDIR_PE/prefix" WINEDEBUG=-all \
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe"
            fi
        }

        run_case "msync-mixed-wait" \
            run_pe "msync-mixed-wait" "tests/msync-mixed-wait-test.c" "" "WINEMSYNC=1"

        run_msync_multi_wait_stress() {
            local exe="$TMPDIR_PE/msync-multi-wait-stress.exe"
            local port_prefix="$TMPDIR_PE/prefix-msync-ports"
            mkdir -p "$port_prefix"
            x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o "$exe" "$PROJECT_DIR/tests/msync-multi-wait-stress-test.c"
            # 1) Default WINEMSYNC=1 (native msync manual-reset events)
            WINEPREFIX="$TMPDIR_PE/prefix" WINEMSYNC=1 WINEDEBUG=-all \
                perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe"
            # 2) Diagnostic mixed-wait path (WINEMSYNC_NO_MANUALEVENT=1)
            WINEPREFIX="$TMPDIR_PE/prefix" WINEMSYNC=1 WINEMSYNC_NO_MANUALEVENT=1 WINEDEBUG=-all \
                perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe"
            # 3) wineserver Mach port send-right leak check across 20 churn runs
            WINEPREFIX="$port_prefix" WINEMSYNC=1 WINEDEBUG=-all "$WS" -p=30
            WINEPREFIX="$port_prefix" WINEMSYNC=1 WINEDEBUG=-all "$WINE" "$exe" --port-churn >/dev/null
            local ws_pid ports_before ports_after delta
            ws_pid=$(pgrep -n -f "$WS" || true)
            # Identify the persistent wineserver belonging to port_prefix if multiple exist
            for p in $(pgrep -f "wineserver" || true); do
                if lsof -p "$p" 2>/dev/null | grep -q "$port_prefix"; then
                    ws_pid="$p"
                    break
                fi
            done
            if [ -n "$ws_pid" ] && command -v top >/dev/null 2>&1; then
                ports_before=$(top -l 1 -stats pid,ports -pid "$ws_pid" 2>/dev/null | awk -v pid="$ws_pid" '$1==pid{gsub(/[^0-9]/,"",$2); print $2}')
                for _ in $(seq 1 20); do
                    WINEPREFIX="$port_prefix" WINEMSYNC=1 WINEDEBUG=-all "$WINE" "$exe" --port-churn >/dev/null
                done
                ports_after=$(top -l 1 -stats pid,ports -pid "$ws_pid" 2>/dev/null | awk -v pid="$ws_pid" '$1==pid{gsub(/[^0-9]/,"",$2); print $2}')
                WINEPREFIX="$port_prefix" "$WS" -k >/dev/null 2>&1 || true
                if [ -n "$ports_before" ] && [ -n "$ports_after" ]; then
                    delta=$((ports_after - ports_before))
                    echo "wineserver Mach ports: before=$ports_before after_20_runs=$ports_after delta=$delta"
                    if [ "$delta" -gt 4 ]; then
                        echo "FAIL: wineserver leaked $delta Mach ports over 20 runs"
                        return 1
                    fi
                fi
            else
                WINEPREFIX="$port_prefix" "$WS" -k >/dev/null 2>&1 || true
            fi
        }
        run_case "msync-multi-wait-stress" run_msync_multi_wait_stress
        run_case "steam-appid-unix-env" \
            run_pe "steam-appid-unix-env" "tests/steam-appid-unix-env-test.c" "" "-u SteamGameId -u SteamAppId -u STEAM_COMPAT_APP_ID"
        run_case "ws2_32-sockopt" \
            run_pe "ws2_32-sockopt" "tests/ws2_32-sockopt-test.c" "-lws2_32" ""
        run_case "bcrypt-ecdh-rsa" \
            run_pe "bcrypt-ecdh-rsa" "tests/bcrypt-ecdh-rsa-test.c" "-lbcrypt" ""
        run_case "signal-thread-guard" \
            run_pe "signal-thread-guard" "tests/signal-thread-guard-test.c" "" ""
        run_case "rosetta-signal-xstate" \
            run_pe "rosetta-signal-xstate" "tests/rosetta-signal-xstate-test.c" "-mavx2" "ROSETTA_ADVERTISE_AVX=1"
        run_case "rosetta-mach-wpm" \
            run_pe "rosetta-mach-wpm" "tests/rosetta-mach-wpm-test.c" "" ""

        run_vulkan_dpi_swapchain() {
            local exe="$TMPDIR_PE/vulkan-dpi-swapchain.exe"
            local dpi_prefix="$TMPDIR_PE/prefix-dpi"
            local vk_stderr="$TMPDIR_PE/vulkan-dpi-stderr.log"
            mkdir -p "$dpi_prefix"
            x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o "$exe" "$PROJECT_DIR/tests/vulkan-dpi-swapchain-test.c"
            WINEPREFIX="$dpi_prefix" WINEDEBUG=-all "$WINE" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d y /f >/dev/null
            WINEPREFIX="$dpi_prefix" WINEDEBUG=-all "$WINE" reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 192 /f >/dev/null
            WINEPREFIX="$dpi_prefix" WINEDEBUG=-all "$WS" -k >/dev/null 2>&1 || true
            local rc=0
            # 1) DPI-unaware window: verify 0 VK_SUBOPTIMAL_KHR AND no fshack compute double-blit on macOS.
            WINEPREFIX="$dpi_prefix" WINEDEBUG=warn+vulkan \
                perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe" 2>"$vk_stderr" || rc=$?
            if [ "$rc" -eq 0 ] && grep -q "Enabled fullscreen hack on swapchain" "$vk_stderr"; then
                echo "FAIL: Vulkan fshack compute double-blit activated on macOS DPI-unaware surface"
                grep "Enabled fullscreen hack" "$vk_stderr"
                rc=1
            elif [ "$rc" -eq 0 ]; then
                echo "PASS: no Vulkan fshack double-blit on macOS DPI-unaware surface"
            fi
            # 2) DPI-aware window: verify full 2x Retina swapchain (1280x720) with 0 VK_SUBOPTIMAL_KHR.
            if [ "$rc" -eq 0 ]; then
                WINEPREFIX="$dpi_prefix" WINEDEBUG=-all \
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe" --dpi-aware || rc=$?
            fi
            WINEPREFIX="$dpi_prefix" "$WS" -k >/dev/null 2>&1 || true
            return "$rc"
        }
        run_case "vulkan-dpi-swapchain" run_vulkan_dpi_swapchain

        if command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
            run_wow64_cs_recovery() {
                local dll="$TMPDIR_PE/dummy-rosetta.dll"
                local exe="$TMPDIR_PE/wow64-rosetta-cs-recovery.exe"
                i686-w64-mingw32-gcc -O2 -Wall -Wextra -shared -o "$dll" -xc - <<'EOF'
#include <windows.h>
__declspec(dllexport) int ping(int x) { return x + 1; }
BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, void *r) { (void)h; (void)reason; (void)r; return TRUE; }
EOF
                i686-w64-mingw32-gcc -O2 -Wall -Wextra -o "$exe" "$PROJECT_DIR/tests/wow64-rosetta-cs-recovery-test.c" -lbcrypt
                WINEPREFIX="$TMPDIR_PE/prefix" WINEDEBUG=-all \
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe" "$dll"
            }
            run_case "wow64-rosetta-cs-recovery" run_wow64_cs_recovery
        else
            echo "SKIP: i686-w64-mingw32-gcc not found; skipping WoW64 CS recovery test"
            SKIP=$((SKIP + 1))
        fi
    else
        echo "SKIP: x86_64-w64-mingw32-gcc not found; skipping standalone PE regression tests"
        SKIP=$((SKIP + 4))
    fi
else
    echo "SKIP: Wine not found at $WINE; skipping Wine-dependent tests"
    SKIP=$((SKIP + 8))
fi

echo ""
echo "================================================================"
echo "Whisky Regression Summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed: ${FAILED_NAMES[*]}"
    exit 1
fi

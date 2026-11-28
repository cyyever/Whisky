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
WINE_ROOT="$(cd "$WINE_PREFIX_BIN/.." 2>/dev/null && pwd || echo "")"
WINE="$WINE_PREFIX_BIN/wine64"
WS="${WINESERVER:-$WINE_PREFIX_BIN/wineserver}"

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

TMPDIR_PE=""
TMPDIR_SAN=""
cleanup_all() {
    if [ -n "$TMPDIR_PE" ]; then
        WINEPREFIX="$TMPDIR_PE/prefix" "$WS" -k >/dev/null 2>&1 || true
        WINEPREFIX="$TMPDIR_PE/prefix" "$WS" -w >/dev/null 2>&1 || true
        rm -rf "$TMPDIR_PE"
    fi
    if [ -n "$TMPDIR_SAN" ]; then
        rm -rf "$TMPDIR_SAN"
    fi
}
trap cleanup_all EXIT

PE_OPT_FLAGS=(-O1 -g -Wall -Wextra -fsanitize=undefined -fsanitize-undefined-trap-on-error)
if [ -d "$PROJECT_DIR/vendor/proton-wine/build/include" ] && [ -x "$WINE" ]; then
    TMPDIR_SAN="$(mktemp -d /tmp/whisky-reg-san.XXXXXX)"
    SDK="$(xcrun --show-sdk-path)"
    LSAN_FLAG=0
    if [ -x /opt/homebrew/opt/llvm/bin/clang ]; then
        SAN_CC="/opt/homebrew/opt/llvm/bin/clang"
        LSAN_FLAG=1
        echo "=== [SANITIZERS] Building arm64 wineserver with LLVM ASan + UBSan + LSan ==="
    else
        SAN_CC="$(xcrun --find clang)"
        echo "=== [SANITIZERS] Building arm64 wineserver with Apple Clang ASan + UBSan ==="
    fi
    mkdir -p "$TMPDIR_SAN/ws-obj"
    for f in "$PROJECT_DIR"/vendor/proton-wine/server/*.c; do
        base="$(basename "$f" .c)"
        "$SAN_CC" -arch arm64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer \
            -fsanitize=address,undefined,local-bounds,float-divide-by-zero -fno-sanitize=function -fno-sanitize-recover=undefined \
            -c -o "$TMPDIR_SAN/ws-obj/${base}.o" "$f" \
            -I"$PROJECT_DIR/vendor/proton-wine/build/server" -I"$PROJECT_DIR/vendor/proton-wine/server" \
            -I"$PROJECT_DIR/vendor/proton-wine/build/include" -I"$PROJECT_DIR/vendor/proton-wine/include" \
            -D__WINESRC__ -DWINE_UNIX_LIB \
            -DBINDIR="\"$WINE_PREFIX_BIN\"" -DDATADIR="\"$WINE_ROOT/share\"" \
            -fvisibility=hidden -fno-strict-aliasing 2>/dev/null &
    done
    wait
    "$SAN_CC" -arch arm64 -isysroot "$SDK" -fsanitize=address,undefined,local-bounds,float-divide-by-zero -fno-sanitize=function \
        -o "$TMPDIR_SAN/wineserver-asan" "$TMPDIR_SAN/ws-obj"/*.o
    cat > "$TMPDIR_SAN/wineserver" <<EOF
#!/bin/sh
export ASAN_OPTIONS="detect_leaks=${LSAN_FLAG}:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:strict_init_order=1:halt_on_error=1:exitcode=77:log_path=${TMPDIR_SAN}/wineserver-asan.log"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1:log_path=${TMPDIR_SAN}/wineserver-ubsan.log"
exec "${TMPDIR_SAN}/wineserver-asan" "\$@"
EOF
    chmod +x "$TMPDIR_SAN/wineserver"
    WS="$TMPDIR_SAN/wineserver"
    export WINESERVER="$WS"
fi

# Always enable Metal API + GPU Shader Validation across all GPU tests.
export METAL_DEVICE_WRAPPER_TYPE=1
export MTL_DEBUG_LAYER=1
export MTL_DEBUG_LAYER_WARNING_MODE=nslog
export MTL_SHADER_VALIDATION=1

# Enable Khronos Vulkan Validation Layers when built into vendor/vulkan-validation/.
if [ -f "$PROJECT_DIR/vendor/vulkan-validation/VkLayer_khronos_validation.json" ]; then
    export VK_LAYER_PATH="$PROJECT_DIR/vendor/vulkan-validation"
    export VK_INSTANCE_LAYERS="VK_LAYER_KHRONOS_validation"
fi

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
run_case "libfuzzer-smoke"        bash "$PROJECT_DIR/tests/fuzz/run-fuzz.sh"
run_case "mullion-host-sanitizers" bash "$PROJECT_DIR/tests/mullion-host-sanitizers.sh"
run_case "gstreamer-videotoolbox" bash "$PROJECT_DIR/tests/gstreamer/videotoolbox-test.sh"
if [ "${WHISKY_SLOW_TESTS:-0}" = "1" ]; then
    run_case "vulkan-strip-cull"  bash "$PROJECT_DIR/tests/vulkan/strip-cull-test.sh"
else
    echo "SKIP: vulkan-strip-cull (multi-minute GPU stress; set WHISKY_SLOW_TESTS=1 to include)"
    SKIP=$((SKIP + 1))
fi

if [ -x "$WINE" ]; then
    run_case "build-codegen-contract"        bash "$PROJECT_DIR/tests/build-codegen-contract-test.sh"
    run_case "loadorder-builtins"            bash "$PROJECT_DIR/tests/loadorder/run.sh"
    run_case "audio-coreaudio-vol-route-ev"  bash "$PROJECT_DIR/tests/audio/coreaudio-volume-and-routing-test.sh"
    run_case "audio-name-growth"             bash "$PROJECT_DIR/tests/audio/audio-name-growth-test.sh"
    if [ -f "$PROJECT_DIR/scripts/lib/vkd3d.sh" ]; then
        run_case "d3d12-builtins"            bash "$PROJECT_DIR/tests/d3d12/run.sh"
    fi

    # 2. Standalone Win64 PE regression tests in a fresh disposable prefix
    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        TMPDIR_PE="$(mktemp -d /tmp/whisky-reg-pe.XXXXXX)"
        mkdir -p "$TMPDIR_PE/prefix"

        run_pe() {
            local name="$1" src="$2" extra_libs="$3" extra_env="${4:-}"
            local exe="$TMPDIR_PE/${name}.exe"
            # shellcheck disable=SC2086
            x86_64-w64-mingw32-gcc "${PE_OPT_FLAGS[@]}" -o "$exe" "$PROJECT_DIR/$src" $extra_libs
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
            x86_64-w64-mingw32-gcc "${PE_OPT_FLAGS[@]}" -o "$exe" "$PROJECT_DIR/tests/msync-multi-wait-stress-test.c"
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
        run_case "ws2_32-fd-write-rearm" \
            run_pe "ws2_32-fd-write-rearm" "tests/ws2_32-fd-write-rearm-test.c" "-lws2_32" "WINEMSYNC=1"
        run_case "rawinput-active-window" \
            run_pe "rawinput-active-window" "tests/rawinput-active-window-test.c" "-luser32" "WINEMSYNC=1"
        run_case "macos-sleep-qos-and-avrt" \
            run_pe "macos-sleep-qos-and-avrt" "tests/macos-sleep-qos-and-avrt-test.c" "-lws2_32" "WINEMSYNC=1"
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
            x86_64-w64-mingw32-gcc "${PE_OPT_FLAGS[@]}" -o "$exe" "$PROJECT_DIR/tests/vulkan-dpi-swapchain-test.c"
            WINEPREFIX="$dpi_prefix" WINEDEBUG=-all "$WINE" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d y /f >/dev/null
            WINEPREFIX="$dpi_prefix" WINEDEBUG=-all "$WINE" reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 192 /f >/dev/null
            WINEPREFIX="$dpi_prefix" WINEDEBUG=-all "$WS" -k >/dev/null 2>&1 || true
            local rc=0
            # 1) DPI-unaware window: verify 0 VK_SUBOPTIMAL_KHR AND no fshack compute double-blit on macOS.
            WINEPREFIX="$dpi_prefix" WINEDEBUG=warn+vulkan \
                perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe" 2>"$vk_stderr" || rc=$?
            if [ "$rc" -eq 0 ] && grep -q "Validation Error:" "$vk_stderr"; then
                echo "FAIL: Vulkan Validation Layer reported errors on DPI-unaware swapchain"
                grep -A 3 "Validation Error:" "$vk_stderr"
                rc=1
            fi
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
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe" --dpi-aware 2>"$vk_stderr" || rc=$?
                if [ "$rc" -eq 0 ] && grep -q "Validation Error:" "$vk_stderr"; then
                    echo "FAIL: Vulkan Validation Layer reported errors on DPI-aware swapchain"
                    grep -A 3 "Validation Error:" "$vk_stderr"
                    rc=1
                fi
            fi
            WINEPREFIX="$dpi_prefix" "$WS" -k >/dev/null 2>&1 || true
            return "$rc"
        }
        run_case "vulkan-dpi-swapchain" run_vulkan_dpi_swapchain

        if command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
            run_wow64_cs_recovery() {
                local dll="$TMPDIR_PE/dummy-rosetta.dll"
                local exe="$TMPDIR_PE/wow64-rosetta-cs-recovery.exe"
                i686-w64-mingw32-gcc "${PE_OPT_FLAGS[@]}" -shared -o "$dll" -xc - <<'EOF'
#include <windows.h>
__declspec(dllexport) int ping(int x) { return x + 1; }
BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, void *r) { (void)h; (void)reason; (void)r; return TRUE; }
EOF
                i686-w64-mingw32-gcc "${PE_OPT_FLAGS[@]}" -o "$exe" "$PROJECT_DIR/tests/wow64-rosetta-cs-recovery-test.c" -lbcrypt
                WINEPREFIX="$TMPDIR_PE/prefix" WINEDEBUG=-all \
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe" "$dll"
            }
            run_case "wow64-rosetta-cs-recovery" run_wow64_cs_recovery

            run_i386_sse_math_and_stack() {
                local exe="$TMPDIR_PE/i386-sse-math-and-stack-test.exe"
                i686-w64-mingw32-gcc "${PE_OPT_FLAGS[@]}" -msse2 -o "$exe" "$PROJECT_DIR/tests/i386-sse-math-and-stack-test.c" -lole32
                WINEPREFIX="$TMPDIR_PE/prefix" WINEDEBUG=-all WINEDLLOVERRIDES="d3dx9_43,xaudio2_7=b" \
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$exe"
            }
            run_case "i386-sse-math-and-stack" run_i386_sse_math_and_stack
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

if [ -n "$TMPDIR_SAN" ]; then
    # Stop the PE prefix's wineserver cleanly so LSan runs its exit-time leak check.
    if [ -n "$TMPDIR_PE" ]; then
        WINEPREFIX="$TMPDIR_PE/prefix" "$WS" -k >/dev/null 2>&1 || true
        WINEPREFIX="$TMPDIR_PE/prefix" "$WS" -w >/dev/null 2>&1 || true
    fi
    audit_wineserver_sanitizers() {
        local san_fail=0
        local f
        for f in "$TMPDIR_SAN"/wineserver-asan.log*; do
            [ -f "$f" ] || continue
            if grep -qE 'ERROR: (AddressSanitizer|LeakSanitizer)' "$f"; then
                echo "FAIL: ASan/LSan reported errors in wineserver ($f):"
                cat "$f"
                san_fail=1
            fi
        done
        for f in "$TMPDIR_SAN"/wineserver-ubsan.log*; do
            [ -f "$f" ] || continue
            if grep -q 'runtime error:' "$f"; then
                echo "FAIL: UBSan runtime errors in wineserver ($f):"
                cat "$f"
                san_fail=1
            fi
        done
        if [ "$san_fail" -eq 0 ]; then
            echo "PASS: wineserver ASan + UBSan + LSan logs clean across full test suite"
        fi
        return "$san_fail"
    }
    run_case "wineserver-asan-ubsan-lsan-audit" audit_wineserver_sanitizers

    run_wineserver_tsan() {
        local wine_src="$PROJECT_DIR/vendor/proton-wine"
        local tsan_dir="$TMPDIR_SAN/tsan"
        mkdir -p "$tsan_dir/ws-obj" "$tsan_dir/pfx"
        for f in "$wine_src"/server/*.c; do
            local base
            base="$(basename "$f" .c)"
            "$SAN_CC" -arch arm64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer \
                -fsanitize=thread \
                -c -o "$tsan_dir/ws-obj/${base}.o" "$f" \
                -I"$wine_src/build/server" -I"$wine_src/server" \
                -I"$wine_src/build/include" -I"$wine_src/include" \
                -D__WINESRC__ -DWINE_UNIX_LIB \
                -DBINDIR="\"$WINE_PREFIX_BIN\"" -DDATADIR="\"$WINE_ROOT/share\"" \
                -fvisibility=hidden -fno-strict-aliasing 2>/dev/null &
        done
        wait
        "$SAN_CC" -arch arm64 -isysroot "$SDK" -fsanitize=thread \
            -o "$tsan_dir/wineserver-tsan" "$tsan_dir/ws-obj"/*.o
        cat > "$tsan_dir/wineserver" <<EOF
#!/bin/sh
export TSAN_OPTIONS="halt_on_error=1:second_deadlock_stack=1:log_path=${tsan_dir}/wineserver-tsan.log"
exec "${tsan_dir}/wineserver-tsan" "\$@"
EOF
        chmod +x "$tsan_dir/wineserver"
        local rc=0
        local tsan_pfx="$TMPDIR_PE/prefix"
        if [ -z "$TMPDIR_PE" ] || [ ! -d "$tsan_pfx" ]; then
            tsan_pfx="$tsan_dir/pfx"
        fi
        if [ -n "$TMPDIR_PE" ] && [ -x "$TMPDIR_PE/msync-mixed-wait.exe" ] && [ -x "$TMPDIR_PE/msync-multi-wait-stress.exe" ]; then
            WINEPREFIX="$tsan_pfx" WINESERVER="$tsan_dir/wineserver" WINEMSYNC=1 WINEDEBUG=-all \
                perl -e 'alarm 45; exec @ARGV' "$WINE" "$TMPDIR_PE/msync-mixed-wait.exe" || rc=$?
            if [ "$rc" -eq 0 ]; then
                WINEPREFIX="$tsan_pfx" WINESERVER="$tsan_dir/wineserver" WINEMSYNC=1 WINEDEBUG=-all \
                    perl -e 'alarm 45; exec @ARGV' "$WINE" "$TMPDIR_PE/msync-multi-wait-stress.exe" || rc=$?
            fi
        fi
        WINEPREFIX="$tsan_pfx" "$tsan_dir/wineserver" -k >/dev/null 2>&1 || true
        WINEPREFIX="$tsan_pfx" "$tsan_dir/wineserver" -w >/dev/null 2>&1 || true
        for f in "$tsan_dir"/wineserver-tsan.log*; do
            [ -f "$f" ] || continue
            if grep -q 'WARNING: ThreadSanitizer:' "$f"; then
                echo "FAIL: ThreadSanitizer reported data race(s) in wineserver ($f):"
                cat "$f"
                rc=1
            fi
        done
        if [ "$rc" -eq 0 ]; then
            echo "PASS: wineserver TSan clean (0 data races across msync mixed-wait + multi-wait stress)"
        fi
        return "$rc"
    }
    run_case "wineserver-tsan-msync" run_wineserver_tsan

    check_patched_modules_ubsan() {
        local wine_src="$PROJECT_DIR/vendor/proton-wine"
        if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
            x86_64-w64-mingw32-gcc -O1 -g -fsanitize=undefined -fsanitize-undefined-trap-on-error \
                -c -o "$TMPDIR_SAN/dsoundrender64.o" "$wine_src/dlls/quartz/dsoundrender.c" \
                -I"$wine_src/build/dlls/quartz" -I"$wine_src/dlls/quartz" \
                -I"$wine_src/build/include" -I"$wine_src/include" -I"$wine_src/include/msvcrt" \
                -D_MSVCR_VER=0 -D__WINESRC__ -D__WINE_PE_BUILD
            x86_64-w64-mingw32-gcc -O1 -g -fsanitize=undefined -fsanitize-undefined-trap-on-error \
                -c -o "$TMPDIR_SAN/asfreader64.o" "$wine_src/dlls/qasf/asfreader.c" \
                -I"$wine_src/build/dlls/qasf" -I"$wine_src/dlls/qasf" \
                -I"$wine_src/build/include" -I"$wine_src/include" -I"$wine_src/include/msvcrt" \
                -D_MSVCR_VER=0 -D__WINESRC__ -D__WINE_PE_BUILD
        fi
        clang -arch x86_64 -O1 -g -fsanitize=undefined,nullability,local-bounds,float-divide-by-zero \
            -fsanitize-trap=undefined,nullability,local-bounds,float-divide-by-zero \
            -c -o "$TMPDIR_SAN/socket.o" "$wine_src/dlls/ntdll/unix/socket.c" \
            -I"$wine_src/build/dlls/ntdll" -I"$wine_src/dlls/ntdll" \
            -I"$wine_src/build/include" -I"$wine_src/include" \
            -D__WINESRC__ -D_NTSYSTEM_ -D_ACRTIMP= -DWINBASEAPI= -DWINE_UNIX_LIB
        clang -arch x86_64 -O1 -g -fsanitize=undefined,nullability,local-bounds,float-divide-by-zero \
            -fsanitize-trap=undefined,nullability,local-bounds,float-divide-by-zero \
            -c -o "$TMPDIR_SAN/cocoa_window.o" "$wine_src/dlls/winemac.drv/cocoa_window.m" \
            -I"$wine_src/build/dlls/winemac.drv" -I"$wine_src/dlls/winemac.drv" \
            -I"$wine_src/build/include" -I"$wine_src/include" \
            -D__WINESRC__ -DWINE_UNIX_LIB
        echo "PASS: UBSan trap-mode compile clean for dsoundrender, asfreader, socket, cocoa_window"
    }
    run_case "wine-modules-ubsan-compile" check_patched_modules_ubsan
fi

echo ""
echo "================================================================"
echo "Whisky Regression Summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed: ${FAILED_NAMES[*]}"
    exit 1
fi

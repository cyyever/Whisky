#!/usr/bin/env bash
#
# tests/fuzz/run-fuzz.sh — Build and run Whisky's libFuzzer targets under
# Homebrew LLVM ASan + UBSan + LSan + nullability + local-bounds.
#
# Usage:
#   tests/fuzz/run-fuzz.sh [max_seconds_per_target]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAX_TIME="${1:-3}"
MAX_RUNS="${2:-50000}"

LLVM_CC="/opt/homebrew/opt/llvm/bin/clang"
if [ ! -x "$LLVM_CC" ]; then
    echo "SKIP: Homebrew LLVM clang not found at $LLVM_CC (required for libFuzzer)"
    exit 0
fi

SDK="$(xcrun --show-sdk-path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/whisky-fuzz.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

COMMON_FLAGS=(
    -arch arm64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer
    -fsanitize=fuzzer,address,undefined,nullability,local-bounds,float-divide-by-zero
    -fno-sanitize-recover=all
    -Wall -Wextra
)

export ASAN_OPTIONS="detect_leaks=1:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:strict_init_order=1:halt_on_error=1:exitcode=77"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"

echo "=== 1. Fuzz winecoreaudio.drv/volume_scale.h (${MAX_TIME}s, max ${MAX_RUNS} runs) ==="
"$LLVM_CC" "${COMMON_FLAGS[@]}" \
    -I"$PROJECT_DIR/vendor/proton-wine/dlls/winecoreaudio.drv" \
    "$PROJECT_DIR/tests/fuzz/fuzz-volume-scale.c" \
    -o "$WORK/fuzz-volume-scale" -lm
"$WORK/fuzz-volume-scale" -rss_limit_mb=0 -artifact_prefix="$WORK/" -max_total_time="$MAX_TIME" -runs="$MAX_RUNS" -print_final_stats=1 2>&1 | tail -n 15

echo ""
echo "=== 2. Fuzz macOS IP_RECVTOS/IP_RECVTTL cmsghdr conversion (${MAX_TIME}s, max ${MAX_RUNS} runs) ==="
"$LLVM_CC" "${COMMON_FLAGS[@]}" \
    "$PROJECT_DIR/tests/fuzz/fuzz-cmsg-control.c" \
    -o "$WORK/fuzz-cmsg-control"
"$WORK/fuzz-cmsg-control" -rss_limit_mb=0 -artifact_prefix="$WORK/" -max_total_time="$MAX_TIME" -runs="$MAX_RUNS" -print_final_stats=1 2>&1 | tail -n 15

echo ""
echo "PASS: all libFuzzer targets clean (0 crashes, 0 ASan/UBSan/LSan errors)"

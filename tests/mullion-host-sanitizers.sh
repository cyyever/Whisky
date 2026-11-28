#!/usr/bin/env bash
#
# tests/mullion-host-sanitizers.sh — Build and run Mullion's native C++26/ObjC
# host unit tests under LLVM ASan+UBSan+LSan+nullability+local-bounds, TSan,
# and TySan.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MULLION="$PROJECT_DIR/vendor/mullion"
[ -d "$MULLION/tests/host" ] || { echo "SKIP: vendor/mullion not present"; exit 0; }

if [ -x /opt/homebrew/opt/llvm/bin/clang++ ]; then
    CXX="/opt/homebrew/opt/llvm/bin/clang++"
    CC="/opt/homebrew/opt/llvm/bin/clang"
    HAS_LLVM=1
else
    CXX="$(xcrun --find clang++)"
    CC="$(xcrun --find clang)"
    HAS_LLVM=0
fi

SDK="$(xcrun --show-sdk-path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/whisky-mullion-san.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ASAN_OPTS="detect_leaks=${HAS_LLVM}:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:strict_init_order=1:halt_on_error=1:exitcode=77"
UBSAN_OPTS="print_stacktrace=1:halt_on_error=1"
TSAN_OPTS="halt_on_error=1:second_deadlock_stack=1"

CXX_BASE=(
    -arch arm64 -isysroot "$SDK" -std=c++26 -O1 -g -fno-omit-frame-pointer
    -I"$MULLION/include" -I"$MULLION/include/native/directx" -I"$MULLION/include/native/windows"
    -I"$MULLION/src/util" -I"$MULLION/src/winemetal"
    -I"$MULLION/tests/host/metal" -Wno-unknown-pragmas
)

run_cpp_test() {
    local name="$1" run_tysan="$2" extra_san="$3"
    shift 3
    local srcs=("$@")

    # 1. Strict ASan + UBSan + LSan + nullability + local-bounds
    "$CXX" "${CXX_BASE[@]}" \
        -fsanitize=address,undefined,nullability,local-bounds${extra_san} -fno-sanitize-recover=all \
        "${srcs[@]}" -o "$WORK/${name}-asan"
    ASAN_OPTIONS="$ASAN_OPTS" UBSAN_OPTIONS="$UBSAN_OPTS" "$WORK/${name}-asan" >/dev/null

    # 2. TSan
    "$CXX" "${CXX_BASE[@]}" -fsanitize=thread "${srcs[@]}" -o "$WORK/${name}-tsan"
    TSAN_OPTIONS="$TSAN_OPTS" "$WORK/${name}-tsan" >/dev/null

    # 3. TySan (Homebrew LLVM)
    if [ "$HAS_LLVM" = "1" ] && [ "$run_tysan" = "1" ]; then
        "$CXX" "${CXX_BASE[@]}" -fsanitize=type "${srcs[@]}" -o "$WORK/${name}-tysan"
        TYSAN_OPTIONS="halt_on_error=1" "$WORK/${name}-tysan" >/dev/null
        echo "PASS: mullion/${name} (ASan+UBSan+LSan + TSan + TySan)"
    else
        echo "PASS: mullion/${name} (ASan+UBSan+LSan + TSan)"
    fi
}

run_cpp_test "colorspace"          1 ",float-divide-by-zero" "$MULLION/tests/host/colorspace.cpp"
run_cpp_test "window_placement"    1 ",float-divide-by-zero" "$MULLION/tests/host/window_placement.cpp"
run_cpp_test "geometry_budget"     1 ",float-divide-by-zero" "$MULLION/tests/host/geometry_budget.cpp"
run_cpp_test "format"              1 ",float-divide-by-zero" "$MULLION/tests/host/format.cpp" "$MULLION/src/util/util_string.cpp"
run_cpp_test "rc_self_move"        1 ",float-divide-by-zero" "$MULLION/tests/host/rc.cpp"
run_cpp_test "metal_reference"     0 ",float-divide-by-zero" "$MULLION/tests/host/metal_reference.cpp"
run_cpp_test "packed_variant_list" 1 ",float-divide-by-zero" "$MULLION/tests/host/packed_variant_list.cpp"
run_cpp_test "private_data"        1 ",float-divide-by-zero" "$MULLION/tests/host/private_data.cpp" "$MULLION/src/util/com/com_private_data.cpp"
run_cpp_test "denorm"              1 ""                      "$MULLION/tests/host/denorm.cpp"
run_cpp_test "sha1"                1 ",float-divide-by-zero" "$MULLION/tests/host/sha1.cpp" "$MULLION/src/util/sha1/sha1.c"

# Objective-C + SQLite + Metal shader store test
"$CC" -arch arm64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer -ObjC -w \
    -I"$MULLION/include" -I"$MULLION/src/winemetal" -I"$MULLION/src/airconv" \
    -fsanitize=address,undefined,nullability,local-bounds,float-divide-by-zero -fno-sanitize-recover=all \
    "$MULLION/tests/host/shader_store.c" "$MULLION/src/winemetal/unix/cache.c" \
    -framework Foundation -framework Metal -lsqlite3 -o "$WORK/shader_store-asan"
ASAN_OPTIONS="detect_leaks=0:detect_stack_use_after_return=1:strict_string_checks=1:halt_on_error=1:exitcode=77" \
    UBSAN_OPTIONS="$UBSAN_OPTS" "$WORK/shader_store-asan" >/dev/null

"$CC" -arch arm64 -isysroot "$SDK" -O1 -g -fno-omit-frame-pointer -ObjC -w \
    -I"$MULLION/include" -I"$MULLION/src/winemetal" -I"$MULLION/src/airconv" \
    -fsanitize=thread \
    "$MULLION/tests/host/shader_store.c" "$MULLION/src/winemetal/unix/cache.c" \
    -framework Foundation -framework Metal -lsqlite3 -o "$WORK/shader_store-tsan"
TSAN_OPTIONS="$TSAN_OPTS" "$WORK/shader_store-tsan" >/dev/null
echo "PASS: mullion/shader_store (ObjC+SQLite+Metal: ASan+UBSan+nullability + TSan)"

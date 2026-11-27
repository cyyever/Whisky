#!/usr/bin/env bash
#
# tests/build-codegen-contract-test.sh — Verify shipped Wine binaries carry the
# expected Rosetta 2 / Apple Silicon compiler optimizations:
#   1. 32-bit PE DLLs (xaudio2_7, dsound, d3dx9_43, msvcrt, ucrtbase) use SSE2
#      scalar math (-mfpmath=sse) rather than Rosetta-emulated x87 arithmetic.
#   2. Wine Unix .so modules (ntdll, win32u, winemac, winevulkan, winecoreaudio)
#      are compiled with optimization (-O2, not -O0) and keep frame pointers.
#   3. Shipped Wine binaries contain no accidental AVX instructions (must stay
#      within Rosetta 2's universal x86-64-v2 / SSE4.2 baseline).
#   4. wineserver is a native arm64 Mach-O binary.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINE_ROOT="${WHISKY_WINE_ROOT:-$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine}"

OBJDUMP=""
for cand in /opt/homebrew/opt/llvm/bin/llvm-objdump "$(command -v llvm-objdump 2>/dev/null || true)" /usr/bin/objdump; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
        OBJDUMP="$cand"
        break
    fi
done
if [ -z "$OBJDUMP" ]; then
    echo "ERROR: no objdump / llvm-objdump found" >&2
    exit 1
fi

fail=0

# 1. wineserver must be native arm64
ws="$WINE_ROOT/bin/wineserver"
if [ ! -x "$ws" ]; then
    echo "FAIL: wineserver missing at $ws"
    exit 1
fi
ws_file="$(file "$ws")"
if echo "$ws_file" | grep -q 'Mach-O 64-bit executable arm64'; then
    echo "PASS: wineserver is native arm64 ($ws_file)"
else
    echo "FAIL: wineserver is not native arm64 ($ws_file)"
    fail=$((fail + 1))
fi

# 2. 32-bit PE DLLs: verify SSE2 scalar math active and x87 arithmetic eliminated.
#    Note: i386 cdecl ABI still requires `fld`/`fstp` solely for float/double return
#    values, and CRT transcendental asm in msvcrt/ucrtbase may have a handful of
#    explicit x87 instructions, so we check x87 arithmetic ops (fmul/fadd/fsub/fdiv)
#    and require strong SSE scalar presence.
echo ""
echo "--- 32-bit PE DLL x87 vs SSE2 audit ---"
check_i386_dll() {
    local dll="$1" max_x87_arith="$2" min_sse="$3"
    local path="$WINE_ROOT/lib/wine/i386-windows/$dll"
    if [ ! -f "$path" ]; then
        echo "FAIL: missing $path"
        fail=$((fail + 1))
        return
    fi
    local dis x87_arith sse_cnt avx_cnt
    dis="$("$OBJDUMP" -d "$path")"
    x87_arith=$(printf '%s\n' "$dis" | grep -cE '\b(fmul|fadd|fsub|fdiv|fmulp|faddp|fsubp|fsubrp|fdivp|fdivrp)\b' || true)
    sse_cnt=$(printf '%s\n' "$dis" | grep -cE '\b(mulss|addss|subss|divss|mulsd|addsd|subsd|divsd|movss|movsd)\b' || true)
    avx_cnt=$(printf '%s\n' "$dis" | grep -cE '\bv(mov|add|sub|mul|div)(ss|sd|ps|pd|aps|ups|dqa|dqu)\b' || true)
    printf "%-18s x87_arith=%-4d (max=%-3d)  sse=%-5d (min=%-3d)  avx=%d\n" \
        "$dll" "$x87_arith" "$max_x87_arith" "$sse_cnt" "$min_sse" "$avx_cnt"
    if [ "$x87_arith" -gt "$max_x87_arith" ]; then
        echo "FAIL: $dll has $x87_arith x87 arithmetic ops (limit $max_x87_arith) — was -mfpmath=sse dropped?"
        fail=$((fail + 1))
    fi
    if [ "$sse_cnt" -lt "$min_sse" ]; then
        echo "FAIL: $dll has only $sse_cnt SSE scalar FP ops (expected >= $min_sse)"
        fail=$((fail + 1))
    fi
    if [ "$avx_cnt" -gt 0 ]; then
        echo "FAIL: $dll contains $avx_cnt AVX instructions (must stay within Rosetta 2 SSE4.2 baseline)"
        fail=$((fail + 1))
    fi
}

check_i386_dll "xaudio2_7.dll"  0   50
check_i386_dll "dsound.dll"     0   50
check_i386_dll "d3dx9_43.dll"   0  500
check_i386_dll "msvcrt.dll"    20  100
check_i386_dll "ucrtbase.dll"  20  100

# 3. Wine Unix .so modules: verify optimized (-O2, not -O0), frame pointers kept, no AVX.
#    At -O0 clang spills locals with `movl $0, -N(%rbp)` / `movq %rdi, -N(%rbp)` in
#    virtually every function prologue. Checking the ratio of `-N(%rbp)` frame-local
#    stores vs total instructions cleanly distinguishes -O0 (>12%) from -O2 (<3%).
echo ""
echo "--- Wine Unix .so optimization (-O2) & ISA audit ---"
for mod in ntdll.so win32u.so winemac.so winevulkan.so winecoreaudio.so; do
    path="$WINE_ROOT/lib/wine/x86_64-unix/$mod"
    if [ ! -f "$path" ]; then
        echo "FAIL: missing $path"
        fail=$((fail + 1))
        continue
    fi
    dis="$("$OBJDUMP" -d "$path")"
    # Count arg-spill prologues (`movq %rdi, -N(%rbp)` / `movl %edi, -N(%rbp)`),
    # which clang emits in nearly every -O0 function and almost never at -O2.
    total_funcs=$(printf '%s\n' "$dis" | grep -cE '^[0-9a-f]+ <.*>:' || true)
    fp_prologues=$(printf '%s\n' "$dis" | grep -cE 'movq[[:space:]]+%rsp, %rbp' || true)
    o0_spills=$(printf '%s\n' "$dis" | grep -cE 'mov[ql][[:space:]]+%(rdi|edi), -0x[0-9a-f]+\(%rbp\)' || true)
    avx_cnt=$(printf '%s\n' "$dis" | grep -cE '\bv(mov|add|sub|mul|div)(ss|sd|ps|pd|aps|ups|dqa|dqu)\b' || true)
    ratio=0
    if [ "$total_funcs" -gt 0 ]; then
        ratio=$(( o0_spills * 100 / total_funcs ))
    fi
    printf "%-18s funcs=%-5d fp_prologues=%-5d o0_arg_spills=%-4d (%d%%)  avx=%d\n" \
        "$mod" "$total_funcs" "$fp_prologues" "$o0_spills" "$ratio" "$avx_cnt"
    if [ "$total_funcs" -gt 20 ] && [ "$ratio" -gt 15 ]; then
        echo "FAIL: $mod looks unoptimized (-O0): $o0_spills/$total_funcs ($ratio%) functions spill %rdi/%edi to -N(%rbp)"
        fail=$((fail + 1))
    fi
    if [ "$total_funcs" -gt 20 ] && [ "$fp_prologues" -lt $(( total_funcs / 5 )) ]; then
        echo "FAIL: $mod lost frame pointers ($fp_prologues/$total_funcs) — keep -fno-omit-frame-pointer for sample(1)"
        fail=$((fail + 1))
    fi
    if [ "$avx_cnt" -gt 0 ]; then
        echo "FAIL: $mod contains $avx_cnt AVX instructions (must stay within Rosetta 2 SSE4.2 baseline)"
        fail=$((fail + 1))
    fi
done

# 4. If vendor/proton-wine/build/Makefile exists, also verify recorded flags directly.
mk="$PROJECT_DIR/vendor/proton-wine/build/Makefile"
if [ -f "$mk" ]; then
    echo ""
    echo "--- Build Makefile flag check ---"
    if grep -qE '^CFLAGS = .*-O2.*-fno-omit-frame-pointer.*-msse4\.2' "$mk" && \
       grep -qE '^i386_CFLAGS = .*-O2.*-msse2.*-mfpmath=sse' "$mk" && \
       grep -qE '^x86_64_CFLAGS = .*-O2.*-msse4\.2' "$mk"; then
        echo "PASS: Makefile records optimized unix CFLAGS, i386_CFLAGS (-mfpmath=sse), and x86_64_CFLAGS"
    else
        echo "FAIL: Makefile missing expected optimization flags:"
        grep -E '^(CFLAGS|i386_CFLAGS|x86_64_CFLAGS) =' "$mk" || true
        fail=$((fail + 1))
    fi
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo "FAILED ($fail codegen contract violation(s))"
    exit 1
fi
echo "ALL CODEGEN CONTRACT CHECKS PASSED"

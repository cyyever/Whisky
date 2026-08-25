#!/usr/bin/env bash
#
# catch-crash — attach to a running Wine process and stop the moment a thread
# takes EXC_BAD_ACCESS, then dump where.
#
#   tests/catch-crash.sh [pid | name-fragment] [timeout-seconds]
#
# WHY this rather than capture-freeze.sh. A fault in native code reached from a
# Wine PE thread does not kill the process here: Rosetta retries the faulting
# instruction forever, so the thread burns a core and the application wedges
# without ever producing a crash report. By the time anyone notices, neither
# tool can read it --
#
#   * `sample` cannot unwind Wine PE threads under Rosetta. Every frame comes
#     back as __wine_syscall_dispatcher recursing into itself; 81 of 83 samples
#     of the faulting thread carried no information at all.
#   * lldb attached to a target that already has a pending EXC_BAD_ACCESS does
#     not run its command list, and detaching delivers the exception and kills
#     the process. Three specimens were lost that way.
#
# So arm the exception BEFORE it happens and let lldb stop on it. `continue`
# blocks until that stop, and the backtrace taken there is the real one.
#
# -p false: do not pass the exception to the target, which is what makes the
# Rosetta retry loop stop rather than resume.
set -uo pipefail

TARGET="${1:-SSFIV}"
WAIT="${2:-600}"
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    PID="$TARGET"
else
    # Exclude this script and its children. capture-freeze.sh had exactly this
    # bug -- invoked as `catch-crash.sh SSFIV`, the fragment is in our own
    # command line, so a plain grep attaches lldb to ourselves and then waits
    # out the full timeout for a fault that cannot come.
    PID=$(ps ax -o pid,command | grep -i "$TARGET" | grep -v grep |
          grep -v "catch-crash" | awk '{print $1}' |
          grep -vx "$$" | head -1)
fi
[ -n "${PID:-}" ] || { echo "no process matching '$TARGET'"; exit 1; }
kill -0 "$PID" 2>/dev/null || { echo "pid $PID is gone"; exit 1; }

OUT="${TMPDIR:-/tmp}/crash-$PID-$(date +%H%M%S).txt"
echo "armed on pid $PID, waiting up to ${WAIT}s -- reproduce the fault now"
echo "output: $OUT"

timeout "$WAIT" lldb -p "$PID" --batch \
    -o "process handle -s true -p false EXC_BAD_ACCESS" \
    -o "continue" \
    -o "thread backtrace all" \
    -o "register read" \
    -o "detach" > "$OUT" 2>&1
rc=$?

echo
if [ "$rc" = 124 ]; then
    # `timeout` SIGTERMs lldb while it is still attached and inside `continue`,
    # before its `detach` command ever runs -- and a debugger dying attached can
    # take the inferior with it. Say which happened rather than implying the
    # specimen survived.
    if kill -0 "$PID" 2>/dev/null; then
        echo "TIMED OUT with no fault; pid $PID is still alive."
        echo "The wedge this time was not a crash."
    else
        echo "TIMED OUT with no fault, and pid $PID is GONE -- killing lldb while"
        echo "it was attached took the target with it. The specimen is lost."
    fi
    exit 3
fi

if ! grep -q "stop reason = EXC_BAD_ACCESS" "$OUT"; then
    # lldb exits non-zero for "attach failed" (no entitlement, needs sudo,
    # target already exited) and the report below would then print two empty
    # sections and exit 0, which reads exactly like "attached, saw no fault".
    echo "NO FAULT CAPTURED (lldb exit $rc). First lines of its output:"
    sed -n '1,6p' "$OUT" | sed 's/^/  /'
    echo "full output: $OUT"
    exit 4
fi

echo "=== the faulting thread ==="
grep -B2 -A14 "stop reason = EXC_BAD_ACCESS" "$OUT" | sed 's/^ *//' | head -24
echo
echo "=== which module ==="
grep -A14 "stop reason = EXC_BAD_ACCESS" "$OUT" |
    grep -oE "in [a-zA-Z0-9_.+-]+\`" | sort | uniq -c | sort -rn | head -6
echo
echo "full output: $OUT"

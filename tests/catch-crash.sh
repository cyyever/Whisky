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
    PID=$(ps ax -o pid,command | grep -i "$TARGET" | grep -v grep | awk '{print $1}' | head -1)
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
    echo "TIMED OUT with no fault. The wedge this time was not a crash."
    exit 3
fi

echo "=== the faulting thread ==="
grep -B2 -A14 "stop reason = EXC_BAD_ACCESS" "$OUT" | sed 's/^ *//' | head -24
echo
echo "=== which module ==="
grep -A14 "stop reason = EXC_BAD_ACCESS" "$OUT" |
    grep -oE "in [a-zA-Z0-9_.+-]+\`" | sort | uniq -c | sort -rn | head -6
echo
echo "full output: $OUT"

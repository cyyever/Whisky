#!/usr/bin/env bash
#
# capture-freeze — harvest everything from a wedged Wine process, in one shot.
#
#   tests/capture-freeze.sh [pid | name-fragment]
#
# Defaults to the SSFIV process. Writes into a timestamped directory and
# prints the summary that usually decides where to look next.
#
# WHY a script. A freeze is a live specimen with a short life -- the user
# closes the game, or it is killed to free the bottle -- and typing four
# commands at it loses the first one to a typo. It also encodes two things
# learned the hard way:
#
#   * `sample` cannot find a spin. It samples every thread whether running or
#     not, so the hottest "top of stack" is whatever blocking primitive most
#     threads sit in. `ps -M` reports per-thread CPU time and is what actually
#     names the thread that is burning.
#   * The distinction that matters most is which wait it is in. Four SSFIV
#     freezes were in [CAMetalLayer nextDrawable] with an exhausted drawable
#     pool; two were nowhere near it, with winegstreamer deadlocked at the
#     application boundary instead. Those are different bugs and the grep for
#     each is worth having built in.
set -uo pipefail

TARGET="${1:-SSFIV}"
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
    PID="$TARGET"
else
    PID=$(ps ax -o pid,command | grep -i "$TARGET" | grep -v grep | awk '{print $1}' | head -1)
fi
[ -n "${PID:-}" ] || { echo "no process matching '$TARGET'"; exit 1; }
kill -0 "$PID" 2>/dev/null || { echo "pid $PID is gone"; exit 1; }

OUT="${TMPDIR:-/tmp}/freeze-$PID-$(date +%H%M%S)"
mkdir -p "$OUT"
echo "pid $PID -> $OUT"
echo

# Per-thread CPU first: it is the cheapest, and a thread with minutes of user
# time is the whole answer when the freeze is a spin rather than a wait.
ps -M -p "$PID" > "$OUT/threads.txt" 2>&1
echo "=== busiest threads (UTIME) ==="
sort -k7 -rn "$OUT/threads.txt" | head -4

# Then the stacks. lldb detaches itself; a stopped process left behind would
# look exactly like the freeze under investigation.
echo
echo "=== capturing stacks ==="
timeout 120 lldb -p "$PID" -b -o "thread backtrace all" -o detach > "$OUT/stacks.txt" 2>&1
nthreads=$(grep -c 'thread #' "$OUT/stacks.txt")
echo "threads: $nthreads"

# A capture that got a handful of threads is a FAILED capture, not a process
# with a handful of threads: lldb's command list does not run when the target
# has a pending exception, and it leaves behind an attach banner plus one or
# two stop reasons. Classifying that as a freeze type invents a finding out of
# a broken measurement.
if [ "$nthreads" -lt 10 ]; then
    echo
    echo "INCOMPLETE: lldb returned only $nthreads thread(s) -- its command list did"
    echo "not run. Check stacks.txt for a stop reason: an EXC_BAD_ACCESS there means"
    echo "the process CRASHED rather than hung, and that is the finding."
    grep -E "stop reason = (EXC|signal SIG)" "$OUT/stacks.txt" | grep -v SIGSTOP | sed 's/^ */  /'
    echo
    echo "saved: $OUT"
    exit 2
fi

echo
echo "=== which freeze is it ==="
dr=$(grep -c "nextDrawable" "$OUT/stacks.txt")
gs=$(grep -c "sink_chain_cb" "$OUT/stacks.txt")
echo "  nextDrawable frames : $dr   $([ "$dr" -gt 0 ] && echo '<- drawable pool')"
echo "  sink_chain_cb frames: $gs   $([ "$gs" -gt 0 ] && echo '<- winegstreamer app boundary')"
[ "$dr" = 0 ] && [ "$gs" = 0 ] && echo "  neither -- a third kind; read stacks.txt"

echo
echo "=== dxvk-submit ==="
awk "/name = 'dxvk-submit'/,/^\$/" "$OUT/stacks.txt" |
    grep "frame #" | head -6 | sed 's/^ *//;s/0x[0-9a-f]* //'

LOG=$(ls -t ~/Library/Logs/com.isaacmarovitz.Whisky/*.log 2>/dev/null | head -1)
if [ -n "$LOG" ]; then
    cp "$LOG" "$OUT/whisky.log"
    echo
    echo "=== last PROBE lines ==="
    grep "PROBE" "$LOG" | tail -6 | sed 's/^[0-9a-f]*://'
fi

echo
echo "saved: $OUT"

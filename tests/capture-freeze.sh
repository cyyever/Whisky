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
    # Exclude this script and its children: invoking it as
    # `capture-freeze.sh SSFIV` puts the fragment in our own command line, and
    # a plain grep then matches -- and attaches lldb to -- ourselves.
    PID=$(ps ax -o pid,command | grep -i "$TARGET" | grep -v grep |
          grep -v "capture-freeze" | awk '{print $1}' |
          grep -vx "$$" | head -1)
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

# `sample` FIRST, and always. It is non-invasive, while attaching lldb to a
# process that has a pending EXC_BAD_ACCESS and then detaching lets the
# exception be delivered -- the process dies on the spot. That destroyed two
# specimens of the dxvk-shader-n crash before the order was fixed, and each one
# costs a full reproduction to get back.
echo
echo "=== sampling (non-invasive) ==="
if sample "$PID" 3 -f "$OUT/sample.txt" >/dev/null 2>&1; then
    echo "  saved sample.txt ($(wc -l < "$OUT/sample.txt" | tr -d ' ') lines)"
    awk '/Sort by top of stack/,0' "$OUT/sample.txt" | head -6 | sed 's/^/  /'
else
    echo "  sample failed (needs sudo, or the process is already a zombie)"
fi

# Then the stacks. lldb detaches itself; a stopped process left behind would
# look exactly like the freeze under investigation.
echo
echo "=== capturing stacks (lldb -- may kill a crashed target) ==="
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

# A second capture, and the difference between the two. One snapshot cannot
# tell a wedged thread from a spinning one: a thread cycling through short
# waits is inside some wait every time you look, so the classifier below called
# a dxvk-submit that was looping in the drawable-acquire path "a third kind".
# What moved between two captures is the thread that is actually running.
sleep 3
timeout 120 lldb -p "$PID" --batch -o "thread backtrace all" -o detach > "$OUT/stacks2.txt" 2>&1

echo
echo "=== which threads MOVED (these are running, not wedged) ==="
python3 - "$OUT/stacks.txt" "$OUT/stacks2.txt" <<'EOF'
import sys, re

def load(path):
    out, cur, frames = {}, None, []
    for line in open(path, errors="ignore"):
        m = re.match(r"\s*thread #(\d+)(?:, name = '([^']+)')?", line)
        if m:
            if cur:
                out[cur] = tuple(frames[:4])
            cur, frames = m.group(2) or "#" + m.group(1), []
        elif "frame #" in line:
            frames.append(re.sub(r"\s+", " ", re.sub(r"0x[0-9a-f]+", "", line)).strip())
    if cur:
        out[cur] = tuple(frames[:4])
    return out

# Keyed by NAME, not index: thread indices shift between captures as threads
# come and go, and pairing by position compares unrelated threads.
a, b = load(sys.argv[1]), load(sys.argv[2])
named = [k for k in a if not k.startswith("#") and k in b]
moved = [k for k in named if a[k] != b[k]]
print(f"  named threads: {len(named)}, moved: {len(moved)}")
for k in moved[:5]:
    print(f"    {k}")
    print(f"      was: {a[k][1] if len(a[k]) > 1 else a[k]}")
    print(f"      now: {b[k][1] if len(b[k]) > 1 else b[k]}")
if not moved:
    print("    none -- every named thread is genuinely blocked")
EOF

echo
echo "=== which freeze is it (both captures) ==="
for f in stacks.txt stacks2.txt; do
    dr=$(grep -c "nextDrawable" "$OUT/$f")
    gs=$(grep -c "sink_chain_cb" "$OUT/$f")
    echo "  $f: nextDrawable=$dr sink_chain_cb=$gs"
done

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

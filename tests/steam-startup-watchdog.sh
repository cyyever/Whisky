#!/bin/bash
#
# steam-startup-watchdog.sh — capture the intermittent "Steam has no UI" hang
# the next time it happens on its own.
#
#   tests/steam-startup-watchdog.sh [out-dir]        # leave it running while you work
#
# Why a watchdog and not a reproducer: `tests/steam-startup-loop.sh` relaunched
# Steam ten times from a clean, warm state and every one came up fine, so the
# conditions that produce the fault are not in that loop. It does happen several
# times an evening during ordinary use. So stop trying to provoke it and instead
# make the next natural occurrence produce a full diagnosis.
#
# Signature watched for: Steam.exe alive, exactly ONE steamwebhelper (healthy is
# 4-6), and zero visible top-level windows -- sustained, so a launch that is
# merely still starting is not mistaken for the fault.
#
# On a hit it captures and EXITS WITHOUT KILLING ANYTHING, so the live processes
# are still there to poke at. Everything that evaporates is taken first.
set -u

OUT="${1:-/tmp/steam-hang-$(date +%Y%m%d-%H%M%S)}"

BOTTLE="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles/7935D389-D184-4BAD-A127-6CE3473A9BD0"
WHISKY_LIB="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"
WINEBIN="$WHISKY_LIB/bin"
STEAM_DIR="$BOTTLE/drive_c/Program Files (x86)/Steam"
PROBE="$(cd "$(dirname "$0")" && pwd)/window-pump-test.exe"
WHISKY_LOGS="$HOME/Library/Logs/com.isaacmarovitz.Whisky"

POLL=5          # seconds between cheap process checks
STABLE=60       # seconds the signature must hold before it counts

steam_pid()   { pgrep -f 'Steam\\Steam\.exe' 2>/dev/null | head -1; }
browser_pid() { pgrep -f 'steamwebhelper\.exe.*-steampid=' 2>/dev/null | head -1; }
helper_count() { pgrep -f 'steamwebhelper\.exe' 2>/dev/null | wc -l | tr -d ' '; }

# The window probe costs a whole wine process, so it only runs once the cheap
# check already matches. It also must not be the thing that decides "healthy":
# its exit code counts NON-PUMPING windows, which is 0 both for a healthy Steam
# and for a Steam with no windows at all. Parse the count out of the text.
visible_windows() {
    (cd "$WINEBIN" && env -i \
        WINEPREFIX="$BOTTLE" WINEDEBUG=-all \
        DYLD_FALLBACK_LIBRARY_PATH="$WHISKY_LIB/lib" \
        "$WINEBIN/wine64" "$PROBE" 2>/dev/null) \
        | sed -n 's/^\([0-9][0-9]*\) visible window(s).*/\1/p' | head -1
}

capture() {
    local sp="$1" bp="$2"
    mkdir -p "$OUT"
    echo "=== HIT: capturing to $OUT ==="

    # 1. Stacks first -- the only evidence that disappears if anything changes.
    for pid in $(pgrep -f 'Steam\\Steam\.exe|steamwebhelper\.exe|winedevice\.exe|wineserver'); do
        sample "$pid" 3 -f "$OUT/sample-$pid.txt" >/dev/null 2>&1
    done

    # 2. Is the prefix even still alive? A capture taken after a `wineserver -k`
    #    (which quitting Whisky or running `make app` does) shows wedged
    #    survivors that look exactly like this fault but are not it -- that
    #    mistake cost most of an afternoon on 2026-08-08. The socket's presence
    #    is what tells the two apart, so it is recorded, not assumed.
    {
        echo "date: $(date -u +%FT%TZ)"
        echo "steam.exe pid: ${sp:-none}"
        echo "browser webhelper pid: ${bp:-none}"
        echo "webhelper count: $(helper_count)"
        echo "visible windows: $(visible_windows)"
        echo
        echo "wineserver process: $(pgrep -lf wineserver || echo NONE)"
        echo "wineserver socket dir:"
        ls -la /tmp/.wine-"$(id -u)"/server-*/ 2>&1
        echo
        echo "Whisky.app running: $(pgrep -f '/Applications/Whisky.app' >/dev/null && echo yes || echo no)"
    } >"$OUT/state.txt" 2>&1

    ps -eo pid,ppid,etime,%cpu,args >"$OUT/ps.txt" 2>&1

    # 3. Logs. cef_log.txt now carries the CEF children's own account of why they
    #    exit (patch 0025 adds --enable-logging --v=1); the Whisky run log carries
    #    the Wine side, including +process exit codes when Steam.exe's per-program
    #    WINEDEBUG asks for them.
    for f in cef_log.txt webhelper.txt bootstrap_log.txt console_log.txt \
             connection_log.txt steamui_system.txt; do
        cp "$STEAM_DIR/logs/$f" "$OUT/" 2>/dev/null
    done
    ls -t "$WHISKY_LOGS"/*.log 2>/dev/null | head -3 | while read -r f; do
        cp "$f" "$OUT/whisky-$(basename "$f")" 2>/dev/null
    done

    # 4. The in-tree tracers, for every wine process still up.
    for pid in $(pgrep -f 'Steam\\Steam\.exe|steamwebhelper\.exe|winedevice\.exe'); do
        for t in mring segv modmap vprot; do
            cp "/tmp/${t}_$pid.log" "$OUT/${t}_$pid.log" 2>/dev/null
        done
    done

    echo "=== captured. Processes left running on purpose -- go look at them. ==="
    echo "    $OUT"
}

echo "watching (poll ${POLL}s, signature must hold ${STABLE}s); Ctrl-C to stop"
held=0
while :; do
    sleep "$POLL"
    sp="$(steam_pid)"
    if [ -z "$sp" ]; then held=0; continue; fi
    if [ "$(helper_count)" != 1 ]; then held=0; continue; fi

    wins="$(visible_windows)"
    if [ -n "$wins" ] && [ "$wins" -ge 1 ]; then held=0; continue; fi

    held=$(( held + POLL ))
    echo "  signature held ${held}s (steam=$sp, 1 webhelper, ${wins:-?} windows)"
    [ "$held" -lt "$STABLE" ] && continue

    capture "$sp" "$(browser_pid)"
    exit 0
done

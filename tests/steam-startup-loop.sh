#!/bin/bash
#
# steam-startup-loop.sh — measure how often Steam fails to bring up its UI.
#
# The failure this exists for is intermittent: Steam starts, ends up with a
# single steamwebhelper (healthy is 4-6), zero visible windows and low CPU, and
# the only way out is to kill it and try again. A single observation of an
# intermittent fault proves nothing, and every A/B against it (msync on/off,
# Vulkan, DXMT) is unreadable without a failure *rate* to compare against. So:
# run the launch N times, classify each round, and keep the evidence from the
# rounds that fail.
#
#   tests/steam-startup-loop.sh [rounds] [out-dir]
#   LOAD=1 tests/steam-startup-loop.sh 15        # same, under CPU contention
#
# Each round: kill everything -> launch -> poll for the healthy shape -> on
# timeout, capture the crime scene (process list, `sample` of steam.exe and the
# browser webhelper, CEF log) into out-dir/round-NN/.
#
# LOAD=1 saturates every core for the whole run. A clean, warm, back-to-back
# relaunch went 10/10 on 2026-08-08 without reproducing the fault at all, so the
# conditions that do produce it are not in that loop; heavy build load is the
# candidate that was most often true when it was seen by hand. Contention is a
# legitimate lever here rather than a shot in the dark -- the fault's signature
# (a CEF child connects, then vanishes) is the shape a startup race takes.
#
# WHAT THIS REPLICATES. Whisky's GUI launch is Program.launch() ->
# Wine.runProgram(): `wine64 start /unix <exe>`, cwd = the Wine bin folder, and
# a *replaced* environment (Swift's Process.environment does not merge with the
# parent) -- hence `env -i` and the explicit list below. It is constructed from
# Wine.constructWineEnvironment() + the bottle's Metadata.plist + the
# per-program Steam.exe.plist, so it must be re-checked when any of those
# change.
#
# A bare `wine 'C:\Program Files (x86)\Steam\Steam.exe'` is NOT equivalent and
# must not be used. It was once thought that `Client version: no bootstrapper
# found` in logs/webhelper.txt marked such a non-equivalent launch; it does not
# -- runs through this script log that line and come up with a full, working UI.
# The only trustworthy verdict is the observable one this script checks for.
#
# DO NOT quit Whisky.app while this runs. AppDelegate.applicationWillTerminate
# calls killBottles() -> `wineserver -k`, which tears down the prefix mid-round
# and leaves surviving processes wedged in a way that looks like a new bug. For
# the same reason, do not run `make app` (it quits Whisky to install).
set -u

ROUNDS="${1:-10}"
OUT="${2:-/tmp/steam-startup-loop}"

BOTTLE="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles/7935D389-D184-4BAD-A127-6CE3473A9BD0"
WHISKY_LIB="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"
WINEBIN="$WHISKY_LIB/bin"
WINELIB="$WHISKY_LIB/lib"
STEAM_DIR="$BOTTLE/drive_c/Program Files (x86)/Steam"
STEAM_EXE="$STEAM_DIR/Steam.exe"
PROBE="$(cd "$(dirname "$0")" && pwd)/window-pump-test.exe"

# How long to give a launch before calling it hung. A healthy launch reaches the
# UI in well under a minute here; 150 s is slack for a slow content-server day,
# not a guess at the fault's timescale.
DEADLINE=150

wine_env() {
    env -i \
        WINEPREFIX="$BOTTLE" \
        WINEDEBUG="${WINEDEBUG:--all}" \
        WINE_DISABLE_IPV6=1 \
        DYLD_FALLBACK_LIBRARY_PATH="$WINELIB" \
        GST_DEBUG=1 \
        WINE_NX_COMPAT=1 \
        SDL_JOYSTICK_MFI=0 \
        PROTON_DISABLE_LSTEAMCLIENT=1 \
        WINEMSYNC_NO_MANUALEVENT=1 \
        WHISKY_HIDE_VIRTUAL_AUDIO=1 \
        WINE_MRING="${WINE_MRING:-1}" \
        WINE_SEGV_TRACE="${WINE_SEGV_TRACE:-1}" \
        ${WINE_SIMULATE_WRITECOPY:+WINE_SIMULATE_WRITECOPY="$WINE_SIMULATE_WRITECOPY"} \
        "$@"
}

# WSTRACE=1: run the wineserver under its own request trace, which is the only
# way to answer "what is this thread waiting on". Its `select( ... timeout=...,
# data={WAIT,handles={....}} )` / `select() = PENDING` pairs name the objects a
# thread blocked on and whether it was ever woken -- which `sample` cannot tell
# us, because a thread parked from Rosetta-translated code shows one JIT frame
# and nothing below it.
#
# The server has to be started FIRST and left running, so the client attaches to
# it instead of spawning an untraced one of its own. Tracing the clients too
# (WINEDEBUG=+server) would be the obvious thing and is the wrong one: it
# instruments every process in the tree, and a firehose that size perturbs the
# startup being measured -- WINEDEBUG=+virtual wrote 53 MB in a minute and left
# Steam with no window, i.e. it manufactured the very fault it was watching for.
#
# Register dumps are dropped: `contexts={{machine=...}}` lines carry the entire
# CPU state and are by far the longest, while the handle sets we need are on the
# lines without them.
WSTRACE_LOG="${WSTRACE_LOG:-/tmp/wineserver-trace.log}"

# This bottle's server directory, derived the way Wine derives it: the prefix's
# device and inode in hex. Globbing /tmp/.wine-<uid>/server-*/ instead is wrong
# twice over -- every prefix the user has ever run leaves its own directory, so
# `[` gets several arguments and errors out, and the one that matches may belong
# to a different bottle.
server_dir() {
    set -- $(stat -f '%d %i' "$BOTTLE" 2>/dev/null)
    [ -n "${1:-}" ] || return 1
    printf '/tmp/.wine-%s/server-%x-%x\n' "$(id -u)" "$1" "$2"
}

start_traced_server() {
    [ "${WSTRACE:-0}" = 1 ] || return 0
    local dir sock
    dir="$(server_dir)" || { echo "WARNING: cannot derive the server dir" >&2; return 0; }
    sock="$dir/socket"

    # cleanup() SIGKILLs the wineserver, which skips its atexit unlink, so the
    # previous round's socket inode is still sitting there. Without removing it
    # the readiness poll below matches that dead socket on its first iteration
    # and returns before the traced server has bound -- and a client that starts
    # in that window forks an untraced server of its own, which may win the lock.
    # The round then runs with no trace and looks exactly like one that worked.
    rm -f "$sock"

    : >"$WSTRACE_LOG"
    ( cd "$WINEBIN" && wine_env "$WINEBIN/wineserver" -f -d1 -p 2>&1 \
        | grep --line-buffered -v 'contexts={{machine=' >>"$WSTRACE_LOG" ) &

    # Now the socket's existence means our server created it, and nothing else.
    for _ in $(seq 1 20); do
        [ -S "$sock" ] && return 0
        sleep 0.5
    done
    echo "WARNING: traced wineserver never bound $sock -- this round would run" \
         "untraced; treat its result as unmeasured" >&2
}

# Kill everything and *wait for it to be gone*. A survivor from the previous
# round makes the next one fail inside msync_init ("Failed to open msync shared
# memory file"), which looks nothing like the fault being measured and has
# invalidated whole sessions of msync A/B work before.
cleanup() {
    (cd "$WINEBIN" && wine_env "$WINEBIN/wineserver" -k) >/dev/null 2>&1
    pkill -9 -f 'Steam\.exe|steamwebhelper|steamservice|GameOverlayUI|winedevice|wineserver' >/dev/null 2>&1
    for _ in $(seq 1 30); do
        pgrep -f 'Steam\.exe|steamwebhelper|wineserver' >/dev/null 2>&1 || return 0
        sleep 1
    done
    echo "WARNING: processes survived cleanup:" >&2
    pgrep -lf 'Steam\.exe|steamwebhelper|wineserver' >&2
}

# macOS `pgrep` has no `-c`, so count lines. `wc -l` also gives a clean 0 for the
# no-match case, where pgrep prints nothing and exits 1.
webhelper_count() { pgrep -f 'steamwebhelper\.exe' 2>/dev/null | wc -l | tr -d ' '; }

# The CEF browser process is the one Steam itself launched, identifiable by the
# -steampid= argument; its children carry --type= instead.
browser_pid() { pgrep -f 'steamwebhelper\.exe.*-steampid=' 2>/dev/null | head -1; }

# Match the trailing `\Steam.exe` of the Windows path. Plain `Steam.exe` would
# also hit the webhelper, whose command line quotes the client's own path.
steam_pid() { pgrep -f 'Steam\\Steam\.exe' 2>/dev/null | head -1; }

# Visible top-level windows, via the in-bottle probe. Its exit code is the count
# of *non-pumping* windows, so parse the line instead: 0 windows and 0 hung
# windows are the same exit code but opposite verdicts.
visible_windows() {
    (cd "$WINEBIN" && wine_env "$WINEBIN/wine64" "$PROBE" 2>/dev/null) \
        | sed -n 's/^\([0-9][0-9]*\) visible window(s).*/\1/p' | head -1
}

LOAD_PIDS=""
start_load() {
    [ "${LOAD:-0}" = 1 ] || return 0
    ncpu=$(sysctl -n hw.ncpu)
    for _ in $(seq 1 "$ncpu"); do
        ( while :; do :; done ) &
        LOAD_PIDS="$LOAD_PIDS $!"
    done
    echo "load: $ncpu busy loops (pids:$LOAD_PIDS)"
}
stop_load() { [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null; LOAD_PIDS=""; }
trap 'stop_load' EXIT INT TERM

mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
: >"$SUMMARY"
start_load

pass=0
fail=0

for round in $(seq 1 "$ROUNDS"); do
    dir="$(printf '%s/round-%02d' "$OUT" "$round")"
    mkdir -p "$dir"
    cleanup
    start_traced_server

    started=$(date +%s)
    (cd "$WINEBIN" && wine_env "$WINEBIN/wine64" start /unix "$STEAM_EXE") \
        >"$dir/launch.log" 2>&1

    verdict=TIMEOUT
    while [ $(( $(date +%s) - started )) -lt "$DEADLINE" ]; do
        sleep 10
        helpers=$(webhelper_count)
        # Healthy is several webhelpers *and* a window on screen. Either alone is
        # not enough: the fault shows exactly one helper and no window, and a
        # window can exist for a few seconds before the tree collapses.
        if [ "$helpers" -ge 3 ]; then
            wins=$(visible_windows)
            if [ -n "$wins" ] && [ "$wins" -ge 1 ]; then
                verdict=OK
                break
            fi
        fi
    done

    elapsed=$(( $(date +%s) - started ))
    helpers=$(webhelper_count)

    if [ "$verdict" = OK ]; then
        pass=$(( pass + 1 ))
    else
        fail=$(( fail + 1 ))
        # Capture before anything else touches the prefix. `sample` first: it is
        # the only evidence that evaporates.
        bp=$(browser_pid); sp=$(steam_pid)
        [ -n "$sp" ] && sample "$sp" 3 -f "$dir/sample-steam.txt" >/dev/null 2>&1
        [ -n "$bp" ] && sample "$bp" 3 -f "$dir/sample-webhelper.txt" >/dev/null 2>&1
        ps -eo pid,ppid,etime,%cpu,args >"$dir/ps.txt" 2>&1
        cp "$STEAM_DIR/logs/cef_log.txt" "$dir/" 2>/dev/null
        cp "$STEAM_DIR/logs/webhelper.txt" "$dir/" 2>/dev/null
        cp "$STEAM_DIR/logs/bootstrap_log.txt" "$dir/" 2>/dev/null
        for pid in $sp $bp; do
            cp "/tmp/mring_$pid.log" "$dir/mring_$pid.log" 2>/dev/null
            cp "/tmp/segv_$pid.log" "$dir/segv_$pid.log" 2>/dev/null
        done
        # The tail of the server trace, not the whole thing: a Steam startup
        # produces hundreds of MB of it, and what matters is the last select()
        # each thread issued and whether a *wakeup* ever followed. Kept per
        # round because the next round truncates the live file.
        if [ "${WSTRACE:-0}" = 1 ] && [ -s "$WSTRACE_LOG" ]; then
            tail -c "${WSTRACE_TAIL:-40000000}" "$WSTRACE_LOG" >"$dir/wineserver-trace-tail.log"
            echo "  server trace: $(du -h "$dir/wineserver-trace-tail.log" | cut -f1)" \
                 "of $(du -h "$WSTRACE_LOG" | cut -f1) total"
        fi
    fi

    printf 'round %02d  %-7s  %3ds  webhelpers=%s\n' \
        "$round" "$verdict" "$elapsed" "$helpers" | tee -a "$SUMMARY"
done

cleanup
printf '\n%d/%d OK, %d failed\n' "$pass" "$ROUNDS" "$fail" | tee -a "$SUMMARY"

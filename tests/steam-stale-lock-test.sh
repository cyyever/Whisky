#!/usr/bin/env bash
#
# steam-stale-lock-test — assert no bottle carries the state a killed Steam
# leaves behind.
#
# Steam's CEF holds Chromium's singleton lock plus a LevelDB LOCK per store
# under htmlcache, and Steam keeps a .crash marker it deletes only on a clean
# exit. After a SIGKILL -- Whisky's own reapSteamProcesses uses SIGKILL, and so
# does any crash or wineserver death -- all of it survives. The next launch then
# comes up in a distinctive shape: the browser process runs but spawns no
# renderers and creates no window, so Steam sits with no UI at low CPU.
#
# That reads as "Steam hangs on startup, sometimes", and the "sometimes" is the
# tell: whether it happens is decided entirely by how the *previous* session
# ended. It cost a debugging session, during which several unrelated Wine
# changes were wrongly suspected because the symptom came and went.
#
# Steam.clearStaleLocks (WhiskyKit/.../Steam+LaunchGuard.swift) now runs at the
# end of every reap, so a bottle should never be found in this state while Steam
# is not running. If this test fails with no Steam running, that call regressed.
#
# Only .crash is asserted on, and that is deliberate. The two obvious-looking
# candidates are not usable as evidence:
#
#   - htmlcache/*/LOCK -- LevelDB never unlinks these. Measured: after deleting
#     all of them, a *healthy* Steam recreated 25 within the hour, and they
#     outlive a clean exit. Their presence says nothing about how the last
#     session ended, so asserting on them would fail on every good machine.
#   - htmlcache/lockfile -- present throughout a normal run, and whether it
#     survives a clean exit was not established. Not a discriminator until it is.
#
# .crash is the one Steam itself deletes on a clean exit, so it means exactly
# what this test needs it to mean. The clearing code removes all three, since
# removing the others is harmless and cheap; the test only claims what it can
# actually tell apart.
#
# Run: tests/steam-stale-lock-test.sh [bottle-dir]   # exit 0 = clean
#      With no argument, checks every bottle.
set -uo pipefail

. "$(dirname "$0")/lib/bottles.sh"

# A live Steam legitimately holds every one of these, so the check is only
# meaningful when none is running.
if pgrep -f "steamwebhelper" >/dev/null 2>&1 || pgrep -f "Steam.exe" >/dev/null 2>&1; then
    echo "SKIP: Steam is running -- these locks are held legitimately while it is up"
    exit 0
fi

select_bottles "$@"
stale=0

for bottle in "${bottles[@]}"; do
    steam_dir="$bottle/drive_c/Program Files (x86)/Steam"
    [ -d "$steam_dir" ] || continue
    echo "=== $(basename "$bottle")"

    crash="$steam_dir/.crash"
    if [ -f "$crash" ]; then
        echo "  !! Steam/.crash  ($(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$crash"))"
        echo "       Steam deletes this on a clean exit; its presence makes the next"
        echo "       start take the crash-recovery path."
        stale=$((stale + 1))
    fi

done

echo
if [ "$stale" -gt 0 ]; then
    echo "FAIL: $stale stale item(s) with no Steam running."
    echo "      Steam.clearStaleLocks should have removed these during the last reap."
    exit 1
fi

echo "ok: no stale Steam lock state"
exit 0

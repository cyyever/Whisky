/*
 * window-snap-test — assert the borderless-fullscreen snap (patches/proton-wine/0023)
 * moves exactly the windows it should and no others, and that Wine's own idea of
 * the window position agrees with where the window ended up.
 *
 * Why the snap exists: rcWork and rcMonitor share an origin on Windows (the
 * taskbar is at the bottom) but not on macOS (the menu bar is at the top). An
 * app that positions at the work-area origin while sizing to the full monitor
 * is self-consistent only on Windows; on macOS it lands one menu-bar height too
 * low, leaving the menu bar visible and clipping the bottom. Measured here:
 * rcMonitor 0,0 1470x956 / rcWork 0,33 1470x923.
 *
 * The second assertion per case is the one that matters most. The snap changes
 * the NSWindow frame behind Wine's back, so unless a frame-changed event pushes
 * the new origin back up, GetWindowRect keeps reporting the pre-snap position
 * and every click lands offset. Testing only "where is the window" would miss
 * that entirely.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O1 -o window-snap-test.exe window-snap-test.c -luser32
 * Run:
 *   wine window-snap-test.exe          # exit 0 = all cases pass
 */

#include <windows.h>
#include <stdio.h>

static int failures;
static RECT monitor_rc, work_rc;

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void pump(void)
{
    MSG msg;
    int i;

    /* The snap's frame-changed event comes back from the Cocoa side through the
     * driver's event queue, so it needs a few round trips, not just one. */
    for (i = 0; i < 20; i++)
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        Sleep(10);
    }
}

/* One case: place a window of `style` at (x,y) sized cx x cy, then check where
 * it ends up. `expect_snap` says whether the origin should have been corrected
 * to the monitor origin. */
static void check(const char *name, DWORD style, int x, int y, int cx, int cy,
                  BOOL expect_snap, BOOL allow_constraint)
{
    RECT got;
    HWND hwnd;
    int want_x = expect_snap ? monitor_rc.left : x;
    int want_y = expect_snap ? monitor_rc.top  : y;

    hwnd = CreateWindowExA(0, "WindowSnapTest", "snap", style, x, y, cx, cy,
                           NULL, NULL, GetModuleHandleA(NULL), NULL);
    if (!hwnd)
    {
        printf("FAIL %-38s CreateWindow failed (%lu)\n", name, GetLastError());
        failures++;
        return;
    }
    ShowWindow(hwnd, SW_SHOW);
    /* Re-apply the position after showing: the interesting path is a window
     * that is positioned while hidden and then shown, which is where the
     * frame-changed event was previously suppressed. */
    SetWindowPos(hwnd, NULL, x, y, cx, cy, SWP_NOZORDER | SWP_NOACTIVATE);
    pump();

    GetWindowRect(hwnd, &got);

    /* Compare against where the window was asked to go, not against a fixed
     * position: "must not be snapped" and "is at the monitor origin" are not
     * opposites — a window asked for the origin belongs there.
     *
     * allow_constraint covers AppKit's constrainFrameRect:toScreen:, which
     * refuses to put a titled window's title bar under the menu bar and pins
     * its top a couple of points below the work area. Measured: a titled window
     * asked for 0,33 and one asked for 0,0 both land at 0,35. Wine reports the
     * constrained position faithfully, which is correct, so the assertion is
     * "not moved up", not a pixel match macOS cannot deliver. */
    if (got.left == want_x && (got.top == want_y || (allow_constraint && got.top > want_y)))
        printf("PASS %-38s at %ld,%ld\n", name, got.left, got.top);
    else
    {
        printf("FAIL %-38s at %ld,%ld, wanted %d,%d%s\n", name, got.left, got.top,
               want_x, want_y,
               expect_snap ? "  (not snapped, or Wine was not told)"
                           : "  (moved when it should not be)");
        failures++;
    }
    DestroyWindow(hwnd);
    pump();
}

int main(void)
{
    WNDCLASSA wc = {0};
    MONITORINFO mi = { sizeof(mi) };
    int mon_w, mon_h;

    GetMonitorInfoA(MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY), &mi);
    monitor_rc = mi.rcMonitor;
    work_rc = mi.rcWork;
    mon_w = monitor_rc.right - monitor_rc.left;
    mon_h = monitor_rc.bottom - monitor_rc.top;

    printf("rcMonitor %ld,%ld %dx%d   rcWork %ld,%ld   work-origin offset %ld,%ld\n",
           monitor_rc.left, monitor_rc.top, mon_w, mon_h, work_rc.left, work_rc.top,
           work_rc.left - monitor_rc.left, work_rc.top - monitor_rc.top);

    if (work_rc.top == monitor_rc.top && work_rc.left == monitor_rc.left)
    {
        printf("SKIP  work area and monitor share an origin here, so the mismatch\n"
               "      this snap corrects cannot occur. (Expected on Windows.)\n");
        return 0;
    }

    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "WindowSnapTest";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&wc);

    /* The case the snap exists for: work-area origin, full-monitor size. */
    check("borderless, monitor-sized, work origin", WS_POPUP,
          work_rc.left, work_rc.top, mon_w, mon_h, TRUE, FALSE);

    /* Already correct — must not be touched. */
    check("borderless, monitor-sized, at origin", WS_POPUP,
          monitor_rc.left, monitor_rc.top, mon_w, mon_h, FALSE, FALSE);

    /* Deliberately placed elsewhere. Nothing about this says "the app confused
     * the work-area origin for the screen origin", so it must be left alone.
     * A heuristic keyed only on "borderless, monitor-sized, not at the origin"
     * moves this one. */
    check("borderless, monitor-sized, offset 100", WS_POPUP,
          monitor_rc.left + 100, monitor_rc.top + 100, mon_w, mon_h, FALSE, FALSE);

    /* Titled: has a title bar, so it is not a fullscreen game window. */
    check("titled, monitor-sized, work origin", WS_OVERLAPPEDWINDOW,
          work_rc.left, work_rc.top, mon_w, mon_h, FALSE, TRUE);

    /* One pixel short of the monitor in each axis: not a fullscreen window. */
    check("borderless, monitor-1px, work origin", WS_POPUP,
          work_rc.left, work_rc.top, mon_w - 1, mon_h - 1, FALSE, FALSE);

    /* Work-area *sized* as well as positioned: this app asked for the work area
     * and got it. Nothing to correct. */
    check("borderless, work-sized, work origin", WS_POPUP,
          work_rc.left, work_rc.top,
          work_rc.right - work_rc.left, work_rc.bottom - work_rc.top, FALSE, FALSE);

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "OK", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}

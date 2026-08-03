/* win-toplevel-visible-test.c — does a plain top-level window actually reach
 * the Mac driver and become a visible NSWindow?
 *
 * Steam's login window is created, sized (1102x659) and marked visible at the
 * Win32 layer, yet nothing appears on screen and winemac never logs
 * "creating ... window" — i.e. no NSWindow is made for it. This probe strips
 * that down to the smallest possible case so the failure can be attributed:
 *
 *   [A] a normal WS_OVERLAPPEDWINDOW top-level, shown with ShowWindow
 *   [B] the same, but created 0x0 and resized afterwards — Steam's CEF shape
 *       (CreateBrowser logs (-2147483648,-2147483648) 0x0 before the real size)
 *   [C] a child of the desktop window created with an explicit parent, which
 *       is how Steam's windows end up parented under hwnd 0x10020
 *
 * For each it reports what Win32 believes (style, WS_VISIBLE, rect, IsWindowVisible)
 * so a mismatch between "Win32 says visible" and "nothing on screen" is explicit.
 * Run it under `WINEDEBUG=+winemac` and grep for "creating" to see which cases
 * actually produce a Cocoa window.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o win-toplevel-visible-test.exe \
 *          win-toplevel-visible-test.c -mconsole -lgdi32 -luser32
 * Run:   WINEPREFIX=<bottle> wine64 win-toplevel-visible-test.exe
 *        (add WIN_TEST_HOLD=1 to keep the windows up for a screenshot)
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void report(const char *label, HWND hwnd)
{
    RECT r = {0};
    LONG style;

    if (!hwnd)
    {
        fprintf(stderr, "%-28s CreateWindowEx FAILED (err %lu)\n", label, GetLastError());
        return;
    }
    style = GetWindowLongA(hwnd, GWL_STYLE);
    GetWindowRect(hwnd, &r);
    fprintf(stderr, "%-28s hwnd=%p rect=(%ld,%ld)-(%ld,%ld) %ldx%ld  WS_VISIBLE=%d IsWindowVisible=%d parent=%p\n",
            label, hwnd, r.left, r.top, r.right, r.bottom,
            r.right - r.left, r.bottom - r.top,
            !!(style & WS_VISIBLE), IsWindowVisible(hwnd), GetParent(hwnd));
}

static void pump(int ms)
{
    MSG msg;
    DWORD end = GetTickCount() + ms;
    while (GetTickCount() < end)
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        Sleep(10);
    }
}

int main(void)
{
    HINSTANCE inst = GetModuleHandleA(NULL);
    WNDCLASSA wc = {0};
    HWND a, b, c;

    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.lpszClassName = "wintoplevel";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    if (!RegisterClassA(&wc)) { fprintf(stderr, "RegisterClass failed %lu\n", GetLastError()); return 1; }

    fprintf(stderr, "top-level window visibility probe\n");
    fprintf(stderr, "---------------------------------\n");
    fprintf(stderr, "desktop hwnd = %p\n\n", GetDesktopWindow());

    /* [A] the straightforward case */
    a = CreateWindowExA(0, "wintoplevel", "A: plain toplevel", WS_OVERLAPPEDWINDOW,
                        100, 100, 640, 480, NULL, NULL, inst, NULL);
    ShowWindow(a, SW_SHOW);
    UpdateWindow(a);
    pump(300);
    report("[A] plain toplevel", a);

    /* [B] Steam/CEF's shape: created with no size, sized afterwards. If only
     * this one fails to appear, the Mac driver is skipping windows that were
     * empty at creation time and never revisits them after the resize. */
    b = CreateWindowExA(0, "wintoplevel", "B: 0x0 then resized", WS_OVERLAPPEDWINDOW,
                        0, 0, 0, 0, NULL, NULL, inst, NULL);
    report("[B] after create (0x0)", b);
    SetWindowPos(b, NULL, 200, 200, 700, 440, SWP_NOZORDER | SWP_NOACTIVATE);
    ShowWindow(b, SW_SHOW);
    UpdateWindow(b);
    pump(300);
    report("[B] after resize+show", b);

    /* [C] explicitly parented to the desktop, like Steam's windows (parent
     * 0x10020 in the trace). A child window is drawn into its parent's surface
     * and gets no NSWindow of its own — if Steam's windows land here, that
     * alone explains an invisible UI. */
    c = CreateWindowExA(0, "wintoplevel", "C: desktop-parented", WS_OVERLAPPEDWINDOW,
                        300, 300, 500, 400, GetDesktopWindow(), NULL, inst, NULL);
    ShowWindow(c, SW_SHOW);
    UpdateWindow(c);
    pump(300);
    report("[C] desktop-parented", c);

    fprintf(stderr, "\nRun with WINEDEBUG=+winemac and grep 'creating' to see which\n"
                    "of these produced a Cocoa window.\n");

    if (getenv("WIN_TEST_HOLD"))
    {
        fprintf(stderr, "\nWIN_TEST_HOLD set - holding for 30s so the screen can be checked.\n");
        pump(30000);
    }

    DestroyWindow(a);
    DestroyWindow(b);
    DestroyWindow(c);
    return 0;
}

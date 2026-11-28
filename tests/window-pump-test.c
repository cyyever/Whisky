/*
 * window-pump-test — name the window whose owning thread has stopped pumping.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o window-pump-test.exe \
 *            window-pump-test.c -luser32
 * Run:   wine window-pump-test.exe            (inside the affected bottle)
 *
 * A window that ignores its close button looks the same whether the app
 * declined to close it or the thread that owns it is not running a message
 * loop at all. SendMessageTimeout(WM_NULL) separates the two: WM_NULL has no
 * handler and no side effect, so a reply proves only that the queue is being
 * drained. A timeout means the pump is dead, which is a Wine-side problem, not
 * an app-side one.
 *
 * This exists for Steam's "Special Offers" news window, which used to hang
 * under old msync. The output prints the owning thread id in hex (matching
 * WINEDEBUG's line prefix) so a hung window can be matched against Wine debug
 * traces or `sample`.
 *
 * Exit code is the number of non-pumping visible windows, so it doubles as a
 * pass/fail check (0 = every window pumps).
 */
#include <windows.h>
#include <stdio.h>

#define PUMP_TIMEOUT_MS 300

struct scan
{
    int checked;
    int hung;
};

static BOOL CALLBACK visit( HWND hwnd, LPARAM param )
{
    struct scan *scan = (struct scan *)param;
    WCHAR title[256] = {0}, class_name[128] = {0};
    DWORD_PTR result = 0;
    DWORD pid = 0, tid;
    LRESULT ok;

    /* Invisible windows are overwhelmingly message-only helpers whose threads
     * legitimately never pump; including them would bury the real answer. */
    if (!IsWindowVisible( hwnd )) return TRUE;

    tid = GetWindowThreadProcessId( hwnd, &pid );
    GetWindowTextW( hwnd, title, ARRAYSIZE(title) );
    GetClassNameW( hwnd, class_name, ARRAYSIZE(class_name) );

    /* SMTO_ABORTIFHUNG returns early once the window is already flagged hung,
     * so a genuinely dead pump does not cost the full timeout. */
    ok = SendMessageTimeoutW( hwnd, WM_NULL, 0, 0,
                              SMTO_ABORTIFHUNG | SMTO_BLOCK, PUMP_TIMEOUT_MS, &result );
    scan->checked++;

    /* Hex, matching WINEDEBUG's tid=%04x line prefix. */
    printf( "%-6s hwnd=%08lx pid=%04lx tid=%04lx class=%-28ls %ls\n",
            ok ? "pump" : "HUNG", (unsigned long)(ULONG_PTR)hwnd,
            (unsigned long)pid, (unsigned long)tid, class_name, title );

    if (!ok) scan->hung++;
    return TRUE;
}

int main( void )
{
    struct scan scan = {0};

    printf( "Probing every visible top-level window with WM_NULL (%d ms timeout).\n",
            PUMP_TIMEOUT_MS );
    printf( "HUNG = the owning thread is not draining its queue.\n\n" );

    EnumWindows( visit, (LPARAM)&scan );

    printf( "\n%d visible window(s) checked, %d not pumping.\n", scan.checked, scan.hung );
    if (scan.hung)
        printf( "Next: inspect the tid above with WINEDEBUG=+msync,+msg or `sample`.\n" );
    return scan.hung;
}

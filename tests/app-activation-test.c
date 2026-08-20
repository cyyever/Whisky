/*
 * app-activation-test — does Wine tell a program it lost focus?
 *
 *   wine app-activation-test.exe [seconds]
 *
 * Drive it with app-activation-test.sh, which does the switching itself.
 *
 * WHY. On macOS a Wine program was never told the user switched away:
 * macdrv_app_deactivated() dropped the foreground only when
 * get_active_window() — GUITHREADINFO for the *calling* thread — equalled the
 * global foreground window, which for a process-wide event handled by whatever
 * thread pumps first matched only by luck. No foreground change means win32u
 * sends no WM_ACTIVATEAPP. SSFIV's dead pad and black screen both follow from
 * it: never told, it neither re-Acquires DirectInput nor stops submitting
 * frames to a window the compositor no longer displays.
 *
 * Two checks, because they fail at different depths: whether the foreground
 * moves at all (the driver's job, no cooperation needed) and whether
 * WM_ACTIVATEAPP(FALSE) arrives (what an application keys off). Foreground
 * moving without the message would put the fault in win32u instead.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static int saw_deactivate, saw_reactivate, saw_wm_activate_off;

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    switch (m)
    {
    case WM_ACTIVATEAPP:
        if (w) { if (saw_deactivate) saw_reactivate = 1; }
        else saw_deactivate = 1;
        printf("   WM_ACTIVATEAPP %s\n", w ? "TRUE" : "FALSE");
        break;
    /* A different message on a different path; seeing it alone narrows the gap. */
    case WM_ACTIVATE:
        if (LOWORD(w) == WA_INACTIVE) saw_wm_activate_off = 1;
        printf("   WM_ACTIVATE %s\n", LOWORD(w) == WA_INACTIVE ? "INACTIVE" : "ACTIVE");
        break;
    }
    return DefWindowProcA(h, m, w, l);
}

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 20;
    int fg_left = 0, fg_returned = 0;
    HWND win;

    setvbuf(stdout, NULL, _IONBF, 0);

    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "appactivation";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    RegisterClassA(&wc);
    win = CreateWindowExA(0, "appactivation", "app-activation-test",
                          WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                          140, 140, 460, 200, NULL, NULL, wc.hInstance, NULL);
    if (!win) { printf("FAIL  CreateWindow\n"); return 1; }

    SetForegroundWindow(win);
    SetActiveWindow(win);

    /* Hold the foreground first, so "it left" below means the switch. */
    DWORD settle = GetTickCount() + 5000;
    while (GetTickCount() < settle && GetForegroundWindow() != win)
    {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        Sleep(10);
    }
    if (GetForegroundWindow() != win)
    {
        printf("SKIP  never got the foreground, so a switch away is not measurable\n");
        return 0;
    }

    printf("window %p has the foreground\n", win);
    printf("READY\n");

    DWORD end = GetTickCount() + seconds * 1000;
    while (GetTickCount() < end)
    {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);

        if (GetForegroundWindow() != win)
        {
            if (!fg_left) printf("   foreground left us\n");
            fg_left = 1;
        }
        else if (fg_left && !fg_returned)
        {
            printf("   foreground came back\n");
            fg_returned = 1;
        }
        /* A full round trip is all there is to see; the budget is only there
         * for the run where nothing happens at all. */
        if (fg_returned && saw_reactivate) break;
        Sleep(10);
    }

    printf("\nforeground left: %s   WM_ACTIVATEAPP(FALSE): %s   WM_ACTIVATE(INACTIVE): %s\n",
           fg_left ? "yes" : "NO", saw_deactivate ? "yes" : "NO",
           saw_wm_activate_off ? "yes" : "NO");

    if (!fg_left && !saw_deactivate)
    {
        printf("FAIL  switched away and the program was never told: the foreground\n"
               "      window never changed and no WM_ACTIVATEAPP arrived\n");
        return 2;
    }
    if (!saw_deactivate)
    {
        printf("FAIL  the foreground moved but no WM_ACTIVATEAPP(FALSE) was sent\n");
        return 3;
    }
    if (!saw_reactivate)
        printf("note: never saw WM_ACTIVATEAPP(TRUE); the switch back may not have happened\n");
    printf("pass  deactivation was delivered\n");
    return 0;
}

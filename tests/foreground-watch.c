/*
 * foreground-watch — log every change of Wine's foreground window.
 *
 *   wine foreground-watch.exe [seconds]
 *
 * WHY. The foreground window is what DirectInput's DISCL_FOREGROUND keys off,
 * and SSFIV's pad stops responding after a window switch. Reading
 * GetForegroundWindow() from a shell one-shot cannot answer whether it comes
 * back, because typing the command makes the terminal the active application
 * and Wine's foreground correctly becomes the desktop: the measurement
 * destroys the state it measures. So sample instead, print only transitions,
 * and let a human switch away and back while it runs.
 *
 * It creates no window and never calls SetForegroundWindow, so it cannot
 * perturb what it is watching.
 *
 * Read the output as: whichever window is named after the switch back is the
 * one Wine believes is in front. If that is the desktop (class #32769) rather
 * than the game, nothing restored the foreground on activation, and a game
 * that re-Acquires its pad on WM_ACTIVATEAPP never will.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void describe(HWND h, char *out, size_t n)
{
    char cls[96] = { 0 }, txt[128] = { 0 };
    DWORD pid = 0;

    if (!h) { snprintf(out, n, "(none)"); return; }
    GetWindowThreadProcessId(h, &pid);
    GetClassNameA(h, cls, sizeof cls);
    GetWindowTextA(h, txt, sizeof txt);
    snprintf(out, n, "%p pid=%04lx %-20s [%.40s]%s", h, (unsigned long)pid, cls, txt,
             h == GetDesktopWindow() ? "  <- THE DESKTOP" : "");
}

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 60;
    HWND last = (HWND)-1;
    DWORD end;
    char buf[300];

    setvbuf(stdout, NULL, _IONBF, 0);
    describe(GetDesktopWindow(), buf, sizeof buf);
    printf("desktop is %s\n\n", buf);
    printf(">>> switch to the game, then cmd-tab AWAY and back <<<\n\n");

    end = GetTickCount() + seconds * 1000;
    while (GetTickCount() < end)
    {
        HWND fg = GetForegroundWindow();
        if (fg != last)
        {
            last = fg;
            describe(fg, buf, sizeof buf);
            printf("[%6lu ms] foreground -> %s\n",
                   (unsigned long)(GetTickCount() % 1000000), buf);
        }
        Sleep(100);
    }
    return 0;
}

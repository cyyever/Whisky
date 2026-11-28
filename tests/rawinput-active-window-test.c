/*
 * Regression test for patch 0012: RawInput keyboard delivery when a top-level
 * window registers with hwndTarget == NULL and is active without keyboard focus
 * (GetFocus() == NULL, GetActiveWindow() == hwnd).
 *
 * Compile:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o rawinput-active-window-test.exe \
 *       tests/rawinput-active-window-test.c -luser32
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

static int got_raw_enter = 0;
static int got_raw_count = 0;
static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        failures++; \
    } else { \
        printf("PASS: " fmt "\n", ##__VA_ARGS__); \
    } \
} while (0)

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_INPUT) {
        UINT size = 0;
        if (GetRawInputData((HRAWINPUT)lp, RID_INPUT, NULL, &size, sizeof(RAWINPUTHEADER)) == 0 &&
            size > 0 && size <= 128) {
            BYTE buf[128];
            if (GetRawInputData((HRAWINPUT)lp, RID_INPUT, buf, &size, sizeof(RAWINPUTHEADER)) == size) {
                const RAWINPUT *ri = (const RAWINPUT *)buf;
                got_raw_count++;
                if (ri->header.dwType == RIM_TYPEKEYBOARD &&
                    ri->data.keyboard.VKey == VK_RETURN &&
                    !(ri->data.keyboard.Flags & RI_KEY_BREAK)) {
                    got_raw_enter = 1;
                }
            }
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void pump_ms(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    while ((LONG)(end - GetTickCount()) > 0) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

int main(void)
{
    WNDCLASSW wc;
    HWND hwnd;
    RAWINPUTDEVICE rid;
    INPUT in[2];

    setvbuf(stdout, NULL, _IONBF, 0);

    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"WhiskyRawInputActiveTest";
    CHECK(RegisterClassW(&wc) != 0, "RegisterClassW");

    hwnd = CreateWindowExW(0, wc.lpszClassName, L"RawInputActiveTest",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                           100, 100, 320, 240, NULL, NULL, wc.hInstance, NULL);
    CHECK(hwnd != NULL, "CreateWindowExW");
    if (!hwnd) return 1;

    ShowWindow(hwnd, SW_SHOW);
    SetForegroundWindow(hwnd);
    SetActiveWindow(hwnd);
    pump_ms(150);

    /* Explicitly clear focus while keeping hwnd active (matches games whose
     * WM_ACTIVATE handler skips DefWindowProc/SetFocus). */
    SetFocus(NULL);
    pump_ms(50);
    CHECK(GetActiveWindow() == hwnd, "GetActiveWindow() == hwnd (%p)", GetActiveWindow());
    CHECK(GetFocus() == NULL, "GetFocus() == NULL (%p)", GetFocus());

    memset(&rid, 0, sizeof(rid));
    rid.usUsagePage = 0x01;
    rid.usUsage = 0x06;
    rid.dwFlags = 0;
    rid.hwndTarget = NULL;
    CHECK(RegisterRawInputDevices(&rid, 1, sizeof(rid)), "RegisterRawInputDevices(keyboard, target=NULL)");

    memset(in, 0, sizeof(in));
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = VK_RETURN;
    in[0].ki.wScan = 0x1c;
    in[1].type = INPUT_KEYBOARD;
    in[1].ki.wVk = VK_RETURN;
    in[1].ki.wScan = 0x1c;
    in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    CHECK(SendInput(2, in, sizeof(INPUT)) == 2, "SendInput(VK_RETURN down+up)");

    pump_ms(250);
    CHECK(got_raw_enter == 1, "WM_INPUT VK_RETURN delivered with focus=NULL (got_raw_count=%d)", got_raw_count);

    DestroyWindow(hwnd);
    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

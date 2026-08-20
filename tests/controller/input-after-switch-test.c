/*
 * input-after-switch-test — does the pad still work after you cmd-tab away
 * and come back?
 *
 *   wine input-after-switch-test.exe [seconds]
 *
 * WHY. SSFIV's controller stops responding after a window switch and does not
 * come back. The game imports both DINPUT8.dll and XINPUT1_3.dll, and the two
 * behave very differently around focus:
 *
 *   - DirectInput devices are *unacquired* when the window loses focus. The
 *     next GetDeviceState returns DIERR_INPUTLOST or DIERR_NOTACQUIRED and the
 *     application is expected to call Acquire() again. An app that never sees
 *     the focus change never re-acquires, and its pad is dead for good.
 *   - XInput is stateless polling with no acquisition and no focus concept, so
 *     it should be unaffected.
 *
 * Polling both at once tells you which layer stopped: if XInput keeps counting
 * while DirectInput goes quiet, the fault is in acquisition and focus
 * delivery, not in the pad or the Bluetooth stack.
 *
 * It deliberately does NOT re-acquire on failure. Re-acquiring is what the
 * game should do; the probe's job is to report what the layer does on its own.
 *
 * INTERACTIVE: press buttons, cmd-tab away, come back, press buttons again.
 * The per-second line tells you what each API sees.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <dinput.h>
#include <xinput.h>
#include <stdio.h>
#include <stdlib.h>

static HWND g_win;
static volatile LONG g_active = 1;

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_ACTIVATEAPP) {
        InterlockedExchange(&g_active, w ? 1 : 0);
        printf("   [app %s]\n", w ? "ACTIVATED" : "DEACTIVATED");
    }
    return DefWindowProcA(h, m, w, l);
}

static IDirectInputDevice8A *g_pad;

static BOOL CALLBACK enum_pad(const DIDEVICEINSTANCEA *inst, void *ctx)
{
    IDirectInput8A *di = ctx;

    if (FAILED(IDirectInput8_CreateDevice(di, &inst->guidInstance, &g_pad, NULL)))
        return DIENUM_CONTINUE;
    printf("dinput device: %s\n", inst->tszProductName);
    return DIENUM_STOP;
}

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 40;
    IDirectInput8A *di = NULL;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);

    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "inputswitch";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    RegisterClassA(&wc);
    g_win = CreateWindowExA(0, "inputswitch", "input-after-switch-test",
                            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            120, 120, 460, 200, NULL, NULL, wc.hInstance, NULL);
    if (!g_win) { printf("FAIL  CreateWindow\n"); return 1; }

    hr = DirectInput8Create(wc.hInstance, DIRECTINPUT_VERSION, &IID_IDirectInput8A,
                            (void **)&di, NULL);
    if (FAILED(hr)) { printf("FAIL  DirectInput8Create = 0x%08lx\n", (unsigned long)hr); return 1; }

    IDirectInput8_EnumDevices(di, DI8DEVCLASS_GAMECTRL, enum_pad, di, DIEDFL_ATTACHEDONLY);
    if (g_pad) {
        IDirectInputDevice8_SetDataFormat(g_pad, &c_dfDIJoystick2);
        /* Non-exclusive + foreground is what a game uses, and foreground is
         * exactly what makes the device drop on a switch. */
        IDirectInputDevice8_SetCooperativeLevel(g_pad, g_win,
                                                DISCL_NONEXCLUSIVE | DISCL_FOREGROUND);
        hr = IDirectInputDevice8_Acquire(g_pad);
        printf("dinput acquire: 0x%08lx\n", (unsigned long)hr);
    } else {
        printf("note: no DirectInput game controller found\n");
    }

    printf("\n>>> press buttons, then cmd-tab AWAY, come back, and press again <<<\n\n");

    DWORD end = GetTickCount() + seconds * 1000, next = GetTickCount();
    DWORD xi_seen = 0, di_seen = 0, di_lost = 0, xi_pkt = 0;
    DWORD xi_after = 0, di_after = 0;
    int was_deactivated = 0;

    while (GetTickCount() < end) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        if (!InterlockedCompareExchange(&g_active, 0, 0))
            was_deactivated = 1;

        XINPUT_STATE xs = { 0 };
        if (XInputGetState(0, &xs) == ERROR_SUCCESS) {
            if (xs.dwPacketNumber != xi_pkt) {
                xi_pkt = xs.dwPacketNumber;
                xi_seen++;
                if (was_deactivated && InterlockedCompareExchange(&g_active, 0, 0))
                    xi_after++;
            }
        }

        if (g_pad) {
            DIJOYSTATE2 js = { 0 };
            hr = IDirectInputDevice8_GetDeviceState(g_pad, sizeof(js), &js);
            if (hr == DIERR_INPUTLOST || hr == DIERR_NOTACQUIRED) {
                di_lost++;
            } else if (SUCCEEDED(hr)) {
                for (int b = 0; b < 32; b++)
                    if (js.rgbButtons[b] & 0x80) {
                        di_seen++;
                        if (was_deactivated && InterlockedCompareExchange(&g_active, 0, 0))
                            di_after++;
                        break;
                    }
            }
        }

        if (GetTickCount() >= next) {
            next = GetTickCount() + 1000;
            printf("  %s  xinput:%lu changes  dinput:%lu presses  dinput-lost:%lu\n",
                   InterlockedCompareExchange(&g_active, 0, 0) ? "active " : "away   ",
                   (unsigned long)xi_seen, (unsigned long)di_seen,
                   (unsigned long)di_lost);
        }
        Sleep(8);
    }

    printf("\nafter coming back:  xinput saw %lu changes, dinput saw %lu presses\n",
           (unsigned long)xi_after, (unsigned long)di_after);
    if (!was_deactivated) {
        printf("SKIP  never switched away, so nothing was measured\n");
        return 0;
    }
    if (di_lost && !di_after) {
        printf("FAIL  DirectInput went unacquired and never recovered -- a game that\n"
               "      does not re-Acquire has a dead pad from here on\n");
        return 2;
    }
    if (!xi_after && !di_after) {
        printf("FAIL  neither API saw input after the switch back\n");
        return 2;
    }
    printf("pass  input still arrives after the switch\n");
    return 0;
}

/*
 * d3d9-present-stall-test — does D3D9 Present() stall when you cmd-tab away?
 *
 *   wine d3d9-present-stall-test.exe [seconds]
 *
 * WHY. SSFIV freezes when the user switches windows. A backtrace of the frozen
 * game showed the render thread blocked in vkWaitForPresentKHR ->
 * KosmicKrisp's wsi_metal_swapchain_wait_for_present -> a condition variable
 * that only advances when a CAMetalDrawable's addPresentedHandler fires. DXVK
 * passes UINT64_MAX there (dxvk_presenter.cpp), so a handler that never fires
 * is a permanent hang.
 *
 * RESULT: negative, like the native probe before it. A windowed D3D9 device
 * cmd-tabbed away kept presenting in 18 ms over 5391 frames. Neither this nor
 * a plain Cocoa window (vk-present-probe -occlusion: 3156 frames, 9 ms, over
 * a 60 s switch-away) can produce the condition -- every layer that was tried,
 * occluded or hidden or miniaturized or unattached, still gets its presented
 * handler called. That is what left the handler itself as the only remaining
 * suspect, and the fix (patches/mesa/0003) had to add a driver test hook,
 * KK_WSI_TEST_DROP_PRESENT_HANDLER, to keep its recovery path testable.
 *
 * Kept because the negative is load-bearing: if a future change makes a
 * windowed D3D9 present stall on a window switch, that is a new regression,
 * and this says so in 40 s instead of a game session.
 *
 * You have to cmd-tab away yourself; nothing inside Wine can deactivate its
 * own app the way the window server does. The test tells you when to.
 *
 * A WATCHDOG THREAD is the point. If Present() never returns, the main thread
 * cannot report anything -- "the test printed nothing" would be the only
 * symptom, and that reads the same as a crash on the first call. The watchdog
 * runs independently and names the stall, the state (active or switched away),
 * and how long it has been blocked.
 *
 * Exit: 0 no stall, 1 setup failure, 2 Present() stalled.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

#define STALL_MS 2000          /* a windowed Present is ~16 ms; 2 s is a hang */
/* The failure under test is a PERMANENT block: the main thread never comes
 * back, so main()'s own verdict is unreachable and only the watchdog can end
 * the run. It exits the process itself once the stall is beyond argument. */
#define GIVE_UP_MS 30000

static volatile LONG  g_frames;          /* bumped after each Present returns */
static volatile LONG  g_active = 1;      /* WM_ACTIVATEAPP tracks cmd-tab     */
static volatile DWORD g_present_start;   /* tick when the current Present began */
static volatile LONG  g_in_present;
static volatile LONG  g_stalled;
static volatile LONG  g_worst_active, g_worst_away;

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_ACTIVATEAPP) {
        InterlockedExchange(&g_active, w ? 1 : 0);
        printf("   [app %s]\n", w ? "activated" : "DEACTIVATED (switched away)");
    }
    return DefWindowProcA(h, m, w, l);
}

static DWORD WINAPI watchdog(void *unused)
{
    int reported = 0;

    for (;;) {
        Sleep(250);
        if (!InterlockedCompareExchange(&g_in_present, 0, 0))
            { reported = 0; continue; }

        DWORD held = GetTickCount() - g_present_start;
        if (held < STALL_MS) { reported = 0; continue; }

        /* Report once per stall, then every 5 s while it persists, so a
         * permanent hang keeps saying so instead of going quiet. */
        if (!reported || held % 5000 < 300) {
            fprintf(stderr, "STALL Present() has been blocked %.1f s (app %s)\n",
                    held / 1000.0,
                    InterlockedCompareExchange(&g_active, 0, 0) ? "ACTIVE"
                                                                : "switched away");
            reported = 1;
            InterlockedExchange(&g_stalled, 1);
        }

        if (held >= GIVE_UP_MS) {
            fprintf(stderr,
                    "FAIL  Present() blocked %.0f s and is not coming back --\n"
                    "      the game's window-switch freeze, reproduced without the game\n",
                    held / 1000.0);
            _exit(2);   /* main() is stuck inside Present(); nothing else can */
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 40;

    /* Unbuffered: the failure being hunted is a hang, and a killed process
     * discards a block-buffered stdout. */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3d9stall";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    RegisterClassA(&wc);

    HWND win = CreateWindowExA(0, "d3d9stall", "d3d9-present-stall-test",
                               WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                               100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);
    if (!win) { printf("FAIL  CreateWindow\n"); return 1; }

    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) { printf("FAIL  Direct3DCreate9 (is DXVK's d3d9 in the load order?)\n"); return 1; }

    D3DPRESENT_PARAMETERS pp = { 0 };
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_UNKNOWN;
    pp.hDeviceWindow = win;
    /* The game's cadence: vsynced, which is what makes a present wait on the
     * drawable being shown. IMMEDIATE would sidestep the very wait under test. */
    pp.PresentationInterval = D3DPRESENT_INTERVAL_ONE;

    IDirect3DDevice9 *dev = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, win,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
    if (FAILED(hr) || !dev) {
        printf("FAIL  CreateDevice hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    printf("device created; presenting for %d s\n", seconds);
    printf(">>> cmd-tab AWAY from this window now, wait ~10 s, then come back <<<\n");

    CreateThread(NULL, 0, watchdog, NULL, 0, NULL);

    int failed_presents = 0;
    DWORD end = GetTickCount() + seconds * 1000;
    while (GetTickCount() < end) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }

        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET,
                               D3DCOLOR_XRGB(0, (g_frames * 4) & 0xff, 90), 1.0f, 0);
        IDirect3DDevice9_BeginScene(dev);
        IDirect3DDevice9_EndScene(dev);

        g_present_start = GetTickCount();
        InterlockedExchange(&g_in_present, 1);
        hr = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        InterlockedExchange(&g_in_present, 0);
        DWORD took = GetTickCount() - g_present_start;

        if (InterlockedCompareExchange(&g_active, 0, 0)) {
            if ((LONG)took > g_worst_active) g_worst_active = took;
        } else {
            if ((LONG)took > g_worst_away) g_worst_away = took;
        }

        if (FAILED(hr)) {
            /* A lost device returns from Present immediately, so the loop
             * would spin presenting nothing while the watchdog saw no stall
             * and the run ended "pass". Reset only once the device says it is
             * ready, and give up rather than report green on a dead one. */
            if (++failed_presents > 200) {
                printf("FAIL  %d consecutive failed Present() calls (hr=0x%08lx) --\n"
                       "      the device is gone; this run measured nothing\n",
                       failed_presents, (unsigned long)hr);
                return 1;
            }
            Sleep(50);
            if (IDirect3DDevice9_TestCooperativeLevel(dev) == D3DERR_DEVICENOTRESET) {
                HRESULT rhr = IDirect3DDevice9_Reset(dev, &pp);
                printf("   [device reset hr=0x%08lx]\n", (unsigned long)rhr);
            }
            continue;
        }
        failed_presents = 0;
        InterlockedIncrement(&g_frames);
    }

    printf("\npresented %ld frames; worst Present(): %ld ms active, %ld ms switched away\n",
           (long)g_frames, (long)g_worst_active, (long)g_worst_away);
    if (g_stalled) {
        printf("FAIL  Present() stalled past %d ms -- the game's window-switch freeze,\n"
               "      reproduced without the game\n", STALL_MS);
        return 2;
    }
    printf("pass  no stall over %d ms\n", STALL_MS);
    return 0;
}

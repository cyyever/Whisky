/*
 * retina-fullscreen-mode-test — verify display-mode switching (including
 * non-native aspect ratio modes such as 1680x1050 on 16:9 4K HiDPI) and
 * fullscreen window / swapchain geometry under RetinaMode=y.
 *
 * Covers the Resident Evil 2 (DX12) failure mode:
 *   1. Main display is 3840x2160 (1920x1080 @ 2x) with RetinaMode=y.
 *   2. App switches display mode via ChangeDisplaySettingsExW(CDS_FULLSCREEN)
 *      to a non-native aspect ratio (e.g. 1680x1050).
 *   3. Verifies GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN) and GetMonitorInfoW
 *      agree with the active mode (no 2x stale-Retina desync).
 *   4. Verifies a borderless fullscreen window sized to rcMonitor keeps exact
 *      window & client rects matching the active mode (no doubled/exploded rect).
 *   5. Verifies restoring the original display mode restores metrics and
 *      window geometry cleanly.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O1 -Wall -o retina-fullscreen-mode-test.exe \
 *       tests/retina-fullscreen-mode-test.c -luser32 -lgdi32 -ld3d11 -ldxgi -luuid
 * Run:
 *   wine retina-fullscreen-mode-test.exe   # exit 0 = all checks pass
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <string.h>

static int failures;

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void pump(int iterations)
{
    MSG msg;
    for (int i = 0; i < iterations; i++)
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

static void check_eq(const char *label, LONG got, LONG want)
{
    if (got == want)
    {
        printf("PASS %-46s %ld\n", label, got);
    }
    else
    {
        printf("FAIL %-46s got=%ld want=%ld\n", label, got, want);
        failures++;
    }
}

/* Pick a supported display mode that differs in aspect ratio from orig (preferring
 * 1680x1050, the exact RE2 mode), or any smaller mode if none has a different aspect. */
static BOOL pick_test_mode(const WCHAR *device, const DEVMODEW *orig, DEVMODEW *out)
{
    DEVMODEW dm, fallback = {0};
    BOOL have_fallback = FALSE;

    for (DWORD i = 0; ; i++)
    {
        memset(&dm, 0, sizeof(dm));
        dm.dmSize = sizeof(dm);
        if (!EnumDisplaySettingsW(device, i, &dm))
            break;
        if (dm.dmBitsPerPel != 32)
            continue;
        if (dm.dmPelsWidth == orig->dmPelsWidth && dm.dmPelsHeight == orig->dmPelsHeight)
            continue;

        if (dm.dmPelsWidth == 1680 && dm.dmPelsHeight == 1050)
        {
            *out = dm;
            return TRUE;
        }
        /* Prefer a different aspect ratio (e.g. 16:10 or 4:3 on 16:9). */
        if ((LONGLONG)dm.dmPelsWidth * orig->dmPelsHeight !=
            (LONGLONG)dm.dmPelsHeight * orig->dmPelsWidth &&
            dm.dmPelsWidth >= 800 && dm.dmPelsHeight >= 600)
        {
            fallback = dm;
            have_fallback = TRUE;
        }
        else if (!have_fallback && dm.dmPelsWidth >= 800 && dm.dmPelsHeight >= 600)
        {
            fallback = dm;
            have_fallback = TRUE;
        }
    }

    if (have_fallback)
    {
        *out = fallback;
        return TRUE;
    }
    return FALSE;
}

int main(void)
{
    MONITORINFOEXW mi;
    DEVMODEW orig_mode, target_mode, cur_mode;
    WNDCLASSW wc = {0};
    HWND hwnd = NULL;
    LONG status;
    BOOL mode_changed = FALSE;
    RECT wr, cr;

    SetProcessDPIAware();

    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY),
                         (MONITORINFO *)&mi))
    {
        printf("FAIL GetMonitorInfoW failed (%lu)\n", GetLastError());
        return 1;
    }

    memset(&orig_mode, 0, sizeof(orig_mode));
    orig_mode.dmSize = sizeof(orig_mode);
    if (!EnumDisplaySettingsW(mi.szDevice, ENUM_CURRENT_SETTINGS, &orig_mode))
    {
        printf("FAIL EnumDisplaySettingsW(ENUM_CURRENT_SETTINGS) failed\n");
        return 1;
    }

    printf("Initial mode: %lux%lu@%luHz  rcMonitor=(%ld,%ld)-(%ld,%ld)  SM=%dx%d\n",
           orig_mode.dmPelsWidth, orig_mode.dmPelsHeight, orig_mode.dmDisplayFrequency,
           mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right, mi.rcMonitor.bottom,
           GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));

    check_eq("initial SM_CXSCREEN == current width",
             GetSystemMetrics(SM_CXSCREEN), (LONG)orig_mode.dmPelsWidth);
    check_eq("initial SM_CYSCREEN == current height",
             GetSystemMetrics(SM_CYSCREEN), (LONG)orig_mode.dmPelsHeight);
    check_eq("initial rcMonitor width == current width",
             mi.rcMonitor.right - mi.rcMonitor.left, (LONG)orig_mode.dmPelsWidth);
    check_eq("initial rcMonitor height == current height",
             mi.rcMonitor.bottom - mi.rcMonitor.top, (LONG)orig_mode.dmPelsHeight);

    if (!pick_test_mode(mi.szDevice, &orig_mode, &target_mode))
    {
        printf("SKIP no alternate 32bpp display mode available\n");
        return failures ? 1 : 0;
    }

    printf("Target mode:  %lux%lu@%luHz\n",
           target_mode.dmPelsWidth, target_mode.dmPelsHeight, target_mode.dmDisplayFrequency);

    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"RetinaFullscreenModeTest";
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassW(&wc);

    /* Create a titled window first (like RE2 before switching to fullscreen). */
    hwnd = CreateWindowExW(0, wc.lpszClassName, L"retina-fs-test",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                           0, 66, 1280, 720, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd)
    {
        printf("FAIL CreateWindowExW failed (%lu)\n", GetLastError());
        return 1;
    }
    pump(10);

    /* Create a D3D11 swapchain if available to exercise Mullion's WindowFollower/MullionPlace. */
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain1 *sc = NULL;
    if (SUCCEEDED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
                                    NULL, 0, D3D11_SDK_VERSION, &dev, NULL, &ctx)))
    {
        IDXGIDevice *dxdev = NULL;
        IDXGIAdapter *adapter = NULL;
        IDXGIFactory2 *f2 = NULL;
        if (SUCCEEDED(dev->lpVtbl->QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxdev)) &&
            SUCCEEDED(dxdev->lpVtbl->GetAdapter(dxdev, &adapter)) &&
            SUCCEEDED(adapter->lpVtbl->GetParent(adapter, &IID_IDXGIFactory2, (void **)&f2)))
        {
            DXGI_SWAP_CHAIN_DESC1 d1 = {0};
            d1.Width = target_mode.dmPelsWidth;
            d1.Height = target_mode.dmPelsHeight;
            d1.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
            d1.SampleDesc.Count = 1;
            d1.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
            d1.BufferCount = 2;
            d1.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
            d1.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;
            f2->lpVtbl->CreateSwapChainForHwnd(f2, (IUnknown *)dev, hwnd, &d1, NULL, NULL, &sc);
        }
        if (f2) f2->lpVtbl->Release(f2);
        if (adapter) adapter->lpVtbl->Release(adapter);
        if (dxdev) dxdev->lpVtbl->Release(dxdev);
    }

    /* Switch display mode via ChangeDisplaySettingsExW(CDS_FULLSCREEN). */
    target_mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
    status = ChangeDisplaySettingsExW(mi.szDevice, &target_mode, NULL, CDS_FULLSCREEN, NULL);
    if (status != DISP_CHANGE_SUCCESSFUL)
    {
        target_mode.dmFields &= ~DM_DISPLAYFREQUENCY;
        status = ChangeDisplaySettingsExW(mi.szDevice, &target_mode, NULL, CDS_FULLSCREEN, NULL);
    }
    check_eq("ChangeDisplaySettingsExW(target) == SUCCESS", status, DISP_CHANGE_SUCCESSFUL);
    if (status != DISP_CHANGE_SUCCESSFUL)
        goto cleanup;
    mode_changed = TRUE;
    pump(15);

    /* Verify monitor metrics and current mode agree (no 2x stale-Retina mismatch). */
    memset(&cur_mode, 0, sizeof(cur_mode));
    cur_mode.dmSize = sizeof(cur_mode);
    EnumDisplaySettingsW(mi.szDevice, ENUM_CURRENT_SETTINGS, &cur_mode);
    mi.cbSize = sizeof(mi);
    GetMonitorInfoW(MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY), (MONITORINFO *)&mi);

    check_eq("post-switch SM_CXSCREEN == target width",
             GetSystemMetrics(SM_CXSCREEN), (LONG)target_mode.dmPelsWidth);
    check_eq("post-switch SM_CYSCREEN == target height",
             GetSystemMetrics(SM_CYSCREEN), (LONG)target_mode.dmPelsHeight);
    check_eq("post-switch rcMonitor width == target width",
             mi.rcMonitor.right - mi.rcMonitor.left, (LONG)target_mode.dmPelsWidth);
    check_eq("post-switch rcMonitor height == target height",
             mi.rcMonitor.bottom - mi.rcMonitor.top, (LONG)target_mode.dmPelsHeight);

    /* Strip window borders and resize to fullscreen rcMonitor (as DXGI EnterFullscreenMode does). */
    SetWindowLongW(hwnd, GWL_STYLE, WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN);
    SetWindowLongW(hwnd, GWL_EXSTYLE, WS_EX_TOPMOST);
    SetWindowPos(hwnd, HWND_TOPMOST,
                 mi.rcMonitor.left, mi.rcMonitor.top,
                 mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_NOACTIVATE);
    pump(15);

    if (sc)
    {
        sc->lpVtbl->Present(sc, 0, 0);
        pump(10);
    }

    GetWindowRect(hwnd, &wr);
    GetClientRect(hwnd, &cr);
    check_eq("fullscreen window left == rcMonitor.left", wr.left, mi.rcMonitor.left);
    check_eq("fullscreen window top == rcMonitor.top", wr.top, mi.rcMonitor.top);
    check_eq("fullscreen window width == target width",
             wr.right - wr.left, (LONG)target_mode.dmPelsWidth);
    check_eq("fullscreen window height == target height",
             wr.bottom - wr.top, (LONG)target_mode.dmPelsHeight);
    check_eq("fullscreen client width == target width",
             cr.right - cr.left, (LONG)target_mode.dmPelsWidth);
    check_eq("fullscreen client height == target height",
             cr.bottom - cr.top, (LONG)target_mode.dmPelsHeight);

cleanup:
    if (mode_changed)
    {
        status = ChangeDisplaySettingsExW(mi.szDevice, NULL, NULL, 0, NULL);
        check_eq("ChangeDisplaySettingsExW(restore) == SUCCESS", status, DISP_CHANGE_SUCCESSFUL);
        pump(15);

        mi.cbSize = sizeof(mi);
        GetMonitorInfoW(MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY), (MONITORINFO *)&mi);
        check_eq("restored SM_CXSCREEN == orig width",
                 GetSystemMetrics(SM_CXSCREEN), (LONG)orig_mode.dmPelsWidth);
        check_eq("restored SM_CYSCREEN == orig height",
                 GetSystemMetrics(SM_CYSCREEN), (LONG)orig_mode.dmPelsHeight);
        check_eq("restored rcMonitor width == orig width",
                 mi.rcMonitor.right - mi.rcMonitor.left, (LONG)orig_mode.dmPelsWidth);
        check_eq("restored rcMonitor height == orig height",
                 mi.rcMonitor.bottom - mi.rcMonitor.top, (LONG)orig_mode.dmPelsHeight);
    }

    if (sc) sc->lpVtbl->Release(sc);
    if (ctx) ctx->lpVtbl->Release(ctx);
    if (dev) dev->lpVtbl->Release(dev);
    if (hwnd) DestroyWindow(hwnd);

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "OK", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}

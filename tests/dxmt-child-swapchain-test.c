/*
 * dxmt-child-swapchain-test — assert DXMT can build a swapchain on a child HWND.
 *
 * This is the regression that made Steam, GOG and a plain upstream Chromium all
 * show a black window for a few seconds and then vanish. DXMT gets its Metal
 * view from winemac.drv; the shim in patches/proton-wine/0009 only produced one
 * for a toplevel window, so a child HWND yielded NULL. DXMT does not treat that
 * as a recoverable error -- d3d11_swapchain.cpp logs
 *
 *     Failed to create metal view, it seems like your Wine has no exported
 *     symbols needed by DXMT.
 *
 * and calls abort(). A browser composites into a child HWND; a game does not,
 * which is why games were unaffected and this looked like a graphics bug.
 *
 * Because the failure is abort() rather than a bad HRESULT, "the test process
 * exited normally" is itself an assertion here -- a regression kills this
 * program outright, and the exit code says so.
 *
 * Deliberately talks to D3D11/DXGI directly rather than through ANGLE, so a
 * failure points at the driver rather than at a browser's GL layer.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O1 -o dxmt-child-swapchain-test.exe \
 *       dxmt-child-swapchain-test.c -ld3d11 -ldxgi -luser32
 * Run:
 *   wine dxmt-child-swapchain-test.exe     # exit 0 = all cases pass
 */

#define COBJMACROS   /* C-style IFace_Method() wrappers */
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>

static int failures;
static ID3D11Device *device;
static IDXGIFactory2 *factory;

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    return DefWindowProcA(hwnd, msg, wp, lp);
}

/* Create a swapchain on `hwnd`, present once, and release. Presenting matters:
 * creation alone does not exercise the path that needs the view to be visible. */
static void check_swapchain(const char *name, HWND hwnd)
{
    DXGI_SWAP_CHAIN_DESC1 desc = {0};
    IDXGISwapChain1 *swapchain = NULL;
    HRESULT hr;

    if (!hwnd)
    {
        printf("FAIL %-34s CreateWindow failed (%lu)\n", name, GetLastError());
        failures++;
        return;
    }

    desc.Width = 320;
    desc.Height = 240;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)device, hwnd,
                                              &desc, NULL, NULL, &swapchain);
    if (FAILED(hr) || !swapchain)
    {
        printf("FAIL %-34s CreateSwapChainForHwnd hr=0x%08lx\n", name, hr);
        failures++;
        return;
    }

    hr = IDXGISwapChain1_Present(swapchain, 0, 0);
    if (FAILED(hr))
    {
        printf("FAIL %-34s Present hr=0x%08lx\n", name, hr);
        failures++;
    }
    else
        printf("PASS %-34s created and presented\n", name);

    IDXGISwapChain1_Release(swapchain);
}

int main(void)
{
    D3D_FEATURE_LEVEL level = 0;
    WNDCLASSA wc = {0};
    HWND toplevel, child, host, grandchild, hidden;
    IDXGIDevice *dxgi_device = NULL;
    IDXGIAdapter *adapter = NULL;
    HRESULT hr;

    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                           D3D11_SDK_VERSION, &device, &level, NULL);
    if (FAILED(hr))
    {
        printf("FATAL D3D11CreateDevice hr=0x%08lx\n", hr);
        return 2;
    }
    printf("feature level 0x%04x%s\n", level,
           level >= 0xb000 ? "  (DXMT)" : "  (wined3d -- DXMT is not installed, results are not meaningful)");

    if (FAILED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device)) ||
        FAILED(IDXGIDevice_GetAdapter(dxgi_device, &adapter)) ||
        FAILED(IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory)))
    {
        printf("FATAL could not reach IDXGIFactory2\n");
        return 2;
    }

    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "DxmtChildSwapchainTest";
    RegisterClassA(&wc);

#define WIN(style, parent) CreateWindowExA(0, "DxmtChildSwapchainTest", "sc", (style), \
                                           0, 0, 320, 240, (parent), NULL, wc.hInstance, NULL)

    /* Baseline: a toplevel. This is what games hand DXMT, and it always worked. */
    toplevel = WIN(WS_OVERLAPPEDWINDOW, NULL);
    ShowWindow(toplevel, SW_SHOW);
    check_swapchain("toplevel", toplevel);

    /* The regression: a child HWND, which is what a browser composites into. */
    host = WIN(WS_OVERLAPPEDWINDOW, NULL);
    ShowWindow(host, SW_SHOW);
    child = WIN(WS_CHILD | WS_VISIBLE, host);
    check_swapchain("child of toplevel", child);

    /* Two levels down: the toplevel must be found via GA_ROOT, not GetParent. */
    grandchild = WIN(WS_CHILD | WS_VISIBLE, child);
    check_swapchain("grandchild", grandchild);

    /* A child whose toplevel has never been shown. CEF creates its compositing
     * window before the browser window is mapped. */
    hidden = WIN(WS_OVERLAPPEDWINDOW, NULL);
    check_swapchain("child of unshown toplevel", WIN(WS_CHILD, hidden));

    /* Two swapchains alive at once on different children of one toplevel: a
     * browser holds one per composited widget, and a shim that tracks a single
     * surface releases the first while DXMT is still rendering into it. */
    {
        DXGI_SWAP_CHAIN_DESC1 desc = {0};
        IDXGISwapChain1 *a = NULL, *b = NULL;
        HWND ca = WIN(WS_CHILD | WS_VISIBLE, host), cb = WIN(WS_CHILD | WS_VISIBLE, host);

        desc.Width = 160; desc.Height = 120;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

        if (SUCCEEDED(IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)device, ca, &desc, NULL, NULL, &a)) &&
            SUCCEEDED(IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)device, cb, &desc, NULL, NULL, &b)) &&
            SUCCEEDED(IDXGISwapChain1_Present(a, 0, 0)) &&
            SUCCEEDED(IDXGISwapChain1_Present(b, 0, 0)))
            printf("PASS %-34s both present after both exist\n", "two concurrent child swapchains");
        else
        {
            printf("FAIL %-34s\n", "two concurrent child swapchains");
            failures++;
        }
        if (a) IDXGISwapChain1_Release(a);
        if (b) IDXGISwapChain1_Release(b);
    }

    /* Destroying the window must not take the process with it: the surface is
     * detached by win32u while DXMT still holds its view. */
    DestroyWindow(child);
    printf("PASS %-34s survived window destruction\n", "child destroy");

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "OK", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}

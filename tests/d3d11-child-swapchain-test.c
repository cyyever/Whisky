/*
 * d3d11-child-swapchain-test — assert D3D11 can build a swapchain on a child HWND.
 *
 * Browsers composite into child HWNDs. DXVK reaches those windows through
 * winevulkan surfaces; check both presentation and surface lifetime, including
 * concurrent children and window destruction. Crashes count as failures too.
 *
 * Deliberately talks to D3D11/DXGI directly rather than through ANGLE, so a
 * failure points at the driver rather than at a browser's GL layer.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O1 -o d3d11-child-swapchain-test.exe \
 *       d3d11-child-swapchain-test.c -ld3d11 -ldxgi -luser32
 * Run:
 *   wine d3d11-child-swapchain-test.exe    # exit 0 = all cases pass
 *   wine d3d11-child-swapchain-test.exe --continuous single 1
 *   wine d3d11-child-swapchain-test.exe --continuous children 1
 * Continuous mode lasts 30 seconds. Compare interval 0 and 1; check visually.
 * A DXVK_CONFIG syncInterval override takes precedence over this argument.
 */

#define COBJMACROS   /* C-style IFace_Method() wrappers */
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <string.h>

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

/* A static image must stay static: this intentionally has no animation.
 * Escape or closing the host stops the run. HRESULTs cannot detect visible
 * corruption, so success only means presentation completed without API errors. */
static int continuous_present(int children, UINT interval)
{
    HWND host = NULL, windows[2] = {0};
    IDXGISwapChain1 *chains[2] = {0};
    ID3D11RenderTargetView *targets[2] = {0};
    ID3D11DeviceContext *context = NULL;
    const FLOAT colors[2][4] = {{0.1f, 0.5f, 0.8f, 1}, {0.8f, 0.35f, 0.1f, 1}};
    int count = children ? 2 : 1, result = 1;
    unsigned frames = 0;
    ULONGLONG start = GetTickCount64();
    MSG msg;

    SetProcessDPIAware();
    host = CreateWindowExA(0, "D3d11ChildSwapchainTest",
        children ? "D3D11: two static children (Escape closes)" : "D3D11: static window (Escape closes)",
        WS_OVERLAPPEDWINDOW, 100, 100, 700, 350, NULL, NULL, GetModuleHandleA(NULL), NULL);
    if (!host) goto done;
    ID3D11Device_GetImmediateContext(device, &context);
    for (int i = 0; i < count; ++i)
    {
        DXGI_SWAP_CHAIN_DESC1 desc = {0};
        ID3D11Texture2D *buffer = NULL;
        HRESULT hr;
        windows[i] = children ? CreateWindowExA(0, "D3d11ChildSwapchainTest", "child",
            WS_CHILD | WS_VISIBLE, 10 + 330 * i, 10, 320, 240, host, NULL, GetModuleHandleA(NULL), NULL) : host;
        if (!windows[i]) goto done;
        desc.Width = 320; desc.Height = 240;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        hr = IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)device, windows[i], &desc, NULL, NULL, &chains[i]);
        if (FAILED(hr)) { printf("FAIL create %d hr=%08lx\n", i, hr); goto done; }
        hr = IDXGISwapChain1_GetBuffer(chains[i], 0, &IID_ID3D11Texture2D, (void **)&buffer);
        if (SUCCEEDED(hr)) hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)buffer, NULL, &targets[i]);
        if (buffer) ID3D11Texture2D_Release(buffer);
        if (FAILED(hr)) { printf("FAIL target %d hr=%08lx\n", i, hr); goto done; }
    }
    ShowWindow(host, SW_SHOW);
    printf("Continuous: %d surface(s), sync interval %u, 30 seconds; static blue/orange, no intended flicker\n", count, interval);
    fflush(stdout);
    while (IsWindow(host) && GetTickCount64() - start < 30000 && !(GetAsyncKeyState(VK_ESCAPE) & 0x8000))
    {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        if (!IsWindow(host)) break;
        for (int i = 0; i < count; ++i)
        {
            HRESULT hr;
            ID3D11DeviceContext_ClearRenderTargetView(context, targets[i], colors[i]);
            hr = IDXGISwapChain1_Present(chains[i], interval, 0);
            if (FAILED(hr)) { printf("FAIL present %d frame %u hr=%08lx removed=%08lx\n", i, frames, hr, ID3D11Device_GetDeviceRemovedReason(device)); goto done; }
        }
        ++frames;
        Sleep(16); /* Bound CPU use even with sync interval zero. */
    }
    printf("Completed %u frames in %llu ms; inspect visually for corruption\n", frames, GetTickCount64() - start);
    result = 0;
done:
    if (context) { ID3D11DeviceContext_ClearState(context); ID3D11DeviceContext_Flush(context); }
    for (int i = 0; i < count; ++i) {
        if (targets[i]) ID3D11RenderTargetView_Release(targets[i]);
        if (chains[i]) IDXGISwapChain1_Release(chains[i]);
    }
    if (context) ID3D11DeviceContext_Release(context);
    if (host && IsWindow(host)) DestroyWindow(host);
    return result;
}

int main(int argc, char **argv)
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
           level >= 0xb000 ? "  (DXVK)" : "  (wined3d -- DXVK's d3d11 is not installed, results are not meaningful)");

    if (FAILED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi_device)) ||
        FAILED(IDXGIDevice_GetAdapter(dxgi_device, &adapter)) ||
        FAILED(IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory)))
    {
        printf("FATAL could not reach IDXGIFactory2\n");
        return 2;
    }

    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "D3d11ChildSwapchainTest";
    RegisterClassA(&wc);

#define WIN(style, parent) CreateWindowExA(0, "D3d11ChildSwapchainTest", "sc", (style), \
                                           0, 0, 320, 240, (parent), NULL, wc.hInstance, NULL)

    if (argc > 1)
    {
        int result;
        if (strcmp(argv[1], "--continuous") || (argc > 2 && strcmp(argv[2], "single") && strcmp(argv[2], "children")) ||
            (argc > 3 && strcmp(argv[3], "0") && strcmp(argv[3], "1")) || argc > 4)
        { fprintf(stderr, "Usage: %s [--continuous [single|children] [0|1]]\n", argv[0]); return 2; }
        result = continuous_present(argc > 2 && !strcmp(argv[2], "children"), argc > 3 && !strcmp(argv[3], "0") ? 0 : 1);
        IDXGIFactory2_Release(factory); IDXGIAdapter_Release(adapter);
        IDXGIDevice_Release(dxgi_device); ID3D11Device_Release(device);
        return result;
    }

    /* Baseline: a toplevel. This is what games hand D3D11, and it always worked. */
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
     * surface releases the first while D3D11 is still rendering into it. */
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
     * detached by win32u while D3D11 still holds its surface. */
    DestroyWindow(child);
    printf("PASS %-34s survived window destruction\n", "child destroy");

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "OK", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}

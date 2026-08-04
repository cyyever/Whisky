/* dxgi-swapchain-test.c — can a D3D11 swapchain be created on a Wine window?
 *
 * Chromium/ANGLE fails here: SwapChain11::reset reports "Could not create
 * additional swap chains or offscreen surfaces" (0x80004005) and
 * eglCreateWindowSurface then returns EGL_BAD_ALLOC, so the window frame
 * appears but never paints. This isolates that one call away from ANGLE. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>

static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

int main(void) {
    HINSTANCE inst = GetModuleHandleA(NULL);
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wp; wc.hInstance = inst; wc.lpszClassName = "dxgitest";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowExA(0, "dxgitest", "dxgi swapchain test",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 480, NULL, NULL, inst, NULL);
    fprintf(stderr, "hwnd=%p\n", hwnd);

    ID3D11Device *dev = NULL; ID3D11DeviceContext *ctx = NULL;
    D3D_FEATURE_LEVEL got = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
                                   NULL, 0, D3D11_SDK_VERSION, &dev, &got, &ctx);
    fprintf(stderr, "D3D11CreateDevice hr=0x%lx featureLevel=0x%x\n", (unsigned long)hr, got);
    if (FAILED(hr)) return 1;

    /* --- the classic DXGI_SWAP_EFFECT_DISCARD swapchain (what ANGLE uses) --- */
    IDXGIDevice *dxdev = NULL;
    IDXGIAdapter *adapter = NULL;
    IDXGIFactory *factory = NULL;
    dev->lpVtbl->QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxdev);
    if (dxdev) dxdev->lpVtbl->GetAdapter(dxdev, &adapter);
    if (adapter) adapter->lpVtbl->GetParent(adapter, &IID_IDXGIFactory, (void **)&factory);
    fprintf(stderr, "factory=%p\n", factory);
    if (!factory) return 1;

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 1;
    sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 480;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    IDXGISwapChain *sc = NULL;
    hr = factory->lpVtbl->CreateSwapChain(factory, (IUnknown *)dev, &sd, &sc);
    fprintf(stderr, "CreateSwapChain(DISCARD) hr=0x%lx sc=%p  %s\n",
            (unsigned long)hr, sc, SUCCEEDED(hr) ? "OK" : "FAILED");

    /* --- also try an offscreen texture, the other half of ANGLE's message --- */
    /* --- what ANGLE actually prefers: IDXGIFactory2::CreateSwapChainForHwnd
     * with a flip model. If the classic path above works but this one doesn't,
     * that gap is what ANGLE trips over. --- */
    IDXGIFactory2 *f2 = NULL;
    factory->lpVtbl->QueryInterface(factory, &IID_IDXGIFactory2, (void **)&f2);
    fprintf(stderr, "IDXGIFactory2=%p  %s\n", f2, f2 ? "available" : "NOT AVAILABLE");
    if (f2) {
        DXGI_SWAP_CHAIN_DESC1 d1 = {0};
        d1.Width = 640; d1.Height = 480;
        d1.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        d1.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        d1.SampleDesc.Count = 1;
        struct { DXGI_SWAP_EFFECT e; UINT n; const char *name; } modes[] = {
            { DXGI_SWAP_EFFECT_DISCARD,          1, "DISCARD" },
            { DXGI_SWAP_EFFECT_SEQUENTIAL,       2, "SEQUENTIAL" },
            { DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,  2, "FLIP_SEQUENTIAL" },
            { DXGI_SWAP_EFFECT_FLIP_DISCARD,     2, "FLIP_DISCARD" },
        };
        for (int i = 0; i < 4; i++) {
            IDXGISwapChain1 *s1 = NULL;
            d1.SwapEffect = modes[i].e;
            d1.BufferCount = modes[i].n;
            hr = f2->lpVtbl->CreateSwapChainForHwnd(f2, (IUnknown *)dev, hwnd, &d1, NULL, NULL, &s1);
            fprintf(stderr, "  CreateSwapChainForHwnd(%-16s) hr=0x%lx  %s\n",
                    modes[i].name, (unsigned long)hr, SUCCEEDED(hr) ? "OK" : "FAILED");
            if (s1) s1->lpVtbl->Release(s1);
        }
    }

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = 640; td.Height = 480; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D *tex = NULL;
    hr = dev->lpVtbl->CreateTexture2D(dev, &td, NULL, &tex);
    fprintf(stderr, "CreateTexture2D(offscreen) hr=0x%lx tex=%p  %s\n",
            (unsigned long)hr, tex, SUCCEEDED(hr) ? "OK" : "FAILED");
    return 0;
}

/* d3d11-fps-cap-test — verify Mullion's Present-thread MULLION_MAX_FPS pacer.
 *
 *   x86_64-w64-mingw32-gcc -O2 tests/d3d11-fps-cap-test.c -o /tmp/d3d11-fps-cap.exe \
 *       -ld3d11 -ldxgi -luser32 -luuid
 *   MULLION_MAX_FPS=30 wine64 /tmp/d3d11-fps-cap.exe 30 800 3000
 *   MULLION_MAX_FPS=0  wine64 /tmp/d3d11-fps-cap.exe 30 0   500
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int frames = argc > 1 ? atoi(argv[1]) : 30;
    double min_ms = argc > 2 ? atof(argv[2]) : 0.0;
    double max_ms = argc > 3 ? atof(argv[3]) : 10000.0;
    UINT sync_interval = argc > 4 ? (UINT)atoi(argv[4]) : 0;

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "MullionFpsCapTest";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA(wc.lpszClassName, "fps-cap", WS_OVERLAPPEDWINDOW,
                              0, 0, 256, 256, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { fprintf(stderr, "FAIL: CreateWindowA\n"); return 1; }

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = 256;
    sd.BufferDesc.Height = 256;
    sd.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *sc = NULL;
    D3D_FEATURE_LEVEL fl = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
        &sd, &sc, &dev, &fl, &ctx);
    if (FAILED(hr)) { fprintf(stderr, "FAIL: D3D11CreateDeviceAndSwapChain hr=0x%lx\n", (unsigned long)hr); return 1; }

    /* Warm up 2 frames */
    for (int i = 0; i < 2; i++) IDXGISwapChain_Present(sc, sync_interval, 0);

    LARGE_INTEGER freq, t0, t1;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0);
    for (int i = 0; i < frames; i++) {
        hr = IDXGISwapChain_Present(sc, sync_interval, 0);
        if (FAILED(hr)) { fprintf(stderr, "FAIL: Present hr=0x%lx\n", (unsigned long)hr); return 1; }
    }
    QueryPerformanceCounter(&t1);

    double elapsed_ms = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / (double)freq.QuadPart;
    double fps = frames * 1000.0 / (elapsed_ms > 0.001 ? elapsed_ms : 0.001);
    printf("presented %d frames in %.1f ms (%.1f FPS)\n", frames, elapsed_ms, fps);

    IDXGISwapChain_Release(sc);
    ID3D11DeviceContext_Release(ctx);
    ID3D11Device_Release(dev);
    DestroyWindow(hwnd);

    if (elapsed_ms < min_ms || elapsed_ms > max_ms) {
        fprintf(stderr, "FAIL: elapsed %.1f ms outside [%.1f, %.1f] ms\n", elapsed_ms, min_ms, max_ms);
        return 1;
    }
    return 0;
}

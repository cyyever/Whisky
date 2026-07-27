/* d3d11-featurelevel-test.c — print the feature level DXMT gives for a HW
 * device. ANGLE's D3D11 backend derives GLES version from this: FL9_3 caps at
 * GLES2 (SharedImageStub death-loop); FL10_0+ gives GLES3 (no loop, UI paints).
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d11-featurelevel-test.exe \
 *          d3d11-featurelevel-test.c -mconsole -ld3d11 -ldxgi
 * Run:   WINEPREFIX=<bottle> wine64 d3d11-featurelevel-test.exe
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

static const char *fl_name(D3D_FEATURE_LEVEL fl)
{
    switch (fl)
    {
        case D3D_FEATURE_LEVEL_11_1: return "11_1 (-> GLES3.1)";
        case D3D_FEATURE_LEVEL_11_0: return "11_0 (-> GLES3.1)";
        case D3D_FEATURE_LEVEL_10_1: return "10_1 (-> GLES3.0)";
        case D3D_FEATURE_LEVEL_10_0: return "10_0 (-> GLES3.0)";
        case D3D_FEATURE_LEVEL_9_3:  return "9_3  (-> GLES2 ONLY ** death-loop **)";
        case D3D_FEATURE_LEVEL_9_2:  return "9_2  (-> GLES2)";
        case D3D_FEATURE_LEVEL_9_1:  return "9_1  (-> GLES2)";
        default: return "?";
    }
}

int main(void)
{
    D3D_FEATURE_LEVEL req[] = {
        D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_3, D3D_FEATURE_LEVEL_9_2, D3D_FEATURE_LEVEL_9_1,
    };
    D3D_FEATURE_LEVEL got = 0;
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
                                   req, sizeof(req)/sizeof(req[0]),
                                   D3D11_SDK_VERSION, &dev, &got, &ctx);
    printf("D3D11CreateDevice(HARDWARE) hr=0x%lx  featureLevel=0x%x  %s\n",
           (unsigned long)hr, got, fl_name(got));

    /* Also try WARP (software) for contrast. */
    hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, 0,
                           req, sizeof(req)/sizeof(req[0]),
                           D3D11_SDK_VERSION, &dev, &got, &ctx);
    printf("D3D11CreateDevice(WARP)      hr=0x%lx  featureLevel=0x%x  %s\n",
           (unsigned long)hr, got, fl_name(got));
    return 0;
}

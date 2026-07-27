/* angle-shared-context-test.c — minimal reproducer for the webhelper's
 * "Failed to create shared context for virtualization", at the SAME layer
 * (ANGLE EGL), using a WINDOW surface (not Pbuffer) so the Vulkan backend
 * actually requests VK_KHR_win32_surface -> host VK_KHR_surface, exercising
 * the real WSI path.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o angle-shared-context-test.exe \
 *          angle-shared-context-test.c -mconsole -lgdi32
 * Run:   copy the .exe next to cef.win64/libEGL.dll, then
 *        GLTEST_BACKEND=vulkan VK_DRIVER_FILES=<kosmickrisp_icd.json> \
 *          WINEPREFIX=<bottle> wine64 .../cef.win64/angle-shared-context-test.exe
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

typedef int EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef void *EGLDisplay, *EGLConfig, *EGLContext, *EGLSurface, *EGLNativeWindowType, *EGLNativeDisplayType;

#define EGL_DEFAULT_DISPLAY ((EGLNativeDisplayType)0)
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_SURFACE_TYPE 0x3033
#define EGL_WINDOW_BIT 0x0004
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_ES2_BIT 0x0004
#define EGL_OPENGL_ES3_BIT 0x0040
#define EGL_NONE 0x3038
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_VENDOR 0x3053
#define EGL_VERSION 0x3054
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#define EGL_PLATFORM_ANGLE_TYPE_VULKAN_ANGLE 0x3451
#define EGL_PLATFORM_ANGLE_TYPE_OPENGL_ANGLE 0x320D
#define EGL_PLATFORM_ANGLE_TYPE_OPENGLES_ANGLE 0x320E
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE 0x3244
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_SWIFTSHADER_ANGLE 0x3247

typedef EGLDisplay (WINAPI *PFN_eglGetDisplay)(EGLNativeDisplayType);
typedef EGLDisplay (WINAPI *PFN_eglGetPlatformDisplay)(EGLenum, void *, const EGLint *);
typedef EGLBoolean (WINAPI *PFN_eglInitialize)(EGLDisplay, EGLint *, EGLint *);
typedef EGLBoolean (WINAPI *PFN_eglBindAPI)(EGLenum);
typedef EGLBoolean (WINAPI *PFN_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
typedef EGLContext (WINAPI *PFN_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
typedef EGLSurface (WINAPI *PFN_eglCreateWindowSurface)(EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint *);
typedef EGLint (WINAPI *PFN_eglGetError)(void);
typedef const char *(WINAPI *PFN_eglQueryString)(EGLDisplay, EGLint);

static PFN_eglGetDisplay eglGetDisplay;
static PFN_eglGetPlatformDisplay eglGetPlatformDisplay;
static PFN_eglInitialize eglInitialize;
static PFN_eglBindAPI eglBindAPI;
static PFN_eglChooseConfig eglChooseConfig;
static PFN_eglCreateContext eglCreateContext;
static PFN_eglCreateWindowSurface eglCreateWindowSurface;
static PFN_eglGetError eglGetError;
static PFN_eglQueryString eglQueryString;

static HWND g_hwnd;

/* attrs: NULL -> eglGetDisplay default (D3D11); else an ANGLE platform attr list. */
static void test_backend(const char *label, const EGLint *attrs) {
    printf("\n======== backend: %s ========\n", label); fflush(stdout);
    EGLDisplay dpy;
    if (attrs)
        dpy = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, attrs);
    else
        dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint maj = 0, min = 0;
    if (!eglInitialize(dpy, &maj, &min)) {
        printf("  eglInitialize FAIL err=0x%x -- backend unavailable\n", eglGetError());
        return;
    }
    printf("  EGL %d.%d  VENDOR=%s\n", maj, min, eglQueryString(dpy, EGL_VENDOR));
    eglBindAPI(EGL_OPENGL_ES_API);

    const EGLint cfg_attrs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT | EGL_OPENGL_ES3_BIT, EGL_NONE,
    };
    EGLConfig cfg; EGLint nc = 0;
    eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &nc);
    if (!nc) { printf("  no config err=0x%x\n", eglGetError()); return; }

    EGLSurface surf = eglCreateWindowSurface(dpy, cfg, (EGLNativeWindowType)g_hwnd, NULL);
    printf("  eglCreateWindowSurface: %p err=0x%x\n", surf, eglGetError());
    if (!surf) { printf("  no surface -- aborting backend\n"); return; }

    EGLint ctx3[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLint ctx2[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };

    EGLContext primary3 = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx3);
    printf("  primary GLES3:  %p err=0x%x\n", primary3, eglGetError());
    EGLContext primary = primary3;
    if (!primary) { primary = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx2); printf("  primary GLES2:  %p err=0x%x\n", primary, eglGetError()); }
    if (!primary) { printf("  no primary context at all\n"); return; }

    EGLContext shared3 = eglCreateContext(dpy, cfg, primary, ctx3);
    printf("  SHARED GLES3:   %p err=0x%x   %s\n", shared3, eglGetError(),
           shared3 ? "(virtualization would SUCCEED)" : "(*** webhelper failure ***)");
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

int main(void) {
    HMODULE hegl = LoadLibraryA("libEGL.dll");
    if (!hegl) { printf("FAIL: cannot load libEGL.dll (err %lu)\n", GetLastError()); return 1; }

#define GET(name) name = (PFN_##name)GetProcAddress(hegl, #name); if (!name) { printf("FAIL: no " #name "\n"); return 1; }
    GET(eglGetDisplay);
    GET(eglGetPlatformDisplay);
    GET(eglInitialize);
    GET(eglBindAPI);
    GET(eglChooseConfig);
    GET(eglCreateContext);
    GET(eglCreateWindowSurface);
    GET(eglGetError);
    GET(eglQueryString);

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = WndProc; wc.lpszClassName = "angletest"; wc.hInstance = GetModuleHandleA(NULL);
    RegisterClassA(&wc);
    g_hwnd = CreateWindowExA(0, "angletest", "angle test", WS_OVERLAPPEDWINDOW,
                             100, 100, 256, 256, NULL, NULL, wc.hInstance, NULL);

    const char *be = getenv("GLTEST_BACKEND");
    const int all = !be;
    if (all || strcmp(be, "d3d11") == 0)
        test_backend("D3D11 (default, wined3d)", NULL);
    if (all || strcmp(be, "vulkan") == 0) {
        EGLint a_vk[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_VULKAN_ANGLE, EGL_NONE };
        test_backend("Vulkan (winevulkan -> KosmicKrisp)", a_vk);
    }
    if (all || strcmp(be, "gl") == 0) {
        EGLint a_gl[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_OPENGL_ANGLE, EGL_NONE };
        test_backend("OpenGL (ANGLE GL -> wgl -> winemac 4.1)", a_gl);
    }
    if (all || strcmp(be, "swiftshader") == 0) {
        EGLint a_sw[] = {
            EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_VULKAN_ANGLE,
            EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_SWIFTSHADER_ANGLE,
            EGL_NONE,
        };
        test_backend("SwiftShader (software GLES3)", a_sw);
    }
    return 0;
}

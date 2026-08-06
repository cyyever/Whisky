/*
 * angle-window-surface-test — reproduce Chromium's failing ANGLE path without Chromium.
 *
 * Chromium/CEF under Wine never paints: its GPU layer fails at
 * `eglCreateWindowSurface` (EGL_BAD_ALLOC, after SwapChain11::reset returns
 * 0x80004005). tests/dxgi-swapchain-test.c already proved every DXGI call ANGLE
 * makes succeeds on DXMT at feature level 11_0, so the fault is inside ANGLE's
 * own libGLESv2 — but Chromium is a poor place to look at it from.
 *
 * This makes the same EGL calls directly against the ANGLE DLLs already shipped
 * in the bottle (Chromium's, Steam CEF's, or GOG's), on a plain Win32 HWND.
 *
 * The point of doing it this way is EGL_KHR_debug: ANGLE routes its *internal*
 * error strings through that callback even in release builds, so we get the
 * message text that would otherwise need a debug build of ANGLE.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O1 -o angle-window-surface-test.exe \
 *       angle-window-surface-test.c -luser32 -lgdi32
 *
 * Run (inside a bottle, from the directory holding libEGL.dll/libGLESv2.dll):
 *   wine angle-window-surface-test.exe
 *   wine angle-window-surface-test.exe 'C:\path\to\chrome-win'
 */

#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>

/* EGL types and constants, declared here so the test needs no Khronos headers. */
typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLSurface;
typedef void *EGLContext;
typedef void *EGLLabelKHR;
typedef void *EGLObjectKHR;
typedef int EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef intptr_t EGLAttrib;
typedef HWND EGLNativeWindowType;

#define EGL_FALSE                              0
#define EGL_TRUE                               1
#define EGL_NONE                          0x3038
#define EGL_SUCCESS                       0x3000
#define EGL_NO_DISPLAY                    ((EGLDisplay)0)
#define EGL_NO_SURFACE                    ((EGLSurface)0)
#define EGL_NO_CONTEXT                    ((EGLContext)0)
#define EGL_RED_SIZE                      0x3024
#define EGL_GREEN_SIZE                    0x3023
#define EGL_BLUE_SIZE                     0x3022
#define EGL_ALPHA_SIZE                    0x3021
#define EGL_DEPTH_SIZE                    0x3025
#define EGL_SURFACE_TYPE                  0x3033
#define EGL_WINDOW_BIT                    0x0004
#define EGL_RENDERABLE_TYPE               0x3040
#define EGL_OPENGL_ES2_BIT                0x0004
#define EGL_CONTEXT_CLIENT_VERSION        0x3098
#define EGL_VENDOR                        0x3053
#define EGL_VERSION                       0x3054
#define EGL_EXTENSIONS                    0x3055

/* EGL_ANGLE_platform_angle */
#define EGL_PLATFORM_ANGLE_ANGLE                     0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE                0x3203
#define EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE           0x3207
#define EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE          0x3208
#define EGL_PLATFORM_ANGLE_TYPE_OPENGL_ANGLE         0x320D
#define EGL_PLATFORM_ANGLE_TYPE_OPENGLES_ANGLE       0x320E
#define EGL_PLATFORM_ANGLE_TYPE_VULKAN_ANGLE         0x3450

/* EGL_KHR_debug */
#define EGL_DEBUG_MSG_CRITICAL_KHR        0x33B9
#define EGL_DEBUG_MSG_ERROR_KHR           0x33BA
#define EGL_DEBUG_MSG_WARN_KHR            0x33BB
#define EGL_DEBUG_MSG_INFO_KHR            0x33BC

typedef void(__stdcall *EGLDEBUGPROCKHR)(EGLenum error, const char *command,
                                         EGLint messageType, EGLLabelKHR threadLabel,
                                         EGLLabelKHR objectLabel, const char *message);

typedef EGLDisplay(__stdcall *PFNEGLGETPLATFORMDISPLAYEXT)(EGLenum, void *, const EGLint *);
typedef EGLDisplay(__stdcall *PFNEGLGETDISPLAY)(void *);
typedef EGLBoolean(__stdcall *PFNEGLINITIALIZE)(EGLDisplay, EGLint *, EGLint *);
typedef EGLBoolean(__stdcall *PFNEGLCHOOSECONFIG)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
typedef EGLSurface(__stdcall *PFNEGLCREATEWINDOWSURFACE)(EGLDisplay, EGLConfig, EGLNativeWindowType, const EGLint *);
typedef EGLContext(__stdcall *PFNEGLCREATECONTEXT)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
typedef EGLBoolean(__stdcall *PFNEGLMAKECURRENT)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
typedef EGLBoolean(__stdcall *PFNEGLSWAPBUFFERS)(EGLDisplay, EGLSurface);
typedef EGLint(__stdcall *PFNEGLGETERROR)(void);
typedef const char *(__stdcall *PFNEGLQUERYSTRING)(EGLDisplay, EGLint);
typedef void *(__stdcall *PFNEGLGETPROCADDRESS)(const char *);
typedef EGLBoolean(__stdcall *PFNEGLDEBUGMESSAGECONTROLKHR)(EGLDEBUGPROCKHR, const EGLAttrib *);
typedef EGLBoolean(__stdcall *PFNEGLTERMINATE)(EGLDisplay);

static PFNEGLGETPLATFORMDISPLAYEXT  p_eglGetPlatformDisplayEXT;
static PFNEGLGETDISPLAY             p_eglGetDisplay;
static PFNEGLINITIALIZE             p_eglInitialize;
static PFNEGLCHOOSECONFIG           p_eglChooseConfig;
static PFNEGLCREATEWINDOWSURFACE    p_eglCreateWindowSurface;
static PFNEGLCREATECONTEXT          p_eglCreateContext;
static PFNEGLMAKECURRENT            p_eglMakeCurrent;
static PFNEGLSWAPBUFFERS            p_eglSwapBuffers;
static PFNEGLGETERROR               p_eglGetError;
static PFNEGLQUERYSTRING            p_eglQueryString;
static PFNEGLGETPROCADDRESS         p_eglGetProcAddress;
static PFNEGLTERMINATE              p_eglTerminate;

/* ANGLE's own diagnostics. Without this the test would only ever see an EGL
 * error code, which is exactly the dead end Chromium's log leaves us at. */
static void __stdcall debug_callback(EGLenum error, const char *command, EGLint type,
                                     EGLLabelKHR thread_label, EGLLabelKHR object_label,
                                     const char *message)
{
    const char *level = type == EGL_DEBUG_MSG_CRITICAL_KHR ? "CRIT"
                      : type == EGL_DEBUG_MSG_ERROR_KHR    ? "ERR "
                      : type == EGL_DEBUG_MSG_WARN_KHR     ? "WARN"
                                                           : "INFO";
    printf("    [ANGLE %s] %s: error 0x%04x: %s\n", level,
           command ? command : "?", error, message ? message : "(no message)");
    fflush(stdout);
}

static const char *egl_error_name(EGLint err)
{
    switch (err)
    {
    case 0x3000: return "EGL_SUCCESS";
    case 0x3001: return "EGL_NOT_INITIALIZED";
    case 0x3002: return "EGL_BAD_ACCESS";
    case 0x3003: return "EGL_BAD_ALLOC";
    case 0x3004: return "EGL_BAD_ATTRIBUTE";
    case 0x3005: return "EGL_BAD_CONFIG";
    case 0x3006: return "EGL_BAD_CONTEXT";
    case 0x3007: return "EGL_BAD_CURRENT_SURFACE";
    case 0x3008: return "EGL_BAD_DISPLAY";
    case 0x3009: return "EGL_BAD_MATCH";
    case 0x300A: return "EGL_BAD_NATIVE_PIXMAP";
    case 0x300B: return "EGL_BAD_NATIVE_WINDOW";
    case 0x300C: return "EGL_BAD_PARAMETER";
    case 0x300D: return "EGL_BAD_SURFACE";
    case 0x300E: return "EGL_CONTEXT_LOST";
    default:     return "?";
    }
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void register_class(void)
{
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "AngleSurfaceTest";
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&wc);
}

/* A window shape to hand ANGLE. A plain visible toplevel is the easy case; the
 * others are the shapes Chromium actually presents to its GPU layer, which is
 * where the interesting failures should live. */
struct window_kind
{
    const char *name;
    DWORD style;
    int x, y, cx, cy;
    int show;      /* call ShowWindow */
    int parented;  /* create as a child of a host window, like CEF's render widget */
};

static const struct window_kind window_kinds[] = {
    {"visible toplevel 640x480", WS_OVERLAPPEDWINDOW, 100, 100, 640, 480, 1, 0},
    /* Steam's CEF login window is created 0x0: if ANGLE builds the swap chain
     * from the client rect, D3D11 rejects a 0-extent buffer and the resulting
     * E_FAIL surfaces to the caller as EGL_BAD_ALLOC. */
    {"zero-size 0x0",            WS_OVERLAPPEDWINDOW, 100, 100,   0,   0, 1, 0},
    /* Created hidden and never shown — CEF's WasHidden path. */
    {"hidden (never shown)",     WS_OVERLAPPEDWINDOW, 100, 100, 640, 480, 0, 0},
    /* Parked at INT_MIN, the other half of the observed login-window geometry. */
    {"offscreen INT_MIN",        WS_OVERLAPPEDWINDOW, INT_MIN, INT_MIN, 640, 480, 1, 0},
    /* A child HWND, which is what a browser hands its compositor. */
    {"child of toplevel",        WS_CHILD | WS_VISIBLE,   0,   0, 640, 480, 1, 1},
};

static HWND make_window(const struct window_kind *kind)
{
    HWND parent = NULL;
    if (kind->parented)
    {
        parent = CreateWindowExA(0, "AngleSurfaceTest", "ANGLE host",
                                 WS_OVERLAPPEDWINDOW, 100, 100, 660, 500,
                                 NULL, NULL, GetModuleHandleA(NULL), NULL);
        if (parent) ShowWindow(parent, SW_SHOW);
    }
    HWND hwnd = CreateWindowExA(0, "AngleSurfaceTest", "ANGLE window surface test",
                                kind->style, kind->x, kind->y, kind->cx, kind->cy,
                                parent, NULL, GetModuleHandleA(NULL), NULL);
    if (hwnd && kind->show) { ShowWindow(hwnd, SW_SHOW); UpdateWindow(hwnd); }
    return hwnd;
}

struct backend
{
    const char *name;
    EGLint type;  /* 0 = let ANGLE pick (what Chromium does by default) */
};

/* Run the whole browser-side sequence on one backend. Each step prints its own
 * result, so a failure names the exact call rather than just the end state. */
static void try_backend(const struct backend *be, HWND hwnd, const char *window_name)
{
    printf("\n=== backend: %s | window: %s ===\n", be->name, window_name);
    fflush(stdout);

    EGLDisplay dpy;
    if (be->type && p_eglGetPlatformDisplayEXT)
    {
        EGLint attrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, be->type, EGL_NONE};
        dpy = p_eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)0, attrs);
    }
    else
    {
        dpy = p_eglGetDisplay((void *)0);
    }
    if (dpy == EGL_NO_DISPLAY)
    {
        printf("  eglGetDisplay          FAILED (%s)\n", egl_error_name(p_eglGetError()));
        return;
    }
    printf("  eglGetDisplay          ok  (%p)\n", dpy);

    EGLint major = 0, minor = 0;
    if (!p_eglInitialize(dpy, &major, &minor))
    {
        printf("  eglInitialize          FAILED (%s)\n", egl_error_name(p_eglGetError()));
        return;
    }
    printf("  eglInitialize          ok  EGL %d.%d\n", major, minor);
    printf("    vendor  : %s\n", p_eglQueryString(dpy, EGL_VENDOR));
    printf("    version : %s\n", p_eglQueryString(dpy, EGL_VERSION));

    EGLint cfg_attrs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,   8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE,  8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0,
        EGL_NONE
    };
    EGLConfig config = NULL;
    EGLint num_config = 0;
    if (!p_eglChooseConfig(dpy, cfg_attrs, &config, 1, &num_config) || num_config < 1)
    {
        printf("  eglChooseConfig        FAILED (%s, %d configs)\n",
               egl_error_name(p_eglGetError()), num_config);
        p_eglTerminate(dpy);
        return;
    }
    printf("  eglChooseConfig        ok  (%d config)\n", num_config);

    /* The call Chromium dies on. */
    EGLSurface surface = p_eglCreateWindowSurface(dpy, config, hwnd, NULL);
    if (surface == EGL_NO_SURFACE)
    {
        printf("  eglCreateWindowSurface FAILED (%s)   <-- Chromium's failure\n",
               egl_error_name(p_eglGetError()));
        p_eglTerminate(dpy);
        return;
    }
    printf("  eglCreateWindowSurface ok  (%p)\n", surface);

    EGLint ctx_attrs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    EGLContext ctx = p_eglCreateContext(dpy, config, EGL_NO_CONTEXT, ctx_attrs);
    if (ctx == EGL_NO_CONTEXT)
    {
        printf("  eglCreateContext       FAILED (%s)\n", egl_error_name(p_eglGetError()));
        p_eglTerminate(dpy);
        return;
    }
    printf("  eglCreateContext       ok  (%p)\n", ctx);

    if (!p_eglMakeCurrent(dpy, surface, surface, ctx))
    {
        printf("  eglMakeCurrent         FAILED (%s)\n", egl_error_name(p_eglGetError()));
        p_eglTerminate(dpy);
        return;
    }
    printf("  eglMakeCurrent         ok\n");

    /* Paint magenta and present: if this backend works, the window turns a
     * colour the plain WNDCLASS background never is, so "it rendered" is
     * something the user can confirm by eye rather than from a log line. */
    void (__stdcall *p_glClearColor)(float, float, float, float) =
        p_eglGetProcAddress("glClearColor");
    void (__stdcall *p_glClear)(unsigned) = p_eglGetProcAddress("glClear");
    if (p_glClearColor && p_glClear)
    {
        for (int i = 0; i < 30; i++)
        {
            p_glClearColor(1.0f, 0.0f, 1.0f, 1.0f);
            p_glClear(0x00004000 /* GL_COLOR_BUFFER_BIT */);
            if (!p_eglSwapBuffers(dpy, surface))
            {
                printf("  eglSwapBuffers         FAILED (%s)\n", egl_error_name(p_eglGetError()));
                break;
            }
            MSG msg;
            while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
            {
                TranslateMessage(&msg);
                DispatchMessageA(&msg);
            }
            Sleep(16);
        }
        printf("  eglSwapBuffers         ok  (window should be MAGENTA for ~1s)\n");
    }

    p_eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    p_eglTerminate(dpy);
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : NULL;

    /* libEGL imports from libGLESv2, and Wine's loader will not find a sibling
     * DLL by directory alone, so load the dependency explicitly and first. */
    char path[MAX_PATH];
    HMODULE gles, egl;
    if (dir)
    {
        snprintf(path, sizeof(path), "%s\\libGLESv2.dll", dir);
        gles = LoadLibraryA(path);
        snprintf(path, sizeof(path), "%s\\libEGL.dll", dir);
        egl = LoadLibraryA(path);
    }
    else
    {
        gles = LoadLibraryA("libGLESv2.dll");
        egl = LoadLibraryA("libEGL.dll");
    }
    printf("libGLESv2.dll: %p   libEGL.dll: %p\n", gles, egl);
    if (!egl || !gles)
    {
        printf("FATAL: could not load ANGLE (error %lu). Run from the directory\n"
               "holding libEGL.dll/libGLESv2.dll, or pass it as argv[1].\n", GetLastError());
        return 1;
    }

#define LOAD(var, name)                                                       \
    var = (void *)GetProcAddress(egl, name);                                  \
    if (!var) { printf("FATAL: %s missing from libEGL.dll\n", name); return 1; }

    LOAD(p_eglGetDisplay,          "eglGetDisplay")
    LOAD(p_eglInitialize,          "eglInitialize")
    LOAD(p_eglChooseConfig,        "eglChooseConfig")
    LOAD(p_eglCreateWindowSurface, "eglCreateWindowSurface")
    LOAD(p_eglCreateContext,       "eglCreateContext")
    LOAD(p_eglMakeCurrent,         "eglMakeCurrent")
    LOAD(p_eglSwapBuffers,         "eglSwapBuffers")
    LOAD(p_eglGetError,            "eglGetError")
    LOAD(p_eglQueryString,         "eglQueryString")
    LOAD(p_eglGetProcAddress,      "eglGetProcAddress")
    LOAD(p_eglTerminate,           "eglTerminate")
#undef LOAD

    p_eglGetPlatformDisplayEXT = p_eglGetProcAddress("eglGetPlatformDisplayEXT");
    printf("eglGetPlatformDisplayEXT: %p\n", p_eglGetPlatformDisplayEXT);

    /* Client extensions are queryable before any display exists. */
    const char *client_ext = p_eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    printf("client extensions: %s\n", client_ext ? client_ext : "(none)");

    PFNEGLDEBUGMESSAGECONTROLKHR p_debug = p_eglGetProcAddress("eglDebugMessageControlKHR");
    if (p_debug)
    {
        EGLAttrib attrs[] = {
            EGL_DEBUG_MSG_CRITICAL_KHR, EGL_TRUE,
            EGL_DEBUG_MSG_ERROR_KHR,    EGL_TRUE,
            EGL_DEBUG_MSG_WARN_KHR,     EGL_TRUE,
            EGL_DEBUG_MSG_INFO_KHR,     EGL_TRUE,
            EGL_NONE
        };
        p_debug(debug_callback, attrs);
        printf("EGL_KHR_debug: enabled (ANGLE-internal messages follow)\n");
    }
    else
    {
        printf("EGL_KHR_debug: NOT available — only error codes, no ANGLE messages\n");
    }

    register_class();

    static const struct backend backends[] = {
        {"default", 0},
        {"d3d11",   EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE},
        {"d3d9",    EGL_PLATFORM_ANGLE_TYPE_D3D9_ANGLE},
        {"opengl",  EGL_PLATFORM_ANGLE_TYPE_OPENGL_ANGLE},
        {"opengles", EGL_PLATFORM_ANGLE_TYPE_OPENGLES_ANGLE},
        {"vulkan",  EGL_PLATFORM_ANGLE_TYPE_VULKAN_ANGLE},
    };

    /* d3d9/vulkan drag in DXVK + KosmicKrisp, whose first device creation takes
     * minutes on this stack and swamps the run, so they are opt-in. argv[2] is a
     * comma-separated list of backend names, or "all". */
    const char *filter = argc > 2 ? argv[2] : "default,d3d11";
    printf("backends: %s\n", filter);
    fflush(stdout);

    for (size_t b = 0; b < sizeof(backends) / sizeof(backends[0]); b++)
    {
        if (strcmp(filter, "all") != 0 && !strstr(filter, backends[b].name))
            continue;
        for (size_t w = 0; w < sizeof(window_kinds) / sizeof(window_kinds[0]); w++)
        {
            HWND hwnd = make_window(&window_kinds[w]);
            if (!hwnd)
            {
                printf("\n=== backend: %s | window: %s ===\n  CreateWindow FAILED (%lu)\n",
                       backends[b].name, window_kinds[w].name, GetLastError());
                continue;
            }
            RECT rc = {0};
            GetClientRect(hwnd, &rc);
            try_backend(&backends[b], hwnd, window_kinds[w].name);
            printf("  (client rect %ldx%ld, visible=%d)\n",
                   rc.right - rc.left, rc.bottom - rc.top, IsWindowVisible(hwnd));
            DestroyWindow(hwnd);
        }
    }

    printf("\ndone\n");
    return 0;
}

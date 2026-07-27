/* gl-shared-context-test.c — localize the webhelper "Failed to create shared
 * context for virtualization" at the lowest GL layer (winemac/CGL).
 *
 * The webhelper GPU path is ANGLE(D3D11) -> wined3d -> winemac/CGL, and wined3d's
 * GL contexts go through the SAME winemac/CGL layer as wgl. This probe answers:
 *   - what GL version winemac actually gives (the doc assumed 4.1; verify),
 *   - whether a GL 3.2 CORE context can be created (macOS only has 3.2+, not 3.0),
 *   - whether a SHARED 2.1 context can be created (the webhelper's exact case:
 *     primary GLES2/2.1 works, the *shared* one fails),
 *   - whether texture sharing actually works across two contexts.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o gl-shared-context-test.exe \
 *          gl-shared-context-test.c -lopengl32 -lgdi32 -mconsole
 * Run:   WINEPREFIX=<bottle> wine64 gl-shared-context-test.exe
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define WGL_CONTEXT_MAJOR_VERSION_ARB    0x2091
#define WGL_CONTEXT_MINOR_VERSION_ARB    0x2092
#define WGL_CONTEXT_PROFILE_MASK_ARB     0x2094
#define WGL_CONTEXT_CORE_PROFILE_BIT_ARB 0x00000002

typedef HGLRC (WINAPI *PFN_crarb)(HDC, HGLRC, const int *);

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

static HGLRC ctx_versioned(HDC hdc, PFN_crarb f, HGLRC share, int major, int minor, int core) {
    int attrs[8], n = 0;
    attrs[n++] = WGL_CONTEXT_MAJOR_VERSION_ARB; attrs[n++] = major;
    attrs[n++] = WGL_CONTEXT_MINOR_VERSION_ARB; attrs[n++] = minor;
    if (core) { attrs[n++] = WGL_CONTEXT_PROFILE_MASK_ARB; attrs[n++] = WGL_CONTEXT_CORE_PROFILE_BIT_ARB; }
    attrs[n] = 0;
    return f(hdc, share, attrs);
}

int main(void) {
    HINSTANCE hi = GetModuleHandleA(NULL);
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = WndProc; wc.lpszClassName = "glsharertest"; wc.hInstance = hi;
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowExA(0, "glsharertest", "GL render test -- close to stop",
                                WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                100, 100, 640, 480, NULL, NULL, hi, NULL);
    HDC hdc = GetDC(hwnd);
    PIXELFORMATDESCRIPTOR pfd = {0};
    pfd.nSize = sizeof(pfd); pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA; pfd.cColorBits = 24; pfd.cDepthBits = 24;
    int pf = ChoosePixelFormat(hdc, &pfd);
    SetPixelFormat(hdc, pf, &pfd);

    HGLRC dummy = wglCreateContext(hdc);
    wglMakeCurrent(hdc, dummy);
    printf("GL_VENDOR:   %s\n", glGetString(GL_VENDOR));
    printf("GL_RENDERER: %s\n", glGetString(GL_RENDERER));
    printf("GL_VERSION:  %s\n", glGetString(GL_VERSION));
    PFN_crarb crarb = (PFN_crarb)wglGetProcAddress("wglCreateContextAttribsARB");

    /* --- (A) primary 2.1 context (what wined3d/ANGLE GLES2 actually gets) --- */
    HGLRC primary = wglCreateContext(hdc);   /* legacy -> 2.1 */
    wglMakeCurrent(hdc, primary);
    printf("\n[A] primary 2.1 context:           %p\n", primary);

    /* --- (B) can winemac do a GL 3.2 CORE context at all? (macOS minimum) --- */
    if (crarb) {
        SetLastError(0);
        HGLRC c32 = ctx_versioned(hdc, crarb, NULL, 3, 2, 1);
        printf("[B] GL 3.2 core context:           %p  (err %lu)\n", c32, GetLastError());
        if (c32) {
            wglMakeCurrent(hdc, c32);
            printf("    -> GL_VERSION on 3.2 ctx: %s\n", glGetString(GL_VERSION));
            wglDeleteContext(c32);
        }
    }

    /* --- (C) THE KEY TEST: a SHARED 2.1 context (webhelper's exact case) --- */
    HGLRC shared = NULL;
    if (crarb) {
        SetLastError(0);
        shared = ctx_versioned(hdc, crarb, primary, 1, 0, 0);  /* share=primary, GL 1.0 (2.1 compat) */
        printf("[C] SHARED 2.1 context (ARB):      %p  (err %lu)\n", shared, GetLastError());
    }

    /* --- (D) legacy sharing via wglShareLists --- */
    HGLRC leg = wglCreateContext(hdc);
    SetLastError(0);
    BOOL sl = wglShareLists(primary, leg);
    printf("[D] wglShareLists(primary,leg):    %d  (err %lu)\n", sl, GetLastError());

    /* --- (E) verify texture sharing actually works --- */
    if (shared) {
        GLuint tex = 0;
        wglMakeCurrent(hdc, primary);
        glGenTextures(1, &tex);
        glBindTexture(GL_TEXTURE_2D, tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA, GL_UNSIGNED_BYTE, (void *)1);
        printf("\n[E] texture %u created in primary; GL error after upload: 0x%x\n", tex, glGetError());
        wglMakeCurrent(hdc, shared);
        glBindTexture(GL_TEXTURE_2D, tex);
        GLboolean is = glIsTexture(tex);
        printf("    texture %u in SHARED ctx: glIsTexture=%d  GL error: 0x%x\n", tex, is, glGetError());
    }

    printf("\n==== VERDICT ====\n");
    if (shared)
        printf("  shared 2.1 ctx OK + wglShareLists=%d => winemac/CGL sharing WORKS;\n"
               "  webhelper bug is in wined3d D3D11 shared-context path\n", sl);
    else if (!sl)
        printf("  shared ctx FAILED + wglShareLists FAILED => winemac/CGL SHARING broken (backend bug)\n");
    else
        printf("  ARB shared ctx FAILED but wglShareLists OK => ARB-shared path broken in winemac\n");

    if (getenv("GLTEST_NO_RENDER")) { printf("[F] render loop skipped (GLTEST_NO_RENDER)\n"); return 0; }

    /* --- [F] render loop: continuous, until the window is closed. Pumps the
     *       message queue so the close button works. A smooth blue<->red pulse
     *       makes any flicker/tear/flash obvious. If this single-swapchain GL
     *       loop is smooth, the doc's flicker is Vulkan/KosmicKrisp-specific
     *       (multi-swapchain on one Metal queue), not a general present bug. --- */
    printf("\n[F] GL render loop: continuous blue<->red pulse -- CLOSE THE WINDOW to stop.\n");
    fflush(stdout);
    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);
    SetForegroundWindow(hwnd);
    BringWindowToTop(hwnd);
    wglMakeCurrent(hdc, primary);
    MSG msg;
    int frame = 0;
    for (;;) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) goto done;
            TranslateMessage(&msg);
            DispatchMessageA(&msg);
        }
        float t = 0.5f + 0.5f * sinf(frame * 0.05f);
        glClearColor(t, 0.0f, 1.0f - t, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFlush();
        SwapBuffers(hdc);
        frame++;
        Sleep(16);
    }
done:
    printf("[F] window closed; exiting.\n");
    return 0;
}

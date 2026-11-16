/* Exercise real WGL calls and check progress after a driver exception.
 * --visible also exercises DPI-scaled drawables (use a 192 DPI prefix).
 * Default mode uses valid inputs. --fault passes a PAGE_NOACCESS attribute
 * list to wglCreateContextAttribsARB to test lock cleanup after SEH recovery.
 * This invalid-pointer probe models exception recovery, not the unknown Steam
 * trigger. No mutex is called directly. The watchdog bounds deadlocks.
 * Build the SEH object with clang targeting x86_64-w64-windows-gnu, then link
 * with x86_64-w64-mingw32-gcc -lopengl32 -lgdi32.
 */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <string.h>

typedef HGLRC (WINAPI *create_context_attribs_fn)(HDC, HGLRC, const int *);

static volatile LONG stage;
static HANDLE finished;
static DWORD fault;

static DWORD WINAPI watchdog(void *unused)
{
    (void)unused;
    if (WaitForSingleObject(finished, 15000) == WAIT_TIMEOUT)
    {
        fprintf(stderr, "FAIL: WGL stalled at stage %ld; prior exception %#lx\n", stage, fault);
        fflush(stderr);
        TerminateProcess(GetCurrentProcess(), 124);
    }
    return 0;
}

static LONG record_exception(EXCEPTION_POINTERS *e)
{
    fault = e->ExceptionRecord->ExceptionCode;
    fprintf(stderr, "EXCEPTION: stage %ld code %#lx address %p", stage, fault,
            e->ExceptionRecord->ExceptionAddress);
    if (fault == EXCEPTION_ACCESS_VIOLATION && e->ExceptionRecord->NumberParameters >= 2)
        fprintf(stderr, " operation %llu target %p", (unsigned long long)e->ExceptionRecord->ExceptionInformation[0],
                (void *)e->ExceptionRecord->ExceptionInformation[1]);
    fputc('\n', stderr);
    fflush(stderr);
    return EXCEPTION_EXECUTE_HANDLER;
}

int main(int argc, char **argv)
{
    WNDCLASSA wc = {0};
    PIXELFORMATDESCRIPTOR pfd = {0};
    HWND window;
    HDC dc;
    HGLRC context = NULL;
    HANDLE timer;
    BOOL bound = FALSE, fault_rejected = FALSE;
    BOOL inject_fault = argc == 2 && !strcmp(argv[1], "--fault");
    void *unreadable = NULL;
    int format, result = 1;
    setvbuf(stdout, NULL, _IONBF, 0);
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "WhiskyWglLockTest";
    if (!RegisterClassA(&wc)) return 2;
    window = CreateWindowA(wc.lpszClassName, "WGL lock test", WS_OVERLAPPEDWINDOW,
                           0, 0, 64, 64, NULL, NULL, wc.hInstance, NULL);
    if (!window || !(dc = GetDC(window))) return 2;
    if (argc == 2 && !strcmp(argv[1], "--visible"))
    {
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
    }
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 24;
    format = ChoosePixelFormat(dc, &pfd);
    if (!format || !SetPixelFormat(dc, format, &pfd)) return 2;
    finished = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!finished || !(timer = CreateThread(NULL, 0, watchdog, NULL, 0, NULL))) return 2;
    __try
    {
        InterlockedExchange(&stage, 1);
        puts("stage 1: wglCreateContext");
        context = wglCreateContext(dc);
        if (context)
        {
            InterlockedExchange(&stage, 2);
            puts("stage 2: first wglMakeCurrent");
            bound = wglMakeCurrent(dc, context);
            if (bound) printf("GL_VERSION: %s\n", glGetString(GL_VERSION));
            if (bound && inject_fault)
            {
                create_context_attribs_fn create_attribs =
                    (create_context_attribs_fn)wglGetProcAddress("wglCreateContextAttribsARB");
                unreadable = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_NOACCESS);
                if (!create_attribs || !unreadable)
                {
                    fputs("SETUP FAILED: fault probe unavailable\n", stderr);
                    ExitProcess(2);
                }
                InterlockedExchange(&stage, 5);
                puts("stage 5: WGL attribute access fault injection");
                SetLastError(0);
                HGLRC probe = create_attribs(dc, NULL, unreadable);
                DWORD error = GetLastError();
                printf("fault probe returned %p, error %lu\n", probe, error);
                fault_rejected = !probe && error == ERROR_NOACCESS;
                if (probe) wglDeleteContext(probe);
            }
        }
    }
    __except(record_exception(GetExceptionInformation()))
    {
        puts("Caught driver exception; checking whether WGL lock was released");
    }
    InterlockedExchange(&stage, 3);
    puts("stage 3: wglMakeCurrent(NULL, NULL)");
    wglMakeCurrent(NULL, NULL);
    InterlockedExchange(&stage, 4);
    puts("stage 4: wglDeleteContext");
    if (context) wglDeleteContext(context);
    result = !bound || (inject_fault ? !fault_rejected : !!fault);
    printf("%s: WGL calls completed; bound=%d exception=%#lx\n", result ? "FAIL" : "PASS", bound, fault);
    SetEvent(finished);
    WaitForSingleObject(timer, INFINITE);
    CloseHandle(timer);
    CloseHandle(finished);
    if (unreadable) VirtualFree(unreadable, 0, MEM_RELEASE);
    ReleaseDC(window, dc);
    DestroyWindow(window);
    return result;
}

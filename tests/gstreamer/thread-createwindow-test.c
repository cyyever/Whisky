/*
 * thread-createwindow-test — CreateWindowExW off the main thread, nothing else.
 *
 *   wine64 thread-createwindow-test.exe [seconds]
 *
 * The 32-bit DirectShow hang (tests/gstreamer/dshow-render-test.sh) ends in
 * quartz's message thread, blocked in CreateWindowExW -> NtUserCreateWindowEx
 * while autoplug waits on it. That stack has quartz, devenum, combase and
 * winegstreamer in it, any of which could be the real culprit. This strips all
 * of them: one worker thread, one window, no COM, no media.
 *
 * If this hangs in a 32-bit process and completes in a 64-bit one, the fault is
 * in win32u/winemac window creation under WoW64 and DirectShow is only the
 * messenger. If it completes in both, the hang needs something DirectShow does
 * on top -- the class it registers, the COM apartment it creates it from, or
 * the thread it uses.
 *
 * Exit code: 0 created, 1 timed out, 2 usage.
 */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static HANDLE done;

static DWORD WINAPI worker( void *arg )
{
    WNDCLASSEXW cls = { sizeof(cls) };
    HWND hwnd;

    cls.lpfnWndProc = DefWindowProcW;
    cls.hInstance = GetModuleHandleW( NULL );
    cls.lpszClassName = L"whisky_thread_createwindow";
    RegisterClassExW( &cls );

    printf( "      worker: calling CreateWindowExW\n" );
    hwnd = CreateWindowExW( 0, cls.lpszClassName, L"probe", WS_OVERLAPPEDWINDOW,
                            100, 100, 320, 200, NULL, NULL, cls.hInstance, NULL );
    printf( "      worker: CreateWindowExW returned %p\n", hwnd );
    if (hwnd) DestroyWindow( hwnd );
    SetEvent( done );
    return 0;
}

int main( int argc, char **argv )
{
    /* Unbuffered: on a timeout kill a block-buffered stdout is discarded, and
     * "printed nothing" then reads as "hung on the first call". */
    setvbuf( stdout, NULL, _IONBF, 0 );

    DWORD secs = (argc > 1) ? (DWORD)atol( argv[1] ) : 20;
    HANDLE thread;
    DWORD ret;

    done = CreateEventW( NULL, TRUE, FALSE, NULL );
    if (!(thread = CreateThread( NULL, 0, worker, NULL, 0, NULL )))
    {
        printf( "FAIL  CreateThread %lu\n", GetLastError() );
        return 2;
    }

    /* MsgWaitForMultipleObjects, not WaitForSingleObject: this thread owns the
     * process's first message queue, and a driver that dispatches window
     * creation to it deadlocks against a thread that only ever blocks. Pumping
     * here is what a real app does, so a hang under it is a real hang. */
    for (;;)
    {
        MSG msg;
        ret = MsgWaitForMultipleObjects( 1, &done, FALSE, secs * 1000, QS_ALLINPUT );
        if (ret == WAIT_OBJECT_0) { printf( "pass  window created off-thread\n" ); return 0; }
        if (ret == WAIT_TIMEOUT)  { printf( "FAIL  timed out after %lu s\n", secs ); return 1; }
        while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
        {
            TranslateMessage( &msg );
            DispatchMessageW( &msg );
        }
    }
}

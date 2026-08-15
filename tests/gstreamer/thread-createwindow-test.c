/*
 * thread-createwindow-test — CreateWindowExW off the main thread, nothing else.
 *
 *   wine64 thread-createwindow-test.exe [seconds] [nopump]
 *
 * The 32-bit DirectShow hang (tests/gstreamer/dshow-render-test.sh) ends in
 * quartz's message thread, blocked in CreateWindowExW -> NtUserCreateWindowEx
 * while autoplug waits on it. That stack has quartz, devenum, combase and
 * winegstreamer in it, any of which could be the real culprit. This strips all
 * of them: one worker thread, one window, no COM, no media.
 *
 * "nopump" is the mode that matches the real failure: quartz's caller is inside
 * a synchronous RenderFile and cannot pump, so if window creation needs the
 * first thread to service it, it never gets serviced. The default (pumping)
 * mode is the control -- it is what a well-behaved app does, and it passes.
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
#include <string.h>

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

    /* "nopump" accepted in either position, and a bad seconds value rejected:
     * `... nopump` alone used to give secs = atol("nopump") = 0 AND the pumping
     * mode -- an instant "timed out after 0 s" for the mode not even asked for,
     * indistinguishable from the hang this looks for. */
    BOOL nopump = FALSE;
    DWORD secs = 20;
    int i;

    for (i = 1; i < argc; i++)
    {
        if (!strcmp( argv[i], "nopump" )) nopump = TRUE;
        else if (atol( argv[i] ) > 0) secs = (DWORD)atol( argv[i] );
        else { printf( "usage: %s [seconds > 0] [nopump]\n", argv[0] ); return 2; }
    }
    HANDLE thread;
    DWORD ret;

    if (!(done = CreateEventW( NULL, TRUE, FALSE, NULL )))
    {
        printf( "FAIL  CreateEventW %lu\n", GetLastError() );
        return 2;
    }
    if (!(thread = CreateThread( NULL, 0, worker, NULL, 0, NULL )))
    {
        printf( "FAIL  CreateThread %lu\n", GetLastError() );
        return 2;
    }

    /* Pumping mode below; nopump takes the plain wait just above, which is the
     * point of that mode.
     *
     * MsgWaitForMultipleObjects, not WaitForSingleObject: this thread owns the
     * process's first message queue, and a driver that dispatches window
     * creation to it deadlocks against a thread that only ever blocks. Pumping
     * here is what a real app does, so a hang under it is a real hang.
     *
     * Against an ABSOLUTE deadline, not `secs` handed to each call: the failure
     * this looks for is a driver posting messages to this thread, so every batch
     * would re-arm the timeout from zero and the probe would pump forever
     * instead of ever reporting the hang. */
    if (nopump)
    {
        printf( "      main: blocking WITHOUT pumping (the RenderFile case)\n" );
        ret = WaitForSingleObject( done, secs * 1000 );
        if (ret == WAIT_OBJECT_0) { printf( "pass  window created off-thread\n" ); return 0; }
        printf( "FAIL  timed out after %lu s (no pump)\n", secs );
        return 1;
    }

    {
        ULONGLONG deadline = GetTickCount64() + (ULONGLONG)secs * 1000;
        for (;;)
        {
            ULONGLONG now = GetTickCount64();
            MSG msg;

            if (now >= deadline) { printf( "FAIL  timed out after %lu s\n", secs ); return 1; }
            ret = MsgWaitForMultipleObjects( 1, &done, FALSE, (DWORD)(deadline - now), QS_ALLINPUT );
            if (ret == WAIT_OBJECT_0) { printf( "pass  window created off-thread\n" ); return 0; }
            if (ret == WAIT_TIMEOUT)  { printf( "FAIL  timed out after %lu s\n", secs ); return 1; }
            if (ret == WAIT_FAILED)   { printf( "FAIL  MsgWaitForMultipleObjects %lu\n", GetLastError() ); return 2; }
            while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
            {
                TranslateMessage( &msg );
                DispatchMessageW( &msg );
            }
        }
    }
}

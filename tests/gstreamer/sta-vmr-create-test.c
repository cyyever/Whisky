/*
 * sta-vmr-create-test — quartz's shape, with no quartz graph.
 *
 *   wine64 sta-vmr-create-test.exe [seconds]
 *
 * dshow-render-test.sh shows a 32-bit RenderFile hanging where a 64-bit one
 * plays, with the stacks
 *
 *     main    : RenderFile -> autoplug -> NtWaitForSingleObject
 *     worker  : message_thread_run -> CoCreateInstance
 *               -> video_renderer_default_create -> vmr7_create
 *               -> video_window_create_window -> NtUserCreateWindowEx
 *
 * thread-createwindow-test then rules out the simple reading: a bare off-thread
 * CreateWindowExW completes in both bitnesses even with the first thread blocked
 * and not pumping. So the missing ingredient is COM, and this probe adds exactly
 * that and nothing else -- no file, no splitter, no decoder, no graph:
 *
 *     main thread   : CoInitializeEx(APARTMENTTHREADED), then blocks on an
 *                     event without pumping, which is what a synchronous
 *                     RenderFile does to its caller.
 *     worker thread : CoInitializeEx(MULTITHREADED), like quartz's message
 *                     thread, then CoCreateInstance(CLSID_VideoRenderer) --
 *                     the call that ends in CreateWindowExW.
 *
 * A 32-bit hang with a 64-bit pass here means the fault is cross-apartment
 * instantiation of the video renderer under WoW64, and DirectShow is only the
 * caller that happens to arrange it.
 *
 * Exit code: 0 created, 1 timed out, 2 setup failure.
 */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <stdio.h>
#include <stdlib.h>

static HANDLE done;
static HRESULT worker_hr = E_FAIL;

static DWORD WINAPI worker( void *arg )
{
    IBaseFilter *filter = NULL;
    MSG msg;

    /* A message queue first, exactly as message_thread_run does -- and then NOT
     * pumping while the object is created, which is also what it does (creation
     * happens inside its WM_USER handler). A worker with no queue at all is a
     * different animal, and passed in both bitnesses. */
    PeekMessageW( &msg, NULL, 0, 0, PM_NOREMOVE );

    /* MTA, exactly as quartz's message_thread_run does before servicing
     * filter-creation requests. */
    CoInitializeEx( NULL, COINIT_MULTITHREADED );

    printf( "      worker(MTA): CoCreateInstance(CLSID_VideoRenderer)\n" );
    worker_hr = CoCreateInstance( &CLSID_VideoRenderer, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IBaseFilter, (void **)&filter );
    printf( "      worker(MTA): returned 0x%08lx\n", (unsigned long)worker_hr );
    if (filter) IBaseFilter_Release( filter );

    CoUninitialize();
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

    if (FAILED( CoInitializeEx( NULL, COINIT_APARTMENTTHREADED ) ))
    {
        printf( "FAIL  CoInitializeEx(STA)\n" );
        return 2;
    }
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

    /* No pump. This is the whole point: the STA that owns the process's first
     * message queue is stuck inside a synchronous call, so anything that needs
     * it to run does not get run. */
    printf( "      main(STA): blocking without pumping\n" );
    ret = WaitForSingleObject( done, secs * 1000 );
    if (ret != WAIT_OBJECT_0)
    {
        printf( "FAIL  timed out after %lu s\n", secs );
        return 1;
    }
    if (FAILED( worker_hr ))
    {
        printf( "FAIL  CoCreateInstance 0x%08lx\n", (unsigned long)worker_hr );
        return 1;
    }
    printf( "pass  video renderer created from an MTA thread\n" );
    return 0;
}

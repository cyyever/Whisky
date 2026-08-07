/*
 * msync-msgloop-hang-test — assert a window's message pump keeps answering
 * while both of its wake sources are driven at once under msync.
 *
 * What this is for: Steam's "Special Offers" window cannot be closed. WM_CLOSE
 * is ignored, SendMessageTimeout(hwnd, WM_NULL) times out — so it is not a
 * handler declining to close, it is a dead pump — and `sample` shows the thread
 * that owns the window (CrBrowserMain) parked in msync_wait_single(). With the
 * bottle's enhanced sync set to none (WINEMSYNC=0) the same window closes
 * normally, so the fault is in msync, not in winemac or the window system.
 *
 * Why the test looks like this. The thing under test is a Chromium UI thread:
 * it blocks in MsgWaitForMultipleObjects over a set of events PLUS the message
 * queue, and drains with PeekMessage when the queue wakes it. Two wait shapes
 * matter and they take different code paths, so both are run here:
 *
 *     0 events  queue only     -> ONE object   -> msync_wait_single/__ulock_wait2
 *     N events  events + queue -> multi-object -> mach semaphore + registration
 *
 * The stuck Steam thread is on the first. Worker threads then drive both wake
 * sources at once (SetEvent and PostMessage), because a wake lost between the
 * two is the interleaving being hunted.
 *
 * Two details are load-bearing, and getting either wrong makes the test unable
 * to fail for the right reason:
 *
 *   - The pump waits INFINITE. With a finite timeout it wakes itself on expiry,
 *     a lost wakeup degrades from a hang into mere latency, and the probe can no
 *     longer see the thing it exists to find.
 *   - The detector is SendMessageTimeout(WM_NULL, SMTO_ABORTIFHUNG) from another
 *     thread — the exact call that fails against the real Steam window. A pump
 *     that is running answers WM_NULL immediately; a parked one cannot answer at
 *     all. Counting dispatched messages would not distinguish "slow" from "dead".
 *
 * Note the WINEMSYNC_NO_* gates cannot be used to narrow this down: switching an
 * object class to the server routes the whole wait into msync_wait_mixed_any(),
 * a polling loop, which cannot hang however broken the object is. Any gate would
 * look equally exculpatory. Use WINE_MRING=1 instead — it names the object a
 * parked thread is on and whether that object is already signaled.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O2 -o msync-msgloop-hang-test.exe msync-msgloop-hang-test.c
 * Run:
 *   wine64 msync-msgloop-hang-test.exe [seconds-per-case]   # exit 0 = pass
 *
 *   A failure here is only evidence about msync if the same run passes on the
 *   wineserver oracle, so confirm with:
 *       WINEMSYNC=0 wine64 msync-msgloop-hang-test.exe
 *   A stall under BOTH is a bug in this test or a loaded machine.
 *
 *   WINE_MRING=1 arms the in-tree wait-path tracer (patches/proton-wine/0010),
 *   which writes /tmp/mring_<pid>.log while this runs.
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_EVENTS   8
#define WORKERS      4
#define WM_PROBE     (WM_APP + 1)
#define PROBE_MS     100      /* how often the detector pokes the pump */
#define ANSWER_MS    1000     /* a live pump answers WM_NULL far inside this */
#define MAX_STALLS   3        /* proven by then; no value in watching it hang */

struct scenario
{
    int    n_events;
    int    alertable;      /* pump waits alertably; workers queue APCs and
                            * block in cross-thread SendMessage (see run_case) */
    HANDLE events[MAX_EVENTS];
    HWND   hwnd;
    HANDLE pump_thread_h;
    HANDLE ready;
    volatile LONG stop;
    volatile LONG dispatched;
    volatile LONG evt_wakes;
    volatile LONG apcs;
    volatile LONG sends;
};

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    struct scenario *s = (struct scenario *)GetWindowLongPtrW( hwnd, GWLP_USERDATA );

    switch (msg)
    {
    case WM_PROBE:
        if (s) InterlockedIncrement( &s->dispatched );
        return 0;
    case WM_CLOSE:
        DestroyWindow( hwnd );
        return 0;
    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcW( hwnd, msg, wp, lp );
}

static DWORD WINAPI pump_thread( void *arg )
{
    struct scenario *s = arg;
    WNDCLASSEXW wc;
    MSG msg;

    memset( &wc, 0, sizeof(wc) );
    wc.cbSize = sizeof(wc);

    wc.lpfnWndProc   = wnd_proc;
    wc.hInstance     = GetModuleHandleW( NULL );
    wc.lpszClassName = L"MsyncMsgLoopTest";
    RegisterClassExW( &wc );   /* may already exist from a previous case */

    s->hwnd = CreateWindowExW( 0, L"MsyncMsgLoopTest", L"msync msgloop test",
                               WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                               320, 200, NULL, NULL, wc.hInstance, NULL );
    if (!s->hwnd)
    {
        printf( "  CreateWindowEx failed: %lu\n", GetLastError() );
        SetEvent( s->ready );
        return 1;
    }
    SetWindowLongPtrW( s->hwnd, GWLP_USERDATA, (LONG_PTR)s );

    /* Make this a real UI thread with a queue before the detector starts, so a
     * slow first paint is never mistaken for a stall. */
    PeekMessageW( &msg, NULL, 0, 0, PM_NOREMOVE );
    SetEvent( s->ready );

    while (!InterlockedCompareExchange( &s->stop, 0, 0 ))
    {
        DWORD r;

        if (s->alertable)
        {
            /* What a Chromium UI thread actually runs. The alertable form takes a
             * different path from plain MsgWaitForMultipleObjects: the wait set
             * gains the thread's APC object, so it is never the single-object
             * case, and an APC arriving concurrently with a queue wake is an
             * interleaving the non-alertable cases cannot produce. */
            r = MsgWaitForMultipleObjectsEx( s->n_events, s->events, INFINITE,
                                             QS_ALLINPUT,
                                             MWMO_ALERTABLE | MWMO_INPUTAVAILABLE );
            if (r == WAIT_IO_COMPLETION) continue;
        }
        else r = MsgWaitForMultipleObjects( s->n_events, s->events, FALSE,
                                            INFINITE, QS_ALLINPUT );

        if (r == (DWORD)(WAIT_OBJECT_0 + s->n_events))
        {
            while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
            {
                if (msg.message == WM_QUIT) return 0;
                TranslateMessage( &msg );
                DispatchMessageW( &msg );
            }
        }
        else if (r < (DWORD)(WAIT_OBJECT_0 + s->n_events))
        {
            InterlockedIncrement( &s->evt_wakes );
        }
        else if (r == WAIT_FAILED)
        {
            printf( "  MsgWaitForMultipleObjects failed: %lu\n", GetLastError() );
            return 1;
        }
    }
    return 0;
}

static void CALLBACK apc_proc( ULONG_PTR param )
{
    struct scenario *s = (struct scenario *)param;
    InterlockedIncrement( &s->apcs );
}

/* Drives every wake source at once. A wake lost between two of them is the
 * interleaving being hunted, so they are deliberately not serialised. */
static DWORD WINAPI worker_thread( void *arg )
{
    struct scenario *s = arg;
    unsigned int tick = GetCurrentThreadId();   /* per-worker phase */

    while (!InterlockedCompareExchange( &s->stop, 0, 0 ))
    {
        if (s->n_events) SetEvent( s->events[tick % s->n_events] );
        PostMessageW( s->hwnd, WM_PROBE, 0, 0 );

        if (s->alertable)
        {
            switch (tick % 3)
            {
            case 0:
                if (s->pump_thread_h)
                    QueueUserAPC( apc_proc, s->pump_thread_h, (ULONG_PTR)s );
                break;
            case 1:
                /* Blocking, unlike the detector's SendMessageTimeout: this parks
                 * the sender until the pump replies, so it exercises the
                 * server's send/reply path rather than just posting. */
                SendMessageW( s->hwnd, WM_PROBE, 0, 0 );
                InterlockedIncrement( &s->sends );
                break;
            }
        }

        Sleep( tick & 1 );   /* alternate a bare yield with a 1ms sleep */
        tick++;
    }
    return 0;
}

/* Returns the number of stalls observed. */
static int run_case( int n_events, int alertable, int seconds )
{
    struct scenario s = { 0 };
    HANDLE pump, workers[WORKERS];
    DWORD_PTR res = 0;
    ULONGLONG start, last_ok;
    int i, probes = 0, stalls = 0;

    s.n_events  = n_events;
    s.alertable = alertable;
    printf( "--- %d event(s) + queue%s: %s\n", n_events,
            alertable ? ", alertable + APCs + blocking SendMessage" : "",
            n_events == 0 && !alertable
                ? "single-object wait (msync_wait_single/__ulock_wait2)"
                : "multi-object wait (mach semaphore + registration)" );

    for (i = 0; i < n_events; i++)
        s.events[i] = CreateEventW( NULL, FALSE, FALSE, NULL );   /* auto-reset */

    s.ready = CreateEventW( NULL, TRUE, FALSE, NULL );
    pump = CreateThread( NULL, 0, pump_thread, &s, 0, NULL );
    s.pump_thread_h = pump;
    WaitForSingleObject( s.ready, 5000 );
    if (!s.hwnd) { printf( "  setup failed\n" ); return 1; }

    for (i = 0; i < WORKERS; i++)
        workers[i] = CreateThread( NULL, 0, worker_thread, &s, 0, NULL );

    start = last_ok = GetTickCount64();
    while ((int)((GetTickCount64() - start) / 1000) < seconds && stalls < MAX_STALLS)
    {
        Sleep( PROBE_MS );
        probes++;
        if (SendMessageTimeoutW( s.hwnd, WM_NULL, 0, 0,
                                 SMTO_ABORTIFHUNG, ANSWER_MS, &res ))
        {
            last_ok = GetTickCount64();
            continue;
        }
        stalls++;
        printf( "  STALL at probe %d: SendMessageTimeout(WM_NULL) gave up (err %lu),"
                " pump unresponsive for %llu ms\n", probes, GetLastError(),
                (unsigned long long)(GetTickCount64() - last_ok) );
        fflush( stdout );
    }

    InterlockedExchange( &s.stop, 1 );
    for (i = 0; i < n_events; i++) SetEvent( s.events[i] );
    PostMessageW( s.hwnd, WM_PROBE, 0, 0 );

    /* The user-visible symptom: does WM_CLOSE actually close it? */
    PostMessageW( s.hwnd, WM_CLOSE, 0, 0 );
    if (WaitForSingleObject( pump, 5000 ) != WAIT_OBJECT_0)
    {
        printf( "  STALL: pump thread did not exit after WM_CLOSE\n" );
        stalls++;
    }
    for (i = 0; i < WORKERS; i++) WaitForSingleObject( workers[i], 2000 );

    printf( "  probes=%d stalls=%d dispatched=%ld evt_wakes=%ld apcs=%ld sends=%ld\n",
            probes, stalls, s.dispatched, s.evt_wakes, s.apcs, s.sends );

    for (i = 0; i < n_events; i++) CloseHandle( s.events[i] );
    CloseHandle( s.ready );
    CloseHandle( pump );
    for (i = 0; i < WORKERS; i++) CloseHandle( workers[i] );
    return stalls;
}

int main( int argc, char **argv )
{
    int seconds = argc > 1 ? atoi( argv[1] ) : 15;
    int stalls = 0;

    if (seconds <= 0) seconds = 15;
    printf( "=== msync msgloop hang test (%d s per case) ===\n", seconds );

    stalls += run_case( 0, 0, seconds );  /* the path the stuck Steam thread is on */
    stalls += run_case( 2, 0, seconds );
    stalls += run_case( 2, 1, seconds );  /* closest to CEF's actual pump */

    printf( "=== total stalls: %d ===\n", stalls );
    printf( "RESULT: %s\n", stalls ? "FAIL - message pump stalled" : "ok" );
    return stalls ? 1 : 0;
}

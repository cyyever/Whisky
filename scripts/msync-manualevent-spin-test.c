/*
 * msync manual-event busy-spin reproducer.
 *
 * The msync fast path (dlls/ntdll/unix/msync.c) has a wait_any/single inner loop
 * ("INNERSPIN") that must BLOCK each pass. For a level-triggered MANUAL event whose
 * shm signaled-state races the server's, check_shm_contention keeps returning
 * "signaled" so the loop re-polls without blocking -> 100% CPU on one core.
 *
 * This hammers a manual-reset event: one thread rapidly SetEvent()/ResetEvent()s it
 * (making the shm signaled-flag flap), while N waiter threads sit in
 * WaitForSingleObject(ev, INFINITE). Under a correct implementation the waiters
 * BLOCK when the event is reset (low CPU). If msync busy-spins on the flapping
 * signaled-flag, the process pegs the CPU.
 *
 * Compare: `WINEMSYNC=0` (wineserver sync, the "default"/old path) vs the msync
 * default. Same binary, same workload; only the sync backend differs.
 *
 * Prints wakeups and elapsed wall time; wrap with `/usr/bin/time` (or read the
 * harness) to see CPU seconds — a spin shows CPU >> wall on the waiter cores.
 */
#include <windows.h>
#include <stdio.h>

#define WAITERS 3
#define RUN_MS  4000

static HANDLE ev;
static volatile LONG stop;
static volatile LONG wakeups;

static DWORD WINAPI flapper(void *unused)
{
    (void)unused;
    while (!stop)
    {
        SetEvent(ev);
        ResetEvent(ev);
    }
    return 0;
}

static DWORD WINAPI waiter(void *unused)
{
    (void)unused;
    while (!stop)
    {
        /* Block until signaled. A correct backend parks the thread while reset;
         * a spinning fast path never parks. Short timeout so we can honour `stop`. */
        if (WaitForSingleObject(ev, 50) == WAIT_OBJECT_0)
            InterlockedIncrement(&wakeups);
    }
    return 0;
}

int main(void)
{
    HANDLE threads[WAITERS + 1];
    DWORD start, elapsed;
    int i;

    /* manual-reset (TRUE), initially non-signaled */
    ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!ev) { printf("CreateEvent failed\n"); return 1; }

    threads[0] = CreateThread(NULL, 0, flapper, NULL, 0, NULL);
    for (i = 0; i < WAITERS; i++)
        threads[i + 1] = CreateThread(NULL, 0, waiter, NULL, 0, NULL);

    start = GetTickCount();
    Sleep(RUN_MS);
    InterlockedExchange(&stop, 1);
    WaitForMultipleObjects(WAITERS + 1, threads, TRUE, INFINITE);
    elapsed = GetTickCount() - start;

    printf("manual-event: %d waiters, %lums wall, wakeups=%ld\n",
           WAITERS, (unsigned long)elapsed, (long)wakeups);
    return 0;
}

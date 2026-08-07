/*
 * msync close-during-wait regression probe.
 *
 * Investigates whether proton-wine patch 0016 (msync last-handle-close mutex
 * retention + client per-wait object snapshot) introduced a CORRECTNESS
 * regression for NON-mutex objects (events / semaphores).
 *
 * Scenario (the concern): thread A blocks in a wait on an event or semaphore;
 * another thread closes the LAST handle to that object while A is still
 * blocked. Under Windows / the wineserver oracle, a pending wait references the
 * object, so closing another handle does NOT free it and the wait keeps running
 * to its natural end (timeout, or a real signal). The worry is that under msync
 * (WINEMSYNC=1) the server destroys the object out from under A's private
 * snapshot, so A could wake spuriously, return a wrong status, hang, or crash.
 *
 * This PE exercises three object types (auto-reset event, manual-reset event,
 * semaphore). For each it starts a waiter thread that blocks with a finite
 * timeout, then the main thread sleeps briefly and CloseHandle()s the last
 * handle. It prints the waiter's result status and how long it actually blocked
 * (elapsed_ms), so the caller can diff WINEMSYNC=1 vs WINEMSYNC=0 for both the
 * STATUS (correctness) and the timing.
 *
 * An optional shm-churn thread (env MSYNC_CHURN=1) rapidly creates+closes many
 * events during the wait, to try to force the server to REUSE the freed shm
 * slot under A's live snapshot (the only theoretical divergence path) — if that
 * reuse ever steals a signal, the waiter would return WAIT_OBJECT_0 early.
 *
 * Build: like the other msync test PEs, mingw x86_64 (see the accompanying
 * scripts/run-msync-close-test.sh). Run inside a bottle once with msync on
 * (the default; WINEMSYNC unset) and once with WINEMSYNC=0, and compare.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WAIT_TIMEOUT_MS   3000u   /* waiter's finite timeout */
#define CLOSE_AFTER_MS     400u   /* main sleeps this long, then closes handle */

static const char *decode_wait(DWORD r)
{
    switch (r)
    {
    case WAIT_OBJECT_0:  return "WAIT_OBJECT_0";
    case WAIT_ABANDONED: return "WAIT_ABANDONED";
    case WAIT_TIMEOUT:   return "WAIT_TIMEOUT";
    case WAIT_FAILED:    return "WAIT_FAILED";
    default:             return "WAIT_OTHER";
    }
}

struct waiter_ctx {
    HANDLE  obj;
    DWORD   result;
    DWORD   elapsed_ms;
    DWORD   last_error;
};

static DWORD WINAPI waiter_thread(void *param)
{
    struct waiter_ctx *c = param;
    DWORD start = GetTickCount();
    SetLastError(0);
    c->result     = WaitForSingleObject(c->obj, WAIT_TIMEOUT_MS);
    c->last_error = GetLastError();
    c->elapsed_ms = GetTickCount() - start;
    return 0;
}

static volatile LONG churn_stop = 0;

static DWORD WINAPI churn_thread(void *param)
{
    (void)param;
    /* Rapidly create + close anonymous auto-reset events to churn the server's
     * shm_idx allocator, trying to force reuse of a just-freed slot. */
    while (!churn_stop)
    {
        HANDLE h = CreateEventA(NULL, FALSE, FALSE, NULL);
        if (h) CloseHandle(h);
    }
    return 0;
}

/* Run one close-during-wait trial on the given already-created object handle.
 * Takes ownership of `obj` (closes it). Returns the waiter result. */
static DWORD run_trial(const char *label, HANDLE obj, int churn)
{
    struct waiter_ctx c;
    HANDLE wt, ct = NULL;

    memset(&c, 0, sizeof(c));
    c.obj = obj;

    wt = CreateThread(NULL, 0, waiter_thread, &c, 0, NULL);
    if (!wt) { printf("RESULT %-8s ERROR could not start waiter\n", label); CloseHandle(obj); return WAIT_FAILED; }

    if (churn)
    {
        churn_stop = 0;
        ct = CreateThread(NULL, 0, churn_thread, NULL, 0, NULL);
    }

    /* Let the waiter get solidly blocked, then close the LAST handle. */
    Sleep(CLOSE_AFTER_MS);
    CloseHandle(obj);              /* <-- last handle closed while A waits */

    WaitForSingleObject(wt, INFINITE);
    CloseHandle(wt);

    if (ct)
    {
        InterlockedExchange(&churn_stop, 1);
        WaitForSingleObject(ct, INFINITE);
        CloseHandle(ct);
    }

    printf("RESULT %-8s %-14s 0x%08lx elapsed_ms=%4lu gle=%lu\n",
           label, decode_wait(c.result), (unsigned long)c.result,
           (unsigned long)c.elapsed_ms, (unsigned long)c.last_error);
    fflush(stdout);
    return c.result;
}

int main(int argc, char **argv)
{
    int iters = 1;
    int churn = 0;
    const char *env;

    if (argc > 1) iters = atoi(argv[1]);
    if (iters < 1) iters = 1;
    env = getenv("MSYNC_CHURN");
    if (env && env[0] == '1') churn = 1;

    printf("=== msync close-during-wait probe (iters=%d churn=%d timeout=%ums close@%ums) ===\n",
           iters, churn, WAIT_TIMEOUT_MS, CLOSE_AFTER_MS);
    fflush(stdout);

    for (int i = 0; i < iters; i++)
    {
        run_trial("auto",   CreateEventA(NULL, FALSE, FALSE, NULL), churn); /* auto-reset event  */
        run_trial("manual", CreateEventA(NULL, TRUE,  FALSE, NULL), churn); /* manual-reset event */
        run_trial("sema",   CreateSemaphoreA(NULL, 0, 4, NULL),     churn); /* semaphore, count 0 */
    }

    printf("=== done ===\n");
    fflush(stdout);
    return 0;
}

/*
 * msync-multi-wait-stress-test — regression test for three msync multi-wait bugs:
 *
 *   1. Mach semaphore pool count poisoning / spurious wakeup spin:
 *      When multiple objects in a WaitForMultipleObjects() set signal together
 *      or check_shm_contention() bails after server_register_wait(), the old
 *      mach_message_pump signaled the semaphore multiple times and the client
 *      returned it undrained to the global pool, leaving count > 0 so later
 *      waits spun at 100% CPU without blocking.
 *
 *   2. wineserver Mach port send-right leak:
 *      server/msync.c called semaphore_destroy(mach_task_self(), sem) on a
 *      remote client's semaphore (always failing with KERN_INVALID_ARGUMENT)
 *      and never called mach_port_deallocate() in remove_sem(). Every client
 *      process / semaphore that ever entered msync_wait_multiple() leaked a
 *      send-right / dead-name Mach port in wineserver permanently.
 *      Pass `--port-churn` from the runner script across N short invocations
 *      while measuring `wineserver`'s Mach port count before and after.
 *
 *   3. Manual-reset event flapping regression:
 *      With manual-reset events handled natively by msync, flapping a
 *      manual-reset event with multiple waiters in
 *      WaitForMultipleObjects({manual, auto}) must not busy-spin once reset,
 *      must wake promptly when signaled, and must consume negligible CPU while
 *      parked.
 *
 *   4. Destroyed handle wake in WaitForMultipleObjects:
 *      Closing one handle in a multi-object wait while another signals must
 *      wake cleanly without hanging or leaking ports.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o msync-multi-wait-stress-test.exe \
 *       tests/msync-multi-wait-stress-test.c
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        fflush(stdout); \
        failures++; \
    } else { \
        printf("PASS: " fmt "\n", ##__VA_ARGS__); \
        fflush(stdout); \
    } \
} while (0)

static ULONGLONG process_cpu_ms(void)
{
    FILETIME create_t, exit_t, kernel_t, user_t;
    ULARGE_INTEGER k, u;
    if (!GetProcessTimes(GetCurrentProcess(), &create_t, &exit_t, &kernel_t, &user_t))
        return 0;
    k.LowPart = kernel_t.dwLowDateTime;
    k.HighPart = kernel_t.dwHighDateTime;
    u.LowPart = user_t.dwLowDateTime;
    u.HighPart = user_t.dwHighDateTime;
    return (k.QuadPart + u.QuadPart) / 10000ULL;
}

/* ---- Case 1: multi-signal burst followed by quiet multi-wait ---- */

struct burst_ctx {
    HANDLE ev[4];
    volatile LONG stop;
    volatile LONG wakes;
};

static DWORD WINAPI burst_waiter(void *arg)
{
    struct burst_ctx *ctx = (struct burst_ctx *)arg;
    while (!InterlockedCompareExchange(&ctx->stop, 0, 0))
    {
        DWORD r = WaitForMultipleObjects(4, ctx->ev, FALSE, 20);
        if (r < WAIT_OBJECT_0 + 4)
            InterlockedIncrement(&ctx->wakes);
    }
    return 0;
}

static DWORD WINAPI quiet_waiter(void *arg)
{
    HANDLE *ev = (HANDLE *)arg;
    DWORD r = WaitForMultipleObjects(4, ev, FALSE, 600);
    return r;
}

static void test_semaphore_poisoning_and_spin(void)
{
    struct burst_ctx ctx;
    HANDLE threads[4];
    ULONGLONG cpu0, cpu1, t0, elapsed;
    int i, iter;
    DWORD r;

    printf("--- case 1: multi-signal burst + quiet multi-wait (semaphore poisoning) ---\n");
    memset(&ctx, 0, sizeof(ctx));
    for (i = 0; i < 4; i++)
        ctx.ev[i] = CreateEventW(NULL, FALSE, FALSE, NULL);

    for (i = 0; i < 4; i++)
        threads[i] = CreateThread(NULL, 0, burst_waiter, &ctx, 0, NULL);

    /* Hammer all 4 events together so mach_message_pump sees multiple ready
     * objects per registration and check_shm_contention bails frequently. */
    for (iter = 0; iter < 600; iter++)
    {
        for (i = 0; i < 4; i++) SetEvent(ctx.ev[i]);
        if ((iter & 31) == 0) Sleep(1);
    }

    InterlockedExchange(&ctx.stop, 1);
    for (i = 0; i < 4; i++) SetEvent(ctx.ev[i]);
    WaitForMultipleObjects(4, threads, TRUE, 5000);
    for (i = 0; i < 4; i++) CloseHandle(threads[i]);

    /* Drain all 4 events so none are signaled. */
    for (i = 0; i < 4; i++) ResetEvent(ctx.ev[i]);

    /* Now block 4 threads in a quiet 600ms multi-wait. Poisoned semaphores
     * cause spurious immediate wakeups / spin loops and elevated CPU time. */
    cpu0 = process_cpu_ms();
    t0 = GetTickCount64();
    for (i = 0; i < 4; i++)
        threads[i] = CreateThread(NULL, 0, quiet_waiter, ctx.ev, 0, NULL);
    r = WaitForMultipleObjects(4, threads, TRUE, 5000);
    elapsed = GetTickCount64() - t0;
    cpu1 = process_cpu_ms();

    CHECK(r == WAIT_OBJECT_0, "1a: quiet multi-wait threads joined cleanly (r=0x%lx)", (unsigned long)r);
    for (i = 0; i < 4; i++)
    {
        DWORD ec = 0;
        GetExitCodeThread(threads[i], &ec);
        CloseHandle(threads[i]);
        if (ec != WAIT_TIMEOUT)
        {
            printf("FAIL: 1b: quiet waiter %d returned 0x%lx instead of WAIT_TIMEOUT\n", i, (unsigned long)ec);
            failures++;
        }
    }
    CHECK(elapsed >= 520 && elapsed < 2000,
          "1c: quiet 600ms multi-wait elapsed=%llu ms (wakes during burst=%ld)",
          (unsigned long long)elapsed, (long)ctx.wakes);
    CHECK((cpu1 - cpu0) < 120,
          "1d: quiet 4-thread multi-wait CPU=%llu ms (< 120ms; spin would be >500ms)",
          (unsigned long long)(cpu1 - cpu0));

    for (i = 0; i < 4; i++) CloseHandle(ctx.ev[i]);
}

/* ---- Case 2: flapping manual-reset event in WaitForMultipleObjects ---- */

struct manual_ctx {
    HANDLE handles[2]; /* [0]=manual-reset, [1]=auto-reset */
    volatile LONG stop;
    volatile LONG flapping;
    volatile LONG wakes;
};

static DWORD WINAPI manual_waiter(void *arg)
{
    struct manual_ctx *ctx = (struct manual_ctx *)arg;
    while (!InterlockedCompareExchange(&ctx->stop, 0, 0))
    {
        DWORD r = WaitForMultipleObjects(2, ctx->handles, FALSE, 250);
        if (r == WAIT_OBJECT_0)
            InterlockedIncrement(&ctx->wakes);
        else if (r == WAIT_OBJECT_0 + 1)
            break;
    }
    return 0;
}

static void test_manual_event_flap_and_idle(void)
{
    struct manual_ctx ctx;
    HANDLE threads[4];
    ULONGLONG cpu0, cpu1, t0, elapsed;
    int i;

    printf("--- case 2: manual-reset event flap + idle multi-wait ---\n");
    memset(&ctx, 0, sizeof(ctx));
    ctx.handles[0] = CreateEventW(NULL, TRUE, FALSE, NULL);  /* manual-reset */
    ctx.handles[1] = CreateEventW(NULL, FALSE, FALSE, NULL); /* auto-reset */

    for (i = 0; i < 4; i++)
        threads[i] = CreateThread(NULL, 0, manual_waiter, &ctx, 0, NULL);

    /* Flap manual-reset event rapidly for 200ms */
    t0 = GetTickCount64();
    while (GetTickCount64() - t0 < 200)
    {
        SetEvent(ctx.handles[0]);
        ResetEvent(ctx.handles[0]);
    }
    ResetEvent(ctx.handles[0]);
    Sleep(30); /* let waiters settle into blocked state */

    /* Measure CPU during 800ms of complete silence (event reset). */
    cpu0 = process_cpu_ms();
    Sleep(800);
    cpu1 = process_cpu_ms();

    /* Wake all 4 waiters promptly via manual-reset event and stop them. */
    InterlockedExchange(&ctx.stop, 1);
    t0 = GetTickCount64();
    SetEvent(ctx.handles[0]);
    WaitForMultipleObjects(4, threads, TRUE, 3000);
    elapsed = GetTickCount64() - t0;

    for (i = 0; i < 4; i++) CloseHandle(threads[i]);

    CHECK(elapsed < 500,
          "2a: 4 waiters woke promptly on manual-reset SetEvent (%llu ms, flap wakes=%ld)",
          (unsigned long long)elapsed, (long)ctx.wakes);
    CHECK((cpu1 - cpu0) < 120,
          "2b: 4 idle manual+auto multi-waiters over 800ms used CPU=%llu ms (< 120ms)",
          (unsigned long long)(cpu1 - cpu0));

    CloseHandle(ctx.handles[0]);
    CloseHandle(ctx.handles[1]);
}

/* ---- Case 3: close one handle during WaitForMultipleObjects while another signals ---- */

struct close_ctx {
    HANDLE ev[2];
};

static DWORD WINAPI close_signaler(void *arg)
{
    struct close_ctx *ctx = (struct close_ctx *)arg;
    Sleep(60);
    CloseHandle(ctx->ev[0]);
    Sleep(30);
    SetEvent(ctx->ev[1]);
    return 0;
}

static void test_close_during_multi_wait(void)
{
    struct close_ctx ctx;
    HANDLE th;
    ULONGLONG t0, elapsed;
    DWORD r;

    printf("--- case 3: close one handle during multi-wait ---\n");
    ctx.ev[0] = CreateEventW(NULL, FALSE, FALSE, NULL);
    ctx.ev[1] = CreateEventW(NULL, FALSE, FALSE, NULL);

    t0 = GetTickCount64();
    th = CreateThread(NULL, 0, close_signaler, &ctx, 0, NULL);
    r = WaitForMultipleObjects(2, ctx.ev, FALSE, 2000);
    elapsed = GetTickCount64() - t0;
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    CloseHandle(ctx.ev[1]);

    CHECK(r == WAIT_OBJECT_0 + 1 && elapsed < 1000,
          "3a: multi-wait survived handle close and woke on ev[1] (r=0x%lx, %llu ms)",
          (unsigned long)r, (unsigned long long)elapsed);
}

/* ---- Port-churn mode: exercise msync_wait_multiple across many short-lived threads ---- */

static DWORD WINAPI churn_worker(void *arg)
{
    HANDLE *ev = (HANDLE *)arg;
    WaitForMultipleObjects(2, ev, FALSE, 1);
    return 0;
}

static int run_block_named(const char *n0, const char *n1)
{
    HANDLE ev[2];
    ev[0] = OpenEventA(SYNCHRONIZE, FALSE, n0);
    ev[1] = OpenEventA(SYNCHRONIZE, FALSE, n1);
    if (!ev[0] || !ev[1]) return 2;
    /* Block indefinitely in msync_wait_multiple until TerminateProcess kills us. */
    WaitForMultipleObjects(2, ev, FALSE, INFINITE);
    return 0;
}

static int run_port_churn(const char *self_path, int count)
{
    HANDLE ev[2];
    char n0[64], n1[64], cmd[1024];
    int i;

    snprintf(n0, sizeof(n0), "Local\\WhiskyMsyncChurn0_%lu", (unsigned long)GetCurrentProcessId());
    snprintf(n1, sizeof(n1), "Local\\WhiskyMsyncChurn1_%lu", (unsigned long)GetCurrentProcessId());
    ev[0] = CreateEventA(NULL, TRUE, FALSE, n0);
    ev[1] = CreateEventA(NULL, TRUE, FALSE, n1);

    /* 1) Normal thread multi-wait churn */
    for (i = 0; i < count; i++)
    {
        HANDLE th = CreateThread(NULL, 0, churn_worker, ev, 0, NULL);
        if (th)
        {
            WaitForSingleObject(th, INFINITE);
            CloseHandle(th);
        }
    }

    /* 2) Abrupt TerminateProcess while blocked in msync_wait_multiple on long-lived
     *    named events: verifies wineserver reclaims the dead thread's Mach semaphore
     *    send right via msync_cleanup_thread() even without server_remove_wait(). */
    snprintf(cmd, sizeof(cmd), "\"%s\" --block-named %s %s", self_path, n0, n1);
    for (i = 0; i < 4; i++)
    {
        STARTUPINFOA si;
        PROCESS_INFORMATION pi;
        memset(&si, 0, sizeof(si));
        si.cb = sizeof(si);
        memset(&pi, 0, sizeof(pi));
        if (CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
        {
            Sleep(40);
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 3000);
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
        }
    }

    CloseHandle(ev[0]);
    CloseHandle(ev[1]);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 3 && strcmp(argv[1], "--block-named") == 0)
        return run_block_named(argv[2], argv[3]);

    if (argc > 1 && strcmp(argv[1], "--port-churn") == 0)
    {
        int n = (argc > 2) ? atoi(argv[2]) : 20;
        return run_port_churn(argv[0], n);
    }

    printf("=== msync multi-wait stress test ===\n");
    test_semaphore_poisoning_and_spin();
    test_manual_event_flap_and_idle();
    test_close_during_multi_wait();

    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

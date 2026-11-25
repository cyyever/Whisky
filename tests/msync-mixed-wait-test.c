/*
 * msync-mixed-wait-test — verify WaitForMultipleObjects on a mix of msync and
 * server-side handles under WINEMSYNC=1.
 *
 * Covers:
 *   1. RE2 idle-worker shape: [msync semaphore, manual-reset event (server
 *      under default WINEMSYNC_NO_MANUALEVENT=1)]:
 *        - signaling the msync handle while waiting wakes promptly
 *        - signaling the server handle while waiting wakes promptly
 *        - timeout=0 poll sees a signaled server handle (not skipped!)
 *        - timeout=0 poll returns WAIT_TIMEOUT when neither is signaled
 *        - finite timeout expires cleanly
 *        - legitimate >5s INFINITE wait wakes cleanly on signal without
 *          lost wakeup or bogus "mixed wait looping >5s" ERR spam
 *   2. Always-server handle shape: [msync auto-reset event, overlapped named
 *      pipe with ov.hEvent == NULL] (exercises msync_wait_mixed_any even if
 *      WINEMSYNC_NO_MANUALEVENT=0):
 *        - signaling the msync event while pipe connect is pending
 *        - completing the pipe connect while waiting
 *        - timeout=0 poll sees the signaled pipe
 *        - WaitAll (msync_wait_mixed_all) succeeds when both are signaled
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o msync-mixed-wait-test.exe \
 *       tests/msync-mixed-wait-test.c
 *
 * Run:
 *   WINEMSYNC=1 wine64 msync-mixed-wait-test.exe [long_wait_ms]
 *   WINEMSYNC=0 wine64 msync-mixed-wait-test.exe [long_wait_ms]
 *
 * Default long_wait_ms is 5500 (past the old 5s diagnostic threshold).
 * Check that stderr under WINEMSYNC=1 contains no "mixed wait looping >5s".
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        fflush(stdout); \
        failures++; \
    } \
} while (0)

struct delayed_signal {
    HANDLE target;
    DWORD  delay_ms;
    int    is_semaphore;
};

static DWORD WINAPI signaler_thread(void *arg)
{
    struct delayed_signal *s = (struct delayed_signal *)arg;
    Sleep(s->delay_ms);
    if (s->is_semaphore)
        ReleaseSemaphore(s->target, 1, NULL);
    else
        SetEvent(s->target);
    return 0;
}

struct pipe_connector {
    WCHAR name[128];
    DWORD delay_ms;
    HANDLE client;
};

static DWORD WINAPI pipe_connect_thread(void *arg)
{
    struct pipe_connector *c = (struct pipe_connector *)arg;
    Sleep(c->delay_ms);
    c->client = CreateFileW(c->name, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                            OPEN_EXISTING, 0, NULL);
    return 0;
}

static void test_semaphore_and_manual_event(DWORD long_wait_ms)
{
    HANDLE sem = CreateSemaphoreW(NULL, 0, 10, NULL);
    HANDLE ev  = CreateEventW(NULL, TRUE, FALSE, NULL);
    HANDLE handles[2] = { sem, ev };
    HANDLE th;
    struct delayed_signal ds;
    ULONGLONG t0, elapsed;
    DWORD r;

    printf("--- case 1: [semaphore, manual-reset event] ---\n");
    CHECK(sem != NULL && ev != NULL, "create handles failed (gle=%lu)", GetLastError());
    if (!sem || !ev) return;

    /* 1a. Timeout=0 when neither is signaled */
    r = WaitForMultipleObjects(2, handles, FALSE, 0);
    CHECK(r == WAIT_TIMEOUT, "1a: expected WAIT_TIMEOUT, got 0x%lx", (unsigned long)r);

    /* 1b. Timeout=0 when server handle (manual event) IS signaled */
    SetEvent(ev);
    r = WaitForMultipleObjects(2, handles, FALSE, 0);
    CHECK(r == WAIT_OBJECT_0 + 1, "1b: timeout=0 missed signaled server handle (got 0x%lx)",
          (unsigned long)r);
    ResetEvent(ev);

    /* 1c. Signal msync semaphore while waiting */
    ds.target = sem;
    ds.delay_ms = 80;
    ds.is_semaphore = 1;
    t0 = GetTickCount64();
    th = CreateThread(NULL, 0, signaler_thread, &ds, 0, NULL);
    r = WaitForMultipleObjects(2, handles, FALSE, 3000);
    elapsed = GetTickCount64() - t0;
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    CHECK(r == WAIT_OBJECT_0 + 0, "1c: expected WAIT_OBJECT_0+0, got 0x%lx", (unsigned long)r);
    CHECK(elapsed < 1000, "1c: msync wakeup too slow (%llu ms)", (unsigned long long)elapsed);
    printf("  1c msync semaphore wake: %llu ms\n", (unsigned long long)elapsed);

    /* 1d. Signal server manual-reset event while waiting */
    ds.target = ev;
    ds.delay_ms = 80;
    ds.is_semaphore = 0;
    t0 = GetTickCount64();
    th = CreateThread(NULL, 0, signaler_thread, &ds, 0, NULL);
    r = WaitForMultipleObjects(2, handles, FALSE, 3000);
    elapsed = GetTickCount64() - t0;
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    CHECK(r == WAIT_OBJECT_0 + 1, "1d: expected WAIT_OBJECT_0+1, got 0x%lx", (unsigned long)r);
    CHECK(elapsed < 1000, "1d: server wakeup too slow (%llu ms)", (unsigned long long)elapsed);
    ResetEvent(ev);
    printf("  1d manual event wake: %llu ms\n", (unsigned long long)elapsed);

    /* 1e. Finite timeout expires cleanly */
    t0 = GetTickCount64();
    r = WaitForMultipleObjects(2, handles, FALSE, 120);
    elapsed = GetTickCount64() - t0;
    CHECK(r == WAIT_TIMEOUT, "1e: expected WAIT_TIMEOUT, got 0x%lx", (unsigned long)r);
    CHECK(elapsed >= 80 && elapsed < 1000, "1e: bad timeout elapsed %llu ms",
          (unsigned long long)elapsed);
    printf("  1e finite timeout (120ms): %llu ms\n", (unsigned long long)elapsed);

    /* 1f. Long INFINITE wait (>5s by default), then signal msync semaphore */
    ds.target = sem;
    ds.delay_ms = long_wait_ms;
    ds.is_semaphore = 1;
    t0 = GetTickCount64();
    th = CreateThread(NULL, 0, signaler_thread, &ds, 0, NULL);
    r = WaitForMultipleObjects(2, handles, FALSE, INFINITE);
    elapsed = GetTickCount64() - t0;
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    CHECK(r == WAIT_OBJECT_0 + 0, "1f: expected WAIT_OBJECT_0+0 after long wait, got 0x%lx",
          (unsigned long)r);
    CHECK(elapsed >= long_wait_ms - 100 && elapsed < long_wait_ms + 1500,
          "1f: unexpected long-wait elapsed %llu ms (target %lu ms)",
          (unsigned long long)elapsed, (unsigned long)long_wait_ms);
    printf("  1f long INFINITE wait (%lums): woke in %llu ms\n",
           (unsigned long)long_wait_ms, (unsigned long long)elapsed);

    CloseHandle(sem);
    CloseHandle(ev);
}

static void test_auto_event_and_named_pipe(void)
{
    WCHAR pipe_name[128];
    HANDLE ev, pipe, th;
    OVERLAPPED ov;
    HANDLE handles[2];
    struct delayed_signal ds;
    struct pipe_connector pc;
    ULONGLONG t0, elapsed;
    DWORD r, gle;
    BOOL ok;

    printf("--- case 2: [auto-reset event, overlapped named pipe] ---\n");
    swprintf(pipe_name, 128, L"\\\\.\\pipe\\msync-mixed-wait-test-%lu", GetCurrentProcessId());

    ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    pipe = CreateNamedPipeW(pipe_name,
                            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                            PIPE_TYPE_BYTE | PIPE_WAIT,
                            1, 1024, 1024, 0, NULL);
    CHECK(ev != NULL && pipe != INVALID_HANDLE_VALUE,
          "create event/pipe failed (gle=%lu)", GetLastError());
    if (!ev || pipe == INVALID_HANDLE_VALUE) return;

    handles[0] = ev;
    handles[1] = pipe;

    /* Start pending overlapped ConnectNamedPipe with ov.hEvent == NULL so the
     * pipe handle itself is unsignaled until a client connects. */
    memset(&ov, 0, sizeof(ov));
    ok = ConnectNamedPipe(pipe, &ov);
    gle = GetLastError();
    CHECK(!ok && gle == ERROR_IO_PENDING,
          "2a: ConnectNamedPipe expected ERROR_IO_PENDING, got ok=%d gle=%lu", ok, gle);

    /* 2a. Timeout=0 while neither is signaled */
    r = WaitForMultipleObjects(2, handles, FALSE, 0);
    CHECK(r == WAIT_TIMEOUT, "2a: expected WAIT_TIMEOUT, got 0x%lx", (unsigned long)r);

    /* 2b. Signal msync auto-reset event while pipe connect is pending */
    ds.target = ev;
    ds.delay_ms = 80;
    ds.is_semaphore = 0;
    t0 = GetTickCount64();
    th = CreateThread(NULL, 0, signaler_thread, &ds, 0, NULL);
    r = WaitForMultipleObjects(2, handles, FALSE, 3000);
    elapsed = GetTickCount64() - t0;
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    CHECK(r == WAIT_OBJECT_0 + 0, "2b: expected WAIT_OBJECT_0+0, got 0x%lx", (unsigned long)r);
    CHECK(elapsed < 1000, "2b: msync event wakeup too slow (%llu ms)", (unsigned long long)elapsed);
    printf("  2b msync auto-event wake: %llu ms\n", (unsigned long long)elapsed);

    /* 2c. Connect pipe client while waiting on [auto_event, pipe] */
    memset(&pc, 0, sizeof(pc));
    wcscpy(pc.name, pipe_name);
    pc.delay_ms = 80;
    pc.client = INVALID_HANDLE_VALUE;
    t0 = GetTickCount64();
    th = CreateThread(NULL, 0, pipe_connect_thread, &pc, 0, NULL);
    r = WaitForMultipleObjects(2, handles, FALSE, 3000);
    elapsed = GetTickCount64() - t0;
    WaitForSingleObject(th, INFINITE);
    CloseHandle(th);
    CHECK(pc.client != INVALID_HANDLE_VALUE, "2c: client CreateFileW failed");
    CHECK(r == WAIT_OBJECT_0 + 1, "2c: expected WAIT_OBJECT_0+1 (pipe), got 0x%lx",
          (unsigned long)r);
    CHECK(elapsed < 1000, "2c: pipe wakeup too slow (%llu ms)", (unsigned long long)elapsed);
    printf("  2c server pipe wake: %llu ms\n", (unsigned long long)elapsed);

    /* 2d. Timeout=0 when pipe IS signaled and msync event is unsignaled */
    r = WaitForMultipleObjects(2, handles, FALSE, 0);
    CHECK(r == WAIT_OBJECT_0 + 1, "2d: timeout=0 missed signaled pipe (got 0x%lx)",
          (unsigned long)r);

    /* 2e. WaitAll (msync_wait_mixed_all) when both are signaled */
    SetEvent(ev);
    r = WaitForMultipleObjects(2, handles, TRUE, 1000);
    CHECK(r == WAIT_OBJECT_0, "2e: WaitAll expected WAIT_OBJECT_0, got 0x%lx", (unsigned long)r);

    if (pc.client != INVALID_HANDLE_VALUE) CloseHandle(pc.client);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    CloseHandle(ev);
}

int main(int argc, char **argv)
{
    DWORD long_wait_ms = (argc > 1) ? (DWORD)strtoul(argv[1], NULL, 10) : 5500;
    if (long_wait_ms < 200) long_wait_ms = 200;

    printf("=== msync mixed-wait test (long_wait_ms=%lu) ===\n", (unsigned long)long_wait_ms);
    test_semaphore_and_manual_event(long_wait_ms);
    test_auto_event_and_named_pipe();

    printf("=== failures: %d ===\n", failures);
    printf("RESULT: %s\n", failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
}

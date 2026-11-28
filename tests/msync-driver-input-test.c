/*
 * Regression test for macOS msync (Wine 10 inproc_sync backend):
 *   1. QS_DRIVER / winemac.drv queue->fd must NOT be disarmed after a
 *      non-driver wakeup from MsgWaitForMultipleObjectsEx() or cross-thread
 *      SendMessage(), so a subsequent PeekMessageW() game loop still receives
 *      macOS driver events (window minimize/restore, keyboard, mouse).
 *   2. CancelWaitableTimer() on a queued user APC must clear alert_sync so
 *      subsequent alertable waits do not spin returning WAIT_IO_COMPLETION.
 *   3. Server event lookups (RegNotifyChangeKeyValue) must reject mutex and
 *      semaphore handles without corrupting their state.
 *   4. Far-future relative NtWaitForSingleObject timeouts must not overflow
 *      into immediate STATUS_TIMEOUT.
 *   5. High-churn concurrent handle create/wait/close across pipes, events,
 *      mutexes, and semaphores must not race on the client handle cache.
 *
 * Compile:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o msync-driver-input-test.exe \
 *       tests/msync-driver-input-test.c -luser32 -ladvapi32 -lntdll
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <stdlib.h>

static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        failures++; \
    } else { \
        printf("PASS: " fmt "\n", ##__VA_ARGS__); \
    } \
} while (0)

/* ---- Test 1: QS_DRIVER / queue->fd survival across MsgWait + SendMessage ---- */
static volatile int got_size_minimized = 0;
static volatile int got_size_restored = 0;
static volatile int got_user_ping = 0;

static LRESULT CALLBACK driver_wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_SIZE) {
        if (wp == SIZE_MINIMIZED) got_size_minimized = 1;
        else if (wp == SIZE_RESTORED) got_size_restored = 1;
    } else if (msg == WM_USER + 42) {
        got_user_ping = 1;
        return 0x1234;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static DWORD WINAPI ping_thread(void *arg)
{
    HWND hwnd = (HWND)arg;
    Sleep(20);
    SendMessageW(hwnd, WM_USER + 42, 0, 0);
    return 0;
}

static void pump_peek_only(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    while ((LONG)(end - GetTickCount()) > 0) {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

static void test_qs_driver_after_msgwait(void)
{
    WNDCLASSW wc = {0};
    HWND hwnd;
    HANDLE ev, thr;
    DWORD r;

    wc.lpfnWndProc = driver_wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"WhiskyMsyncDriverTest";
    CHECK(RegisterClassW(&wc) != 0, "RegisterClassW");

    hwnd = CreateWindowExW(0, wc.lpszClassName, L"MsyncDriverTest",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                           120, 120, 320, 240, NULL, NULL, wc.hInstance, NULL);
    CHECK(hwnd != NULL, "CreateWindowExW");
    if (!hwnd) return;

    ShowWindow(hwnd, SW_SHOW);
    pump_peek_only(150);

    /* 1a. Non-driver wakeup from MsgWaitForMultipleObjectsEx (event signaled). */
    ev = CreateEventW(NULL, TRUE, TRUE, NULL);
    r = MsgWaitForMultipleObjectsEx(1, &ev, 50, QS_ALLINPUT, 0);
    CHECK(r == WAIT_OBJECT_0, "MsgWaitForMultipleObjectsEx woke on event (r=%lu)", r);
    CloseHandle(ev);

    /* 1b. Cross-thread SendMessage wakeup while waiting. */
    thr = CreateThread(NULL, 0, ping_thread, hwnd, 0, NULL);
    r = MsgWaitForMultipleObjectsEx(0, NULL, 500, QS_ALLINPUT, 0);
    pump_peek_only(50);
    WaitForSingleObject(thr, 3000);
    CloseHandle(thr);
    CHECK(got_user_ping == 1, "cross-thread SendMessage delivered (msgwait r=%lu)", r);

    /* 1c. Now stay strictly in a game-style PeekMessage-only loop and verify
     *     macOS driver events (minimize -> restore via Cocoa/queue->fd) still arrive. */
    got_size_minimized = 0;
    got_size_restored = 0;
    ShowWindow(hwnd, SW_MINIMIZE);
    pump_peek_only(300);
    ShowWindow(hwnd, SW_RESTORE);
    pump_peek_only(300);
    CHECK(got_size_minimized && got_size_restored,
          "PeekMessage-only loop still receives driver events after MsgWait (min=%d rest=%d)",
          got_size_minimized, got_size_restored);

    DestroyWindow(hwnd);
}

/* ---- Test 2: CancelWaitableTimer must clear alert_sync (no APC spin) ---- */
static volatile int apc_ran = 0;
static void CALLBACK timer_apc(void *arg, DWORD lo, DWORD hi)
{
    (void)arg; (void)lo; (void)hi;
    apc_ran++;
}

static void test_cancel_timer_apc(void)
{
    HANDLE timer = CreateWaitableTimerW(NULL, TRUE, NULL);
    HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    LARGE_INTEGER due;
    DWORD t0, dt, r;

    due.QuadPart = -10000LL; /* 1 ms */
    apc_ran = 0;
    CHECK(SetWaitableTimer(timer, &due, 0, timer_apc, NULL, FALSE), "SetWaitableTimer(1ms, apc)");
    Sleep(40); /* timer expires -> server queues APC_USER & signals alert_sync */
    CHECK(CancelWaitableTimer(timer), "CancelWaitableTimer before alertable wait");

    t0 = GetTickCount();
    r = WaitForSingleObjectEx(ev, 80, TRUE);
    dt = GetTickCount() - t0;
    CHECK(r == WAIT_TIMEOUT && dt >= 50 && apc_ran == 0,
          "alertable wait after CancelWaitableTimer timed out cleanly (r=%lu dt=%lums apc=%d)",
          r, dt, apc_ran);

    CloseHandle(timer);
    CloseHandle(ev);
}

/* ---- Test 3: Server event lookup must reject mutex/semaphore handles ---- */
static void test_server_event_type_isolation(void)
{
    HANDLE mtx = CreateMutexW(NULL, TRUE, NULL);
    HANDLE sem = CreateSemaphoreW(NULL, 0, 5, NULL);
    HKEY hkey = NULL;
    LONG err;

    err = RegOpenKeyExW(HKEY_CURRENT_USER, L"Software", 0, KEY_NOTIFY, &hkey);
    CHECK(err == ERROR_SUCCESS, "RegOpenKeyExW(HKCU\\Software, KEY_NOTIFY) err=%ld", err);
    if (err == ERROR_SUCCESS) {
        LONG r_mtx = RegNotifyChangeKeyValue(hkey, FALSE, REG_NOTIFY_CHANGE_NAME, mtx, TRUE);
        LONG r_sem = RegNotifyChangeKeyValue(hkey, FALSE, REG_NOTIFY_CHANGE_NAME, sem, TRUE);
        CHECK(r_mtx != ERROR_SUCCESS, "RegNotifyChangeKeyValue rejected mutex handle (err=%ld)", r_mtx);
        CHECK(r_sem != ERROR_SUCCESS, "RegNotifyChangeKeyValue rejected semaphore handle (err=%ld)", r_sem);
        RegCloseKey(hkey);
    }

    /* Mutex must still be owned by us and cleanly releasable. */
    CHECK(ReleaseMutex(mtx) != 0, "mutex ownership intact after rejected RegNotifyChangeKeyValue");
    CloseHandle(mtx);
    CloseHandle(sem);
}

/* ---- Test 4: Far-future relative timeout must not overflow ---- */
static DWORD WINAPI signal_delayed(void *arg)
{
    Sleep(60);
    SetEvent((HANDLE)arg);
    return 0;
}

static void test_far_future_timeout(void)
{
    HANDLE ev = CreateEventW(NULL, TRUE, FALSE, NULL);
    HANDLE thr = CreateThread(NULL, 0, signal_delayed, ev, 0, NULL);
    LARGE_INTEGER huge_rel;
    NTSTATUS st;

    /* ~18.4 million seconds (~213 days * 10000 -> overflows *100 in 64-bit ns if unclamped) */
    huge_rel.QuadPart = -(1LL << 60);
    st = NtWaitForSingleObject(ev, FALSE, &huge_rel);
    CHECK(st == 0 /* STATUS_SUCCESS */, "NtWaitForSingleObject with -(1<<60) timeout waited for signal (st=0x%08lx)",
          (unsigned long)st);

    WaitForSingleObject(thr, 3000);
    CloseHandle(thr);
    CloseHandle(ev);
}

/* ---- Test 5: Concurrent handle churn across pipes, events, mutexes, semaphores ---- */
static volatile LONG churn_errors = 0;

static DWORD WINAPI churn_worker(void *arg)
{
    int id = (int)(INT_PTR)arg;
    for (int i = 0; i < 400; i++) {
        HANDLE h1 = CreateEventW(NULL, (i & 1) != 0, FALSE, NULL);
        HANDLE h2 = CreateMutexW(NULL, TRUE, NULL);
        HANDLE h3 = CreateSemaphoreW(NULL, 1, 4, NULL);
        HANDLE rp = NULL, wp = NULL;

        if (!h1 || !h2 || !h3 || !CreatePipe(&rp, &wp, NULL, 64)) {
            InterlockedIncrement(&churn_errors);
            break;
        }
        if (!SetEvent(h1) || WaitForSingleObject(h1, 500) != WAIT_OBJECT_0)
            InterlockedIncrement(&churn_errors);
        if (!ReleaseMutex(h2))
            InterlockedIncrement(&churn_errors);
        if (WaitForSingleObject(h3, 500) != WAIT_OBJECT_0 || !ReleaseSemaphore(h3, 1, NULL))
            InterlockedIncrement(&churn_errors);
        if (WaitForSingleObject(h2, 500) != WAIT_OBJECT_0 || !ReleaseMutex(h2))
            InterlockedIncrement(&churn_errors);

        /* Close in rotated order to maximize cross-type handle number reuse */
        if ((i + id) & 1) {
            CloseHandle(rp); CloseHandle(wp); CloseHandle(h2); CloseHandle(h3); CloseHandle(h1);
        } else {
            CloseHandle(h1); CloseHandle(h3); CloseHandle(rp); CloseHandle(h2); CloseHandle(wp);
        }
    }
    return 0;
}

static void test_concurrent_handle_churn(void)
{
    HANDLE thrs[6];
    churn_errors = 0;
    for (int i = 0; i < 6; i++)
        thrs[i] = CreateThread(NULL, 0, churn_worker, (void *)(INT_PTR)i, 0, NULL);
    WaitForMultipleObjects(6, thrs, TRUE, 30000);
    for (int i = 0; i < 6; i++) CloseHandle(thrs[i]);
    CHECK(churn_errors == 0, "6x400 concurrent cross-type handle churn (errors=%ld)", churn_errors);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    test_qs_driver_after_msgwait();
    test_cancel_timer_apc();
    test_server_event_type_isolation();
    test_far_future_timeout();
    test_concurrent_handle_churn();
    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

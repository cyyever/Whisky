/*
 * Regression test for macOS scheduler/timer/kqueue optimizations:
 *   1. NtDelayExecution / Sleep(1, 5, 10) precision via mach_wait_until()
 *      (and Sleep(0) yield non-blocking behavior).
 *   2. SetThreadPriority -> macOS pthread QoS mapping (no errors across all
 *      priority tiers, round-trip via GetThreadPriority).
 *   3. avrt.dll MMCSS implementation: AvSetMmThreadCharacteristicsW(L"Audio")
 *      elevates priority, AvSetMmThreadPriority adjusts it, and
 *      AvRevertMmThreadCharacteristics restores the saved priority.
 *   4. High-churn wineserver kqueue changelist + fd close/reuse stress across
 *      TCP loopback socket pairs with rapid FD_READ/FD_WRITE toggling.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o macos-sleep-qos-and-avrt-test.exe \
 *            tests/macos-sleep-qos-and-avrt-test.c -lws2_32
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef HANDLE (WINAPI *fn_av_set_w_t)(LPCWSTR, LPDWORD);
typedef BOOL   (WINAPI *fn_av_set_prio_t)(HANDLE, int);
typedef BOOL   (WINAPI *fn_av_revert_t)(HANDLE);

static double now_ms(void)
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}

static int test_sleep_precision(void)
{
    /* Sleep(0) must return promptly */
    double t0 = now_ms();
    for (int i = 0; i < 200; i++) Sleep(0);
    double z_ms = now_ms() - t0;
    if (z_ms > 200.0) {
        printf("FAIL: 200x Sleep(0) took %.2f ms\n", z_ms);
        return 1;
    }
    printf("PASS: 200x Sleep(0) completed in %.2f ms\n", z_ms);

    const DWORD targets[3] = { 1, 5, 10 };
    const int iters[3] = { 40, 20, 15 };
    for (int k = 0; k < 3; k++) {
        double sum = 0.0, max_dt = 0.0, min_dt = 1e9;
        for (int i = 0; i < iters[k]; i++) {
            double s0 = now_ms();
            Sleep(targets[k]);
            double dt = now_ms() - s0;
            sum += dt;
            if (dt > max_dt) max_dt = dt;
            if (dt < min_dt) min_dt = dt;
        }
        double avg = sum / iters[k];
        printf("PASS: Sleep(%2lu) x%2d: min=%.2f ms avg=%.2f ms max=%.2f ms\n",
               (unsigned long)targets[k], iters[k], min_dt, avg, max_dt);
        /* Must not return wildly early (>20% short) or oversleep wildly (>+5ms avg) */
        if (avg < (double)targets[k] * 0.85 || avg > (double)targets[k] + 5.0) {
            printf("FAIL: Sleep(%lu) avg=%.2f ms out of bounds\n",
                   (unsigned long)targets[k], avg);
            return 1;
        }
    }
    return 0;
}

static int test_thread_priority_and_avrt(void)
{
    const int prios[] = {
        THREAD_PRIORITY_IDLE,
        THREAD_PRIORITY_LOWEST,
        THREAD_PRIORITY_BELOW_NORMAL,
        THREAD_PRIORITY_NORMAL,
        THREAD_PRIORITY_ABOVE_NORMAL,
        THREAD_PRIORITY_HIGHEST,
        THREAD_PRIORITY_TIME_CRITICAL,
        THREAD_PRIORITY_NORMAL
    };
    HANDLE self = GetCurrentThread();
    for (size_t i = 0; i < sizeof(prios) / sizeof(prios[0]); i++) {
        if (!SetThreadPriority(self, prios[i])) {
            printf("FAIL: SetThreadPriority(%d) err=%lu\n", prios[i], GetLastError());
            return 1;
        }
        int got = GetThreadPriority(self);
        if (got != prios[i]) {
            printf("FAIL: GetThreadPriority expected %d got %d\n", prios[i], got);
            return 1;
        }
    }
    printf("PASS: SetThreadPriority/GetThreadPriority round-trip across all 7 tiers\n");

    HMODULE avrt = LoadLibraryA("avrt.dll");
    if (!avrt) {
        printf("FAIL: LoadLibrary(avrt.dll) err=%lu\n", GetLastError());
        return 1;
    }
    fn_av_set_w_t av_set = (fn_av_set_w_t)(void *)GetProcAddress(avrt, "AvSetMmThreadCharacteristicsW");
    fn_av_set_prio_t av_prio = (fn_av_set_prio_t)(void *)GetProcAddress(avrt, "AvSetMmThreadPriority");
    fn_av_revert_t av_rev = (fn_av_revert_t)(void *)GetProcAddress(avrt, "AvRevertMmThreadCharacteristics");
    if (!av_set || !av_prio || !av_rev) {
        printf("FAIL: missing avrt exports\n");
        return 1;
    }

    SetThreadPriority(self, THREAD_PRIORITY_NORMAL);
    DWORD task_idx = 0;
    HANDLE h = av_set(L"Audio", &task_idx);
    if (!h) {
        printf("FAIL: AvSetMmThreadCharacteristicsW(Audio) err=%lu\n", GetLastError());
        return 1;
    }
    int p_audio = GetThreadPriority(self);
    if (p_audio < THREAD_PRIORITY_HIGHEST) {
        printf("FAIL: Audio task did not elevate priority (got %d)\n", p_audio);
        av_rev(h);
        return 1;
    }
    if (!av_prio(h, 1 /* AVRT_PRIORITY_HIGH */) || GetThreadPriority(self) != THREAD_PRIORITY_HIGHEST) {
        printf("FAIL: AvSetMmThreadPriority(HIGH) did not set HIGHEST (got %d)\n", GetThreadPriority(self));
        av_rev(h);
        return 1;
    }
    if (!av_rev(h)) {
        printf("FAIL: AvRevertMmThreadCharacteristics err=%lu\n", GetLastError());
        return 1;
    }
    if (GetThreadPriority(self) != THREAD_PRIORITY_NORMAL) {
        printf("FAIL: AvRevert did not restore NORMAL (got %d)\n", GetThreadPriority(self));
        return 1;
    }
    if (av_rev((HANDLE)(ULONG_PTR)0xdeadbeef)) {
        printf("FAIL: AvRevert accepted bogus handle\n");
        return 1;
    }
    printf("PASS: avrt.dll Audio priority elevation (%d -> HIGHEST -> NORMAL) + revert ok\n", p_audio);
    return 0;
}

static int test_kqueue_socket_churn(void)
{
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        printf("FAIL: WSAStartup\n");
        return 1;
    }

    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in addr = { 0 };
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listener, 64) != 0) {
        printf("FAIL: bind/listen err=%d\n", WSAGetLastError());
        return 1;
    }
    int alen = sizeof(addr);
    getsockname(listener, (struct sockaddr *)&addr, &alen);

    /* Rapidly create, toggle FD_READ|FD_WRITE via WSAEventSelect, exchange
     * payloads, and close 48 TCP pairs to exercise batched kqueue changelists
     * and fd-reuse synchronous EV_DELETE ordering in wineserver. */
    double t0 = now_ms();
    for (int i = 0; i < 48; i++) {
        SOCKET c = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        WSAEVENT ev_c = WSACreateEvent();
        WSAEventSelect(c, ev_c, FD_CONNECT | FD_READ | FD_WRITE | FD_CLOSE);
        connect(c, (struct sockaddr *)&addr, sizeof(addr));

        SOCKET s = accept(listener, NULL, NULL);
        if (s == INVALID_SOCKET) {
            printf("FAIL: accept iter=%d err=%d\n", i, WSAGetLastError());
            return 1;
        }
        WSAEVENT ev_s = WSACreateEvent();
        WSAEventSelect(s, ev_s, FD_READ | FD_WRITE | FD_CLOSE);

        if (WaitForSingleObject(ev_c, 3000) != WAIT_OBJECT_0) {
            printf("FAIL: client wait timeout iter=%d\n", i);
            return 1;
        }
        char msg[16] = "kq-batch-ping!";
        char buf[16] = { 0 };
        if (send(c, msg, sizeof(msg), 0) != sizeof(msg)) {
            printf("FAIL: send iter=%d err=%d\n", i, WSAGetLastError());
            return 1;
        }
        if (WaitForSingleObject(ev_s, 3000) != WAIT_OBJECT_0) {
            printf("FAIL: server wait timeout iter=%d\n", i);
            return 1;
        }
        int r = recv(s, buf, sizeof(buf), 0);
        if (r != sizeof(msg) || memcmp(buf, msg, sizeof(msg)) != 0) {
            printf("FAIL: recv mismatch iter=%d r=%d\n", i, r);
            return 1;
        }
        /* Re-arm / clear events right before close to stress changelist flush */
        WSAEventSelect(s, ev_s, FD_READ);
        WSAEventSelect(c, ev_c, FD_WRITE);
        closesocket(s);
        closesocket(c);
        WSACloseEvent(ev_s);
        WSACloseEvent(ev_c);
    }
    closesocket(listener);
    WSACleanup();
    printf("PASS: 48 TCP socket kqueue changelist + close/reuse cycles in %.1f ms\n", now_ms() - t0);
    return 0;
}

int main(void)
{
    int fail = 0;
    fail += test_sleep_precision();
    fail += test_thread_priority_and_avrt();
    fail += test_kqueue_socket_churn();
    if (fail) {
        printf("FAILED (%d check(s))\n", fail);
        return 1;
    }
    printf("ALL MACOS SLEEP/QOS/AVRT/KQUEUE CHECKS PASSED\n");
    return 0;
}

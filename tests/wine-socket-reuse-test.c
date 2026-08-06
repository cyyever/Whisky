/* wine-socket-reuse-test.c — regression test for stale connect-error state on
 * reused sockets, the failure behind Steam's CEF webhelper never getting its UI
 * up (spurious WSAENETUNREACH / STATUS_NETWORK_UNREACHABLE on hosts that are
 * plainly reachable).
 *
 * Chromium's network service keeps a socket pool and races/retries connects
 * (Happy Eyeballs). Under Wine a *failed* connect used to leave state behind on
 * the socket, so a later operation on a reused socket reported the old failure:
 *
 *   - the AFD_POLL_CONNECT_ERR event bits   -> fixed upstream by 864ca426
 *     (patch 0022, "server: Clear connection failure events in
 *     IOCTL_AFD_WINE_CONNECT")
 *   - the errors[AFD_POLL_BIT_CONNECT_ERR] code itself -> NOT cleared by that
 *     commit. IOCTL_AFD_WINE_GET_SO_ERROR falls back to scanning errors[] when
 *     the socket has no current error, so the stale code resurfaced on the next
 *     operation — an overlapped send on an already-connected socket returning
 *     network-unreachable. Patch 0023 clears it alongside the event bits.
 *
 * The tests below fail on an unpatched Wine and pass on a patched one. They
 * only need loopback plus one unroutable address, so they are hermetic — no
 * dependency on any external host being up.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o wine-socket-reuse-test.exe \
 *          wine-socket-reuse-test.c -mconsole -lws2_32 -lmswsock
 * Run:   WINEPREFIX=<bottle> wine64 wine-socket-reuse-test.exe
 * Exit:  0 = all passed, 1 = a regression is present.
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <stdio.h>

static int failures;

static void ok_(int cond, const char *name, const char *detail)
{
    fprintf(stderr, "%-4s %s%s%s\n", cond ? "PASS" : "FAIL", name,
            (!cond && detail && *detail) ? " -- " : "", (!cond && detail) ? detail : "");
    if (!cond) failures++;
}

/* An address that is guaranteed not to route: TEST-NET-1 (RFC 5737), reserved
 * for documentation and never reachable. Connecting there fails, which is
 * exactly the "prior failure" we need to poison a socket with. */
#define UNROUTABLE_IP "192.0.2.1"
#define UNROUTABLE_PORT 9

static struct sockaddr_in addr_of(const char *ip, unsigned short port)
{
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr(ip);
    return a;
}

/* Start a listening socket on loopback; returns it and fills @out with the
 * address it ended up bound to (port chosen by the stack). */
static SOCKET start_listener(struct sockaddr_in *out)
{
    SOCKET l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = addr_of("127.0.0.1", 0);
    int len = sizeof(a);

    if (l == INVALID_SOCKET) return INVALID_SOCKET;
    if (bind(l, (struct sockaddr *)&a, sizeof(a)) || listen(l, 4)
        || getsockname(l, (struct sockaddr *)&a, &len))
    {
        closesocket(l);
        return INVALID_SOCKET;
    }
    *out = a;
    return l;
}

/* Drive a non-blocking connect to completion; returns the WSA error (0 = ok). */
static int connect_nb(SOCKET s, const struct sockaddr_in *a, int timeout_ms)
{
    fd_set wr, ex;
    struct timeval tv;
    int err = 0, len = sizeof(err);

    if (!connect(s, (const struct sockaddr *)a, sizeof(*a))) return 0;
    if (WSAGetLastError() != WSAEWOULDBLOCK) return WSAGetLastError();

    FD_ZERO(&wr); FD_SET(s, &wr);
    FD_ZERO(&ex); FD_SET(s, &ex);
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    if (select(0, NULL, &wr, &ex, &tv) <= 0) return WSAETIMEDOUT;

    getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&err, &len);
    return err;
}

/* SO_ERROR must be clear on a socket that just connected successfully, even
 * when an earlier connect on that same socket failed. This is the direct probe
 * of the stale errors[] entry: reading SO_ERROR is what routes through
 * IOCTL_AFD_WINE_GET_SO_ERROR and its errors[] fallback scan. */
static void test_so_error_after_failed_then_good_connect(void)
{
    struct sockaddr_in good, bad = addr_of(UNROUTABLE_IP, UNROUTABLE_PORT);
    SOCKET l = start_listener(&good), s;
    u_long nb = 1;
    int err, so_err = 0, len = sizeof(so_err);
    char detail[128];

    if (l == INVALID_SOCKET) { ok_(0, "so_error_after_reuse", "listener setup failed"); return; }

    s = socket(AF_INET, SOCK_STREAM, 0);
    ioctlsocket(s, FIONBIO, &nb);

    /* 1: poison the socket with a failed connect. */
    err = connect_nb(s, &bad, 3000);
    if (!err)
    {
        /* Someone actually routes TEST-NET-1 — can't poison, so skip rather
         * than report a bogus pass/fail. */
        ok_(1, "so_error_after_reuse (skipped: " UNROUTABLE_IP " is routable)", NULL);
        closesocket(s); closesocket(l);
        return;
    }

    /* 2: a fresh connect on a *new* socket, then check SO_ERROR is clean.
     * (Windows disallows reconnecting the same socket after a failure, so the
     * pool reuse we emulate is "new socket, same server object state".) */
    closesocket(s);
    s = socket(AF_INET, SOCK_STREAM, 0);
    ioctlsocket(s, FIONBIO, &nb);
    err = connect_nb(s, &good, 3000);
    if (err) { ok_(0, "so_error_after_reuse", "loopback connect failed"); goto done; }

    getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&so_err, &len);
    sprintf(detail, "SO_ERROR=%d after a successful connect (expected 0)", so_err);
    ok_(so_err == 0, "so_error_after_reuse", detail);

done:
    closesocket(s);
    closesocket(l);
}

/* The webhelper's actual shape: an overlapped send on a socket that connected
 * successfully must not report the earlier connect's error. Before the fix this
 * surfaced as async_send_proc returning STATUS_NETWORK_UNREACHABLE. */
static void test_overlapped_send_after_failed_connect(void)
{
    struct sockaddr_in good, bad = addr_of(UNROUTABLE_IP, UNROUTABLE_PORT);
    SOCKET l = start_listener(&good), s, peer = INVALID_SOCKET;
    LPFN_CONNECTEX pConnectEx = NULL;
    GUID guid = WSAID_CONNECTEX;
    DWORD nbytes = 0, transferred = 0, flags = 0;
    OVERLAPPED ov;
    WSABUF buf;
    char payload[] = "ping";
    char detail[128];
    struct sockaddr_in any = addr_of("0.0.0.0", 0);
    int err;
    u_long nb = 1;

    if (l == INVALID_SOCKET) { ok_(0, "overlapped_send_after_failure", "listener setup failed"); return; }

    /* 1: poison — a failed connect first. */
    s = socket(AF_INET, SOCK_STREAM, 0);
    ioctlsocket(s, FIONBIO, &nb);
    if (!connect_nb(s, &bad, 3000))
    {
        ok_(1, "overlapped_send_after_failure (skipped: " UNROUTABLE_IP " is routable)", NULL);
        closesocket(s); closesocket(l);
        return;
    }
    closesocket(s);

    /* 2: overlapped ConnectEx to the live listener. */
    s = WSASocketW(AF_INET, SOCK_STREAM, 0, NULL, 0, WSA_FLAG_OVERLAPPED);
    if (s == INVALID_SOCKET) { ok_(0, "overlapped_send_after_failure", "WSASocketW failed"); closesocket(l); return; }
    bind(s, (struct sockaddr *)&any, sizeof(any));   /* ConnectEx requires a bound socket */

    if (WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER, &guid, sizeof(guid),
                 &pConnectEx, sizeof(pConnectEx), &nbytes, NULL, NULL))
    {
        sprintf(detail, "no ConnectEx pointer (err %d)", WSAGetLastError());
        ok_(0, "overlapped_send_after_failure", detail);
        goto done;
    }

    memset(&ov, 0, sizeof(ov));
    ov.hEvent = WSACreateEvent();
    if (!pConnectEx(s, (struct sockaddr *)&good, sizeof(good), NULL, 0, NULL, &ov))
    {
        if (WSAGetLastError() != ERROR_IO_PENDING
            || WSAWaitForMultipleEvents(1, &ov.hEvent, TRUE, 5000, FALSE) != WSA_WAIT_EVENT_0
            || !WSAGetOverlappedResult(s, &ov, &transferred, FALSE, &flags))
        {
            sprintf(detail, "ConnectEx failed (err %d)", WSAGetLastError());
            ok_(0, "overlapped_send_after_failure", detail);
            WSACloseEvent(ov.hEvent);
            goto done;
        }
    }
    setsockopt(s, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, NULL, 0);
    peer = accept(l, NULL, NULL);

    /* 3: the assertion — an overlapped send on this connected socket must
     * succeed, not resurrect the earlier connect's error. */
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = WSACreateEvent();
    buf.buf = payload;
    buf.len = (ULONG)sizeof(payload);
    transferred = 0;
    if (WSASend(s, &buf, 1, &transferred, 0, &ov, NULL))
    {
        err = WSAGetLastError();
        if (err == WSA_IO_PENDING)
        {
            err = (WSAWaitForMultipleEvents(1, &ov.hEvent, TRUE, 5000, FALSE) == WSA_WAIT_EVENT_0
                   && WSAGetOverlappedResult(s, &ov, &transferred, FALSE, &flags))
                  ? 0 : WSAGetLastError();
        }
    }
    else err = 0;

    sprintf(detail, "overlapped WSASend returned %d (expected 0; %d = stale connect error)",
            err, WSAENETUNREACH);
    ok_(err == 0, "overlapped_send_after_failure", detail);
    WSACloseEvent(ov.hEvent);

done:
    if (peer != INVALID_SOCKET) closesocket(peer);
    closesocket(s);
    closesocket(l);
}

/* A plain blocking connect to a live listener must succeed after an unrelated
 * failed connect — the simplest form of the same regression, and the one that
 * kept passing while the overlapped path failed (which is why the bug hid). */
static void test_blocking_connect_after_failure(void)
{
    struct sockaddr_in good, bad = addr_of(UNROUTABLE_IP, UNROUTABLE_PORT);
    SOCKET l = start_listener(&good), s;
    char detail[128];
    u_long nb = 1;
    int err;

    if (l == INVALID_SOCKET) { ok_(0, "blocking_connect_after_failure", "listener setup failed"); return; }

    s = socket(AF_INET, SOCK_STREAM, 0);
    ioctlsocket(s, FIONBIO, &nb);
    if (!connect_nb(s, &bad, 3000))
    {
        ok_(1, "blocking_connect_after_failure (skipped: " UNROUTABLE_IP " is routable)", NULL);
        closesocket(s); closesocket(l);
        return;
    }
    closesocket(s);

    s = socket(AF_INET, SOCK_STREAM, 0);
    err = connect(s, (struct sockaddr *)&good, sizeof(good)) ? WSAGetLastError() : 0;
    sprintf(detail, "connect returned %d (expected 0)", err);
    ok_(err == 0, "blocking_connect_after_failure", detail);

    closesocket(s);
    closesocket(l);
}

int main(void)
{
    WSADATA wsa;

    if (WSAStartup(MAKEWORD(2, 2), &wsa))
    {
        fprintf(stderr, "FAIL WSAStartup\n");
        return 1;
    }

    fprintf(stderr, "socket connect-state regression tests\n");
    fprintf(stderr, "-------------------------------------\n");
    test_blocking_connect_after_failure();
    test_so_error_after_failed_then_good_connect();
    test_overlapped_send_after_failed_connect();
    fprintf(stderr, "-------------------------------------\n");
    fprintf(stderr, "%s (%d failure%s)\n", failures ? "FAILED" : "OK",
            failures, failures == 1 ? "" : "s");

    WSACleanup();
    return failures ? 1 : 0;
}

/*
 * ws2_32-fd-write-rearm-test — regression test for Winsock2 AFD FD_WRITE
 * re-arming semantics and WSAEnumNetworkEvents() stability/throughput.
 *
 * Per Windows Winsock2 / AFD semantics, FD_WRITE is only re-enabled after a
 * send fails with WSAEWOULDBLOCK (STATUS_DEVICE_NOT_READY). Re-arming FD_WRITE
 * on any other send failure (e.g. WSAEMSGSIZE or WSAENETUNREACH on UDP) causes
 * POLLOUT to immediately fire FD_WRITE again and spin polling loops like
 * SteamNetworkingSockets.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o ws2_32-fd-write-rearm-test.exe \
 *       tests/ws2_32-fd-write-rearm-test.c -lws2_32
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
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
    } \
} while (0)

int main(void)
{
    WSADATA wsa;
    SOCKET s;
    WSAEVENT ev;
    WSANETWORKEVENTS ne;
    struct sockaddr_in dst;
    static char big_buf[70000];
    int rc, err;
    DWORD w;
    u_long nonblock = 1;
    int i;

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
    {
        printf("FAIL: WSAStartup failed\n");
        return 1;
    }

    s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    CHECK(s != INVALID_SOCKET, "socket(AF_INET, SOCK_DGRAM) created");
    if (s == INVALID_SOCKET) return 1;

    ioctlsocket(s, FIONBIO, &nonblock);

    ev = WSACreateEvent();
    CHECK(ev != WSA_INVALID_EVENT, "WSACreateEvent created");

    rc = WSAEventSelect(s, ev, FD_READ | FD_WRITE);
    CHECK(rc == 0, "WSAEventSelect(FD_READ|FD_WRITE) rc=%d", rc);

    /* Initial FD_WRITE should be delivered and drained. */
    w = WaitForSingleObject(ev, 500);
    CHECK(w == WAIT_OBJECT_0, "initial FD_WRITE signaled (w=0x%lx)", (unsigned long)w);

    memset(&ne, 0, sizeof(ne));
    rc = WSAEnumNetworkEvents(s, ev, &ne);
    CHECK(rc == 0 && (ne.lNetworkEvents & FD_WRITE) != 0,
          "initial WSAEnumNetworkEvents drained FD_WRITE (rc=%d ev=0x%lx)",
          rc, (unsigned long)ne.lNetworkEvents);

    /* Confirm event is now quiet. */
    w = WaitForSingleObject(ev, 50);
    CHECK(w == WAIT_TIMEOUT, "event quiet after initial FD_WRITE drain (w=0x%lx)", (unsigned long)w);

    /* Send an oversized UDP datagram to loopback: fails with WSAEMSGSIZE
     * (NOT WSAEWOULDBLOCK). Must NOT re-arm FD_WRITE! */
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(65432);
    dst.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    rc = sendto(s, big_buf, sizeof(big_buf), 0, (struct sockaddr *)&dst, sizeof(dst));
    err = WSAGetLastError();
    CHECK(rc == SOCKET_ERROR && err == WSAEMSGSIZE,
          "oversized UDP sendto failed with WSAEMSGSIZE (rc=%d err=%d)", rc, err);

    w = WaitForSingleObject(ev, 100);
    CHECK(w == WAIT_TIMEOUT,
          "non-WSAEWOULDBLOCK send error must NOT re-arm FD_WRITE (w=0x%lx)", (unsigned long)w);

    memset(&ne, 0, sizeof(ne));
    rc = WSAEnumNetworkEvents(s, ev, &ne);
    CHECK(rc == 0 && (ne.lNetworkEvents & FD_WRITE) == 0,
          "WSAEnumNetworkEvents shows no spurious FD_WRITE (rc=%d ev=0x%lx)",
          rc, (unsigned long)ne.lNetworkEvents);

    /* Rapid poll burst: verify WSAEnumNetworkEvents returns cleanly without errors. */
    for (i = 0; i < 2000; i++)
    {
        rc = WSAEnumNetworkEvents(s, NULL, &ne);
        if (rc != 0 || ne.lNetworkEvents != 0)
        {
            printf("FAIL: burst iter %d: rc=%d ev=0x%lx\n", i, rc, (unsigned long)ne.lNetworkEvents);
            failures++;
            break;
        }
    }
    if (i == 2000)
        printf("PASS: 2000 quiet WSAEnumNetworkEvents polls clean\n");

    WSACloseEvent(ev);
    closesocket(s);
    WSACleanup();

    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

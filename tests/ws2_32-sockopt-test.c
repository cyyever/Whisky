/*
 * Regression test for macOS BSD getsockopt/setsockopt normalization in
 * ntdll/unix/socket.c (patch 0029):
 *   1. Boolean socket options (SO_BROADCAST, SO_OOBINLINE, SO_KEEPALIVE,
 *      TCP_NODELAY) return normalized 0/1 instead of macOS kernel bitmasks
 *      (0x20, 0x100, 0x08, 0x04), including 1-byte reads where 0x100 used to
 *      truncate to 0x00.
 *   2. IP_MULTICAST_LOOP / IP_MULTICAST_TTL accept 1..4 byte optlen on macOS
 *      (where XNU expects u_char) and return Windows-conformant 1- or 4-byte
 *      values.
 *   3. IP_TOS / IP_TTL accept 1- and 2-byte optlen and reject values > 255.
 *   4. IPv6 receive options (IPV6_HOPLIMIT, IPV6_PKTINFO, IPV6_RECVTCLASS)
 *      accept 8-byte buffers (truncating to DWORD) and return normalized 0/1.
 *   5. TCP_KEEPCNT rejects values > 255 with WSAEINVAL.
 *
 * Compile:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o ws2_32-sockopt-test.exe \
 *       tests/ws2_32-sockopt-test.c -lws2_32
 */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <stdint.h>

static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        failures++; \
    } else { \
        printf("PASS: " fmt "\n", ##__VA_ARGS__); \
    } \
} while (0)

static void check_bool_opt(int af, int type, int level, int optname, const char *name, int expect_len4)
{
    SOCKET s = socket(af, type, 0);
    DWORD v = 1, out = 0xdeadbeef;
    int len;

    CHECK(s != INVALID_SOCKET, "[%s] socket()", name);
    if (s == INVALID_SOCKET) return;

    CHECK(setsockopt(s, level, optname, (const char *)&v, sizeof(v)) == 0,
          "[%s] setsockopt(1)", name);

    len = sizeof(out);
    out = 0xdeadbeef;
    CHECK(getsockopt(s, level, optname, (char *)&out, &len) == 0 &&
          (expect_len4 ? (out == 1 && len == 4) : ((out & 0xff) == 1 && len == 1)),
          "[%s] getsockopt(len=4) -> val=0x%lx len=%d", name, (unsigned long)out, len);

    len = 1;
    out = 0xdeadbeef;
    CHECK(getsockopt(s, level, optname, (char *)&out, &len) == 0 &&
          out == 0xdeadbe01 && len == 1,
          "[%s] getsockopt(len=1) -> val=0x%lx len=%d", name, (unsigned long)out, len);

    closesocket(s);
}

int main(void)
{
    WSADATA wsa;
    SOCKET s;
    DWORD v, out;
    uint64_t v64;
    int len, rc;

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        printf("FAIL: WSAStartup\n");
        return 1;
    }

    /* 1. Boolean options must return 1, not macOS bitmasks (0x20/0x100/0x08/0x04) */
    check_bool_opt(AF_INET, SOCK_DGRAM,  SOL_SOCKET,  SO_BROADCAST, "SO_BROADCAST", 1);
    check_bool_opt(AF_INET, SOCK_STREAM, SOL_SOCKET,  SO_OOBINLINE, "SO_OOBINLINE", 1);
    check_bool_opt(AF_INET, SOCK_STREAM, SOL_SOCKET,  SO_KEEPALIVE, "SO_KEEPALIVE", 0);
    check_bool_opt(AF_INET, SOCK_STREAM, IPPROTO_TCP, TCP_NODELAY,  "TCP_NODELAY",  0);

    /* 2. IP_MULTICAST_LOOP (value=0x100 with len=4, plus len=2) */
    s = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(s != INVALID_SOCKET, "[IP_MULTICAST_LOOP] socket()");
    if (s != INVALID_SOCKET) {
        v = 0x100;
        CHECK(setsockopt(s, IPPROTO_IP, IP_MULTICAST_LOOP, (const char *)&v, 4) == 0,
              "[IP_MULTICAST_LOOP] setsockopt(0x100, len=4)");
        out = 0xdeadbeef;
        len = 4;
        CHECK(getsockopt(s, IPPROTO_IP, IP_MULTICAST_LOOP, (char *)&out, &len) == 0 &&
              out == 1 && len == 4,
              "[IP_MULTICAST_LOOP] getsockopt(len=4) -> val=0x%lx len=%d", (unsigned long)out, len);
        v = 1;
        CHECK(setsockopt(s, IPPROTO_IP, IP_MULTICAST_LOOP, (const char *)&v, 2) == 0,
              "[IP_MULTICAST_LOOP] setsockopt(1, len=2)");
        out = 0xdeadbeef;
        len = 2;
        CHECK(getsockopt(s, IPPROTO_IP, IP_MULTICAST_LOOP, (char *)&out, &len) == 0 &&
              out == 0xdeadbe01 && len == 1,
              "[IP_MULTICAST_LOOP] getsockopt(len=2) -> val=0x%lx len=%d", (unsigned long)out, len);
        closesocket(s);
    }

    /* 3. IP_MULTICAST_TTL with 1, 2, 3, 4 byte lengths */
    s = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(s != INVALID_SOCKET, "[IP_MULTICAST_TTL] socket()");
    if (s != INVALID_SOCKET) {
        const DWORD vals[4] = { 0xffffff0a, 0xffff000b, 0xff00000c, 0x0000000d };
        int i;
        for (i = 0; i < 4; ++i) {
            DWORD expect = (i == 0) ? 0x0a : (i == 1) ? 0x0b : (i == 2) ? 0x0c : 0x0d;
            CHECK(setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, (const char *)&vals[i], i + 1) == 0,
                  "[IP_MULTICAST_TTL] setsockopt(len=%d)", i + 1);
            out = 0;
            len = 4;
            CHECK(getsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, (char *)&out, &len) == 0 &&
                  out == expect && len == 4,
                  "[IP_MULTICAST_TTL] getsockopt(len=%d) -> 0x%lx (expected 0x%lx)",
                  i + 1, (unsigned long)out, (unsigned long)expect);
        }
        v = 0x100;
        rc = setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, (const char *)&v, 4);
        CHECK(rc == SOCKET_ERROR && WSAGetLastError() == WSAEINVAL,
              "[IP_MULTICAST_TTL] rejects 0x100 with WSAEINVAL (err=%d)", WSAGetLastError());
        closesocket(s);
    }

    /* 4. IP_TOS and IP_TTL with 1- and 2-byte optlen */
    s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s != INVALID_SOCKET) {
        const int opts[2] = { IP_TOS, IP_TTL };
        const char *names[2] = { "IP_TOS", "IP_TTL" };
        int k;
        for (k = 0; k < 2; ++k) {
            v = 1;
            CHECK(setsockopt(s, IPPROTO_IP, opts[k], (const char *)&v, 1) == 0,
                  "[%s] setsockopt(len=1)", names[k]);
            CHECK(setsockopt(s, IPPROTO_IP, opts[k], (const char *)&v, 2) == 0,
                  "[%s] setsockopt(len=2)", names[k]);
            out = 0xdeadbeef;
            len = 2;
            CHECK(getsockopt(s, IPPROTO_IP, opts[k], (char *)&out, &len) == 0 &&
                  out == 0xdeadbe01 && len == 1,
                  "[%s] getsockopt(len=2) -> val=0x%lx len=%d", names[k], (unsigned long)out, len);
        }
        closesocket(s);
    }

    /* 5. IPv6 receive options with 8-byte buffer */
    s = socket(AF_INET6, SOCK_DGRAM, 0);
    if (s != INVALID_SOCKET) {
        const int opts[3] = { IPV6_HOPLIMIT, IPV6_PKTINFO, IPV6_RECVTCLASS };
        const char *names[3] = { "IPV6_HOPLIMIT", "IPV6_PKTINFO", "IPV6_RECVTCLASS" };
        int k;
        for (k = 0; k < 3; ++k) {
            v64 = 0xffffffff00000001ULL;
            CHECK(setsockopt(s, IPPROTO_IPV6, opts[k], (const char *)&v64, sizeof(v64)) == 0,
                  "[%s] setsockopt(len=8)", names[k]);
            out = 0xdeadbeef;
            len = 4;
            CHECK(getsockopt(s, IPPROTO_IPV6, opts[k], (char *)&out, &len) == 0 &&
                  out == 1 && len == 4,
                  "[%s] getsockopt(len=4) -> val=0x%lx len=%d", names[k], (unsigned long)out, len);
        }
        closesocket(s);
    }

    /* 6. TCP_KEEPCNT rejects > 255 */
    s = socket(AF_INET, SOCK_STREAM, 0);
    if (s != INVALID_SOCKET) {
        v = 0x100;
        rc = setsockopt(s, IPPROTO_TCP, TCP_KEEPCNT, (const char *)&v, 4);
        CHECK(rc == SOCKET_ERROR && WSAGetLastError() == WSAEINVAL,
              "[TCP_KEEPCNT] rejects 0x100 with WSAEINVAL (err=%d)", WSAGetLastError());
        closesocket(s);
    }

    WSACleanup();
    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

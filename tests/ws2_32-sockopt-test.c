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
#include <mswsock.h>
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

    /* 7. WSARecvMsg returns IP_TOS and IP_TTL ancillary data on macOS (patch 0040) */
    {
        SOCKET rx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        SOCKET tx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        CHECK(rx != INVALID_SOCKET && tx != INVALID_SOCKET, "[WSARecvMsg] create UDP sockets");
        if (rx != INVALID_SOCKET && tx != INVALID_SOCKET) {
            GUID guid = WSAID_WSARECVMSG;
            LPFN_WSARECVMSG pWSARecvMsg = NULL;
            DWORD bytes = 0;
            struct sockaddr_in addr;
            int addrlen = sizeof(addr);
            DWORD one = 1, tos = 0x28, ttl = 42;
            const char payload[] = "tos-ttl-ping";
            char rbuf[64], cbuf[256];
            WSABUF data_buf = { sizeof(rbuf), rbuf };
            WSAMSG msg;
            int got_tos = 0, got_ttl = 0, got_tos_val = -1, got_ttl_val = -1;

            rc = WSAIoctl(rx, SIO_GET_EXTENSION_FUNCTION_POINTER, &guid, sizeof(guid),
                          &pWSARecvMsg, sizeof(pWSARecvMsg), &bytes, NULL, NULL);
            CHECK(rc == 0 && pWSARecvMsg != NULL, "[WSARecvMsg] resolve extension pointer");

            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            addr.sin_port = 0;
            CHECK(bind(rx, (struct sockaddr *)&addr, sizeof(addr)) == 0, "[WSARecvMsg] bind loopback");
            CHECK(getsockname(rx, (struct sockaddr *)&addr, &addrlen) == 0, "[WSARecvMsg] getsockname");

            CHECK(setsockopt(rx, IPPROTO_IP, IP_RECVTOS, (const char *)&one, sizeof(one)) == 0,
                  "[WSARecvMsg] setsockopt(IP_RECVTOS=1)");
            CHECK(setsockopt(rx, IPPROTO_IP, IP_RECVTTL, (const char *)&one, sizeof(one)) == 0,
                  "[WSARecvMsg] setsockopt(IP_RECVTTL=1)");
            CHECK(setsockopt(tx, IPPROTO_IP, IP_TOS, (const char *)&tos, sizeof(tos)) == 0,
                  "[WSARecvMsg] setsockopt(IP_TOS=0x28)");
            CHECK(setsockopt(tx, IPPROTO_IP, IP_TTL, (const char *)&ttl, sizeof(ttl)) == 0,
                  "[WSARecvMsg] setsockopt(IP_TTL=42)");

            rc = sendto(tx, payload, (int)sizeof(payload), 0, (struct sockaddr *)&addr, sizeof(addr));
            CHECK(rc == (int)sizeof(payload), "[WSARecvMsg] sendto loopback rc=%d", rc);

            if (pWSARecvMsg) {
                DWORD recv_bytes = 0;
                memset(&msg, 0, sizeof(msg));
                memset(cbuf, 0, sizeof(cbuf));
                msg.lpBuffers = &data_buf;
                msg.dwBufferCount = 1;
                msg.Control.buf = cbuf;
                msg.Control.len = sizeof(cbuf);
                rc = pWSARecvMsg(rx, &msg, &recv_bytes, NULL, NULL);
                CHECK(rc == 0 && recv_bytes == sizeof(payload),
                      "[WSARecvMsg] recv rc=%d bytes=%lu err=%d", rc, (unsigned long)recv_bytes, WSAGetLastError());
                if (rc == 0) {
                    WSACMSGHDR *cm;
                    for (cm = WSA_CMSG_FIRSTHDR(&msg); cm != NULL; cm = WSA_CMSG_NXTHDR(&msg, cm)) {
                        if (cm->cmsg_level == IPPROTO_IP && cm->cmsg_type == IP_TOS) {
                            got_tos = 1;
                            memcpy(&got_tos_val, WSA_CMSG_DATA(cm), sizeof(int));
                        } else if (cm->cmsg_level == IPPROTO_IP && cm->cmsg_type == IP_TTL) {
                            got_ttl = 1;
                            memcpy(&got_ttl_val, WSA_CMSG_DATA(cm), sizeof(int));
                        }
                    }
                }
                CHECK(got_tos && got_tos_val == (int)tos,
                      "[WSARecvMsg] IP_TOS cmsg present=%d val=0x%x (expected 0x28)", got_tos, got_tos_val);
                CHECK(got_ttl && got_ttl_val == (int)ttl,
                      "[WSARecvMsg] IP_TTL cmsg present=%d val=%d (expected 42)", got_ttl, got_ttl_val);
            }
        }
        if (rx != INVALID_SOCKET) closesocket(rx);
        if (tx != INVALID_SOCKET) closesocket(tx);
    }

    WSACleanup();
    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

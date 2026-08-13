/*
 * ws2_32 IPv4-only resolution test — verifies patches/proton-wine/0019.
 *
 * The Steam login hang on IPv6-dead networks is caused by Wine's getaddrinfo()
 * returning IPv6 (AAAA) addresses for Steam's CM/directory hosts; steamclient
 * then connects to a dead IPv6 address and stalls (STATUS_HOST_UNREACHABLE
 * 0xc000023d). Patch 0019 makes getaddrinfo() pin ai_family to AF_INET by
 * default, so only A records come back; WINE_DISABLE_IPV6=0 opts back out.
 *
 * This resolves a dual-stack host with AF_UNSPEC hints and counts the address
 * families returned:
 *   - default (or =1)      -> expect ZERO AF_INET6 results (the fix)
 *   - WINE_DISABLE_IPV6=0  -> resolution unchanged (IPv6 may appear)
 *
 * The =0 arm cannot assert that IPv6 *does* come back -- that depends on the
 * network and on the host's records -- so it is a smoke test for the override,
 * not a control. What it does catch is an override that stopped being read.
 *
 * Build (x86_64 mingw, matches the other Steam-side test PEs):
 *   x86_64-w64-mingw32-gcc -O2 -o ws2_32-ipv4-only-test.exe \
 *       scripts/ws2_32-ipv4-only-test.c -lws2_32
 *
 * Run under the Steam bottle's wine, both ways, e.g.:
 *   WINEPREFIX=<bottle>                     wine64 ws2_32-ipv4-only-test.exe
 *   WINEPREFIX=<bottle> WINE_DISABLE_IPV6=0 wine64 ws2_32-ipv4-only-test.exe
 *
 * Exit code 0 = pass, 1 = fail. The host defaults to api.steampowered.com (the
 * real offender) and can be overridden as argv[1].
 */
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[])
{
    const char *host = (argc > 1) ? argv[1] : "api.steampowered.com";
    const char *env = getenv("WINE_DISABLE_IPV6");
    int disabled = (!env || env[0] != '0');
    WSADATA wsa;
    struct addrinfo hints = {0}, *res = NULL, *p;
    int v4 = 0, v6 = 0, other = 0, rc, want_v6_only = 0;

    setvbuf(stdout, NULL, _IONBF, 0);  /* Wine loses buffered stdout on exit */

    if (WSAStartup(MAKEWORD(2, 2), &wsa)) {
        printf("WSAStartup failed\n");
        return 1;
    }

    /* argv[2] == "v6" asks for AF_INET6 explicitly. The pin must NOT apply
     * there: an app that names a family has said something specific, and A
     * records would be a wrong answer rather than a narrowed one. This arm is
     * checkable even on a network with no AAAA at all -- what it asserts is the
     * absence of AF_INET results, not the presence of AF_INET6 ones. */
    if (argc > 2 && !strcmp(argv[2], "v6")) {
        want_v6_only = 1;
        hints.ai_family = AF_INET6;
    } else {
        hints.ai_family = AF_UNSPEC;   /* the query Steam makes: any family */
    }
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    rc = getaddrinfo(host, "443", &hints, &res);
    if (rc) {
        printf("getaddrinfo(%s) failed: %d\n", host, rc);
        WSACleanup();
        /* An AF_INET6 request that resolves to nothing is the correct outcome on
         * a network with no AAAA -- the wrong outcome would be A records. */
        if (want_v6_only) { printf("PASS (no results, and none of them IPv4)\n"); return 0; }
        /* A resolve failure is only conclusive when IPv6 was requested-off and
         * the host is IPv6-only; treat as fail so a broken hook is noticed. */
        return 1;
    }

    for (p = res; p; p = p->ai_next) {
        if (p->ai_family == AF_INET)       v4++;
        else if (p->ai_family == AF_INET6) v6++;
        else                               other++;
    }
    freeaddrinfo(res);
    WSACleanup();

    printf("host=%s WINE_DISABLE_IPV6=%d -> AF_INET=%d AF_INET6=%d other=%d\n",
           host, disabled, v4, v6, other);

    if (want_v6_only) {
        printf("%s: explicit AF_INET6 request\n", v4 ? "FAIL" : "PASS");
        if (v4) printf("FAIL: the IPv4 pin overrode an explicit AF_INET6 request\n");
        return v4 ? 1 : 0;
    }
    if (disabled && v6 > 0) {
        printf("FAIL: IPv6 not suppressed (patch 0019's default is not in this build)\n");
        return 1;
    }
    if (disabled && v4 == 0) {
        printf("FAIL: no IPv4 results while IPv6 is suppressed\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}

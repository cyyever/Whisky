/*
 * bottle-health-test — assert the environment invariants Steam depends on.
 *
 * Every check here corresponds to something that has silently broken in this
 * bottle at least once and cost hours to find, because the symptom appears
 * somewhere else entirely: Steam sits at "Logged Off" with no window and no
 * error, and nothing in its logs names the actual cause.
 *
 * Deliberately not a Steam test. Each case is a small, direct question about
 * Wine's environment with a yes/no answer, so a failure names the broken thing
 * instead of a downstream symptom.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O1 -o bottle-health-test.exe bottle-health-test.c \
 *       -lws2_32 -lwinhttp
 * Run:
 *   wine bottle-health-test.exe        # exit 0 = the bottle is sane
 */

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

static int failures;

static void ok(const char *name, const char *detail)
{
    printf("PASS %-34s %s\n", name, detail);
}

static void bad(const char *name, const char *detail)
{
    printf("FAIL %-34s %s\n", name, detail);
    failures++;
}

/* Steam's UI process and its CEF host talk over a loopback socket. If this
 * breaks, WebUITransportController initialises and then nothing ever happens —
 * no window, no error. */
static DWORD WINAPI connect_back(LPVOID port)
{
    SOCKET c = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {0};

    a.sin_family = AF_INET;
    a.sin_port = htons((u_short)(UINT_PTR)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(c, (struct sockaddr *)&a, sizeof(a))) return 1;
    send(c, "hi", 2, 0);
    return 0;
}

static void test_loopback(void)
{
    struct sockaddr_in a = {0};
    int len = sizeof(a);
    char buf[8] = {0}, msg[128];
    SOCKET lsock, s;
    HANDLE th;

    lsock = socket(AF_INET, SOCK_STREAM, 0);
    if (lsock == INVALID_SOCKET)
    {
        sprintf(msg, "socket() failed, WSA error %d", WSAGetLastError());
        bad("loopback TCP", msg);
        return;
    }
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(lsock, (struct sockaddr *)&a, sizeof(a)) || listen(lsock, 5))
    {
        sprintf(msg, "bind/listen failed, WSA error %d", WSAGetLastError());
        bad("loopback TCP", msg);
        return;
    }
    getsockname(lsock, (struct sockaddr *)&a, &len);
    th = CreateThread(NULL, 0, connect_back, (LPVOID)(UINT_PTR)ntohs(a.sin_port), 0, NULL);

    if ((s = accept(lsock, NULL, NULL)) == INVALID_SOCKET)
    {
        sprintf(msg, "accept failed, WSA error %d", WSAGetLastError());
        bad("loopback TCP", msg);
    }
    else
    {
        recv(s, buf, sizeof(buf), 0);
        if (buf[0] == 'h') { sprintf(msg, "port %d round trip", ntohs(a.sin_port)); ok("loopback TCP", msg); }
        else bad("loopback TCP", "accepted but no data");
    }
    WaitForSingleObject(th, 3000);
    closesocket(lsock);
}

/* Name resolution. A resolver that returns an h_errno ws2_32 does not map
 * surfaces as WSAEOPNOTSUPP (10045), which Chromium logs as an unexplained
 * "Unknown error 10045 mapped to net::ERR_FAILED".
 *
 * Only hostnames Steam actually uses. There is no "cm.steampowered.com" —
 * login servers are discovered at runtime through ISteamDirectory/GetCMList on
 * api.steampowered.com, so asserting on a guessed CM hostname tests nothing but
 * the guess. */
static void test_resolve(const char *host)
{
    struct addrinfo hints = {0}, *res = NULL;
    char msg[160], addr[64] = "";
    int err;

    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if ((err = getaddrinfo(host, "443", &hints, &res)) || !res)
    {
        sprintf(msg, "%s: getaddrinfo failed, error %d", host, err);
        bad("DNS resolve", msg);
        return;
    }
    inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, addr, sizeof(addr));
    sprintf(msg, "%s -> %s", host, addr);
    ok("DNS resolve", msg);
    freeaddrinfo(res);
}

/* Steam's own updater hangs on this host when the network path is broken,
 * without logging anything past "Downloading manifest". Wine's HTTPS stack
 * reaching it in well under a second is what distinguishes "the network is
 * fine, Steam's client is stuck" from "nothing can get out". */
static void test_https(void)
{
    DWORD t0 = GetTickCount(), status = 0, sz = sizeof(status);
    HINTERNET session, conn, req;
    char msg[128];

    session = WinHttpOpen(L"bottle-health", WINHTTP_ACCESS_TYPE_NO_PROXY,
                          WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) { bad("HTTPS to update host", "WinHttpOpen failed"); return; }
    WinHttpSetTimeouts(session, 10000, 10000, 10000, 10000);

    conn = WinHttpConnect(session, L"client-update.steamstatic.com",
                          INTERNET_DEFAULT_HTTPS_PORT, 0);
    req = conn ? WinHttpOpenRequest(conn, L"GET", L"/steam_client_win64", NULL,
                                    WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                    WINHTTP_FLAG_SECURE) : NULL;
    if (!req) { bad("HTTPS to update host", "could not open request"); return; }

    if (!WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0, NULL, 0, 0, 0) ||
        !WinHttpReceiveResponse(req, NULL))
    {
        sprintf(msg, "failed after %lums, error %lu", GetTickCount() - t0, GetLastError());
        bad("HTTPS to update host", msg);
        return;
    }
    WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &sz, WINHTTP_NO_HEADER_INDEX);
    sprintf(msg, "HTTP %lu in %lums", status, GetTickCount() - t0);
    if (status == 200) ok("HTTPS to update host", msg);
    else bad("HTTPS to update host", msg);
}

/* Helper executables Steam shells out to. A missing import makes them exit
 * c0000135 (STATUS_DLL_NOT_FOUND) before main(), which Steam records as one
 * opaque "process exit code 3221225781" line. */
static void test_helper_deps(const char *exe, const char *dll)
{
    char msg[160];
    HMODULE m = LoadLibraryExA(dll, NULL, LOAD_LIBRARY_AS_DATAFILE);

    if (m) { sprintf(msg, "%s: %s present", exe, dll); ok("helper dependency", msg); FreeLibrary(m); }
    else { sprintf(msg, "%s needs %s, which is missing (exits c0000135)", exe, dll);
           bad("helper dependency", msg); }
}

int main(void)
{
    WSADATA wsa;

    WSAStartup(MAKEWORD(2, 2), &wsa);

    test_loopback();
    test_resolve("client-update.steamstatic.com");   /* the update manifest host */
    test_resolve("api.steampowered.com");            /* CM discovery lives here */
    test_https();
    test_helper_deps("gldriverquery.exe", "SDL2.dll");

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "OK", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}

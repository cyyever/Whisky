/*
 * Regression test for patches/proton-wine/0007-ntdll-kernelbase-macos-and-steam-defaults.patch.
 *
 * Verifies that when a Windows parent process (such as Steam.exe) launches a
 * child via CreateProcessW with SteamAppId / SteamGameId in the Windows
 * environment block, Wine propagates them into the child's Unix environment so
 * Proton's ~70 Unix-side getenv("SteamGameId") / getenv("SteamAppId") game
 * adaptations activate without polluting the parent's Unix environment.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o steam-appid-unix-env-test.exe \
 *       tests/steam-appid-unix-env-test.c
 *
 * Run (ensure SteamGameId / SteamAppId are unset in the host shell):
 *   env -u SteamGameId -u SteamAppId -u STEAM_COMPAT_APP_ID \
 *       wine64 steam-appid-unix-env-test.exe
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

typedef LONG (WINAPI *p_wine_get_unix_env_t)(const char *var, char *val, unsigned int len);

static p_wine_get_unix_env_t p_wine_get_unix_env;
static int failures;

static int get_unix_env(const char *name, char *buf, unsigned int len)
{
    buf[0] = '\0';
    return p_wine_get_unix_env(name, buf, len) == 0;
}

static void expect_unix_eq(const char *tag, const char *name, const char *expected)
{
    char val[256];
    int ok = get_unix_env(name, val, sizeof(val));

    if (!ok || strcmp(val, expected) != 0) {
        printf("FAIL [%s]: unix %s = %s (expected %s)\n",
               tag, name, ok ? val : "<unset>", expected);
        failures++;
    } else {
        printf("PASS [%s]: unix %s = %s\n", tag, name, val);
    }
}

static void expect_unix_unset(const char *tag, const char *name)
{
    char val[256];
    if (get_unix_env(name, val, sizeof(val))) {
        printf("FAIL [%s]: unix %s unexpectedly set to %s\n", tag, name, val);
        failures++;
    } else {
        printf("PASS [%s]: unix %s is unset\n", tag, name);
    }
}

static int run_child(const wchar_t *self, const wchar_t *arg, const wchar_t *env_block)
{
    wchar_t cmd[MAX_PATH + 64];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD exit_code = 99;

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));
    swprintf(cmd, MAX_PATH + 64, L"\"%s\" %s", self, arg);

    if (!CreateProcessW(self, cmd, NULL, NULL, TRUE, CREATE_UNICODE_ENVIRONMENT,
                        (LPVOID)env_block, NULL, &si, &pi)) {
        printf("FAIL: CreateProcessW(%ls) failed err=%lu\n", arg, GetLastError());
        return 1;
    }
    WaitForSingleObject(pi.hProcess, 30000);
    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return (int)exit_code;
}

int main(int argc, char **argv)
{
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    p_wine_get_unix_env = (p_wine_get_unix_env_t)(void *)GetProcAddress(ntdll, "__wine_get_unix_env");
    if (!p_wine_get_unix_env) {
        printf("FAIL: __wine_get_unix_env not exported by ntdll.dll\n");
        return 2;
    }

    if (argc >= 2 && strcmp(argv[1], "--child-mixed") == 0) {
        expect_unix_eq("mixed", "SteamAppId", "883710");
        expect_unix_eq("mixed", "SteamGameId", "883710");
        expect_unix_eq("mixed", "STEAM_COMPAT_APP_ID", "883710");
        return failures ? 1 : 0;
    }

    if (argc >= 2 && strcmp(argv[1], "--child-sf6") == 0) {
        /* Street Fighter 6 (1364780): Proton's ntdll/unix/loader.c hacks_init()
         * checks getenv("SteamGameId") == "1364780" and sets WINE_ENABLE_GST_LIVE_LATENCY=1. */
        expect_unix_eq("sf6", "SteamAppId", "1364780");
        expect_unix_eq("sf6", "SteamGameId", "1364780");
        expect_unix_eq("sf6", "STEAM_COMPAT_APP_ID", "1364780");
        expect_unix_eq("sf6", "WINE_ENABLE_GST_LIVE_LATENCY", "1");
        return failures ? 1 : 0;
    }

    wchar_t self[MAX_PATH];
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) {
        printf("FAIL: GetModuleFileNameW failed\n");
        return 2;
    }

    /* Confirm host launched us clean */
    expect_unix_unset("parent-before", "SteamAppId");
    expect_unix_unset("parent-before", "SteamGameId");
    expect_unix_unset("parent-before", "STEAM_COMPAT_APP_ID");

    /* Case 1: Mixed-case Windows env keys normalized to exact Proton Unix names */
    {
        static const wchar_t env1[] =
            L"SystemRoot=C:\\windows\0"
            L"steamappid=883710\0"
            L"STEAMGAMEID=883710\0";
        if (run_child(self, L"--child-mixed", env1) != 0)
            failures++;
    }

    /* Case 2: Only SteamAppId set -> mirrors to SteamGameId & STEAM_COMPAT_APP_ID
     * and triggers Proton's real hacks_init() entry for SF6 (1364780) */
    {
        static const wchar_t env2[] =
            L"SystemRoot=C:\\windows\0"
            L"SteamAppId=1364780\0";
        if (run_child(self, L"--child-sf6", env2) != 0)
            failures++;
    }

    /* Case 3: Parent's own Unix environment must remain unpolluted */
    expect_unix_unset("parent-after", "SteamAppId");
    expect_unix_unset("parent-after", "SteamGameId");
    expect_unix_unset("parent-after", "STEAM_COMPAT_APP_ID");

    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

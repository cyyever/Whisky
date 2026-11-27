/*
 * Regression test for ARM64 wineserver + Rosetta 2 x86_64 client fixes:
 *
 *   1. wpm-exec-rwx: Cross-process WriteProcessMemory onto a PAGE_EXECUTE_READWRITE
 *      page in a child process *after* the child executes code on that page
 *      (forcing Rosetta 2 to downgrade Mach VM protection from RWX to R-X).
 *      Unpatched arm64 wineserver checks sysctl.proc_translated on itself (0)
 *      and rejects the write with ERROR_ACCESS_DENIED.
 *
 *   2. get-ctx-dr: GetThreadContext(CONTEXT_DEBUG_REGISTERS) via a real thread
 *      handle (bypassing ntdll's cached-DR fast path) with pre-poisoned
 *      Dr0..Dr7 = 0xdeadbeef. Unpatched arm64 wineserver compiles out
 *      get_thread_context(), leaving SERVER_CTX_DEBUG_REGISTERS unset and
 *      Dr0..Dr7 unzeroed (0xdeadbeef).
 *
 *   3. set-ctx-dr: SetThreadContext(CONTEXT_DEBUG_REGISTERS) with non-zero
 *      Dr7 = 0x1 on both a suspended worker thread and self. Unpatched arm64
 *      wineserver compiles out set_thread_context() and wrongly returns TRUE
 *      instead of failing with STATUS_UNSUCCESSFUL (ERROR_GEN_FAILURE).
 *
 *   4. map-view-4k-placeholder: MapViewOfFile3(MEM_REPLACE_PLACEHOLDER) at a
 *      4KB-aligned (non-16KB-aligned) placeholder address. Unpatched arm64
 *      wineserver validates req->base against its own 16KB host_page_mask
 *      instead of the Rosetta client's 4KB page_mask and rejects it with
 *      STATUS_INVALID_PARAMETER.
 *
 * Build:
 *   x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -o rosetta-mach-wpm-test.exe \
 *       tests/rosetta-mach-wpm-test.c
 */

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef MEM_RESERVE_PLACEHOLDER
#define MEM_RESERVE_PLACEHOLDER 0x00040000
#endif
#ifndef MEM_REPLACE_PLACEHOLDER
#define MEM_REPLACE_PLACEHOLDER 0x00004000
#endif
#ifndef MEM_PRESERVE_PLACEHOLDER
#define MEM_PRESERVE_PLACEHOLDER 0x00000002
#endif

typedef LPVOID (WINAPI *PFN_VirtualAlloc2)(HANDLE, PVOID, SIZE_T, ULONG, ULONG, PVOID, ULONG);
typedef LPVOID (WINAPI *PFN_MapViewOfFile3)(HANDLE, HANDLE, PVOID, ULONG64, SIZE_T, ULONG, ULONG, PVOID, ULONG);

static int read_exact(HANDLE h, void *buf, DWORD len)
{
    BYTE *p = (BYTE *)buf;
    DWORD done = 0;
    while (done < len)
    {
        DWORD n = 0;
        if (!ReadFile(h, p + done, len - done, &n, NULL) || n == 0)
            return 0;
        done += n;
    }
    return 1;
}

static int write_exact(HANDLE h, const void *buf, DWORD len)
{
    const BYTE *p = (const BYTE *)buf;
    DWORD done = 0;
    while (done < len)
    {
        DWORD n = 0;
        if (!WriteFile(h, p + done, len - done, &n, NULL) || n == 0)
            return 0;
        done += n;
    }
    return 1;
}

static int run_child(void)
{
    HANDLE hIn = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    BYTE *page;
    int (*fn)(void);
    int32_t res1, res2;
    uint64_t addr;
    BYTE go = 0;

    /* Allocate RWX page and emit `mov eax, 42; ret`. */
    page = (BYTE *)VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!page)
        return 10;

    page[0] = 0xb8; /* mov eax, imm32 */
    page[1] = 42;
    page[2] = 0;
    page[3] = 0;
    page[4] = 0;
    page[5] = 0xc3; /* ret */

    /* Execute the stub so Rosetta 2 translates the page and downgrades RWX -> R-X. */
    fn = (int (*)(void))(void *)page;
    res1 = fn();
    if (res1 != 42)
        return 11;

    addr = (uint64_t)(uintptr_t)page;
    if (!write_exact(hOut, &addr, sizeof(addr)))
        return 12;

    /* Wait for parent to patch the immediate and signal us. */
    if (!read_exact(hIn, &go, sizeof(go)))
        return 13;

    if (go == 1)
    {
        res2 = fn();
        if (!write_exact(hOut, &res2, sizeof(res2)))
            return 14;
    }

    VirtualFree(page, 0, MEM_RELEASE);
    return 0;
}

static int test_wpm_exec_rwx(void)
{
    char exe_path[MAX_PATH];
    char cmdline[MAX_PATH + 32];
    SECURITY_ATTRIBUTES sa;
    HANDLE p2c_r = NULL, p2c_w = NULL;
    HANDLE c2p_r = NULL, c2p_w = NULL;
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    uint64_t child_addr = 0;
    int32_t patch_val = 99;
    int32_t child_res = 0;
    SIZE_T written = 0;
    BYTE go = 0;
    int ok = 0;

    if (!GetModuleFileNameA(NULL, exe_path, sizeof(exe_path)))
    {
        printf("FAIL [wpm-exec-rwx]: GetModuleFileNameA failed (%lu)\n", GetLastError());
        return 1;
    }

    memset(&sa, 0, sizeof(sa));
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;

    if (!CreatePipe(&p2c_r, &p2c_w, &sa, 0) || !CreatePipe(&c2p_r, &c2p_w, &sa, 0))
    {
        printf("FAIL [wpm-exec-rwx]: CreatePipe failed (%lu)\n", GetLastError());
        return 1;
    }
    SetHandleInformation(p2c_w, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(c2p_r, HANDLE_FLAG_INHERIT, 0);

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = p2c_r;
    si.hStdOutput = c2p_w;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

    memset(&pi, 0, sizeof(pi));
    snprintf(cmdline, sizeof(cmdline), "\"%s\" --child", exe_path);

    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
    {
        printf("FAIL [wpm-exec-rwx]: CreateProcessA failed (%lu)\n", GetLastError());
        CloseHandle(p2c_r); CloseHandle(p2c_w);
        CloseHandle(c2p_r); CloseHandle(c2p_w);
        return 1;
    }

    CloseHandle(p2c_r);
    CloseHandle(c2p_w);

    if (!read_exact(c2p_r, &child_addr, sizeof(child_addr)))
    {
        printf("FAIL [wpm-exec-rwx]: failed reading child stub address\n");
        goto cleanup;
    }

    /* Patch the 4-byte immediate at unaligned offset +1 (42 -> 99). */
    SetLastError(0);
    if (!WriteProcessMemory(pi.hProcess, (LPVOID)(uintptr_t)(child_addr + 1),
                            &patch_val, sizeof(patch_val), &written))
    {
        printf("FAIL [wpm-exec-rwx]: WriteProcessMemory failed (err=%lu, written=%zu)\n",
               GetLastError(), (size_t)written);
        go = 0;
        write_exact(p2c_w, &go, sizeof(go));
        goto cleanup;
    }

    if (written != sizeof(patch_val))
    {
        printf("FAIL [wpm-exec-rwx]: short write (%zu != %zu)\n",
               (size_t)written, sizeof(patch_val));
        go = 0;
        write_exact(p2c_w, &go, sizeof(go));
        goto cleanup;
    }

    go = 1;
    if (!write_exact(p2c_w, &go, sizeof(go)) ||
        !read_exact(c2p_r, &child_res, sizeof(child_res)))
    {
        printf("FAIL [wpm-exec-rwx]: child IPC failed after patch\n");
        goto cleanup;
    }

    if (child_res != 99)
    {
        printf("FAIL [wpm-exec-rwx]: child executed stale/wrong value %d (expected 99)\n",
               (int)child_res);
        goto cleanup;
    }

    printf("PASS [wpm-exec-rwx]: cross-process WriteProcessMemory patched executed RWX page (42 -> %d)\n",
           (int)child_res);
    ok = 1;

cleanup:
    WaitForSingleObject(pi.hProcess, 5000);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    CloseHandle(p2c_w);
    CloseHandle(c2p_r);
    return ok ? 0 : 1;
}

static DWORD WINAPI get_ctx_dr_worker(void *unused)
{
    HANDLE hSelf;
    DECLSPEC_ALIGN(16) CONTEXT ctx;

    (void)unused;
    hSelf = OpenThread(THREAD_GET_CONTEXT, FALSE, GetCurrentThreadId());
    if (!hSelf)
    {
        printf("FAIL [get-ctx-dr]: OpenThread failed (%lu)\n", GetLastError());
        return 1;
    }

    memset(&ctx, 0, sizeof(ctx));
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    ctx.Dr0 = 0xdeadbeefULL;
    ctx.Dr1 = 0xdeadbeefULL;
    ctx.Dr2 = 0xdeadbeefULL;
    ctx.Dr3 = 0xdeadbeefULL;
    ctx.Dr6 = 0xdeadbeefULL;
    ctx.Dr7 = 0xdeadbeefULL;

    if (!GetThreadContext(hSelf, &ctx))
    {
        printf("FAIL [get-ctx-dr]: GetThreadContext failed (%lu)\n", GetLastError());
        CloseHandle(hSelf);
        return 1;
    }
    CloseHandle(hSelf);

    if ((ctx.ContextFlags & CONTEXT_DEBUG_REGISTERS) != CONTEXT_DEBUG_REGISTERS)
    {
        printf("FAIL [get-ctx-dr]: CONTEXT_DEBUG_REGISTERS not set in ContextFlags (0x%lx)\n",
               (unsigned long)ctx.ContextFlags);
        return 1;
    }

    if (ctx.Dr0 || ctx.Dr1 || ctx.Dr2 || ctx.Dr3 || ctx.Dr6 || ctx.Dr7)
    {
        printf("FAIL [get-ctx-dr]: DR0..DR7 not zeroed (Dr0=0x%llx Dr7=0x%llx)\n",
               (unsigned long long)ctx.Dr0, (unsigned long long)ctx.Dr7);
        return 1;
    }

    printf("PASS [get-ctx-dr]: GetThreadContext(CONTEXT_DEBUG_REGISTERS) zeroed DR0..DR7\n");
    return 0;
}

static int test_get_ctx_dr(void)
{
    HANDLE h;
    DWORD code = 1;

    h = CreateThread(NULL, 0, get_ctx_dr_worker, NULL, 0, NULL);
    if (!h)
    {
        printf("FAIL [get-ctx-dr]: CreateThread failed (%lu)\n", GetLastError());
        return 1;
    }
    if (WaitForSingleObject(h, 5000) != WAIT_OBJECT_0 || !GetExitCodeThread(h, &code))
    {
        printf("FAIL [get-ctx-dr]: worker wait failed\n");
        CloseHandle(h);
        return 1;
    }
    CloseHandle(h);
    return (code == 0) ? 0 : 1;
}

static DWORD WINAPI dummy_worker(void *unused)
{
    (void)unused;
    return 0;
}

static DWORD WINAPI set_ctx_dr_self_worker(void *unused)
{
    DECLSPEC_ALIGN(16) CONTEXT ctx;

    (void)unused;
    memset(&ctx, 0, sizeof(ctx));
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    ctx.Dr0 = 0x1234ULL;
    ctx.Dr7 = 0x1ULL;

    SetLastError(0);
    if (SetThreadContext(GetCurrentThread(), &ctx))
    {
        printf("FAIL [set-ctx-dr]: SetThreadContext(self, Dr7=0x1) wrongly succeeded\n");
        return 1;
    }
    return 0;
}

static int test_set_ctx_dr(void)
{
    HANDLE hSusp, hSelfWorker;
    DECLSPEC_ALIGN(16) CONTEXT ctx;
    DWORD code = 1;
    DWORD err_susp = 0;

    /* (a) Suspended worker thread */
    hSusp = CreateThread(NULL, 0, dummy_worker, NULL, CREATE_SUSPENDED, NULL);
    if (!hSusp)
    {
        printf("FAIL [set-ctx-dr]: CreateThread(CREATE_SUSPENDED) failed (%lu)\n", GetLastError());
        return 1;
    }

    memset(&ctx, 0, sizeof(ctx));
    ctx.ContextFlags = CONTEXT_DEBUG_REGISTERS;
    ctx.Dr0 = 0x1234ULL;
    ctx.Dr7 = 0x1ULL;

    SetLastError(0);
    if (SetThreadContext(hSusp, &ctx))
    {
        printf("FAIL [set-ctx-dr]: SetThreadContext(suspended, Dr7=0x1) wrongly succeeded\n");
        ResumeThread(hSusp);
        WaitForSingleObject(hSusp, 5000);
        CloseHandle(hSusp);
        return 1;
    }
    err_susp = GetLastError();
    ResumeThread(hSusp);
    WaitForSingleObject(hSusp, 5000);
    CloseHandle(hSusp);

    /* (b) Self thread */
    hSelfWorker = CreateThread(NULL, 0, set_ctx_dr_self_worker, NULL, 0, NULL);
    if (!hSelfWorker)
    {
        printf("FAIL [set-ctx-dr]: CreateThread(self worker) failed (%lu)\n", GetLastError());
        return 1;
    }
    if (WaitForSingleObject(hSelfWorker, 5000) != WAIT_OBJECT_0 ||
        !GetExitCodeThread(hSelfWorker, &code))
    {
        printf("FAIL [set-ctx-dr]: self worker wait failed\n");
        CloseHandle(hSelfWorker);
        return 1;
    }
    CloseHandle(hSelfWorker);
    if (code != 0)
        return 1;

    printf("PASS [set-ctx-dr]: SetThreadContext(Dr7=0x1) rejected on suspended (err=%lu) and self threads\n",
           err_susp);
    return 0;
}

static int test_map_view_4k_placeholder(void)
{
    HMODULE kb = GetModuleHandleA("kernelbase.dll");
    PFN_VirtualAlloc2 pVirtualAlloc2;
    PFN_MapViewOfFile3 pMapViewOfFile3;
    HANDLE hMap = NULL;
    BYTE *base = NULL;
    BYTE *view = NULL;
    int ok = 0;

    if (!kb) kb = LoadLibraryA("kernelbase.dll");
    pVirtualAlloc2 = kb ? (PFN_VirtualAlloc2)(void *)GetProcAddress(kb, "VirtualAlloc2") : NULL;
    pMapViewOfFile3 = kb ? (PFN_MapViewOfFile3)(void *)GetProcAddress(kb, "MapViewOfFile3") : NULL;
    if (!pVirtualAlloc2 || !pMapViewOfFile3)
    {
        printf("FAIL [map-view-4k-placeholder]: VirtualAlloc2/MapViewOfFile3 unavailable\n");
        return 1;
    }

    hMap = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, 0x10000, NULL);
    if (!hMap)
    {
        printf("FAIL [map-view-4k-placeholder]: CreateFileMappingA failed (%lu)\n", GetLastError());
        return 1;
    }

    base = (BYTE *)pVirtualAlloc2(GetCurrentProcess(), NULL, 0x10000,
                                  MEM_RESERVE | MEM_RESERVE_PLACEHOLDER, PAGE_NOACCESS, NULL, 0);
    if (!base)
    {
        printf("FAIL [map-view-4k-placeholder]: VirtualAlloc2 failed (%lu)\n", GetLastError());
        goto cleanup;
    }

    /* Split placeholder at 4KB boundary: [base, base+0x1000) and [base+0x1000, base+0x10000). */
    if (!VirtualFree(base, 0x1000, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER))
    {
        printf("FAIL [map-view-4k-placeholder]: VirtualFree(split 4KB) failed (%lu)\n", GetLastError());
        goto cleanup;
    }

    /* Map view at 4KB-aligned, non-16KB-aligned address base + 0x1000 (size 0xf000). */
    SetLastError(0);
    view = (BYTE *)pMapViewOfFile3(hMap, GetCurrentProcess(), base + 0x1000, 0x1000,
                                   0xf000, MEM_REPLACE_PLACEHOLDER, PAGE_READWRITE, NULL, 0);
    if (!view)
    {
        printf("FAIL [map-view-4k-placeholder]: MapViewOfFile3(base+0x1000) failed (err=%lu)\n",
               GetLastError());
        goto cleanup;
    }

    view[0] = 0x5a;
    if (view[0] != 0x5a)
    {
        printf("FAIL [map-view-4k-placeholder]: mapped 4KB view readback mismatch\n");
        goto cleanup;
    }

    printf("PASS [map-view-4k-placeholder]: MapViewOfFile3 succeeded at 4KB-aligned %p\n", view);
    ok = 1;

cleanup:
    if (view) UnmapViewOfFile(view);
    if (base)
    {
        VirtualFree(base, 0, MEM_RELEASE);
        VirtualFree(base + 0x1000, 0, MEM_RELEASE);
    }
    if (hMap) CloseHandle(hMap);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    int failures = 0;

    if (argc >= 2 && strcmp(argv[1], "--child") == 0)
        return run_child();

    failures += test_wpm_exec_rwx();
    failures += test_get_ctx_dr();
    failures += test_set_ctx_dr();
    failures += test_map_view_4k_placeholder();

    if (failures)
    {
        printf("SUMMARY: %d sub-case(s) FAILED\n", failures);
        return 1;
    }
    printf("SUMMARY: all 4 sub-cases PASSED\n");
    return 0;
}

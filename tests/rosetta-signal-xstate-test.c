/* Regression test for macOS / Rosetta 2 ntdll signal, XState, and fault fixes.
 *
 * Build 64-bit PE with x86_64-w64-mingw32-gcc:
 *   x86_64-w64-mingw32-gcc -O2 -mavx2 -Wall -Wextra \
 *     tests/rosetta-signal-xstate-test.c -o rosetta-signal-xstate-test.exe
 *
 * Covers:
 *  1. Privileged instructions (rdmsr / wrmsr) raise STATUS_PRIVILEGED_INSTRUCTION
 *     (0xC0000096), not STATUS_ACCESS_VIOLATION.
 *  2. Invalid %gs: memory access (`mov rax, gs:[0x12345678]`) raises
 *     STATUS_ACCESS_VIOLATION promptly instead of looping infinitely in
 *     check_invalid_gsbase() (tested in a child process with a 3s timeout).
 *  3. AVX2 YMM0/YMM7/YMM15 upper-128-bit preservation and modification across a
 *     VEH exception (requires ROSETTA_ADVERTISE_AVX=1 / AVX-capable CPU).
 *  4. AVX2 YMM0/YMM7/YMM15 capture via SuspendThread + GetThreadContext
 *     (CONTEXT_ALL | CONTEXT_XSTATE) and modification via SetThreadContext +
 *     ResumeThread.
 *  5. Write fault on a PAGE_READONLY page (including atomic RMW) reports
 *     EXCEPTION_WRITE_FAULT (1) in ExceptionRecord->ExceptionInformation[0].
 */
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef STATUS_PRIVILEGED_INSTRUCTION
#define STATUS_PRIVILEGED_INSTRUCTION ((DWORD)0xC0000096UL)
#endif
#ifndef PF_AVX_INSTRUCTIONS_AVAILABLE
#define PF_AVX_INSTRUCTIONS_AVAILABLE 39
#endif
#ifndef EXCEPTION_WRITE_FAULT
#define EXCEPTION_WRITE_FAULT 1
#endif

typedef DWORD64 (WINAPI *pfn_GetEnabledXStateFeatures)(void);
typedef BOOL (WINAPI *pfn_InitializeContext)(PVOID, DWORD, PCONTEXT *, PDWORD);
typedef BOOL (WINAPI *pfn_SetXStateFeaturesMask)(PCONTEXT, DWORD64);
typedef BOOL (WINAPI *pfn_GetXStateFeaturesMask)(PCONTEXT, PDWORD64);
typedef PVOID (WINAPI *pfn_LocateXStateFeature)(PCONTEXT, DWORD, PDWORD);

static pfn_GetEnabledXStateFeatures fn_GetEnabledXStateFeatures;
static pfn_InitializeContext        fn_InitializeContext;
static pfn_SetXStateFeaturesMask    fn_SetXStateFeaturesMask;
static pfn_GetXStateFeaturesMask    fn_GetXStateFeaturesMask;
static pfn_LocateXStateFeature      fn_LocateXStateFeature;

static int load_xstate_apis(void)
{
    HMODULE k32 = GetModuleHandleA("kernel32.dll");
    if (!k32) return 0;
    fn_GetEnabledXStateFeatures = (pfn_GetEnabledXStateFeatures)(void *)GetProcAddress(k32, "GetEnabledXStateFeatures");
    fn_InitializeContext        = (pfn_InitializeContext)(void *)GetProcAddress(k32, "InitializeContext");
    fn_SetXStateFeaturesMask    = (pfn_SetXStateFeaturesMask)(void *)GetProcAddress(k32, "SetXStateFeaturesMask");
    fn_GetXStateFeaturesMask    = (pfn_GetXStateFeaturesMask)(void *)GetProcAddress(k32, "GetXStateFeaturesMask");
    fn_LocateXStateFeature      = (pfn_LocateXStateFeature)(void *)GetProcAddress(k32, "LocateXStateFeature");
    return fn_GetEnabledXStateFeatures && fn_InitializeContext &&
           fn_SetXStateFeaturesMask && fn_GetXStateFeaturesMask &&
           fn_LocateXStateFeature;
}

/* =========================================================================
 * Case 1: rdmsr / wrmsr must raise STATUS_PRIVILEGED_INSTRUCTION
 * ========================================================================= */
static volatile DWORD64 g_priv_fault_ip = 0;
static volatile DWORD64 g_priv_resume_ip = 0;
static volatile DWORD   g_priv_exc_code = 0;

static LONG CALLBACK priv_veh(EXCEPTION_POINTERS *ep)
{
    if (ep->ContextRecord->Rip == g_priv_fault_ip)
    {
        g_priv_exc_code = ep->ExceptionRecord->ExceptionCode;
        ep->ContextRecord->Rip = g_priv_resume_ip;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static __attribute__((noinline)) DWORD run_rdmsr(void)
{
    g_priv_exc_code = 0;
    __asm__ __volatile__(
        "leaq 1f(%%rip), %%rax\n\t"
        "movq %%rax, %0\n\t"
        "leaq 2f(%%rip), %%rax\n\t"
        "movq %%rax, %1\n\t"
        "movl $0x10, %%ecx\n\t"
        "1:\n\t"
        "rdmsr\n\t"
        "2:\n\t"
        : "=m"(g_priv_fault_ip), "=m"(g_priv_resume_ip)
        :
        : "rax", "rcx", "rdx", "memory"
    );
    g_priv_fault_ip = 0;
    return g_priv_exc_code;
}

static __attribute__((noinline)) DWORD run_wrmsr(void)
{
    g_priv_exc_code = 0;
    __asm__ __volatile__(
        "leaq 1f(%%rip), %%rax\n\t"
        "movq %%rax, %0\n\t"
        "leaq 2f(%%rip), %%rax\n\t"
        "movq %%rax, %1\n\t"
        "movl $0x10, %%ecx\n\t"
        "xorl %%eax, %%eax\n\t"
        "xorl %%edx, %%edx\n\t"
        "1:\n\t"
        "wrmsr\n\t"
        "2:\n\t"
        : "=m"(g_priv_fault_ip), "=m"(g_priv_resume_ip)
        :
        : "rax", "rcx", "rdx", "memory"
    );
    g_priv_fault_ip = 0;
    return g_priv_exc_code;
}

static int test_privileged_msr(void)
{
    void *veh = AddVectoredExceptionHandler(1, priv_veh);
    DWORD rd_code, wr_code;
    int fail = 0;

    if (!veh)
    {
        printf("FAIL: priv_msr: AddVectoredExceptionHandler failed\n");
        return 1;
    }

    rd_code = run_rdmsr();
    wr_code = run_wrmsr();
    RemoveVectoredExceptionHandler(veh);

    if (rd_code != STATUS_PRIVILEGED_INSTRUCTION)
    {
        printf("FAIL: priv_rdmsr: got 0x%08lx, expected STATUS_PRIVILEGED_INSTRUCTION (0x%08lx)\n",
               (unsigned long)rd_code, (unsigned long)STATUS_PRIVILEGED_INSTRUCTION);
        fail = 1;
    }
    else
    {
        printf("PASS: priv_rdmsr: raised STATUS_PRIVILEGED_INSTRUCTION (0x%08lx)\n",
               (unsigned long)rd_code);
    }

    if (wr_code != STATUS_PRIVILEGED_INSTRUCTION)
    {
        printf("FAIL: priv_wrmsr: got 0x%08lx, expected STATUS_PRIVILEGED_INSTRUCTION (0x%08lx)\n",
               (unsigned long)wr_code, (unsigned long)STATUS_PRIVILEGED_INSTRUCTION);
        fail = 1;
    }
    else
    {
        printf("PASS: priv_wrmsr: raised STATUS_PRIVILEGED_INSTRUCTION (0x%08lx)\n",
               (unsigned long)wr_code);
    }

    return fail;
}

/* =========================================================================
 * Case 2: Invalid %gs: access must raise EXCEPTION_ACCESS_VIOLATION promptly
 * ========================================================================= */
static volatile DWORD64 g_gs_fault_ip = 0;
static volatile DWORD64 g_gs_resume_ip = 0;
static volatile DWORD   g_gs_exc_code = 0;
static volatile LONG    g_gs_caught = 0;

static LONG CALLBACK gs_veh(EXCEPTION_POINTERS *ep)
{
    if (ep->ContextRecord->Rip == g_gs_fault_ip)
    {
        g_gs_exc_code = ep->ExceptionRecord->ExceptionCode;
        InterlockedIncrement(&g_gs_caught);
        ep->ContextRecord->Rip = g_gs_resume_ip;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static __attribute__((noinline)) int run_gs_child(void)
{
    void *veh = AddVectoredExceptionHandler(1, gs_veh);
    if (!veh) return 2;

    __asm__ __volatile__(
        "leaq 1f(%%rip), %%rax\n\t"
        "movq %%rax, %0\n\t"
        "leaq 2f(%%rip), %%rax\n\t"
        "movq %%rax, %1\n\t"
        "1:\n\t"
        "movq %%gs:0x12345678, %%rax\n\t"
        "2:\n\t"
        : "=m"(g_gs_fault_ip), "=m"(g_gs_resume_ip)
        :
        : "rax", "memory"
    );

    g_gs_fault_ip = 0;
    RemoveVectoredExceptionHandler(veh);

    if (g_gs_caught != 1 || g_gs_exc_code != EXCEPTION_ACCESS_VIOLATION)
        return 3;
    return 0;
}

static int test_gs_invalid_offset(void)
{
    char exe_path[MAX_PATH];
    char cmdline[MAX_PATH + 32];
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    DWORD wait_res, exit_code = 1;

    if (!GetModuleFileNameA(NULL, exe_path, sizeof(exe_path)))
    {
        printf("FAIL: gs_invalid_offset: GetModuleFileNameA failed (%lu)\n", GetLastError());
        return 1;
    }

    snprintf(cmdline, sizeof(cmdline), "\"%s\" --gs-child", exe_path);
    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    memset(&pi, 0, sizeof(pi));

    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
    {
        printf("FAIL: gs_invalid_offset: CreateProcessA failed (%lu)\n", GetLastError());
        return 1;
    }

    wait_res = WaitForSingleObject(pi.hProcess, 3000);
    if (wait_res == WAIT_TIMEOUT)
    {
        TerminateProcess(pi.hProcess, 124);
        WaitForSingleObject(pi.hProcess, 2000);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        printf("FAIL: gs_invalid_offset: TIMEOUT/HANG after 3000ms (check_invalid_gsbase infinite loop)\n");
        return 1;
    }

    GetExitCodeProcess(pi.hProcess, &exit_code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    if (wait_res != WAIT_OBJECT_0 || exit_code != 0)
    {
        printf("FAIL: gs_invalid_offset: child wait=%lu exit=%lu\n",
               (unsigned long)wait_res, (unsigned long)exit_code);
        return 1;
    }

    printf("PASS: gs_invalid_offset: raised EXCEPTION_ACCESS_VIOLATION promptly\n");
    return 0;
}

/* =========================================================================
 * Case 3: AVX2 YMM0/YMM7/YMM15 preservation & modification across VEH
 * ========================================================================= */
static const uint64_t g_ymm0_in[4]  = {
    0x1111111122222222ULL, 0x3333333344444444ULL,
    0x5555555566666666ULL, 0x7777777788888888ULL
};
static const uint64_t g_ymm7_in[4]  = {
    0x0123456789abcdefULL, 0xfedcba9876543210ULL,
    0xdeadbeefcafebabeULL, 0x13579bdf2468ace0ULL
};
static const uint64_t g_ymm15_in[4] = {
    0xaaaaaaaaaaaaaaaaULL, 0xbbbbbbbbbbbbbbbbULL,
    0xccccccccccccccccULL, 0xddddddddddddddddULL
};
static const uint64_t g_ymm0_mod_hi[2] = {
    0xa5a5a5a55a5a5a5aULL, 0x0f0f0f0ff0f0f0f0ULL
};

static volatile DWORD64 g_avx_fault_ip = 0;
static volatile DWORD64 g_avx_resume_ip = 0;
static volatile int     g_avx_veh_seen = 0;
static volatile int     g_avx_veh_ok = 0;
static char             g_avx_veh_err[256];

static LONG CALLBACK avx_veh(EXCEPTION_POINTERS *ep)
{
    if (ep->ContextRecord->Rip == g_avx_fault_ip)
    {
        CONTEXT *ctx = ep->ContextRecord;
        DWORD len = 0;
        DWORD64 mask = 0;
        M128A *ymmh;

        g_avx_veh_seen = 1;
        g_avx_veh_ok = 0;

        if ((ctx->ContextFlags & CONTEXT_XSTATE) != CONTEXT_XSTATE)
        {
            snprintf(g_avx_veh_err, sizeof(g_avx_veh_err),
                     "CONTEXT_XSTATE not set (ContextFlags=0x%08lx)",
                     (unsigned long)ctx->ContextFlags);
        }
        else if (!fn_GetXStateFeaturesMask(ctx, &mask) || !(mask & XSTATE_MASK_AVX))
        {
            snprintf(g_avx_veh_err, sizeof(g_avx_veh_err),
                     "XSTATE_MASK_AVX missing in mask=0x%llx",
                     (unsigned long long)mask);
        }
        else if (!(ymmh = (M128A *)fn_LocateXStateFeature(ctx, XSTATE_AVX, &len)) ||
                 len < 16 * sizeof(M128A))
        {
            snprintf(g_avx_veh_err, sizeof(g_avx_veh_err),
                     "LocateXStateFeature(XSTATE_AVX) failed (ptr=%p len=%lu)",
                     (void *)ymmh, (unsigned long)len);
        }
        else if ((uint64_t)ymmh[0].Low != g_ymm0_in[2] || (uint64_t)ymmh[0].High != g_ymm0_in[3] ||
                 (uint64_t)ymmh[7].Low != g_ymm7_in[2] || (uint64_t)ymmh[7].High != g_ymm7_in[3] ||
                 (uint64_t)ymmh[15].Low != g_ymm15_in[2] || (uint64_t)ymmh[15].High != g_ymm15_in[3])
        {
            snprintf(g_avx_veh_err, sizeof(g_avx_veh_err),
                     "YMMH mismatch in VEH: ymm0=(%016llx,%016llx) ymm7=(%016llx,%016llx) ymm15=(%016llx,%016llx)",
                     (unsigned long long)ymmh[0].Low, (unsigned long long)ymmh[0].High,
                     (unsigned long long)ymmh[7].Low, (unsigned long long)ymmh[7].High,
                     (unsigned long long)ymmh[15].Low, (unsigned long long)ymmh[15].High);
        }
        else
        {
            /* Modify YMM0 upper 128 bits in the exception context. */
            ymmh[0].Low  = g_ymm0_mod_hi[0];
            ymmh[0].High = (LONGLONG)g_ymm0_mod_hi[1];
            g_avx_veh_ok = 1;
        }

        ctx->Rip = g_avx_resume_ip;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static __attribute__((noinline)) void avx_fault_probe(
    const uint64_t *in0, const uint64_t *in7, const uint64_t *in15,
    uint64_t *out0, uint64_t *out7, uint64_t *out15)
{
    __asm__ __volatile__(
        "leaq 1f(%%rip), %%rax\n\t"
        "movq %%rax, %0\n\t"
        "leaq 2f(%%rip), %%rax\n\t"
        "movq %%rax, %1\n\t"
        "vmovdqu (%2), %%ymm0\n\t"
        "vmovdqu (%3), %%ymm7\n\t"
        "vmovdqu (%4), %%ymm15\n\t"
        "xorl %%eax, %%eax\n\t"
        "1:\n\t"
        "movl (%%rax), %%eax\n\t"
        "2:\n\t"
        "vmovdqu %%ymm0, (%5)\n\t"
        "vmovdqu %%ymm7, (%6)\n\t"
        "vmovdqu %%ymm15, (%7)\n\t"
        "vzeroupper\n\t"
        : "=m"(g_avx_fault_ip), "=m"(g_avx_resume_ip)
        : "r"(in0), "r"(in7), "r"(in15), "r"(out0), "r"(out7), "r"(out15)
        : "rax", "ymm0", "ymm7", "ymm15", "memory"
    );
    g_avx_fault_ip = 0;
}

static int test_avx_veh_xstate(void)
{
    uint64_t out0[4] = {0}, out7[4] = {0}, out15[4] = {0};
    void *veh;

    g_avx_veh_seen = 0;
    g_avx_veh_ok = 0;
    g_avx_veh_err[0] = '\0';

    veh = AddVectoredExceptionHandler(1, avx_veh);
    if (!veh)
    {
        printf("FAIL: avx_veh_xstate: AddVectoredExceptionHandler failed\n");
        return 1;
    }

    avx_fault_probe(g_ymm0_in, g_ymm7_in, g_ymm15_in, out0, out7, out15);
    RemoveVectoredExceptionHandler(veh);

    if (!g_avx_veh_seen)
    {
        printf("FAIL: avx_veh_xstate: VEH was not invoked\n");
        return 1;
    }
    if (!g_avx_veh_ok)
    {
        printf("FAIL: avx_veh_xstate: %s\n", g_avx_veh_err);
        return 1;
    }
    if (out0[0] != g_ymm0_in[0] || out0[1] != g_ymm0_in[1] ||
        out0[2] != g_ymm0_mod_hi[0] || out0[3] != g_ymm0_mod_hi[1])
    {
        printf("FAIL: avx_veh_xstate: resumed YMM0 mismatch: (%016llx,%016llx,%016llx,%016llx)\n",
               (unsigned long long)out0[0], (unsigned long long)out0[1],
               (unsigned long long)out0[2], (unsigned long long)out0[3]);
        return 1;
    }
    if (memcmp(out7, g_ymm7_in, sizeof(out7)) != 0 ||
        memcmp(out15, g_ymm15_in, sizeof(out15)) != 0)
    {
        printf("FAIL: avx_veh_xstate: resumed YMM7/YMM15 corrupted\n");
        return 1;
    }

    printf("PASS: avx_veh_xstate: YMM0/YMM7/YMM15 captured, YMM0 upper modified & resumed\n");
    return 0;
}

/* =========================================================================
 * Case 4: SuspendThread + GetThreadContext/SetThreadContext(CONTEXT_XSTATE)
 * ========================================================================= */
struct suspend_worker_args
{
    volatile LONG ready;
    volatile LONG stop;
    uint64_t out0[4];
    uint64_t out7[4];
    uint64_t out15[4];
};

static __attribute__((noinline)) void spin_with_ymm(
    const uint64_t *in0, const uint64_t *in7, const uint64_t *in15,
    struct suspend_worker_args *a)
{
    __asm__ __volatile__(
        "vmovdqu (%0), %%ymm0\n\t"
        "vmovdqu (%1), %%ymm7\n\t"
        "vmovdqu (%2), %%ymm15\n\t"
        "movl $1, (%3)\n\t"
        "1:\n\t"
        "pause\n\t"
        "cmpl $0, (%4)\n\t"
        "je 1b\n\t"
        "vmovdqu %%ymm0, (%5)\n\t"
        "vmovdqu %%ymm7, (%6)\n\t"
        "vmovdqu %%ymm15, (%7)\n\t"
        "vzeroupper\n\t"
        :
        : "r"(in0), "r"(in7), "r"(in15),
          "r"(&a->ready), "r"(&a->stop),
          "r"(a->out0), "r"(a->out7), "r"(a->out15)
        : "ymm0", "ymm7", "ymm15", "cc", "memory"
    );
}

static DWORD WINAPI avx_suspend_worker(void *param)
{
    struct suspend_worker_args *a = (struct suspend_worker_args *)param;
    spin_with_ymm(g_ymm0_in, g_ymm7_in, g_ymm15_in, a);
    return 0;
}

static int test_avx_suspend_getcontext(void)
{
    struct suspend_worker_args args;
    HANDLE th;
    BYTE ctx_buf[4096] __attribute__((aligned(64)));
    DWORD ctx_len = sizeof(ctx_buf);
    CONTEXT *ctx = NULL;
    DWORD len = 0;
    DWORD64 mask = 0;
    M128A *ymmh;
    int tries, fail = 0;

    memset(&args, 0, sizeof(args));
    th = CreateThread(NULL, 0, avx_suspend_worker, &args, 0, NULL);
    if (!th)
    {
        printf("FAIL: avx_suspend_context: CreateThread failed (%lu)\n", GetLastError());
        return 1;
    }

    for (tries = 0; tries < 500 && !InterlockedCompareExchange(&args.ready, 0, 0); tries++)
        Sleep(1);
    if (!InterlockedCompareExchange(&args.ready, 0, 0))
    {
        printf("FAIL: avx_suspend_context: worker did not reach ready state\n");
        InterlockedExchange(&args.stop, 1);
        WaitForSingleObject(th, 2000);
        CloseHandle(th);
        return 1;
    }
    /* Give the worker a moment to enter the tight usermode spin loop. */
    Sleep(5);

    if (SuspendThread(th) == (DWORD)-1)
    {
        printf("FAIL: avx_suspend_context: SuspendThread failed (%lu)\n", GetLastError());
        InterlockedExchange(&args.stop, 1);
        WaitForSingleObject(th, 2000);
        CloseHandle(th);
        return 1;
    }

    if (!fn_InitializeContext(ctx_buf, CONTEXT_ALL | CONTEXT_XSTATE, &ctx, &ctx_len) ||
        !fn_SetXStateFeaturesMask(ctx, XSTATE_MASK_AVX))
    {
        printf("FAIL: avx_suspend_context: InitializeContext/SetXStateFeaturesMask failed (%lu)\n",
               GetLastError());
        fail = 1;
    }
    else if (!GetThreadContext(th, ctx))
    {
        printf("FAIL: avx_suspend_context: GetThreadContext failed (%lu)\n", GetLastError());
        fail = 1;
    }
    else if (!fn_GetXStateFeaturesMask(ctx, &mask) || !(mask & XSTATE_MASK_AVX))
    {
        printf("FAIL: avx_suspend_context: GetThreadContext XSTATE_MASK_AVX missing (mask=0x%llx)\n",
               (unsigned long long)mask);
        fail = 1;
    }
    else if (!(ymmh = (M128A *)fn_LocateXStateFeature(ctx, XSTATE_AVX, &len)) ||
             len < 16 * sizeof(M128A))
    {
        printf("FAIL: avx_suspend_context: LocateXStateFeature failed (ptr=%p len=%lu)\n",
               (void *)ymmh, (unsigned long)len);
        fail = 1;
    }
    else if ((uint64_t)ymmh[0].Low != g_ymm0_in[2] || (uint64_t)ymmh[0].High != g_ymm0_in[3] ||
             (uint64_t)ymmh[7].Low != g_ymm7_in[2] || (uint64_t)ymmh[7].High != g_ymm7_in[3] ||
             (uint64_t)ymmh[15].Low != g_ymm15_in[2] || (uint64_t)ymmh[15].High != g_ymm15_in[3])
    {
        printf("FAIL: avx_suspend_context: YMMH mismatch: ymm0=(%016llx,%016llx) ymm7=(%016llx,%016llx) ymm15=(%016llx,%016llx)\n",
               (unsigned long long)ymmh[0].Low, (unsigned long long)ymmh[0].High,
               (unsigned long long)ymmh[7].Low, (unsigned long long)ymmh[7].High,
               (unsigned long long)ymmh[15].Low, (unsigned long long)ymmh[15].High);
        fail = 1;
    }
    else
    {
        /* Also test SetThreadContext modifying YMM0 upper 128 bits across suspend/resume. */
        ymmh[0].Low  = g_ymm0_mod_hi[0];
        ymmh[0].High = (LONGLONG)g_ymm0_mod_hi[1];
        if (!SetThreadContext(th, ctx))
        {
            printf("FAIL: avx_suspend_context: SetThreadContext failed (%lu)\n", GetLastError());
            fail = 1;
        }
    }

    ResumeThread(th);
    InterlockedExchange(&args.stop, 1);
    if (WaitForSingleObject(th, 3000) != WAIT_OBJECT_0)
    {
        printf("FAIL: avx_suspend_context: worker timed out on exit\n");
        CloseHandle(th);
        return 1;
    }
    CloseHandle(th);

    if (!fail)
    {
        if (args.out0[0] != g_ymm0_in[0] || args.out0[1] != g_ymm0_in[1] ||
            args.out0[2] != g_ymm0_mod_hi[0] || args.out0[3] != g_ymm0_mod_hi[1])
        {
            printf("FAIL: avx_suspend_context: resumed worker YMM0 mismatch: (%016llx,%016llx,%016llx,%016llx)\n",
                   (unsigned long long)args.out0[0], (unsigned long long)args.out0[1],
                   (unsigned long long)args.out0[2], (unsigned long long)args.out0[3]);
            fail = 1;
        }
        else if (memcmp(args.out7, g_ymm7_in, sizeof(args.out7)) != 0 ||
                 memcmp(args.out15, g_ymm15_in, sizeof(args.out15)) != 0)
        {
            printf("FAIL: avx_suspend_context: resumed worker YMM7/YMM15 corrupted\n");
            fail = 1;
        }
    }

    if (!fail)
        printf("PASS: avx_suspend_context: SuspendThread Get/SetThreadContext YMM0/YMM7/YMM15 verified\n");
    return fail;
}

/* =========================================================================
 * Case 5: PAGE_READONLY write fault reports EXCEPTION_WRITE_FAULT (1)
 * ========================================================================= */
static volatile DWORD64   g_ro_fault_ip = 0;
static volatile DWORD64   g_ro_resume_ip = 0;
static volatile DWORD     g_ro_exc_code = 0;
static volatile ULONG_PTR g_ro_fault_type = (ULONG_PTR)-1;

static LONG CALLBACK ro_write_veh(EXCEPTION_POINTERS *ep)
{
    if (ep->ContextRecord->Rip == g_ro_fault_ip)
    {
        g_ro_exc_code = ep->ExceptionRecord->ExceptionCode;
        g_ro_fault_type = (ep->ExceptionRecord->NumberParameters >= 1)
                          ? ep->ExceptionRecord->ExceptionInformation[0]
                          : (ULONG_PTR)-1;
        ep->ContextRecord->Rip = g_ro_resume_ip;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static __attribute__((noinline)) void run_ro_store(volatile DWORD *p)
{
    g_ro_exc_code = 0;
    g_ro_fault_type = (ULONG_PTR)-1;
    __asm__ __volatile__(
        "leaq 1f(%%rip), %%rax\n\t"
        "movq %%rax, %0\n\t"
        "leaq 2f(%%rip), %%rax\n\t"
        "movq %%rax, %1\n\t"
        "1:\n\t"
        "movl $0x12345678, (%2)\n\t"
        "2:\n\t"
        : "=m"(g_ro_fault_ip), "=m"(g_ro_resume_ip)
        : "r"(p)
        : "rax", "memory"
    );
    g_ro_fault_ip = 0;
}

static __attribute__((noinline)) void run_ro_lock_xadd(volatile DWORD *p)
{
    g_ro_exc_code = 0;
    g_ro_fault_type = (ULONG_PTR)-1;
    __asm__ __volatile__(
        "leaq 1f(%%rip), %%rax\n\t"
        "movq %%rax, %0\n\t"
        "leaq 2f(%%rip), %%rax\n\t"
        "movq %%rax, %1\n\t"
        "movl $1, %%eax\n\t"
        "1:\n\t"
        "lock xaddl %%eax, (%2)\n\t"
        "2:\n\t"
        : "=m"(g_ro_fault_ip), "=m"(g_ro_resume_ip)
        : "r"(p)
        : "rax", "cc", "memory"
    );
    g_ro_fault_ip = 0;
}

static int test_ro_write_fault_type(void)
{
    BYTE *base;
    DWORD old_prot = 0;
    volatile DWORD *ro_page;
    volatile DWORD *straddle_ptr;
    void *veh;
    int fail = 0;

    /* Allocate 2 contiguous pages: page 0 is RW, page 1 is RO.
     * Under Rosetta 2 on Apple Silicon, an atomic RMW (`lock xaddl`) straddling
     * the RW -> RO page boundary triggers a fault that Rosetta reports as a read
     * fault on the readable RO page; virtual_handle_fault() must fix up
     * ExceptionInformation[0] to EXCEPTION_WRITE_FAULT (1). */
    base = (BYTE *)VirtualAlloc(NULL, 8192, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!base)
    {
        printf("FAIL: ro_write_fault: VirtualAlloc failed (%lu)\n", GetLastError());
        return 1;
    }
    if (!VirtualProtect(base + 4096, 4096, PAGE_READONLY, &old_prot))
    {
        VirtualFree(base, 0, MEM_RELEASE);
        printf("FAIL: ro_write_fault: VirtualProtect failed (%lu)\n", GetLastError());
        return 1;
    }
    ro_page = (volatile DWORD *)(base + 4096);
    straddle_ptr = (volatile DWORD *)(base + 4094);

    veh = AddVectoredExceptionHandler(1, ro_write_veh);
    if (!veh)
    {
        VirtualFree(base, 0, MEM_RELEASE);
        printf("FAIL: ro_write_fault: AddVectoredExceptionHandler failed\n");
        return 1;
    }

    run_ro_store(ro_page);
    if (g_ro_exc_code != EXCEPTION_ACCESS_VIOLATION || g_ro_fault_type != EXCEPTION_WRITE_FAULT)
    {
        printf("FAIL: ro_write_store: code=0x%08lx info[0]=%llu (expected AV + WRITE_FAULT=1)\n",
               (unsigned long)g_ro_exc_code, (unsigned long long)g_ro_fault_type);
        fail = 1;
    }
    else
    {
        printf("PASS: ro_write_store: AV with EXCEPTION_WRITE_FAULT (1)\n");
    }

    run_ro_lock_xadd(straddle_ptr);
    if (g_ro_exc_code != EXCEPTION_ACCESS_VIOLATION || g_ro_fault_type != EXCEPTION_WRITE_FAULT)
    {
        printf("FAIL: ro_write_straddle_lock_xadd: code=0x%08lx info[0]=%llu (expected AV + WRITE_FAULT=1)\n",
               (unsigned long)g_ro_exc_code, (unsigned long long)g_ro_fault_type);
        fail = 1;
    }
    else
    {
        printf("PASS: ro_write_straddle_lock_xadd: AV with EXCEPTION_WRITE_FAULT (1)\n");
    }

    RemoveVectoredExceptionHandler(veh);
    VirtualFree(base, 0, MEM_RELEASE);
    return fail;
}

int main(int argc, char **argv)
{
    int failures = 0;

    if (argc > 1 && strcmp(argv[1], "--gs-child") == 0)
        return run_gs_child();

    setvbuf(stdout, NULL, _IONBF, 0);

    failures += test_privileged_msr();
    failures += test_gs_invalid_offset();
    failures += test_ro_write_fault_type();

    if (!IsProcessorFeaturePresent(PF_AVX_INSTRUCTIONS_AVAILABLE))
    {
        printf("SKIP: avx_xstate: PF_AVX_INSTRUCTIONS_AVAILABLE is false\n");
    }
    else if (!load_xstate_apis())
    {
        printf("FAIL: avx_xstate: XState kernel32 APIs unavailable\n");
        failures++;
    }
    else if (!(fn_GetEnabledXStateFeatures() & XSTATE_MASK_AVX))
    {
        printf("FAIL: avx_xstate: AVX available but GetEnabledXStateFeatures()=0x%llx lacks XSTATE_MASK_AVX\n",
               (unsigned long long)fn_GetEnabledXStateFeatures());
        failures++;
    }
    else
    {
        failures += test_avx_veh_xstate();
        failures += test_avx_suspend_getcontext();
    }

    printf("SUMMARY: %s (failures=%d)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}

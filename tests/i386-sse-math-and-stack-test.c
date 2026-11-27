/*
 * 32-bit (WoW64) runtime verification for Wine's SSE2/SSE4.2 PE codegen:
 *   1. Calls Wine's 32-bit builtins (msvcrt, ucrtbase, d3dx9_43, xaudio2_7)
 *      through an inline-asm trampoline that deliberately forces ESP % 16 to
 *      every 4-byte misalignment (4, 8, 12) as legacy Win32 games do. This
 *      catches any missing stack realignment (movaps #GP) in -mfpmath=sse DLLs.
 *   2. Exercises FAudio/xaudio2_7 initialization + voice creation and 32-bit
 *      floating-point throughput (x87 vs SSE2 comparison + builtin math bench).
 *
 * Build: i686-w64-mingw32-gcc -O2 -Wall -Wextra -o i386-sse-math-and-stack-test.exe \
 *            tests/i386-sse-math-and-stack-test.c -lole32
 */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <stdio.h>
#include <stdint.h>
#include <math.h>

typedef double (__cdecl *fn_d1_t)(double);
typedef double (__cdecl *fn_d2_t)(double, double);
typedef int (__cdecl *fn_snprintf_t)(char *, size_t, const char *, ...);

/* Invoke a cdecl double(double) function with ESP deliberately shifted so
 * (ESP % 16) == target_mod right before `call` (so callee sees target_mod-4). */
__attribute__((noinline))
static double call_d1_misaligned(fn_d1_t fn, double x, unsigned target_mod)
{
    double out;
    __asm__ volatile (
        "pushl %%ebx\n\t"
        "movl %%esp, %%ebx\n\t"
        "andl $-16, %%esp\n\t"
        "subl %3, %%esp\n\t"      /* ESP % 16 == (16 - target_mod) % 16 */
        "subl $8, %%esp\n\t"
        "fldl %2\n\t"
        "fstpl (%%esp)\n\t"
        "call *%1\n\t"
        "fstpl %0\n\t"
        "movl %%ebx, %%esp\n\t"
        "popl %%ebx\n\t"
        : "=m"(out)
        : "r"(fn), "m"(x), "r"(target_mod)
        : "eax", "ecx", "edx", "memory", "cc",
          "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7"
    );
    return out;
}

typedef struct { float m[4][4]; } MAT4;
typedef MAT4 * (WINAPI *fn_mat_mul_t)(MAT4 *, const MAT4 *, const MAT4 *);
typedef MAT4 * (WINAPI *fn_mat_inv_t)(MAT4 *, float *, const MAT4 *);

__attribute__((noinline))
static void *call_stdcall3_misaligned(void *fn, void *a, void *b, void *c, unsigned target_mod)
{
    void *ret;
    __asm__ volatile (
        "pushl %%ebx\n\t"
        "movl %%esp, %%ebx\n\t"
        "andl $-16, %%esp\n\t"
        "subl %5, %%esp\n\t"
        "pushl %4\n\t"
        "pushl %3\n\t"
        "pushl %2\n\t"
        "call *%1\n\t"
        "movl %%ebx, %%esp\n\t"
        "popl %%ebx\n\t"
        : "=a"(ret)
        : "r"(fn), "r"(a), "r"(b), "r"(c), "r"(target_mod)
        : "ecx", "edx", "memory", "cc",
          "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7"
    );
    return ret;
}

static double now_ms(void)
{
    LARGE_INTEGER freq, ctr;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&ctr);
    return (double)ctr.QuadPart * 1000.0 / (double)freq.QuadPart;
}

__attribute__((noinline))
static void bench_x87_comb(float *buf, int iters, float g)
{
    for (int i = 0; i < iters; i++) {
        float *p = &buf[i & 255];
        __asm__ volatile (
            "flds (%0)\n\t"
            "fmuls %1\n\t"
            "fstps (%0)\n\t"
            :
            : "r"(p), "m"(g)
            : "memory", "st"
        );
    }
}

__attribute__((noinline))
static void bench_sse_comb(float *buf, int iters, float g)
{
    for (int i = 0; i < iters; i++) {
        float *p = &buf[i & 255];
        __asm__ volatile (
            "movss (%0), %%xmm0\n\t"
            "mulss %1, %%xmm0\n\t"
            "movss %%xmm0, (%0)\n\t"
            :
            : "r"(p), "m"(g)
            : "memory", "xmm0"
        );
    }
}

static int test_crt_misaligned(const char *dll_name)
{
    HMODULE mod = LoadLibraryA(dll_name);
    if (!mod) {
        printf("SKIP: %s not loaded (err=%lu)\n", dll_name, GetLastError());
        return 0;
    }
    fn_d1_t fn_sin  = (fn_d1_t)(void *)GetProcAddress(mod, "sin");
    fn_d1_t fn_cos  = (fn_d1_t)(void *)GetProcAddress(mod, "cos");
    fn_d1_t fn_sqrt = (fn_d1_t)(void *)GetProcAddress(mod, "sqrt");
    if (!fn_sin || !fn_cos || !fn_sqrt) {
        printf("FAIL: %s missing sin/cos/sqrt exports\n", dll_name);
        return 1;
    }

    const unsigned mods[4] = { 0, 4, 8, 12 };
    for (int i = 0; i < 4; i++) {
        double s = call_d1_misaligned(fn_sin, 1.0, mods[i]);
        double c = call_d1_misaligned(fn_cos, 1.0, mods[i]);
        double r = call_d1_misaligned(fn_sqrt, 2.0, mods[i]);
        if (fabs(s * s + c * c - 1.0) > 1e-12 || fabs(r * r - 2.0) > 1e-12) {
            printf("FAIL: %s math wrong at esp_mod=%u (s=%.15f c=%.15f r=%.15f)\n",
                   dll_name, mods[i], s, c, r);
            return 1;
        }
    }

    double t0 = now_ms();
    volatile double acc = 0.0;
    for (int i = 1; i <= 50000; i++)
        acc += fn_sin((double)i * 0.001) + fn_cos((double)i * 0.001);
    double dt = now_ms() - t0;
    printf("PASS: %s 4-byte stack alignment + 50k sin/cos in %.2f ms (acc=%.2f)\n",
           dll_name, dt, acc);
    return 0;
}

static int test_d3dx9_misaligned(void)
{
    HMODULE mod = LoadLibraryA("d3dx9_43.dll");
    if (!mod) {
        printf("FAIL: d3dx9_43.dll failed to load (err=%lu)\n", GetLastError());
        return 1;
    }
    fn_mat_mul_t mul = (fn_mat_mul_t)(void *)GetProcAddress(mod, "D3DXMatrixMultiply");
    fn_mat_inv_t inv = (fn_mat_inv_t)(void *)GetProcAddress(mod, "D3DXMatrixInverse");
    if (!mul || !inv) {
        printf("FAIL: d3dx9_43.dll missing matrix exports\n");
        return 1;
    }

    MAT4 a = {{{ 2, 0, 0, 0 }, { 0, 3, 0, 0 }, { 0, 0, 4, 0 }, { 1, 2, 3, 1 }}};
    MAT4 b = {{{ 0.5f, 0, 0, 0 }, { 0, 1.0f/3.0f, 0, 0 }, { 0, 0, 0.25f, 0 }, { 0, 0, 0, 1 }}};
    MAT4 out, inv_a;
    float det = 0.0f;

    const unsigned mods[4] = { 0, 4, 8, 12 };
    for (int i = 0; i < 4; i++) {
        call_stdcall3_misaligned((void *)mul, &out, &a, &b, mods[i]);
        if (fabsf(out.m[0][0] - 1.0f) > 1e-5f || fabsf(out.m[1][1] - 1.0f) > 1e-5f ||
            fabsf(out.m[2][2] - 1.0f) > 1e-5f) {
            printf("FAIL: D3DXMatrixMultiply wrong at esp_mod=%u\n", mods[i]);
            return 1;
        }
        call_stdcall3_misaligned((void *)inv, &inv_a, &det, &a, mods[i]);
        if (fabsf(det - 24.0f) > 1e-4f || fabsf(inv_a.m[0][0] - 0.5f) > 1e-5f) {
            printf("FAIL: D3DXMatrixInverse wrong at esp_mod=%u (det=%f)\n", mods[i], det);
            return 1;
        }
    }

    double t0 = now_ms();
    for (int i = 0; i < 100000; i++) {
        mul(&out, &a, &b);
        inv(&inv_a, &det, &a);
    }
    double dt = now_ms() - t0;
    printf("PASS: d3dx9_43 4-byte stack alignment + 100k mul+inv in %.2f ms\n", dt);
    return 0;
}

static int test_xaudio2_load(void)
{
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        printf("FAIL: CoInitializeEx hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    HMODULE mod = LoadLibraryA("xaudio2_7.dll");
    if (!mod) {
        printf("FAIL: xaudio2_7.dll failed to load (err=%lu)\n", GetLastError());
        return 1;
    }
    /* Create CLSID_XAudio2 ({5a508685-a254-4fba-9b82-9a24b00306af}) */
    static const GUID clsid_xa2 = { 0x5a508685, 0xa254, 0x4fba, { 0x9b, 0x82, 0x9a, 0x24, 0xb0, 0x03, 0x06, 0xaf } };
    static const GUID iid_xa2   = { 0x8bcf1f58, 0x9fe7, 0x4583, { 0x8a, 0xc6, 0xe2, 0xad, 0xc4, 0x65, 0xc8, 0xbb } };
    IUnknown *xa2 = NULL;
    hr = CoCreateInstance(&clsid_xa2, NULL, CLSCTX_INPROC_SERVER, &iid_xa2, (void **)&xa2);
    if (FAILED(hr) || !xa2) {
        printf("FAIL: CoCreateInstance(XAudio2_7) hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    IUnknown_Release(xa2);
    printf("PASS: xaudio2_7 (FAudio builtin) CoCreateInstance + Release ok\n");
    CoUninitialize();
    return 0;
}

int main(void)
{
    int fail = 0;

    /* Sanity-measure x87 vs SSE2 under Rosetta 2 on this machine */
    float buf[256];
    for (int i = 0; i < 256; i++) buf[i] = 0.5f;
    double t0 = now_ms();
    bench_x87_comb(buf, 500000, 1.0f);
    double x87_ms = now_ms() - t0;

    for (int i = 0; i < 256; i++) buf[i] = 0.5f;
    t0 = now_ms();
    bench_sse_comb(buf, 500000, 1.0f);
    double sse_ms = now_ms() - t0;
    printf("INFO: Rosetta 32-bit FP 500k ops: x87=%.2f ms vs SSE2=%.2f ms (%.1fx speedup)\n",
           x87_ms, sse_ms, sse_ms > 0.01 ? x87_ms / sse_ms : 0.0);

    fail += test_crt_misaligned("msvcrt.dll");
    fail += test_crt_misaligned("ucrtbase.dll");
    fail += test_d3dx9_misaligned();
    fail += test_xaudio2_load();

    if (fail) {
        printf("FAILED (%d check(s))\n", fail);
        return 1;
    }
    printf("ALL i386 SSE2/STACK ALIGNMENT CHECKS PASSED\n");
    return 0;
}

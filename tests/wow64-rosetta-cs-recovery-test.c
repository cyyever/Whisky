/* Regression test for Rosetta 2 WoW64 32<->64 far-jump CS mismatch recovery.
 *
 * Build 32-bit PE with i686-w64-mingw32-gcc:
 *   i686-w64-mingw32-gcc -O2 -Wall -Wextra -shared -o dummy.dll -xc - <<<'int __declspec(dllexport) ping(int x){return x+1;}'
 *   i686-w64-mingw32-gcc -O2 -Wall -Wextra -o test.exe tests/wow64-rosetta-cs-recovery-test.c -lbcrypt
 *
 * Covers three scenarios:
 *  1. syscall_32to64 + 64->32 iretq return: 4 worker threads calling Sleep(0)
 *     inside a critical section during 200 concurrent LoadLibrary/FreeLibrary cycles.
 *  2. unix_call_32to64 + 64->32 iretq return: 2 worker threads calling
 *     BCryptGenRandom (WINE_UNIX_CALL into bcrypt.so) inside a critical section
 *     during the same LoadLibrary/FreeLibrary storm.
 *  3. Negative safety check: a real 32-bit `movl 0x5ef6, %edx` (opcode 8b 15)
 *     reading the unmapped low 64KB page MUST still deliver EXCEPTION_ACCESS_VIOLATION
 *     to the 32-bit VEH handler (never falsely switched to 64-bit mode).
 */
#include <windows.h>
#include <bcrypt.h>
#include <stdio.h>

static CRITICAL_SECTION cs;
static volatile LONG stop_flag = 0;
static volatile LONG syscall_iters = 0;
static volatile LONG unixcall_iters = 0;
static volatile LONG neg_fault_caught = 0;

static DWORD WINAPI syscall_worker(void *unused)
{
    (void)unused;
    while (!InterlockedCompareExchange(&stop_flag, 0, 0))
    {
        EnterCriticalSection(&cs);
        Sleep(0);
        InterlockedIncrement(&syscall_iters);
        LeaveCriticalSection(&cs);
    }
    return 0;
}

static DWORD WINAPI unixcall_worker(void *unused)
{
    BYTE buf[16];
    (void)unused;
    while (!InterlockedCompareExchange(&stop_flag, 0, 0))
    {
        EnterCriticalSection(&cs);
        if (BCryptGenRandom(NULL, buf, sizeof(buf), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
        {
            LeaveCriticalSection(&cs);
            return 2;
        }
        InterlockedIncrement(&unixcall_iters);
        LeaveCriticalSection(&cs);
    }
    return 0;
}

static LONG CALLBACK negative_veh(EXCEPTION_POINTERS *ep)
{
    if (ep->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION &&
        ep->ExceptionRecord->NumberParameters >= 2 &&
        ep->ExceptionRecord->ExceptionInformation[1] == 0x5ef6)
    {
        InterlockedIncrement(&neg_fault_caught);
        /* Skip the 6-byte `8b 15 f6 5e 00 00` (`movl 0x5ef6, %edx`) instruction. */
        ep->ContextRecord->Eip += 6;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static int test_negative_near_null_read(void)
{
    void *veh = AddVectoredExceptionHandler(1, negative_veh);
    if (!veh)
    {
        fprintf(stderr, "AddVectoredExceptionHandler failed\n");
        return 1;
    }

    /* Emit the exact 6-byte 32-bit instruction `movl 0x5ef6, %edx` (8b 15 f6 5e 00 00). */
    __asm__ __volatile__(
        ".byte 0x8b, 0x15, 0xf6, 0x5e, 0x00, 0x00\n\t"
        :
        :
        : "edx", "memory"
    );

    RemoveVectoredExceptionHandler(veh);
    if (neg_fault_caught != 1)
    {
        fprintf(stderr, "FAIL: negative near-null 8b 15 read was not delivered to 32-bit VEH (caught=%ld)\n",
                neg_fault_caught);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *dll_name = (argc > 1 && argv[1][0]) ? argv[1] : "d3dcompiler_43.dll";
    HANDLE threads[6];
    int i;

    if (test_negative_near_null_read() != 0)
        return 1;

    InitializeCriticalSection(&cs);

    for (i = 0; i < 4; i++)
    {
        threads[i] = CreateThread(NULL, 0, syscall_worker, NULL, 0, NULL);
        if (!threads[i])
        {
            fprintf(stderr, "CreateThread(syscall %d) failed: %lu\n", i, GetLastError());
            return 1;
        }
    }
    for (i = 4; i < 6; i++)
    {
        threads[i] = CreateThread(NULL, 0, unixcall_worker, NULL, 0, NULL);
        if (!threads[i])
        {
            fprintf(stderr, "CreateThread(unixcall %d) failed: %lu\n", i, GetLastError());
            return 1;
        }
    }

    for (i = 0; i < 200; i++)
    {
        HMODULE mod = LoadLibraryA(dll_name);
        if (!mod)
        {
            fprintf(stderr, "LoadLibraryA(%s) failed at iter %d: %lu\n",
                    dll_name, i, GetLastError());
            InterlockedExchange(&stop_flag, 1);
            return 1;
        }
        GetProcAddress(mod, "ping");
        if (!FreeLibrary(mod))
        {
            fprintf(stderr, "FreeLibrary failed at iter %d: %lu\n", i, GetLastError());
            InterlockedExchange(&stop_flag, 1);
            return 1;
        }
        if ((i & 7) == 0)
        {
            EnterCriticalSection(&cs);
            LeaveCriticalSection(&cs);
        }
    }

    InterlockedExchange(&stop_flag, 1);
    for (i = 0; i < 6; i++)
    {
        DWORD w = WaitForSingleObject(threads[i], 10000);
        DWORD code = 1;
        if (w != WAIT_OBJECT_0 || !GetExitCodeThread(threads[i], &code) || code != 0)
        {
            fprintf(stderr, "Worker %d failed/timed out (wait=%lu exit=%lu)\n", i, w, code);
            return 1;
        }
        CloseHandle(threads[i]);
    }

    DeleteCriticalSection(&cs);
    printf("PASS: 200 LoadLibrary/FreeLibrary cycles, %ld syscalls, %ld unixcalls, %ld neg-VEH\n",
           syscall_iters, unixcall_iters, neg_fault_caught);
    return 0;
}

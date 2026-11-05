/* A hardware access violation must reach Windows VEH on either Wine thread.
 * Build with x86_64-w64-mingw32-gcc or i686-w64-mingw32-gcc, then run with Wine.
 * Run under an external timeout: a broken Unix signal guard hangs before VEH.
 */
#include <windows.h>
#include <stdio.h>

static void *page;
static LONG exceptions;

static LONG CALLBACK recover_fault(EXCEPTION_POINTERS *exception)
{
    DWORD previous;
    if (exception->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION ||
        exception->ExceptionRecord->NumberParameters < 2 ||
        exception->ExceptionRecord->ExceptionInformation[1] != (ULONG_PTR)page)
        return EXCEPTION_CONTINUE_SEARCH;
    if (!VirtualProtect(page, 4096, PAGE_READWRITE, &previous))
        return EXCEPTION_CONTINUE_SEARCH;
    InterlockedIncrement(&exceptions);
    return EXCEPTION_CONTINUE_EXECUTION;
}

static DWORD WINAPI fault_and_recover(void *unused)
{
    DWORD previous;
    (void)unused;
    if (!VirtualProtect(page, 4096, PAGE_NOACCESS, &previous)) return 1;
    *(volatile int *)page = 42;
    return *(volatile int *)page != 42;
}

int main(void)
{
    HANDLE thread;
    DWORD result = 1;
    void *handler;
    page = VirtualAlloc(NULL, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    handler = AddVectoredExceptionHandler(1, recover_fault);
    if (!page || !handler) return 1;
    puts("Testing initial-thread hardware access violation");
    fflush(stdout);
    if (fault_and_recover(NULL)) return 1;
    puts("Testing worker-thread hardware access violation");
    fflush(stdout);
    thread = CreateThread(NULL, 0, fault_and_recover, NULL, 0, NULL);
    if (!thread || WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0 ||
        !GetExitCodeThread(thread, &result)) return 1;
    CloseHandle(thread);
    RemoveVectoredExceptionHandler(handler);
    VirtualFree(page, 0, MEM_RELEASE);
    printf("Recovered %ld exceptions; worker exit %lu\n", exceptions, result);
    return result || exceptions != 2;
}

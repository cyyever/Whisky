/*
 * wow64-low-address-space-test — does a 32-bit process ever get its low
 * address space back?
 *
 * Build: i686-w64-mingw32-gcc -O2 -o wow64-low-address-space-test.exe \
 *            wow64-low-address-space-test.c
 * Run:   wine wow64-low-address-space-test.exe        (must be the 32-bit build)
 *
 * WHY. Wine's preloader reserves the low address space so that the host's
 * allocator cannot scatter mappings through the range a Windows process expects
 * to own. It is handed back once the process's DLLs are initialised, by a
 * private handshake: ntdll's PE side calls
 *
 *     NtFreeVirtualMemory( proc, (void *)1, 0, MEM_RELEASE )   // loader.c
 *
 * and the unix side recognises address 1 as "release the reserved space"
 * (virtual.c). Both halves of that handshake are inside `#ifndef _WIN64`.
 *
 * Under the *new* WoW64 -- one 64-bit unix ntdll serving 32-bit PE processes,
 * which is what `--enable-archs=i386,x86_64` builds -- the two halves land on
 * opposite sides of that guard. The 32-bit PE ntdll still sends the request;
 * the 64-bit unix ntdll has the handler compiled out and answers
 * STATUS_INVALID_PARAMETER. So the reservation is never released, and every
 * 32-bit DLL whose preferred ImageBase falls in the reserved range is
 * relocated for the life of the process.
 *
 * That is not merely untidy. A DLL that checksums its own loaded image will
 * fail: relocation rewrites absolute addresses inside .text, so the in-memory
 * bytes no longer match what the checksum was computed over. Crypto++ built as
 * a FIPS module does exactly this, and SSFIV ships one (preferred base
 * 0x42900000, squarely inside the reserved range) -- it prints "In memory
 * integrity check failed. This may be caused by debug breakpoints or DLL
 * relocation." and exits(3).
 *
 * WHAT THIS PROVES. The reasoning above is a reading of the source; this is the
 * measurement. It asks three questions a patch has to move:
 *
 *   1. does the release handshake succeed?
 *   2. can the low range be reserved by hand afterwards?
 *   3. does a DLL that wants a base in that range actually get it?
 *
 * READ CHECK 2 AS CONTEXT, NOT AS EVIDENCE. It passes either way, so it cannot
 * tell the states apart: a fixed-base NtAllocateVirtualMemory goes through
 * map_view() -> map_fixed_area(), which walks the reserved areas and maps
 * straight over any that covers the request -- handing that range to the
 * application is what the reservation is *for*. So these probes succeed with
 * the reservation intact and succeed again once it is gone. It is here to show
 * the range is usable at all, and it was briefly misread as proof that the
 * unreleased reservation does not force relocation. It proves no such thing;
 * check 3 is the only discriminating probe, because only it observes where the
 * loader *chooses* to put a relocatable image.
 *
 * Check 2's first probe is doubly uninformative: virtual_release_address_space()
 * frees 0x20000000-0x7f000000, and 0x10000000 lies below that, so no fix to the
 * handshake could change it even in principle. (Check 1 has a single probe --
 * the NtFreeVirtualMemory((void *)1, ...) call -- and its verdict is the point
 * of this file; do not discount it.)
 *
 * Exit code is the number of failed checks, so it doubles as a pass/fail gate.
 */
#include <windows.h>
#include <stdio.h>

#ifndef STATUS_SUCCESS
#define STATUS_SUCCESS 0
#endif
/* STATUS_INVALID_PARAMETER comes from winnt.h; do not redefine it. */

typedef LONG NTSTATUS;
typedef NTSTATUS (WINAPI *NtFreeVirtualMemory_t)( HANDLE, PVOID *, SIZE_T *, ULONG );

/* Addresses inside the range the preloader reserves for a 32-bit process
 * (0x110000 .. 0x68000000). 0x42900000 is not arbitrary: it is the preferred
 * base of the Crypto++ FIPS DLL this was written for. */
static const struct { void *addr; const char *what; } probes[] =
{
    { (void *)0x10000000, "0x10000000  common OpenSSL/DLL default base" },
    { (void *)0x42900000, "0x42900000  cryptopp.dll preferred base" },
    { (void *)0x60000000, "0x60000000  upper end of the reserved range" },
};

static int reserve_probe( void *addr, SIZE_T size )
{
    void *got = VirtualAlloc( addr, size, MEM_RESERVE, PAGE_NOACCESS );
    if (!got) return 0;
    VirtualFree( got, 0, MEM_RELEASE );
    return got == addr;
}

int main( void )
{
    NtFreeVirtualMemory_t pNtFreeVirtualMemory;
    unsigned int i, failures = 0;
    NTSTATUS status;
    PVOID addr;
    SIZE_T size;

    if (sizeof(void *) != 4)
    {
        printf( "FAIL  this must be built 32-bit (i686-w64-mingw32-gcc); "
                "a 64-bit process has no low-range reservation to release\n" );
        return 1;
    }

    printf( "1. the release handshake\n" );
    pNtFreeVirtualMemory = (NtFreeVirtualMemory_t)GetProcAddress(
        GetModuleHandleA( "ntdll.dll" ), "NtFreeVirtualMemory" );
    if (!pNtFreeVirtualMemory)
    {
        printf( "   FAIL  no NtFreeVirtualMemory\n" );
        return ++failures;
    }
    /* The same call ntdll's PE side makes after DLL init. Sending it twice is
     * harmless -- a release that already happened is idempotent -- so this
     * measures the answer rather than causing it. */
    addr = (PVOID)1; size = 0;
    status = pNtFreeVirtualMemory( GetCurrentProcess(), &addr, &size, MEM_RELEASE );
    if (status == STATUS_SUCCESS)
        printf( "   pass  returned STATUS_SUCCESS (handler present)\n" );
    else if ((ULONG)status == STATUS_INVALID_PARAMETER)
    {
        printf( "   FAIL  returned STATUS_INVALID_PARAMETER -- the unix side has no\n"
                "         handler for the magic address, i.e. the reservation is never\n"
                "         released. This is the new-WoW64 signature.\n" );
        failures++;
    }
    else
    {
        printf( "   FAIL  returned %08lx (expected SUCCESS)\n", (unsigned long)status );
        failures++;
    }

    printf( "\n2. can the reserved range be taken by hand?\n" );
    for (i = 0; i < sizeof(probes)/sizeof(probes[0]); i++)
    {
        /* Deliberately not counted: this check cannot tell the two states apart
         * (see the header), and 0x10000000 is a base several DLLs declare, so a
         * resident module there would fail it for a reason unrelated to the
         * question and drag the whole gate down with it. */
        int ok = reserve_probe( probes[i].addr, 0x142000 );
        printf( "   %s  %s%s\n", ok ? "pass " : "note ", probes[i].what,
                ok ? "" : "  (not counted)" );
    }

    printf( "\n3. does a DLL get its preferred base?\n" );
    {
        /* DONT_RESOLVE_DLL_REFERENCES: map it, run nothing. The point is where
         * the loader puts it, and a FIPS DLL's DllMain would run the very self
         * test this is about. */
        static const char *dll =
            "C:\\Program Files (x86)\\Steam\\steamapps\\common\\"
            "Super Street Fighter IV - Arcade Edition\\cryptopp.dll";
        HMODULE h = LoadLibraryExA( dll, NULL, DONT_RESOLVE_DLL_REFERENCES );
        if (!h)
        {
            /* Counted. The header calls this the only discriminating probe, so a
             * run that skipped it measured nothing about image placement and
             * must not exit 0 into a CI job or a shell && chain. */
            printf( "   SKIP  cannot load %s (%lu) -- and this was the only\n"
                    "         discriminating check, so this run measured the handshake\n"
                    "         and nothing about where the loader places an image\n",
                    dll, GetLastError() );
            failures++;
        }
        else
        {
            /* Read the preferred base from the FILE, never from the loaded
             * image: the loader rewrites OptionalHeader.ImageBase in memory to
             * wherever it actually put the module, exactly as Windows does, so
             * comparing the mapped header against the mapped base is an
             * identity and always "passes". That bug made this check report
             * success on a module that had plainly been relocated. */
            DWORD want = 0;
            HANDLE f = CreateFileA( dll, GENERIC_READ, FILE_SHARE_READ, NULL,
                                    OPEN_EXISTING, 0, NULL );
            if (f != INVALID_HANDLE_VALUE)
            {
                IMAGE_DOS_HEADER fdos;
                IMAGE_NT_HEADERS32 fnt;
                DWORD got;
                if (ReadFile( f, &fdos, sizeof(fdos), &got, NULL ) && got == sizeof(fdos) &&
                    SetFilePointer( f, fdos.e_lfanew, NULL, FILE_BEGIN ) != INVALID_SET_FILE_POINTER &&
                    ReadFile( f, &fnt, sizeof(fnt), &got, NULL ) && got == sizeof(fnt))
                    want = fnt.OptionalHeader.ImageBase;
                CloseHandle( f );
            }
            if (!want)
                printf( "   skip  cannot read the on-disk ImageBase\n" );
            else if ((DWORD)(ULONG_PTR)h == want)
                printf( "   pass  loaded at its preferred base %08lx\n", want );
            else
            {
                printf( "   FAIL  preferred %08lx, loaded at %08lx -- relocated, so its\n"
                        "         .text no longer matches the image it was checksummed from\n",
                        want, (unsigned long)(ULONG_PTR)h );
                failures++;
            }
            FreeLibrary( h );
        }
    }

    printf( "\n%u failed check(s)\n", failures );
    return (int)failures;
}

/*
 * module-map-test — print the loaded module map (base, size, name) of a Wine
 * process, so a raw address from vmmap/lldb can be attributed to a DLL.
 *
 * Build 32-bit (needed to see the 32-bit builtin layout a 32-bit game sees):
 *     i686-w64-mingw32-gcc -O2 -o module-map-test.exe module-map-test.c
 * Build 64-bit:
 *     x86_64-w64-mingw32-gcc -O2 -o module-map-test64.exe module-map-test.c
 * Run:  wine module-map-test.exe [hex-address]
 *
 * Why this exists: vmmap(1) labels every Wine PE mapping as WINE_RESERVE
 * pointing at the wine binary, so it can give you a region's bounds and
 * protection but never a module name. lldb cannot help either -- these are not
 * dyld images, and its -o commands do not run after attaching to a
 * Rosetta-translated process. Matching a region's .text size against the
 * on-disk builtins narrows it down but is not proof when two DLLs happen to
 * round to the same page count.
 *
 * Wine's builtins load at their fixed ImageBase, and the layout was verified
 * byte-identical across separate runs of the same program, so a probe launched
 * into the same prefix sees the same bases as the process under investigation.
 * That is what makes this indirection sound -- but it is an indirection, so
 * treat a hit as strong evidence, not as a reading taken from the live process.
 *
 * With an address argument it prints only the containing module and the offset
 * into it, which is the form you want when chasing a fault address.
 */
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>

int main( int argc, char **argv )
{
    ULONG_PTR target = 0;
    HMODULE mods[1024];
    DWORD needed = 0;
    unsigned int i, count;
    int found = 0;

    if (argc > 1) target = (ULONG_PTR)strtoull( argv[1], NULL, 16 );

    if (!EnumProcessModules( GetCurrentProcess(), mods, sizeof(mods), &needed ))
    {
        printf( "EnumProcessModules failed: %lu\n", GetLastError() );
        return 2;
    }
    count = needed / sizeof(HMODULE);

    if (!target) printf( "%-12s %-10s %s\n", "base", "size", "module" );

    for (i = 0; i < count; i++)
    {
        MODULEINFO mi;
        WCHAR name[MAX_PATH] = {0};
        ULONG_PTR base;

        if (!GetModuleInformation( GetCurrentProcess(), mods[i], &mi, sizeof(mi) )) continue;
        GetModuleFileNameExW( GetCurrentProcess(), mods[i], name, MAX_PATH );
        base = (ULONG_PTR)mi.lpBaseOfDll;

        if (target)
        {
            if (target >= base && target < base + mi.SizeOfImage)
            {
                printf( "%0*llx is in %ls\n", (int)(sizeof(void *) * 2),
                        (unsigned long long)target, name );
                printf( "    base %0*llx  size %lx  offset +%llx\n",
                        (int)(sizeof(void *) * 2), (unsigned long long)base,
                        (unsigned long)mi.SizeOfImage,
                        (unsigned long long)(target - base) );
                found = 1;
            }
        }
        else
        {
            printf( "%0*llx %-10lx %ls\n", (int)(sizeof(void *) * 2),
                    (unsigned long long)base, (unsigned long)mi.SizeOfImage, name );
        }
    }

    if (target && !found)
    {
        printf( "%llx is in no loaded module of this process.\n",
                (unsigned long long)target );
        printf( "Either it is not a PE mapping (stack, heap, or a Wine internal\n"
                "reservation), or the process under investigation had loaded\n"
                "something this probe has not.\n" );
        return 1;
    }
    return 0;
}

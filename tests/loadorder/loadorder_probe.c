/*
 * Load-order probe — one DLL per invocation.
 *
 * LoadLibraryA the single module named in argv[1], then exit. Loading a module
 * runs get_load_order() in the Wine loader, which under WINEDEBUG=+module logs
 * its decision (patch 0017 logs `got fork|Metal builtin b for ...`) *before* the
 * module is mapped or its DllMain runs. run.sh asserts that logged decision was
 * builtin — with NO WINEDLLOVERRIDES set. Whether the module then finishes
 * mapping/initialising is irrelevant here; only the load-order *decision*
 * matters, and it is logged first.
 *
 * One DLL per process (fresh address space, isolated failure) so a large builtin
 * that fails to map — or a crash in one module's init — cannot suppress another
 * module's trace, as happened when all seven were loaded in a single process.
 */
#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s <dll>\n", argv[0]);
        return 2;
    }
    HMODULE h = LoadLibraryA(argv[1]);
    printf("%s: %s\n", argv[1], h ? "loaded" : "not-loaded");
    fflush(stdout);
    if (h) FreeLibrary(h);
    return 0;
}

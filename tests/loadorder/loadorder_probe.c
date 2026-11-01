/*
 * Load-order probe — one DLL per invocation.
 *
 * LoadLibraryA the module named in argv[1]. Both the load-order trace and
 * successful loading are required; a crash or missing builtin must fail.
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
    return h ? 0 : 1;
}

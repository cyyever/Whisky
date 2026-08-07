/*
 * wx-mprotect-test — does macOS let an executable mapping become writable, the
 * way Proton's steamclient trampoline setup assumes?
 *
 * ANSWER, measured on macOS 27 / Apple Silicon: YES, under Rosetta and
 * natively. This test exists to record a NEGATIVE result -- it was written to
 * confirm a W^X explanation for the Super Street Fighter IV fault, and it
 * refuted it instead. Do not re-derive that theory.
 *
 * Build: cc -O2 -arch x86_64 -o wx-mprotect-test wx-mprotect-test.c
 * Run:   arch -x86_64 ./wx-mprotect-test   (as Wine runs)
 *
 * dlls/ntdll/unix/loader.c:steamclient_setup_trampolines() does
 *
 *     mprotect(text, size, PROT_READ|PROT_WRITE|PROT_EXEC);
 *
 * over steamclient.dll's .text and then writes jump stubs into it, redirecting
 * every export into lsteamclient. It does not check the return value, and this
 * tree has no MAP_JIT anywhere -- which made "macOS refuses W+X on a mapping
 * not created with MAP_JIT, the mprotect fails silently, and the jump stubs
 * then fault on a read-only page" a tidy explanation for SFIV's death
 * (EXC_BAD_ACCESS code=2 in memmove at an r-x PE code page, 100% CPU retry
 * loop). It is wrong: the mprotect below is granted.
 *
 * So whatever leaves that page r-x at the moment of the write, it is not the
 * kernel refusing W+X. Wine's own vprot bookkeeping resetting the protection,
 * or a write outside the range that was mprotect'd, remain open.
 *
 * Exit 0 if W+X is refused, 1 if granted. It currently exits 1.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

int main( void )
{
    const size_t len = 0x4000;
    int rc, failures = 0;
    void *addr;

    /* Anonymous, read+execute: the shape Wine's loader leaves a PE .text
     * section in. (A *file* mapping cannot be made executable at all here --
     * macOS refuses PROT_EXEC on an unsigned file -- so an anonymous mapping is
     * both what Wine uses via anon_mmap_fixed() and the only thing testable.) */
    addr = mmap( NULL, len, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0 );
    if (addr == MAP_FAILED) { perror( "mmap r-x" ); return 2; }

    printf( "mapped %zu bytes r-x at %p\n\n", len, addr );

    /* 1. What Proton's default trampoline path asks for. */
    errno = 0;
    rc = mprotect( addr, len, PROT_READ | PROT_WRITE | PROT_EXEC );
    printf( "mprotect(RWX)  -> %d", rc );
    if (rc == -1) { printf( "  errno=%d (%s)  <- W^X refuses it\n", errno, strerror( errno ) ); failures++; }
    else printf( "  granted\n" );

    /* 2. Write+read without exec, to show the refusal is about W+X together and
     * not about the mapping being unwritable in general. */
    errno = 0;
    rc = mprotect( addr, len, PROT_READ | PROT_WRITE );
    printf( "mprotect(RW)   -> %d", rc );
    if (rc == -1) printf( "  errno=%d (%s)\n", errno, strerror( errno ) );
    else printf( "  granted\n" );

    /* 3. Whether the write Proton then performs would actually land. Only
     * meaningful if step 1 granted; otherwise the page is RW from step 2. */
    if (rc == 0)
    {
        memset( addr, 0x90, 16 );
        printf( "write after RW -> ok\n" );
    }

    printf( "\n" );
    if (failures)
        printf( "W+X refused. steamclient_setup_trampolines()'s unchecked mprotect\n"
                "fails here, and the jump stubs it writes next hit a read-only page.\n"
                "WINESTEAMNOEXEC=1 takes the branch that never writes to .text.\n" );
    else
        printf( "W+X granted -- the SFIV fault is NOT explained by W^X.\n" );

    munmap( addr, len );
    return failures ? 0 : 1;
}

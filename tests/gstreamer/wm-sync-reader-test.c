/*
 * wm-sync-reader-test — can a bottle create an IWMSyncReader?
 *
 * Build: i686-w64-mingw32-gcc -O2 -o wm-sync-reader-test.exe wm-sync-reader-test.c
 * Run:   wine wm-sync-reader-test.exe        (gstreamer-test.sh does both)
 *
 * WMCreateSyncReader is a one-line wrapper around
 * winegstreamer_create_wm_sync_reader (dlls/wmvcore/wmvcore_main.c), which
 * wmvcore delay-loads from winegstreamer.dll. Build Wine --without-gstreamer and
 * that DLL does not exist: the delay-load raises EXCEPTION_WINE_STUB and the
 * caller dies. SSFIV died there, at exit 255, after reaching Steam's stats API
 * -- the failure names GStreamer nowhere, only "failed to delay load".
 *
 * 32-bit because that is what a 32-bit game's wmvcore runs as.
 *
 * Prints a line before the call it might not return from, so the wrapper can
 * tell "returned an error" from "died reaching the export".
 *
 * Exit code is the number of failed checks.
 */
#include <windows.h>
#include <stdio.h>

typedef HRESULT (WINAPI *PFN_WMCreateSyncReader)( IUnknown *, DWORD, void ** );

int main( void )
{
    HMODULE wmv;
    PFN_WMCreateSyncReader pCreate;
    void *reader = NULL;
    HRESULT hr;

    setvbuf( stdout, NULL, _IONBF, 0 );  /* Wine loses buffered stdout on exit */

    printf( "process is %d-bit\n", (int)(sizeof(void *) * 8) );

    if (!(wmv = LoadLibraryA( "wmvcore.dll" )))
    {
        printf( "FAIL  wmvcore.dll will not load (%lu)\n", GetLastError() );
        return 1;
    }
    printf( "pass  wmvcore.dll loaded\n" );

    if (!(pCreate = (PFN_WMCreateSyncReader)GetProcAddress( wmv, "WMCreateSyncReader" )))
    {
        printf( "FAIL  wmvcore.dll exports no WMCreateSyncReader\n" );
        return 1;
    }
    printf( "pass  WMCreateSyncReader resolved\n" );

    /* Past this line the delay-load of winegstreamer.dll happens. Without it
     * the process does not come back. */
    printf( "      calling WMCreateSyncReader (delay-loads winegstreamer)\n" );
    hr = pCreate( NULL, 0, &reader );

    if (FAILED( hr ) || !reader)
    {
        printf( "FAIL  WMCreateSyncReader returned 0x%08lx\n", (unsigned long)hr );
        return 1;
    }
    printf( "pass  IWMSyncReader created\n" );

    printf( "\n0 failed check(s)\n" );
    return 0;
}

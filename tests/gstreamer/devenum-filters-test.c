/*
 * devenum-filters-test — enumerate DirectShow filters, as quartz's autoplug does.
 *
 *   wine64 devenum-filters-test.exe
 *
 * midiOutGetNumDevs alone returns in both bitnesses, so the hang needs the
 * context around it. This is the next layer out and the one quartz actually
 * uses: CoCreateInstance(CLSID_SystemDeviceEnum) then CreateClassEnumerator on
 * the legacy filter category, from an STA -- which internally counts MIDI
 * devices (devenum/createdevenum.c register_midiout_devices).
 */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <stdio.h>
#include <stdlib.h>

int main( void )
{
    ICreateDevEnum *devenum = NULL;
    IEnumMoniker *e = NULL;
    HRESULT hr;
    int n = 0;

    setvbuf( stdout, NULL, _IONBF, 0 );
    CoInitializeEx( NULL, COINIT_APARTMENTTHREADED );

    hr = CoCreateInstance( &CLSID_SystemDeviceEnum, NULL, CLSCTX_INPROC_SERVER,
                           &IID_ICreateDevEnum, (void **)&devenum );
    printf( "      CoCreateInstance(SystemDeviceEnum) 0x%08lx\n", (unsigned long)hr );
    if (FAILED( hr )) return 2;

    printf( "      CreateClassEnumerator(LegacyAmFilterCategory)\n" );
    hr = ICreateDevEnum_CreateClassEnumerator( devenum, &CLSID_LegacyAmFilterCategory, &e, 0 );
    printf( "      returned 0x%08lx\n", (unsigned long)hr );
    /* S_FALSE means "category empty, no enumerator" -- not a pass. */
    if (hr != S_OK || !e)
    {
        printf( "FAIL  no enumerator (0x%08lx)\n", (unsigned long)hr );
        ICreateDevEnum_Release( devenum );
        return 1;
    }
    if (hr == S_OK && e)
    {
        IMoniker *m;
        while (IEnumMoniker_Next( e, 1, &m, NULL ) == S_OK) { n++; IMoniker_Release( m ); }
        IEnumMoniker_Release( e );
    }
    ICreateDevEnum_Release( devenum );
    /* Zero filters is a broken registration, not a successful enumeration. */
    printf( "%s  enumerated %d filter(s)\n", n ? "pass " : "FAIL ", n );
    return n ? 0 : 1;
}

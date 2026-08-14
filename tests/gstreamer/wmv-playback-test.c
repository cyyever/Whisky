/*
 * wmv-playback-test — can a bottle actually decode a WMV?
 *
 * Build: i686-w64-mingw32-gcc -O2 -o wmv-playback-test.exe wmv-playback-test.c -lole32
 *        (WMCreateSyncReader is resolved at runtime -- mingw ships wmsdk.h but
 *         no wmvcore import library.)
 * Run:   wine wmv-playback-test.exe <path-to.wmv>   (gstreamer-test.sh does both)
 *
 * The sibling wm-sync-reader-test proves winegstreamer loads and hands back an
 * IWMSyncReader. That is the delay-load SSFIV died on, but it is not playback:
 * creating the object builds no pipeline, so it passes on a GStreamer with no
 * demuxer and no decoder. This one opens a real file and pulls samples, which
 * needs asfdemux for the container and libav for WMV3/VC-1 -- the plugins the
 * build enables and build-proton-x86.sh bundles.
 *
 * Reading one sample would only prove the header parsed. It reads several, so a
 * decoder that dies after the first frame is caught too.
 *
 * 32-bit, like the game.
 *
 * Exit code is the number of failed checks.
 */
#define COBJMACROS
#include <windows.h>
#include <wmsdk.h>

/* mingw ships the interfaces but not the WM error codes. */
#ifndef NS_E_NO_MORE_SAMPLES
#define NS_E_NO_MORE_SAMPLES ((HRESULT)0xC00D0BCFL)
#endif
#include <stdio.h>

typedef HRESULT (WINAPI *PFN_WMCreateSyncReader)( IUnknown *, DWORD, IWMSyncReader ** );

#define WANT_SAMPLES 5

int main( int argc, char *argv[] )
{
    IWMSyncReader *reader = NULL;
    WCHAR path[MAX_PATH];
    HRESULT hr;
    DWORD outputs = 0, got = 0, i;

    setvbuf( stdout, NULL, _IONBF, 0 );

    if (argc < 2)
    {
        printf( "usage: wmv-playback-test <file.wmv>\n" );
        return 1;
    }
    if (!MultiByteToWideChar( CP_ACP, 0, argv[1], -1, path, MAX_PATH ))
    {
        /* Unchecked, a path too long for MAX_PATH leaves `path` uninitialised
         * stack and hands that to Open(). */
        printf( "FAIL  path does not fit MAX_PATH: %s\n", argv[1] );
        return 1;
    }

    hr = CoInitializeEx( NULL, COINIT_MULTITHREADED );
    if (FAILED( hr )) { printf( "FAIL  CoInitializeEx 0x%08lx\n", (unsigned long)hr ); return 1; }

    {
        HMODULE wmv = LoadLibraryA( "wmvcore.dll" );
        PFN_WMCreateSyncReader pCreate = wmv
            ? (PFN_WMCreateSyncReader)GetProcAddress( wmv, "WMCreateSyncReader" ) : NULL;
        if (!pCreate) { printf( "FAIL  wmvcore.dll / WMCreateSyncReader unavailable\n" ); return 1; }
        hr = pCreate( NULL, 0, &reader );
    }
    if (FAILED( hr ) || !reader)
    {
        printf( "FAIL  WMCreateSyncReader 0x%08lx\n", (unsigned long)hr );
        return 1;
    }
    printf( "pass  sync reader created\n" );

    /* Opens the container: needs a demuxer that understands ASF. */
    hr = IWMSyncReader_Open( reader, path );
    if (FAILED( hr ))
    {
        printf( "FAIL  Open(%s) 0x%08lx -- no ASF demuxer, or the file is unreadable\n",
                argv[1], (unsigned long)hr );
        return 1;
    }
    printf( "pass  opened %s\n", argv[1] );

    hr = IWMSyncReader_GetOutputCount( reader, &outputs );
    if (FAILED( hr ) || !outputs)
    {
        printf( "FAIL  GetOutputCount 0x%08lx (%lu outputs)\n", (unsigned long)hr, outputs );
        return 1;
    }
    printf( "pass  %lu output(s)\n", outputs );

    /* Pulls decoded samples: needs the WMV/VC-1 decoder behind the demuxer. */
    for (i = 0; i < WANT_SAMPLES; i++)
    {
        INSSBuffer *buffer = NULL;
        QWORD time = 0, duration = 0;
        DWORD flags = 0, output = 0;
        WORD stream = 0;

        hr = IWMSyncReader_GetNextSample( reader, 0, &buffer, &time, &duration, &flags, &output, &stream );
        if (hr == NS_E_NO_MORE_SAMPLES) break;
        if (FAILED( hr ) || !buffer)
        {
            printf( "FAIL  GetNextSample #%lu 0x%08lx -- demuxed, but nothing decoded it\n",
                    i, (unsigned long)hr );
            return 1;
        }
        INSSBuffer_Release( buffer );
        got++;
    }

    printf( "%s  %lu sample(s) read\n", got ? "pass " : "FAIL ", got );
    IWMSyncReader_Close( reader );
    IWMSyncReader_Release( reader );
    CoUninitialize();

    printf( "\n%d failed check(s)\n", got ? 0 : 1 );
    return got ? 0 : 1;
}

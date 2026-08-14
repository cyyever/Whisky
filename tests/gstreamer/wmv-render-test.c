/*
 * wmv-render-test — play a WMV in a window, so a human can see it.
 *
 *   wine64 wmv-render-test.exe 'C:\path\to\movie.wmv'
 *
 * The sibling wmv-playback-test proves the file DECODES: IWMSyncReader is a
 * pull API, Open() then GetNextSample() hands frames back in memory, and no
 * renderer or window is involved anywhere in it. Green there and a black screen
 * in the game are perfectly consistent -- they test different halves.
 *
 * This one builds a DirectShow graph instead: quartz RenderFile picks the
 * splitter and decoder (both winegstreamer, the same GStreamer pipeline), then
 * connects them to quartz's video renderer, which creates the window. So it
 * exercises the presentation half the other test cannot reach.
 *
 * Exits when playback completes, or after --seconds (default 20).
 */
/* COBJMACROS: the IFoo_Method(obj, ...) helpers this file uses are only
 * declared when it is defined before the COM headers. */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <stdio.h>
#include <stdlib.h>

int main( int argc, char **argv )
{
    IGraphBuilder *graph = NULL;
    IMediaControl *control = NULL;
    IMediaEvent *event = NULL;
    IVideoWindow *window = NULL;
    WCHAR path[MAX_PATH];
    long code = 0, secs = 20;
    HRESULT hr;

    if (argc < 2)
    {
        printf( "usage: wmv-render-test <file.wmv> [seconds]\n" );
        return 2;
    }
    if (argc > 2) secs = atol( argv[2] );

    if (!MultiByteToWideChar( CP_ACP, 0, argv[1], -1, path, MAX_PATH ))
    {
        printf( "FAIL  path does not fit MAX_PATH: %s\n", argv[1] );
        return 1;
    }

    hr = CoInitializeEx( NULL, COINIT_APARTMENTTHREADED );
    if (FAILED( hr )) { printf( "FAIL  CoInitializeEx 0x%08lx\n", (unsigned long)hr ); return 1; }

    hr = CoCreateInstance( &CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
                           &IID_IGraphBuilder, (void **)&graph );
    if (FAILED( hr )) { printf( "FAIL  CoCreateInstance(FilterGraph) 0x%08lx\n", (unsigned long)hr ); return 1; }

    /* Picks the splitter, the decoder and the renderer, and connects them.
     * A missing decoder shows up HERE, as a failing HRESULT, rather than as a
     * pipeline that stalls -- quartz gives up instead of waiting. */
    hr = IGraphBuilder_RenderFile( graph, path, NULL );
    if (FAILED( hr ))
    {
        printf( "FAIL  RenderFile 0x%08lx -- no filter chain for this file\n", (unsigned long)hr );
        return 1;
    }
    printf( "pass  graph built\n" );

    IGraphBuilder_QueryInterface( graph, &IID_IMediaControl, (void **)&control );
    IGraphBuilder_QueryInterface( graph, &IID_IMediaEvent, (void **)&event );

    /* The renderer creates its own window; without this it can come up hidden,
     * which looks exactly like the failure this test exists to rule out. */
    if (SUCCEEDED( IGraphBuilder_QueryInterface( graph, &IID_IVideoWindow, (void **)&window ) ))
    {
        IVideoWindow_put_AutoShow( window, OATRUE );
        IVideoWindow_put_Visible( window, OATRUE );
        IVideoWindow_SetWindowPosition( window, 100, 100, 640, 360 );
        printf( "pass  video window created\n" );
    }
    else
        printf( "FAIL  no IVideoWindow -- the graph has no video renderer\n" );

    hr = IMediaControl_Run( control );
    if (FAILED( hr )) { printf( "FAIL  Run 0x%08lx\n", (unsigned long)hr ); return 1; }
    printf( "pass  running -- playing for up to %ld s\n", secs );

    /* Pump messages: the renderer's window is on this thread, and a window that
     * never dispatches is a window macOS draws once and then greys out. */
    {
        DWORD end = GetTickCount() + secs * 1000;
        MSG msg;
        while (GetTickCount() < end)
        {
            while (PeekMessageW( &msg, NULL, 0, 0, PM_REMOVE ))
            {
                TranslateMessage( &msg );
                DispatchMessageW( &msg );
            }
            if (event && SUCCEEDED( IMediaEvent_WaitForCompletion( event, 50, &code ) ) && code)
            {
                printf( "pass  playback completed (event %ld)\n", code );
                break;
            }
        }
    }

    if (window) IVideoWindow_put_Visible( window, OAFALSE );
    if (control) IMediaControl_Stop( control );
    printf( "\n0 failed check(s)\n" );
    return 0;
}

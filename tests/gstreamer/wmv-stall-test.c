/*
 * wmv-stall-test -- does a WMV's graph clock keep advancing, headless?
 *
 * WHY. SSFIV hangs on a black screen with no sound at its intro movie. A
 * backtrace showed the media pipeline live but stalled -- asfdemux and the
 * libav audio decoder running, winegstreamer's sink_chain_cb and
 * wg_parser_get_next_read_offset blocked at the app boundary, the DirectShow
 * graph worker parked in wait_message -- while every DXVK thread sat idle in
 * futex_wait with no GPU work outstanding. That points at the DirectShow
 * path, not the Vulkan driver, but the game is a slow and noisy way to test
 * it: a launch costs a Steam round trip and the graphics stack is in the
 * picture the whole time.
 *
 * This is the same graph the game builds -- RenderFile on the game's own
 * .wmv, Run, wait for EC_COMPLETE -- and nothing else. Built as a 32-bit PE
 * to match the game. Rendering goes to the null renderer by default so the
 * run is headless and the video decoder still has to feed a connected sink;
 * pass -show for a real window.
 *
 * The question is "does it play", not "does it play all of it": these movies
 * run minutes, and a graph advancing its clock at wall-clock rate has already
 * answered. So the run stops as soon as -enough seconds of the stream have
 * been decoded (default 25), and only a clock that STOPS advancing counts as
 * the hang. Watch the reported rate: healthy playback is ~1.0x.
 *
 * Exit codes:  0 played   1 setup/API failure   2 STALLED or timed out
 *
 * Usage: dshow-play-test.exe [-show] [-enough seconds] [-t seconds] <file.wmv>
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dshow.h>
#include <stdio.h>
#include <stdlib.h>

/* The null renderer lives in qedit/quartz as CLSID_NullRenderer. Declared
 * here so the test does not need the (frequently absent) qedit headers. */
static const GUID CLSID_NullRendererLocal =
    { 0xc1f400a4, 0x3f08, 0x11d3, { 0x9f, 0x0b, 0x00, 0x60, 0x08, 0x03, 0x9e, 0x37 } };

static const char *hr_name(HRESULT hr)
{
    switch (hr) {
    case S_OK:                    return "S_OK";
    case VFW_E_UNSUPPORTED_STREAM: return "VFW_E_UNSUPPORTED_STREAM";
    case VFW_E_CANNOT_RENDER:     return "VFW_E_CANNOT_RENDER";
    case VFW_E_NOT_FOUND:         return "VFW_E_NOT_FOUND";
    case E_NOINTERFACE:           return "E_NOINTERFACE";
    case REGDB_E_CLASSNOTREG:     return "REGDB_E_CLASSNOTREG";
    default:                      return "";
    }
}

#define CHECK(what, hr) do {                                                  \
    HRESULT h_ = (hr);                                                        \
    if (FAILED(h_)) {                                                         \
        printf("FAIL  %s = 0x%08lx %s\n", what, (unsigned long)h_, hr_name(h_)); \
        return 1;                                                             \
    }                                                                         \
} while (0)

int main(int argc, char **argv)
{
    const char *path = NULL;
    int show = 0, timeout_s = 0, enough_s = 25;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-show")) show = 1;
        else if (!strcmp(argv[i], "-t") && i + 1 < argc) timeout_s = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-enough") && i + 1 < argc) enough_s = atoi(argv[++i]);
        else path = argv[i];
    }
    if (!path) {
        printf("usage: %s [-show] [-enough seconds] [-t seconds] <file.wmv>\n", argv[0]);
        return 1;
    }

    WCHAR wpath[MAX_PATH];
    if (!MultiByteToWideChar(CP_ACP, 0, path, -1, wpath, MAX_PATH)) {
        printf("FAIL  path does not convert: %s\n", path);
        return 1;
    }

    /* Unbuffered: this probe can be killed by the runner's timeout, and a
     * block-buffered stdout is discarded then -- "printed nothing" would read
     * as "hung on the first call" when it may have hung much later. */
    setvbuf(stdout, NULL, _IONBF, 0);

    CHECK("CoInitialize", CoInitialize(NULL));

    IGraphBuilder *graph = NULL;
    CHECK("CoCreateInstance(FilterGraph)",
          CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
                           &IID_IGraphBuilder, (void **)&graph));

    /* Headless by default: connect the video to a null renderer so no window
     * is needed, but the decoder still has a downstream sink to feed -- an
     * unconnected pin would not exercise the stall. */
    IBaseFilter *nullrend = NULL;
    if (!show) {
        HRESULT hr = CoCreateInstance(&CLSID_NullRendererLocal, NULL, CLSCTX_INPROC_SERVER,
                                      &IID_IBaseFilter, (void **)&nullrend);
        if (SUCCEEDED(hr))
            IGraphBuilder_AddFilter(graph, nullrend, L"null");
        else
            printf("note: no null renderer (0x%08lx), letting RenderFile pick a video renderer\n",
                   (unsigned long)hr);
    }

    printf("RenderFile: %s\n", path);
    CHECK("RenderFile", IGraphBuilder_RenderFile(graph, wpath, NULL));

    IMediaControl *ctrl = NULL;
    IMediaEvent *ev = NULL;
    CHECK("QI(IMediaControl)",
          IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&ctrl));
    CHECK("QI(IMediaEvent)",
          IGraphBuilder_QueryInterface(graph, &IID_IMediaEvent, (void **)&ev));

    IMediaSeeking *seek = NULL;
    LONGLONG duration = 0;
    if (SUCCEEDED(IGraphBuilder_QueryInterface(graph, &IID_IMediaSeeking, (void **)&seek))) {
        if (SUCCEEDED(IMediaSeeking_GetDuration(seek, &duration)))
            printf("duration: %.1f s\n", (double)duration / 1e7);
    }

    /* Never let the wall-clock budget undercut real-time playback -- that is
     * a test reporting a hang for a movie that is merely long. */
    double dur_s = (double)duration / 1e7;
    if (enough_s > 0 && dur_s > 0 && enough_s > (int)dur_s) enough_s = (int)dur_s;
    if (timeout_s <= 0) timeout_s = (enough_s > 0 ? enough_s : (int)dur_s) * 3 + 30;

    CHECK("Run", IMediaControl_Run(ctrl));

    /* Poll rather than one long WaitForCompletion so a stall reports the
     * position it froze at -- that is what separates "never started" from
     * "died partway". */
    DWORD start = GetTickCount();
    LONGLONG last_pos = -1;
    DWORD last_change = start;
    /* Without a readable position there is no clock to call stalled: graphs
     * ending in a null renderer can answer E_NOTIMPL, and treating "unknown"
     * as "frozen" would fail every healthy run of exactly the configuration
     * this test uses by default. */
    int have_pos = 0;
    for (;;) {
        long code = 0;
        LONG_PTR p1, p2;
        HRESULT hr = IMediaEvent_WaitForCompletion(ev, 500, &code);
        if (hr == S_OK && (code == EC_ERRORABORT || code == EC_USERABORT)) {
            printf("FAIL  graph aborted (event 0x%lx) -- not a stall\n",
                   (unsigned long)code);
            return 1;
        }
        if (hr == S_OK && code == EC_COMPLETE) {
            printf("PASS  played to completion (%.1f s wall)\n",
                   (GetTickCount() - start) / 1000.0);
            return 0;
        }
        while (SUCCEEDED(IMediaEvent_GetEvent(ev, &code, &p1, &p2, 0))) {
            if (code == EC_ERRORABORT || code == EC_USERABORT) {
                printf("FAIL  graph aborted, event 0x%lx param 0x%lx\n",
                       (unsigned long)code, (unsigned long)p1);
                return 1;
            }
            IMediaEvent_FreeEventParams(ev, code, p1, p2);
        }

        LONGLONG pos = 0;
        if (seek && SUCCEEDED(IMediaSeeking_GetCurrentPosition(seek, &pos))) {
            have_pos = 1;
            if (pos != last_pos) { last_pos = pos; last_change = GetTickCount(); }
        }

        double wall = (GetTickCount() - start) / 1000.0;
        double played = (double)last_pos / 1e7;

        /* Enough of the stream decoded at a sane rate answers the question. */
        if (enough_s > 0 && have_pos && played >= enough_s) {
            printf("PASS  played %.1f s of %.1f s in %.1f s wall (%.2fx realtime)\n",
                   played, dur_s, wall, wall > 0 ? played / wall : 0.0);
            return 0;
        }

        /* 15 s with the clock frozen is a stall, not slow decoding. This --
         * not the wall-clock budget -- is what identifies the hang. */
        if (have_pos && GetTickCount() - last_change >= 15000) {
            printf("FAIL  STALLED at position %.1f s of %.1f s (no progress for 15 s)\n",
                   played, dur_s);
            printf("      the graph is running but its clock stopped -- the game's hang\n");
            return 2;
        }
        if (wall >= timeout_s) {
            printf("FAIL  TIMED OUT after %.0fs at position %.1f s of %.1f s (%.2fx realtime)\n",
                   wall, played, dur_s, wall > 0 ? played / wall : 0.0);
            printf("      the clock advanced but far too slowly to be healthy playback\n");
            return 2;
        }
    }
}

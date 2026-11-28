/*
 * wmv-multi-render-test — minimal reproducer for DirectShow FilterGraph reuse stall.
 *
 * Reproduces the SF4 post-movie black-screen / hang bug in ~75 lines:
 *   Reuse a single IGraphBuilder across sequential clips:
 *     RenderFile(clip) -> Run() -> Stop() -> RemoveFilter(all)
 *   Verifies that CurrentPosition advances and IMediaControl_Stop() returns
 *   promptly without deadlocking in qasf's asf_reader_cleanup_stream().
 *
 * Build (32-bit, matching SSFIV.exe):
 *   i686-w64-mingw32-gcc -O2 -Wall -Wextra -o wmv-multi-render-test32.exe \
 *       wmv-multi-render-test.c -lole32 -loleaut32 -lstrmiids -luuid
 */
#define COBJMACROS
#include <windows.h>
#include <dshow.h>
#include <stdio.h>
#include <stdlib.h>

static void clear_graph(IGraphBuilder *graph)
{
    IEnumFilters *enm = NULL;
    IBaseFilter *filters[32];
    ULONG count = 0;

    if (FAILED(IGraphBuilder_EnumFilters(graph, &enm))) return;
    while (count < 32 && IEnumFilters_Next(enm, 1, &filters[count], NULL) == S_OK)
        count++;
    IEnumFilters_Release(enm);

    for (ULONG i = 0; i < count; i++) {
        IGraphBuilder_RemoveFilter(graph, filters[i]);
        IBaseFilter_Release(filters[i]);
    }
}

static int play_clip(IGraphBuilder *graph, IMediaControl *ctrl, IMediaSeeking *seek,
                     const WCHAR *path, int idx, int secs)
{
    HRESULT hr = IGraphBuilder_RenderFile(graph, path, NULL);
    printf("[%d] RenderFile hr=0x%08lx\n", idx, (unsigned long)hr);
    if (FAILED(hr)) return 1;

    hr = IMediaControl_Run(ctrl);
    printf("[%d] Run hr=0x%08lx\n", idx, (unsigned long)hr);
    if (FAILED(hr)) return 1;

    LONGLONG first = -1, last = -1;
    for (int i = 0; i < secs * 2; i++) {
        DWORD end = GetTickCount() + 500;
        MSG msg;
        while (GetTickCount() < end) {
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            Sleep(10);
        }
        LONGLONG cur = -1;
        IMediaSeeking_GetCurrentPosition(seek, &cur);
        if (i == 0 || first < 0) first = cur;
        last = cur;
        printf("[%d] t=%.1fs pos=%.3fs\n", idx, (i + 1) * 0.5, (double)cur / 10000000.0);
        if (idx == 0 && i == 1) {
            /* Live seek while State_Running (without Pause): exercises
             * qasf media_seeking_ChangeCurrent() decommit-before-stop +
             * re-commit-before-start without AB-BA deadlock. */
            LONGLONG zero = 0;
            HRESULT shr = IMediaSeeking_SetPositions(seek, &zero, AM_SEEKING_AbsolutePositioning,
                                                     NULL, AM_SEEKING_NoPositioning);
            printf("[%d] LiveSeek0=0x%08lx\n", idx, (unsigned long)shr);
            if (FAILED(shr)) return 1;
            first = -1;
        }
        if (idx == 1 && i == 1) {
            LONGLONG zero = 0;
            HRESULT phr = IMediaControl_Pause(ctrl);
            Sleep(150);
            HRESULT shr = IMediaSeeking_SetPositions(seek, &zero, AM_SEEKING_AbsolutePositioning,
                                                     NULL, AM_SEEKING_NoPositioning);
            HRESULT rhr = IMediaControl_Run(ctrl);
            printf("[%d] Pause=0x%08lx Seek0=0x%08lx Run=0x%08lx\n",
                   idx, (unsigned long)phr, (unsigned long)shr, (unsigned long)rhr);
            if (FAILED(phr) || FAILED(rhr)) return 1;
            first = -1;
        }
    }

    hr = IMediaControl_Stop(ctrl);
    printf("[%d] Stop hr=0x%08lx (advanced=%.3fs)\n",
           idx, (unsigned long)hr, (double)(last - first) / 10000000.0);
    if (idx == 0) {
        /* Exact SSFIV.exe pattern: Stop() -> SetPositions(beyond duration) while
         * State_Stopped -> Stop(). Must NOT start WMReader on a stopped graph. */
        LONGLONG dur = 0;
        IMediaSeeking_GetDuration(seek, &dur);
        LONGLONG past_end = (dur > 0 ? dur : 60000000LL) + 5000000LL;
        HRESULT shr = IMediaSeeking_SetPositions(seek, &past_end, AM_SEEKING_AbsolutePositioning,
                                                 NULL, AM_SEEKING_NoPositioning);
        HRESULT hr2 = IMediaControl_Stop(ctrl);
        printf("[%d] StoppedSeek(+0.5s)=0x%08lx Stop2=0x%08lx\n",
               idx, (unsigned long)shr, (unsigned long)hr2);
        if (FAILED(hr2)) return 1;
    }
    clear_graph(graph);
    return (last - first > 5000000) ? 0 : 1;
}

int main(int argc, char **argv)
{
    WCHAR w1[MAX_PATH], w2[MAX_PATH];
    if (argc < 3) {
        printf("usage: wmv-multi-render-test <clip1.wmv> <clip2.wmv>\n");
        return 2;
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    MultiByteToWideChar(CP_ACP, 0, argv[1], -1, w1, MAX_PATH);
    MultiByteToWideChar(CP_ACP, 0, argv[2], -1, w2, MAX_PATH);

    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    IGraphBuilder *graph = NULL;
    IMediaControl *ctrl = NULL;
    IMediaSeeking *seek = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
                                  &IID_IGraphBuilder, (void **)&graph);
    if (FAILED(hr)) { printf("FAIL CoCreateInstance 0x%08lx\n", (unsigned long)hr); return 1; }
    IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&ctrl);
    IGraphBuilder_QueryInterface(graph, &IID_IMediaSeeking, (void **)&seek);

    int failures = 0;
    const WCHAR *clips[3] = { w1, w2, w1 };
    for (int i = 0; i < 3; i++) {
        if (play_clip(graph, ctrl, seek, clips[i], i, 3) != 0) {
            printf("FAIL clip %d stalled!\n", i);
            failures++;
            break;
        }
    }
    IMediaSeeking_Release(seek);
    IMediaControl_Release(ctrl);
    IGraphBuilder_Release(graph);
    CoUninitialize();
    printf("failures=%d\n", failures);
    return failures;
}

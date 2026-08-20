/*
 * dsound-after-video-test — does DirectSound still play after a DirectShow
 * video has played?
 *
 *   wine dsound-after-video-test.exe [C:\path\to\movie.wmv]
 *
 * WHY. SSFIV's opening animation plays with sound and the main menu that
 * follows is silent. Those are two different audio paths: the movie is a
 * DirectShow graph (quartz + winegstreamer, ending in the DirectSound
 * renderer), while the game's own engine imports DSOUND.dll directly. So the
 * question is not "does Wine have audio" -- the movie proves it does -- but
 * whether a DirectSound device still works once a graph has had it.
 *
 * A snapshot of the game at the main menu had no audio threads at all: no
 * com.apple.audio.IOThread.client, no wine_dsound_mixer, no
 * audio_client_timer, where a snapshot taken during the movie had all three.
 * The output stream is not muted, it is never opened.
 *
 * NO EARS REQUIRED. The verdict is the play cursor: IDirectSoundBuffer's
 * GetCurrentPosition advances only while the buffer is really being consumed
 * by an output stream. A buffer that "plays" with a frozen cursor is silence,
 * and that is checkable in CI.
 *
 * Phases:
 *   1. DirectSound alone -- tone, cursor must advance   (baseline)
 *   2. a DirectShow graph plays the movie for a few seconds, then is released
 *   3. DirectSound again, same as phase 1               (the game's situation)
 *
 * Phase 1 passing and phase 3 failing is the bug, reproduced without the game.
 *
 * Exit: 0 both phases play, 1 setup failure, 2 phase 3 went silent,
 *       3 phase 1 already silent (audio is broken before the video, so this
 *         test cannot say anything about the video's effect).
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>   /* dsound.h uses LPWAVEFORMATEX without declaring it */
#include <dsound.h>
#include <dshow.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define TONE_HZ     440
#define SAMPLE_RATE 44100
#define TONE_MS     1500

static HWND g_win;

/* Plays a tone and reports whether the play cursor actually moved.
 * moved_out is the cursor delta in bytes. */
/* Returns the play-cursor delta in bytes; 0 means nothing came out, whether
 * because setup failed or because the buffer was not being consumed. The
 * per-failure printfs above each return carry which. */
static DWORD play_tone(const char *label)
{
    IDirectSound8 *ds = NULL;
    IDirectSoundBuffer *buf = NULL;
    DWORD moved = 0;
    HRESULT hr;

    hr = DirectSoundCreate8(NULL, &ds, NULL);
    if (FAILED(hr)) { printf("   %s: DirectSoundCreate8 = 0x%08lx\n", label, (unsigned long)hr); return 0; }

    hr = IDirectSound8_SetCooperativeLevel(ds, g_win, DSSCL_PRIORITY);
    if (FAILED(hr)) { printf("   %s: SetCooperativeLevel = 0x%08lx\n", label, (unsigned long)hr); goto done; }

    WAVEFORMATEX wf = { 0 };
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = 1;
    wf.nSamplesPerSec = SAMPLE_RATE;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = wf.nChannels * wf.wBitsPerSample / 8;
    wf.nAvgBytesPerSec = wf.nSamplesPerSec * wf.nBlockAlign;

    DWORD bytes = wf.nAvgBytesPerSec * TONE_MS / 1000;
    DSBUFFERDESC desc = { 0 };
    desc.dwSize = sizeof(desc);
    desc.dwFlags = DSBCAPS_GETCURRENTPOSITION2 | DSBCAPS_GLOBALFOCUS;
    desc.dwBufferBytes = bytes;
    desc.lpwfxFormat = &wf;

    hr = IDirectSound8_CreateSoundBuffer(ds, &desc, &buf, NULL);
    if (FAILED(hr)) { printf("   %s: CreateSoundBuffer = 0x%08lx\n", label, (unsigned long)hr); goto done; }

    void *p1 = NULL, *p2 = NULL;
    DWORD n1 = 0, n2 = 0;
    hr = IDirectSoundBuffer_Lock(buf, 0, bytes, &p1, &n1, &p2, &n2, 0);
    if (FAILED(hr)) { printf("   %s: Lock = 0x%08lx\n", label, (unsigned long)hr); goto done; }
    short *s = p1;
    for (DWORD i = 0; i < n1 / 2; i++)
        s[i] = (short)(8000.0 * sin(2.0 * 3.14159265 * TONE_HZ * i / SAMPLE_RATE));
    IDirectSoundBuffer_Unlock(buf, p1, n1, p2, n2);

    hr = IDirectSoundBuffer_Play(buf, 0, 0, 0);
    if (FAILED(hr)) { printf("   %s: Play = 0x%08lx\n", label, (unsigned long)hr); goto done; }

    /* The whole verdict. A cursor that does not move means the buffer is not
     * being consumed: Play() succeeded and nothing is coming out. */
    DWORD first = 0, last = 0;
    IDirectSoundBuffer_GetCurrentPosition(buf, &first, NULL);
    Sleep(500);
    IDirectSoundBuffer_GetCurrentPosition(buf, &last, NULL);
    moved = last >= first ? last - first : bytes - first + last;

    printf("   %s: cursor %lu -> %lu (%lu bytes in 500 ms, expected ~%lu)\n",
           label, (unsigned long)first, (unsigned long)last,
           (unsigned long)moved, (unsigned long)(wf.nAvgBytesPerSec / 2));
    IDirectSoundBuffer_Stop(buf);

done:
    if (buf) IDirectSoundBuffer_Release(buf);
    if (ds) IDirectSound8_Release(ds);
    return moved;
}

/* Plays the movie for a few seconds through a full DirectShow graph, then
 * tears it down -- the thing the game does before its menu goes silent. */
static HRESULT play_video(const WCHAR *path, int seconds)
{
    IGraphBuilder *graph = NULL;
    IMediaControl *ctrl = NULL;
    HRESULT hr;

    hr = CoCreateInstance(&CLSID_FilterGraph, NULL, CLSCTX_INPROC_SERVER,
                          &IID_IGraphBuilder, (void **)&graph);
    if (FAILED(hr)) return hr;

    hr = IGraphBuilder_RenderFile(graph, path, NULL);
    if (FAILED(hr)) { printf("   RenderFile = 0x%08lx\n", (unsigned long)hr); goto done; }

    hr = IGraphBuilder_QueryInterface(graph, &IID_IMediaControl, (void **)&ctrl);
    if (FAILED(hr)) goto done;

    hr = IMediaControl_Run(ctrl);
    if (FAILED(hr)) {
        /* Without this the graph never runs, phase 3 still "passes", and the
         * premise -- that a graph held the device -- was never established. */
        printf("   Run = 0x%08lx\n", (unsigned long)hr);
        goto done;
    }
    Sleep(seconds * 1000);
    IMediaControl_Stop(ctrl);

done:
    if (ctrl) IMediaControl_Release(ctrl);
    if (graph) IGraphBuilder_Release(graph);
    return hr;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    if (FAILED(CoInitialize(NULL))) { printf("FAIL  CoInitialize\n"); return 1; }

    /* DirectSound wants a window for SetCooperativeLevel. It never has to be
     * shown -- the buffer is DSBCAPS_GLOBALFOCUS, so it plays regardless. */
    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "dsafter";
    RegisterClassA(&wc);
    g_win = CreateWindowExA(0, "dsafter", "dsound-after-video-test", WS_OVERLAPPEDWINDOW,
                            0, 0, 320, 200, NULL, NULL, wc.hInstance, NULL);
    if (!g_win) { printf("FAIL  CreateWindow\n"); return 1; }

    DWORD before = 0, after = 0;

    printf("phase 1: DirectSound before any video\n");
    before = play_tone("before");
    if (!before) {
        printf("SKIP  the play cursor does not move even before a video plays --\n"
               "      DirectSound output is broken on its own, so this test cannot\n"
               "      say anything about the video's effect on it\n");
        return 3;
    }

    if (argc > 1) {
        printf("phase 2: playing %s through DirectShow for 4 s\n", argv[1]);
        WCHAR wpath[MAX_PATH];
        MultiByteToWideChar(CP_ACP, 0, argv[1], -1, wpath, MAX_PATH);
        HRESULT hr = play_video(wpath, 4);
        if (FAILED(hr)) { printf("FAIL  the video would not play (0x%08lx)\n", (unsigned long)hr); return 1; }
    } else {
        printf("phase 2: no movie given, skipping (pass one to test the transition)\n");
    }

    printf("phase 3: DirectSound after the graph was released\n");
    after = play_tone("after");

    printf("\n");
    if (!after) {
        printf("FAIL  DirectSound played before the video (%lu bytes) and is silent\n"
               "      after it (0) -- the game's menu-goes-quiet bug, without the game\n",
               (unsigned long)before);
        return 2;
    }
    printf("pass  DirectSound plays before (%lu bytes) and after (%lu bytes)\n",
           (unsigned long)before, (unsigned long)after);
    return 0;
}

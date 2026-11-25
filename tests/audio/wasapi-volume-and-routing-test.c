/*
 * Live WASAPI test for winecoreaudio.drv per-stream volume isolation and
 * DefaultOutput routing.
 *
 * Opens the default eRender endpoint in both float32 (mix format) and 16-bit
 * PCM, exercises ISimpleAudioVolume (SetMasterVolume + SetMute),
 * IAudioStreamVolume, IChannelAudioVolume, GetStreamLatency, Start/Stop and
 * render buffer submission.
 *
 * Driven by tests/audio/coreaudio-volume-and-routing-test.sh, which asserts
 * that macOS host system volume and mute state are NEVER altered.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audiopolicy.h>
#include <propsys.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        printf("FAIL: " fmt "\n", ##__VA_ARGS__); \
        failures++; \
    } else { \
        printf("PASS: " fmt "\n", ##__VA_ARGS__); \
    } \
} while (0)

static void exercise_stream(IMMDevice *dev, const char *label, const WAVEFORMATEX *override_fmt)
{
    IAudioClient *client = NULL;
    IAudioRenderClient *render = NULL;
    ISimpleAudioVolume *simple_vol = NULL;
    IAudioStreamVolume *stream_vol = NULL;
    IChannelAudioVolume *chan_vol = NULL;
    WAVEFORMATEX *mix_fmt = NULL;
    const WAVEFORMATEX *fmt = NULL;
    REFERENCE_TIME latency = 0;
    UINT32 buf_frames = 0, ch_count = 0;
    BYTE *data = NULL;
    float vol = -1.0f;
    BOOL muted = FALSE;
    HRESULT hr;

    hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    CHECK(SUCCEEDED(hr) && client, "[%s] Activate IAudioClient (hr=0x%08lx)", label, (unsigned long)hr);
    if (FAILED(hr) || !client) return;

    if (override_fmt) {
        fmt = override_fmt;
    } else {
        hr = IAudioClient_GetMixFormat(client, &mix_fmt);
        CHECK(SUCCEEDED(hr) && mix_fmt, "[%s] GetMixFormat (hr=0x%08lx)", label, (unsigned long)hr);
        if (FAILED(hr) || !mix_fmt) goto done;
        fmt = mix_fmt;
    }

    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0, fmt, NULL);
    CHECK(SUCCEEDED(hr), "[%s] Initialize shared stream (hr=0x%08lx)", label, (unsigned long)hr);
    if (FAILED(hr)) goto done;

    hr = IAudioClient_GetBufferSize(client, &buf_frames);
    CHECK(SUCCEEDED(hr) && buf_frames > 0, "[%s] GetBufferSize=%u (hr=0x%08lx)", label, buf_frames, (unsigned long)hr);

    /* Exercises unix_get_latency() on kAudioUnitSubType_DefaultOutput */
    hr = IAudioClient_GetStreamLatency(client, &latency);
    CHECK(SUCCEEDED(hr) && latency > 0, "[%s] GetStreamLatency=%lld (hr=0x%08lx)",
          label, (long long)latency, (unsigned long)hr);

    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render);
    CHECK(SUCCEEDED(hr) && render, "[%s] GetService IAudioRenderClient (hr=0x%08lx)", label, (unsigned long)hr);

    hr = IAudioClient_GetService(client, &IID_ISimpleAudioVolume, (void **)&simple_vol);
    CHECK(SUCCEEDED(hr) && simple_vol, "[%s] GetService ISimpleAudioVolume (hr=0x%08lx)", label, (unsigned long)hr);

    hr = IAudioClient_GetService(client, &IID_IAudioStreamVolume, (void **)&stream_vol);
    CHECK(SUCCEEDED(hr) && stream_vol, "[%s] GetService IAudioStreamVolume (hr=0x%08lx)", label, (unsigned long)hr);

    hr = IAudioClient_GetService(client, &IID_IChannelAudioVolume, (void **)&chan_vol);
    CHECK(SUCCEEDED(hr) && chan_vol, "[%s] GetService IChannelAudioVolume (hr=0x%08lx)", label, (unsigned long)hr);

    if (simple_vol) {
        hr = ISimpleAudioVolume_SetMasterVolume(simple_vol, 0.15f, NULL);
        CHECK(SUCCEEDED(hr), "[%s] SetMasterVolume(0.15) (hr=0x%08lx)", label, (unsigned long)hr);
        hr = ISimpleAudioVolume_GetMasterVolume(simple_vol, &vol);
        CHECK(SUCCEEDED(hr) && fabsf(vol - 0.15f) < 0.01f, "[%s] GetMasterVolume=%.2f", label, vol);
    }

    if (stream_vol) {
        hr = IAudioStreamVolume_GetChannelCount(stream_vol, &ch_count);
        CHECK(SUCCEEDED(hr) && ch_count == fmt->nChannels, "[%s] StreamVolume ch=%u", label, ch_count);
        if (ch_count >= 1) {
            hr = IAudioStreamVolume_SetChannelVolume(stream_vol, 0, 0.25f);
            CHECK(SUCCEEDED(hr), "[%s] StreamVolume SetChannelVolume(0, 0.25)", label);
        }
        if (ch_count >= 2) {
            hr = IAudioStreamVolume_SetChannelVolume(stream_vol, 1, 0.05f);
            CHECK(SUCCEEDED(hr), "[%s] StreamVolume SetChannelVolume(1, 0.05)", label);
        }
    }

    if (chan_vol) {
        hr = IChannelAudioVolume_GetChannelCount(chan_vol, &ch_count);
        CHECK(SUCCEEDED(hr) && ch_count == fmt->nChannels, "[%s] ChannelVolume ch=%u", label, ch_count);
        if (ch_count >= 1) {
            hr = IChannelAudioVolume_SetChannelVolume(chan_vol, 0, 0.5f, NULL);
            CHECK(SUCCEEDED(hr), "[%s] ChannelVolume SetChannelVolume(0, 0.5)", label);
        }
    }

    hr = IAudioClient_Start(client);
    CHECK(SUCCEEDED(hr), "[%s] Start (hr=0x%08lx)", label, (unsigned long)hr);

    /* Render silent frames at scaled volume, then mute and render again */
    if (render && buf_frames > 0) {
        UINT32 chunk = buf_frames / 4;
        if (chunk == 0) chunk = 1;
        hr = IAudioRenderClient_GetBuffer(render, chunk, &data);
        CHECK(SUCCEEDED(hr) && data, "[%s] GetBuffer(%u) scaled (hr=0x%08lx)", label, chunk, (unsigned long)hr);
        if (SUCCEEDED(hr) && data) {
            memset(data, 0, chunk * fmt->nBlockAlign);
            hr = IAudioRenderClient_ReleaseBuffer(render, chunk, 0);
            CHECK(SUCCEEDED(hr), "[%s] ReleaseBuffer scaled (hr=0x%08lx)", label, (unsigned long)hr);
        }
        Sleep(40);

        if (simple_vol) {
            hr = ISimpleAudioVolume_SetMute(simple_vol, TRUE, NULL);
            CHECK(SUCCEEDED(hr), "[%s] SetMute(TRUE) (hr=0x%08lx)", label, (unsigned long)hr);
            hr = ISimpleAudioVolume_GetMute(simple_vol, &muted);
            CHECK(SUCCEEDED(hr) && muted, "[%s] GetMute=%d", label, muted);
        }

        hr = IAudioRenderClient_GetBuffer(render, chunk, &data);
        if (SUCCEEDED(hr) && data) {
            memset(data, 0, chunk * fmt->nBlockAlign);
            hr = IAudioRenderClient_ReleaseBuffer(render, chunk, 0);
            CHECK(SUCCEEDED(hr), "[%s] ReleaseBuffer muted (hr=0x%08lx)", label, (unsigned long)hr);
        }
        Sleep(40);
    }

    hr = IAudioClient_Stop(client);
    CHECK(SUCCEEDED(hr), "[%s] Stop (hr=0x%08lx)", label, (unsigned long)hr);

done:
    if (chan_vol) IChannelAudioVolume_Release(chan_vol);
    if (stream_vol) IAudioStreamVolume_Release(stream_vol);
    if (simple_vol) ISimpleAudioVolume_Release(simple_vol);
    if (render) IAudioRenderClient_Release(render);
    if (mix_fmt) CoTaskMemFree(mix_fmt);
    if (client) IAudioClient_Release(client);
}

static void exercise_event_clock_and_rate(IMMDevice *dev)
{
    IAudioClient *client = NULL;
    IAudioRenderClient *render = NULL;
    IAudioClock *clock = NULL;
    IAudioClock2 *clock2 = NULL;
    IAudioClockAdjustment *rate_adj = NULL;
    WAVEFORMATEX *mix_fmt = NULL;
    HANDLE ev = NULL;
    UINT32 buf_frames = 0, pad = 0;
    UINT64 pos1 = 0, pos2 = 0, qpc1 = 0, qpc2 = 0, freq = 0;
    int wakes = 0, i;
    BYTE *data = NULL;
    HRESULT hr;

    hr = IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client);
    CHECK(SUCCEEDED(hr) && client, "[event-clock-rate] Activate IAudioClient (hr=0x%08lx)", (unsigned long)hr);
    if (FAILED(hr) || !client) return;

    hr = IAudioClient_GetMixFormat(client, &mix_fmt);
    CHECK(SUCCEEDED(hr) && mix_fmt, "[event-clock-rate] GetMixFormat (hr=0x%08lx)", (unsigned long)hr);
    if (FAILED(hr) || !mix_fmt) goto done;

    hr = IAudioClient_Initialize(client, AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_RATEADJUST,
            1000000, 0, mix_fmt, NULL);
    CHECK(SUCCEEDED(hr), "[event-clock-rate] Initialize EVENTCALLBACK|RATEADJUST (hr=0x%08lx)", (unsigned long)hr);
    if (FAILED(hr)) goto done;

    ev = CreateEventW(NULL, FALSE, FALSE, NULL);
    CHECK(ev != NULL, "[event-clock-rate] CreateEventW");
    hr = IAudioClient_SetEventHandle(client, ev);
    CHECK(SUCCEEDED(hr), "[event-clock-rate] SetEventHandle (hr=0x%08lx)", (unsigned long)hr);

    hr = IAudioClient_GetBufferSize(client, &buf_frames);
    CHECK(SUCCEEDED(hr) && buf_frames > 0, "[event-clock-rate] GetBufferSize=%u", buf_frames);

    hr = IAudioClient_GetService(client, &IID_IAudioRenderClient, (void **)&render);
    CHECK(SUCCEEDED(hr) && render, "[event-clock-rate] GetService IAudioRenderClient");

    hr = IAudioClient_GetService(client, &IID_IAudioClock, (void **)&clock);
    CHECK(SUCCEEDED(hr) && clock, "[event-clock-rate] GetService IAudioClock");

    if (clock) {
        hr = IAudioClock_QueryInterface(clock, &IID_IAudioClock2, (void **)&clock2);
        CHECK(SUCCEEDED(hr) && clock2, "[event-clock-rate] QueryInterface IAudioClock2 (hr=0x%08lx)", (unsigned long)hr);
        hr = IAudioClock_GetFrequency(clock, &freq);
        CHECK(SUCCEEDED(hr) && freq > 0, "[event-clock-rate] GetFrequency=%llu", (unsigned long long)freq);
    }

    hr = IAudioClient_GetService(client, &IID_IAudioClockAdjustment, (void **)&rate_adj);
    CHECK(SUCCEEDED(hr) && rate_adj, "[event-clock-rate] GetService IAudioClockAdjustment (hr=0x%08lx)", (unsigned long)hr);

    /* Validate sample-rate adjustment (valid + invalid rates) */
    if (rate_adj) {
        hr = IAudioClockAdjustment_SetSampleRate(rate_adj, 0.0f);
        CHECK(hr == E_INVALIDARG, "[event-clock-rate] SetSampleRate(0) rejected (hr=0x%08lx)", (unsigned long)hr);
        hr = IAudioClockAdjustment_SetSampleRate(rate_adj, 44100.0f);
        CHECK(SUCCEEDED(hr), "[event-clock-rate] SetSampleRate(44100) (hr=0x%08lx)", (unsigned long)hr);
        hr = IAudioClockAdjustment_SetSampleRate(rate_adj, (float)mix_fmt->nSamplesPerSec);
        CHECK(SUCCEEDED(hr), "[event-clock-rate] SetSampleRate(restore %lu) (hr=0x%08lx)",
              (unsigned long)mix_fmt->nSamplesPerSec, (unsigned long)hr);
    }

    /* Before Start(): event must NOT fire while stopped */
    CHECK(WaitForSingleObject(ev, 50) == WAIT_TIMEOUT, "[event-clock-rate] no spurious event before Start()");

    if (clock2) {
        hr = IAudioClock2_GetDevicePosition(clock2, &pos1, &qpc1);
        CHECK(SUCCEEDED(hr) && pos1 == 0 && qpc1 > 0,
              "[event-clock-rate] GetDevicePosition before Start: pos=%llu qpc=%llu (hr=0x%08lx)",
              (unsigned long long)pos1, (unsigned long long)qpc1, (unsigned long)hr);
    }

    hr = IAudioClient_Start(client);
    CHECK(SUCCEEDED(hr), "[event-clock-rate] Start (hr=0x%08lx)", (unsigned long)hr);

    /* Drive 6 real CoreAudio hardware callback wakeups */
    for (i = 0; i < 6; ++i) {
        DWORD wr = WaitForSingleObject(ev, 250);
        if (wr == WAIT_OBJECT_0) {
            wakes++;
            hr = IAudioClient_GetCurrentPadding(client, &pad);
            if (SUCCEEDED(hr) && buf_frames > pad) {
                UINT32 avail = buf_frames - pad;
                if (avail > buf_frames / 4) avail = buf_frames / 4;
                if (avail > 0 && SUCCEEDED(IAudioRenderClient_GetBuffer(render, avail, &data)) && data) {
                    memset(data, 0, avail * mix_fmt->nBlockAlign);
                    IAudioRenderClient_ReleaseBuffer(render, avail, 0);
                }
            }
        }
    }
    CHECK(wakes == 6, "[event-clock-rate] CoreAudio callback event wakes=%d/6", wakes);

    /* Check live rate adjustment while playing + synchronized IAudioClock::GetFrequency */
    if (rate_adj) {
        UINT64 freq2 = 0;
        hr = IAudioClockAdjustment_SetSampleRate(rate_adj, 44100.0f);
        CHECK(SUCCEEDED(hr), "[event-clock-rate] SetSampleRate(44100) while playing (hr=0x%08lx)", (unsigned long)hr);
        if (clock) {
            hr = IAudioClock_GetFrequency(clock, &freq2);
            CHECK(SUCCEEDED(hr) && freq2 == (UINT64)44100 * mix_fmt->nBlockAlign,
                  "[event-clock-rate] GetFrequency after SetSampleRate(44100)=%llu (expected %llu)",
                  (unsigned long long)freq2, (unsigned long long)44100 * mix_fmt->nBlockAlign);
        }
        Sleep(40);
    }

    if (clock2) {
        hr = IAudioClock2_GetDevicePosition(clock2, &pos2, &qpc2);
        CHECK(SUCCEEDED(hr) && pos2 > pos1 && qpc2 >= qpc1,
              "[event-clock-rate] GetDevicePosition advanced: %llu -> %llu (hr=0x%08lx)",
              (unsigned long long)pos1, (unsigned long long)pos2, (unsigned long)hr);
    }

    hr = IAudioClient_Stop(client);
    CHECK(SUCCEEDED(hr), "[event-clock-rate] Stop (hr=0x%08lx)", (unsigned long)hr);

    /* Windows WASAPI continues delivering periodic buffer events after Stop()/Reset()
     * until Release() even though CoreAudio's RT AudioUnit is stopped. */
    ResetEvent(ev);
    CHECK(WaitForSingleObject(ev, 100) == WAIT_OBJECT_0, "[event-clock-rate] periodic event continues after Stop()");
    hr = IAudioClient_Reset(client);
    CHECK(SUCCEEDED(hr), "[event-clock-rate] Reset (hr=0x%08lx)", (unsigned long)hr);
    ResetEvent(ev);
    CHECK(WaitForSingleObject(ev, 100) == WAIT_OBJECT_0, "[event-clock-rate] periodic event continues after Reset()");

done:
    if (rate_adj) IAudioClockAdjustment_Release(rate_adj);
    if (clock2) IAudioClock2_Release(clock2);
    if (clock) IAudioClock_Release(clock);
    if (render) IAudioRenderClient_Release(render);
    if (mix_fmt) CoTaskMemFree(mix_fmt);
    if (client) IAudioClient_Release(client);
    if (ev) CloseHandle(ev);
}

static void exercise_endpoint_properties(IMMDevice *dev)
{
    static const PROPERTYKEY pkey_form_factor = {
        { 0x1da5d803, 0xd492, 0x4edd, { 0x8c, 0x23, 0xe0, 0xc0, 0xff, 0xee, 0x7f, 0x0e } }, 0
    };
    static const PROPERTYKEY pkey_physical_speakers = {
        { 0x1da5d803, 0xd492, 0x4edd, { 0x8c, 0x23, 0xe0, 0xc0, 0xff, 0xee, 0x7f, 0x0e } }, 3
    };
    IPropertyStore *store = NULL;
    IAudioClient *client = NULL;
    WAVEFORMATEX *mix_fmt = NULL;
    PROPVARIANT pv;
    DWORD expected_mask = 0;
    HRESULT hr;

    hr = IMMDevice_OpenPropertyStore(dev, STGM_READ, &store);
    CHECK(SUCCEEDED(hr) && store, "[propstore] OpenPropertyStore (hr=0x%08lx)", (unsigned long)hr);
    if (FAILED(hr) || !store) return;

    PropVariantInit(&pv);
    hr = IPropertyStore_GetValue(store, &pkey_form_factor, &pv);
    CHECK(SUCCEEDED(hr) && pv.vt == VT_UI4 && pv.ulVal < EndpointFormFactor_enum_count,
          "[propstore] PKEY_AudioEndpoint_FormFactor=%lu (vt=%u hr=0x%08lx)",
          pv.vt == VT_UI4 ? (unsigned long)pv.ulVal : 0UL, pv.vt, (unsigned long)hr);
    PropVariantClear(&pv);

    if (SUCCEEDED(IMMDevice_Activate(dev, &IID_IAudioClient, CLSCTX_ALL, NULL, (void **)&client)) && client) {
        if (SUCCEEDED(IAudioClient_GetMixFormat(client, &mix_fmt)) && mix_fmt) {
            if (mix_fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE)
                expected_mask = ((WAVEFORMATEXTENSIBLE *)mix_fmt)->dwChannelMask;
            CoTaskMemFree(mix_fmt);
        }
        IAudioClient_Release(client);
    }

    PropVariantInit(&pv);
    hr = IPropertyStore_GetValue(store, &pkey_physical_speakers, &pv);
    CHECK(SUCCEEDED(hr) && pv.vt == VT_UI4 && pv.ulVal != 0 &&
          (!expected_mask || pv.ulVal == expected_mask),
          "[propstore] PKEY_AudioEndpoint_PhysicalSpeakers=0x%lx (expected 0x%lx, vt=%u hr=0x%08lx)",
          pv.vt == VT_UI4 ? (unsigned long)pv.ulVal : 0UL, (unsigned long)expected_mask,
          pv.vt, (unsigned long)hr);
    PropVariantClear(&pv);

    IPropertyStore_Release(store);
}

int main(void)
{
    IMMDeviceEnumerator *enumerator = NULL;
    IMMDevice *dev = NULL;
    WAVEFORMATEX pcm16;
    HRESULT hr;

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        printf("FAIL: CoInitializeEx hr=0x%08lx\n", (unsigned long)hr);
        return 1;
    }

    hr = CoCreateInstance(&CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
                          &IID_IMMDeviceEnumerator, (void **)&enumerator);
    CHECK(SUCCEEDED(hr) && enumerator, "CoCreateInstance MMDeviceEnumerator (hr=0x%08lx)", (unsigned long)hr);
    if (FAILED(hr) || !enumerator) goto exit;

    hr = IMMDeviceEnumerator_GetDefaultAudioEndpoint(enumerator, eRender, eConsole, &dev);
    CHECK(SUCCEEDED(hr) && dev, "GetDefaultAudioEndpoint eRender (hr=0x%08lx)", (unsigned long)hr);
    if (FAILED(hr) || !dev) goto exit;

    exercise_stream(dev, "mix-float32", NULL);

    memset(&pcm16, 0, sizeof(pcm16));
    pcm16.wFormatTag = WAVE_FORMAT_PCM;
    pcm16.nChannels = 2;
    pcm16.nSamplesPerSec = 48000;
    pcm16.wBitsPerSample = 16;
    pcm16.nBlockAlign = pcm16.nChannels * (pcm16.wBitsPerSample / 8);
    pcm16.nAvgBytesPerSec = pcm16.nSamplesPerSec * pcm16.nBlockAlign;
    exercise_stream(dev, "pcm16-stereo", &pcm16);

    exercise_event_clock_and_rate(dev);
    exercise_endpoint_properties(dev);

exit:
    if (dev) IMMDevice_Release(dev);
    if (enumerator) IMMDeviceEnumerator_Release(enumerator);
    CoUninitialize();

    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

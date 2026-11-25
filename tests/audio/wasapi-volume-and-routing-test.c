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

exit:
    if (dev) IMMDevice_Release(dev);
    if (enumerator) IMMDeviceEnumerator_Release(enumerator);
    CoUninitialize();

    printf("RESULT: %s (failures=%d)\n", failures ? "FAIL" : "OK", failures);
    return failures ? 1 : 0;
}

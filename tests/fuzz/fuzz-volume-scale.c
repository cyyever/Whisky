/*
 * libFuzzer target for winecoreaudio.drv/volume_scale.h.
 * Exercises ca_compute_channel_gains() and ca_scale_pcm_frames() across all
 * PCM formats, arbitrary channel/frame counts, adversarial float bit patterns
 * (NaN, Inf, denormals, negative values), and exact heap-sized buffers under
 * ASan + UBSan + LSan.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "volume_scale.h"

static size_t format_sample_bytes(enum ca_sample_format fmt)
{
    switch (fmt)
    {
    case CA_FMT_FLOAT32: return 4;
    case CA_FMT_PCM8:    return 1;
    case CA_FMT_PCM16:   return 2;
    case CA_FMT_PCM24:   return 3;
    case CA_FMT_PCM32:   return 4;
    default:             return 0;
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 8) return 0;

    enum ca_sample_format fmt = (enum ca_sample_format)(data[0] % 6);
    unsigned int nch = data[1] % 17;     /* 0..16 */
    unsigned int frames = data[2] % 65;  /* 0..64 */
    unsigned int flags = data[3];
    float master = 0.0f;
    memcpy(&master, data + 4, sizeof(master));

    const uint8_t *p = data + 8;
    size_t rem = size - 8;

    float *session_vols = NULL;
    float *stream_vols = NULL;
    float *gains = NULL;

    if (nch > 0)
    {
        gains = (float *)malloc(nch * sizeof(float));
        if (!gains) return 0;

        if (flags & 1)
        {
            session_vols = (float *)calloc(nch, sizeof(float));
            if (session_vols)
            {
                size_t copy = nch * sizeof(float);
                if (copy > rem) copy = rem;
                memcpy(session_vols, p, copy);
                p += copy;
                rem -= copy;
            }
        }
        if (flags & 2)
        {
            stream_vols = (float *)calloc(nch, sizeof(float));
            if (stream_vols)
            {
                size_t copy = nch * sizeof(float);
                if (copy > rem) copy = rem;
                memcpy(stream_vols, p, copy);
                p += copy;
                rem -= copy;
            }
        }
    }

    int is_unity = 0, is_muted = 0;
    ca_compute_channel_gains(nch, master, session_vols, stream_vols, gains, &is_unity, &is_muted);

    size_t sample_bytes = format_sample_bytes(fmt);
    size_t buf_bytes = (size_t)frames * (size_t)nch * sample_bytes;
    void *buf = NULL;
    if (buf_bytes > 0)
    {
        buf = calloc(1, buf_bytes);
        if (buf)
        {
            size_t copy = buf_bytes < rem ? buf_bytes : rem;
            if (copy > 0) memcpy(buf, p, copy);
            ca_scale_pcm_frames(buf, frames, nch, fmt, gains);
        }
    }
    else
    {
        ca_scale_pcm_frames(NULL, frames, nch, fmt, gains);
    }

    free(buf);
    free(stream_vols);
    free(session_vols);
    free(gains);
    return 0;
}

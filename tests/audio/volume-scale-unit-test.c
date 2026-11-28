/*
 * Host unit test for winecoreaudio.drv per-stream software volume scaling
 * (dlls/winecoreaudio.drv/volume_scale.h).
 *
 * Exercises the exact production scaling helpers across all 5 linear PCM
 * formats (FLOAT32, PCM16, PCM24, PCM32, PCM8), independent L/R channel gains,
 * master * session * stream gain composition, unity/muted fast-path flags,
 * NaN/negative sanitization, and saturation clamping.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "volume_scale.h"

static int failures = 0;

#define CHECK(cond, fmt, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL (%s:%d): " fmt "\n", __FILE__, __LINE__, ##__VA_ARGS__); \
        failures++; \
    } \
} while (0)

static void test_gain_computation(void)
{
    float sess[2] = { 0.5f, 1.0f };
    float strm[2] = { 0.5f, 0.25f };
    float out[2] = { -1.0f, -1.0f };
    int unity = -1, muted = -1;

    /* Default unity */
    ca_compute_channel_gains(2, 1.0f, NULL, NULL, out, &unity, &muted);
    CHECK(unity == 1 && muted == 0, "default should be unity=1 muted=0");
    CHECK(out[0] == 1.0f && out[1] == 1.0f, "default gains should be 1.0");

    /* Composition: master * session * stream */
    ca_compute_channel_gains(2, 0.8f, sess, strm, out, &unity, &muted);
    CHECK(unity == 0 && muted == 0, "0.8*sess*strm should be non-unity non-muted");
    CHECK(fabsf(out[0] - 0.2f) < 1e-6f, "ch0 expected 0.2 got %f", out[0]);
    CHECK(fabsf(out[1] - 0.2f) < 1e-6f, "ch1 expected 0.2 got %f", out[1]);

    /* Muted via master == 0 */
    ca_compute_channel_gains(2, 0.0f, sess, strm, out, &unity, &muted);
    CHECK(unity == 0 && muted == 1, "master=0 should be muted=1");
    CHECK(out[0] == 0.0f && out[1] == 0.0f, "muted gains should be 0.0");

    /* Negative and NaN sanitized to 0 */
    float bad[2] = { -2.0f, NAN };
    ca_compute_channel_gains(2, 1.0f, bad, NULL, out, &unity, &muted);
    CHECK(unity == 0 && muted == 1, "negative/NaN should sanitize to muted=1");
    CHECK(out[0] == 0.0f && out[1] == 0.0f, "negative/NaN should become 0.0");
}

static void test_float32(void)
{
    float buf[4] = { 1.0f, -1.0f, 0.5f, -0.25f };
    float gains[2] = { 0.5f, 0.25f };

    ca_scale_pcm_frames(buf, 2, 2, CA_FMT_FLOAT32, gains);
    CHECK(fabsf(buf[0] - 0.5f) < 1e-6f, "f32[0]=%f", buf[0]);
    CHECK(fabsf(buf[1] - (-0.25f)) < 1e-6f, "f32[1]=%f", buf[1]);
    CHECK(fabsf(buf[2] - 0.25f) < 1e-6f, "f32[2]=%f", buf[2]);
    CHECK(fabsf(buf[3] - (-0.0625f)) < 1e-6f, "f32[3]=%f", buf[3]);
}

static void test_pcm16(void)
{
    int16_t buf[4] = { 20000, -20000, 30000, -30000 };
    float gains[2] = { 0.5f, 2.0f }; /* ch1 > 1.0 tests saturation clamp */

    ca_scale_pcm_frames(buf, 2, 2, CA_FMT_PCM16, gains);
    CHECK(buf[0] == 10000, "i16[0]=%d", buf[0]);
    CHECK(buf[1] == -32768, "i16[1]=%d expected clamp -32768", buf[1]);
    CHECK(buf[2] == 15000, "i16[2]=%d", buf[2]);
    CHECK(buf[3] == -32768, "i16[3]=%d expected clamp -32768", buf[3]);
}

static void pack_i24(uint8_t *dst, int32_t v)
{
    uint32_t u = (uint32_t)v;
    dst[0] = (uint8_t)(u & 0xffu);
    dst[1] = (uint8_t)((u >> 8) & 0xffu);
    dst[2] = (uint8_t)((u >> 16) & 0xffu);
}

static int32_t unpack_i24(const uint8_t *src)
{
    uint32_t u = (uint32_t)src[0] | ((uint32_t)src[1] << 8) | ((uint32_t)src[2] << 16);
    return (int32_t)(u ^ 0x800000u) - 0x800000;
}

static void test_pcm24(void)
{
    uint8_t buf[6];
    float gains[2] = { 0.5f, 0.25f };

    pack_i24(&buf[0], 4000000);
    pack_i24(&buf[3], -4000000);
    ca_scale_pcm_frames(buf, 1, 2, CA_FMT_PCM24, gains);
    CHECK(unpack_i24(&buf[0]) == 2000000, "i24[0]=%d", unpack_i24(&buf[0]));
    CHECK(unpack_i24(&buf[3]) == -1000000, "i24[1]=%d", unpack_i24(&buf[3]));
}

static void test_pcm32(void)
{
    int32_t buf[2] = { 1000000000, -2000000000 };
    float gains[2] = { 0.25f, 2.0f };

    ca_scale_pcm_frames(buf, 1, 2, CA_FMT_PCM32, gains);
    CHECK(buf[0] == 250000000, "i32[0]=%d", buf[0]);
    CHECK(buf[1] == INT32_MIN, "i32[1]=%d expected INT32_MIN", buf[1]);
}

static void test_pcm8(void)
{
    uint8_t buf[2] = { 228, 28 }; /* +100 and -100 around midpoint 128 */
    float gains[2] = { 0.5f, 0.0f };

    ca_scale_pcm_frames(buf, 1, 2, CA_FMT_PCM8, gains);
    CHECK(buf[0] == 178, "u8[0]=%u expected 178", buf[0]);
    CHECK(buf[1] == 128, "u8[1]=%u expected silence midpoint 128", buf[1]);
}

#if defined(__has_attribute) && __has_attribute(nonblocking)
#define WHISKY_NONBLOCKING __attribute__((nonblocking))
#else
#define WHISKY_NONBLOCKING
#endif

static void rtsan_verify_all_formats(void) WHISKY_NONBLOCKING
{
    float gains[2] = { 0.5f, 0.25f };
    float stream_vols[2] = { 1.0f, 0.5f };
    float chan_vols[2] = { 0.5f, 1.0f };
    float f32[4] = { 0.5f, -0.5f, 1.0f, -1.0f };
    int16_t s16[4] = { 1000, -1000, 32767, -32768 };
    uint8_t s24[6] = { 0x00, 0x00, 0x40, 0x00, 0x00, 0xc0 };
    int32_t s32[4] = { 100000, -100000, INT32_MAX, INT32_MIN + 1 };
    uint8_t u8[4] = { 228, 28, 128, 255 };

    int is_unity = 0, is_muted = 0;

    ca_compute_channel_gains(2, 0.5f, stream_vols, chan_vols, gains, &is_unity, &is_muted);
    ca_scale_pcm_frames(f32, 2, 2, CA_FMT_FLOAT32, gains);
    ca_scale_pcm_frames(s16, 2, 2, CA_FMT_PCM16, gains);
    ca_scale_pcm_frames(s24, 1, 2, CA_FMT_PCM24, gains);
    ca_scale_pcm_frames(s32, 2, 2, CA_FMT_PCM32, gains);
    ca_scale_pcm_frames(u8, 2, 2, CA_FMT_PCM8, gains);
}

int main(void)
{
    test_gain_computation();
    test_float32();
    test_pcm16();
    test_pcm24();
    test_pcm32();
    test_pcm8();
    rtsan_verify_all_formats();

    printf("volume-scale-unit-test: %s (failures=%d)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}

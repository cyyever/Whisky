/*
 * libFuzzer target for macOS/BSD -> Windows WSACMSGHDR IP_RECVTOS / IP_RECVTTL
 * control-header conversion logic (patches/proton-wine/0009).
 * Verifies zero out-of-bounds reads/writes and zero UB on arbitrary or
 * truncated cmsghdr streams and tight destination buffers.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>

struct ws_cmsghdr
{
    uint64_t cmsg_len;
    int32_t  cmsg_level;
    int32_t  cmsg_type;
};

#define WS_CMSG_ALIGN(len) (((len) + sizeof(uint64_t) - 1) & ~(sizeof(uint64_t) - 1))
#define WS_CMSG_HDRLEN     WS_CMSG_ALIGN(sizeof(struct ws_cmsghdr))
#define WS_CMSG_LEN(len)   (WS_CMSG_HDRLEN + (len))
#define WS_CMSG_SPACE(len) (WS_CMSG_HDRLEN + WS_CMSG_ALIGN(len))
#define WS_IP_TOS          3
#define WS_IP_TTL          4

static size_t convert_ip_cmsgs(const uint8_t *src, size_t src_len,
                               uint8_t *dst, size_t dst_cap, int *truncated)
{
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_control = (void *)src;
    msg.msg_controllen = (socklen_t)src_len;

    size_t out_off = 0;
    *truncated = 0;

    for (struct cmsghdr *hdr = CMSG_FIRSTHDR(&msg); hdr != NULL; hdr = CMSG_NXTHDR(&msg, hdr))
    {
        if (hdr->cmsg_len < CMSG_LEN(0)) break;
        const uint8_t *hdr_start = (const uint8_t *)hdr;
        if (hdr_start < src || (size_t)(hdr_start - src) > src_len) break;
        if (hdr->cmsg_len > src_len - (size_t)(hdr_start - src)) break;

        size_t payload_len = hdr->cmsg_len - CMSG_LEN(0);
        if (hdr->cmsg_level != IPPROTO_IP) continue;

        int32_t ws_type = 0;
        if (hdr->cmsg_type == IP_TOS || hdr->cmsg_type == IP_RECVTOS)
            ws_type = WS_IP_TOS;
        else if (hdr->cmsg_type == IP_TTL || hdr->cmsg_type == IP_RECVTTL)
            ws_type = WS_IP_TTL;
        else
            continue;

        int32_t val = 0;
        const uint8_t *payload = CMSG_DATA(hdr);
        if (payload_len == sizeof(unsigned char))
            val = payload[0];
        else if (payload_len >= sizeof(int32_t))
            memcpy(&val, payload, sizeof(val));
        else
            continue;

        size_t need = WS_CMSG_SPACE(sizeof(val));
        if (need > dst_cap - out_off)
        {
            *truncated = 1;
            break;
        }
        struct ws_cmsghdr wh;
        wh.cmsg_len = WS_CMSG_LEN(sizeof(val));
        wh.cmsg_level = IPPROTO_IP;
        wh.cmsg_type = ws_type;
        memset(dst + out_off, 0, need);
        memcpy(dst + out_off, &wh, sizeof(wh));
        memcpy(dst + out_off + WS_CMSG_HDRLEN, &val, sizeof(val));
        out_off += need;
    }
    return out_off;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 2) return 0;

    size_t dst_cap = data[0];
    size_t src_len = size - 1;
    if (src_len > 4096) src_len = 4096;

    uint8_t *src = (uint8_t *)malloc(src_len > 0 ? src_len : 1);
    uint8_t *dst = (uint8_t *)malloc(dst_cap > 0 ? dst_cap : 1);
    if (!src || !dst)
    {
        free(src);
        free(dst);
        return 0;
    }
    if (src_len > 0) memcpy(src, data + 1, src_len);

    int truncated = 0;
    size_t written = convert_ip_cmsgs(src, src_len, dst, dst_cap, &truncated);
    if (written > dst_cap) __builtin_trap();

    free(dst);
    free(src);
    return 0;
}

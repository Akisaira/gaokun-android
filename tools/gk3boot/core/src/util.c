/* libgk3core：freestanding 小工具 —— 内存、小端、CRC32、SHA-1、错误串。 */
#include "gk3core.h"

const char *gk3_strerror(gk3_err e)
{
    switch (e) {
    case GK3_OK: return "ok";
    case GK3_EIO: return "io error";
    case GK3_EINVAL: return "invalid argument";
    case GK3_EMAGIC: return "bad magic";
    case GK3_EVERSION: return "unsupported version";
    case GK3_ECRC: return "bad crc";
    case GK3_ERANGE: return "out of range";
    case GK3_ENOENT: return "not found";
    case GK3_EDUP: return "duplicate";
    case GK3_ENOSPC: return "buffer too small";
    case GK3_EVERIFY: return "verify mismatch";
    case GK3_ESLOTS: return "nb_slot != 2";
    }
    return "?";
}

/* 逐字节实现，故意不交给编译器内建：EFI 侧没有 libc 的 memcpy 可链。
 * volatile 指针防止 clang 把循环识别回 memcpy/memset 调用。 */
void gk3_memcpy(void *dst, const void *src, size_t n)
{
    volatile uint8_t *d = dst;
    const uint8_t *s = src;
    while (n--)
        *d++ = *s++;
}

void gk3_memset(void *dst, int c, size_t n)
{
    volatile uint8_t *d = dst;
    while (n--)
        *d++ = (uint8_t)c;
}

int gk3_memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y)
            return *x < *y ? -1 : 1;
    return 0;
}

size_t gk3_strnlen(const char *s, size_t max)
{
    size_t n = 0;
    while (n < max && s[n])
        n++;
    return n;
}

bool gk3_is_zero(const void *p, size_t n)
{
    const uint8_t *b = p;
    while (n--)
        if (*b++)
            return false;
    return true;
}

uint16_t gk3_le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
uint32_t gk3_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
uint64_t gk3_le64(const uint8_t *p) { return (uint64_t)gk3_le32(p) | ((uint64_t)gk3_le32(p + 4) << 32); }
void gk3_put_le16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
void gk3_put_le32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
void gk3_put_le64(uint8_t *p, uint64_t v) { gk3_put_le32(p, (uint32_t)v); gk3_put_le32(p + 4, (uint32_t)(v >> 32)); }

/* ---------------------------------------------------------------- CRC32
 * 无表逐位算法，与 libboot_control.cpp:50-71 生成表的递推相同（0xEDB88320、按位 mask）。
 * 只算 misc 里几十字节和 16 KiB 的 GPT 表，不值得常驻 1 KiB 的表。 */
uint32_t gk3_crc32(uint32_t crc, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    crc = ~crc;
    while (len--) {
        crc ^= *p++;
        for (int j = 0; j < 8; j++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

/* ---------------------------------------------------------------- SHA-1（FIPS 180-4 §6.1） */

static uint32_t rol(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

static void sha1_block(uint32_t h[5], const uint8_t *p)
{
    uint32_t w[80], a, b, c, d, e, t;
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
               ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
    for (int i = 16; i < 80; i++)
        w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999u; }
        else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1u; }
        else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCu; }
        else { f = b ^ c ^ d; k = 0xCA62C1D6u; }
        t = rol(a, 5) + f + e + k + w[i];
        e = d; d = c; c = rol(b, 30); b = a; a = t;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

void gk3_sha1_init(gk3_sha1_ctx *c)
{
    c->h[0] = 0x67452301u; c->h[1] = 0xEFCDAB89u; c->h[2] = 0x98BADCFEu;
    c->h[3] = 0x10325476u; c->h[4] = 0xC3D2E1F0u;
    c->len = 0;
    c->fill = 0;
}

void gk3_sha1_update(gk3_sha1_ctx *c, const void *data, size_t len)
{
    const uint8_t *p = data;
    c->len += len;
    if (c->fill) {
        while (len && c->fill < 64) {
            c->buf[c->fill++] = *p++;
            len--;
        }
        if (c->fill < 64)
            return;
        sha1_block(c->h, c->buf);
        c->fill = 0;
    }
    while (len >= 64) {
        sha1_block(c->h, p);
        p += 64;
        len -= 64;
    }
    while (len--)
        c->buf[c->fill++] = *p++;
}

void gk3_sha1_final(gk3_sha1_ctx *c, uint8_t out[20])
{
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80, zero = 0, lenb[8];
    gk3_sha1_update(c, &pad, 1);
    while (c->fill != 56)
        gk3_sha1_update(c, &zero, 1);
    for (int i = 0; i < 8; i++)
        lenb[i] = (uint8_t)(bits >> (56 - 8 * i));
    gk3_sha1_update(c, lenb, 8);
    for (int i = 0; i < 5; i++) {
        out[4 * i] = (uint8_t)(c->h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(c->h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(c->h[i] >> 8);
        out[4 * i + 3] = (uint8_t)c->h[i];
    }
}

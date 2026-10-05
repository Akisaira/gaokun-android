/* gk3-fastbootd：super 的 LP 元数据（只读）+ SHA-256。
 *
 * 布局（refs/lineage-system-core/fs_mgr/liblp/）：
 *   include/liblp/metadata_format.h:32-43   几何区魔数 0x616c4467、几何区 4096 字节、头魔数 0x414C5030、major 10、minor 0–2
 *   :116-144  LpMetadataGeometry：magic / struct_size / checksum[32] / metadata_max_size / metadata_slot_count / logical_block_size
 *   :182-236  LpMetadataHeader：magic / major u16 / minor u16 / header_size / header_checksum[32] / tables_size /
 *             tables_checksum[32] / 4 个表描述符（offset/num_entries/entry_size）/ [v1.2+] flags + reserved[124]
 *   :249-273  LpMetadataPartition：name[36] / attributes / first_extent_index / num_extents / group_index
 *   utility.cpp:75-89   几何区在 4096（主）/ 8192（备）；槽 s 的主元数据在 4096 + 2*4096 + s*metadata_max_size
 *   reader.cpp:85-97、:207-216、:276-279   三处 SHA-256：几何区（校验时 checksum 字段清零，按 struct_size 算）、
 *             头（header_checksum 清零，按 header_size 算）、表（tables_size 字节）
 * 只读主几何区和主元数据；坏了就报错，不去读备份 —— 我们只拿它做"刷完 super 后这份元数据服务哪个槽"的判断。
 */
#include <stdlib.h>
#include <string.h>

#include "fbd.h"

/* ---------------------------------------------------------------- SHA-256（FIPS 180-4） */

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const uint8_t *p)
{
    uint32_t w[64], a, b, c, d, e, f, g, hh;
    for (int i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = hh + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

void fb_sha256(const void *data, size_t len, uint8_t out[32])
{
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    const uint8_t *p = data;
    uint8_t tail[128];
    size_t full = len & ~(size_t)63, rem = len - full, tl;
    uint64_t bits = (uint64_t)len * 8;
    for (size_t i = 0; i < full; i += 64)
        sha256_block(h, p + i);
    memset(tail, 0, sizeof(tail));
    memcpy(tail, p + full, rem);
    tail[rem] = 0x80;
    tl = rem + 1 + 8 <= 64 ? 64 : 128;
    for (int i = 0; i < 8; i++)
        tail[tl - 1 - i] = (uint8_t)(bits >> (8 * i));
    sha256_block(h, tail);
    if (tl == 128)
        sha256_block(h, tail + 64);
    for (int i = 0; i < 8; i++) {
        out[4 * i] = (uint8_t)(h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(h[i] >> 8);
        out[4 * i + 3] = (uint8_t)h[i];
    }
}

/* ---------------------------------------------------------------- LP */

#define LP_RESERVED     4096u
#define LP_GEOM_SIZE    4096u
#define LP_GEOM_MAGIC   0x616c4467u
#define LP_HDR_MAGIC    0x414C5030u
#define LP_MAJOR        10u
#define LP_MINOR_MAX    2u
#define LP_HDR_V1_0     128u
#define LP_HDR_V1_2     256u
#define LP_PART_ENTRY   52u      /* sizeof(LpMetadataPartition) */
#define LP_MAX_META     (1u << 20)

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

const char *fb_lp_read(int (*rd)(void *ctx, uint64_t off, void *buf, size_t len), void *ctx,
                       uint32_t slot, fb_lp *out)
{
    uint8_t geo[LP_GEOM_SIZE], tmp[LP_HDR_V1_2], sum[32];
    uint8_t *hdr = NULL, *tab = NULL;
    uint32_t ssize, hsize, tsize;
    const char *err = NULL;

    memset(out, 0, sizeof(*out));
    if (rd(ctx, LP_RESERVED, geo, sizeof(geo)))
        return "lp: cannot read geometry";
    if (rd32(geo) != LP_GEOM_MAGIC)
        return "lp: bad geometry magic (not a super image?)";
    ssize = rd32(geo + 4);
    if (ssize < 52 || ssize > sizeof(geo))
        return "lp: bad geometry struct_size";
    memcpy(tmp, geo, ssize < sizeof(tmp) ? ssize : sizeof(tmp));
    {
        uint8_t g2[LP_GEOM_SIZE];
        memcpy(g2, geo, ssize);
        memset(g2 + 8, 0, 32);
        fb_sha256(g2, ssize, sum);
    }
    if (memcmp(sum, geo + 8, 32))
        return "lp: geometry checksum mismatch";
    out->metadata_max_size = rd32(geo + 40);
    out->metadata_slot_count = rd32(geo + 44);
    out->logical_block_size = rd32(geo + 48);
    if (out->metadata_max_size < LP_HDR_V1_0 || out->metadata_max_size > LP_MAX_META || (out->metadata_max_size % 512))
        return "lp: bad metadata_max_size";
    if (out->metadata_slot_count == 0 || out->metadata_slot_count > 3)
        return "lp: bad metadata_slot_count";
    if (slot >= out->metadata_slot_count)
        return "lp: no metadata for this slot";

    hdr = malloc(out->metadata_max_size);
    if (!hdr)
        return "lp: out of memory";
    if (rd(ctx, (uint64_t)LP_RESERVED + 2u * LP_GEOM_SIZE + (uint64_t)slot * out->metadata_max_size, hdr,
           out->metadata_max_size)) {
        err = "lp: cannot read metadata";
        goto done;
    }
    if (rd32(hdr) != LP_HDR_MAGIC) {
        err = "lp: bad metadata header magic";
        goto done;
    }
    out->major = rd16(hdr + 4);
    out->minor = rd16(hdr + 6);
    hsize = rd32(hdr + 8);
    if (out->major != LP_MAJOR || out->minor > LP_MINOR_MAX) {
        err = "lp: unsupported metadata version";
        goto done;
    }
    if (hsize != (out->minor >= 2 ? LP_HDR_V1_2 : LP_HDR_V1_0)) {
        err = "lp: bad header_size";
        goto done;
    }
    memcpy(tmp, hdr, hsize);
    memset(tmp + 12, 0, 32);
    fb_sha256(tmp, hsize, sum);
    if (memcmp(sum, hdr + 12, 32)) {
        err = "lp: header checksum mismatch";
        goto done;
    }
    tsize = rd32(hdr + 44);
    if (tsize > out->metadata_max_size - hsize) {
        err = "lp: tables_size out of range";
        goto done;
    }
    tab = hdr + hsize;
    fb_sha256(tab, tsize, sum);
    if (memcmp(sum, hdr + 48, 32)) {
        err = "lp: tables checksum mismatch";
        goto done;
    }
    out->flags = out->minor >= 2 ? rd32(hdr + 128) : 0;
    {
        uint32_t poff = rd32(hdr + 80), pn = rd32(hdr + 84), pes = rd32(hdr + 88);
        if (pes != LP_PART_ENTRY || (uint64_t)poff + (uint64_t)pn * pes > tsize) {
            err = "lp: partition table out of range";
            goto done;
        }
        for (uint32_t i = 0; i < pn && out->n_parts < FB_LP_MAX_PARTS; i++) {
            const uint8_t *e = tab + poff + (size_t)i * pes;
            size_t nl = strnlen((const char *)e, 36);
            memcpy(out->parts[out->n_parts].name, e, nl);
            out->parts[out->n_parts].name[nl] = 0;
            out->parts[out->n_parts].attrs = rd32(e + 36);
            out->parts[out->n_parts].num_extents = rd32(e + 44);
            out->n_parts++;
        }
    }
done:
    free(hdr);
    return err;
}

bool fb_lp_serves_slot(const fb_lp *lp, unsigned slot)
{
    char suf[3] = {'_', (char)('a' + (slot & 1)), 0};
    for (uint32_t i = 0; i < lp->n_parts; i++) {
        size_t n = strlen(lp->parts[i].name);
        if (n > 2 && !strcmp(lp->parts[i].name + n - 2, suf))
            return true;
    }
    return false;
}

/* libgk3core：GPT（UEFI 2.10 §5.3）。只解析主表，不读备份、不修表（§4.9：GPT 只读、只信主表）。
 *
 * 为什么不用固件的 EFI_PARTITION_INFO：PartitionDxe 在主备不一致时会自己写盘修备份表（§2.1），
 * 而我们要的"名字唯一"判据它不提供；入口自己解析主表，行为在 QEMU / 主机测试里可复现。 */
#include "gk3core.h"

#define HDR_MIN 92u
#define MAX_TABLE_BYTES (1u << 20)   /* 表最多 1 MiB（常规 128×128 = 16 KiB），挡住坏头里的天文数字 */

gk3_err gk3_gpt_parse_header(const uint8_t *h, uint32_t bs, gk3_gpt *g)
{
    uint8_t tmp[512];
    uint32_t hsize, crc;
    uint64_t table_bytes, table_blocks;

    if (bs < 512 || (bs & (bs - 1)))
        return GK3_EINVAL;
    if (gk3_memcmp(h, "EFI PART", 8))
        return GK3_EMAGIC;
    if (gk3_le32(h + 8) != 0x00010000u)
        return GK3_EVERSION;
    hsize = gk3_le32(h + 12);
    if (hsize < HDR_MIN || hsize > bs || hsize > sizeof(tmp))
        return GK3_ERANGE;
    gk3_memcpy(tmp, h, hsize);
    gk3_put_le32(tmp + 16, 0);
    crc = gk3_crc32(0, tmp, hsize);
    if (crc != gk3_le32(h + 16))
        return GK3_ECRC;

    gk3_memset(g, 0, sizeof(*g));
    g->block_size = bs;
    g->my_lba = gk3_le64(h + 24);
    g->alt_lba = gk3_le64(h + 32);
    g->first_usable = gk3_le64(h + 40);
    g->last_usable = gk3_le64(h + 48);
    gk3_memcpy(g->disk_guid, h + 56, 16);
    g->entries_lba = gk3_le64(h + 72);
    g->num_entries = gk3_le32(h + 80);
    g->entry_size = gk3_le32(h + 84);

    if (g->my_lba != 1)
        return GK3_ERANGE;                       /* 这不是主表头 */
    if (g->first_usable > g->last_usable)
        return GK3_ERANGE;
    /* 表项大小必须是 128·2^n（UEFI 2.10 §5.3.2） */
    if (g->entry_size < 128 || (g->entry_size & (g->entry_size - 1)))
        return GK3_ERANGE;
    if (g->num_entries == 0)
        return GK3_ERANGE;
    table_bytes = (uint64_t)g->num_entries * g->entry_size;
    if (table_bytes > MAX_TABLE_BYTES)
        return GK3_ERANGE;
    table_blocks = (table_bytes + bs - 1) / bs;
    /* 主表的表项在头之后、usable 区之前 */
    if (g->entries_lba < 2 || g->entries_lba > g->first_usable ||
        g->first_usable - g->entries_lba < table_blocks)
        return GK3_ERANGE;
    return GK3_OK;
}

/* 表 CRC（头偏移 88）只覆盖 num_entries*entry_size，不含块尾的填充。 */
static gk3_err check_entries(gk3_gpt *g, const uint8_t *entries, size_t len, uint32_t want_crc)
{
    uint64_t table_bytes = (uint64_t)g->num_entries * g->entry_size;
    if (len < table_bytes)
        return GK3_ENOSPC;
    if (gk3_crc32(0, entries, (size_t)table_bytes) != want_crc)
        return GK3_ECRC;
    g->entries = entries;
    return GK3_OK;
}

gk3_err gk3_gpt_read(const gk3_blk *dev, gk3_gpt *out, uint8_t *hdr_scratch,
                     uint8_t *entries_buf, size_t entries_buf_len)
{
    gk3_err e;
    uint32_t want_crc;
    uint64_t table_blocks;
    if (dev->read(dev->ctx, 1, 1, hdr_scratch))
        return GK3_EIO;
    e = gk3_gpt_parse_header(hdr_scratch, dev->block_size, out);
    if (e)
        return e;
    if (out->last_usable >= dev->num_blocks)
        return GK3_ERANGE;                       /* 表是从更大的盘上抄来的 */
    want_crc = gk3_le32(hdr_scratch + 88);
    table_blocks = ((uint64_t)out->num_entries * out->entry_size + dev->block_size - 1) / dev->block_size;
    if (table_blocks * dev->block_size > entries_buf_len)
        return GK3_ENOSPC;
    if (out->entries_lba + table_blocks > dev->num_blocks)
        return GK3_ERANGE;
    if (dev->read(dev->ctx, out->entries_lba, (uint32_t)table_blocks, entries_buf))
        return GK3_EIO;
    return check_entries(out, entries_buf, entries_buf_len, want_crc);
}

gk3_err gk3_gpt_parse_mem(const uint8_t *hdr_block, uint32_t bs, const uint8_t *entries,
                          size_t entries_len, gk3_gpt *out)
{
    gk3_err e = gk3_gpt_parse_header(hdr_block, bs, out);
    if (e)
        return e;
    return check_entries(out, entries, entries_len, gk3_le32(hdr_block + 88));
}

static const uint8_t *entry(const gk3_gpt *g, uint32_t i)
{
    return g->entries + (size_t)i * g->entry_size;
}

static void decode(const gk3_gpt *g, uint32_t i, gk3_gpt_part *p)
{
    const uint8_t *e = entry(g, i);
    int k;
    gk3_memcpy(p->type_guid, e, 16);
    gk3_memcpy(p->part_guid, e + 16, 16);
    p->first_lba = gk3_le64(e + 32);
    p->last_lba = gk3_le64(e + 40);
    p->attrs = gk3_le64(e + 48);
    p->index = i + 1;
    for (k = 0; k < GK3_GPT_NAME_CHARS; k++) {
        uint16_t c = gk3_le16(e + 56 + 2 * k);
        if (c == 0)
            break;
        if (c < 0x20 || c > 0x7e) {          /* 非 ASCII：整个名字作废，不参与按名查找 */
            k = 0;
            break;
        }
        p->name[k] = (char)c;
    }
    p->name[k] = 0;
}

static bool used(const gk3_gpt *g, uint32_t i)
{
    return !gk3_is_zero(entry(g, i), 16);
}

uint32_t gk3_gpt_count(const gk3_gpt *g)
{
    uint32_t n = 0;
    if (!g->entries)
        return 0;
    for (uint32_t i = 0; i < g->num_entries; i++)
        n += used(g, i);
    return n;
}

gk3_err gk3_gpt_get(const gk3_gpt *g, uint32_t i, gk3_gpt_part *out)
{
    if (!g->entries)
        return GK3_EINVAL;
    if (i >= g->num_entries)
        return GK3_ERANGE;
    if (!used(g, i))
        return GK3_ENOENT;
    decode(g, i, out);
    return GK3_OK;
}

static bool name_eq(const char *a, const char *b)
{
    while (*a && *a == *b)
        a++, b++;
    return *a == *b;
}

gk3_err gk3_gpt_find(const gk3_gpt *g, const char *name, gk3_gpt_part *out)
{
    gk3_gpt_part p;
    uint32_t hits = 0;
    if (!g->entries || !name || !*name)
        return GK3_EINVAL;
    for (uint32_t i = 0; i < g->num_entries; i++) {
        if (!used(g, i))
            continue;
        decode(g, i, &p);
        if (!name_eq(p.name, name))
            continue;
        if (++hits == 1)
            gk3_memcpy(out, &p, sizeof(p));
    }
    if (hits == 0)
        return GK3_ENOENT;
    if (hits > 1)
        return GK3_EDUP;
    if (out->first_lba > out->last_lba || out->first_lba < g->first_usable ||
        out->last_lba > g->last_usable)
        return GK3_ERANGE;
    return GK3_OK;
}

gk3_err gk3_gpt_require_unique(const gk3_gpt *g, const char *const *names, size_t n, const char **bad)
{
    gk3_gpt_part p;
    for (size_t i = 0; i < n; i++) {
        gk3_err e = gk3_gpt_find(g, names[i], &p);
        if (e) {
            if (bad)
                *bad = names[i];
            return e;
        }
    }
    return GK3_OK;
}

void gk3_guid_str(const uint8_t g[16], char out[37])
{
    static const char hx[] = "0123456789abcdef";
    /* 前三段小端，后两段按字节 */
    static const int order[16] = {3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15};
    int o = 0;
    for (int i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10)
            out[o++] = '-';
        out[o++] = hx[g[order[i]] >> 4];
        out[o++] = hx[g[order[i]] & 15];
    }
    out[o] = 0;
}

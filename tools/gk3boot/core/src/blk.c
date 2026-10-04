/* libgk3core：分区内按字节读写（读-改-写 + 写后读回）。 */
#include "gk3core.h"

static gk3_err span(const gk3_blk *dev, uint64_t part_blocks, uint64_t off, size_t len,
                    uint64_t *first, uint64_t *count)
{
    uint64_t bs = dev->block_size, end;
    if (!bs || len == 0)
        return GK3_EINVAL;
    if (off > UINT64_MAX - len)
        return GK3_ERANGE;
    end = off + len;
    if (part_blocks > UINT64_MAX / bs || end > part_blocks * bs)
        return GK3_ERANGE;
    *first = off / bs;
    *count = (end + bs - 1) / bs - *first;
    return GK3_OK;
}

gk3_err gk3_blk_read_bytes(const gk3_blk *dev, uint64_t part_first_lba, uint64_t part_blocks,
                           uint64_t off, void *out, size_t len, void *scratch, size_t scratch_len)
{
    uint64_t first, count, bs = dev->block_size;
    uint8_t *o = out, *s = scratch;
    gk3_err e = span(dev, part_blocks, off, len, &first, &count);
    if (e)
        return e;
    if (scratch_len < bs)
        return GK3_ENOSPC;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t blk_start = (first + i) * bs, a, b;
        if (dev->read(dev->ctx, part_first_lba + first + i, 1, s))
            return GK3_EIO;
        a = off > blk_start ? off - blk_start : 0;
        b = (off + len < blk_start + bs) ? off + len - blk_start : bs;
        gk3_memcpy(o + (blk_start + a - off), s + a, (size_t)(b - a));
    }
    return GK3_OK;
}

gk3_err gk3_blk_write_bytes_verify(const gk3_blk *dev, uint64_t part_first_lba, uint64_t part_blocks,
                                   uint64_t off, const void *data, size_t len,
                                   void *scratch, size_t scratch_len)
{
    uint64_t first, count, bs = dev->block_size;
    const uint8_t *d = data;
    uint8_t *s = scratch, *v;
    gk3_err e = span(dev, part_blocks, off, len, &first, &count);
    if (e)
        return e;
    if (!dev->write)
        return GK3_EINVAL;
    if (scratch_len < 2 * bs)
        return GK3_ENOSPC;
    v = s + bs;
    for (uint64_t i = 0; i < count; i++) {
        uint64_t lba = part_first_lba + first + i, blk_start = (first + i) * bs, a, b;
        a = off > blk_start ? off - blk_start : 0;
        b = (off + len < blk_start + bs) ? off + len - blk_start : bs;
        if (a != 0 || b != bs) {            /* 不整块：先读出来补齐 */
            if (dev->read(dev->ctx, lba, 1, s))
                return GK3_EIO;
        }
        gk3_memcpy(s + a, d + (blk_start + a - off), (size_t)(b - a));
        if (dev->write(dev->ctx, lba, 1, s))
            return GK3_EIO;
        if (dev->flush && dev->flush(dev->ctx))
            return GK3_EIO;
        if (dev->read(dev->ctx, lba, 1, v))
            return GK3_EIO;
        if (gk3_memcmp(s, v, (size_t)bs))
            return GK3_EVERIFY;
    }
    return GK3_OK;
}

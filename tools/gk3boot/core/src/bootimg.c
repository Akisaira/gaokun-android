/* libgk3core：Android boot.img header v0–v2（本机用 v2，BoardConfig.mk:90-95）。
 *
 * 头布局（system/tools/mkbootimg 的 boot_img_hdr_v0/v1/v2）：
 *   0 magic[8]  8 kernel_size  12 kernel_addr  16 ramdisk_size  20 ramdisk_addr
 *   24 second_size  28 second_addr  32 tags_addr  36 page_size  40 header_version
 *   44 os_version  48 name[16]  64 cmdline[512]  576 id[32]  608 extra_cmdline[1024]
 *   v1：1632 recovery_dtbo_size  1636 recovery_dtbo_offset(u64)  1644 header_size
 *   v2：1648 dtb_size  1652 dtb_addr(u64)
 * 各段按 page_size 对齐依次排在头那一页之后。
 * id 前 20 字节 = SHA1(kernel‖le32(len), ramdisk‖len, second‖len[, recovery_dtbo‖len][, dtb‖len])
 * —— 设计稿 §2.2 对 out/issues-1791053208/boot.img 复算过（9274d5f8…e885e0），
 * test_bootimg.c 用同一份镜像再核一次。 */
#include "gk3core.h"

static bool add_pages(uint64_t *acc, uint64_t n, uint32_t page)
{
    uint64_t pad = (n + page - 1) / page * page;
    if (n > UINT64_MAX - page || *acc > UINT64_MAX - pad)
        return false;
    *acc += pad;
    return true;
}

gk3_err gk3_bootimg_parse(const uint8_t *h, size_t len, uint64_t part_size, gk3_bootimg *b)
{
    uint32_t need;
    uint64_t off;

    if (len < 1632)
        return GK3_ENOSPC;
    if (gk3_memcmp(h, GK3_BOOT_MAGIC, 8))
        return GK3_EMAGIC;
    gk3_memset(b, 0, sizeof(*b));
    b->hdr = h;
    b->version = gk3_le32(h + 40);
    if (b->version > 2)
        return GK3_EVERSION;
    need = b->version == 0 ? 1632 : b->version == 1 ? GK3_BOOT_HDR_V1_SIZE : GK3_BOOT_HDR_V2_SIZE;
    if (len < need)
        return GK3_ENOSPC;
    b->page_size = gk3_le32(h + 36);
    if (b->page_size != 2048 && b->page_size != 4096 && b->page_size != 8192 && b->page_size != 16384)
        return GK3_ERANGE;
    if (b->version >= 1 && gk3_le32(h + 1644) != need)
        return GK3_ERANGE;
    b->kernel_size = gk3_le32(h + 8);
    b->ramdisk_size = gk3_le32(h + 16);
    b->second_size = gk3_le32(h + 24);
    b->os_version = gk3_le32(h + 44);
    gk3_memcpy(b->name, h + 48, 16);
    b->name[16] = 0;
    gk3_memcpy(b->id, h + 576, 32);
    if (b->version >= 1)
        b->recovery_dtbo_size = gk3_le32(h + 1632);
    if (b->version >= 2)
        b->dtb_size = gk3_le32(h + 1648);
    if (b->kernel_size == 0)
        return GK3_ERANGE;

    off = b->page_size;                                  /* 头占一页 */
    b->kernel_off = off;
    if (!add_pages(&off, b->kernel_size, b->page_size)) return GK3_ERANGE;
    b->ramdisk_off = off;
    if (!add_pages(&off, b->ramdisk_size, b->page_size)) return GK3_ERANGE;
    b->second_off = off;
    if (!add_pages(&off, b->second_size, b->page_size)) return GK3_ERANGE;
    b->recovery_dtbo_off = off;
    if (!add_pages(&off, b->recovery_dtbo_size, b->page_size)) return GK3_ERANGE;
    b->dtb_off = off;
    if (!add_pages(&off, b->dtb_size, b->page_size)) return GK3_ERANGE;
    b->total_size = off;
    if (part_size && b->total_size > part_size)
        return GK3_ERANGE;
    return GK3_OK;
}

static void seg(gk3_sha1_ctx *c, const uint8_t *img, uint64_t off, uint32_t size)
{
    uint8_t le[4];
    gk3_sha1_update(c, img + off, size);
    gk3_put_le32(le, size);
    gk3_sha1_update(c, le, 4);
}

gk3_err gk3_bootimg_verify_id(const gk3_bootimg *b, const uint8_t *img, size_t img_len, uint8_t got[20])
{
    gk3_sha1_ctx c;
    if (img_len < b->total_size)
        return GK3_ENOSPC;
    gk3_sha1_init(&c);
    seg(&c, img, b->kernel_off, b->kernel_size);
    seg(&c, img, b->ramdisk_off, b->ramdisk_size);
    seg(&c, img, b->second_off, b->second_size);
    if (b->version >= 1)
        seg(&c, img, b->recovery_dtbo_off, b->recovery_dtbo_size);
    if (b->version >= 2)
        seg(&c, img, b->dtb_off, b->dtb_size);
    gk3_sha1_final(&c, got);
    return gk3_memcmp(got, b->id, 20) ? GK3_EVERIFY : GK3_OK;
}

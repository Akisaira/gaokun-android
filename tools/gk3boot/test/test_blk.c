/* 块设备读改写（§4.12：写后读回）+ 解析器的随机输入（ASan/UBSan 下不崩、不越界）。 */
#include "t.h"

void test_blk(void)
{
    for (unsigned bs = 512; bs <= 4096; bs *= 8) {
        size_t len = 64 * 1024;
        unsigned char *disk = malloc(len), *ref = malloc(len), buf[100], scratch[8192];
        t_memdev md = {disk, len, bs, -1, -1, 0};
        gk3_blk dev;
        const uint64_t first = 2, nblk = (len / bs) - 4;   /* "分区"从第 2 块起 */
        for (size_t i = 0; i < len; i++)
            disk[i] = (unsigned char)(i * 7);
        memcpy(ref, disk, len);
        t_memdev_bind(&md, &dev);

        /* 写一段跨块的 32 字节（像 BCAB 在 2048 处，4K 扇区时不对齐），其余字节不能动 */
        memset(buf, 0xAB, sizeof(buf));
        CHECK_EQ(gk3_blk_write_bytes_verify(&dev, first, nblk, 2040, buf, 32, scratch, sizeof(scratch)), GK3_OK);
        memset(ref + first * bs + 2040, 0xAB, 32);
        CHECK(memcmp(disk, ref, len) == 0, "bs=%u 只改了那 32 字节", bs);
        CHECK_EQ(gk3_blk_read_bytes(&dev, first, nblk, 2036, buf, 40, scratch, sizeof(scratch)), GK3_OK);
        CHECK(memcmp(buf, ref + first * bs + 2036, 40) == 0, "读回");

        /* 越界、溢出 */
        CHECK_EQ(gk3_blk_write_bytes_verify(&dev, first, nblk, nblk * bs - 10, buf, 32, scratch, sizeof(scratch)), GK3_ERANGE);
        CHECK_EQ(gk3_blk_read_bytes(&dev, first, nblk, UINT64_MAX - 3, buf, 32, scratch, sizeof(scratch)), GK3_ERANGE);
        CHECK_EQ(gk3_blk_write_bytes_verify(&dev, first, nblk, 0, buf, 32, scratch, bs), GK3_ENOSPC);
        /* 写失败 → EIO；读回不一致（写"成功"但盘上不是那样）→ EVERIFY */
        md.fail_write_at = md.writes;
        CHECK_EQ(gk3_blk_write_bytes_verify(&dev, first, nblk, 0, buf, 32, scratch, sizeof(scratch)), GK3_EIO);
        md.fail_write_at = -1;
        md.corrupt_after = md.writes;
        CHECK_EQ(gk3_blk_write_bytes_verify(&dev, first, nblk, 0, buf, 32, scratch, sizeof(scratch)), GK3_EVERIFY);
        md.corrupt_after = -1;
        /* 只读设备 */
        dev.write = NULL;
        CHECK_EQ(gk3_blk_write_bytes_verify(&dev, first, nblk, 0, buf, 32, scratch, sizeof(scratch)), GK3_EINVAL);
        free(disk);
        free(ref);
    }
}

void test_fuzz(void)
{
    unsigned char *buf = malloc(65536);
    gk3_gpt g;
    gk3_gpt_part p;
    gk3_bootimg b;
    gk3_bcb_info bi;
    gk3_sel sel;
    gk3_event ev[GK3_EV_N];
    char out[600];
    srand(1);
    for (int r = 0; r < 20000; r++) {
        size_t n = (size_t)(rand() % 4096) + 1;
        for (size_t i = 0; i < 65536; i++)
            buf[i] = (unsigned char)rand();
        if (r & 1) {                       /* 一半样本带对的魔数，往深处走 */
            memcpy(buf + 512, "EFI PART", 8);
            gk3_put_le32(buf + 520, 0x00010000);
            gk3_put_le32(buf + 524, 92);
            memcpy(buf, "ANDROID!", 8);
            gk3_put_le32(buf + 40, (uint32_t)(rand() % 3));
            gk3_put_le32(buf + 36, 2048);
            buf[64 + 511] = 0;
        }
        (void)gk3_gpt_parse_header(buf + 512, 512, &g);
        if (gk3_gpt_parse_mem(buf + 512, 512, buf + 1024, 65536 - 1024, &g) == GK3_OK)
            (void)gk3_gpt_find(&g, "misc", &p);
        if (gk3_bootimg_parse(buf, n < 1660 ? 1660 : n, 0, &b) == GK3_OK)
            (void)gk3_bootimg_cmdline(&b, out, sizeof(out));
        gk3_bcb_classify(buf, &bi);
        gk3_select_slot(buf + 2048, (unsigned)r, (uint8_t)rand(), &sel);
        (void)gk3_rec_validate(buf + 8192);
        (void)gk3_rec_events(buf + 8192, ev, GK3_EV_N);
        (void)gk3_rec_next(buf + 8192, NULL);
        {
            gk3_android_args a = {(unsigned)(r & 1), NULL, NULL, NULL};
            buf[600] = 0;
            (void)gk3_cmdline_android((const char *)buf + 1, &a, out, sizeof(out));
        }
    }
    CHECK(1, "随机输入跑完");
    free(buf);
}

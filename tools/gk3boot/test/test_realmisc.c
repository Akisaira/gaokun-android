/* 实机 misc（2026-10-05，候选版 1791053208 跑在 _a 时只读 dd 出的前 64 KiB）的逐字段 golden。 */
#include "t.h"

void test_realmisc(void)
{
    size_t len;
    unsigned char *m = t_vector("misc-20261005-1791053208.bin", &len);
    gk3_bcb_info bi;
    gk3_slot_info s;
    gk3_vab v;
    gk3_sel sel;
    uint8_t bc[32];
    static const uint8_t want_bcab[32] = {
        0x5f, 0x61, 0x00, 0x00, 0x42, 0x43, 0x41, 0x42, 0x01, 0x02, 0x00, 0x00, 0x9f, 0x00, 0x0e, 0x00,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x67, 0xdd, 0xc3, 0x20};
    if (!m)
        return;
    CHECK_EQ(len, 65536);

    /* BCB：全零 */
    gk3_bcb_classify(m, &bi);
    CHECK_EQ(bi.kind, GK3_BCB_NONE);
    CHECK(gk3_is_zero(m, 2048), "BCB 2 KiB 全零");

    /* BCAB：设计稿 §2.3 那段 dump；CRC 盘上字节 67 dd c3 20（= 小端 0x20c3dd67） */
    CHECK_MEM(m + 2048, want_bcab, 32);
    CHECK_EQ(gk3_bcab_validate(m + 2048), GK3_OK);
    CHECK_EQ(gk3_bcab_crc(m + 2048), 0x20c3dd67u);
    CHECK_EQ(gk3_bcab_nb_slot(m + 2048), 2);
    CHECK_EQ(gk3_bcab_merge_status(m + 2048), 0);
    CHECK_EQ(gk3_bcab_recovery_tries(m + 2048), 0);
    gk3_bcab_get_slot(m + 2048, 0, &s);
    CHECK(s.priority == 15 && s.tries == 1 && s.successful && !s.verity_corrupted, "_a = 15/1/成功");
    gk3_bcab_get_slot(m + 2048, 1, &s);
    CHECK(s.priority == 14 && s.tries == 0 && !s.successful, "_b = 14/0/未成功（不可启动）");
    CHECK(!gk3_slot_bootable(&s), "_b 不可启动");

    /* 2K+32 到 32K 全零 ⇒ 8 KiB 处的 GK3 记录位置实机上空着（E1 的"无人使用"之一半：盘上证据） */
    CHECK(gk3_is_zero(m + 2080, 32768 - 2080), "2080–32767 全零");
    CHECK_EQ(gk3_rec_validate(m + 8192), GK3_EMAGIC);

    /* 32 KiB：virtual_ab v2 / NONE / source 0；后面的 memtag 空、kcmdline 与 misctrl 各一份 v1 */
    gk3_vab_parse(m + 32768, &v);
    CHECK(v.valid && v.merge_status == GK3_MERGE_NONE && v.source_slot == 0, "VAB v2 NONE src 0");
    CHECK(gk3_is_zero(m + 32768 + 7, 57), "VAB reserved 全零");
    CHECK(gk3_is_zero(m + 32768 + 64, 64), "memtag 消息空");
    CHECK(m[32768 + 128] == 1 && gk3_le32(m + 32768 + 129) == 0x6ab5110cu, "kcmdline 消息 v1（bootloader_message.h:134-135）");
    CHECK(m[32768 + 192] == 1 && gk3_le32(m + 32768 + 193) == 0x736d6f72u, "misctrl 消息 v1（:138-139）");
    CHECK(gk3_is_zero(m + 32768 + 256, 65536 - 32768 - 256), "其余全零");

    /* 入口在这份 misc 上会怎么选：_a、不写 */
    memcpy(bc, m + 2048, 32);
    gk3_select_slot(bc, 0, gk3_vab_effective(&v, 0), &sel);
    CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 0 && !sel.decremented && !sel.fallback, "选 _a 不写");
    CHECK_MEM(bc, m + 2048, 32);
    free(m);
}

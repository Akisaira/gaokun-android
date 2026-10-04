/* bootloader_control 与选槽。
 *  - 入口侧选槽：与 GBL libgbl/src/slots/android.rs 的 get_boot_target（:295-305）+ mark_boot_attempt
 *    （:328-356）逐条转写的参照实现做随机对拍；差异只允许出现在"priority 0 但 tries>0/successful"
 *    （我们从严判不可启动，见 gk3core.h）。
 *  - HAL 侧原语（set_active 等）与真正的 libboot_control.cpp 逐字节对拍在 test_upstream.cpp。
 *  - 回滚时序：§4.3.2-7 的"setActive 给 6 次、扣完回旧槽"。 */
#include "t.h"

/* —— GBL 参照实现（转写，不改语义）——
 * SlotMetaData：priority[0:3] tries[4:6] successful[7]（android.rs:77-87）
 * is_bootable：Successful 或 Retriable(t>0)（:280-284、slots.rs:217-219）
 * 目标：可启动的槽里 max_by_key((priority, rank))，rank = -(suffix 字符)，即同分取 'a'（slots.rs:87-89）
 *       —— Rust 的 max_by_key 在相等时取最后一个，但 rank 已经区分了 a/b，所以不存在相等
 * mark_boot_attempt：Retriable → tries-1；Successful → 不动（:343-355） */
typedef struct { int boot; unsigned slot; unsigned tries_after; } gbl_res;

static gbl_res gbl_ref(const uint8_t bc[32])
{
    gbl_res r = {0, 0, 0};
    long best_key = -1;
    for (unsigned i = 0; i < 2; i++) {          /* nb_slots() 取 min(nb,4)；这里 nb==2 */
        uint16_t v = (uint16_t)(bc[12 + 2 * i] | (bc[13 + 2 * i] << 8));
        unsigned pr = v & 15, tr = (v >> 4) & 7, su = (v >> 7) & 1;
        long key;
        if (!(su || tr > 0))
            continue;
        key = (long)pr * 1000 - (long)('a' + i);
        if (best_key < 0 || key > best_key) {
            best_key = key;
            r.boot = 1;
            r.slot = i;
            r.tries_after = su ? tr : tr - 1;
        }
    }
    return r;
}

static void mk(uint8_t bc[32], unsigned pa, unsigned ta, int sa, unsigned pb, unsigned tb, int sb)
{
    gk3_slot_info a = {(uint8_t)pa, (uint8_t)ta, sa != 0, false}, b = {(uint8_t)pb, (uint8_t)tb, sb != 0, false};
    gk3_bcab_init_default(bc, 0, 2);
    gk3_bcab_set_slot(bc, 0, &a);
    gk3_bcab_set_slot(bc, 1, &b);
    gk3_bcab_update_crc(bc);
}

static void slot(const uint8_t bc[32], unsigned i, gk3_slot_info *s) { gk3_bcab_get_slot(bc, i, s); }

void test_bcab(void)
{
    uint8_t bc[32], orig[32];
    gk3_sel sel;
    gk3_slot_info s;
    int diverge = 0, agree = 0;

    /* —— 随机对拍 GBL 参照（含 reserved 位乱填） —— */
    int f0 = t_fail;
    srand(4321);
    for (int r = 0; r < 200000; r++) {
        gbl_res g;
        uint16_t va = (uint16_t)rand(), vb = (uint16_t)rand();
        gk3_bcab_init_default(bc, 0, 2);
        gk3_put_le16(bc + 12, va);
        gk3_put_le16(bc + 14, vb);
        gk3_bcab_update_crc(bc);
        memcpy(orig, bc, 32);
        g = gbl_ref(bc);
        gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
        {
            unsigned pa = va & 15, pb = vb & 15;
            int a_bootable_gbl = ((va >> 7) & 1) || ((va >> 4) & 7);
            int b_bootable_gbl = ((vb >> 7) & 1) || ((vb >> 4) & 7);
            if ((pa == 0 && a_bootable_gbl) || (pb == 0 && b_bootable_gbl)) {
                diverge++;
                continue;                     /* 有意的差异：priority 0 判不可启动 */
            }
        }
        agree++;
        if (!g.boot) {
            CHECKQ(sel.kind == GK3_SEL_NOSLOT, "GBL 无槽可启动而我们 kind=%d（%04x %04x）", sel.kind, va, vb);
            CHECKQ(memcmp(bc, orig, 32) == 0, "无槽可启动时不该写");
            continue;
        }
        CHECKQ(sel.kind == GK3_SEL_BOOT && sel.slot == g.slot,
              "选槽不同：GBL %u，我们 kind=%d slot=%u（%04x %04x）", g.slot, sel.kind, sel.slot, va, vb);
        CHECKQ(sel.tries_after == g.tries_after, "tries 不同（%04x %04x）", va, vb);
        /* 写回只动选中槽的 tries 位 + CRC：其余 30 字节逐字节不变 */
        if (sel.decremented) {
            uint8_t want[32];
            memcpy(want, orig, 32);
            gk3_put_le16(want + 12 + 2 * sel.slot,
                         (uint16_t)((gk3_le16(orig + 12 + 2 * sel.slot) & ~0x70) | (g.tries_after << 4)));
            gk3_bcab_update_crc(want);
            CHECKQ(memcmp(bc, want, 32) == 0, "扣 tries 改到了别的位（%04x %04x）", va, vb);
            CHECKQ(gk3_bcab_validate(bc) == GK3_OK, "写回后 BCAB 无效");
        } else {
            CHECKQ(memcmp(bc, orig, 32) == 0, "已成功的槽不该写");
        }
    }
    printf("    GBL 对拍：一致 %d 组，有意差异（priority 0）跳过 %d 组\n", agree, diverge);
    CHECK(agree > 150000, "对拍样本太少");
    CHECK(t_fail == f0, "GBL 随机对拍 %d 组全部一致", agree);

    /* —— GBL 单测转写（android.rs:523-588；GBL 默认 4 槽，我们只认 2 槽，所以 nb 改成 2） —— */
    mk(bc, 7, 7, 0, 7, 7, 0);
    gk3_select_slot(bc, 1, GK3_MERGE_NONE, &sel);                     /* test_slot_mark_boot_attempt */
    CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 0 && sel.tries_after == 6, "同分取 _a，扣到 6");
    mk(bc, 7, 1, 0, 7, 7, 0);
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);                     /* ..._no_more_tries */
    slot(bc, 0, &s);
    CHECK(sel.slot == 0 && s.tries == 0 && !gk3_slot_bootable(&s), "最后一次机会用掉后不可启动");
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 1 && sel.active == 0 && sel.fallback,
          "a 不可启动后同分的 b 上位（active 仍是同分取 a，所以记 fallback）");
    mk(bc, 7, 3, 1, 7, 7, 0);
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);                     /* ..._successful */
    CHECK(sel.slot == 0 && !sel.decremented && sel.tries_after == 3, "成功的槽不扣");
    mk(bc, 7, 0, 0, 7, 0, 0);
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);                     /* test_get_boot_target_recovery */
    CHECK_EQ(sel.kind, GK3_SEL_NOSLOT);

    /* —— 实机状态（2026-10-05 misc）：_a 15/1/成功，_b 14/0 —— */
    mk(bc, 15, 1, 1, 14, 0, 0);
    gk3_select_slot(bc, 1, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 0 && !sel.decremented && !sel.fallback, "实机：启动 _a、不写");

    /* —— 回滚时序（§4.3.2-7）：HAL setActive(b) → b 15/6；不确认 → b 启动 6 次后回到 a —— */
    CHECK_EQ(gk3_bcab_set_active(bc, 1, 0), GK3_OK);
    slot(bc, 0, &s);
    CHECK(s.priority == 14 && s.successful, "旧槽降到 14、成功位不动");
    slot(bc, 1, &s);
    CHECK(s.priority == 15 && s.tries == 6 && !s.successful, "新槽 15/6");
    for (int boot = 1; boot <= 6; boot++) {
        gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
        CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 1 && sel.decremented && sel.tries_after == 6 - boot,
              "第 %d 次开机应启动 _b、tries→%d（得 slot %u tries %u）", boot, 6 - boot, sel.slot, sel.tries_after);
    }
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 0 && sel.fallback && sel.active == 1 && !sel.decremented,
          "第 7 次回落到 _a（event=fallback）");
    /* 另一条线：b 第 2 次开机成功 → markBootSuccessful → 以后都启动 b、不扣 */
    gk3_bcab_set_active(bc, 1, 0);
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    gk3_bcab_mark_successful(bc, 1);
    for (int boot = 0; boot < 3; boot++) {
        gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
        CHECK(sel.slot == 1 && !sel.decremented && sel.tries_after == 1, "确认后不再扣");
    }

    /* —— VAB：MERGING 不换槽；SNAPSHOTTED 允许回落 —— */
    mk(bc, 14, 1, 1, 15, 0, 0);
    memcpy(orig, bc, 32);
    gk3_select_slot(bc, 0, GK3_MERGE_MERGING, &sel);
    CHECK(sel.kind == GK3_SEL_MERGING && sel.slot == 1 && memcmp(bc, orig, 32) == 0, "MERGING：不回落、不写");
    gk3_select_slot(bc, 0, GK3_MERGE_SNAPSHOTTED, &sel);
    CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 0 && sel.fallback, "SNAPSHOTTED：回落到源槽");
    mk(bc, 14, 1, 1, 15, 3, 0);
    gk3_select_slot(bc, 0, GK3_MERGE_MERGING, &sel);
    CHECK(sel.kind == GK3_SEL_BOOT && sel.slot == 1 && sel.tries_after == 2, "MERGING 但 active 可启动：照常启动并扣");

    /* —— 无效 BCAB：不写，按 hint —— */
    mk(bc, 15, 6, 0, 14, 1, 1);
    bc[4] ^= 1;
    memcpy(orig, bc, 32);
    gk3_select_slot(bc, 1, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BCAB_INVALID && sel.bcab_err == GK3_EMAGIC && sel.slot == 1 &&
          memcmp(bc, orig, 32) == 0, "坏魔数");
    mk(bc, 15, 6, 0, 14, 1, 1);
    bc[8] = 2;
    gk3_bcab_update_crc(bc);
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BCAB_INVALID && sel.bcab_err == GK3_EVERSION, "坏版本");
    mk(bc, 15, 6, 0, 14, 1, 1);
    bc[28] ^= 1;
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BCAB_INVALID && sel.bcab_err == GK3_ECRC, "坏 CRC");
    gk3_bcab_init_default(bc, 0, 4);                                   /* GBL 默认就是 4 槽 */
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BCAB_INVALID && sel.bcab_err == GK3_ESLOTS, "nb_slot=4");
    memset(bc, 0, 32);                                                 /* 安装器清零后的 misc */
    gk3_select_slot(bc, 0, GK3_MERGE_NONE, &sel);
    CHECK(sel.kind == GK3_SEL_BCAB_INVALID && sel.bcab_err == GK3_EMAGIC && sel.slot == 0, "全零 misc");

    /* —— set_slot 保留 reserved 位；控制位跨字节 —— */
    gk3_bcab_init_default(bc, 0, 2);
    gk3_put_le16(bc + 14, 0xfe00);
    s.priority = 3; s.tries = 5; s.successful = true; s.verity_corrupted = false;
    gk3_bcab_set_slot(bc, 1, &s);
    CHECK_EQ(gk3_le16(bc + 14), 0xfe00 | 3 | (5 << 4) | (1 << 7));
    gk3_put_le16(bc + 9, (uint16_t)(2 | (5 << 3) | (5 << 6)));         /* merge_status=5（101b）跨到第 10 字节 */
    CHECK(gk3_bcab_nb_slot(bc) == 2 && gk3_bcab_recovery_tries(bc) == 5 && gk3_bcab_merge_status(bc) == 5,
          "控制位解码");
    CHECK(bc[10] == 0x01 && bc[9] == 0x6A, "merge_status 的最高位在字节 10 的 bit0（得 %02x %02x）", bc[9], bc[10]);

    /* —— 安装器初始化（§4.7） —— */
    gk3_bcab_init_install(bc, 0);
    {
        static const uint8_t want[28] = {'_', 'a', 0, 0, 0x42, 0x43, 0x41, 0x42, 1, 2, 0, 0, 0x6f, 0, 0, 0};
        CHECK(memcmp(bc, want, 28) == 0, "init_install 字节");
    }
    CHECK_EQ(gk3_bcab_validate(bc), GK3_OK);
    gk3_select_slot(bc, 1, GK3_MERGE_NONE, &sel);
    CHECK(sel.slot == 0 && sel.tries_after == 5, "新装机器第一次开机扣到 5");
    gk3_bcab_init_install(bc, 1);
    slot(bc, 0, &s);
    CHECK(s.priority == 0 && s.tries == 0 && bc[1] == 'b', "init_install(b)");

    /* —— 越界参数 —— */
    gk3_bcab_init_default(bc, 0, 2);
    CHECK_EQ(gk3_bcab_set_active(bc, 2, 0), GK3_EINVAL);
    CHECK_EQ(gk3_bcab_set_unbootable(bc, 3), GK3_EINVAL);
    CHECK_EQ(gk3_bcab_mark_successful(bc, 4), GK3_EINVAL);

    /* —— VAB 有效值（libboot_control.cpp:432-439） —— */
    {
        uint8_t m[64] = {2, 0xb0, 0x0a, 0x74, 0x56, GK3_MERGE_SNAPSHOTTED, 1};
        gk3_vab v;
        gk3_vab_parse(m, &v);
        CHECK(v.valid && v.merge_status == 2 && v.source_slot == 1, "VAB 解析");
        CHECK_EQ(gk3_vab_effective(&v, 1), GK3_MERGE_NONE);
        CHECK_EQ(gk3_vab_effective(&v, 0), GK3_MERGE_SNAPSHOTTED);
        m[0] = 1;
        gk3_vab_parse(m, &v);
        CHECK(!v.valid && gk3_vab_effective(&v, 0) == GK3_MERGE_UNKNOWN, "v1 消息不认");
    }
}

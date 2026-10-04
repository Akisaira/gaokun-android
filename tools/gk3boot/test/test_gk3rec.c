/* GK3 记录：CRC 判有效、迁移、分派计数、事件环。 */
#include "t.h"

void test_gk3rec(void)
{
    uint8_t rec[GK3_REC_SIZE], bcb[2048], d[20];
    gk3_event ev[GK3_EV_N + 4];
    gk3_bcb_info bi;
    char cmd[33];
    uint8_t slot;
    uint32_t n;

    memset(rec, 0, sizeof(rec));
    CHECK_EQ(gk3_rec_validate(rec), GK3_EMAGIC);            /* 全零 = 无记录 */
    gk3_rec_init(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_OK);
    CHECK(!gk3_rec_migrated(rec), "新记录未迁移");
    CHECK_EQ(gk3_rec_events(rec, ev, GK3_EV_N), 0);
    rec[100] ^= 1;
    CHECK_EQ(gk3_rec_validate(rec), GK3_ECRC);              /* 改了不封 → 无效 */
    gk3_rec_seal(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_OK);
    rec[4] = 2;
    gk3_rec_seal(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_EVERSION);

    /* 首跑迁移：存量 BCB = 一次没执行的恢复出厂（§4.8 的代价那一行） */
    gk3_rec_init(rec);
    memset(bcb, 0, sizeof(bcb));
    {
        const char *args[] = {"--wipe_data", "--reason=MasterClearConfirm", "--locale=zh-CN"};
        gk3_bcb_write_recovery(bcb, args, 3);
    }
    gk3_rec_migrate(rec, bcb, 1);
    gk3_rec_seal(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_OK);
    CHECK(gk3_rec_migrated(rec), "迁移标记");
    gk3_rec_migrated_command(rec, cmd);
    CHECK_STR(cmd, "boot-recovery");
    CHECK(memcmp(rec + 100, "recovery\n--wipe_data\n", 21) == 0, "recovery 原文留在记录里");
    n = gk3_rec_events(rec, ev, GK3_EV_N);
    CHECK(n == 2 && ev[0].code == GK3_EV_MIGRATED && ev[1].code == GK3_EV_BCB_DROPPED &&
          ev[1].aux == GK3_BCB_WIPE && ev[0].seq + 1 == ev[1].seq, "MIGRATED + BCB_DROPPED(wipe)");
    /* BCB 为空时只记 MIGRATED */
    gk3_rec_init(rec);
    memset(bcb, 0, sizeof(bcb));
    gk3_rec_migrate(rec, bcb, 7);
    CHECK_EQ(gk3_rec_events(rec, ev, GK3_EV_N), 1);
    CHECK_EQ(gk3_le32(rec + 12), 7);

    /* 分派计数：同一份 BCB 连续进入 3 次 → 3；换一份 → 重置 */
    gk3_rec_init(rec);
    memset(bcb, 0, sizeof(bcb));
    {
        const char *args[] = {"--wipe_data"};
        gk3_bcb_write_recovery(bcb, args, 1);
    }
    gk3_bcb_classify(bcb, &bi);
    CHECK_EQ(gk3_rec_dispatch_enter(rec, bi.kind, 0, bi.digest), 1);
    CHECK_EQ(gk3_rec_dispatch_enter(rec, bi.kind, 0, bi.digest), 2);
    CHECK_EQ(gk3_rec_dispatch_enter(rec, bi.kind, 0, bi.digest), 3);
    gk3_rec_dispatch_digest(rec, d);
    CHECK_MEM(d, bi.digest, 20);
    bcb[2000] = 1;
    gk3_bcb_classify(bcb, &bi);
    CHECK_EQ(gk3_rec_dispatch_enter(rec, bi.kind, 1, bi.digest), 1);
    CHECK_EQ(gk3_rec_dispatch_enter(rec, GK3_BCB_FASTBOOT, 1, bi.digest), 1);   /* why 变了也重置 */
    gk3_rec_dispatch_reset(rec);
    CHECK_EQ(gk3_rec_dispatch_count(rec), 0);

    /* 连续未完成启动计数，饱和 */
    gk3_rec_set_boot_streak(rec, 254);
    CHECK_EQ(gk3_rec_inc_boot_streak(rec), 255);
    CHECK_EQ(gk3_rec_inc_boot_streak(rec), 255);
    gk3_rec_set_boot_streak(rec, 0);
    CHECK_EQ(gk3_rec_inc_boot_streak(rec), 1);

    /* 一次性意图 */
    gk3_rec_set_next(rec, GK3_NEXT_SLOT, 1);
    CHECK(gk3_rec_next(rec, &slot) == GK3_NEXT_SLOT && slot == 1, "next=slot:b");
    gk3_rec_set_next(rec, GK3_NEXT_SDBOOT_MENU, 1);
    CHECK(gk3_rec_next(rec, &slot) == GK3_NEXT_SDBOOT_MENU && slot == 0, "next=sdboot-menu");
    rec[21] = 9;
    CHECK_EQ(gk3_rec_next(rec, NULL), GK3_NEXT_NONE);         /* 不认识的意图当没有 */
    rec[21] = GK3_NEXT_SLOT; rec[22] = 5;
    CHECK_EQ(gk3_rec_next(rec, NULL), GK3_NEXT_NONE);

    /* 事件环：写 40 条，留最近 32 条，按旧→新 */
    gk3_rec_init(rec);
    for (uint32_t i = 1; i <= 40; i++)
        gk3_rec_event_add(rec, (gk3_ev_code)(1 + i % 8), (uint8_t)(i & 1), i * 10);
    gk3_rec_seal(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_OK);
    n = gk3_rec_events(rec, ev, GK3_EV_N + 4);
    CHECK_EQ(n, GK3_EV_N);
    CHECK(ev[0].seq == 9 && ev[GK3_EV_N - 1].seq == 40 && ev[GK3_EV_N - 1].aux == 400, "环的首尾");
    for (uint32_t i = 1; i < n; i++)
        CHECK(ev[i].seq == ev[i - 1].seq + 1, "序号连续");
    gk3_rec_events_mark_notified(rec, 30);
    n = gk3_rec_events(rec, ev, GK3_EV_N);
    CHECK((ev[21].flags & GK3_EVF_NOTIFIED) && ev[21].seq == 30 && !(ev[22].flags & GK3_EVF_NOTIFIED),
          "置已通知到 seq 30 为止");
    rec[26] = GK3_EV_N;                                       /* 坏的 head */
    gk3_rec_seal(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_ERANGE);
    CHECK_STR(gk3_ev_name(GK3_EV_WIPE_FAILED), "wipe_failed");
}

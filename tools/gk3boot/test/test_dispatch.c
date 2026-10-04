/* BCB 分派的决定（§4.3.4、§4.10）+ GK3 记录里 S5 动作模式新用的字段。 */
#include "t.h"

static void plan_for(uint8_t *rec, const uint8_t *bcb, gk3_disp_plan *p)
{
    gk3_bcb_info bi;
    gk3_bcb_classify(bcb, &bi);
    gk3_dispatch_plan(&bi, rec, 1, p);
}

void test_dispatch(void)
{
    uint8_t rec[GK3_REC_SIZE], bcb[2048];
    gk3_disp_plan p;
    gk3_event ev[GK3_EV_N];

    /* 没迁移：不论 BCB 是什么都先迁移（只清不执行） */
    gk3_rec_init(rec);
    memset(bcb, 0, sizeof(bcb));
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_MIGRATE && p.why == GK3_BCB_NONE, "未迁移 + 空 BCB → migrate");
    {
        const char *a[] = {"--wipe_data", "--reason=MasterClearConfirm"};
        gk3_bcb_write_recovery(bcb, a, 2);
    }
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_MIGRATE && p.why == GK3_BCB_WIPE && p.count == 0, "未迁移 + wipe → migrate，不进执行端");
    CHECK_EQ(gk3_rec_dispatch_count(rec), 0);

    /* 迁移之后 */
    gk3_rec_migrate(rec, bcb, GK3_DISPATCH_VER);
    for (unsigned i = 1; i <= GK3_WIPE_MAX_ENTRIES; i++) {
        plan_for(rec, bcb, &p);
        CHECK(p.action == GK3_DISP_EXECUTOR && p.why == GK3_BCB_WIPE && p.count == i && !p.clear_command_first,
              "wipe 第 %u 次 → 执行端（BCB 由执行端擦完再清）", i);
    }
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_WIPE_CAP && p.count == GK3_WIPE_MAX_ENTRIES + 1, "同一份 wipe 第 4 次 → 入口自己清");
    /* 执行端清掉之后（BCB 空）：计数作废 */
    memset(bcb, 0, sizeof(bcb));
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_NONE && gk3_rec_dispatch_count(rec) == 0, "BCB 空 → none，旧计数清零");
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_NONE, "再一次也是 none");

    /* prompt_wipe：永不自动清 */
    {
        const char *a[] = {"--prompt_and_wipe_data", "--reason=RescueParty"};
        gk3_bcb_write_recovery(bcb, a, 2);
    }
    for (unsigned i = 0; i < 6; i++)
        plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_EXECUTOR && p.why == GK3_BCB_PROMPT_WIPE && p.count == 6, "prompt_wipe 第 6 次仍进执行端");

    /* bootonce-bootloader / --fastboot：先清 command */
    memset(bcb, 0, sizeof(bcb));
    memcpy(bcb, "bootonce-bootloader", 19);
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_EXECUTOR && p.why == GK3_BCB_BOOTLOADER && p.clear_command_first && p.count == 1,
          "bootonce-bootloader → 先清 command 再进执行端");
    {
        const char *a[] = {"--fastboot"};
        gk3_bcb_write_recovery(bcb, a, 1);
    }
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_EXECUTOR && p.why == GK3_BCB_FASTBOOT && p.clear_command_first, "--fastboot 同上");
    {
        const char *a[] = {"--update_package=/x.zip"};
        gk3_bcb_write_recovery(bcb, a, 1);
    }
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_EXECUTOR && p.why == GK3_BCB_RECOVERY && !p.clear_command_first, "其他 recovery → 菜单");
    /* 未知命令：清掉，不计次 */
    memset(bcb, 0, sizeof(bcb));
    memcpy(bcb, "boot-quiescent", 14);
    gk3_rec_dispatch_reset(rec);
    plan_for(rec, bcb, &p);
    CHECK(p.action == GK3_DISP_CLEAR && p.why == GK3_BCB_UNKNOWN && gk3_rec_dispatch_count(rec) == 0,
          "boot-quiescent → 清掉，不进执行端");

    /* S5 动作模式新用的字段：flags 的回落位、bcb_seen（偏移 356），都进 CRC、不碰别的字段 */
    gk3_rec_init(rec);
    gk3_rec_migrate(rec, bcb, 1);
    gk3_rec_set_flag(rec, GK3_REC_F_IN_FALLBACK, true);
    CHECK(gk3_rec_migrated(rec) && (gk3_rec_flags(rec) & GK3_REC_F_IN_FALLBACK), "置回落位不碰迁移位");
    gk3_rec_set_flag(rec, GK3_REC_F_IN_FALLBACK, false);
    CHECK(gk3_rec_flags(rec) == GK3_REC_F_MIGRATED, "清回落位");
    CHECK_EQ(gk3_rec_bcb_seen(rec), 0);
    gk3_rec_set_bcb_seen(rec, 0xdeadbeefu);
    CHECK_EQ(gk3_rec_bcb_seen(rec), 0xdeadbeefu);
    CHECK(rec[356] == 0xef && rec[359] == 0xde && rec[355] == 0 && rec[360] == 0, "bcb_seen 在偏移 356，小端");
    gk3_rec_seal(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_OK);
    rec[357] ^= 1;
    CHECK_EQ(gk3_rec_validate(rec), GK3_ECRC);
    gk3_rec_init(rec);
    gk3_rec_event_add(rec, GK3_EV_BCB_IGNORED, 0xff, GK3_BCB_WIPE);
    CHECK(gk3_rec_events(rec, ev, GK3_EV_N) == 1 && ev[0].code == GK3_EV_BCB_IGNORED && ev[0].aux == GK3_BCB_WIPE,
          "BCB_IGNORED 事件");
    CHECK_STR(gk3_ev_name(GK3_EV_BCB_IGNORED), "bcb_ignored");
    CHECK_STR(gk3_disp_name(GK3_DISP_WIPE_CAP), "wipe_cap");
}

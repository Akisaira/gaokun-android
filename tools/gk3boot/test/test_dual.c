/* 双系统（S15，设计稿 §4.9.3 / §4.9.4）：GK3 记录新字段的逐字节 golden + 向后兼容、LoaderEntryDefault 分类、
 * gk3_dual_plan_default / gk3_dual_plan_boot 的规则表、mark-poweroff。 */
#include "t.h"

static uint32_t last_code(const uint8_t *rec, gk3_event *e)
{
    gk3_event ev[GK3_EV_N];
    uint32_t n = gk3_rec_events(rec, ev, GK3_EV_N);
    if (!n)
        return 0;
    if (e)
        *e = ev[n - 1];
    return ev[n - 1].code;
}

static uint32_t nev(const uint8_t *rec)
{
    gk3_event ev[GK3_EV_N];
    return gk3_rec_events(rec, ev, GK3_EV_N);
}

void test_dual(void)
{
    uint8_t rec[GK3_REC_SIZE];
    gk3_def_plan dp;
    gk3_dual_boot db;
    gk3_event e;

    /* —— golden：字段位置与 CRC（期望值用 Python zlib 独立算：README §5）—— */
    gk3_rec_init(rec);
    CHECK_EQ(gk3_le32(rec + 2044), 0x79ee8a3e);              /* 空的 v1 记录（S15 之前与之后同一份字节） */
    CHECK(gk3_rec_set_default_req(rec) == GK3_SETDEF_NONE && gk3_rec_default_os(rec) == GK3_OS_UNKNOWN &&
          !gk3_rec_clean_poweroff(rec) && gk3_rec_next(rec, NULL) == GK3_NEXT_NONE, "空记录：S15 字段全是'没有'");
    gk3_rec_set_flag(rec, GK3_REC_F_MIGRATED, true);
    gk3_rec_set_flag(rec, GK3_REC_F_CLEAN_POWEROFF, true);
    gk3_rec_set_next(rec, GK3_NEXT_WINDOWS, 1);
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_WINDOWS);
    gk3_rec_put_default_os(rec, GK3_OS_WINDOWS);
    gk3_rec_seal(rec);
    CHECK_EQ(gk3_rec_validate(rec), GK3_OK);
    CHECK(rec[8] == 0x05 && rec[21] == 3 && rec[22] == 0 && rec[360] == 1 && rec[361] == 2,
          "字节位置：flags=0x05 @8、next_kind=3 @21（next_slot 清零）、set_default=1 @360、default_os=2 @361");
    CHECK_EQ(gk3_le32(rec + 2044), 0x068f30d2);
    {   /* 别的字节一个都没碰：除 8、21、360、361 与 CRC 外，与空记录逐字节相同 */
        uint8_t z[GK3_REC_SIZE];
        bool same = true;
        gk3_rec_init(z);
        for (unsigned i = 0; i < 2044; i++)
            if (i != 8 && i != 21 && i != 360 && i != 361 && rec[i] != z[i])
                same = false;
        CHECK(same, "S15 字段只占 flags bit2、next_kind、360、361");
    }
    CHECK(gk3_rec_clean_poweroff(rec) && gk3_rec_migrated(rec) && gk3_rec_next(rec, NULL) == GK3_NEXT_WINDOWS,
          "读回");
    /* 不认识的值当没有（向前兼容：将来的写者多一种取值，这一版入口不会误执行） */
    rec[360] = 7; rec[361] = 9; rec[21] = 4;
    CHECK(gk3_rec_set_default_req(rec) == GK3_SETDEF_NONE && gk3_rec_default_os(rec) == GK3_OS_UNKNOWN &&
          gk3_rec_next(rec, NULL) == GK3_NEXT_NONE, "不认识的 set_default / default_os / next 当没有");
    CHECK_STR(gk3_ev_name(GK3_EV_INTENT_DROPPED), "intent_dropped");
    CHECK_STR(gk3_ev_name(GK3_EV_TO_WINDOWS), "to_windows");
    CHECK_STR(gk3_ev_name(GK3_EV_DEFAULT_RESET), "default_reset");
    CHECK_STR(gk3_ev_name(GK3_EV_DEFAULT_SET), "default_set");
    CHECK(GK3_EV_DEFAULT_RESET == 10 && GK3_EV_INTENT_DROPPED == 11 && GK3_EV_TO_WINDOWS == 12 &&
          GK3_EV_DEFAULT_SET == 13, "事件码是盘上格式，不许重排");

    /* —— LoaderEntryDefault 分类 —— */
    CHECK_EQ(gk3_defvar_classify(NULL), GK3_DEFVAR_ABSENT);
    CHECK_EQ(gk3_defvar_classify("auto-windows"), GK3_DEFVAR_WINDOWS);
    CHECK_EQ(gk3_defvar_classify("Auto-Windows"), GK3_DEFVAR_WINDOWS);
    CHECK_EQ(gk3_defvar_classify("gk3-windows.conf"), GK3_DEFVAR_WINDOWS);
    CHECK_EQ(gk3_defvar_classify("gk3-windows"), GK3_DEFVAR_OTHER);      /* type1 的 id 带 .conf，不带的匹配不到 */
    CHECK_EQ(gk3_defvar_classify("gk3boot-android-a.conf"), GK3_DEFVAR_OTHER);
    CHECK_EQ(gk3_defvar_classify("@saved"), GK3_DEFVAR_OTHER);
    CHECK_EQ(gk3_defvar_classify("auto-windows*"), GK3_DEFVAR_OTHER);
    CHECK_EQ(gk3_defvar_classify(""), GK3_DEFVAR_OTHER);

    /* —— a、b：默认系统 —— */
    gk3_rec_init(rec);
    gk3_dual_plan_default(rec, GK3_DEFVAR_ABSENT, true, &dp);
    CHECK(dp.action == GK3_DEFACT_NONE && !dp.default_windows && !dp.reset && nev(rec) == 0,
          "不存在 + 没有请求：什么都不做（纯 Android 的正常路径不多写一字节）");
    gk3_dual_plan_default(rec, GK3_DEFVAR_WINDOWS, true, &dp);
    CHECK(dp.action == GK3_DEFACT_NONE && dp.default_windows && nev(rec) == 0, "auto-windows + bootmgfw 在 = 默认 Windows");
    gk3_dual_plan_default(rec, GK3_DEFVAR_WINDOWS, false, &dp);
    CHECK(dp.action == GK3_DEFACT_NONE && !dp.default_windows && nev(rec) == 0,
          "auto-windows 但 bootmgfw 不在：合法、不删，实际默认 Android");
    gk3_dual_plan_default(rec, GK3_DEFVAR_OTHER, true, &dp);
    CHECK(dp.action == GK3_DEFACT_DELETE && dp.reset && !dp.default_windows && last_code(rec, NULL) == GK3_EV_DEFAULT_RESET,
          "不合法（Android 精确 id 等）：删、记 default_reset");
    gk3_rec_init(rec);
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_WINDOWS);
    gk3_dual_plan_default(rec, GK3_DEFVAR_ABSENT, true, &dp);
    CHECK(dp.action == GK3_DEFACT_SET_WINDOWS && dp.default_windows && !dp.default_windows_before &&
          dp.applied == GK3_SETDEF_WINDOWS && gk3_rec_set_default_req(rec) == GK3_SETDEF_NONE &&
          last_code(rec, &e) == GK3_EV_DEFAULT_SET && e.aux == GK3_OS_WINDOWS && e.slot == 0,
          "set_default=windows：写变量、请求清零、记 default_set(windows)");
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_WINDOWS);
    gk3_dual_plan_default(rec, GK3_DEFVAR_WINDOWS, true, &dp);
    CHECK(dp.action == GK3_DEFACT_NONE && dp.default_windows, "已是 Windows：不重写变量");
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_WINDOWS);
    gk3_dual_plan_default(rec, GK3_DEFVAR_OTHER, true, &dp);
    CHECK(dp.action == GK3_DEFACT_SET_WINDOWS && dp.reset && dp.default_windows, "不合法 + 请求 windows：直接改写成 Windows");
    gk3_rec_init(rec);
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_WINDOWS);
    gk3_dual_plan_default(rec, GK3_DEFVAR_ABSENT, false, &dp);
    CHECK(dp.action == GK3_DEFACT_NONE && dp.dropped && !dp.default_windows && gk3_rec_set_default_req(rec) == 0 &&
          last_code(rec, &e) == GK3_EV_INTENT_DROPPED && e.aux == GK3_INTENT_SET_DEFAULT && e.slot == GK3_DROP_NO_WINDOWS,
          "没有 Windows 时请求 windows：作废、记 intent_dropped(set_default, no_windows)");
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_ANDROID);
    gk3_dual_plan_default(rec, GK3_DEFVAR_WINDOWS, true, &dp);
    CHECK(dp.action == GK3_DEFACT_DELETE && !dp.default_windows && dp.default_windows_before &&
          last_code(rec, &e) == GK3_EV_DEFAULT_SET && e.aux == GK3_OS_ANDROID, "set_default=android：删变量");
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_ANDROID);
    gk3_dual_plan_default(rec, GK3_DEFVAR_ABSENT, true, &dp);
    CHECK(dp.action == GK3_DEFACT_NONE && !dp.default_windows, "已是 Android：不动变量");

    /* —— c、d、e：开机去哪 —— */
    gk3_rec_init(rec);
    gk3_dual_plan_boot(rec, false, true, false, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && !db.preset_oneshot && nev(rec) == 0, "没有意图、默认 Android：照常、不预置");
    gk3_dual_plan_boot(rec, true, true, false, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && db.preset_oneshot && nev(rec) == 0, "默认 Windows：照常启动 Android、预置 OneShot");
    gk3_rec_set_next(rec, GK3_NEXT_WINDOWS, 0);
    gk3_dual_plan_boot(rec, false, true, false, &db);
    CHECK(db.kind == GK3_DUAL_WINDOWS && db.why == GK3_INTENT_NEXT_WINDOWS && gk3_rec_next(rec, NULL) == GK3_NEXT_NONE &&
          last_code(rec, &e) == GK3_EV_TO_WINDOWS && e.aux == GK3_INTENT_NEXT_WINDOWS,
          "next=windows（默认 Android）：去 Windows、标记清掉、记 to_windows");
    gk3_rec_set_next(rec, GK3_NEXT_WINDOWS, 0);
    gk3_dual_plan_boot(rec, true, true, true, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && db.preset_oneshot && db.dropped == 1 && gk3_rec_next(rec, NULL) == GK3_NEXT_NONE &&
          last_code(rec, &e) == GK3_EV_INTENT_DROPPED && e.aux == GK3_INTENT_NEXT_WINDOWS &&
          e.slot == GK3_DROP_ANDROID_PENDING, "next=windows + Android 待办：作废（清掉、记事件）、照常 Android、默认 Windows 仍预置");
    gk3_rec_set_next(rec, GK3_NEXT_WINDOWS, 0);
    gk3_dual_plan_boot(rec, false, false, false, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && db.dropped == 1 && last_code(rec, &e) == GK3_EV_INTENT_DROPPED &&
          e.slot == GK3_DROP_NO_WINDOWS && gk3_rec_next(rec, NULL) == GK3_NEXT_NONE, "next=windows 但没有 bootmgfw：作废");
    gk3_rec_init(rec);
    gk3_rec_set_flag(rec, GK3_REC_F_CLEAN_POWEROFF, true);
    gk3_dual_plan_boot(rec, true, true, false, &db);
    CHECK(db.kind == GK3_DUAL_WINDOWS && db.why == GK3_INTENT_CLEAN_POWEROFF && !gk3_rec_clean_poweroff(rec) &&
          last_code(rec, &e) == GK3_EV_TO_WINDOWS && e.aux == GK3_INTENT_CLEAN_POWEROFF,
          "clean_poweroff + 默认 Windows：冷开机进 Windows、标记清掉");
    gk3_rec_init(rec);
    gk3_rec_set_flag(rec, GK3_REC_F_CLEAN_POWEROFF, true);
    gk3_dual_plan_boot(rec, false, true, false, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && !gk3_rec_clean_poweroff(rec) && nev(rec) == 0,
          "clean_poweroff 但默认 Android：静默清掉、照常 Android");
    gk3_rec_set_flag(rec, GK3_REC_F_CLEAN_POWEROFF, true);
    gk3_dual_plan_boot(rec, true, true, true, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && db.dropped == 2 && db.preset_oneshot && !gk3_rec_clean_poweroff(rec) &&
          last_code(rec, &e) == GK3_EV_INTENT_DROPPED && e.aux == GK3_INTENT_CLEAN_POWEROFF,
          "clean_poweroff + 待办：作废、照常 Android（预置）");
    gk3_rec_init(rec);
    gk3_rec_set_next(rec, GK3_NEXT_WINDOWS, 0);
    gk3_rec_set_flag(rec, GK3_REC_F_CLEAN_POWEROFF, true);
    gk3_dual_plan_boot(rec, true, true, false, &db);
    CHECK(db.kind == GK3_DUAL_WINDOWS && db.why == GK3_INTENT_NEXT_WINDOWS && !gk3_rec_clean_poweroff(rec) &&
          gk3_rec_next(rec, NULL) == GK3_NEXT_NONE && nev(rec) == 1, "两个都在：一次 to_windows、两个都清");
    gk3_rec_init(rec);
    gk3_rec_set_next(rec, GK3_NEXT_SLOT, 1);
    gk3_rec_set_flag(rec, GK3_REC_F_CLEAN_POWEROFF, true);
    gk3_dual_plan_boot(rec, true, true, false, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && db.dropped == 2 && gk3_rec_next(rec, NULL) == GK3_NEXT_SLOT,
          "next=slot:b 算待办：clean_poweroff 作废，slot 意图原样留给它自己那一段");
    gk3_rec_init(rec);
    gk3_rec_set_next(rec, GK3_NEXT_SDBOOT_MENU, 0);
    gk3_rec_set_flag(rec, GK3_REC_F_CLEAN_POWEROFF, true);
    gk3_dual_plan_boot(rec, true, true, false, &db);
    CHECK(db.kind == GK3_DUAL_SDBOOT_MENU && !db.preset_oneshot && gk3_rec_next(rec, NULL) == GK3_NEXT_NONE &&
          !gk3_rec_clean_poweroff(rec) && db.dropped == 2, "next=sdboot-menu：回菜单、清掉；clean_poweroff 作废");
    gk3_rec_set_next(rec, GK3_NEXT_SDBOOT_MENU, 0);
    gk3_dual_plan_boot(rec, false, false, true, &db);
    CHECK(db.kind == GK3_DUAL_SDBOOT_MENU && db.dropped == 0, "sdboot-menu 不看待办与 Windows");

    /* —— mark-poweroff —— */
    gk3_rec_init(rec);
    gk3_rec_put_default_os(rec, GK3_OS_WINDOWS);
    CHECK(!gk3_rec_mark_poweroff(rec, "reboot") && !gk3_rec_mark_poweroff(rec, "reboot,bootloader") &&
          !gk3_rec_mark_poweroff(rec, "shutdownx") && !gk3_rec_mark_poweroff(rec, NULL) && !gk3_rec_clean_poweroff(rec),
          "重启 / 不像 shutdown 的值：不写");
    CHECK(gk3_rec_mark_poweroff(rec, "shutdown,userrequested") && gk3_rec_clean_poweroff(rec), "关机 + 默认 Windows：置标记");
    gk3_rec_init(rec);
    gk3_rec_put_default_os(rec, GK3_OS_WINDOWS);
    CHECK(gk3_rec_mark_poweroff(rec, "shutdown") && gk3_rec_mark_poweroff(rec, "shutdown,thermal"), "shutdown / thermal");
    gk3_rec_init(rec);
    gk3_rec_put_default_os(rec, GK3_OS_ANDROID);
    CHECK(!gk3_rec_mark_poweroff(rec, "shutdown") && !gk3_rec_clean_poweroff(rec), "默认 Android：不写");
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_WINDOWS);
    CHECK(gk3_rec_mark_poweroff(rec, "shutdown"), "缓存是 Android 但已请求改成 Windows（入口下次先应用请求）：写");
    gk3_rec_init(rec);
    gk3_rec_put_default_os(rec, GK3_OS_WINDOWS);
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_ANDROID);
    CHECK(!gk3_rec_mark_poweroff(rec, "shutdown"), "缓存是 Windows 但已请求改回 Android：不写");
    gk3_rec_put_set_default_req(rec, GK3_SETDEF_NONE);
    gk3_rec_put_default_os(rec, GK3_OS_UNKNOWN);
    CHECK(!gk3_rec_mark_poweroff(rec, "shutdown"), "缓存未知（入口还没在动作模式下跑过）：不写");

    /* —— 端到端：关机 → 冷开机（入口先 plan_default 再 plan_boot）—— */
    gk3_rec_init(rec);
    gk3_rec_put_default_os(rec, GK3_OS_WINDOWS);
    CHECK(gk3_rec_mark_poweroff(rec, "shutdown,userrequested"), "关机写标记");
    gk3_dual_plan_default(rec, GK3_DEFVAR_WINDOWS, true, &dp);
    gk3_dual_plan_boot(rec, dp.default_windows, true, false, &db);
    CHECK(db.kind == GK3_DUAL_WINDOWS && !gk3_rec_clean_poweroff(rec), "冷开机 → Windows");
    gk3_dual_plan_boot(rec, dp.default_windows, true, false, &db);
    CHECK(db.kind == GK3_DUAL_ANDROID && db.preset_oneshot, "下一次（标记已清）→ Android + 预置：不会循环");
}

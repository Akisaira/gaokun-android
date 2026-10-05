/* libgk3core：BCB 分派的决定（设计稿 §4.3.4 的表 + §4.10 首跑迁移）。只决定、不写盘。
 *
 * 分派开关默认关（E-K7：开关必须与执行端 S7、迁移同版发布）。S7c 起开关打开时入口真的按这里的决定
 * 去执行端（gk3boot.c 的 step_dispatch / boot_executor）；执行端缺失或加载失败则只记录、照常启动 Android。 */
#include "gk3core.h"

const char *gk3_disp_name(gk3_disp_action a)
{
    switch (a) {
    case GK3_DISP_NONE: return "none";
    case GK3_DISP_MIGRATE: return "migrate";
    case GK3_DISP_CLEAR: return "clear";
    case GK3_DISP_EXECUTOR: return "executor";
    case GK3_DISP_WIPE_CAP: return "wipe_cap";
    }
    return "?";
}

void gk3_dispatch_plan(const gk3_bcb_info *bi, uint8_t *rec, uint8_t slot, gk3_disp_plan *out)
{
    gk3_memset(out, 0, sizeof(*out));
    out->why = bi->kind;
    /* §4.10：迁移标记写入之前的 BCB 一律只清不执行（BCB 为空也要置标记） */
    if (!gk3_rec_migrated(rec)) {
        out->action = GK3_DISP_MIGRATE;
        return;
    }
    switch (bi->kind) {
    case GK3_BCB_NONE:
        /* 执行端擦完 / 清完之后的第一次正常启动：旧的分派计数作废，下一份同样的 BCB 从 1 数起 */
        if (gk3_rec_dispatch_count(rec))
            gk3_rec_dispatch_reset(rec);
        out->action = GK3_DISP_NONE;
        return;
    case GK3_BCB_UNKNOWN:
        out->action = GK3_DISP_CLEAR;       /* 不清会堵住 init 的写入通道（reboot.cpp:923-937） */
        return;
    case GK3_BCB_BOOTLOADER:
    case GK3_BCB_FASTBOOT:
    case GK3_BCB_RECOVERY:
        /* fastbootd 也是进入时就清（fastboot/fastboot.cpp:96）。recovery 类在设计稿 §4.3.4 里写的是"由执行端清"，
         * S7c 改成入口先清：执行端没有 recovery ramdisk 能做的事（只有菜单），留着它只会让执行端缺失 / 崩溃时
         * 每次开机都被送回来（S7b README 的未决项） */
        out->clear_bcb_first = true;
        break;
    case GK3_BCB_WIPE:
    case GK3_BCB_PROMPT_WIPE:
        break;
    }
    out->count = gk3_rec_dispatch_enter(rec, bi->kind, slot, bi->digest);
    /* 只有免确认的 wipe 有上限；prompt_wipe 永不自动清（要人按键确认） */
    out->action = bi->kind == GK3_BCB_WIPE && out->count > GK3_WIPE_MAX_ENTRIES ? GK3_DISP_WIPE_CAP
                                                                                 : GK3_DISP_EXECUTOR;
}

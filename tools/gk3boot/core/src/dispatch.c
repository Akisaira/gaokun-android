/* libgk3core：BCB 分派的决定（设计稿 §4.3.4 的表 + §4.10 首跑迁移）。只决定、不写盘。
 *
 * 入口这一版（S5 动作模式）分派开关默认关（E-K7：开关必须与执行端 S7、迁移同版发布）；开关打开时也只把
 * 这里的决定记进日志和 GK3 记录、照常启动 Android —— 执行端还不存在。决定逻辑先写好、先测好，
 * 等执行端就绪时入口只需把"记录"换成"去执行端"。 */
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
        out->clear_command_first = true;    /* fastbootd 也是进入时就清（fastboot/fastboot.cpp:96） */
        break;
    case GK3_BCB_WIPE:
    case GK3_BCB_PROMPT_WIPE:
    case GK3_BCB_RECOVERY:
        break;
    }
    out->count = gk3_rec_dispatch_enter(rec, bi->kind, slot, bi->digest);
    /* 只有免确认的 wipe 有上限；prompt_wipe 永不自动清（要人按键确认），recovery 由执行端菜单清 */
    out->action = bi->kind == GK3_BCB_WIPE && out->count > GK3_WIPE_MAX_ENTRIES ? GK3_DISP_WIPE_CAP
                                                                                 : GK3_DISP_EXECUTOR;
}

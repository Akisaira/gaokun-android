/* BCB：Android 各写者的真实格式（出处见 bcb.c 头注释）+ GBL libmisc 的单测向量 + 边界。 */
#include "t.h"

static uint8_t bcb[2048];

static void set(const char *cmd, const char *rec)
{
    memset(bcb, 0, sizeof(bcb));
    memcpy(bcb, cmd, strlen(cmd));
    if (rec)
        memcpy(bcb + 64, rec, strlen(rec));
}

static gk3_bcb_kind kind(const char *cmd, const char *rec)
{
    gk3_bcb_info i;
    set(cmd, rec);
    gk3_bcb_classify(bcb, &i);
    return i.kind;
}

void test_bcb(void)
{
    gk3_bcb_info info;
    uint8_t d1[20];

    /* GBL libmisc/src/lib.rs:237-260 的向量（boot-rescue 在我们这里归 UNKNOWN：本机没有 rescue 模式，§4.3.4） */
    CHECK_EQ(kind("", NULL), GK3_BCB_NONE);
    CHECK_EQ(kind("boot-wrong", NULL), GK3_BCB_UNKNOWN);
    CHECK_EQ(kind("boot-recovery", NULL), GK3_BCB_RECOVERY);
    CHECK_EQ(kind("boot-fastboot", NULL), GK3_BCB_FASTBOOT);
    CHECK_EQ(kind("bootonce-bootloader", NULL), GK3_BCB_BOOTLOADER);
    CHECK_EQ(kind("boot-rescue", NULL), GK3_BCB_UNKNOWN);
    CHECK_EQ(kind("boot-quiescent", NULL), GK3_BCB_UNKNOWN);

    /* Android 写者的原样格式 */
    CHECK_EQ(kind("boot-recovery", "recovery\n--fastboot\n"), GK3_BCB_FASTBOOT);       /* adb reboot fastboot */
    CHECK_EQ(kind("boot-recovery", "recovery\n"), GK3_BCB_RECOVERY);                   /* adb reboot recovery */
    CHECK_EQ(kind("boot-recovery",
                  "recovery\n--wipe_data\n--reason=MasterClearConfirm,2026-10-05T02:00:00Z\n--locale=zh-Hans-CN\n"),
             GK3_BCB_WIPE);                                                            /* 设置 → 清除所有数据 */
    CHECK_EQ(kind("boot-recovery", "recovery\n--shutdown_after\n--wipe_data\n--reason=x\n--locale=en-US\n--keep_memtag_mode\n"),
             GK3_BCB_WIPE);
    CHECK_EQ(kind("boot-recovery", "recovery\n--prompt_and_wipe_data\n--reason=RescueParty\n--locale=en-US\n"),
             GK3_BCB_PROMPT_WIPE);                                                     /* RescueParty */
    /* 从严：不认识的参数 / 两种动作 → 交给菜单 */
    CHECK_EQ(kind("boot-recovery", "recovery\n--update_package=/data/ota.zip\n--wipe_data\n"), GK3_BCB_RECOVERY);
    CHECK_EQ(kind("boot-recovery", "recovery\n--wipe_data\n--fastboot\n"), GK3_BCB_RECOVERY);
    CHECK_EQ(kind("boot-recovery", "recovery\n--wipe_data\n--prompt_and_wipe_data\n"), GK3_BCB_RECOVERY);
    CHECK_EQ(kind("boot-recovery", "recovery\n--wipe_data\n--wipe_data\n"), GK3_BCB_RECOVERY);
    CHECK_EQ(kind("boot-recovery", "recovery\n--sideload\n"), GK3_BCB_RECOVERY);
    CHECK_EQ(kind("boot-recovery", "recovery\n--wipe_cache\n"), GK3_BCB_RECOVERY);
    CHECK_EQ(kind("boot-recovery", "recovery\n--wipe_data_now\n"), GK3_BCB_RECOVERY);   /* 精确匹配，不认前缀 */
    CHECK_EQ(kind("boot-recovery", "--wipe_data\n"), GK3_BCB_WIPE);                     /* 没有程序名行也认 */
    CHECK_EQ(kind("boot-recovery", "recovery\n--fastboot"), GK3_BCB_FASTBOOT);          /* 末尾没换行 */
    CHECK_EQ(kind("boot-recoveryX", "recovery\n--wipe_data\n"), GK3_BCB_UNKNOWN);
    CHECK_EQ(kind("bootonce-bootloader", "recovery\n--wipe_data\n"), GK3_BCB_BOOTLOADER); /* command 说了算 */

    /* command 字段 32 字节没有 NUL → 乱码 */
    memset(bcb, 'A', 32);
    gk3_bcb_classify(bcb, &info);
    CHECK_EQ(info.kind, GK3_BCB_UNKNOWN);
    CHECK(!info.command_terminated, "无 NUL");
    CHECK_EQ(strlen(info.command), 32);
    /* recovery 字段 768 字节没有 NUL → 不是 Android 写的，交给菜单 */
    set("boot-recovery", NULL);
    memset(bcb + 64, 'x', 768);
    gk3_bcb_classify(bcb, &info);
    CHECK_EQ(info.kind, GK3_BCB_RECOVERY);

    set("boot-recovery", "recovery\n--wipe_data\n--reason=a\n");
    gk3_bcb_classify(bcb, &info);
    CHECK(info.has_reason, "has_reason");
    CHECK_EQ(info.n_args, 2);
    memcpy(d1, info.digest, 20);
    bcb[2047] = 1;                                         /* reserved 里的变化也算"另一份 BCB" */
    gk3_bcb_classify(bcb, &info);
    CHECK(memcmp(d1, info.digest, 20) != 0, "摘要覆盖整个 2048 字节");

    /* 写：与 update_bootloader_message_in_struct 同格式，status / stage 保留 */
    {
        const char *args[] = {"--wipe_data", "--reason=test\n", "--locale=en-US"};
        memset(bcb, 0, sizeof(bcb));
        memcpy(bcb + 32, "OKAY", 4);
        memcpy(bcb + 832, "1/3", 3);
        memset(bcb + 64, 'z', 768);                        /* 旧的满长 recovery 要被清掉 */
        CHECK_EQ(gk3_bcb_write_recovery(bcb, args, 3), GK3_OK);
        CHECK_STR((char *)bcb, "boot-recovery");
        CHECK_STR((char *)bcb + 64, "recovery\n--wipe_data\n--reason=test\n--locale=en-US\n");
        CHECK(memcmp(bcb + 32, "OKAY", 4) == 0 && memcmp(bcb + 832, "1/3", 3) == 0, "status/stage 保留");
        CHECK(bcb[64 + 767] == 0, "recovery 字段尾部清零");
        CHECK(bcb[832 - 1] == 0, "recovery 字段清到 832");
        gk3_bcb_classify(bcb, &info);
        CHECK_EQ(info.kind, GK3_BCB_WIPE);
    }
    {
        char longarg[800];
        const char *args[] = {longarg};
        memset(longarg, 'a', sizeof(longarg) - 1);
        longarg[sizeof(longarg) - 1] = 0;
        CHECK_EQ(gk3_bcb_write_recovery(bcb, args, 1), GK3_ENOSPC);
    }

    /* 清除 */
    set("bootonce-bootloader", "recovery\n--x\n");
    gk3_bcb_clear_command(bcb);
    CHECK(gk3_is_zero(bcb, 32) && bcb[64] == 'r', "只清 command");
    gk3_bcb_clear(bcb);
    CHECK(gk3_is_zero(bcb, 2048), "全清");
    CHECK_STR(gk3_bcb_kind_name(GK3_BCB_PROMPT_WIPE), "prompt_wipe");
}

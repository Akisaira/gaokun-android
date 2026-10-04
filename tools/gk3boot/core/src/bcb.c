/* libgk3core：BCB（misc 偏移 0 的 bootloader_message，bootloader_message.h:67-84）。
 *
 * 写者与格式（设计稿 §2.4、§4.3.4）：
 *   adb reboot bootloader  → command="bootonce-bootloader"（bootloader_message.cpp:234-245）
 *   adb reboot fastboot    → "boot-recovery" + "recovery\n--fastboot\n"（init/reboot.cpp）
 *   设置 → 清除所有数据     → "boot-recovery" + "recovery\n--wipe_data\n--reason=…\n--locale=…\n"
 *                             （RecoverySystem.java:979-988，S1 grep）
 *   RescueParty            → "boot-recovery" + "--prompt_and_wipe_data" + --reason/--locale（:1230-1234）
 *   recovery 字段的拼法见 update_bootloader_message_in_struct（bootloader_message.cpp:214-232）。
 *
 * 分类从严：只认得出"纯粹"的 fastboot / wipe / prompt_wipe；带了任何不认识的参数
 * （--update_package、--sideload、两种动作同时出现……）一律归 RECOVERY，交给执行端菜单让人决定，
 * 不替用户自动清数据。 */
#include "gk3core.h"

static const char *const companions[] = {
    /* 只是附加信息、不改变动作的参数（前缀匹配） */
    "--reason=", "--locale=", "--keep_memtag_mode", "--shutdown_after",
};

static bool starts(const char *s, size_t n, const char *pfx)
{
    size_t k = 0;
    while (pfx[k]) {
        if (k >= n || s[k] != pfx[k])
            return false;
        k++;
    }
    return true;
}

static bool equals(const char *s, size_t n, const char *lit)
{
    return starts(s, n, lit) && gk3_strnlen(lit, 64) == n;
}

const char *gk3_bcb_kind_name(gk3_bcb_kind k)
{
    switch (k) {
    case GK3_BCB_NONE: return "none";
    case GK3_BCB_BOOTLOADER: return "bootloader";
    case GK3_BCB_FASTBOOT: return "fastboot";
    case GK3_BCB_WIPE: return "wipe";
    case GK3_BCB_PROMPT_WIPE: return "prompt_wipe";
    case GK3_BCB_RECOVERY: return "recovery";
    case GK3_BCB_UNKNOWN: return "unknown";
    }
    return "?";
}

static gk3_bcb_kind classify_recovery(const uint8_t *bcb, gk3_bcb_info *out)
{
    const char *r = (const char *)bcb + GK3_BCB_RECOVERY_OFF;
    size_t len = gk3_strnlen(r, GK3_BCB_RECOVERY_LEN), i = 0, line = 0;
    unsigned fastboot = 0, wipe = 0, prompt = 0, other = 0;

    if (len == GK3_BCB_RECOVERY_LEN)
        return GK3_BCB_RECOVERY;             /* 没有 NUL：不是 Android 写的格式 */
    while (i < len) {
        size_t s = i, n;
        while (i < len && r[i] != '\n')
            i++;
        n = i - s;
        if (i < len)
            i++;                              /* 跳过 '\n' */
        if (n == 0)
            continue;
        if (line++ == 0 && equals(r + s, n, "recovery"))
            continue;                         /* 第一行是程序名 */
        out->n_args++;
        if (equals(r + s, n, "--fastboot"))
            fastboot++;
        else if (equals(r + s, n, "--wipe_data"))
            wipe++;
        else if (equals(r + s, n, "--prompt_and_wipe_data"))
            prompt++;
        else {
            bool comp = false;
            for (size_t k = 0; k < sizeof(companions) / sizeof(companions[0]); k++)
                if (starts(r + s, n, companions[k]))
                    comp = true;
            if (starts(r + s, n, "--reason="))
                out->has_reason = true;
            if (!comp)
                other++;
        }
    }
    if (other || fastboot + wipe + prompt != 1)
        return GK3_BCB_RECOVERY;
    if (fastboot)
        return GK3_BCB_FASTBOOT;
    return wipe ? GK3_BCB_WIPE : GK3_BCB_PROMPT_WIPE;
}

void gk3_bcb_classify(const uint8_t *bcb, gk3_bcb_info *out)
{
    const char *c = (const char *)bcb + GK3_BCB_COMMAND_OFF;
    size_t n = gk3_strnlen(c, GK3_BCB_COMMAND_LEN);
    gk3_sha1_ctx h;

    gk3_memset(out, 0, sizeof(*out));
    gk3_memcpy(out->command, c, n);
    out->command[n] = 0;
    out->command_terminated = n < GK3_BCB_COMMAND_LEN;
    gk3_sha1_init(&h);
    gk3_sha1_update(&h, bcb, GK3_MISC_BCB_SIZE);
    gk3_sha1_final(&h, out->digest);

    if (!out->command_terminated)
        out->kind = GK3_BCB_UNKNOWN;
    else if (n == 0)
        out->kind = GK3_BCB_NONE;
    else if (equals(c, n, "bootonce-bootloader"))
        out->kind = GK3_BCB_BOOTLOADER;
    else if (equals(c, n, "boot-fastboot"))
        out->kind = GK3_BCB_FASTBOOT;
    else if (equals(c, n, "boot-recovery"))
        out->kind = classify_recovery(bcb, out);
    else
        out->kind = GK3_BCB_UNKNOWN;
}

void gk3_bcb_clear_command(uint8_t *bcb)
{
    gk3_memset(bcb + GK3_BCB_COMMAND_OFF, 0, GK3_BCB_COMMAND_LEN);
}

void gk3_bcb_clear(uint8_t *bcb)
{
    gk3_memset(bcb, 0, GK3_MISC_BCB_SIZE);
}

gk3_err gk3_bcb_write_recovery(uint8_t *bcb, const char *const *args, size_t nargs)
{
    static const char cmd[] = "boot-recovery", prog[] = "recovery\n";
    size_t need = sizeof(prog) - 1, o;
    char *r = (char *)bcb + GK3_BCB_RECOVERY_OFF;

    for (size_t i = 0; i < nargs; i++) {
        size_t n = gk3_strnlen(args[i], GK3_BCB_RECOVERY_LEN);
        if (n == 0)
            return GK3_EINVAL;
        need += n + (args[i][n - 1] != '\n');
    }
    if (need >= GK3_BCB_RECOVERY_LEN)
        return GK3_ENOSPC;
    gk3_memset(bcb + GK3_BCB_COMMAND_OFF, 0, GK3_BCB_COMMAND_LEN);
    gk3_memset(r, 0, GK3_BCB_RECOVERY_LEN);
    gk3_memcpy(bcb + GK3_BCB_COMMAND_OFF, cmd, sizeof(cmd) - 1);
    gk3_memcpy(r, prog, sizeof(prog) - 1);
    o = sizeof(prog) - 1;
    for (size_t i = 0; i < nargs; i++) {
        size_t n = gk3_strnlen(args[i], GK3_BCB_RECOVERY_LEN);
        gk3_memcpy(r + o, args[i], n);
        o += n;
        if (args[i][n - 1] != '\n')
            r[o++] = '\n';
    }
    return GK3_OK;
}

/* gk3-fastbootd：命令（fastboot-design §4.5 的表 + boot-entry-design §4.4.2 的改动）。
 *
 * 写盘的总规矩（§4.10）：
 *   · 只经 fb_part_write / fb_misc_write（白名单 + 越界检查都在 disk.c）；
 *   · 写前：重读主 GPT 核对没变（fb_disk_recheck），INFO 打出"盘型号 + 分区名 + 分区号 + PARTUUID + 起止 LBA"；
 *   · 写后：fsync + 丢缓存，再逐字节读回比对（raw / sparse / 擦除都一样）；
 *   · VAB 守卫照上游 fastbootd（fastboot/device/commands.cpp:72-88、:351-368）：SNAPSHOTTED / MERGING 时不许
 *     擦写 userdata / metadata；MERGING 时不许 set_active、不许整块刷 super。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fbd.h"

fb_state G;
fb_reboot_kind fb_pending_reboot;

static uint8_t misc[GK3_MISC_READ_SIZE];

const char *fb_merge_name(uint8_t st)
{
    switch (st) {
    case GK3_MERGE_SNAPSHOTTED: return "snapshotted";
    case GK3_MERGE_MERGING: return "merging";
    default: return "none";     /* NONE / UNKNOWN / CANCELLED：同上游 GetSnapshotUpdateStatus（variables.cpp:464-487） */
    }
}

uint8_t fb_vab_status(void)
{
    gk3_vab v;
    if (!G.disk.ok || fb_misc_read(&G.disk, misc))
        return GK3_MERGE_UNKNOWN;
    gk3_vab_parse(misc + GK3_MISC_SYSTEM_OFF, &v);
    return gk3_vab_effective(&v, G.cur_slot < 0 ? 0u : (unsigned)G.cur_slot);
}

gk3_err fb_bcab_read(uint8_t bc[32])
{
    if (!G.disk.ok || fb_misc_read(&G.disk, misc))
        return GK3_EIO;
    memcpy(bc, misc + GK3_MISC_BCAB_OFF, 32);
    return gk3_bcab_validate(bc);
}

static bool update_in_progress(void)
{
    uint8_t st = fb_vab_status();
    return st == GK3_MERGE_SNAPSHOTTED || st == GK3_MERGE_MERGING;
}

static void announce(fb_ctx *c, const char *verb, int pi)
{
    const fb_part *p = &G.disk.p[pi];
    fb_info(c, "%s %s on %s (%s) p%u PARTUUID %s LBA %llu-%llu", verb, p->name, G.disk.model, G.disk.path, p->index,
            p->partuuid, (unsigned long long)p->first_lba, (unsigned long long)p->last_lba);
}

static int precheck(fb_ctx *c)
{
    char why[256];
    if (fb_disk_recheck(&G.disk, why, sizeof(why))) {
        fb_fail(c, "%s", why);
        return -1;
    }
    return 0;
}

/* ---------------------------------------------------------------- 写 + 读回 */

#define VCHUNK (4u << 20)

static int verify_raw(int pi, uint64_t off, const uint8_t *data, size_t len)
{
    static uint8_t *rb;
    if (!rb && !(rb = malloc(VCHUNK)))
        return -1;
    for (size_t done = 0; done < len;) {
        size_t n = len - done > VCHUNK ? VCHUNK : len - done;
        if (fb_part_read(&G.disk, pi, off + done, rb, n))
            return -1;
        if (memcmp(rb, data + done, n)) {
            errno = EIO;
            return -2;
        }
        done += n;
    }
    return 0;
}

typedef struct {
    int pi;
    bool verify;
    uint64_t lowest;
    int rc;
} sp_ctx;

static uint8_t *fill_buf(uint32_t pattern)
{
    static uint8_t *b;
    static uint32_t cur;
    static bool have;
    if (!b && !(b = malloc(VCHUNK)))
        return NULL;
    if (!have || cur != pattern) {
        for (size_t i = 0; i < VCHUNK; i += 4)
            memcpy(b + i, &pattern, 4);     /* 盘上字节 = 小端的 pattern（libsparse 的 fill 语义） */
        cur = pattern;
        have = true;
    }
    return b;
}

static int sp_raw(void *ctx, uint64_t off, const void *data, size_t len)
{
    sp_ctx *s = ctx;
    if (off < s->lowest)
        s->lowest = off;
    if (s->verify)
        return verify_raw(s->pi, off, data, len) ? -1 : 0;
    return fb_part_write(&G.disk, s->pi, off, data, len);
}

static int sp_fill(void *ctx, uint64_t off, uint32_t pattern, uint64_t len)
{
    sp_ctx *s = ctx;
    uint8_t *b = fill_buf(pattern);
    if (!b)
        return -1;
    if (off < s->lowest)
        s->lowest = off;
    for (uint64_t done = 0; done < len;) {
        size_t n = len - done > VCHUNK ? VCHUNK : (size_t)(len - done);
        int r = s->verify ? verify_raw(s->pi, off + done, b, n) : fb_part_write(&G.disk, s->pi, off + done, b, n);
        if (r)
            return -1;
        done += n;
    }
    return 0;
}

/* 返回最低写入偏移（UINT64_MAX = 没写任何东西），失败 -1 并已回 FAIL */
static int write_image(fb_ctx *c, int pi, uint64_t *lowest)
{
    const fb_part *p = &G.disk.p[pi];
    *lowest = UINT64_MAX;
    if (fb_sparse_is(G.dl, G.dl_len)) {
        fb_sparse_hdr h;
        const char *e = fb_sparse_check(G.dl, G.dl_len, p->size, &h);
        sp_ctx s = {pi, false, UINT64_MAX, 0};
        fb_sparse_ops ops = {&s, sp_raw, sp_fill};
        if (e) {
            fb_fail(c, "%s (partition %s is %llu bytes) — nothing written", e, p->name, (unsigned long long)p->size);
            return -1;
        }
        fb_info(c, "sparse image: %u chunks, %u blocks of %u bytes (%llu bytes expanded)", h.total_chunks, h.total_blks,
                h.blk_sz, (unsigned long long)h.out_size);
        if (fb_sparse_walk(G.dl, G.dl_len, &ops)) {
            fb_fail(c, "write to %s failed: %s", p->name, strerror(errno));
            return -1;
        }
        if (fb_disk_sync_drop(&G.disk, pi, 0, h.out_size)) {
            fb_fail(c, "flush %s failed: %s", p->name, strerror(errno));
            return -1;
        }
        s.verify = true;
        if (fb_sparse_walk(G.dl, G.dl_len, &ops)) {
            fb_fail(c, "read-back of %s does NOT match the image (%s)", p->name, strerror(errno));
            return -1;
        }
        *lowest = s.lowest;
    } else {
        if (G.dl_len > p->size) {
            fb_fail(c, "image is %zu bytes, partition %s is only %llu — nothing written", G.dl_len, p->name,
                    (unsigned long long)p->size);
            return -1;
        }
        if (fb_part_write(&G.disk, pi, 0, G.dl, G.dl_len)) {
            fb_fail(c, "write to %s failed: %s", p->name, strerror(errno));
            return -1;
        }
        if (fb_disk_sync_drop(&G.disk, pi, 0, G.dl_len)) {
            fb_fail(c, "flush %s failed: %s", p->name, strerror(errno));
            return -1;
        }
        if (verify_raw(pi, 0, G.dl, G.dl_len)) {
            fb_fail(c, "read-back of %s does NOT match the image (%s)", p->name, strerror(errno));
            return -1;
        }
        *lowest = 0;
    }
    fb_info(c, "%s written and read back OK", p->name);
    return 0;
}

/* ---------------------------------------------------------------- set_active（boot-entry-design §4.4.2） */

static int read_part_cb(void *ctx, uint64_t off, void *buf, size_t len)
{
    return fb_part_read(&G.disk, *(int *)ctx, off, buf, len);
}

/* boot_x 里是一份完整、SHA1(id) 对得上的 v2 boot.img？img/len 非空时返回读出的整份（调用方 free）。 */
static int check_boot_part(unsigned slot, char *why, size_t why_len, uint8_t **img_out, size_t *len_out, gk3_bootimg *b)
{
    int pi = slot ? FB_P_BOOT_B : FB_P_BOOT_A;
    uint8_t hdr[GK3_BOOT_HDR_V2_SIZE], got[20];
    uint8_t *img;
    gk3_err e;
    if (fb_part_read(&G.disk, pi, 0, hdr, sizeof(hdr))) {
        snprintf(why, why_len, "cannot read %s", fb_part_names[pi]);
        return -1;
    }
    e = gk3_bootimg_parse(hdr, sizeof(hdr), G.disk.p[pi].size, b);
    if (e) {
        snprintf(why, why_len, "%s does not hold a valid boot image (%s)", fb_part_names[pi], gk3_strerror(e));
        return -1;
    }
    img = malloc((size_t)b->total_size);
    if (!img || fb_part_read(&G.disk, pi, 0, img, (size_t)b->total_size)) {
        free(img);
        snprintf(why, why_len, "cannot read %s", fb_part_names[pi]);
        return -1;
    }
    e = gk3_bootimg_parse(img, (size_t)b->total_size, G.disk.p[pi].size, b);
    if (!e)
        e = gk3_bootimg_verify_id(b, img, (size_t)b->total_size, got);
    if (e) {
        free(img);
        snprintf(why, why_len, "%s: boot image id (SHA-1) does not verify (%s)", fb_part_names[pi], gk3_strerror(e));
        return -1;
    }
    if (img_out) {
        *img_out = img;
        *len_out = (size_t)b->total_size;
    } else {
        free(img);
    }
    return 0;
}

static int do_set_active(fb_ctx *c, unsigned slot, bool from_flash)
{
    uint8_t bc[32], nb[32];
    gk3_err e;
    gk3_slot_info si;
    uint8_t st;
    char why[256];
    fb_lp lp;
    int sp = FB_P_SUPER;
    const char *le;
    gk3_bootimg b;
    fb_esp esp;
    unsigned cur = G.cur_slot < 0 ? slot : (unsigned)G.cur_slot;

#define REFUSE(...) do { if (from_flash) { fb_info(c, "set_active refused: " __VA_ARGS__); } \
                         else { fb_fail(c, __VA_ARGS__); } return -1; } while (0)

    if (!G.disk.ok)
        REFUSE("%s", G.disk.err);
    e = fb_bcab_read(bc);
    if (e)
        REFUSE("bootloader_control in misc is invalid (%s); boot Android once so the boot HAL rebuilds it", gk3_strerror(e));
    st = fb_vab_status();
    /* ① MERGING 时不换槽（commands.cpp:351-356） */
    if (st == GK3_MERGE_MERGING)
        REFUSE("Cannot change slots while a snapshot update is in progress (merging) — boot Android once to let it finish");
    /* ② boot_x 是完整可校验的 boot.img（gk3boot 从分区启动，坏的切过去也起不来） */
    if (check_boot_part(slot, why, sizeof(why), NULL, NULL, &b))
        REFUSE("%s", why);
    /* ③ super 的 LP 元数据服务槽 x（必要条件，不充分 —— _b 的陈旧元数据也能过这一条，fastboot-design §2.6） */
    le = fb_lp_read(read_part_cb, &sp, slot, &lp);
    if (le)
        REFUSE("super: %s", le);
    if (!fb_lp_serves_slot(&lp, slot))
        REFUSE("super's LP metadata has no _%c partitions for slot %c", 'a' + slot, 'a' + slot);
    /* ④ 目标槽可启动，或本会话刚刷过 boot_x（刷过就是用户在明确地重建这个槽） */
    gk3_bcab_get_slot(bc, slot, &si);
    if (!gk3_slot_bootable(&si) && !G.flashed_boot[slot])
        REFUSE("slot _%c is marked unbootable (priority %u, tries %u, not successful); flash boot_%c in this session first",
               'a' + slot, si.priority, si.tries, 'a' + slot);
    /* ⑤ ESP 上 slot_x 的三个文件在（直连回落要用，boot-entry-design §4.4.2） */
    {
        char err[256];
        if (fb_esp_open(&esp, &G.disk, &G.eopt, err, sizeof(err)))
            REFUSE("ESP: %s", err);
        if (fb_esp_slot_present(&esp, slot, err, sizeof(err))) {
            fb_esp_close(&esp);
            REFUSE("%s", err);
        }
    }
    if (st == GK3_MERGE_SNAPSHOTTED)
        fb_info(c, "Changing the active slot with a snapshot applied may cancel the update.");   /* commands.cpp:363-366 */

    memcpy(nb, bc, 32);
    gk3_bcab_set_active(nb, slot, cur);
    if (memcmp(nb, bc, 32)) {
        if (precheck(c)) {
            fb_esp_close(&esp);
            return -1;
        }
        fb_info(c, "misc: bootloader_control _%c -> priority 15 / tries 6 (libboot_control SetActiveBootSlot)", 'a' + slot);
        if (fb_misc_write(&G.disk, GK3_MISC_BCAB_OFF, nb, 32)) {
            fb_esp_close(&esp);
            if (from_flash)
                fb_info(c, "writing bootloader_control failed: %s", strerror(errno));
            else
                fb_fail(c, "writing bootloader_control failed: %s", strerror(errno));
            return -1;
        }
    }
    {
        char err[256];
        if (fb_esp_set_default(&esp, slot, err, sizeof(err)))
            fb_info(c, "WARNING: misc now selects _%c, but loader.conf default was not updated (%s); "
                       "gk3boot follows misc, the boot HAL re-syncs default on the next boot", 'a' + slot, err);
        else
            fb_info(c, "ESP: loader.conf default *-android-%c.conf", 'a' + slot);
    }
    fb_esp_close(&esp);
    G.cur_slot = (int)slot;
    return 0;
#undef REFUSE
}

/* ---------------------------------------------------------------- flash */

static bool is_lp_name(const char *name)
{
    fb_lp lp;
    int sp = FB_P_SUPER;
    for (unsigned s = 0; s < 2; s++) {
        if (fb_lp_read(read_part_cb, &sp, s, &lp))
            continue;
        for (uint32_t i = 0; i < lp.n_parts; i++) {
            size_t n = strlen(name);
            if (!strcmp(lp.parts[i].name, name) ||
                (!strncmp(lp.parts[i].name, name, n) && lp.parts[i].name[n] == '_' && lp.parts[i].name[n + 2] == 0))
                return true;
        }
    }
    return false;
}

static int lookup_or_fail(fb_ctx *c, const char *name, const char *verb)
{
    int pi = fb_part_lookup(name, G.cur_slot);
    if (pi >= 0)
        return pi;
    if (!strcmp(name, "misc") || !strcmp(name, "esp") || !strcmp(name, "EFI system partition") ||
        !strcmp(name, "ubunturescue") || !strcmp(name, "gk3rescue"))
        fb_fail(c, "%s is not %s from fastboot (only boot_a, boot_b, super, userdata, metadata are)", name, verb);
    else if (G.disk.ok && is_lp_name(name))
        fb_fail(c, "%s is a logical partition: 1.0 only supports flashing the whole super (use flash-all or the installer)", name);
    else
        fb_fail(c, "Partition doesn't exist: %s", name);
    return -1;
}

static void post_super(fb_ctx *c)
{
    fb_lp lp;
    int sp = FB_P_SUPER;
    bool serves[2] = {false, false};
    uint8_t bc[32], st;
    for (unsigned s = 0; s < 2; s++) {
        const char *e = fb_lp_read(read_part_cb, &sp, s, &lp);
        if (!e) {
            serves[s] = fb_lp_serves_slot(&lp, s);
            if (s == 0)
                fb_info(c, "super: LP metadata %u.%u, %u slot(s) of metadata, %u partitions in slot a's copy", lp.major,
                        lp.minor, lp.metadata_slot_count, lp.n_parts);
        } else if (s == 0) {
            fb_info(c, "WARNING: super has no readable LP metadata (%s) — Android will not boot from it", e);
            return;
        }
    }
    fb_info(c, "super: LP metadata serves slot(s):%s%s%s", serves[0] ? " a" : "", serves[1] ? " b" : "",
            !serves[0] && !serves[1] ? " none" : "");
    st = fb_vab_status();
    if (st == GK3_MERGE_SNAPSHOTTED) {
        if (G.cancel_requested) {
            uint8_t vab[64];
            memcpy(vab, misc + GK3_MISC_SYSTEM_OFF, 64);
            vab[5] = GK3_MERGE_NONE;      /* merge_status，bootloader_message.h:88-94 */
            if (fb_misc_write(&G.disk, GK3_MISC_SYSTEM_OFF, vab, 64))
                fb_info(c, "WARNING: could not reset the virtual A/B status in misc: %s", strerror(errno));
            else if (fb_part_zero_verify(&G.disk, FB_P_METADATA, 0, G.disk.p[FB_P_METADATA].size))
                fb_info(c, "WARNING: virtual A/B status reset, but zeroing metadata failed: %s — run 'fastboot erase metadata'",
                        strerror(errno));
            else
                fb_info(c, "snapshot-update cancel finished: virtual A/B status -> none, metadata zeroed (Android re-creates it)");
            G.cancel_requested = false;
        } else {
            fb_info(c, "WARNING: a snapshot update is still recorded (snapshotted); run 'fastboot snapshot-update cancel' and "
                       "flash super again, or Android may fail to mount the new super");
        }
    }
    if (fb_bcab_read(bc) == GK3_OK) {
        gk3_slot_info a, b;
        unsigned active;
        gk3_bcab_get_slot(bc, 0, &a);
        gk3_bcab_get_slot(bc, 1, &b);
        active = b.priority > a.priority ? 1u : 0u;
        if (!serves[active] && serves[active ^ 1]) {
            fb_info(c, "active slot _%c is not served by the new super; switching to _%c", 'a' + active, 'a' + (active ^ 1));
            if (do_set_active(c, active ^ 1, true) == 0)
                fb_info(c, "active slot is now _%c", 'a' + (active ^ 1));
        }
        for (unsigned s = 0; s < 2; s++)
            if (serves[s] && !G.flashed_boot[s])
                fb_info(c, "note: boot_%c was not flashed in this session — boot and super may come from different builds",
                        'a' + s);
    }
}

static void cmd_flash(fb_ctx *c, const char *name)
{
    int pi;
    uint64_t lowest;
    gk3_bootimg b;
    if (!G.dl || !G.dl_len) {
        fb_fail(c, "no image downloaded");
        return;
    }
    if (!G.disk.ok) {
        fb_fail(c, "%s", G.disk.err);
        return;
    }
    if ((pi = lookup_or_fail(c, name, "writable")) < 0)
        return;
    if ((pi == FB_P_USERDATA || pi == FB_P_METADATA) && update_in_progress()) {
        fb_fail(c, "Cannot flash %s while a snapshot update is in progress", fb_part_names[pi]);
        return;
    }
    if (pi == FB_P_SUPER && fb_vab_status() == GK3_MERGE_MERGING) {
        fb_fail(c, "a snapshot merge is in progress — boot Android once to let it finish before flashing super");
        return;
    }
    if (pi == FB_P_BOOT_A || pi == FB_P_BOOT_B) {
        uint8_t got[20];
        gk3_err e;
        if (fb_sparse_is(G.dl, G.dl_len)) {
            fb_fail(c, "boot images must be flashed raw, not sparse");
            return;
        }
        e = gk3_bootimg_parse(G.dl, G.dl_len, G.disk.p[pi].size, &b);
        if (!e && b.version != 2)
            e = GK3_EVERSION;
        if (!e && (!b.kernel_size || !b.ramdisk_size || !b.dtb_size))
            e = GK3_EINVAL;
        if (!e && b.total_size > G.dl_len)
            e = GK3_ERANGE;
        if (!e)
            e = gk3_bootimg_verify_id(&b, G.dl, G.dl_len, got);
        if (e) {
            fb_fail(c, "not a usable boot image for this device (need header v2 with kernel, ramdisk and dtb, valid SHA-1 id): %s",
                    gk3_strerror(e));
            return;
        }
    }
    if (precheck(c))
        return;
    announce(c, "writing", pi);
    if (write_image(c, pi, &lowest))
        return;
    if (pi == FB_P_BOOT_A || pi == FB_P_BOOT_B) {
        unsigned slot = pi == FB_P_BOOT_B;
        fb_esp esp;
        char err[256];
        G.flashed_boot[slot] = true;
        if (fb_esp_open(&esp, &G.disk, &G.eopt, err, sizeof(err)) ||
            fb_esp_sync_slot(&esp, slot, G.dl, G.dl_len, &b, fb_info_cb, c, err, sizeof(err))) {
            fb_esp_close(&esp);
            fb_fail(c, "boot_%c written and verified, but the ESP copy was NOT updated (%s); gk3boot boots from the partition, "
                       "only the direct fallback entry still has the old kernel", 'a' + slot, err);
            return;
        }
        fb_esp_close(&esp);
    } else if (pi == FB_P_SUPER) {
        G.flashed_super = true;
        if (lowest < (1u << 20))
            post_super(c);
    }
    fb_okay(c, "%s", "");
}

/* ---------------------------------------------------------------- erase（§4.6.1 第 2、3 步） */

int fb_erase_part(fb_ctx *c, int pi)
{
    const fb_part *p = &G.disk.p[pi];
    if (pi != FB_P_USERDATA && pi != FB_P_METADATA) {
        fb_fail(c, "erase is only supported for userdata and metadata (flash %s instead)", fb_part_names[pi]);
        return -1;
    }
    if (precheck(c))
        return -1;
    announce(c, "erasing", pi);
    fb_status("erasing %s", fb_part_names[pi]);
    if (pi == FB_P_USERDATA) {
        const uint64_t M = 1u << 20;
        int r = fb_part_discard(&G.disk, pi, 0, p->size);
        fb_info(c, "discard: %s", r == 0 ? "done" : r == 1 ? "not supported (zeroing only)" : strerror(errno));
        if (p->size <= 2 * M) {
            r = fb_part_zero_verify(&G.disk, pi, 0, p->size);
        } else {
            r = fb_part_zero_verify(&G.disk, pi, 0, M);
            if (!r)
                r = fb_part_zero_verify(&G.disk, pi, p->size - M, M);
        }
        if (r) {
            fb_fail(c, "zeroing userdata failed: %s", strerror(errno));
            return -1;
        }
        fb_info(c, "userdata: first and last 1 MiB zeroed, first 4 KiB read back as zero");
    } else {
        if (fb_part_zero_verify(&G.disk, pi, 0, p->size)) {
            fb_fail(c, "zeroing metadata failed: %s", strerror(errno));
            return -1;
        }
        fb_info(c, "metadata: all %llu bytes zeroed and read back", (unsigned long long)p->size);
    }
    return 0;
}

static void cmd_erase(fb_ctx *c, const char *name)
{
    int pi;
    if (!G.disk.ok) {
        fb_fail(c, "%s", G.disk.err);
        return;
    }
    if ((pi = lookup_or_fail(c, name, "erasable")) < 0)
        return;
    if (pi != FB_P_USERDATA && pi != FB_P_METADATA) {
        fb_fail(c, "erase is only supported for userdata and metadata (flash %s instead)", fb_part_names[pi]);
        return;
    }
    if (update_in_progress()) {
        fb_fail(c, "Cannot erase %s while a snapshot update is in progress", fb_part_names[pi]);   /* commands.cpp:233-236 */
        return;
    }
    if (fb_erase_part(c, pi))
        return;
    fb_info(c, "Will be formatted by Android on next boot");
    fb_okay(c, "Erasing succeeded");
}

/* ---------------------------------------------------------------- 重启类
 *
 * 守护进程不调 reboot(2)：收尾后以退出码把意图交给 /init（fbd.h 的 FB_EXIT_*）。
 *   gk3.dispatch=1（拉起本执行端的 gk3boot 会消费 BCB）：reboot-bootloader / -fastboot / -recovery 照 init 的写法写 BCB，
 *     然后冷重启 —— 走与 adb reboot bootloader 完全相同的路（gk3boot 分派回执行端），刷过的 boot_x 也真的换上了；
 *   否则（分派关着、或执行端是从别的路进来的）：BCB 写了也没人消费，还会堵住 init 的写入通道（reboot.cpp:923-937）
 *     ⇒ 不写，原地重起 fastboot（软重新枚举）/ 原地切到菜单。写不了 BCB（没有可信的 misc）时同样原地。 */

/* 返回 -1 = 已回 FAIL；0 = BCB 已写好或保留（冷重启）；1 = 没写（原地） */
static int bcb_update(fb_ctx *c, fb_reboot_kind k)
{
    uint8_t bcb[GK3_MISC_BCB_SIZE];
    gk3_bcb_info bi;
    if (k != FB_RB_BOOTLOADER && k != FB_RB_FASTBOOT && k != FB_RB_RECOVERY)
        return 0;
    if (!G.dispatch) {
        fb_info(c, "gk3boot BCB dispatch is off for this boot (no gk3.dispatch=1): %s in place, no BCB written",
                k == FB_RB_RECOVERY ? "switching to the menu" : "restarting fastboot");
        return 1;
    }
    if (!G.disk.ok) {
        fb_info(c, "no trusted misc (%s): %s in place", G.disk.err,
                k == FB_RB_RECOVERY ? "switching to the menu" : "restarting fastboot");
        return 1;
    }
    if (fb_misc_read(&G.disk, misc)) {
        fb_info(c, "WARNING: cannot read misc (%s): %s in place", strerror(errno),
                k == FB_RB_RECOVERY ? "switching to the menu" : "restarting fastboot");
        return 1;
    }
    memcpy(bcb, misc, sizeof(bcb));
    gk3_bcb_classify(bcb, &bi);
    if (k == FB_RB_BOOTLOADER || k == FB_RB_RECOVERY) {
        /* init 的写法（reboot.cpp:915-937、bootloader_message.cpp:234-246）：command 已有内容就不动 */
        if (bi.command[0] || !bi.command_terminated) {
            fb_info(c, "BCB already holds '%s' — kept (as Android's init would)", bi.command);
            return 0;
        }
        memset(bcb, 0, GK3_BCB_COMMAND_LEN);
        memcpy(bcb, k == FB_RB_BOOTLOADER ? "bootonce-bootloader" : "boot-recovery",
               strlen(k == FB_RB_BOOTLOADER ? "bootonce-bootloader" : "boot-recovery"));
    } else {
        /* init 的 reboot,fastboot 是整份重写（write_bootloader_message(options)）；但一个待执行的恢复出厂不能被它冲掉 */
        static const char *const args[] = {"--fastboot"};
        if (bi.kind == GK3_BCB_WIPE || bi.kind == GK3_BCB_PROMPT_WIPE) {
            fb_info(c, "BCB holds a pending %s — kept", gk3_bcb_kind_name(bi.kind));
            return 0;
        }
        gk3_bcb_clear(bcb);
        gk3_bcb_write_recovery(bcb, args, 1);
    }
    if (precheck(c))
        return -1;
    if (fb_misc_write(&G.disk, GK3_MISC_BCB_OFF, bcb, sizeof(bcb))) {
        fb_fail(c, "writing the boot intent to misc failed: %s", strerror(errno));
        return -1;
    }
    gk3_bcb_classify(bcb, &bi);
    fb_info(c, "misc: BCB '%s' (%s) written and read back", bi.command, gk3_bcb_kind_name(bi.kind));
    return 0;
}

static void cmd_reboot(fb_ctx *c, fb_reboot_kind k)
{
    int r = bcb_update(c, k);
    if (r < 0)
        return;
    if (r == 1)
        k = k == FB_RB_RECOVERY ? FB_RB_MENU : FB_RB_RESTART;
    fb_pending_reboot = k;
    fb_okay(c, "%s", k == FB_RB_POWEROFF ? "Shutting down" : k == FB_RB_RESTART ? "Restarting fastboot"
                     : k == FB_RB_MENU ? "Switching to the menu" : "Rebooting");
}

int fb_reboot_exit_code(fb_reboot_kind k)
{
    switch (k) {
    case FB_RB_POWEROFF: return FB_EXIT_POWEROFF;
    case FB_RB_RESTART: return FB_EXIT_RESTART;
    case FB_RB_MENU: return FB_EXIT_MENU;
    default: return FB_EXIT_REBOOT;     /* reboot；bootloader / fastboot / recovery 的 BCB 已经写好 */
    }
}

void fb_do_reboot(fb_reboot_kind k)
{
    static const char *const names[] = {"none", "reboot", "bootloader", "fastboot", "recovery", "poweroff",
                                        "restart", "menu"};
    int code = fb_reboot_exit_code(k);
    fb_pending_reboot = FB_RB_NONE;
    fb_log("reboot requested: %s (exit code %d for /init)", names[k], code);
    if (G.test_reboot) {
        FILE *f = fopen(G.test_reboot, "a");
        if (f) {
            fprintf(f, "%s\n", names[k]);
            fclose(f);
        }
        return;
    }
    fb_status("%s", k == FB_RB_POWEROFF ? "powering off (host request)"
                    : k == FB_RB_RESTART ? "restarting fastboot (host request)"
                    : k == FB_RB_MENU ? "switching to the menu (host request)"
                    : k == FB_RB_REBOOT ? "rebooting (host request)"
                    : "rebooting to the executor (BCB written, host request)");
    sync();
    usleep(300000);     /* 让最后一个 OKAY 走完 USB（/init 收到退出码后才解绑 UDC） */
    exit(code);
}

/* ---------------------------------------------------------------- 进入时（boot-entry-design §4.3.4） */

void fb_entry(void)
{
    uint8_t bcb[GK3_MISC_BCB_SIZE];
    gk3_bcb_info bi;
    if (!G.disk.ok) {
        snprintf(G.entry_note, sizeof(G.entry_note), "no target disk: BCB not inspected");
        return;
    }
    if (fb_misc_read(&G.disk, misc)) {
        snprintf(G.entry_note, sizeof(G.entry_note), "cannot read misc");
        return;
    }
    memcpy(bcb, misc, sizeof(bcb));
    gk3_bcb_classify(bcb, &bi);
    fb_log("entry: gk3.why=%s, BCB kind=%s command='%s'", G.why[0] ? G.why : "-", gk3_bcb_kind_name(bi.kind), bi.command);
    switch (bi.kind) {
    case GK3_BCB_BOOTLOADER:
    case GK3_BCB_FASTBOOT:
    case GK3_BCB_RECOVERY:
        /* 已经在执行端里了，这类请求就算满足了：整份清掉（= fastbootd 进入时的 clear_bootloader_message，
         * fastboot/fastboot.cpp:96），否则 fastboot reboot 之后又被 gk3boot 送回来 */
        gk3_bcb_clear(bcb);
        if (fb_misc_write(&G.disk, GK3_MISC_BCB_OFF, bcb, sizeof(bcb)))
            snprintf(G.entry_note, sizeof(G.entry_note), "BCB '%s' (%s) could NOT be cleared: %s", bi.command,
                     gk3_bcb_kind_name(bi.kind), strerror(errno));
        else
            snprintf(G.entry_note, sizeof(G.entry_note), "BCB '%s' (%s) consumed and cleared", bi.command,
                     gk3_bcb_kind_name(bi.kind));
        break;
    case GK3_BCB_WIPE:
    case GK3_BCB_PROMPT_WIPE:
        snprintf(G.entry_note, sizeof(G.entry_note), "BCB holds a pending %s — left for the executor UI (S7b)",
                 gk3_bcb_kind_name(bi.kind));
        break;
    case GK3_BCB_NONE:
        snprintf(G.entry_note, sizeof(G.entry_note), "BCB empty");
        break;
    default:
        snprintf(G.entry_note, sizeof(G.entry_note), "BCB '%s' unrecognised — left alone (gk3boot clears these)", bi.command);
        break;
    }
    fb_log("entry: %s", G.entry_note);
}

/* ---------------------------------------------------------------- oem */

static void log_line_cb(void *ctx, const char *line)
{
    fb_info(ctx, "%s", line);
}

static void device_info(fb_ctx *c)
{
    uint8_t bc[32];
    gk3_err e;
    fb_info(c, "gk3-fastbootd %s, why=%s, gk3.slot=%d, current-slot=%c, bootver=%s", GK3FB_VERSION, G.why[0] ? G.why : "-",
            G.slot_hint, G.cur_slot >= 0 ? 'a' + G.cur_slot : '?', G.bootver[0] ? G.bootver : "-");
    if (!G.disk.ok) {
        fb_info(c, "disk: NOT usable — %s", G.disk.err);
        return;
    }
    fb_info(c, "disk: %s (%s), %u-byte blocks, %llu blocks, GUID %s", G.disk.path, G.disk.model, G.disk.bs,
            (unsigned long long)G.disk.nblocks, G.disk.disk_guid);
    for (int i = 0; i < FB_P_N; i++)
        fb_info(c, "  %-8s p%u LBA %llu-%llu %s", G.disk.p[i].name, G.disk.p[i].index,
                (unsigned long long)G.disk.p[i].first_lba, (unsigned long long)G.disk.p[i].last_lba, G.disk.p[i].partuuid);
    fb_info(c, "entry: %s", G.entry_note);
    e = fb_bcab_read(bc);
    if (e) {
        fb_info(c, "bootloader_control: invalid (%s)", gk3_strerror(e));
    } else {
        for (unsigned s = 0; s < 2; s++) {
            gk3_slot_info si;
            gk3_bcab_get_slot(bc, s, &si);
            fb_info(c, "bootloader_control _%c: priority %u tries %u successful %u verity_corrupted %u (%s)", 'a' + s,
                    si.priority, si.tries, si.successful, si.verity_corrupted, gk3_slot_bootable(&si) ? "bootable" : "unbootable");
        }
    }
    fb_info(c, "virtual A/B: %s", fb_merge_name(fb_vab_status()));
    if (gk3_rec_validate(misc + GK3_MISC_GK3_OFF) == GK3_OK) {
        gk3_event ev[GK3_EV_N];
        uint32_t n = gk3_rec_events(misc + GK3_MISC_GK3_OFF, ev, GK3_EV_N);
        fb_info(c, "GK3 record: migrated=%d boot_streak=%u dispatch_count=%u events=%u", gk3_rec_migrated(misc + GK3_MISC_GK3_OFF),
                gk3_rec_boot_streak(misc + GK3_MISC_GK3_OFF), gk3_rec_dispatch_count(misc + GK3_MISC_GK3_OFF), n);
        for (uint32_t i = n > 5 ? n - 5 : 0; i < n; i++)
            fb_info(c, "  event #%u %s slot %u aux %u", ev[i].seq, gk3_ev_name((gk3_ev_code)ev[i].code), ev[i].slot, ev[i].aux);
    } else {
        fb_info(c, "GK3 record: none");
    }
    {
        fb_esp esp;
        char err[256], def[128];
        if (fb_esp_open(&esp, &G.disk, &G.eopt, err, sizeof(err)) == 0) {
            fb_esp_get_default(&esp, def, sizeof(def));
            fb_info(c, "ESP: %s %s, loader.conf default '%s'", esp.dev[0] ? esp.dev : esp.root, esp.partuuid, def);
            fb_esp_close(&esp);
        } else {
            fb_info(c, "ESP: %s", err);
        }
    }
}

static void cmd_oem(fb_ctx *c, const char *arg)
{
    if (!strcmp(arg, "log")) {
        fb_log_foreach(400, log_line_cb, c);
        fb_okay(c, "%s", "");
    } else if (!strcmp(arg, "device-info")) {
        device_info(c);
        fb_okay(c, "%s", "");
    } else if (!strcmp(arg, "help")) {
        fb_info(c, "oem log          show the executor log");
        fb_info(c, "oem device-info  disk, partitions, misc, ESP");
        fb_okay(c, "%s", "");
    } else {
        fb_fail(c, "unknown oem command (try 'fastboot oem help')");
    }
}

/* ---------------------------------------------------------------- 分派 */

static void cmd_snapshot_update(fb_ctx *c, const char *arg)
{
    uint8_t st = fb_vab_status();
    if (!strcmp(arg, "merge")) {
        fb_fail(c, "snapshot-update merge is not supported here — boot Android, it merges by itself");
        return;
    }
    if (strcmp(arg, "cancel") && arg[0]) {
        fb_fail(c, "expected: snapshot-update cancel");
        return;
    }
    if (!G.disk.ok) {
        fb_fail(c, "%s", G.disk.err);
        return;
    }
    if (st == GK3_MERGE_MERGING) {
        fb_fail(c, "a snapshot merge is in progress — boot Android once to let it finish (it cannot be cancelled)");
        return;
    }
    if (st != GK3_MERGE_SNAPSHOTTED) {
        fb_okay(c, "no snapshot update to cancel (%s)", fb_merge_name(st));
        return;
    }
    G.cancel_requested = true;
    fb_info(c, "noted: this executor has no libsnapshot; the cancel is completed when the whole super is flashed in "
               "this session (virtual A/B status -> none, metadata zeroed)");
    fb_okay(c, "%s", "");
}

static void cmd_set_active(fb_ctx *c, const char *arg)
{
    unsigned slot;
    if (arg[0] == '_')
        arg++;
    if ((arg[0] != 'a' && arg[0] != 'b') || arg[1]) {
        fb_fail(c, "Bad slot suffix (a or b)");
        return;
    }
    slot = (unsigned)(arg[0] - 'a');
    if (do_set_active(c, slot, false) == 0)
        fb_okay(c, "%s", "");
}

static void cmd_flashing(fb_ctx *c, const char *arg)
{
    if (!strcmp(arg, "unlock") || !strcmp(arg, "unlock_critical")) {
        fb_info(c, "this device is always unlocked (orange state)");
        fb_okay(c, "%s", "");
    } else if (!strcmp(arg, "get_unlock_ability")) {
        fb_info(c, "get_unlock_ability: 1");
        fb_okay(c, "%s", "");
    } else if (!strcmp(arg, "lock") || !strcmp(arg, "lock_critical")) {
        fb_fail(c, "locking is not supported (test-key build, orange state)");
    } else {
        fb_fail(c, "unknown flashing command");
    }
}

void fb_dispatch(fb_ctx *c, char *cmd)
{
    char *arg = strchr(cmd, ':');
    if (arg)
        *arg++ = 0;
    else
        arg = cmd + strlen(cmd);

    if (!strcmp(cmd, "getvar"))
        fb_cmd_getvar(c, arg);
    else if (!strcmp(cmd, "flash"))
        cmd_flash(c, arg);
    else if (!strcmp(cmd, "erase"))
        cmd_erase(c, arg);
    else if (!strcmp(cmd, "set_active"))
        cmd_set_active(c, arg);
    else if (!strcmp(cmd, "snapshot-update"))
        cmd_snapshot_update(c, arg);
    else if (!strcmp(cmd, "reboot"))
        cmd_reboot(c, FB_RB_REBOOT);
    else if (!strcmp(cmd, "reboot-bootloader"))
        cmd_reboot(c, FB_RB_BOOTLOADER);
    else if (!strcmp(cmd, "reboot-fastboot"))
        cmd_reboot(c, FB_RB_FASTBOOT);
    else if (!strcmp(cmd, "reboot-recovery"))
        cmd_reboot(c, FB_RB_RECOVERY);
    else if (!strcmp(cmd, "shutdown") || !strcmp(cmd, "powerdown"))
        cmd_reboot(c, FB_RB_POWEROFF);
    else if (!strncmp(cmd, "oem ", 4))
        cmd_oem(c, cmd + 4);
    else if (!strncmp(cmd, "flashing ", 9))
        cmd_flashing(c, cmd + 9);
    else if (!strcmp(cmd, "boot"))
        fb_fail(c, "boot is not supported (no kexec in this kernel); flash boot_a/boot_b instead");
    else if (!strcmp(cmd, "continue"))
        fb_fail(c, "continue is not supported; use 'fastboot reboot'");
    else if (!strcmp(cmd, "update-super") || !strcmp(cmd, "create-logical-partition") ||
             !strcmp(cmd, "delete-logical-partition") || !strcmp(cmd, "resize-logical-partition"))
        fb_fail(c, "logical partition operations are not supported: flash the whole super (flash-all, or an update zip without super_empty.img)");
    else if (!strcmp(cmd, "fetch") || !strcmp(cmd, "upload"))
        fb_fail(c, "%s is not supported", cmd);
    else if (!strcmp(cmd, "gsi"))
        fb_fail(c, "gsi is not supported");
    else
        fb_fail(c, "unknown command");
}

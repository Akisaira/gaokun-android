/*
 * gk3boot.efi —— 统一启动入口（docs/boot-entry-design.md 方案 Y）的 S5 最小可上机版本，目标是 E4 门槛：
 *
 *   作为 systemd-boot 的非默认 efi 条目经 LoaderEntryOneShot 进入 → 定位本盘 → 读 misc 算出"动作模式会怎么做"
 *   （只记录，观察模式）→ 读 boot_<x> 整份、校验 SHA1(id) → 拼 cmdline → H2 交接（handoff.c）真正启动 Android。
 *
 * 这一版是【观察模式专用】（§4.12 "观察模式"）：
 *   - 不写 misc、不扣 tries、不消费 BCB、不写任何块设备 —— 块设备包装连 write 回调都不给（gk3_blk_from_bio）；
 *   - 不写任何 EFI 变量；
 *   - ESP 上只写自己的日志 \EFI\gk3boot\log\boot-<n>.txt（n 递增、不覆盖）。
 *   动作模式（扣 tries、BCB 分派、迁移、GK3 记录）留给 S5 后续 / S6；LoadOptions 里没有 gk3.observe=1 也按观察模式跑，
 *   并在日志里记一行。
 *
 * fail-open（§4.12）：任何一步失败 → 记日志 → ResetSystem(EfiResetCold)，下一次由 systemd-boot 的默认条目
 * （今天的直连条目 <mid>-android-<x>.conf）接手。最小版本【不写】LoaderEntryOneShot（阶梯第 1 步），理由：
 *   E4 的条目本来就不是默认项（经 OneShot 进入，systemd-boot 读后即删，boot.c:1637-1640），复位后自然回到默认的直连条目；
 *   不写变量 = 观察模式"什么都不写"的承诺不打折，也不会两次改动固件状态。
 *   ⚠️ 代价：本版本不能当默认条目用（E5 之前必须补上阶梯第 1 步，否则 fail-open 会复位回自己、循环）。
 * 绝不 return 错误码给 systemd-boot（boot.c:2971-2973 会原样交给固件，华为 BootFail 计数，§2.1），也不 return SUCCESS
 * （会停在不倒计时的菜单上）。
 *
 * LoadOptions（条目的 options 行，空格分隔）：
 *   gk3.observe=1     观察模式（本版本只有这一种；缺省也按观察模式跑并记一行）
 *   gk3.slot=a|b      强制启动这一槽（测试用；决策照算照记）
 *   gk3.hint=a|b      BCAB 无效时按它启动（§4.3.2-1），缺省 a
 *   gk3.hold=<秒>     fail-open 复位前在屏幕上停多久，缺省 5，最大 30
 */
#include "gk3efi.h"

#include "handoff.h"

#ifndef GK3BOOT_VERSION
#define GK3BOOT_VERSION "dev"
#endif

#define WATCHDOG_SEC 120               /* 设计稿 §4.2 第 0 步 */
#define WATCHDOG_CODE 0x10002          /* 0x0000–0xFFFF 留给固件 */
#define LOG_CAP (256u * 1024u)
#define LOG_MAX 1000u                  /* boot-0 … boot-999；满了只上屏幕（README 的上机步骤里有清理） */
#define BOOTIMG_MAX (128ull * 1024 * 1024)

static uint64_t T0;
static EFI_LOADED_IMAGE_PROTOCOL *self_li;
static gk3_logfile g_log;

static struct {
    bool observe_opt;          /* LoadOptions 里有 gk3.observe=1 */
    int force_slot;            /* -1 = 不强制 */
    unsigned hint;
    unsigned hold;
} opt = {false, -1, 0, 5};

#define MS() ((unsigned long long)(gk3_us_since(T0) / 1000u))
#define MSF(us) (unsigned long long)((us) / 1000u), (unsigned long long)((us) / 100u % 10u)

static void hex_str(const uint8_t *p, size_t n, char *out, size_t cap)
{
    size_t o = 0;
    for (size_t i = 0; i < n && o + 3 <= cap; i++)
        o += (size_t)gk3_snprintf(out + o, cap - o, "%02x", p[i]);
    if (cap)
        out[o < cap ? o : cap - 1] = 0;
}

/* ------------------------------------------------------------------ fail-open */

static void pre_start(void)
{
    gk3_logd("gk3boot.result=handoff t=%llu ms (log closed before StartImage)\n", MS());
    gk3_log_close(&g_log);
}

static void __attribute__((noreturn, format(printf, 2, 3))) fail_open(const char *stage, const char *fmt, ...)
{
    static char why[512];
    va_list ap;
    va_start(ap, fmt);
    gk3_vsnprintf(why, sizeof(why), fmt, ap);
    va_end(ap);

    if (!g_log.open)
        gk3_log_reopen(&g_log);       /* 交接失败回来时文件已关 */
    gk3_logf("\n!! FAIL-OPEN at %s: %s\n", stage, why);
    gk3_logf("gk3boot.result=fail-open stage=%s t=%llu ms\n", stage, MS());
    gk3_logf("fail-open: nothing was written (observe build: no misc, no EFI variable).\n"
             "fail-open: ResetSystem(EfiResetCold) -> systemd-boot boots its default entry (the direct Android entry).\n");
    gk3_log_close(&g_log);
    if (gk3_lg.file_failed)
        gk3_screenf("!! log file write failed: %s (log is incomplete)\n", gk3_efi_strerror(gk3_lg.file_err));
    for (unsigned s = opt.hold; s > 0; s--) {
        gk3_screenf("cold reset in %u s ...\n", s);
        gk3_bs->Stall(1000000);
    }
    gk3_rt->ResetSystem(EfiResetCold, EFI_SUCCESS, 0, NULL);
    /* 不该回来。回来了就等看门狗（绝不把错误返回给固件） */
    gk3_screenf("!! ResetSystem returned; waiting for the %u s watchdog\n", WATCHDOG_SEC);
    for (;;)
        gk3_bs->Stall(1000000);
}

/* ------------------------------------------------------------------ 选项 */

/* 找 " key=" 形式的 token，值拷进 out（到空白为止）；没有返回 false */
static bool opt_get(const char *s, const char *key, char *out, size_t cap)
{
    size_t kl = gk3_strlen(key), sl = gk3_strlen(s);
    for (size_t i = 0; i + kl <= sl; i++) {
        if ((i == 0 || s[i - 1] == ' ') && !gk3_memcmp(s + i, key, kl)) {
            size_t n = 0;
            for (const char *q = s + i + kl; *q && *q != ' ' && n + 1 < cap; q++)
                out[n++] = *q;
            out[n] = 0;
            return true;
        }
    }
    return false;
}

static int slot_letter(const char *v)
{
    if ((v[0] == 'a' || v[0] == 'b') && !v[1])
        return v[0] - 'a';
    if (v[0] == '_' && (v[1] == 'a' || v[1] == 'b') && !v[2])
        return v[1] - 'a';
    return -1;
}

static void step_header(void)
{
    static char opts[1024];
    char v[32];
    EFI_STATUS st;

    gk3_logf("gk3boot %s  (S5 minimal, observe-only build; docs/boot-entry-design.md E4)\n", GK3BOOT_VERSION);
    st = gk3_bs->SetWatchdogTimer(WATCHDOG_SEC, WATCHDOG_CODE, 0, NULL);
    gk3_logf("watchdog: %u s %s\n", WATCHDOG_SEC, EFI_ERROR(st) ? gk3_efi_strerror(st) : "armed");

    st = gk3_bs->HandleProtocol(gk3_image, (EFI_GUID *)&gk3_guid_loaded_image, (void **)&self_li);
    if (EFI_ERROR(st) || !self_li) {
        self_li = NULL;
        fail_open("self", "LoadedImage(self): %s", gk3_efi_strerror(st));
    }
    opts[0] = 0;
    if (self_li->LoadOptions && self_li->LoadOptionsSize >= 2)
        gk3_ucs2_to_ascii(self_li->LoadOptions, self_li->LoadOptionsSize / 2, opts, sizeof(opts));
    gk3_logf("load_options: \"%s\"\n", opts);

    opt.observe_opt = opt_get(opts, "gk3.observe=", v, sizeof(v)) && v[0] == '1' && !v[1];
    if (opt_get(opts, "gk3.slot=", v, sizeof(v)) && (opt.force_slot = slot_letter(v)) < 0)
        fail_open("options", "gk3.slot=%s is not a|b", v);
    if (opt_get(opts, "gk3.hint=", v, sizeof(v))) {
        int h = slot_letter(v);
        if (h < 0)
            fail_open("options", "gk3.hint=%s is not a|b", v);
        opt.hint = (unsigned)h;
    }
    if (opt_get(opts, "gk3.hold=", v, sizeof(v))) {
        unsigned h = 0;
        for (const char *q = v; *q >= '0' && *q <= '9' && h < 1000; q++)
            h = h * 10 + (unsigned)(*q - '0');
        opt.hold = h > 30 ? 30 : h;
    }
    gk3_logf("mode: observe%s force_slot=%c hint=_%c hold=%u s\n",
             opt.observe_opt ? "" : " (gk3.observe=1 missing: this build has no action mode, observing anyway)",
             opt.force_slot < 0 ? '-' : 'a' + opt.force_slot, 'a' + opt.hint, opt.hold);
}

static void step_open_log(void)
{
    if (gk3_log_open_seq(&g_log, self_li->DeviceHandle, u"\\EFI\\gk3boot\\log", "boot-", LOG_MAX)) {
        gk3_logf("log_file: \\EFI\\gk3boot\\log\\boot-%u.txt\n", g_log.n);
        gk3_log_sync();
    } else {
        gk3_logf("!! no log file (screen only); continuing\n");
    }
}

/* ------------------------------------------------------------------ 1. 本盘 + GPT（同探针 step_disk，设计稿 §4.2 第 1 步） */

static struct {
    EFI_BLOCK_IO_PROTOCOL *bio;
    gk3_bio_ctx ctx;
    gk3_blk dev;
    gk3_gpt gpt;
    uint8_t *entries;
} disk;

static void step_disk(void)
{
    static char dp[1024];
    UINTN n = 0, matches = 0;
    EFI_HANDLE *hs = NULL;
    uint64_t t = gk3_ticks();

    EFI_DEVICE_PATH_PROTOCOL *esp = gk3_dp_of(self_li->DeviceHandle);
    const EFI_DEVICE_PATH_PROTOCOL *hd = gk3_dp_find_hd(esp);
    if (!esp || !hd)
        fail_open("disk", "own device path has no HD node");
    size_t prefix = (size_t)((const uint8_t *)hd - (const uint8_t *)esp);
    gk3_dp_text(esp, dp, sizeof(dp));
    gk3_logd("esp_dp: %s\n", dp);

    EFI_STATUS st = gk3_handles(&gk3_guid_block_io, &n, &hs);
    if (EFI_ERROR(st))
        fail_open("disk", "LocateHandleBuffer(BlockIo): %s", gk3_efi_strerror(st));
    for (UINTN i = 0; i < n; i++) {
        EFI_BLOCK_IO_PROTOCOL *b = NULL;
        if (EFI_ERROR(gk3_bs->HandleProtocol(hs[i], (EFI_GUID *)&gk3_guid_block_io, (void **)&b)) || !b || !b->Media)
            continue;
        EFI_DEVICE_PATH_PROTOCOL *d = gk3_dp_of(hs[i]);
        /* 整盘 = 自己 ESP 的设备路径去掉 HD 节点（前缀 + 结束节点） */
        if (!b->Media->LogicalPartition && d && gk3_dp_size(d) == prefix + 4 && !gk3_memcmp(d, esp, prefix)) {
            matches++;
            if (!disk.bio) {
                disk.bio = b;
                gk3_dp_text(d, dp, sizeof(dp));
                gk3_logd("whole_disk: %s bs=%u last=%llu\n", dp, b->Media->BlockSize,
                         (unsigned long long)b->Media->LastBlock);
            }
        }
    }
    gk3_free(hs);
    /* §4.2 第 1 步：本盘找不到（或不唯一）时设计稿要扫所有整盘；最小版本直接 fail-open */
    if (matches != 1)
        fail_open("disk", "whole-disk candidates for own ESP: %llu (expected 1)", (unsigned long long)matches);
    if (disk.bio->Media->BlockSize < 512 || disk.bio->Media->BlockSize > 4096 || disk.bio->Media->IoAlign > 4096)
        fail_open("disk", "unsupported block size %u / io_align %u", disk.bio->Media->BlockSize,
                  disk.bio->Media->IoAlign);
    gk3_blk_from_bio(&disk.dev, &disk.ctx, disk.bio);   /* 只读：write / flush 都是 NULL */

    uint32_t bs = disk.dev.block_size;
    uint8_t *hdr = gk3_alloc_pages(bs);
    gk3_gpt g0;
    if (!hdr)
        fail_open("disk", "alloc");
    if (disk.dev.read(disk.dev.ctx, 1, 1, hdr))
        fail_open("disk", "read LBA1: %s", gk3_efi_strerror(disk.ctx.last_err));
    gk3_err e = gk3_gpt_parse_header(hdr, bs, &g0);
    if (e)
        fail_open("disk", "GPT header: %s", gk3_strerror(e));
    size_t elen = ((size_t)g0.num_entries * g0.entry_size + bs - 1) / bs * bs;
    if (!(disk.entries = gk3_alloc_pages(elen)))
        fail_open("disk", "alloc entries %llu", (unsigned long long)elen);
    e = gk3_gpt_read(&disk.dev, &disk.gpt, hdr, disk.entries, elen);
    if (e)
        fail_open("disk", "GPT: %s (efi %s)", gk3_strerror(e), gk3_efi_strerror(disk.ctx.last_err));

    /* 入口硬要求的五个名字各恰好一个（同探针 unique_required；metadata 只记录） */
    static const char *const req[] = {"misc", "boot_a", "boot_b", "super", "userdata"};
    const char *bad = NULL;
    e = gk3_gpt_require_unique(&disk.gpt, req, sizeof(req) / sizeof(req[0]), &bad);
    if (e)
        fail_open("disk", "GPT name %s: %s", bad ? bad : "?", gk3_strerror(e));
    gk3_gpt_part mp;
    gk3_logd("gpt: metadata %s\n", gk3_gpt_find(&disk.gpt, "metadata", &mp) ? "not unique/absent" : "unique");
    /* 自己的 ESP 在这张表里对得上吗（HD 节点的分区号与 PARTUUID）—— 对不上说明设备路径前缀骗了我们 */
    const uint8_t *h = (const uint8_t *)hd;
    gk3_gpt_part ep;
    if (h[41] != 2 || gk3_gpt_get(&disk.gpt, gk3_le32(h + 4) - 1, &ep) || gk3_memcmp(ep.part_guid, h + 24, 16))
        fail_open("disk", "own ESP (partition %u) not found in this GPT", gk3_le32(h + 4));
    char g[37];
    gk3_guid_str(disk.gpt.disk_guid, g);
    gk3_logf("disk: gpt %s, %u partitions, misc/boot_a/boot_b/super/userdata unique, esp=p%u  [%llu.%llu ms]\n", g,
             gk3_gpt_count(&disk.gpt), ep.index, MSF(gk3_us_since(t)));
    gk3_free_pages(hdr, bs);
}

static void part(const char *name, gk3_gpt_part *p)
{
    gk3_err e = gk3_gpt_find(&disk.gpt, name, p);
    if (e)
        fail_open("disk", "%s: %s", name, gk3_strerror(e));
}

/* ------------------------------------------------------------------ 2. misc 与决策（只算、只记，不写） */

static const char *const selk[] = {"boot", "bcab_invalid", "noslot", "merging"};

/* §4.3.4：动作模式会怎么处理这份 BCB（这一版只记录 —— 与今天的直连条目一样不消费 BCB） */
static const char *bcb_would(gk3_bcb_kind k)
{
    switch (k) {
    case GK3_BCB_NONE: return "normal boot";
    case GK3_BCB_BOOTLOADER: return "clear command, then executor why=bootloader";
    case GK3_BCB_FASTBOOT: return "clear command, then executor why=fastboot";
    case GK3_BCB_WIPE: return "executor why=wipe (BCB cleared by executor after wiping; 3-entry cap)";
    case GK3_BCB_PROMPT_WIPE: return "executor why=prompt_wipe (never auto-cleared)";
    case GK3_BCB_RECOVERY: return "executor recovery menu why=recovery";
    case GK3_BCB_UNKNOWN: return "record in GK3, clear, boot normally";
    }
    return "?";
}

static unsigned g_slot;
static const char *g_event = "none";

static void step_misc(void)
{
    gk3_gpt_part p;
    char hx[80];
    part("misc", &p);
    uint32_t bs = disk.dev.block_size;
    uint64_t pbytes = (p.last_lba - p.first_lba + 1) * bs;
    if (pbytes < GK3_MISC_READ_SIZE)
        fail_open("misc", "misc is only %llu bytes (< 64 KiB)", (unsigned long long)pbytes);
    uint8_t *m = gk3_alloc_pages(GK3_MISC_READ_SIZE);
    if (!m)
        fail_open("misc", "alloc");
    uint64_t t = gk3_ticks();
    if (disk.dev.read(disk.dev.ctx, p.first_lba, GK3_MISC_READ_SIZE / bs, m))
        fail_open("misc", "read misc (p%u, 64 KiB): %s", p.index, gk3_efi_strerror(disk.ctx.last_err));
    gk3_logf("misc: p%u read 64 KiB [%llu.%llu ms]\n", p.index, MSF(gk3_us_since(t)));

    /* BCB */
    gk3_bcb_info bi;
    gk3_bcb_classify(m, &bi);
    gk3_logf("bcb: kind=%s command=\"%s\" args=%u\n", gk3_bcb_kind_name(bi.kind), bi.command, bi.n_args);
    /* GK3 记录与首跑迁移（§4.10） */
    const uint8_t *rec = m + GK3_MISC_GK3_OFF;
    gk3_err re = gk3_rec_validate(rec);
    bool migrated = !re && gk3_rec_migrated(rec);
    gk3_logf("gk3rec: %s%s\n", re ? gk3_strerror(re) : "valid", re ? "" : migrated ? " migrated" : " not-migrated");
    if (!migrated)
        gk3_logf("would (action): first-run migration: %sset marker (NOT done)\n",
                 bi.kind == GK3_BCB_NONE ? "BCB empty, " : "clear BCB without executing it, ");
    else
        gk3_logf("would (action): BCB -> %s (NOT done)\n", bcb_would(bi.kind));

    /* BCAB + virtual_ab → 选槽（§4.3.2）；在副本上算 */
    const uint8_t *bc = m + GK3_MISC_BCAB_OFF;
    gk3_err be = gk3_bcab_validate(bc);
    hex_str(bc, 32, hx, sizeof(hx));
    gk3_logd("bcab_raw: %s\n", hx);
    gk3_logf("bcab: %s", be ? gk3_strerror(be) : "valid");
    if (!be)
        for (unsigned i = 0; i < 2; i++) {
            gk3_slot_info s;
            gk3_bcab_get_slot(bc, i, &s);
            gk3_logf("  _%c=%u/%u%s%s", 'a' + i, s.priority, s.tries, s.successful ? "/ok" : "",
                     gk3_slot_bootable(&s) ? "" : "/unbootable");
        }
    gk3_logf("\n");
    gk3_vab v;
    gk3_vab_parse(m + GK3_MISC_SYSTEM_OFF, &v);
    uint8_t merge = v.valid ? v.merge_status : GK3_MERGE_UNKNOWN;
    gk3_logf("vab: %s merge_status=%u source=_%c\n", v.valid ? "valid" : "invalid", v.merge_status,
             v.source_slot < 2 ? 'a' + v.source_slot : '?');

    uint8_t copy[32];
    gk3_sel s;
    gk3_memcpy(copy, bc, 32);
    gk3_select_slot(copy, opt.hint, merge, &s);
    gk3_logf("decision: %s slot=_%c active=_%c fallback=%u\n", selk[s.kind], 'a' + s.slot, 'a' + s.active, s.fallback);
    if (s.decremented) {
        hex_str(copy, 32, hx, sizeof(hx));
        gk3_logf("would (action): write misc+0x800: _%c tries %u -> %u (NOT written; new bcab %s)\n", 'a' + s.slot,
                 s.tries_before, s.tries_after, hx);
    } else if (s.kind == GK3_SEL_BOOT) {
        gk3_logf("would (action): no misc write (slot already successful)\n");
    }
    gk3_logf("would (action): GK3 boot_streak +1 (NOT written)\n");

    if (opt.force_slot >= 0) {
        g_slot = (unsigned)opt.force_slot;
        g_event = "forced";
        gk3_logf("slot: _%c (forced by gk3.slot; decision above is %s _%c)\n", 'a' + g_slot, selk[s.kind],
                 'a' + s.slot);
    } else {
        switch (s.kind) {
        case GK3_SEL_BOOT:
            g_slot = s.slot;
            g_event = s.fallback ? "fallback" : "none";
            break;
        case GK3_SEL_BCAB_INVALID:
            g_slot = opt.hint;
            g_event = "bcab_invalid";
            break;
        case GK3_SEL_NOSLOT:
        case GK3_SEL_MERGING:
            /* 动作模式会进执行端（why=noslot / merging）；执行端还不存在 → 回到今天的路 */
            fail_open("decision", "%s: action mode would enter the executor (why=%s), which this build does not have",
                      selk[s.kind], selk[s.kind]);
        }
        gk3_logf("slot: _%c (event=%s)\n", 'a' + g_slot, g_event);
    }
    gk3_free_pages(m, GK3_MISC_READ_SIZE);
}

/* ------------------------------------------------------------------ 3. boot_<x>：整份读进来、校验、拆段 */

static struct {
    uint8_t *img;
    size_t img_len;
    gk3_bootimg b;
    uint8_t hdr[4096];
} boot;

static void step_boot(void)
{
    gk3_gpt_part p;
    char name[8] = "boot_a", hx[48], want[48];
    name[5] = (char)('a' + g_slot);
    part(name, &p);
    uint32_t bs = disk.dev.block_size;
    uint64_t pbytes = (p.last_lba - p.first_lba + 1) * bs;
    uint8_t *h = gk3_alloc_pages(4096);
    if (!h)
        fail_open("boot", "alloc");
    if (disk.dev.read(disk.dev.ctx, p.first_lba, 4096 / bs, h))
        fail_open("boot", "read %s header: %s", name, gk3_efi_strerror(disk.ctx.last_err));
    gk3_memcpy(boot.hdr, h, 4096);
    gk3_free_pages(h, 4096);
    gk3_err e = gk3_bootimg_parse(boot.hdr, sizeof(boot.hdr), pbytes, &boot.b);
    if (e)
        fail_open("boot", "%s header: %s (first bytes %02x %02x %02x %02x)", name, gk3_strerror(e), boot.hdr[0],
                  boot.hdr[1], boot.hdr[2], boot.hdr[3]);
    gk3_bootimg *b = &boot.b;
    if (b->version != 2)
        fail_open("boot", "%s: header v%u, this build expects v2 (kernel+ramdisk+dtb in one image, §2.2)", name,
                  b->version);
    if (b->total_size > BOOTIMG_MAX)
        fail_open("boot", "%s: total %llu bytes is implausible", name, (unsigned long long)b->total_size);
    hex_str(b->id, 20, want, sizeof(want));
    gk3_logf("%s: p%u v%u page=%u kernel=%u ramdisk=%u dtb=%u total=%llu id=%s\n", name, p.index, b->version,
             b->page_size, b->kernel_size, b->ramdisk_size, b->dtb_size, (unsigned long long)b->total_size, want);

    boot.img_len = (size_t)((b->total_size + bs - 1) / bs * bs);
    if (!(boot.img = gk3_alloc_pages(boot.img_len)))
        fail_open("boot", "alloc %llu", (unsigned long long)boot.img_len);
    uint64_t t = gk3_ticks();
    if (disk.dev.read(disk.dev.ctx, p.first_lba, (uint32_t)(boot.img_len / bs), boot.img))
        fail_open("boot", "read %s (%llu bytes): %s", name, (unsigned long long)boot.img_len,
                  gk3_efi_strerror(disk.ctx.last_err));
    uint64_t us_r = gk3_us_since(t);
    uint8_t got[20];
    t = gk3_ticks();
    e = gk3_bootimg_verify_id(b, boot.img, boot.img_len, got);
    uint64_t us_s = gk3_us_since(t);
    hex_str(got, 20, hx, sizeof(hx));
    /* §4.3.3：SHA1 不对时动作模式会换另一个可启动的槽（不写 misc）、两个都坏走 H1；最小版本直接 fail-open */
    if (e)
        fail_open("boot", "%s: SHA1(id) MISMATCH: header %s, computed %s", name, want, hx);
    gk3_logf("%s: read %llu.%llu ms, sha1(id) %llu.%llu ms: OK\n", name, MSF(us_r), MSF(us_s));

    const uint8_t *k = boot.img + b->kernel_off, *d = boot.img + b->dtb_off;
    if (k[0] != 'M' || k[1] != 'Z')
        fail_open("boot", "%s: kernel is not a PE image (%02x %02x)", name, k[0], k[1]);
    gk3_logf("%s: kernel %s\n", name, !gk3_memcmp(k + 4, "zimg", 4) ? "EFI zboot PE" : "PE (EFI stub)");
    if (!b->ramdisk_size)
        fail_open("boot", "%s: no ramdisk", name);
    /* FDT 头：magic 0xd00dfeed、totalsize（大端）不超过段长 */
    uint32_t fdt_magic = (uint32_t)d[0] << 24 | (uint32_t)d[1] << 16 | (uint32_t)d[2] << 8 | d[3];
    uint32_t fdt_size = (uint32_t)d[4] << 24 | (uint32_t)d[5] << 16 | (uint32_t)d[6] << 8 | d[7];
    if (b->dtb_size < 40 || fdt_magic != 0xd00dfeedu || fdt_size > b->dtb_size || fdt_size < 40)
        fail_open("boot", "%s: dtb is not a valid FDT (magic %08x size %u / %u)", name, fdt_magic, fdt_size,
                  b->dtb_size);
}

/* ------------------------------------------------------------------ 4. cmdline（§4.3.1） */

static CHAR16 *g_cmdline16;

/* systemd-boot 设的 LoaderBootCountPath（带计数的条目才有，"\loader\entries\x+2-1.conf"）取文件名；
 * 没有就用 LoaderEntrySelected（条目 id，小写，boot.c:1540-1541、:2697）。值不合规就不加。 */
static const char *entry_name(void)
{
    static char out[128];
    static uint8_t buf[512];
    UINTN sz = sizeof(buf) - 2;
    char a[256];
    const char *base;
    gk3_memset(buf, 0, sizeof(buf));
    if (EFI_ERROR(gk3_getvar(u"LoaderBootCountPath", &gk3_guid_loader, NULL, buf, &sz))) {
        sz = sizeof(buf) - 2;
        gk3_memset(buf, 0, sizeof(buf));
        if (EFI_ERROR(gk3_getvar(u"LoaderEntrySelected", &gk3_guid_loader, NULL, buf, &sz)))
            return NULL;
    }
    gk3_ucs2_to_ascii((const CHAR16 *)buf, sz / 2, a, sizeof(a));
    base = a;
    for (const char *q = a; *q; q++)
        if (*q == '\\' || *q == '/')
            base = q + 1;
    size_t n = 0;
    for (; base[n] && n + 1 < sizeof(out); n++) {
        char c = base[n];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' ||
              c == '+' || c == '-'))
            return NULL;
        out[n] = c;
    }
    out[n] = 0;
    return n ? out : NULL;
}

static void step_cmdline(void)
{
    static char base[GK3_BOOT_ARGS_SIZE + GK3_BOOT_EXTRA_ARGS_SIZE + 8], out[4096];
    gk3_android_args a = {g_slot, "gk3boot-" GK3BOOT_VERSION, g_event, entry_name(), "observe"};
    long bn = gk3_bootimg_cmdline(&boot.b, base, sizeof(base));
    if (bn < 0)
        fail_open("cmdline", "boot.img cmdline does not fit");
    gk3_err e = gk3_cmdline_android(base, &a, out, sizeof(out));
    if (e)
        fail_open("cmdline", "gk3_cmdline_android: %s", gk3_strerror(e));
    size_t n = gk3_strlen(out);
    if (!(g_cmdline16 = gk3_alloc((n + 1) * sizeof(CHAR16))))
        fail_open("cmdline", "alloc");
    e = gk3_ascii_to_ucs2(out, (uint16_t *)g_cmdline16, n + 1);
    if (e)
        fail_open("cmdline", "ucs2: %s", gk3_strerror(e));
    gk3_logf("cmdline.base(%ld): %s\n", bn, base);
    gk3_logf("cmdline(%llu): %s\n", (unsigned long long)n, out);
}

/* ------------------------------------------------------------------ main */

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    gk3efi_init(image, st);
    T0 = gk3_ticks();
    gk3_log_init(LOG_CAP);
    gk3_screenf("\n");          /* systemd-boot 可能把光标留在行中间；只上屏幕 */
    step_header();
    step_open_log();
    step_disk();
    step_misc();
    step_boot();
    step_cmdline();

    gk3_bootimg *b = &boot.b;
    gk3_linux L = {
        .kernel = boot.img + b->kernel_off,
        .kernel_len = b->kernel_size,
        .initrd = boot.img + b->ramdisk_off,
        .initrd_len = b->ramdisk_size,
        .dtb = boot.img + b->dtb_off,
        .dtb_len = b->dtb_size,
        .cmdline = g_cmdline16,
    };
    const char *stage = "?";
    gk3_logf("gk3boot: booting boot_%c via H2 (t=%llu ms)\n", 'a' + g_slot, MS());
    EFI_STATUS r = gk3_linux_boot(&L, pre_start, &stage);
    /* 只有失败才回到这里 */
    fail_open("handoff", "%s: %s", stage, gk3_efi_strerror(r));
    return EFI_SUCCESS;     /* 不可达 */
}

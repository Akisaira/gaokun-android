/* gk3-misc：libgk3core 的只读 CLI（设计稿 §4.1；安装器用的 init 子命令是 S10 的事，这里还没有）。
 *
 *   gk3-misc dump    <misc 镜像（≥64 KiB，dd if=/dev/block/by-name/misc bs=4096 count=16）>
 *   gk3-misc select  <misc 镜像> [hint a|b]     入口在这份 misc 上会怎么选（只算，不写）
 *   gk3-misc gpt     <盘头镜像（LBA 0–33）> [块大小]
 *   gk3-misc bootimg <boot.img>                 解析头、复算 SHA1(id)、打印 cmdline
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gk3core.h"

static unsigned char *slurp(const char *p, size_t *n)
{
    FILE *f = fopen(p, "rb");
    unsigned char *b;
    long l;
    if (!f) {
        perror(p);
        exit(2);
    }
    fseek(f, 0, SEEK_END);
    l = ftell(f);
    fseek(f, 0, SEEK_SET);
    b = malloc(l ? (size_t)l : 1);
    if (fread(b, 1, (size_t)l, f) != (size_t)l) {
        perror(p);
        exit(2);
    }
    fclose(f);
    *n = (size_t)l;
    return b;
}

static void printable(const char *label, const unsigned char *p, size_t n)
{
    printf("%s\"", label);
    for (size_t i = 0; i < n && p[i]; i++)
        if (p[i] == '\n')
            printf("\\n");
        else if (p[i] >= 0x20 && p[i] < 0x7f)
            putchar(p[i]);
        else
            printf("\\x%02x", p[i]);
    printf("\"\n");
}

static int dump(const unsigned char *m, size_t n)
{
    gk3_bcb_info bi;
    gk3_vab v;
    gk3_err e;
    if (n < GK3_MISC_READ_SIZE) {
        fprintf(stderr, "misc 镜像不足 64 KiB\n");
        return 2;
    }
    gk3_bcb_classify(m, &bi);
    printf("BCB      kind=%s%s\n", gk3_bcb_kind_name(bi.kind), gk3_is_zero(m, 2048) ? "（2 KiB 全零）" : "");
    printable("         command=", m, 32);
    printable("         recovery=", m + 64, 768);

    e = gk3_bcab_validate(m + 2048);
    printf("BCAB     %s  suffix=", e ? gk3_strerror(e) : "有效");
    printable("", m + 2048, 4);
    printf("         nb_slot=%u recovery_tries=%u merge_status=%u crc(盘上字节)=%02x %02x %02x %02x\n",
           gk3_bcab_nb_slot(m + 2048), gk3_bcab_recovery_tries(m + 2048), gk3_bcab_merge_status(m + 2048),
           m[2076], m[2077], m[2078], m[2079]);
    for (unsigned i = 0; i < 2; i++) {
        gk3_slot_info s;
        gk3_bcab_get_slot(m + 2048, i, &s);
        printf("         _%c priority=%u tries=%u successful=%u verity_corrupted=%u → %s\n", 'a' + i, s.priority,
               s.tries, s.successful, s.verity_corrupted, gk3_slot_bootable(&s) ? "可启动" : "不可启动");
    }

    e = gk3_rec_validate(m + GK3_MISC_GK3_OFF);
    if (e) {
        printf("GK3      无记录（%s）%s\n", gk3_strerror(e),
               gk3_is_zero(m + GK3_MISC_GK3_OFF, GK3_REC_SIZE) ? "，8 KiB 处 2 KiB 全零" : "，⚠️ 8 KiB 处有非零内容");
    } else {
        const unsigned char *r = m + GK3_MISC_GK3_OFF;
        gk3_event ev[GK3_EV_N];
        uint32_t k = gk3_rec_events(r, ev, GK3_EV_N);
        uint8_t ns;
        gk3_next_kind nk = gk3_rec_next(r, &ns);
        char cmd[33];
        gk3_rec_migrated_command(r, cmd);
        printf("GK3      有效  migrated=%u boot_streak=%u next=%u/%u dispatch_count=%u migrated_command=\"%s\"\n",
               gk3_rec_migrated(r), gk3_rec_boot_streak(r), nk, ns, gk3_rec_dispatch_count(r), cmd);
        for (uint32_t i = 0; i < k && i < GK3_EV_N; i++)
            printf("         #%u %s slot=%u aux=%u%s\n", ev[i].seq, gk3_ev_name((gk3_ev_code)ev[i].code), ev[i].slot,
                   ev[i].aux, ev[i].flags & GK3_EVF_NOTIFIED ? "（已通知）" : "");
    }

    gk3_vab_parse(m + GK3_MISC_SYSTEM_OFF, &v);
    printf("VAB      %s version=%u magic=%08x merge_status=%u source_slot=%u\n", v.valid ? "有效" : "无效",
           v.version, v.magic, v.merge_status, v.source_slot);
    printf("其他     2K+32..32K %s\n", gk3_is_zero(m + 2080, 32768 - 2080) ? "全零" : "有非零内容");
    return 0;
}

static int sel(unsigned char *m, unsigned hint)
{
    gk3_sel s;
    gk3_vab v;
    uint8_t bc[32];
    static const char *k[] = {"boot", "bcab_invalid", "noslot", "merging"};
    gk3_vab_parse(m + GK3_MISC_SYSTEM_OFF, &v);
    memcpy(bc, m + 2048, 32);
    gk3_select_slot(bc, hint, v.valid ? v.merge_status : GK3_MERGE_UNKNOWN, &s);
    printf("决定 %s：slot=_%c active=_%c fallback=%u 扣 tries=%u（%u→%u）%s%s\n", k[s.kind], 'a' + s.slot,
           'a' + s.active, s.fallback, s.decremented, s.tries_before, s.tries_after,
           s.kind == GK3_SEL_BCAB_INVALID ? " bcab=" : "", s.kind == GK3_SEL_BCAB_INVALID ? gk3_strerror(s.bcab_err) : "");
    if (s.decremented)
        printf("（入口会把 BCAB 写回 misc+2048，这里没写）\n");
    return 0;
}

static int gpt(const unsigned char *d, size_t n, unsigned bs)
{
    gk3_gpt g;
    gk3_gpt_part p;
    gk3_err e;
    char gs[37];
    static const char *const six[] = {"misc", "boot_a", "boot_b", "super", "userdata", "metadata"};
    const char *bad = NULL;
    if (n < 2 * bs) {
        fprintf(stderr, "太短\n");
        return 2;
    }
    e = gk3_gpt_parse_header(d + bs, bs, &g);
    if (!e && g.entries_lba * bs + (size_t)g.num_entries * g.entry_size > n)
        e = GK3_ENOSPC;
    if (!e)
        e = gk3_gpt_parse_mem(d + bs, bs, d + g.entries_lba * bs, n - g.entries_lba * bs, &g);
    if (e) {
        printf("GPT 无效：%s\n", gk3_strerror(e));
        return 1;
    }
    gk3_guid_str(g.disk_guid, gs);
    printf("GPT  disk=%s  表项 %u×%u @LBA %llu  usable %llu–%llu  已用 %u\n", gs, g.num_entries, g.entry_size,
           (unsigned long long)g.entries_lba, (unsigned long long)g.first_usable, (unsigned long long)g.last_usable,
           gk3_gpt_count(&g));
    for (uint32_t i = 0; i < g.num_entries; i++) {
        if (gk3_gpt_get(&g, i, &p))
            continue;
        gk3_guid_str(p.part_guid, gs);
        printf("  p%-3u %-14s %12llu %12llu  attrs=%016llx  %s\n", p.index, p.name, (unsigned long long)p.first_lba,
               (unsigned long long)p.last_lba, (unsigned long long)p.attrs, gs);
    }
    e = gk3_gpt_require_unique(&g, six, 6, &bad);
    printf("六个名字各恰好一次：%s%s%s\n", e ? gk3_strerror(e) : "是", e ? " —— " : "", e ? bad : "");
    return e ? 1 : 0;
}

static int bootimg(const unsigned char *d, size_t n)
{
    gk3_bootimg b;
    uint8_t got[20];
    char cmd[2048];
    gk3_err e = gk3_bootimg_parse(d, n, 0, &b);
    if (e) {
        printf("boot.img 无效：%s\n", gk3_strerror(e));
        return 1;
    }
    printf("boot.img v%u page=%u kernel=%u ramdisk=%u second=%u recovery_dtbo=%u dtb=%u total=%llu\n", b.version,
           b.page_size, b.kernel_size, b.ramdisk_size, b.second_size, b.recovery_dtbo_size, b.dtb_size,
           (unsigned long long)b.total_size);
    e = gk3_bootimg_verify_id(&b, d, n, got);
    printf("id ");
    for (int i = 0; i < 20; i++)
        printf("%02x", b.id[i]);
    printf("  复算 %s\n", e == GK3_OK ? "一致" : gk3_strerror(e));
    if (gk3_bootimg_cmdline(&b, cmd, sizeof(cmd)) >= 0)
        printf("cmdline \"%s\"\n", cmd);
    return e ? 1 : 0;
}

int main(int argc, char **argv)
{
    size_t n;
    unsigned char *d;
    if (argc < 3) {
        fprintf(stderr, "用法：gk3-misc dump|select|gpt|bootimg <文件> [参数]\n");
        return 2;
    }
    d = slurp(argv[2], &n);
    if (!strcmp(argv[1], "dump"))
        return dump(d, n);
    if (!strcmp(argv[1], "select"))
        return n < GK3_MISC_READ_SIZE ? 2 : sel(d, argc > 3 && argv[3][0] == 'b');
    if (!strcmp(argv[1], "gpt"))
        return gpt(d, n, argc > 3 ? (unsigned)atoi(argv[3]) : 512);
    if (!strcmp(argv[1], "bootimg"))
        return bootimg(d, n);
    fprintf(stderr, "不认识的子命令 %s\n", argv[1]);
    return 2;
}

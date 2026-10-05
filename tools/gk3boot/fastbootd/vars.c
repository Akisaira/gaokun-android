/* gk3-fastbootd：getvar（fastboot-design §4.5 + boot-entry-design §4.4.2）。
 *
 * 名字与取值格式对齐设备端上游 fastboot/device/variables.cpp / commands.cpp:113-200：
 *   未知变量 → FAIL "Unknown variable"；getvar all → 每个变量一条 INFO "<名>:<值>"（带参数的变量逐个参数
 *   "<名>:<参数>:<值>"），取不到的那个就跳过，最后 OKAY。数值一律 0x 开头的十六进制（GetPartitionSize / GetMaxDownloadSize）。
 * 我们自己的变量以 gk3- 开头。
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fbd.h"

typedef int (*getter)(const char *arg, char *out, size_t n);   /* 0 = 有值；否则 out 是 FAIL 的原因 */

static int v_version(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "0.4"); return 0; }
static int v_bootloader(const char *a, char *o, size_t n)
{
    (void)a;
    snprintf(o, n, "%s", G.bootver[0] ? G.bootver : "gk3boot-unknown");
    return 0;
}
static int v_product(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "gaokun3"); return 0; }
static int v_serial(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "%s", G.serial); return 0; }
static int v_secure(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "no"); return 0; }
static int v_unlocked(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "yes"); return 0; }
static int v_userspace(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "yes"); return 0; }   /* U4：用户已定 */
static int v_maxdl(const char *a, char *o, size_t n)
{
    (void)a;
    snprintf(o, n, "0x%llX", (unsigned long long)G.max_download);
    return 0;
}
static int v_slotcount(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "2"); return 0; }
static int v_curslot(const char *a, char *o, size_t n)
{
    (void)a;
    if (G.cur_slot < 0) {
        snprintf(o, n, "current slot unknown");
        return -1;
    }
    snprintf(o, n, "%c", 'a' + G.cur_slot);
    return 0;
}
static int v_superpart(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "super"); return 0; }
static int v_snapstatus(const char *a, char *o, size_t n)
{
    (void)a;
    if (!G.disk.ok) {
        snprintf(o, n, "%s", G.disk.err);
        return -1;
    }
    snprintf(o, n, "%s", fb_merge_name(fb_vab_status()));
    return 0;
}

static int slot_arg(const char *a, char *o, size_t n, gk3_slot_info *si)
{
    uint8_t bc[32];
    gk3_err e;
    unsigned s;
    if (a[0] == '_')
        a++;
    if ((a[0] != 'a' && a[0] != 'b') || a[1]) {
        snprintf(o, n, "Invalid slot");
        return -1;
    }
    s = (unsigned)(a[0] - 'a');
    e = fb_bcab_read(bc);
    if (e) {
        snprintf(o, n, "bootloader_control unreadable (%s)", gk3_strerror(e));
        return -1;
    }
    gk3_bcab_get_slot(bc, s, si);
    return 0;
}
static int v_slot_ok(const char *a, char *o, size_t n)
{
    gk3_slot_info si;
    if (slot_arg(a, o, n, &si))
        return -1;
    snprintf(o, n, "%s", si.successful ? "yes" : "no");
    return 0;
}
static int v_slot_unbootable(const char *a, char *o, size_t n)
{
    gk3_slot_info si;
    if (slot_arg(a, o, n, &si))
        return -1;
    snprintf(o, n, "%s", gk3_slot_bootable(&si) ? "no" : "yes");
    return 0;
}
static int v_slot_retry(const char *a, char *o, size_t n)
{
    gk3_slot_info si;
    if (slot_arg(a, o, n, &si))
        return -1;
    snprintf(o, n, "%u", si.tries);
    return 0;
}

static int part_arg(const char *a, char *o, size_t n)
{
    int pi = fb_part_lookup(a, G.cur_slot);
    if (pi < 0)
        snprintf(o, n, "Could not find partition");
    else if (!G.disk.ok) {
        snprintf(o, n, "%s", G.disk.err);
        pi = -1;
    }
    return pi;
}
static int v_psize(const char *a, char *o, size_t n)
{
    int pi = part_arg(a, o, n);
    if (pi < 0)
        return -1;
    snprintf(o, n, "0x%llX", (unsigned long long)G.disk.p[pi].size);
    return 0;
}
static int v_ptype(const char *a, char *o, size_t n)
{
    /* 一律 raw：擦在设备端做、建文件系统交给 Android 的 fs_mgr（fastboot-design §4.6.5） */
    if (part_arg(a, o, n) < 0)
        return -1;
    snprintf(o, n, "raw");
    return 0;
}
static int v_logical(const char *a, char *o, size_t n)
{
    if (part_arg(a, o, n) < 0)
        return -1;
    snprintf(o, n, "no");
    return 0;
}
static int v_hasslot(const char *a, char *o, size_t n)
{
    if (!strcmp(a, "boot")) {
        snprintf(o, n, "yes");
        return 0;
    }
    if (!strcmp(a, "super") || !strcmp(a, "userdata") || !strcmp(a, "metadata") || !strcmp(a, "boot_a") ||
        !strcmp(a, "boot_b")) {
        snprintf(o, n, "no");
        return 0;
    }
    snprintf(o, n, "Could not find partition");
    return -1;
}

/* EC 的 power_supply：type = Battery 的第一个（读不到就 FAIL，不影响刷机） */
static int battery(const char *attr, char *o, size_t n)
{
    DIR *d = opendir("/sys/class/power_supply");
    struct dirent *e;
    int rc = -1;
    snprintf(o, n, "no battery information");
    if (!d)
        return -1;
    while ((e = readdir(d))) {
        char p[512], v[64] = "";
        FILE *f;
        if (e->d_name[0] == '.')
            continue;
        snprintf(p, sizeof(p), "/sys/class/power_supply/%s/type", e->d_name);
        if (!(f = fopen(p, "r")))
            continue;
        if (!fgets(v, sizeof(v), f))
            v[0] = 0;
        fclose(f);
        if (strncmp(v, "Battery", 7))
            continue;
        snprintf(p, sizeof(p), "/sys/class/power_supply/%s/%s", e->d_name, attr);
        if (!(f = fopen(p, "r")))
            continue;
        if (fgets(v, sizeof(v), f)) {
            v[strcspn(v, "\n")] = 0;
            snprintf(o, n, "%s", v);
            rc = 0;
        }
        fclose(f);
        if (!rc)
            break;
    }
    closedir(d);
    return rc;
}
static int v_bat_mv(const char *a, char *o, size_t n)
{
    (void)a;
    if (battery("voltage_now", o, n))
        return -1;
    snprintf(o, n, "%ld", strtol(o, NULL, 10) / 1000);   /* µV → mV（上游 GetBatteryVoltage 报 mV） */
    return 0;
}
static int v_bat_soc(const char *a, char *o, size_t n) { (void)a; return battery("capacity", o, n); }
static int v_bat_ok(const char *a, char *o, size_t n)
{
    char st[64];
    long cap;
    (void)a;
    if (battery("capacity", o, n))
        return -1;
    cap = strtol(o, NULL, 10);
    if (battery("status", st, sizeof(st)))
        st[0] = 0;
    snprintf(o, n, "%s", cap >= 20 || !strcmp(st, "Charging") || !strcmp(st, "Full") ? "yes" : "no");
    return 0;
}

static int v_fbver(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "%s", GK3FB_VERSION); return 0; }
static int v_why(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "%s", G.why[0] ? G.why : "none"); return 0; }
static int v_disk(const char *a, char *o, size_t n)
{
    (void)a;
    if (!G.disk.ok) {
        snprintf(o, n, "%s", G.disk.err);
        return -1;
    }
    snprintf(o, n, "%s", G.disk.path);
    return 0;
}
static int v_diskok(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "%s", G.disk.ok ? "yes" : "no"); return 0; }
static int v_diskerr(const char *a, char *o, size_t n)
{
    (void)a;
    snprintf(o, n, "%s", G.disk.ok ? "none" : G.disk.err);
    return 0;
}
static int v_entry(const char *a, char *o, size_t n) { (void)a; snprintf(o, n, "%s", G.entry_note); return 0; }
static int v_espdef(const char *a, char *o, size_t n)
{
    fb_esp esp;
    char err[256];
    (void)a;
    if (fb_esp_open(&esp, &G.disk, &G.eopt, err, sizeof(err))) {
        snprintf(o, n, "%s", err);
        return -1;
    }
    if (fb_esp_get_default(&esp, o, n)) {
        snprintf(o, n, "loader.conf has no default line");
        fb_esp_close(&esp);
        return -1;
    }
    fb_esp_close(&esp);
    return 0;
}

typedef struct {
    const char *name;
    getter get;
    const char *const *all_args;    /* getvar all 时逐个参数列出；NULL = 不带参数 */
} var;

static const char *const PART_ARGS[] = {"boot_a", "boot_b", "super", "userdata", "metadata", NULL};
static const char *const SLOTLESS_ARGS[] = {"boot", "super", "userdata", "metadata", NULL};
static const char *const SLOT_ARGS[] = {"a", "b", NULL};

static const var VARS[] = {
    {"version", v_version, NULL},
    {"version-bootloader", v_bootloader, NULL},
    {"product", v_product, NULL},
    {"serialno", v_serial, NULL},
    {"secure", v_secure, NULL},
    {"unlocked", v_unlocked, NULL},
    {"is-userspace", v_userspace, NULL},
    {"max-download-size", v_maxdl, NULL},
    {"slot-count", v_slotcount, NULL},
    {"current-slot", v_curslot, NULL},
    {"has-slot", v_hasslot, SLOTLESS_ARGS},
    {"slot-successful", v_slot_ok, SLOT_ARGS},
    {"slot-unbootable", v_slot_unbootable, SLOT_ARGS},
    {"slot-retry-count", v_slot_retry, SLOT_ARGS},
    {"partition-size", v_psize, PART_ARGS},
    {"partition-type", v_ptype, PART_ARGS},
    {"is-logical", v_logical, PART_ARGS},
    {"super-partition-name", v_superpart, NULL},
    {"snapshot-update-status", v_snapstatus, NULL},
    {"battery-voltage", v_bat_mv, NULL},
    {"battery-soc", v_bat_soc, NULL},
    {"battery-soc-ok", v_bat_ok, NULL},
    {"gk3-fastbootd-version", v_fbver, NULL},
    {"gk3-why", v_why, NULL},
    {"gk3-disk", v_disk, NULL},
    {"gk3-disk-ok", v_diskok, NULL},
    {"gk3-disk-error", v_diskerr, NULL},
    {"gk3-entry", v_entry, NULL},
    {"gk3-esp-default", v_espdef, NULL},
};

void fb_cmd_getvar(fb_ctx *c, const char *arg)
{
    char out[FB_MSG_MAX + 1];
    if (!arg[0]) {
        fb_fail(c, "Missing argument");
        return;
    }
    if (!strcmp(arg, "all")) {
        for (size_t i = 0; i < sizeof(VARS) / sizeof(VARS[0]); i++) {
            if (!VARS[i].all_args) {
                if (VARS[i].get("", out, sizeof(out)) == 0)
                    fb_info(c, "%s:%s", VARS[i].name, out);
                continue;
            }
            for (const char *const *a = VARS[i].all_args; *a; a++)
                if (VARS[i].get(*a, out, sizeof(out)) == 0)
                    fb_info(c, "%s:%s:%s", VARS[i].name, *a, out);
        }
        fb_okay(c, "%s", "");
        return;
    }
    for (size_t i = 0; i < sizeof(VARS) / sizeof(VARS[0]); i++) {
        size_t nl = strlen(VARS[i].name);
        const char *a;
        if (strncmp(arg, VARS[i].name, nl))
            continue;
        if (arg[nl] == 0)
            a = "";
        else if (arg[nl] == ':')
            a = arg + nl + 1;
        else
            continue;
        if ((VARS[i].all_args != NULL) != (a[0] != 0)) {
            fb_fail(c, VARS[i].all_args ? "Missing argument" : "Unknown variable");
            return;
        }
        if (VARS[i].get(a, out, sizeof(out)))
            fb_fail(c, "%s", out);
        else
            fb_okay(c, "%s", out);
        return;
    }
    fb_fail(c, "Unknown variable");
}

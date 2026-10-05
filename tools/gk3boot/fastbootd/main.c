/* gk3-fastbootd：入口。
 *
 *   gk3-fastbootd [选项]
 *     --usb               起 USB 传输：建 configfs gadget g1（18D1:4EE0）+ functionfs + 绑 UDC（缺省开）
 *     --no-usb            不起 USB
 *     --usb-nosetup       gadget 与 functionfs 已由 /init 建好（/dev/usb-ffs/fastboot），只写描述符
 *     --udc=<名字>        缺省 a600000.usb（boot-entry-design §4.4.1：只用 port0）
 *     --tcp[=<端口>]      起 TCP 传输（缺省 5554）。不给时看 cmdline 的 gk3.fbtcp=1；发布默认关
 *     --cmdline=<文件>    代替 /proc/cmdline（测试）
 *     --disk=<路径>       直接指定目标盘（整盘节点或镜像文件；测试 / 开发）。仍要过六个名字的唯一性检查
 *     --disks=<a,b,…>     扫描时只看这些盘（测试隔离：容器里还有别的 loop 盘）
 *     --esp-dir=<目录>    把一个已有目录当 ESP 根（不挂载；只给没有 loop 设备的主机测试用）
 *     --rundir=<目录>     私有目录（mknod 的节点、ESP 挂载点），缺省 /run/gk3-fastbootd
 *     --max-download=<字节> 缺省 0x20000000（512 MiB，fastboot-design §4.5）
 *     --test-reboot=<文件> 重启类命令只把意图（reboot / bootloader / fastboot / recovery / poweroff）追加进文件、不真重启
 *     --log=<文件>        日志另写一份文件；--kmsg 写 /dev/kmsg
 *     --no-entry          不处理进入时的 BCB（测试）
 *     --version
 *   读的 cmdline 键（boot-entry-design §4.4.1，由 gk3boot 拼）：
 *     gk3.why=<…>  gk3.slot=<a|b|0|1>  gk3.bootver=<…>  gk3.disk=<misc 的 PARTUUID>
 *     gk3.esp=<ESP 的 PARTUUID>（S7c 新增，可选）  gk3.fbtcp=1（打开 TCP）  gk3.serialno=<…>（可选，缺省 gaokun3）
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "fbd.h"

static char *cmdline_get(const char *cl, const char *key, char *out, size_t n)
{
    size_t kl = strlen(key);
    const char *p = cl;
    out[0] = 0;
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == '\n')
            p++;
        if (!strncmp(p, key, kl) && p[kl] == '=') {
            const char *v = p + kl + 1;
            size_t vl = strcspn(v, " \t\n");
            snprintf(out, n, "%.*s", (int)(vl < n ? vl : n - 1), v);
            /* 同名键取最后一个（与内核 / init 的语义一致） */
        }
        p += strcspn(p, " \t\n");
    }
    return out[0] ? out : NULL;
}

static bool safe_val(const char *s)
{
    for (; *s; s++)
        if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9') || strchr("._+-:,=/", *s)))
            return false;
    return true;
}

static void *serve_thread(void *arg)
{
    fb_transport *t = arg;
    for (;;) {
        int r;
        if (t->open_session(t))
            continue;
        fb_log("%s: host connected", t->name);
        r = fb_serve(t);
        t->close_session(t);
        fb_log("%s: session closed", t->name);
        if (r == 1)
            fb_do_reboot(fb_pending_reboot);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    bool usb = true, usb_setup = true, tcp = false, kmsg = false, entry = true;
    int tcp_port = 5554;
    const char *udc = "a600000.usb", *cmdline_file = "/proc/cmdline", *logfile = NULL;
    static char cl[8192], v[256], disk_uuid[64], esp_uuid[64];
    pthread_t th[2];
    int nth = 0;

    memset(&G, 0, sizeof(G));
    G.max_download = 0x20000000;
    G.slot_hint = -1;
    G.cur_slot = -1;
    G.dopt.rundir = G.eopt.rundir = "/run/gk3-fastbootd";
    snprintf(G.serial, sizeof(G.serial), "gaokun3");

    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
#define OPT(n) (!strncmp(a, n "=", sizeof(n)) ? a + sizeof(n) : NULL)
        const char *x;
        if (!strcmp(a, "--version")) {
            printf("gk3-fastbootd %s\n", GK3FB_VERSION);
            return 0;
        } else if (!strcmp(a, "--usb"))
            usb = true;
        else if (!strcmp(a, "--no-usb"))
            usb = false;
        else if (!strcmp(a, "--usb-nosetup"))
            usb_setup = false;
        else if ((x = OPT("--udc")))
            udc = x;
        else if (!strcmp(a, "--tcp"))
            tcp = true;
        else if ((x = OPT("--tcp"))) {
            tcp = true;
            tcp_port = atoi(x);
        } else if ((x = OPT("--cmdline")))
            cmdline_file = x;
        else if ((x = OPT("--disk")))
            G.dopt.disk_override = x;
        else if ((x = OPT("--disks")))
            G.dopt.disks_filter = x;
        else if ((x = OPT("--esp-dir")))
            G.eopt.esp_dir_override = x;
        else if ((x = OPT("--rundir")))
            G.dopt.rundir = G.eopt.rundir = x;
        else if ((x = OPT("--max-download")))
            G.max_download = strtoull(x, NULL, 0);
        else if ((x = OPT("--test-reboot")))
            G.test_reboot = x;
        else if ((x = OPT("--log")))
            logfile = x;
        else if (!strcmp(a, "--kmsg"))
            kmsg = true;
        else if (!strcmp(a, "--no-entry"))
            entry = false;
        else {
            fprintf(stderr, "gk3-fastbootd: unknown option %s\n", a);
            return 2;
        }
#undef OPT
    }
    if (G.max_download < 4096 || G.max_download > 0xFFFFFFFFull) {
        fprintf(stderr, "gk3-fastbootd: --max-download out of range\n");
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    fb_log_init(kmsg, logfile);

    {
        int fd = open(cmdline_file, O_RDONLY | O_CLOEXEC);
        ssize_t n = fd >= 0 ? read(fd, cl, sizeof(cl) - 1) : -1;
        if (fd >= 0)
            close(fd);
        cl[n > 0 ? n : 0] = 0;
    }
    if (cmdline_get(cl, "gk3.why", v, sizeof(v)) && safe_val(v))
        snprintf(G.why, sizeof(G.why), "%s", v);
    if (cmdline_get(cl, "gk3.slot", v, sizeof(v))) {
        if (!strcmp(v, "a") || !strcmp(v, "0") || !strcmp(v, "_a"))
            G.slot_hint = 0;
        else if (!strcmp(v, "b") || !strcmp(v, "1") || !strcmp(v, "_b"))
            G.slot_hint = 1;
    }
    if (cmdline_get(cl, "gk3.bootver", v, sizeof(v)) && safe_val(v))
        snprintf(G.bootver, sizeof(G.bootver), "%s", v);
    if (cmdline_get(cl, "gk3.serialno", v, sizeof(v)) && safe_val(v) && v[0])
        snprintf(G.serial, sizeof(G.serial), "%s", v);
    if (cmdline_get(cl, "gk3.disk", disk_uuid, sizeof(disk_uuid)))
        G.dopt.want_misc_uuid = disk_uuid;
    if (cmdline_get(cl, "gk3.esp", esp_uuid, sizeof(esp_uuid)))
        G.eopt.want_esp_uuid = esp_uuid;
    if (cmdline_get(cl, "gk3.fbtcp", v, sizeof(v)) && !strcmp(v, "1"))
        tcp = true;

    fb_log("gk3-fastbootd %s starting: why=%s slot=%d bootver=%s disk=%s esp=%s usb=%d tcp=%d", GK3FB_VERSION,
           G.why[0] ? G.why : "-", G.slot_hint, G.bootver[0] ? G.bootver : "-", disk_uuid[0] ? disk_uuid : "(scan)",
           esp_uuid[0] ? esp_uuid : "(probe)", usb, tcp);

    /* 不挂起（fastboot-design §4.7）：initramfs 里本来没人写 /sys/power/state，这里再拿一把 wakelock 作保险 */
    {
        int fd = open("/sys/power/wake_lock", O_WRONLY | O_CLOEXEC);
        if (fd >= 0) {
            if (write(fd, "gk3fastboot", 11) != 11)
                fb_log("wake_lock: %s", strerror(errno));
            close(fd);
        }
    }

    fb_disk_open(&G.disk, &G.dopt);
    if (!G.disk.ok)
        fb_log("NO TARGET DISK — every write will be refused: %s", G.disk.err);

    /* current-slot：gk3.slot；没给就取 BCAB 里 priority 最高的槽（同分 _a），都没有就 _a */
    if (G.slot_hint >= 0) {
        G.cur_slot = G.slot_hint;
    } else {
        uint8_t bc[32];
        G.cur_slot = 0;
        if (fb_bcab_read(bc) == GK3_OK) {
            gk3_slot_info a, b;
            gk3_bcab_get_slot(bc, 0, &a);
            gk3_bcab_get_slot(bc, 1, &b);
            G.cur_slot = b.priority > a.priority;
        }
    }
    if (entry)
        fb_entry();

    if (usb) {
        fb_transport *t = fb_usb_new(udc, usb_setup);
        if (t)
            pthread_create(&th[nth++], NULL, serve_thread, t);
        else
            fb_log("USB transport unavailable");
    }
    if (tcp) {
        fb_transport *t = fb_tcp_new(tcp_port);
        if (t)
            pthread_create(&th[nth++], NULL, serve_thread, t);
        else
            fb_log("TCP transport unavailable");
    }
    if (!nth) {
        fb_log("no transport could be started — exiting");
        return 1;
    }
    fb_log("ready");
    for (int i = 0; i < nth; i++)
        pthread_join(th[i], NULL);
    return 0;
}

/* gk3-fastbootd：入口。
 *
 * 在执行端 initramfs 里由 /init（PID 1，管生命周期与界面）这样调（README §13.3，唯一的约定写法）：
 *   常驻：   gk3-fastbootd --usb-nosetup               gadget / UDC / role 归 /init；本进程只往 $GK3_FFS/ep0 写描述符
 *   子命令： gk3-fastbootd --wipe-data [--confirm]     恢复出厂（/init 先停掉常驻实例：同一块盘只有一个写者）
 *            gk3-fastbootd --clear-bcb                 只清 BCB
 * 参数之外的输入：/init 导出的环境变量 GK3_WHY GK3_SLOT GK3_DISK GK3_BOOTVER GK3_FFS GK3_UDC GK3_RUN
 * （前四个 = cmdline 里的同名值；GK3_RUN 决定状态文件 $GK3_RUN/fastbootd.status），其余键自己读 /proc/cmdline。
 * 优先级：命令行选项 > 环境变量 > /proc/cmdline。
 * 常驻模式不调 reboot(2)：重启 / 关机 / 原地重起 / 切菜单都用退出码交给 /init（fbd.h 的 FB_EXIT_*）。
 * SIGTERM / SIGINT：等手上那条命令做完（拿命令锁）再以 128+信号 退出，不在写盘中途停下（/init 3 秒后才 SIGKILL）。
 *
 *   gk3-fastbootd [选项]
 *     --wipe-data [--confirm]  子命令：恢复出厂（boot-entry-design §4.4.3）。不带 --confirm 时自己判"免二次确认"
 *     --clear-bcb         子命令：只清 BCB（0–2 KiB），写后读回
 *     --usb               起 USB 传输（缺省开）；不带 --usb-nosetup 时本进程自己建 configfs gadget g1 + 绑 UDC（开发用）
 *     --no-usb            不起 USB
 *     --usb-nosetup       gadget 与 functionfs 已由 /init 建好：只写描述符，不碰 UDC、不碰 role
 *     --ffs=<目录>        FunctionFS 挂载点（缺省 $GK3_FFS，再缺省 /dev/usb-ffs/fastboot）
 *     --udc=<名字>        缺省 $GK3_UDC，再缺省 a600000.usb（boot-entry-design §4.4.1：只用 port0；只在自己建 gadget 时用）
 *     --tcp[=<端口>]      起 TCP 传输（缺省 5554）。不给时看 cmdline 的 gk3.fbtcp=1；发布默认关
 *     --cmdline=<文件>    代替 /proc/cmdline（测试）
 *     --disk=<路径>       直接指定目标盘（整盘节点或镜像文件；测试 / 开发）。仍要过六个名字的唯一性检查
 *     --disks=<a,b,…>     扫描时只看这些盘（测试隔离：容器里还有别的 loop 盘）
 *     --esp-dir=<目录>    把一个已有目录当 ESP 根（不挂载；只给没有 loop 设备的主机测试用）
 *     --rundir=<目录>     私有目录（mknod 的节点、ESP 挂载点），缺省 /run/gk3-fastbootd
 *     --status=<文件>     状态文件（缺省 $GK3_RUN/fastbootd.status；都没有就不写）
 *     --max-download=<字节> 缺省 0x20000000（512 MiB，fastboot-design §4.5）
 *     --test-reboot=<文件> 重启类命令只把意图（reboot / bootloader / fastboot / recovery / poweroff / restart / menu）
 *                         追加进文件、不退出（离线测试）
 *     --log=<文件>        日志另写一份文件；--kmsg 写 /dev/kmsg
 *     --no-entry          不处理进入时的 BCB（测试）
 *     --version
 *   读的 cmdline 键（boot-entry-design §4.4.1，由 gk3boot 的 gk3_cmdline_fastboot 拼）：
 *     gk3.why=<…>  gk3.slot=<a|b|0|1>  gk3.bootver=<…>  gk3.disk=<misc 的 PARTUUID>  gk3.esp=<ESP 的 PARTUUID>
 *     gk3.dispatch=1（拉起本执行端的 gk3boot 开着 BCB 分派 ⇒ 重启类命令写 BCB + 冷重启；否则原地）
 *     gk3.fbtcp=1（打开 TCP）  gk3.serialno=<…>（可选，缺省 gaokun3）
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

/* 环境变量：没设、空串、含不合规字符 ⇒ 当作没给 */
static const char *env(const char *k)
{
    const char *v = getenv(k);
    return v && v[0] && safe_val(v) ? v : NULL;
}

static int parse_slot(const char *v)
{
    if (!strcmp(v, "a") || !strcmp(v, "0") || !strcmp(v, "_a"))
        return 0;
    if (!strcmp(v, "b") || !strcmp(v, "1") || !strcmp(v, "_b"))
        return 1;
    return -1;
}

/* SIGTERM / SIGINT：拿到命令锁（= 手上的命令做完）再退出。信号在所有线程里都屏蔽，只由这个线程 sigwait。 */
static void *signal_thread(void *arg)
{
    sigset_t *set = arg;
    int sig = 0;
    if (sigwait(set, &sig))
        return NULL;
    fb_log("signal %d: waiting for the running command, then exiting", sig);
    fb_cmd_lock(true);
    fb_status("stopped (signal %d)", sig);
    fb_log("exiting on signal %d", sig);
    _exit(128 + sig);
}

static void *serve_thread(void *arg)
{
    fb_transport *t = arg;
    for (;;) {
        int r;
        if (t->open_session(t))
            continue;
        fb_log("%s: host connected", t->name);
        fb_status("%s: host connected", t->name);
        r = fb_serve(t);
        t->close_session(t);
        fb_session_end();
        fb_log("%s: session closed", t->name);
        fb_status("%s: session closed, waiting for a host", t->name);
        if (r == 1) {
            fb_cmd_lock(true);
            fb_do_reboot(fb_pending_reboot);    /* 不是 --test-reboot 时不返回（exit 退出码给 /init） */
            fb_cmd_lock(false);
        }
    }
    return NULL;
}

int main(int argc, char **argv)
{
    bool usb = true, usb_setup = true, tcp = false, kmsg = false, entry = true, confirm = false;
    int tcp_port = 5554, sub = 0;   /* sub：0 常驻 / 1 --wipe-data / 2 --clear-bcb */
    const char *udc = NULL, *ffs = NULL, *cmdline_file = "/proc/cmdline", *logfile = NULL, *status = NULL;
    static char cl[8192], v[256], disk_uuid[64], esp_uuid[64], status_buf[300];
    pthread_t th[3];
    int nth = 0, ntr = 0;
    sigset_t sigs;

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
        } else if (!strcmp(a, "--wipe-data"))
            sub = 1;
        else if (!strcmp(a, "--confirm"))
            confirm = true;
        else if (!strcmp(a, "--clear-bcb"))
            sub = 2;
        else if (!strcmp(a, "--usb"))
            usb = true;
        else if (!strcmp(a, "--no-usb"))
            usb = false;
        else if (!strcmp(a, "--usb-nosetup"))
            usb_setup = false;
        else if ((x = OPT("--udc")))
            udc = x;
        else if ((x = OPT("--ffs")))
            ffs = x;
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
        else if ((x = OPT("--status")))
            status = x;
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
            return FB_EXIT_USAGE;
        }
#undef OPT
    }
    if (confirm && sub != 1) {
        fprintf(stderr, "gk3-fastbootd: --confirm only goes with --wipe-data\n");
        return FB_EXIT_USAGE;
    }
    if (G.max_download < 4096 || G.max_download > 0xFFFFFFFFull) {
        fprintf(stderr, "gk3-fastbootd: --max-download out of range\n");
        return FB_EXIT_USAGE;
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
    /* cmdline 打底，/init 的环境变量覆盖（它们本来就是从 cmdline 抄来的同一份值） */
    if (cmdline_get(cl, "gk3.why", v, sizeof(v)) && safe_val(v))
        snprintf(G.why, sizeof(G.why), "%s", v);
    if (env("GK3_WHY"))
        snprintf(G.why, sizeof(G.why), "%s", env("GK3_WHY"));
    if (cmdline_get(cl, "gk3.slot", v, sizeof(v)))
        G.slot_hint = parse_slot(v);
    if (env("GK3_SLOT") && parse_slot(env("GK3_SLOT")) >= 0)      /* /init 认不出的槽写成 "?"：不覆盖 */
        G.slot_hint = parse_slot(env("GK3_SLOT"));
    if (cmdline_get(cl, "gk3.bootver", v, sizeof(v)) && safe_val(v))
        snprintf(G.bootver, sizeof(G.bootver), "%s", v);
    if (env("GK3_BOOTVER"))
        snprintf(G.bootver, sizeof(G.bootver), "%s", env("GK3_BOOTVER"));
    if (cmdline_get(cl, "gk3.serialno", v, sizeof(v)) && safe_val(v) && v[0])
        snprintf(G.serial, sizeof(G.serial), "%s", v);
    cmdline_get(cl, "gk3.disk", disk_uuid, sizeof(disk_uuid));
    if (env("GK3_DISK"))
        snprintf(disk_uuid, sizeof(disk_uuid), "%s", env("GK3_DISK"));
    if (disk_uuid[0])
        G.dopt.want_misc_uuid = disk_uuid;
    if (cmdline_get(cl, "gk3.esp", esp_uuid, sizeof(esp_uuid)))
        G.eopt.want_esp_uuid = esp_uuid;
    if (cmdline_get(cl, "gk3.fbtcp", v, sizeof(v)) && !strcmp(v, "1"))
        tcp = true;
    if (cmdline_get(cl, "gk3.dispatch", v, sizeof(v)) && !strcmp(v, "1"))
        G.dispatch = true;
    if (!udc)
        udc = env("GK3_UDC") ? env("GK3_UDC") : "a600000.usb";
    if (!ffs)
        ffs = env("GK3_FFS");
    if (!status && env("GK3_RUN")) {
        snprintf(status_buf, sizeof(status_buf), "%s/fastbootd.status", env("GK3_RUN"));
        status = status_buf;
    }
    G.status_file = status;

    fb_log("gk3-fastbootd %s %s: why=%s slot=%d bootver=%s disk=%s esp=%s dispatch=%d usb=%d%s tcp=%d", GK3FB_VERSION,
           sub == 1 ? (confirm ? "--wipe-data --confirm" : "--wipe-data") : sub == 2 ? "--clear-bcb" : "starting",
           G.why[0] ? G.why : "-", G.slot_hint, G.bootver[0] ? G.bootver : "-", disk_uuid[0] ? disk_uuid : "(scan)",
           esp_uuid[0] ? esp_uuid : "(probe)", G.dispatch, usb, usb_setup ? "" : " (nosetup)", tcp);

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

    if (sub == 1)
        return fb_sub_wipe(confirm);
    if (sub == 2)
        return fb_sub_clear_bcb();

    /* 常驻。信号由专门的线程收：先屏蔽，再起其他线程（它们继承屏蔽字） */
    sigemptyset(&sigs);
    sigaddset(&sigs, SIGTERM);
    sigaddset(&sigs, SIGINT);
    pthread_sigmask(SIG_BLOCK, &sigs, NULL);
    pthread_create(&th[nth++], NULL, signal_thread, &sigs);
    fb_status("starting");

    /* 不挂起（fastboot-design §4.7）：initramfs 里本来没人写 /sys/power/state，这里再拿一把 wakelock 作保险 */
    {
        int fd = open("/sys/power/wake_lock", O_WRONLY | O_CLOEXEC);
        if (fd >= 0) {
            if (write(fd, "gk3fastboot", 11) != 11)
                fb_log("wake_lock: %s", strerror(errno));
            close(fd);
        }
    }
    if (entry)
        fb_entry();

    if (usb) {
        fb_transport *t = fb_usb_new(udc, usb_setup, ffs);
        if (t) {
            pthread_create(&th[nth++], NULL, serve_thread, t);
            ntr++;
        } else {
            fb_log("USB transport unavailable");
        }
    }
    if (tcp) {
        fb_transport *t = fb_tcp_new(tcp_port);
        if (t) {
            pthread_create(&th[nth++], NULL, serve_thread, t);
            ntr++;
        } else {
            fb_log("TCP transport unavailable");
        }
    }
    if (!ntr) {
        fb_log("no transport could be started — exiting");
        fb_status("no transport could be started (see log)");
        return FB_EXIT_FATAL;
    }
    fb_log("ready");
    fb_status("ready: waiting for a host (%s%s%s)", usb ? "usb" : "", usb && tcp ? " + " : "", tcp ? "tcp" : "");
    for (int i = 1; i < nth; i++)
        pthread_join(th[i], NULL);
    return FB_EXIT_FATAL;
}

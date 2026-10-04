/*
 * QEMU 夹具专用：测试 initramfs 的 /init（静态、无 libc，aarch64 Linux 系统调用直调）。
 *
 * gk3boot 的 H2 交接（tools/gk3boot/efi/boot/handoff.c）把一个通用 arm64 内核（Debian）+ 这份 initramfs
 * + 带标记属性的 dtb 交给内核 EFI stub。/init 一跑起来就说明 initrd（LoadFile2）通了；它再把三样东西打到串口：
 *   - /proc/cmdline                       → LoadOptions（UCS-2 cmdline）通了
 *   - /sys/firmware/devicetree/base/gk3,fixture-marker
 *                                         → 内核用的是我们装进配置表的 dtb（固件自己的 dtb 没有这个属性）
 *   - /gk3-initrd-marker                  → 跑的确实是我们打进 boot.img 的这份 initramfs
 * 然后 reboot(POWER_OFF)，QEMU 退出。check_boot.py 读串口判定。
 *
 * 编译（容器里，gcc 原生 aarch64）：gcc -static -nostdlib -ffreestanding -fno-stack-protector -O2 -o init init.c
 */
typedef unsigned long u64;

#define SYS_mkdirat 34
#define SYS_mount 40
#define SYS_openat 56
#define SYS_close 57
#define SYS_read 63
#define SYS_write 64
#define SYS_exit 93
#define SYS_reboot 142
#define AT_FDCWD -100
#define O_RDONLY 0
#define O_WRONLY 1
#define O_DIRECTORY 040000

static long sc(long n, long a, long b, long c, long d, long e)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    register long x4 __asm__("x4") = e;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4) : "memory");
    return x0;
}

static int out = 1;

static unsigned long slen(const char *s)
{
    unsigned long n = 0;
    while (s[n])
        n++;
    return n;
}

static void puts_(const char *s) { sc(SYS_write, out, (long)s, (long)slen(s), 0, 0); }

/* 读一个小文件进 buf（NUL 结尾；内部的 NUL 与换行换成空格，便于一行打印）；失败返回 -1 */
static long slurp(const char *path, char *buf, long cap)
{
    long fd = sc(SYS_openat, AT_FDCWD, (long)path, O_RDONLY, 0, 0), n = 0, r;
    if (fd < 0)
        return -1;
    while (n < cap - 1 && (r = sc(SYS_read, fd, (long)(buf + n), cap - 1 - n, 0, 0)) > 0)
        n += r;
    sc(SYS_close, fd, 0, 0, 0, 0);
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == 0))
        n--;
    for (long i = 0; i < n; i++)
        if (buf[i] == 0 || buf[i] == '\n')
            buf[i] = ' ';
    buf[n] = 0;
    return n;
}

static void show(const char *label, const char *path)
{
    static char buf[4096];
    puts_("GK3-INIT ");
    puts_(label);
    puts_("=");
    puts_(slurp(path, buf, sizeof(buf)) < 0 ? "(absent)" : buf);
    puts_("\n");
}

static void exists(const char *label, const char *path)
{
    long fd = sc(SYS_openat, AT_FDCWD, (long)path, O_RDONLY | O_DIRECTORY, 0, 0);
    puts_("GK3-INIT ");
    puts_(label);
    puts_(fd >= 0 ? "=present\n" : "=absent\n");
    if (fd >= 0)
        sc(SYS_close, fd, 0, 0, 0, 0);
}

void _start(void)
{
    sc(SYS_mount, (long)"devtmpfs", (long)"/dev", (long)"devtmpfs", 0, 0);
    sc(SYS_mount, (long)"proc", (long)"/proc", (long)"proc", 0, 0);
    sc(SYS_mount, (long)"sysfs", (long)"/sys", (long)"sysfs", 0, 0);
    long fd = sc(SYS_openat, AT_FDCWD, (long)"/dev/console", O_WRONLY, 0, 0);
    if (fd >= 0)
        out = (int)fd;
    puts_("\nGK3-INIT hello from the fixture initramfs (pid 1)\n");
    show("cmdline", "/proc/cmdline");
    show("dt_marker", "/sys/firmware/devicetree/base/gk3,fixture-marker");
    show("dt_model", "/sys/firmware/devicetree/base/model");
    show("initrd_marker", "/gk3-initrd-marker");
    exists("dt_chosen", "/sys/firmware/devicetree/base/chosen");
    exists("efi", "/sys/firmware/efi");
    show("efi_systab", "/sys/firmware/efi/systab");
    puts_("GK3-INIT done, powering off\n");
    /* LINUX_REBOOT_MAGIC1/2、LINUX_REBOOT_CMD_POWER_OFF（include/uapi/linux/reboot.h） */
    sc(SYS_reboot, 0xfee1deadL, 672274793L, 0x4321fedcL, 0, 0);
    for (;;)
        sc(SYS_exit, 0, 0, 0, 0, 0);
}

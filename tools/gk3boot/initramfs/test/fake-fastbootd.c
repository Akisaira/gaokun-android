/* 测试用的假 gk3-fastbootd：只实现 /init 与 gk3-fastbootd 之间的【接口】（README §13），不实现 fastboot 协议。
 * 由 scripts/gk3boot/test-initramfs.sh 编成静态 aarch64，放进测试 overlay 的 /bin/gk3-fastbootd。
 *
 * 行为由 /etc/gk3-fbi/stub.conf 控制（每个 QEMU 场景一份），key=value：
 *   serve_exits=11,0   第 1 次 serve 退出码 11、第 2 次 0……（用完了重复最后一个）；hold = 一直挂着
 *   serve_hold=3       serve 写完描述符后挂几秒再退出
 *   wipe_rc=3          --wipe-data（不带 --confirm）的退出码
 *   confirm_rc=0       --wipe-data --confirm 的退出码
 *   clear_rc=0         --clear-bcb 的退出码
 * 每次调用都往 /dev/kmsg 打一行 "fake-fastbootd: …"，测试从串口里认。
 */
#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/usb/ch9.h>
#include <linux/usb/functionfs.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void say(const char *fmt, ...)
{
    char b[512];
    va_list ap;
    int fd;
    va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    fprintf(stderr, "fake-fastbootd: %s\n", b);
    fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        dprintf(fd, "<2>fake-fastbootd: %s\n", b);
        close(fd);
    }
}

static char conf[2048];

static const char *get(const char *key, const char *def)
{
    static char v[256];
    size_t kl = strlen(key);
    for (const char *p = conf; *p;) {
        const char *nl = strchr(p, '\n');
        size_t n = nl ? (size_t)(nl - p) : strlen(p);
        if (n > kl && !strncmp(p, key, kl) && p[kl] == '=') {
            size_t vl = n - kl - 1 < sizeof(v) - 1 ? n - kl - 1 : sizeof(v) - 1;
            memcpy(v, p + kl + 1, vl);
            v[vl] = 0;
            return v;
        }
        p += n + (nl ? 1 : 0);
    }
    return def;
}

/* FunctionFS v2 描述符：一个接口 0xff/0x42/0x03 + bulk OUT/IN（照 usb_client.cpp 的 fs/hs 两套） */
struct func {
    struct usb_interface_descriptor intf;
    struct usb_endpoint_descriptor_no_audio out, in;
} __attribute__((packed));

static const struct {
    struct usb_functionfs_descs_head_v2 h;
    __le32 fs_count, hs_count;
    struct func fs, hs;
} __attribute__((packed)) descs = {
    .h = {.magic = htole32(FUNCTIONFS_DESCRIPTORS_MAGIC_V2),
          .length = htole32(sizeof(descs)),
          .flags = htole32(FUNCTIONFS_HAS_FS_DESC | FUNCTIONFS_HAS_HS_DESC)},
    .fs_count = htole32(3),
    .hs_count = htole32(3),
#define F(mps)                                                                                                   \
    {.intf = {.bLength = USB_DT_INTERFACE_SIZE, .bDescriptorType = USB_DT_INTERFACE, .bNumEndpoints = 2,         \
              .bInterfaceClass = USB_CLASS_VENDOR_SPEC, .bInterfaceSubClass = 0x42, .bInterfaceProtocol = 3,     \
              .iInterface = 1},                                                                                  \
     .out = {.bLength = USB_DT_ENDPOINT_SIZE, .bDescriptorType = USB_DT_ENDPOINT,                                 \
             .bEndpointAddress = 1 | USB_DIR_OUT, .bmAttributes = USB_ENDPOINT_XFER_BULK,                       \
             .wMaxPacketSize = htole16(mps)},                                                                    \
     .in = {.bLength = USB_DT_ENDPOINT_SIZE, .bDescriptorType = USB_DT_ENDPOINT,                                  \
            .bEndpointAddress = 2 | USB_DIR_IN, .bmAttributes = USB_ENDPOINT_XFER_BULK,                         \
            .wMaxPacketSize = htole16(mps)}}
    .fs = F(64),
    .hs = F(512),
};

#define STR "fastboot"
static const struct {
    struct usb_functionfs_strings_head h;
    struct {
        __le16 code;
        char s[sizeof(STR)];
    } __attribute__((packed)) l;
} __attribute__((packed)) strs = {
    .h = {.magic = htole32(FUNCTIONFS_STRINGS_MAGIC), .length = htole32(sizeof(strs)),
          .str_count = htole32(1), .lang_count = htole32(1)},
    .l = {htole16(0x0409), STR},
};

static int serve(void)
{
    const char *run = getenv("GK3_RUN") ? getenv("GK3_RUN") : "/run/gk3";
    const char *ffs = getenv("GK3_FFS") ? getenv("GK3_FFS") : "/dev/usb-ffs/fastboot";
    char p[256], list[256], *tok, *save;
    int n = 0, fd, code = 0;
    FILE *f;

    snprintf(p, sizeof(p), "%s/fake-serve-count", run);
    if ((f = fopen(p, "r"))) {
        if (fscanf(f, "%d", &n) != 1)
            n = 0;
        fclose(f);
    }
    if ((f = fopen(p, "w"))) {
        fprintf(f, "%d\n", n + 1);
        fclose(f);
    }
    say("serve #%d why=%s slot=%s disk=%s udc=%s", n + 1, getenv("GK3_WHY"), getenv("GK3_SLOT"),
        getenv("GK3_DISK"), getenv("GK3_UDC"));

    snprintf(p, sizeof(p), "%s/ep0", ffs);
    fd = open(p, O_RDWR);
    if (fd < 0) {
        say("open %s: %s", p, strerror(errno));
        return 1;
    }
    if (write(fd, &descs, sizeof(descs)) != (ssize_t)sizeof(descs) ||
        write(fd, &strs, sizeof(strs)) != (ssize_t)sizeof(strs)) {
        say("write descriptors: %s", strerror(errno));
        return 1;
    }
    say("descriptors written");
    snprintf(p, sizeof(p), "%s/fastbootd.status", run);
    if ((f = fopen(p, "w"))) {
        fprintf(f, "fake: waiting for commands (serve #%d)\n", n + 1);
        fclose(f);
    }

    snprintf(list, sizeof(list), "%s", get("serve_exits", "hold"));
    tok = strtok_r(list, ",", &save);
    for (int i = 0; tok && i < n; i++) {
        char *nx = strtok_r(NULL, ",", &save);
        if (!nx)
            break;
        tok = nx;
    }
    if (!tok || !strcmp(tok, "hold")) {
        say("holding");
        for (;;)
            pause();
    }
    code = atoi(tok);
    sleep((unsigned)atoi(get("serve_hold", "3")));
    say("serve #%d exiting with %d", n + 1, code);
    close(fd);
    return code;
}

int main(int argc, char **argv)
{
    int fd = open("/etc/gk3-fbi/stub.conf", O_RDONLY);
    if (fd >= 0) {
        ssize_t r = read(fd, conf, sizeof(conf) - 1);
        conf[r > 0 ? r : 0] = 0;
        close(fd);
    }
    if (argc == 1)
        return serve();
    if (argc == 2 && !strcmp(argv[1], "--wipe-data")) {
        int rc = atoi(get("wipe_rc", "3"));
        say("wipe-data (no confirm) -> %d", rc);
        if (rc == 3)
            printf("Request not verified: confirmation required\n");
        return rc;
    }
    if (argc == 3 && !strcmp(argv[1], "--wipe-data") && !strcmp(argv[2], "--confirm")) {
        int rc = atoi(get("confirm_rc", "0"));
        say("wipe-data confirm -> %d", rc);
        printf(rc ? "Wipe failed (fake)\n" : "userdata and metadata erased (fake)\n");
        return rc;
    }
    if (argc == 2 && !strcmp(argv[1], "--clear-bcb")) {
        int rc = atoi(get("clear_rc", "0"));
        say("clear-bcb -> %d", rc);
        return rc;
    }
    say("unknown arguments");
    return 2;
}

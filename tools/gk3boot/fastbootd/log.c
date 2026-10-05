/* gk3-fastbootd：日志。stderr + 环形缓冲（oem log）+ 可选 /dev/kmsg（让 dmesg / efi_pstore 也看得到）+ 可选文件。 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "fbd.h"

#define RING 65536u

static char ring[RING];
static size_t ring_head;    /* 下一个写入位置 */
static bool ring_wrapped;
static int kmsg_fd = -1, file_fd = -1;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

void fb_log_init(bool to_kmsg, const char *file)
{
    if (to_kmsg)
        kmsg_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (file)
        file_fd = open(file, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
}

static void ring_put(const char *s, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        ring[ring_head++] = s[i];
        if (ring_head == RING) {
            ring_head = 0;
            ring_wrapped = true;
        }
    }
}

void fb_log(const char *fmt, ...)
{
    char line[1024];
    struct timespec ts;
    int n, ts_len;
    va_list ap;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    n = ts_len = snprintf(line, sizeof(line), "[%5ld.%03ld] ", (long)ts.tv_sec, ts.tv_nsec / 1000000);
    va_start(ap, fmt);
    vsnprintf(line + n, sizeof(line) - (size_t)n - 1, fmt, ap);
    va_end(ap);
    n = (int)strlen(line);
    line[n++] = '\n';
    line[n] = 0;

    pthread_mutex_lock(&mu);
    ring_put(line, (size_t)n);
    if (write(2, line, (size_t)n) < 0) { /* stderr 关了也无妨 */ }
    if (file_fd >= 0 && write(file_fd, line, (size_t)n) < 0) { }
    if (kmsg_fd >= 0) {
        char k[1100];
        int kn = snprintf(k, sizeof(k), "<6>gk3-fastbootd: %s", line + ts_len);
        if (kn > 0 && write(kmsg_fd, k, (size_t)kn) < 0) { }
    }
    pthread_mutex_unlock(&mu);
}

void fb_log_foreach(unsigned max_lines, void (*cb)(void *ctx, const char *line), void *ctx)
{
    static char copy[RING + 1];
    size_t len, start;
    unsigned lines = 0;

    pthread_mutex_lock(&mu);
    if (ring_wrapped) {
        memcpy(copy, ring + ring_head, RING - ring_head);
        memcpy(copy + (RING - ring_head), ring, ring_head);
        len = RING;
    } else {
        memcpy(copy, ring, ring_head);
        len = ring_head;
    }
    pthread_mutex_unlock(&mu);
    copy[len] = 0;

    /* 从尾往前数 max_lines 行 */
    start = len;
    while (start > 0) {
        if (copy[start - 1] == '\n' && start != len && ++lines >= max_lines)
            break;
        start--;
    }
    if (ring_wrapped && start == 0) {     /* 第一行多半是被截断的半行，跳过 */
        char *nl = memchr(copy, '\n', len);
        start = nl ? (size_t)(nl - copy) + 1 : len;
    }
    for (char *p = copy + start; p < copy + len;) {
        char *nl = memchr(p, '\n', (size_t)(copy + len - p));
        if (!nl)
            nl = copy + len;
        *nl = 0;
        if (*p)
            cb(ctx, p);
        p = nl + 1;
    }
}

/* 状态文件：/init 显示第一行（"flash boot_a"、"tcp: host connected"…），并把 mtime 的变化当作"有活干"
 * （空闲关机重新计时）。整份替换（写 .tmp 再 rename），/init 读到的永远是完整的一行。 */
void fb_status(const char *fmt, ...)
{
    char line[256], tmp[300];
    va_list ap;
    int fd;
    size_t n;
    if (!G.status_file)
        return;
    va_start(ap, fmt);
    vsnprintf(line, sizeof(line) - 1, fmt, ap);
    va_end(ap);
    n = strcspn(line, "\n");
    line[n++] = '\n';
    line[n] = 0;
    snprintf(tmp, sizeof(tmp), "%s.tmp", G.status_file);
    pthread_mutex_lock(&mu);
    fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) {
        bool ok = write(fd, line, n) == (ssize_t)n;
        close(fd);
        if (!ok || rename(tmp, G.status_file))
            unlink(tmp);
    }
    pthread_mutex_unlock(&mu);
}

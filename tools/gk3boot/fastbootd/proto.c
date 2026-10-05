/* gk3-fastbootd：协议框架（fastboot README.md "Transport and Framing"）。
 *
 *   主机发一条命令（≤ 4096 字节，不带 NUL）→ 设备回 INFO*（≤ 252 字节一条）→ OKAY / FAIL / DATA。
 *   download:%08x → DATA%08x → 数据阶段恰好 N 字节 → OKAY。
 * 每条命令都恰好以一个 OKAY 或 FAIL 结束；处理函数忘了回应就补 FAIL（不让主机挂死）。
 * 命令在全局锁下执行：USB 与 TCP 两个会话线程不会同时碰盘，也不会交错用同一个 download 缓冲。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fbd.h"

struct fb_ctx {
    fb_transport *t;    /* NULL = 本地上下文（子命令）：回应只进日志 */
    bool done;      /* 已回 OKAY / FAIL */
    bool io_err;    /* 写回应失败 ⇒ 会话断了 */
    char last_fail[FB_MSG_MAX + 1];
};

static pthread_mutex_t cmd_lock = PTHREAD_MUTEX_INITIALIZER;

static void send_pkt(fb_ctx *c, const char *tag, const char *msg)
{
    char pkt[FB_RESP_MAX + 1];
    size_t n;
    if (!c->t) {
        if (!strcmp(tag, "FAIL"))
            snprintf(c->last_fail, sizeof(c->last_fail), "%s", msg);
        return;
    }
    if (c->io_err)
        return;
    n = (size_t)snprintf(pkt, sizeof(pkt), "%s%.*s", tag, (int)FB_MSG_MAX, msg);
    if (n > FB_RESP_MAX)
        n = FB_RESP_MAX;
    if (c->t->write(c->t, pkt, n))
        c->io_err = true;
}

static void vsend(fb_ctx *c, const char *tag, const char *fmt, va_list ap)
{
    char msg[2048];
    vsnprintf(msg, sizeof(msg), fmt, ap);
    if (!strcmp(tag, "INFO")) {
        /* 长 INFO 拆成多条（每条 ≤ 252 字节），换行也各成一条 */
        char *p = msg;
        while (*p) {
            size_t n = strcspn(p, "\n");
            size_t k = n > FB_MSG_MAX ? FB_MSG_MAX : n;
            char save = p[k];
            p[k] = 0;
            send_pkt(c, "INFO", p);
            p[k] = save;
            p += k;
            if (*p == '\n')
                p++;
        }
        fb_log("  INFO %s", msg);
        return;
    }
    if (c->done) {
        fb_log("BUG: second final response (%s %s) suppressed", tag, msg);
        return;
    }
    c->done = true;
    fb_log("  %s %s", tag, msg);
    send_pkt(c, tag, msg);
}

void fb_info(fb_ctx *c, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsend(c, "INFO", fmt, ap);
    va_end(ap);
}

void fb_okay(fb_ctx *c, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsend(c, "OKAY", fmt, ap);
    va_end(ap);
}

void fb_fail(fb_ctx *c, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsend(c, "FAIL", fmt, ap);
    va_end(ap);
}

void fb_info_cb(void *c, const char *msg)
{
    fb_info(c, "%s", msg);
}

fb_ctx *fb_ctx_local(void)
{
    static fb_ctx lc;
    memset(&lc, 0, sizeof(lc));
    return &lc;
}

const char *fb_ctx_last_fail(fb_ctx *c)
{
    return c->last_fail;
}

static int parse_hex8(const char *s, uint32_t *out)
{
    uint32_t v = 0;
    if (strlen(s) != 8)
        return -1;
    for (int i = 0; i < 8; i++) {
        char ch = s[i];
        v <<= 4;
        if (ch >= '0' && ch <= '9')
            v |= (uint32_t)(ch - '0');
        else if (ch >= 'a' && ch <= 'f')
            v |= (uint32_t)(ch - 'a' + 10);
        else if (ch >= 'A' && ch <= 'F')
            v |= (uint32_t)(ch - 'A' + 10);
        else
            return -1;
    }
    *out = v;
    return 0;
}

/* download 需要传输层，放在这里而不是 cmds.c */
static void do_download(fb_ctx *c, const char *arg)
{
    uint32_t sz;
    char resp[16];
    if (parse_hex8(arg, &sz)) {
        fb_fail(c, "Invalid size (need 8 hex digits)");
        return;
    }
    if (sz == 0) {
        fb_fail(c, "Invalid size (0)");
        return;
    }
    if (sz > G.max_download) {
        fb_fail(c, "data too large: %u > max-download-size %llu", sz, (unsigned long long)G.max_download);
        return;
    }
    free(G.dl);
    G.dl = NULL;
    G.dl_len = 0;
    G.dl = malloc(sz);
    if (!G.dl) {
        fb_fail(c, "out of memory for %u bytes", sz);
        return;
    }
    snprintf(resp, sizeof(resp), "%08x", sz);
    c->done = true;     /* DATA 不是终结回应，但这之后的 OKAY/FAIL 由我们自己发 */
    fb_log("  DATA %s", resp);
    send_pkt(c, "DATA", resp);
    if (c->io_err)
        return;
    if (c->t->read_data(c->t, G.dl, sz)) {
        free(G.dl);
        G.dl = NULL;
        c->io_err = true;
        fb_log("download of %u bytes aborted (session lost)", sz);
        return;
    }
    G.dl_len = sz;
    c->done = false;
    fb_okay(c, "%s", "");
}

void fb_cmd_lock(bool on)
{
    if (on)
        pthread_mutex_lock(&cmd_lock);
    else
        pthread_mutex_unlock(&cmd_lock);
}

void fb_session_end(void)
{
    /* 会话结束就丢掉 download 缓冲：下一个主机进程的 flash 不能用上一个进程留下的数据 */
    pthread_mutex_lock(&cmd_lock);
    free(G.dl);
    G.dl = NULL;
    G.dl_len = 0;
    pthread_mutex_unlock(&cmd_lock);
}

int fb_serve(fb_transport *t)
{
    char cmd[FB_CMD_MAX + 1];
    for (;;) {
        fb_ctx c = {t, false, false, ""};
        long n = t->read_cmd(t, cmd, FB_CMD_MAX);
        if (n < 0)
            return 0;
        cmd[n] = 0;
        if (strlen(cmd) != (size_t)n) {
            pthread_mutex_lock(&cmd_lock);
            fb_fail(&c, "command contains a NUL byte");
            pthread_mutex_unlock(&cmd_lock);
            continue;
        }
        pthread_mutex_lock(&cmd_lock);
        fb_log("%s> %s", t->name, cmd);
        /* 状态文件：当前命令（/init 显示，并据此重置空闲计时） */
        fb_status("%s: %.80s", t->name, cmd);
        if (!strncmp(cmd, "download:", 9))
            do_download(&c, cmd + 9);
        else
            fb_dispatch(&c, cmd);
        if (!c.done && !c.io_err)
            fb_fail(&c, "internal error: command produced no response");
        pthread_mutex_unlock(&cmd_lock);
        if (c.io_err)
            return 0;
        if (fb_pending_reboot != FB_RB_NONE)
            return 1;
    }
}

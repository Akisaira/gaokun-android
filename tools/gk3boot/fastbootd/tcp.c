/* gk3-fastbootd：TCP 传输（fastboot README.md "TCP Protocol v1"）。
 *
 * 端口 5554；握手双方各发 "FB01"（版本取小，我们只会 1）；之后每条消息 = 8 字节大端长度 + 内容。
 * 写法对齐设备端上游 fastboot/device/tcp_client.cpp：命令阶段一条消息就是一条命令；数据阶段跨消息拼满。
 * ★ 发布默认关：只有 --tcp 或 cmdline gk3.fbtcp=1 才起（main.c）。它不认证（与 orange 状态下的 fastbootd 一样），
 *   开着时同一网段的任何人都能刷机 —— 只给离线测试和"没有 USB 线"的开发场景用。
 */
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "fbd.h"

#ifndef SOCK_CLOEXEC
#define SOCK_CLOEXEC 0
#endif
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0   /* macOS 主机测试版：main.c 已忽略 SIGPIPE */
#endif

typedef struct {
    int lfd, fd;
    uint64_t left;      /* 当前消息还剩多少字节没读 */
} tcpx;

static int recv_all(int fd, void *buf, size_t n)
{
    uint8_t *b = buf;
    while (n) {
        ssize_t r = recv(fd, b, n, 0);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return -1;
        b += r;
        n -= (size_t)r;
    }
    return 0;
}

static int send_all(int fd, const void *buf, size_t n)
{
    const uint8_t *b = buf;
    while (n) {
        ssize_t r = send(fd, b, n, MSG_NOSIGNAL);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return -1;
        b += r;
        n -= (size_t)r;
    }
    return 0;
}

static int t_open(fb_transport *t)
{
    tcpx *x = t->priv;
    for (;;) {
        char hs[4];
        struct timeval tv = {2, 0};     /* tcp_client.cpp:kHandshakeTimeoutMs */
        int fd = accept(x->lfd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR)
                continue;
            fb_log("tcp: accept: %s", strerror(errno));
            sleep(1);
            continue;
        }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        if (recv_all(fd, hs, 4) || memcmp(hs, "FB", 2) || hs[2] < '0' || hs[2] > '9' || hs[3] < '0' || hs[3] > '9' ||
            (hs[2] - '0') * 10 + (hs[3] - '0') < 1) {
            fb_log("tcp: bad handshake, dropping connection");
            close(fd);
            continue;
        }
        if (send_all(fd, "FB01", 4)) {
            close(fd);
            continue;
        }
        tv.tv_sec = 0;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        {
            int one = 1;
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        }
        x->fd = fd;
        x->left = 0;
        return 0;
    }
}

static int next_msg(tcpx *x)
{
    uint8_t h[8];
    if (recv_all(x->fd, h, 8))
        return -1;
    x->left = 0;
    for (int i = 0; i < 8; i++)
        x->left = x->left << 8 | h[i];
    return 0;
}

static long t_read_cmd(fb_transport *t, char *buf, size_t max)
{
    tcpx *x = t->priv;
    if (x->left) {
        fb_log("tcp: %llu stray bytes before a command, dropping session", (unsigned long long)x->left);
        return -1;
    }
    do {
        if (next_msg(x))
            return -1;
    } while (x->left == 0);
    if (x->left > max) {
        fb_log("tcp: command message of %llu bytes is too long", (unsigned long long)x->left);
        return -1;
    }
    if (recv_all(x->fd, buf, (size_t)x->left))
        return -1;
    {
        long n = (long)x->left;
        x->left = 0;
        return n;
    }
}

static int t_read_data(fb_transport *t, void *buf, size_t len)
{
    tcpx *x = t->priv;
    uint8_t *b = buf;
    while (len) {
        size_t n;
        if (x->left == 0 && next_msg(x))
            return -1;
        n = x->left < len ? (size_t)x->left : len;
        if (n && recv_all(x->fd, b, n))
            return -1;
        b += n;
        len -= n;
        x->left -= n;
    }
    if (x->left) {
        fb_log("tcp: data message longer than the announced download");
        return -1;
    }
    return 0;
}

static int t_write(fb_transport *t, const void *buf, size_t len)
{
    tcpx *x = t->priv;
    uint8_t h[8];
    for (int i = 0; i < 8; i++)
        h[i] = (uint8_t)((uint64_t)len >> (56 - 8 * i));
    if (send_all(x->fd, h, 8) || send_all(x->fd, buf, len))
        return -1;
    return 0;
}

static void t_close(fb_transport *t)
{
    tcpx *x = t->priv;
    if (x->fd >= 0) {
        shutdown(x->fd, SHUT_RDWR);
        close(x->fd);
    }
    x->fd = -1;
    x->left = 0;
}

fb_transport *fb_tcp_new(int port)
{
    fb_transport *t = calloc(1, sizeof(*t));
    tcpx *x = calloc(1, sizeof(*x));
    struct sockaddr_in6 a;
    int one = 1, zero = 0;
    if (!t || !x)
        return NULL;
    x->fd = -1;
    x->lfd = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (x->lfd < 0) {
        fb_log("tcp: socket: %s", strerror(errno));
        return NULL;
    }
    setsockopt(x->lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(x->lfd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero));
    memset(&a, 0, sizeof(a));
    a.sin6_family = AF_INET6;
    a.sin6_port = htons((uint16_t)port);
    a.sin6_addr = in6addr_any;
    if (bind(x->lfd, (struct sockaddr *)&a, sizeof(a)) || listen(x->lfd, 4)) {
        fb_log("tcp: bind/listen :%d: %s", port, strerror(errno));
        close(x->lfd);
        return NULL;
    }
    t->name = "tcp";
    t->open_session = t_open;
    t->read_cmd = t_read_cmd;
    t->read_data = t_read_data;
    t->write = t_write;
    t->close_session = t_close;
    t->priv = x;
    fb_log("tcp: listening on port %d (unauthenticated — test / development only)", port);
    return t;
}

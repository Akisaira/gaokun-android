/* SPDX-License-Identifier: Apache-2.0 */
/*
 * gaokun3-play-probe —— 从【应用视角】量播放通路的时间戳准不准（AAudio，不出声：播的全是 0）。
 *
 * 为什么需要它：音乐游戏按 AudioTrack / AAudio 的时间戳（"第 F 帧在 T 时刻播出"）对拍子。
 * 时间戳比真实播出超前多少，游戏就偏多少；超前量一变，偏移就不稳。这个工具量的正是这个超前量。
 *
 * 用法（adb root 之后，push 到 /data/local/tmp；先等输出线程 standby，否则应用帧号和硬件帧号对不齐）：
 *   gaokun3-play-probe [-t 秒] [-m none|lowlat] [-u media|game] [-k status 路径] [-v 打印原始样本]
 *     -k 默认 /proc/asound/card0/pcm1p/sub0/status（扬声器 hw:0,1；耳机是 pcm0p）
 *
 * 做法：播放期间每 1 ms 读一次 ALSA status（要 CONFIG_SND_VERBOSE_PROCFS），记 hw_ptr 何时前进、ALSA 里还压着多少帧；
 *   每 5 ms 调一次 AAudioStream_getTimestamp(CLOCK_MONOTONIC)。播完离线算：
 *   * 超前量 U = 时间戳说已播出的帧号 − 同一时刻硬件真实 DMA 到的帧号（按 hw_ptr 的前进时刻线性插值），换算成 ms。
 *     U > 0 = 应用以为声音早就出去了，其实还在 HAL 的缓冲里 —— 游戏听到的声音就比它以为的晚 U。
 *     帧号对齐假设"应用第 0 帧 = 硬件第 0 帧"（输出线程从 standby 起、只有我们一条流时成立，误差至多 AudioFlinger 一块）；
 *     ⇒ 同一次运行里 U 的【变化】是准的，绝对值带这个误差。DSP / codec 那一段在 DMA 之后，这里测不出，只会让真实值更大。
 *   * ALSA 积压 = appl_ptr − hw_ptr：已经交给 ALSA、还没播的帧 —— 这部分一定没有算进时间戳，是 U 的下限（不依赖对齐）。
 *   * U 按 1 秒切片报中位数；相邻时间戳样本之间 U 跳变超过 5 ms 的次数与最大跳变。
 */
#include <aaudio/AAudio.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define MAX_HW 400000
#define MAX_TS 200000
static struct { int64_t t, hw, appl; } g_hw[MAX_HW];
static int g_nhw;
static struct { int64_t now, pos, ts, written; } g_ts[MAX_TS];
static int g_nts;
static int g_notRunning;  // 流在跑时 status 不是 RUNNING 的次数（XRUN / 重新 prepare）
static int g_hwBack;      // hw_ptr 往回走的次数

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}
static int64_t kv_int(const char *buf, const char *key) {
    const char *p = strstr(buf, key);
    if (!p || !(p = strchr(p, ':'))) return -1;
    return strtoll(p + 1, NULL, 10);
}
static int64_t kv_time(const char *buf, const char *key) {
    const char *p = strstr(buf, key);
    if (!p || !(p = strchr(p, ':'))) return -1;
    char *e;
    long long sec = strtoll(p + 1, &e, 10);
    if (*e != '.') return -1;
    return sec * 1000000000LL + strtoll(e + 1, NULL, 10);
}

// 读一次 status；hw_ptr 变了就记一条（时刻优先用 status 的 tstamp = 上次更新 hw_ptr 的时刻）
static int poll_status(const char *path, int started) {
    char buf[1024];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    const int64_t t = now_ns();
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    if (!strstr(buf, "RUNNING")) {
        if (started && g_nhw > 0) g_notRunning++;
        return 0;
    }
    const int64_t hw = kv_int(buf, "hw_ptr"), appl = kv_int(buf, "appl_ptr");
    if (hw < 0 || g_nhw >= MAX_HW || (g_nhw > 0 && g_hw[g_nhw - 1].hw == hw)) return 0;
    if (g_nhw > 0 && hw < g_hw[g_nhw - 1].hw) g_hwBack++;
    int64_t ts = kv_time(buf, "tstamp");
    if (ts <= 0 || ts > t || t - ts > 50000000LL) ts = t;
    g_hw[g_nhw].t = ts;
    g_hw[g_nhw].hw = hw;
    g_hw[g_nhw].appl = appl;
    g_nhw++;
    return 0;
}

// 时刻 t 的硬件帧号：在前进时刻之间线性插值；超出范围返回 -1
static double hw_at(int64_t t, int *hint) {
    int i = *hint;
    while (i + 1 < g_nhw && g_hw[i + 1].t <= t) i++;
    *hint = i;
    if (i + 1 >= g_nhw || g_hw[i].t > t) return -1;
    const double f = (double)(t - g_hw[i].t) / (double)(g_hw[i + 1].t - g_hw[i].t);
    return g_hw[i].hw + f * (double)(g_hw[i + 1].hw - g_hw[i].hw);
}

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static double pct(double *v, int n, double p) { return v[(int)(p * (n - 1) + 0.5)]; }

static aaudio_data_callback_result_t on_data(AAudioStream *s, void *u, void *data, int32_t n) {
    (void)u;
    memset(data, 0, (size_t)n * AAudioStream_getChannelCount(s) * sizeof(int16_t));
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

int main(int argc, char **argv) {
    int secs = 10, lowlat = 0, game = 0, verbose = 0, opt;
    const char *statusPath = "/proc/asound/card0/pcm1p/sub0/status";
    while ((opt = getopt(argc, argv, "t:m:u:k:v")) != -1) {
        switch (opt) {
            case 't': secs = atoi(optarg); break;
            case 'm': lowlat = !strcmp(optarg, "lowlat"); break;
            case 'u': game = !strcmp(optarg, "game"); break;
            case 'k': statusPath = optarg; break;
            case 'v': verbose = 1; break;
            default:
                fprintf(stderr, "用法：%s [-t 秒] [-m none|lowlat] [-u media|game] [-k status]\n", argv[0]);
                return 2;
        }
    }
    AAudioStreamBuilder *b;
    AAudioStream *s;
    if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) return 1;
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSampleRate(b, 48000);
    AAudioStreamBuilder_setChannelCount(b, 2);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setPerformanceMode(b, lowlat ? AAUDIO_PERFORMANCE_MODE_LOW_LATENCY
                                                     : AAUDIO_PERFORMANCE_MODE_NONE);
    AAudioStreamBuilder_setUsage(b, game ? AAUDIO_USAGE_GAME : AAUDIO_USAGE_MEDIA);
    AAudioStreamBuilder_setDataCallback(b, on_data, NULL);
    aaudio_result_t r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) { printf("RESULT: FAIL (openStream %s)\n", AAudio_convertResultToText(r)); return 1; }
    const int rate = AAudioStream_getSampleRate(s);
    printf("PROBE: rate %d · ch %d · perf %d · burst %d · buffer %d/%d 帧 · status %s\n", rate,
           AAudioStream_getChannelCount(s), AAudioStream_getPerformanceMode(s),
           AAudioStream_getFramesPerBurst(s), AAudioStream_getBufferSizeInFrames(s),
           AAudioStream_getBufferCapacityInFrames(s), statusPath);

    int statusOk = poll_status(statusPath, 0) == 0;
    const int64_t t0 = now_ns();
    if ((r = AAudioStream_requestStart(s)) != AAUDIO_OK) {
        printf("RESULT: FAIL (requestStart %s)\n", AAudio_convertResultToText(r));
        return 1;
    }
    const int64_t tEnd = t0 + (int64_t)secs * 1000000000LL;
    int loops = 0;
    while (now_ns() < tEnd) {
        if (statusOk && poll_status(statusPath, 1) < 0) statusOk = 0;
        if (++loops % 5 == 0 && g_nts < MAX_TS) {
            int64_t pos, ts;
            if (AAudioStream_getTimestamp(s, CLOCK_MONOTONIC, &pos, &ts) == AAUDIO_OK) {
                g_ts[g_nts].now = now_ns();
                g_ts[g_nts].pos = pos;
                g_ts[g_nts].ts = ts;
                g_ts[g_nts].written = AAudioStream_getFramesWritten(s);
                g_nts++;
            }
        }
        usleep(1000);
    }
    AAudioStream_requestStop(s);
    AAudioStream_close(s);

    if (!statusOk || g_nhw < 10) {
        printf("RESULT: FAIL (没有 ALSA status 样本：%s；设备对不对？要 CONFIG_SND_VERBOSE_PROCFS)\n", statusPath);
        return 1;
    }
    // 第一个 hw_ptr 前进 → 硬件起播的时刻
    printf("PROBE: start → 第一次见到 hw_ptr 前进 %.1f ms · hw 样本 %d · 时间戳样本 %d\n",
           (g_hw[0].t - t0) / 1e6, g_nhw, g_nts);
    // 硬件时钟相对 CLOCK_MONOTONIC 的速率（跳过第 1 秒，最小二乘）
    {
        double sx = 0, sy = 0, sxx = 0, sxy = 0;
        int n = 0;
        for (int i = 0; i < g_nhw; i++) {
            if (g_hw[i].t - g_hw[0].t < 1000000000LL) continue;
            const double x = (g_hw[i].t - g_hw[0].t) / 1e9, y = (double)g_hw[i].hw;
            sx += x; sy += y; sxx += x * x; sxy += x * y; n++;
        }
        if (n > 10) printf("PROBE: 硬件实际消耗速率 %.2f 帧/秒\n", (n * sxy - sx * sy) / (n * sxx - sx * sx));
    }
    double *u = malloc(sizeof(double) * (g_nts + 1)), *d = malloc(sizeof(double) * (g_nhw + 1));
    double *lapp = malloc(sizeof(double) * (g_nts + 1));
    int nu = 0, hint = 0, jumps = 0;
    double prevU = 0, maxJump = 0, sliceV[4096];
    int slice = -1, ns = 0;
    printf("PROBE: 每秒：U 中位数（ms）\n  ");
    for (int k = 0; k < g_nts; k++) {
        const double hw = hw_at(g_ts[k].ts, &hint);
        if (hw < 0) continue;
        const double uk = (g_ts[k].pos - hw) * 1000.0 / rate;
        if (verbose && k % 40 == 0) {
            // 同一时刻（样本读取时 now）的 hw_ptr / appl_ptr：取 now 之前最后一条
            int j = hint;
            while (j + 1 < g_nhw && g_hw[j + 1].t <= g_ts[k].now) j++;
            printf("RAW: now %+8.1f ms · ts %+8.1f · pos %7lld · written %7lld · hw(ts) %9.1f · hw(now) %7lld · appl(now) %7lld\n",
                   (g_ts[k].now - t0) / 1e6, (g_ts[k].ts - t0) / 1e6, (long long)g_ts[k].pos,
                   (long long)g_ts[k].written, hw, (long long)g_hw[j].hw, (long long)g_hw[j].appl);
        }
        // 应用自己算出来的输出延迟 = 已写帧数 − 此刻按时间戳外推的已播帧数
        lapp[nu] = (g_ts[k].written - (g_ts[k].pos + (g_ts[k].now - g_ts[k].ts) * (double)rate / 1e9)) *
                   1000.0 / rate;
        if (nu > 0) {
            const double j = uk - prevU;
            if (j > 5 || j < -5) jumps++;
            if ((j < 0 ? -j : j) > (maxJump < 0 ? -maxJump : maxJump)) maxJump = j;
        }
        prevU = uk;
        u[nu++] = uk;
        const int sl = (int)((g_ts[k].ts - t0) / 1000000000LL);
        if (sl != slice) {
            if (ns > 0) { qsort(sliceV, ns, sizeof(double), cmp_d); printf("%.1f ", sliceV[ns / 2]); }
            slice = sl;
            ns = 0;
        }
        if (ns < 4096) sliceV[ns++] = uk;
    }
    if (ns > 0) { qsort(sliceV, ns, sizeof(double), cmp_d); printf("%.1f", sliceV[ns / 2]); }
    printf("\n");
    int nd = 0;
    for (int i = 0; i < g_nhw; i++) d[nd++] = (g_hw[i].appl - g_hw[i].hw) * 1000.0 / rate;
    qsort(d, nd, sizeof(double), cmp_d);
    printf("PROBE: ALSA 积压（ms，时间戳里一定没算进去的部分）min %.1f · 中位 %.1f · max %.1f\n", d[0], d[nd / 2], d[nd - 1]);
    if (nu < 10) { printf("RESULT: FAIL (有效时间戳样本只有 %d 个)\n", nu); return 1; }
    const int nl = nu;
    qsort(lapp, nl, sizeof(double), cmp_d);
    printf("PROBE: 应用按时间戳算出的输出延迟（ms）中位 %.1f · p5 %.1f · p95 %.1f\n", pct(lapp, nl, .5),
           pct(lapp, nl, .05), pct(lapp, nl, .95));
    qsort(u, nu, sizeof(double), cmp_d);
    printf("PROBE: 超前量 U（ms）min %.1f · p5 %.1f · 中位 %.1f · p95 %.1f · max %.1f · 跳变 >5ms %d 次 · 最大跳变 %+.1f\n",
           u[0], pct(u, nu, .05), pct(u, nu, .5), pct(u, nu, .95), u[nu - 1], jumps, maxJump);
    printf("PROBE: 流在跑时 status 不是 RUNNING %d 次 · hw_ptr 回退 %d 次\n", g_notRunning, g_hwBack);
    printf("RESULT: U_median=%.1f U_p5=%.1f U_p95=%.1f jumps=%d alsa_median=%.1f\n", pct(u, nu, .5),
           pct(u, nu, .05), pct(u, nu, .95), jumps, d[nd / 2]);
    return 0;
}

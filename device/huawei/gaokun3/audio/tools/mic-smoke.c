/* SPDX-License-Identifier: Apache-2.0 */
/*
 * gaokun3-mic-smoke —— 从【应用视角】对录音通路做冒烟测试（AAudio）。
 *
 * 为什么需要它：tinycap 走的是 ALSA，绕过了音频 HAL 与音频策略 —— #40 修好 ALSA 之后，
 * README 写了"麦克风已修"，而走 AudioRecord 的 App 一直录出 44 字节空文件（#127，Issue #9）。
 * AAudio 的普通模式（PERFORMANCE_MODE_NONE / SHARED）在内部就是 AudioRecord，与 App 同一条路
 * （AudioFlinger → 音频策略选剖面 → HAL → ALSA）；低延迟 + 独占会去试 MMAP。
 * 不需要解锁屏幕、不需要装应用。
 *
 * 用法（adb root 之后，push 到 /data/local/tmp）：
 *   gaokun3-mic-smoke [-r 采样率] [-c 声道数] [-p 预设] [-m none|lowlat] [-s shared|exclusive] [-t 秒] [-T [-k status]] [输出.wav]
 *     预设：generic（默认）| camcorder | recognition | communication | unprocessed | performance
 *   例：gaokun3-mic-smoke -r 44100 -c 1 -t 5 /data/local/tmp/m.wav        # 系统录音机那种请求
 *       gaokun3-mic-smoke -r 16000 -c 1 -p communication -t 5              # VoIP
 *
 * ⚠️ 用【回调】收数据，不用 AAudioStream_read()：普通模式下 read() 内部是 AudioRecord 的阻塞读，给的超时不起作用 ——
 *   2026-09-28 在原版 HAL 上实测：一帧数据都不来时它在 AudioRecord::obtainBuffer() 里一直等（App 录出 44 字节就是这样）。
 *   另有 alarm() 看门狗：停流 / 关流也卡住时打一行 "RESULT: FAIL (卡住 …)" 退出。
 *
 * 判据（最后一行 "RESULT: PASS" / "RESULT: FAIL (…)"）：
 *   * 读到的帧数至少是请求时长的 90%（空录音 = 0 帧）
 *   * 没有"静音洞"：所有声道连续 ≥ 20 ms 都【恰好为 0】。真实麦克风的底噪不可能 20 ms 精确为 0，
 *     这种洞只能是 HAL 插的静音（0052 修的那种：约每 8 块丢 1 块，一块 4096 帧 = 85 ms）
 *   * 【开头】的静音（第一个非零样本之前）单独报告、不算洞：2026-09-28 带 0051/0052 实测，每种请求都是开头恰好
 *     170.7 ms（= 2 块 × 4096 帧，logcat 里流刚起时两行 "inserting 4096 frames of silence"），之后 5 秒零洞。
 *     它是流启动时的事，和 Issue #9 那种中途周期性丢块不是一回事；整段全零仍然判 FAIL。
 *   * RMS 只判上限：5 秒平均高于 -8 dBFS 判 FAIL —— 真麦克风在房间里到不了；2026-09-28 原版 HAL 的 MMAP stub
 *     给的是满幅均匀随机数（-4.8 dBFS，理论值 20·log10(1/√3) = -4.77），帧数满、回调多，没有这一条就会判 PASS。
 *     下限不判（安静房间可以很低）
 * ⚠️ 隐私：录下的音频只在给了输出路径时才写文件；不给就只在内存里算完即丢。
 *
 * -T 计时（#127 §6，不出声）：录音期间每 1 ms 读一次 ALSA 的 status（-k，默认 /proc/asound/card0/pcm3c/sub0/status，
 *   要 CONFIG_SND_VERBOSE_PROCFS），记下 hw_ptr 何时前进；回调里记每块数据到达的时刻；每 5 ms 调一次 AAudioStream_getTimestamp。
 *   录完打几行 "TIMING:"：
 *   * 交付延迟 D = 回调时刻 − 该块最后一帧在 ALSA 里可读的时刻（hw_ptr 越过它的那一刻）—— 纯软件链路的积压；
 *   * 时间戳误差 E = AAudio 给的时刻 − 那一帧的真实采集时刻（按 hw_ptr 线性回推）—— App 看到的采集时刻偏了多少；
 *   * D、E 按时间切成 10 段各报中位数（卡顿之后积压有没有留下来，看后几段）；ADC 相对 CLOCK_MONOTONIC 的漂移；ALSA 积压（hw_ptr − appl_ptr）。
 *   流里第 F 帧对应硬件第 F − O(F) 帧，O(F) = F 之前 HAL 补进来的静音帧数（开头那段加上中途每个 ≥20 ms 的全零洞）——
 *   中途补一块静音，后面的帧就整体晚一块；只按开头算 O 的话，这一块会被抵消掉、看不出来。
 *   HAL 进程被 SIGSTOP 时，in_0 正阻塞在 pcm_read 里、已拷的那 L 帧（0 ≤ L < 4096）会被 proxy 的整块重读静默丢掉，
 *   不是零、数不出来 —— 之后 D / E 整体偏大 L/48 ms，那一组只能看洞数，不能看 D / E（审查 2026-09-28）。
 *   只有 48 kHz、不重采样的用例帧号对得上，其它用例只报 O 和起采时刻。
 *   这些都以 ALSA 的 DMA 时刻为基准，DSP / codec 流水线那一段静默测不出；但两份 HAL 之间的差不受它影响。
 */
#include <aaudio/AAudio.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdatomic.h>
#include <time.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const struct { const char *name; aaudio_input_preset_t v; } kPresets[] = {
    {"generic", AAUDIO_INPUT_PRESET_GENERIC},
    {"camcorder", AAUDIO_INPUT_PRESET_CAMCORDER},
    {"recognition", AAUDIO_INPUT_PRESET_VOICE_RECOGNITION},
    {"communication", AAUDIO_INPUT_PRESET_VOICE_COMMUNICATION},
    {"unprocessed", AAUDIO_INPUT_PRESET_UNPROCESSED},
    {"performance", AAUDIO_INPUT_PRESET_VOICE_PERFORMANCE},
};

// 回调把数据拷进这块缓冲；主线程只计时
static struct {
    int16_t *pcm;
    int64_t want;
    int ch;
    _Atomic int64_t got;
    _Atomic int callbacks;
    _Atomic aaudio_result_t error;
} g;

// -T 计时：回调到达、AAudio 时间戳、ALSA status 三组样本，录完再离线算
#define MAX_CB 65536
#define MAX_TS 32768
#define MAX_HW 65536
static int g_timing;
static struct { int64_t t, f0; int32_t n; } g_cb[MAX_CB];
static _Atomic int g_ncb;
static struct { int64_t now, pos, ts; } g_ts[MAX_TS];
static int g_nts;
static struct { int64_t now, tstamp, hw, appl; } g_hw[MAX_HW];
static int g_nhw;
static int64_t g_trigger = -1;

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

// status 里 "键: 数字" 或 "键: 秒.纳秒"；找不到返回 -1
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
    long long ns = strtoll(e + 1, NULL, 10);
    return sec * 1000000000LL + ns;
}

// 读一次 status；RUNNING 且 hw_ptr 变了就记一条。返回 -1 = 文件打不开
static int poll_status(const char *path) {
    char buf[1024];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    const int64_t t = now_ns();
    close(fd);
    if (n <= 0) return 0;
    buf[n] = 0;
    if (!strstr(buf, "RUNNING")) return 0;
    if (g_trigger < 0) g_trigger = kv_time(buf, "trigger_time");
    const int64_t hw = kv_int(buf, "hw_ptr"), appl = kv_int(buf, "appl_ptr");
    if (hw < 0 || g_nhw >= MAX_HW || (g_nhw > 0 && g_hw[g_nhw - 1].hw == hw)) return 0;
    g_hw[g_nhw].now = t;
    g_hw[g_nhw].tstamp = kv_time(buf, "tstamp");
    g_hw[g_nhw].hw = hw;
    g_hw[g_nhw].appl = appl;
    g_nhw++;
    return 0;
}

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
// 排好序的数组的 min / median / max
static void mmm(double *v, int n, const char *what, const char *unit) {
    if (n <= 0) { printf("TIMING: %s：没有样本\n", what); return; }
    qsort(v, (size_t)n, sizeof(double), cmp_d);
    printf("TIMING: %s min / median / max = %.1f / %.1f / %.1f %s（%d 个）\n", what, v[0], v[n / 2], v[n - 1], unit, n);
}

// hw 样本的时刻：status 的 tstamp 合理就用它（上一次 hw_ptr 更新的时刻），否则用读到它的时刻
static int64_t hw_time(int j) {
    const int64_t ts = g_hw[j].tstamp, now = g_hw[j].now;
    return ts > 0 && ts <= now + 1000000 && now - ts < 50000000 ? ts : now;
}
// 第一条 hw_ptr >= h 的样本；没有返回 -1
static int hw_find(int64_t h) {
    int lo = 0, hi = g_nhw - 1, ans = -1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (g_hw[mid].hw >= h) { ans = mid; hi = mid - 1; } else lo = mid + 1;
    }
    return ans;
}

static const int64_t *g_holeStart, *g_holeLen;
static int g_nholes;
static int64_t g_lead;
// 流第 p 帧之前 HAL 补进来的静音帧数；p 落在洞里返回 -1（那是补的零，不对应任何硬件帧）
static int64_t offset_at(int64_t p) {
    int64_t o = g_lead > 0 ? g_lead : 0;
    if (p < o) return -1;
    for (int i = 0; i < g_nholes; i++) {
        if (g_holeStart[i] >= p) break;
        if (p < g_holeStart[i] + g_holeLen[i]) return -1;
        o += g_holeLen[i];
    }
    return o;
}
// 10 段中位数：t[] 为时刻，v[] 为值
static void windows(const int64_t *t, const double *v, int n, const char *what) {
    if (n < 10) return;
    int64_t t0 = t[0], t1 = t[0];
    for (int i = 0; i < n; i++) { if (t[i] < t0) t0 = t[i]; if (t[i] > t1) t1 = t[i]; }
    static double w[MAX_TS > MAX_CB ? MAX_TS : MAX_CB];
    printf("TIMING: %s 分 10 段中位数（ms，每段 %.1f s）：", what, (t1 - t0) / 1e9 / 10);
    for (int k = 0; k < 10; k++) {
        const int64_t a = t0 + (t1 - t0) * k / 10, b = t0 + (t1 - t0) * (k + 1) / 10;
        int m = 0;
        for (int i = 0; i < n; i++) if (t[i] >= a && (t[i] < b || (k == 9 && t[i] <= b))) w[m++] = v[i];
        if (m == 0) { printf(" -"); continue; }
        qsort(w, (size_t)m, sizeof(double), cmp_d);
        printf(" %.1f", w[m / 2]);
    }
    printf("\n");
}

static void report_timing(const int16_t *pcm, int64_t got, int arate, int ach, int64_t lead, int64_t tReq,
                          const char *hwParams, int statusOk, const char *statusPath) {
    if (!statusOk || g_nhw == 0) {
        printf("TIMING: ⚠️ 没有 ALSA status 样本（%s %s），只报回调时刻\n", statusPath, statusOk ? "没见到 RUNNING" : "打不开");
    } else {
        printf("TIMING: %s\n", hwParams[0] ? hwParams : "（没读到 hw_params）");
    }
    const int ncb = atomic_load(&g_ncb) < MAX_CB ? atomic_load(&g_ncb) : MAX_CB;
    // 起采脉冲：声道 0 连续 >=16 帧 |x| >= 32000
    int64_t pulse = -1;
    for (int64_t i = 0, run = 0; i < got; i++) {
        run = abs(pcm[i * ach]) >= 32000 ? run + 1 : 0;
        if (run >= 16) { pulse = i - 15; break; }
    }
    const int64_t O = lead > 0 ? lead : 0;
    int64_t Oend = O;
    for (int i = 0; i < g_nholes; i++) Oend += g_holeLen[i];
    printf("TIMING: 偏移 O = %lld 帧（开头补的静音）→ 末尾 %lld 帧（加上中途 %d 个洞）· 起采脉冲在第 %lld 帧\n", (long long)O,
           (long long)Oend, g_nholes, (long long)pulse);
    // trigger_time 与 CLOCK_MONOTONIC 同一个钟才有意义（tinyalsa 用 PCM_MONOTONIC 打开）；差出 10 秒就当不是
    if (g_trigger > 0 && llabs(g_trigger - tReq) > 10000000000LL) {
        printf("TIMING: ⚠️ trigger_time 不像 CLOCK_MONOTONIC（差 %.1f s），不用它\n", (g_trigger - tReq) / 1e9);
        g_trigger = -1;
    }
    if (g_trigger > 0) printf("TIMING: requestStart → ALSA trigger %.1f ms\n", (g_trigger - tReq) / 1e6);
    if (g_nhw > 0 && g_trigger > 0) {
        const int j1 = hw_find(1);
        if (j1 < 0) printf("TIMING: 没见到 hw_ptr 前进\n");
        else printf("TIMING: trigger → hw_ptr 第一次前进 %.1f ms（到 %lld 帧；含硬件起采与 DSP 交付第一个 period，分不开）\n",
                    (hw_time(j1) - g_trigger) / 1e6, (long long)g_hw[j1].hw);
    }
    if (ncb > 0) {
        int real = -1;
        for (int i = 0; i < ncb; i++) if (g_cb[i].f0 + g_cb[i].n > O) { real = i; break; }
        printf("TIMING: requestStart → 第一次回调 %.1f ms · → 第一次含真实数据的回调 %.1f ms\n",
               (g_cb[0].t - tReq) / 1e6, real >= 0 ? (g_cb[real].t - tReq) / 1e6 : -1.0);
    }
    if (g_nhw == 0) return;
    if (arate != 48000) {
        printf("TIMING: %d Hz 的流经过重采样，帧号和硬件对不上，不算 D / E\n", arate);
        return;
    }
    const double fs = 48000.0;
    static double v[MAX_TS > MAX_CB ? MAX_TS : MAX_CB];
    static int64_t vt[MAX_TS > MAX_CB ? MAX_TS : MAX_CB];
    int n = 0;
    for (int i = 0; i < ncb; i++) {
        const int64_t p = g_cb[i].f0 + g_cb[i].n - 1, o = offset_at(p);   // 这块最后一帧
        const int64_t h = o >= 0 ? p - o + 1 : 0;
        const int j = h >= 1 ? hw_find(h) : -1;
        if (j >= 0) { vt[n] = g_cb[i].t; v[n++] = (g_cb[i].t - hw_time(j)) / 1e6; }
    }
    windows(vt, v, n, "交付延迟 D");
    mmm(v, n, "交付延迟 D（回调时刻 − 该块最后一帧在 ALSA 可读的时刻）", "ms");
    n = 0;
    for (int i = 0; i < g_nts; i++) {
        const int64_t p = g_ts[i].pos - 1, o = offset_at(p);
        const int64_t h = o >= 0 ? p - o + 1 : 0;
        const int j = h >= 1 ? hw_find(h) : -1;
        if (j < 0 || g_ts[i].ts <= 0) continue;
        const double capNs = hw_time(j) - (g_hw[j].hw - h) * 1e9 / fs;
        vt[n] = g_ts[i].now;
        v[n++] = (g_ts[i].ts - capNs) / 1e6;
    }
    windows(vt, v, n, "时间戳误差 E");
    mmm(v, n, "时间戳误差 E（AAudio 时间戳 − 真实采集时刻）", "ms");
    // 漂移：跳过第 1 秒，hw_ptr 对时刻做最小二乘
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    int m = 0;
    int64_t maxBacklog = -1;
    for (int j = 0; j < g_nhw; j++) {
        if (g_hw[j].appl >= 0 && g_hw[j].hw - g_hw[j].appl > maxBacklog) maxBacklog = g_hw[j].hw - g_hw[j].appl;
        const double x = (hw_time(j) - hw_time(0)) / 1e9, y = (double)g_hw[j].hw;
        if (x < 1) continue;
        sx += x; sy += y; sxx += x * x; sxy += x * y; m++;
    }
    if (m > 10 && sxx * m - sx * sx > 0) {
        const double slope = (sxy * m - sx * sy) / (sxx * m - sx * sx);
        const double icpt = (sy - slope * sx) / m, Sxx = sxx - sx * sx / m;
        double sse = 0;
        for (int j = 0; j < g_nhw; j++) {   // 第二遍算残差，求斜率的标准误
            const double x = (hw_time(j) - hw_time(0)) / 1e9;
            if (x < 1) continue;
            const double res = (double)g_hw[j].hw - (icpt + slope * x);
            sse += res * res;
        }
        const double se = Sxx > 0 ? sqrt(sse / (m - 2) / Sxx) / fs * 1e6 : 0;
        printf("TIMING: ADC 相对 CLOCK_MONOTONIC %+.0f ± %.0f ppm（%d 个样本，跨 %.1f 秒）%s\n", (slope / fs - 1) * 1e6, se, m,
               (hw_time(g_nhw - 1) - hw_time(0)) / 1e9, se > 20 ? "—— 跨度太短，只当噪声看" : "");
    }
    printf("TIMING: ALSA 积压（hw_ptr − appl_ptr）最大 %lld 帧 · hw 样本 %d 个 · 时间戳样本 %d 个\n", (long long)maxBacklog, g_nhw, g_nts);
    // ALSA 积压随时间：卡顿之后留下的延迟在 ALSA 里（写端没读走）还是在 HAL 下游，看它回没回到平时的水平
    n = 0;
    for (int j = 0; j < g_nhw && n < MAX_CB; j++)
        if (g_hw[j].appl >= 0) { vt[n] = hw_time(j); v[n++] = (g_hw[j].hw - g_hw[j].appl) * 1000.0 / fs; }
    windows(vt, v, n, "ALSA 积压");
}

static aaudio_data_callback_result_t on_data(AAudioStream *s, void *user, void *audio, int32_t n) {
    (void)s; (void)user;
    int64_t got = atomic_load(&g.got);
    int64_t take = g.want - got < n ? g.want - got : n;
    if (g_timing && take > 0) {
        int i = atomic_fetch_add(&g_ncb, 1);
        if (i < MAX_CB) { g_cb[i].t = now_ns(); g_cb[i].f0 = got; g_cb[i].n = (int32_t)take; }
    }
    if (take > 0) {
        memcpy(g.pcm + got * g.ch, audio, (size_t)take * g.ch * sizeof(int16_t));
        atomic_store(&g.got, got + take);
    }
    atomic_fetch_add(&g.callbacks, 1);
    return atomic_load(&g.got) >= g.want ? AAUDIO_CALLBACK_RESULT_STOP : AAUDIO_CALLBACK_RESULT_CONTINUE;
}

static void on_error(AAudioStream *s, void *user, aaudio_result_t e) {
    (void)s; (void)user;
    atomic_store(&g.error, e);
}

static void on_alarm(int sig) {
    (void)sig;
    static const char m[] = "RESULT: FAIL (卡住：停流 / 关流没有返回)\n";
    ssize_t w = write(1, m, sizeof(m) - 1);
    (void)w;
    _exit(3);
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
static void put16(uint8_t *p, uint16_t v) { p[0] = v; p[1] = v >> 8; }

static int write_wav(const char *path, const int16_t *pcm, int64_t frames, int rate, int ch) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
    uint32_t data = (uint32_t)(frames * ch * 2);
    uint8_t h[44];
    memcpy(h, "RIFF", 4); put32(h + 4, 36 + data); memcpy(h + 8, "WAVEfmt ", 8);
    put32(h + 16, 16); put16(h + 20, 1); put16(h + 22, ch); put32(h + 24, rate);
    put32(h + 28, rate * ch * 2); put16(h + 32, ch * 2); put16(h + 34, 16);
    memcpy(h + 36, "data", 4); put32(h + 40, data);
    int ok = fwrite(h, 1, 44, f) == 44 && fwrite(pcm, 2, (size_t)frames * ch, f) == (size_t)frames * ch;
    fclose(f);
    return ok ? 0 : -1;
}

int main(int argc, char **argv) {
    int rate = 48000, ch = 2, seconds = 5, opt;
    aaudio_input_preset_t preset = AAUDIO_INPUT_PRESET_GENERIC;
    aaudio_performance_mode_t perf = AAUDIO_PERFORMANCE_MODE_NONE;
    aaudio_sharing_mode_t sharing = AAUDIO_SHARING_MODE_SHARED;
    const char *presetName = "generic";
    const char *statusPath = "/proc/asound/card0/pcm3c/sub0/status";
    while ((opt = getopt(argc, argv, "r:c:p:m:s:t:Tk:h")) != -1) {
        switch (opt) {
        case 'r': rate = atoi(optarg); break;
        case 'c': ch = atoi(optarg); break;
        case 't': seconds = atoi(optarg); break;
        case 'T': g_timing = 1; break;
        case 'k': statusPath = optarg; break;
        case 'p': {
            size_t i;
            for (i = 0; i < sizeof(kPresets) / sizeof(kPresets[0]); i++)
                if (!strcmp(optarg, kPresets[i].name)) { preset = kPresets[i].v; presetName = kPresets[i].name; break; }
            if (i == sizeof(kPresets) / sizeof(kPresets[0])) { fprintf(stderr, "不认识的预设 %s\n", optarg); return 1; }
            break;
        }
        case 'm': perf = !strcmp(optarg, "lowlat") ? AAUDIO_PERFORMANCE_MODE_LOW_LATENCY : AAUDIO_PERFORMANCE_MODE_NONE; break;
        case 's': sharing = !strcmp(optarg, "exclusive") ? AAUDIO_SHARING_MODE_EXCLUSIVE : AAUDIO_SHARING_MODE_SHARED; break;
        default:
            fprintf(stderr, "用法：%s [-r 采样率] [-c 声道数] [-p 预设] [-m none|lowlat] [-s shared|exclusive] [-t 秒] [-T [-k status]] [输出.wav]\n", argv[0]);
            return opt == 'h' ? 0 : 1;
        }
    }
    const char *out = optind < argc ? argv[optind] : NULL;
    if (rate <= 0 || ch < 1 || ch > 2 || seconds < 1 || seconds > 120) { fprintf(stderr, "参数不对\n"); return 1; }

    printf("请求：%d Hz · %d 声道 · 预设 %s · %s · %s · %d 秒\n", rate, ch, presetName,
           perf == AAUDIO_PERFORMANCE_MODE_LOW_LATENCY ? "低延迟" : "普通",
           sharing == AAUDIO_SHARING_MODE_EXCLUSIVE ? "独占" : "共享", seconds);

    AAudioStreamBuilder *b = NULL;
    AAudioStream *s = NULL;
    aaudio_result_t r = AAudio_createStreamBuilder(&b);
    if (r != AAUDIO_OK) { printf("RESULT: FAIL (createStreamBuilder: %s)\n", AAudio_convertResultToText(r)); return 1; }
    AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_INPUT);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSampleRate(b, rate);
    AAudioStreamBuilder_setChannelCount(b, ch);
    AAudioStreamBuilder_setInputPreset(b, preset);
    AAudioStreamBuilder_setPerformanceMode(b, perf);
    AAudioStreamBuilder_setSharingMode(b, sharing);
    AAudioStreamBuilder_setDataCallback(b, on_data, NULL);
    AAudioStreamBuilder_setErrorCallback(b, on_error, NULL);
    signal(SIGALRM, on_alarm);
    alarm(seconds + 20);
    r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) { printf("RESULT: FAIL (openStream: %s)\n", AAudio_convertResultToText(r)); return 1; }

    const int arate = AAudioStream_getSampleRate(s), ach = AAudioStream_getChannelCount(s);
    printf("实际：%d Hz · %d 声道 · %s · %s · burst %d 帧\n", arate, ach,
           AAudioStream_getPerformanceMode(s) == AAUDIO_PERFORMANCE_MODE_LOW_LATENCY ? "低延迟" : "普通",
           AAudioStream_getSharingMode(s) == AAUDIO_SHARING_MODE_EXCLUSIVE ? "独占" : "共享",
           AAudioStream_getFramesPerBurst(s));
    if (arate != rate || ach != ch) {
        // AAudio 普通模式在客户端这一侧重采样 / 转声道，照理拿到的就是请求的；不一样就照实际的算
        printf("⚠️ 实际参数与请求不同，按实际参数统计\n");
    }

    const int64_t want = (int64_t)arate * seconds;
    int16_t *pcm = calloc((size_t)want * ach, sizeof(int16_t));
    if (!pcm) { printf("RESULT: FAIL (内存)\n"); return 1; }
    g.pcm = pcm; g.want = want; g.ch = ach;
    const int64_t tReq = now_ns();
    r = AAudioStream_requestStart(s);
    if (r != AAUDIO_OK) { printf("RESULT: FAIL (requestStart: %s)\n", AAudio_convertResultToText(r)); return 1; }

    // 等到收满，或者超过请求时长 3 秒（一帧都不来时就在这里等满时长）
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int statusOk = 1, loops = 0;
    char hwParams[256] = "";
    for (;;) {
        if (g_timing) {
            usleep(1000);
            if (statusOk && poll_status(statusPath) < 0) statusOk = 0;
            if (++loops % 5 == 0 && g_nts < MAX_TS) {
                int64_t pos, ts;
                if (AAudioStream_getTimestamp(s, CLOCK_MONOTONIC, &pos, &ts) == AAUDIO_OK) {
                    g_ts[g_nts].now = now_ns(); g_ts[g_nts].pos = pos; g_ts[g_nts].ts = ts; g_nts++;
                }
            }
            if (!hwParams[0] && g_nhw > 0) {   // 流跑起来以后读一次 hw_params（同目录）
                char path[256];
                snprintf(path, sizeof(path), "%s", statusPath);
                char *slash = strrchr(path, '/');
                if (slash) {
                    snprintf(slash + 1, sizeof(path) - (size_t)(slash + 1 - path), "hw_params");
                    FILE *f = fopen(path, "r");
                    char line[128];
                    size_t used = 0;
                    while (f && fgets(line, sizeof(line), f))
                        if (strstr(line, "period_size") || strstr(line, "buffer_size")) {
                            line[strcspn(line, "\n")] = 0;
                            if (used + 1 >= sizeof(hwParams)) break;
                            int w = snprintf(hwParams + used, sizeof(hwParams) - used, "%s%s", used ? " · " : "", line);
                            if (w < 0) break;
                            used += (size_t)w;
                            if (used >= sizeof(hwParams)) used = sizeof(hwParams) - 1;
                        }
                    if (f) fclose(f);
                    if (!hwParams[0]) snprintf(hwParams, sizeof(hwParams), "（读不到 %s）", path);
                }
            }
        } else {
            usleep(100000);
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        double el = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
        if (atomic_load(&g.got) >= want || el > seconds + 3 || atomic_load(&g.error) != AAUDIO_OK) break;
    }
    AAudioStream_requestStop(s);
    AAudioStream_close(s);
    alarm(0);
    const int64_t got = atomic_load(&g.got);
    if (atomic_load(&g.error) != AAUDIO_OK) printf("⚠️ 错误回调：%s\n", AAudio_convertResultToText(atomic_load(&g.error)));
    printf("数据回调 %d 次\n", atomic_load(&g.callbacks));
    if (got == 0) printf("⚠️ 一帧都没收到 —— App 录出来的就是 44 字节（只有 WAV 头）的空文件\n");

    // RMS、开头静音（第一个非零样本之前）与"静音洞"（之后所有声道连续恰好为 0）
    static struct { int64_t start, len; } holeList[1024];
    int nHoleList = 0;
    double sum = 0;
    int64_t lead = -1, zeroRun = 0, holes = 0, holeFrames = 0, longest = 0;
    const int64_t holeMin = arate / 50;   // 20 ms
    for (int64_t i = 0; i < got; i++) {
        int allZero = 1;
        for (int c = 0; c < ach; c++) {
            int v = pcm[i * ach + c];
            sum += (double)v * v;
            if (v) allZero = 0;
        }
        if (allZero) {
            zeroRun++;
        } else {
            if (lead < 0) lead = zeroRun;
            else if (zeroRun >= holeMin) {
                holes++; holeFrames += zeroRun; if (zeroRun > longest) longest = zeroRun;
                if (nHoleList < 1024) { holeList[nHoleList].start = i - zeroRun; holeList[nHoleList].len = zeroRun; nHoleList++; }
            }
            zeroRun = 0;
        }
    }
    if (lead >= 0 && zeroRun >= holeMin) { holes++; holeFrames += zeroRun; if (zeroRun > longest) longest = zeroRun; }
    const double rms = got ? sqrt(sum / ((double)got * ach)) : 0;
    const double dbfs = rms > 0 ? 20 * log10(rms / 32768.0) : -INFINITY;
    const double leadMs = lead > 0 ? 1000.0 * lead / arate : 0;
    printf("读到 %lld / %lld 帧（%.2f 秒），RMS %.0f = %.1f dBFS\n", (long long)got, (long long)want,
           (double)got / arate, rms, dbfs);
    if (got && lead < 0) printf("⚠️ 整段都是 0（HAL 只给了静音）\n");
    else if (got) printf("开头静音 %.1f ms；之后的静音洞（≥20 ms 全零）：%lld 个，共 %.1f%%，最长 %.1f ms\n", leadMs,
                (long long)holes, got ? 100.0 * holeFrames / got : 0.0, 1000.0 * longest / arate);

    if (g_timing) {
        static int64_t hs[1024], hl[1024];
        for (int i = 0; i < nHoleList; i++) { hs[i] = holeList[i].start; hl[i] = holeList[i].len; }
        g_holeStart = hs; g_holeLen = hl; g_nholes = nHoleList; g_lead = lead;
        report_timing(pcm, got, arate, ach, lead, tReq, hwParams, statusOk, statusPath);
    }

    if (out) {
        if (write_wav(out, pcm, got, arate, ach) == 0) printf("写出 %s（%lld 字节）\n", out, (long long)(44 + got * ach * 2));
        else printf("⚠️ 写不出 %s\n", out);
    }
    free(pcm);

    if (got < want * 9 / 10) { printf("RESULT: FAIL (只读到 %.0f%%)\n", 100.0 * got / want); return 2; }
    if (lead < 0) { printf("RESULT: FAIL (整段全零)\n"); return 2; }
    if (dbfs > -8) { printf("RESULT: FAIL (RMS %.1f dBFS，像随机数而不是麦克风)\n", dbfs); return 2; }
    if (holes) { printf("RESULT: FAIL (%lld 个静音洞)\n", (long long)holes); return 2; }
    printf("RESULT: PASS (开头静音 %.0f ms)\n", leadMs);
    return 0;
}

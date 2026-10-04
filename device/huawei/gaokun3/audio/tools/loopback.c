/* SPDX-License-Identifier: Apache-2.0 */
/*
 * gaokun3-loopback —— 声学回环：扬声器放咔哒声、内置麦克风录回来，量【应用时间戳预测的出声时刻】与【麦克风实际收到的时刻】之差。
 *
 * 为什么需要它：gaokun3-play-probe（不出声）只能拿 ALSA hw_ptr 当基准，而 audioreach 的 DSP 会预读，hw_ptr 领先真实出声，
 * DSP / codec 那一段测不出（#130 §2）。音游关心的是"声音什么时候真的出来"，这只能靠声学回环。
 * ⚠️ 会出声：每 -i 毫秒一声 2 ms 的 3 kHz 短音，默认 -24 dBFS。宿舍环境，要有人在场、同意才跑。
 *
 * 用法（adb root 之后，push 到 /data/local/tmp）：
 *   gaokun3-loopback [-t 秒] [-a dBFS] [-i 间隔ms] [-m none|lowlat] [-u game|media] [-v 打印原始时间戳]
 *
 * 做法：输出流（AAudio 共享）在回调里按帧号放咔哒声，第 k 声在应用帧 F_k；输入流（48 kHz 双声道，只取左声道）把麦克风样本按帧号存下来。
 *   主循环每 5 ms 取一次两个流的 AAudioStream_getTimestamp(CLOCK_MONOTONIC)。录完离线算：
 *   * 预测出声时刻 P_k：用帧号离 F_k 最近的那个输出时间戳样本线性外推（应用就是这么算"这一帧什么时候出声"的）；
 *   * 实际收到时刻 R_k：在麦克风数据里用咔哒声模板做互相关找峰值（搜 P_k 前 100 ms 到后 400 ms），峰值帧号按输入时间戳换成时刻；
 *   * e_k = R_k − P_k。e 的【绝对值】还含着采集方向时间戳自己的误差（#127 §7 实测约 21 ms）和几厘米的声程（< 0.5 ms），
 *     所以只当参考；e 在一次运行里、多次运行之间、卡顿前后【稳不稳】才是判据 —— 音游校准一次偏移，之后要它不变。
 *   * 峰值 / 窗内中位数 < 8 的咔哒声判为没检测到（太轻或被噪声盖住），不计入。
 * 最后一行 "RESULT: e_median=… e_p5=… e_p95=… detected=n/N"。
 */
#include <aaudio/AAudio.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define RATE 48000
#define CLICK_LEN 96  // 2 ms
#define MAX_TS 100000
#define MAX_CLICKS 4096

static float g_tmpl[CLICK_LEN];
static int16_t g_click[CLICK_LEN];
static int64_t g_interval = RATE / 2, g_offset = RATE / 5;  // 第一声在 200 ms
static int64_t g_outFrames;                                  // 输出回调写过的帧数（只在回调线程里改）
static int16_t *g_mic;
static int64_t g_micCap, g_micFrames;
struct tsamp { int64_t pos, ts; };
static struct tsamp g_tsOut[MAX_TS], g_tsIn[MAX_TS];
static int g_nOut, g_nIn;

static int64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static aaudio_data_callback_result_t on_out(AAudioStream *s, void *u, void *data, int32_t n) {
    (void)s; (void)u;
    int16_t *o = data;
    memset(o, 0, (size_t)n * 2 * sizeof(int16_t));
    for (int32_t i = 0; i < n; i++) {
        const int64_t f = g_outFrames + i - g_offset;
        if (f < 0) continue;
        const int64_t ph = f % g_interval;
        if (ph < CLICK_LEN) o[2 * i] = o[2 * i + 1] = g_click[ph];
    }
    g_outFrames += n;
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

static aaudio_data_callback_result_t on_in(AAudioStream *s, void *u, void *data, int32_t n) {
    (void)s; (void)u;
    const int16_t *in = data;
    for (int32_t i = 0; i < n && g_micFrames < g_micCap; i++) g_mic[g_micFrames++] = in[2 * i];
    return AAUDIO_CALLBACK_RESULT_CONTINUE;
}

// 用帧号离 f 最近的时间戳样本，把帧号换成 CLOCK_MONOTONIC 时刻（ns）；没有样本返回 -1
static double frame_to_ns(const struct tsamp *a, int n, double f) {
    int best = -1;
    double bd = 0;
    for (int i = 0; i < n; i++) {
        const double d = fabs((double)a[i].pos - f);
        if (best < 0 || d < bd) { best = i; bd = d; }
    }
    if (best < 0) return -1;
    return (double)a[best].ts + (f - (double)a[best].pos) * 1e9 / RATE;
}
static double ns_to_frame(const struct tsamp *a, int n, double t) {
    int best = -1;
    double bd = 0;
    for (int i = 0; i < n; i++) {
        const double d = fabs((double)a[i].ts - t);
        if (best < 0 || d < bd) { best = i; bd = d; }
    }
    if (best < 0) return -1;
    return (double)a[best].pos + (t - (double)a[best].ts) * RATE / 1e9;
}

// 输入（麦克风）方向：采集时间戳按块更新、每个样本各自抖 ±20 ms 左右 ⇒ 不用"最近的样本"，
// 而用时刻 t 前后 1 s 内的样本做最小二乘（ts = c0 + c1·pos），既平掉块状抖动、又跟得上 1 s 以上的真实跳变。
// 输出方向不这样做：卡顿后输出时间戳的跳变正是要量的东西，拟合会把它抹平。
static int fit_in(double t, double *c0, double *c1) {
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    int n = 0;
    for (int i = 0; i < g_nIn; i++) {
        if (fabs((double)g_tsIn[i].ts - t) > 1e9) continue;
        const double x = (double)g_tsIn[i].pos, y = (double)g_tsIn[i].ts;
        sx += x; sy += y; sxx += x * x; sxy += x * y; n++;
    }
    if (n < 10) return -1;
    const double den = n * sxx - sx * sx;
    if (den <= 0) return -1;
    *c1 = (n * sxy - sx * sy) / den;
    *c0 = (sy - *c1 * sx) / n;
    return 0;
}

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

static AAudioStream *open_stream(aaudio_direction_t dir, int lowlat, int game, AAudioStream_dataCallback cb) {
    AAudioStreamBuilder *b;
    AAudioStream *s = NULL;
    if (AAudio_createStreamBuilder(&b) != AAUDIO_OK) return NULL;
    AAudioStreamBuilder_setDirection(b, dir);
    AAudioStreamBuilder_setSampleRate(b, RATE);
    AAudioStreamBuilder_setChannelCount(b, 2);
    AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
    AAudioStreamBuilder_setPerformanceMode(b, lowlat ? AAUDIO_PERFORMANCE_MODE_LOW_LATENCY
                                                     : AAUDIO_PERFORMANCE_MODE_NONE);
    if (dir == AAUDIO_DIRECTION_OUTPUT)
        AAudioStreamBuilder_setUsage(b, game ? AAUDIO_USAGE_GAME : AAUDIO_USAGE_MEDIA);
    else
        AAudioStreamBuilder_setInputPreset(b, AAUDIO_INPUT_PRESET_UNPROCESSED);
    AAudioStreamBuilder_setDataCallback(b, cb, NULL);
    aaudio_result_t r = AAudioStreamBuilder_openStream(b, &s);
    AAudioStreamBuilder_delete(b);
    if (r != AAUDIO_OK) {
        printf("RESULT: FAIL (open %s: %s)\n", dir == AAUDIO_DIRECTION_OUTPUT ? "output" : "input",
               AAudio_convertResultToText(r));
        return NULL;
    }
    return s;
}

int main(int argc, char **argv) {
    int secs = 10, lowlat = 0, game = 1, verbose = 0, opt;
    setvbuf(stdout, NULL, _IOLBF, 0);  // 崩了也不丢已经打印的行
    double dbfs = -24;
    while ((opt = getopt(argc, argv, "t:a:i:m:u:v")) != -1) {
        switch (opt) {
            case 't': secs = atoi(optarg); break;
            case 'a': dbfs = atof(optarg); break;
            case 'i': g_interval = (int64_t)atoi(optarg) * RATE / 1000; break;
            case 'm': lowlat = !strcmp(optarg, "lowlat"); break;
            case 'u': game = !strcmp(optarg, "game"); break;
            case 'v': verbose = 1; break;
            default:
                fprintf(stderr, "用法：%s [-t 秒] [-a dBFS] [-i 间隔ms] [-m none|lowlat] [-u game|media]\n", argv[0]);
                return 2;
        }
    }
    if (dbfs > -6) dbfs = -6;  // 别太响
    const double amp = 32767.0 * pow(10.0, dbfs / 20.0);
    for (int i = 0; i < CLICK_LEN; i++) {
        const double w = 0.5 - 0.5 * cos(2 * M_PI * i / (CLICK_LEN - 1));  // Hann
        g_tmpl[i] = (float)(w * sin(2 * M_PI * 3000.0 * i / RATE));
        g_click[i] = (int16_t)lrint(amp * g_tmpl[i]);
    }
    g_micCap = (int64_t)(secs + 2) * RATE;
    g_mic = calloc((size_t)g_micCap, sizeof(int16_t));

    AAudioStream *in = open_stream(AAUDIO_DIRECTION_INPUT, lowlat, game, on_in);
    AAudioStream *out = open_stream(AAUDIO_DIRECTION_OUTPUT, lowlat, game, on_out);
    if (!in || !out) return 1;
    printf("LOOP: 输出 burst %d · buffer %d 帧 · 输入 burst %d · 咔哒 %.0f dBFS、每 %lld ms\n",
           AAudioStream_getFramesPerBurst(out), AAudioStream_getBufferSizeInFrames(out),
           AAudioStream_getFramesPerBurst(in), dbfs, (long long)(g_interval * 1000 / RATE));
    AAudioStream_requestStart(in);
    usleep(300000);  // 让采集先跑起来
    AAudioStream_requestStart(out);
    const int64_t tEnd = now_ns() + (int64_t)secs * 1000000000LL;
    while (now_ns() < tEnd) {
        int64_t p, t;
        if (g_nOut < MAX_TS && AAudioStream_getTimestamp(out, CLOCK_MONOTONIC, &p, &t) == AAUDIO_OK) {
            g_tsOut[g_nOut].pos = p; g_tsOut[g_nOut].ts = t; g_nOut++;
        }
        if (g_nIn < MAX_TS && AAudioStream_getTimestamp(in, CLOCK_MONOTONIC, &p, &t) == AAUDIO_OK) {
            g_tsIn[g_nIn].pos = p; g_tsIn[g_nIn].ts = t; g_nIn++;
        }
        usleep(5000);
    }
    AAudioStream_requestStop(out);
    usleep(500000);  // 最后一声还在路上
    AAudioStream_requestStop(in);
    AAudioStream_close(out);
    AAudioStream_close(in);
    printf("LOOP: 输出写了 %lld 帧 · 麦克风收了 %lld 帧 · 时间戳样本 输出 %d / 输入 %d\n",
           (long long)g_outFrames, (long long)g_micFrames, g_nOut, g_nIn);
    if (g_nOut < 10 || g_nIn < 10 || g_micFrames < RATE) { printf("RESULT: FAIL (样本不够)\n"); return 1; }
    if (verbose) {
        // 原始时间戳：每个样本的 (pos, ts) 与 "ts − pos/RATE"（同一条直线上的样本这个值应当不变）
        for (int i = 0; i < g_nOut; i += g_nOut / 12 + 1)
            printf("RAW out %5d: pos %8lld ts %.3f s  起点 %.3f s\n", i, (long long)g_tsOut[i].pos,
                   g_tsOut[i].ts / 1e9, (g_tsOut[i].ts - g_tsOut[i].pos * 1e9 / RATE) / 1e9);
        for (int i = 0; i < g_nIn; i += g_nIn / 12 + 1)
            printf("RAW in  %5d: pos %8lld ts %.3f s  起点 %.3f s\n", i, (long long)g_tsIn[i].pos,
                   g_tsIn[i].ts / 1e9, (g_tsIn[i].ts - g_tsIn[i].pos * 1e9 / RATE) / 1e9);
    }

    double e[MAX_CLICKS];
    int ne = 0, nclicks = 0;
    double *corr = malloc(sizeof(double) * (RATE / 2 + CLICK_LEN));
    printf("LOOP: 每声 e（ms，按时间顺序）：\n  ");
    for (int64_t k = 0;; k++) {
        const int64_t F = g_offset + k * g_interval;
        if (F + CLICK_LEN > g_outFrames || nclicks >= MAX_CLICKS) break;
        nclicks++;
        const double P = frame_to_ns(g_tsOut, g_nOut, (double)F);
        // 窗口两端用同一个时间戳样本换算（离 P 最近的那个），宽度固定 500 ms
        double c0, c1, gc;
        if (fit_in(P, &c0, &c1) == 0) gc = (P - c0) / c1;
        else gc = ns_to_frame(g_tsIn, g_nIn, P);
        int64_t a = (int64_t)gc - RATE / 20, z = (int64_t)gc + RATE / 4;  // P 前 50 ms 到后 250 ms
        if (a < 0) a = 0;
        if (z + CLICK_LEN > g_micFrames) z = g_micFrames - CLICK_LEN;
        if (z - a < CLICK_LEN || z - a > RATE / 2) { printf("× "); continue; }
        int nc = 0, best = 0;
        for (int64_t g = a; g < z; g++, nc++) {
            double c = 0;
            for (int j = 0; j < CLICK_LEN; j++) c += g_tmpl[j] * g_mic[g + j];
            corr[nc] = fabs(c);
            if (corr[nc] > corr[best]) best = nc;
        }
        const double peak = corr[best];
        double *sorted = malloc(sizeof(double) * nc);
        memcpy(sorted, corr, sizeof(double) * nc);
        qsort(sorted, nc, sizeof(double), cmp_d);
        const double med = sorted[nc / 2] > 1 ? sorted[nc / 2] : 1;
        free(sorted);
        if (verbose) printf("[snr %.0f] ", peak / med);
        if (peak / med < 15) { printf("× "); continue; }
        // 直达声最早到，房间反射在后：取第一个达到最大峰一半的位置附近的局部最大值，而不是全窗最大值
        for (int i = 0; i < nc; i++) {
            if (corr[i] >= 0.5 * peak) {
                int j = i;
                while (j + 1 < nc && corr[j + 1] >= corr[j]) j++;
                best = j;
                break;
            }
        }
        double R;
        if (fit_in(P, &c0, &c1) == 0) R = c0 + c1 * (double)(a + best);
        else R = frame_to_ns(g_tsIn, g_nIn, (double)(a + best));
        e[ne] = (R - P) / 1e6;
        printf("%.1f ", e[ne]);
        ne++;
    }
    printf("\n");
    if (ne < 3) { printf("RESULT: FAIL (只检测到 %d/%d 声；音量太小？麦克风没录到？)\n", ne, nclicks); return 1; }
    double s[MAX_CLICKS];
    memcpy(s, e, sizeof(double) * ne);
    qsort(s, ne, sizeof(double), cmp_d);
    printf("RESULT: e_median=%.1f e_p5=%.1f e_p95=%.1f e_min=%.1f e_max=%.1f detected=%d/%d\n", s[ne / 2],
           s[(int)(0.05 * (ne - 1) + 0.5)], s[(int)(0.95 * (ne - 1) + 0.5)], s[0], s[ne - 1], ne, nclicks);
    return 0;
}

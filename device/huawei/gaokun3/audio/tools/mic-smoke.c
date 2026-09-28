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
 *   gaokun3-mic-smoke [-r 采样率] [-c 声道数] [-p 预设] [-m none|lowlat] [-s shared|exclusive] [-t 秒] [输出.wav]
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
 */
#include <aaudio/AAudio.h>
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

static aaudio_data_callback_result_t on_data(AAudioStream *s, void *user, void *audio, int32_t n) {
    (void)s; (void)user;
    int64_t got = atomic_load(&g.got);
    int64_t take = g.want - got < n ? g.want - got : n;
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
    while ((opt = getopt(argc, argv, "r:c:p:m:s:t:h")) != -1) {
        switch (opt) {
        case 'r': rate = atoi(optarg); break;
        case 'c': ch = atoi(optarg); break;
        case 't': seconds = atoi(optarg); break;
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
            fprintf(stderr, "用法：%s [-r 采样率] [-c 声道数] [-p 预设] [-m none|lowlat] [-s shared|exclusive] [-t 秒] [输出.wav]\n", argv[0]);
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
    r = AAudioStream_requestStart(s);
    if (r != AAUDIO_OK) { printf("RESULT: FAIL (requestStart: %s)\n", AAudio_convertResultToText(r)); return 1; }

    // 等到收满，或者超过请求时长 3 秒（一帧都不来时就在这里等满时长）
    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        usleep(100000);
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
            else if (zeroRun >= holeMin) { holes++; holeFrames += zeroRun; if (zeroRun > longest) longest = zeroRun; }
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

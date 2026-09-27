/* eqscan.c — 离线扫出「每个 EQ 槽管哪个频段」（不出声，纯数据）
 *
 * 为什么需要它：靠耳朵连续 A/B 会失效（听觉适应 + 短期记忆只有几秒 + 响度差掩盖音色差）。
 * 这个工具直接在设备上跑 Histen 引擎，输入对数扫频，把每个 EQ 配置的输出写成 wav，
 * 拉回来做 FFT 就能得到完整的频响曲线 —— 一次跑完，不需要听。
 *
 * 用法（设备上）：
 *   ./eqscan <输出目录> [场景号，默认 3]
 *
 * 产出（<输出目录>/）：
 *   in.wav           输入扫频本体（分析时的**参考**，用它相除就免去了解析模型）
 *   base.wav         基线（沿用场景表，不改任何槽）
 *   s<NN>_<VVV>.wav  把槽 NN（= p3 idx(60+NN)）设为 VVV，其余保持基线
 *
 * ══════════════════════════════════════════════════════════════════════════
 * ★★★ 值按【无符号】读！第一版用 -128 / +127 扫，结果两个极值的曲线
 *     几乎逐位相同 —— 因为 -128 存进去是 0x80(=128)、+127 是 0x7f(=127)，
 *     无符号读只差 1 个数。**极值必须取 0 和 255。**
 *
 * 已实测的（2026-09-24，scene=3=LANDSCAPE_TWO）：
 *   - 槽 1..8 有效、槽 0/9/10 改不动
 *   - 槽 n 的频带中心 = 场景表 idx(96+n) 那个频率值（120/560/2200/3700/
 *     4600/1100/220/14000 Hz 与实测 119/545/2170/3600/4530/1090/227/13660 逐个对上）
 *   - 单位 ≈ 0.082 dB/单位（0..255 约合 21 dB），下面 kProbes 就是为标定它
 * ══════════════════════════════════════════════════════════════════════════
 *
 * ══════════════════════════════════════════════════════════════════════════
 * ★★★ 样本格式：int32，音频在**高半字**（`s << 16`）
 *
 *   in  : ((int32)(clamp(f,-1,1) * 32767)) << 16
 *   out :  (int16)(v >> 16)
 *
 *   这是本文件唯一踩过的坑，而且踩得很痛：第一版照 tools/tests/test_histen3.c（作者工作区，不在本仓）
 *   用纯 int16，在设备上**必崩**（SIGSEGV @ libhw_histen_processing.so 的
 *   ImediaSwsS2F，读一个野指针，tombstone 里 x2=480 正是我们的块长）。
 *   histen_chain.h 早就写明了：「喂纯 int16 会让样本流减半、输出白噪声，
 *   是整个移植里最迷惑的失败模式」。test_histen3.c 那套 int16 结论是
 *   **Ubuntu 侧**的旧结论，搬到 Android 不成立。
 *
 *   另外为了让变量最少，这里完全复刻 histen_chain.h 在设备上已验证的做法：
 *   固定一个 480 帧的 int32 输入块，每轮 memcpy 进去再 Apply，
 *   而不是让 p0 在一条大数组上滑动。
 * ══════════════════════════════════════════════════════════════════════════
 *
 * 其余约定（与 histen_chain.h 一致，勿改）：
 *   - cfg.sr = 480（是**帧长**，不是采样率；填 48000 会让 Apply 返回 -35）
 *   - cfg.fl = 真实帧长 480、cfg.ch = 2、cfg.u28 = 0、cfg.u32 = 2
 *   - Init / Apply 第一参数传 **handle 槽的地址**；SetParams 传 **值**
 *   - ★ 每个配置必须【全新零初始化缓冲】：复用缓冲会让参数静默失效
 *
 * ⚠ 扫频幅度取 0.10（-20 dBFS）：引擎内部带正向增益，0.5 会顶到满量程，
 *   削波会压缩基波幅度，测出来的频响就偏了；同时也避开限幅/DRC 的非线性区
 *   （那是非线性区，测的就不是 EQ 了）。结束会打印钳位样本数，非 0 就说明还得降。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <dlfcn.h>

#include "histen_scenes.h"

typedef int (*FN_GetSize)(void *);
typedef int (*FN_Init)(void *, void *, int, void *, void *);
typedef int (*FN_SetParams)(void *, void *, int, void *, void *);
typedef int (*FN_Apply)(void *, void *, int, void *);

#define SR      48000
#define DUR     5.0
#define FRAMES  ((int)(SR * DUR))
#define AMP     0.10
/* 维护者注（2026-09-27）：本仓的 ROM 构建把引擎装在 /vendor（device.mk，effects/prebuilt/ 里有文件时）；
 * /system 那条是作者 KernelSU overlay 的布局。与 histen_chain.h 的 kHistenLibPaths 同一个顺序。 */
static const char *const kLibPaths[] = {
    "/vendor/lib64/soundfx/libhw_histen_processing.so",
    "/system/lib64/soundfx/libhw_histen_processing.so",
};
#define EQBASE  60
#define EQLEN   11
#define BLK     480

static void put32(FILE *f, uint32_t v) { fwrite(&v, 1, 4, f); }
static void put16(FILE *f, uint16_t v) { fwrite(&v, 1, 2, f); }

static void write_wav(const char *path, const int16_t *d, int frames) {
    FILE *f = fopen(path, "wb");
    if (!f) { printf("  [ERR] 写不开 %s\n", path); return; }
    const uint32_t data_bytes = (uint32_t)frames * 2 * 2;
    fwrite("RIFF", 1, 4, f);  put32(f, 36 + data_bytes);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f);  put32(f, 16);
    put16(f, 1);              /* PCM */
    put16(f, 2);              /* channels */
    put32(f, SR);
    put32(f, SR * 2 * 2);     /* byte rate */
    put16(f, 4);              /* block align */
    put16(f, 16);             /* bits */
    fwrite("data", 1, 4, f);  put32(f, data_bytes);
    fwrite(d, 1, data_bytes, f);
    fclose(f);
}

/* 对数扫频 20 Hz -> 20 kHz，相位逐样本积分（不能直接算 sin(2πft)，频率会跳）。
 * 直接按 int32 高半字打包，省得中间再转一道。 */
static void make_sweep(int32_t *d, int frames) {
    const double f0 = 20.0, f1 = 20000.0, dur = (double)frames / SR;
    double phase = 0.0;
    for (int i = 0; i < frames; i++) {
        const double t = (double)i / SR;
        const double fr = f0 * pow(f1 / f0, t / dur);
        phase += 2.0 * M_PI * fr / SR;
        const int32_t s = (int32_t)(AMP * sin(phase) * 32767.0) << 16;
        d[i * 2] = d[i * 2 + 1] = s;
    }
}

/* int32 高半字 -> int16，越界钳位并计数（钳位 = 引擎输出已经顶破 int16，结果不可信） */
static int pack_out(const int32_t *src, int16_t *dst, int n) {
    int clamped = 0;
    for (int i = 0; i < n * 2; i++) {
        int32_t v = src[i] >> 16;
        if (v > 32767)  { v = 32767;  clamped++; }
        if (v < -32768) { v = -32768; clamped++; }
        dst[i] = (int16_t)v;
    }
    return clamped;
}

/* 探头表：要跑哪些 (槽, 值) 组合。改实验设计就改这里。
 *
 * 2026-09-24 已测出的结论（见 android/docs/实测-EQ槽频段映射与增益标定-2026-09-24.md）：
 *   - 槽 1..8 有效，中心 120/220/560/1100/2200/3700/4600/14000 Hz
 *   - 槽 9、10 **确认无效**（基线 100/60，改成 0 输出逐位不变）
 *   - 槽 0 基线就是 0 ⇒ 之前"改成 0 没变化"是废话，必须用非 0 值判，所以下面放 {0,128}
 *   - 值按**无符号**读；1 单位 ≈ 0.0801 dB
 *   - ★ 值 ≥204 被 Init 拒绝、返回 **-145**（200 可、204 不可）⇒ 上限就取 200
 *   - 四个电平 0/64/128/192 已足够拟合（R² ≥ 0.9993） */
typedef struct { unsigned char slot; unsigned char val; } Probe;
static const Probe kProbes[] = {
    /* 频率从低到高：槽 1(120) 7(220) 2(560) 6(1100) 3(2200) 4(3700) 5(4600) 8(14k) */
    {1, 0}, {1, 64}, {1, 128}, {1, 192},
    {7, 0}, {7, 64}, {7, 128}, {7, 192},
    {2, 0}, {2, 64}, {2, 128}, {2, 192},
    {6, 0}, {6, 64}, {6, 128}, {6, 192},
    {3, 0}, {3, 64}, {3, 128}, {3, 192},
    {4, 0}, {4, 64}, {4, 128}, {4, 192},
    {5, 0}, {5, 64}, {5, 128}, {5, 192},
    {8, 0}, {8, 64}, {8, 128}, {8, 192},
    /* 上限附近复核 */
    {1, 200}, {3, 200},
    /* 槽 0 真伪判定（基线为 0，只能抬起来试）+ 槽 9/10 用合法高值复核 */
    {0, 128}, {9, 128}, {10, 128},
};

int main(int argc, char **argv) {
    /* ★ stdout 走管道时是全缓冲，进程一崩缓冲就丢 —— 之前正是因此只看到"零输出"，
     *   误判成 dlopen 失败。改成不缓冲，崩溃前每一行都在。 */
    setvbuf(stdout, NULL, _IONBF, 0);

    const char *outdir = argc > 1 ? argv[1] : "/data/local/tmp/eqscan";
    const int scene = argc > 2 ? atoi(argv[2]) : 3;
    if (scene < 0 || scene >= HISTEN_SCENE_COUNT) {
        printf("[FAIL] 场景号越界 (0..%d)\n", HISTEN_SCENE_COUNT - 1);
        return 1;
    }

    int32_t *src  = (int32_t *)calloc((size_t)FRAMES * 2, sizeof(int32_t));
    int32_t *blkI = (int32_t *)calloc((size_t)BLK * 2, sizeof(int32_t));
    int32_t *blkO = (int32_t *)calloc((size_t)BLK * 2, sizeof(int32_t));
    int16_t *out  = (int16_t *)calloc((size_t)FRAMES * 2, sizeof(int16_t));
    if (!src || !blkI || !blkO || !out) { printf("[FAIL] 分配缓冲\n"); return 1; }
    make_sweep(src, FRAMES);
    printf("[OK] 扫频 %d 帧 (%.1f s @%d Hz) 幅度 %.2f, int32 高半字\n",
           FRAMES, DUR, SR, AMP);

    {   /* 输入参考：把 int32 高半字还原成 int16 写盘，分析脚本拿它当参考 */
        char path[256];
        snprintf(path, sizeof(path), "%s/in.wav", outdir);
        pack_out(src, out, FRAMES);
        write_wav(path, out, FRAMES);
        printf("  [OK] 输入参考 -> %s\n", path);
    }

    void *h = NULL;
    for (size_t i = 0; i < sizeof(kLibPaths) / sizeof(kLibPaths[0]) && !h; i++) {
        h = dlopen(kLibPaths[i], RTLD_NOW);
        if (!h) printf("  [..] dlopen %s: %s\n", kLibPaths[i], dlerror());
        else    printf("  [OK] 引擎：%s\n", kLibPaths[i]);
    }
    if (!h) { printf("[FAIL] 两个位置都没有 libhw_histen_processing.so\n"); return 1; }
    FN_GetSize   GetSize   = (FN_GetSize)dlsym(h, "ImediaHistenGetSize");
    FN_Init      Init      = (FN_Init)dlsym(h, "ImediaHistenInit");
    FN_SetParams SetParams = (FN_SetParams)dlsym(h, "ImediaHistenSetParams");
    FN_Apply     Apply     = (FN_Apply)dlsym(h, "ImediaHistenApply");
    if (!GetSize || !Init || !SetParams || !Apply) { printf("[FAIL] dlsym\n"); return 1; }
    printf("[OK] 核心库已加载\n");

    uint64_t magic __attribute__((aligned(8))) = 0;
    if (GetSize(&magic) != 0) { printf("[FAIL] GetSize\n"); return 1; }
    printf("[OK] GetSize -> sz=%d\n", (int)(magic >> 32));

    struct { void *p0; void *p8; int sr; int fl; int ch; int u28; int u32; } cfg;

    {
        const uint16_t *b = histen_scenes[scene].p3;
        printf("[REF] 场景 %s 基线 idx60..70 (无符号): ", histen_scenes[scene].name);
        for (int i = 0; i < EQLEN; i++) printf("%u ", b[EQBASE + i] & 0xFF);
        printf("\n");
        printf("[REF] 频带中心 idx96..105: ");
        for (int i = 96; i <= 105; i++) printf("%u ", b[i]);
        printf("\n");

        /* 落盘给分析脚本用：脚本不该去解析 C 头文件，基线值必须以设备读到的为准 */
        char path[256];
        snprintf(path, sizeof(path), "%s/base_eq.txt", outdir);
        FILE *f = fopen(path, "w");
        if (f) {
            fprintf(f, "# scene %d %s\n", scene, histen_scenes[scene].name);
            fprintf(f, "# slot idx value_unsigned freq_center_hz\n");
            for (int i = 0; i < EQLEN; i++) {
                fprintf(f, "%d %d %u %u\n", i, EQBASE + i, b[EQBASE + i] & 0xFF,
                        96 + i < 255 ? b[96 + i] : 0);
            }
            fclose(f);
            printf("  [OK] 基线参数 -> %s\n", path);
        }
    }

    const int nblk = FRAMES / BLK;
    int bad = 0, total_clamp = 0;

    /* 0 = 基线；其余按 kProbes 逐条跑。探头表刻意手写：改动它就能换实验设计。 */
    for (int pi = -1; pi < (int)(sizeof(kProbes) / sizeof(kProbes[0])); pi++) {
        char name[64];
        int slot = -1, val = 0;
        if (pi < 0) {
            snprintf(name, sizeof(name), "base");
        } else {
            slot = kProbes[pi].slot;
            val  = kProbes[pi].val;
            snprintf(name, sizeof(name), "s%02d_%03d", slot, val);
        }
        if (slot >= EQLEN) { printf("  [SKIP] %-10s 槽越界\n", name); bad++; continue; }

        /* ★ 全新零初始化缓冲：复用会让参数静默失效 */
        void *work = calloc(1, 0x100000);
        void *bufB = calloc(1, 0x100000);
        void *p3   = calloc(1, 0x2000);
        void *sub  = calloc(1, 0x800);
        void *p4   = calloc(1, 0x100);
        unsigned long hdl = (unsigned long)work;

        uint16_t *p3w = (uint16_t *)p3;
        memcpy(p3, histen_scenes[scene].p3, 510);
        memcpy(p4, histen_scenes[scene].ext, 32);
        if (slot >= 0) {
            const uint16_t b = (uint16_t)(val & 0xFF);
            p3w[EQBASE + slot] = (uint16_t)((b << 8) | b);
        }
        *(unsigned long *)((char *)p3 + 0x200) = (unsigned long)sub;
        *(unsigned long *)((char *)p3 + 0x208) = (unsigned long)sub;
        *(unsigned long *)((char *)p3 + 0x210) = (unsigned long)sub;
        *(unsigned long *)((char *)p3 + 0x218) = (unsigned long)sub;

        int r = Init(&hdl, bufB, 82024, p3, p4);
        if (r != 0) { printf("  [SKIP] %-6s Init=%d\n", name, r); bad++; goto next; }
        r = SetParams((void *)hdl, bufB, 82024, p3, p4);
        if (r != 0) { printf("  [SKIP] %-6s SetParams=%d\n", name, r); bad++; goto next; }

        memset(&cfg, 0, sizeof(cfg));
        cfg.sr = BLK; cfg.fl = BLK; cfg.ch = 2; cfg.u28 = 0; cfg.u32 = 2;
        cfg.p0 = blkI; cfg.p8 = blkO;
        r = Apply(&hdl, bufB, 82024, &cfg);          /* 预热：建内部状态 */
        if (r != 0) { printf("  [SKIP] %-6s 预热Apply=%d\n", name, r); bad++; goto next; }

        {
            int ok = 1;
            for (int b = 0; b < nblk; b++) {
                memcpy(blkI, src + (size_t)b * BLK * 2, BLK * 2 * sizeof(int32_t));
                if (Apply(&hdl, bufB, 82024, &cfg) != 0) {
                    printf("  [SKIP] %-6s Apply 失败 @block %d\n", name, b);
                    ok = 0; bad++; break;
                }
                total_clamp += pack_out(blkO, out + (size_t)b * BLK * 2, BLK);
            }
            if (!ok) goto next;
        }

        {
            char path[256];
            int pk = 0;
            for (int i = 0; i < FRAMES * 2; i++) {
                int v = out[i] < 0 ? -out[i] : out[i];
                if (v > pk) pk = v;
            }
            snprintf(path, sizeof(path), "%s/%s.wav", outdir, name);
            write_wav(path, out, FRAMES);
            printf("  [OK] %-6s -> %s  peak=%d(%.2f FS)\n", name, path, pk,
                   (double)pk / 32767.0);
        }

next:
        free(work); free(bufB); free(p3); free(sub); free(p4);
    }

    printf("[DONE] 输出目录: %s\n", outdir);
    printf("[DONE] 失败配置 %d 个；总钳位样本 %d %s\n", bad, total_clamp,
           total_clamp ? "=> 幅度还要降（结果不可信）" : "=> 幅度合适");
    return 0;
}

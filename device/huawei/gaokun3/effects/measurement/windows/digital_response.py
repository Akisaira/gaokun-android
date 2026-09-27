#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""digital_response.py -- 数字域传递函数（输入 wav -> 输出 wav）。

用途：把「同一条激励信号喂进去、抓输出」的两侧曲线放在**同一口径**下比较。
典型场景：

  Windows 侧： in = analysis/audio/noise-flat.wav
               out = analysis/audio/m3/lb-noise-win.wav   (WASAPI loopback 录的渲染端点数字输出)
               => Windows 整条 APO 链（Qualcomm Aqstic + 华为 Histen）的 H(f)

  Android 侧： in = noise-flat.wav
               out = eqscan 跑出来的引擎输出 wav
               => Android effect 链的 H(f)

两者都是「数字域」，所以可以直接相减 => 每个频段要补多少 dB，是算出来的。

为什么用噪声而不是扫频：不需要时间对齐之外的任何假设，Welch 平均直接给出 |H(f)|，
统计散布可以靠加长录音压到 0.1 dB 以下。扫频+对角线采样是另一种估计量，
两种估计量混用会引入系统性偏差 —— 比较时**必须同口径**。

用法:
    py -3 tools/digital_response.py <in.wav> <out.wav> [--oct 12] [--csv out.csv]
    py -3 tools/digital_response.py --diff <a.csv> <b.csv>      # b 相对 a 的逐频段差
"""

import argparse
import math
import os
import sys
import wave

import numpy as np

NFFT = 8192
FMIN, FMAX = 40.0, 16000.0


def load_mono(path):
    with wave.open(path, "rb") as r:
        nch, sr, n = r.getnchannels(), r.getframerate(), r.getnframes()
        raw = r.readframes(n)
    x = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    x = x.reshape(-1, nch).mean(axis=1)
    return x, sr


def find_lag(a, b, max_lag=None):
    """b 相对 a 的样本延迟（b[lag:] ≈ a[:]）。FFT 互相关，取全局峰。"""
    n = 1
    while n < len(a) + len(b):
        n <<= 1
    fa = np.fft.rfft(a - a.mean(), n)
    fb = np.fft.rfft(b - b.mean(), n)
    cc = np.fft.irfft(fa.conj() * fb, n)
    if max_lag is None:
        max_lag = len(b)
    head = cc[:max_lag]
    return int(np.argmax(head))


def welch(x, sr):
    win = np.hanning(NFFT)
    step = NFFT // 2
    acc = np.zeros(NFFT // 2 + 1)
    cnt = 0
    for i in range(0, len(x) - NFFT + 1, step):
        seg = x[i:i + NFFT]
        acc += np.abs(np.fft.rfft(seg * win)) ** 2
        cnt += 1
    if cnt == 0:
        raise SystemExit("信号太短，装不下一个 %d 点窗" % NFFT)
    return np.fft.rfftfreq(NFFT, 1.0 / sr), acc / cnt


def oct_bands(oct_div, fmin, fmax):
    """返回 [(f_center, lo, hi), ...]，1/oct_div 倍频程。"""
    r = 2.0 ** (1.0 / oct_div)
    out = []
    f = fmin
    while f * r <= fmax:
        lo, hi = f, f * r
        out.append((math.sqrt(lo * hi), lo, hi))
        f = hi
    return out


def band_energy(f, p, lo, hi):
    m = (f >= lo) & (f < hi)
    if not m.any():
        # 低频端 1/N 倍频程带可能窄于 FFT 分辨率（8192 点 @48k ⇒ 5.86 Hz/bin），
        # 此时带内一个 bin 都没有。退回"离带中心最近的 bin"，并让调用方知道。
        i = int(np.argmin(np.abs(f - math.sqrt(lo * hi))))
        return float(10.0 * np.log10(p[i] + 1e-30)), True
    return float(10.0 * np.log10(p[m].mean() + 1e-30)), False


def response(in_wav, out_wav, oct_div, fmin, fmax):
    xin, srin = load_mono(in_wav)
    xout, srout = load_mono(out_wav)
    if srin != srout:
        raise SystemExit("采样率不一致: %d vs %d" % (srin, srout))

    lag = find_lag(xin, xout)
    # 截取输出中真正的播放段，长度与输入严格相同 —— 否则静音会稀释分母/分子
    # 之外的统计，比例被系统性拉偏（这是本类比较最常见的假阴性来源）。
    if lag < 0 or lag + len(xin) > len(xout):
        print("[warn] 互相关给出的对齐 lag=%d 越界，退回不裁剪" % lag)
        n = min(len(xin), len(xout))
        xin, xout = xin[:n], xout[:n]
    else:
        xout = xout[lag:lag + len(xin)]
    print("对齐 lag = %d 样本 (%.3f ms)   分析长度 = %.2f s"
          % (lag, lag * 1000.0 / srin, len(xin) / srin))

    fin, pin = welch(xin, srin)
    fout, pout = welch(xout, srin)
    assert np.allclose(fin, fout)

    rows = []
    approx = 0
    for fc, lo, hi in oct_bands(oct_div, fmin, fmax):
        gi, a1 = band_energy(fin, pin, lo, hi)
        go, a2 = band_energy(fout, pout, lo, hi)
        approx += int(a1 or a2)
        rows.append((fc, go - gi))
    if approx:
        print("注：%d 个低频带的带宽窄于 FFT 分辨率，已退回最近 bin（分辨率 %.2f Hz）"
              % (approx, srin / float(NFFT)))
    # rel 参考点 = 1 kHz 所在那一格
    k = min(range(len(rows)), key=lambda i: abs(math.log(rows[i][0] / 1000.0)))
    ref = rows[k][1]
    return [(fc, g, g - ref) for fc, g in rows], rows[k][0]


def cmd_diff(a_csv, b_csv):
    ra = read_csv(a_csv)
    rb = read_csv(b_csv)
    print("%-11s %9s %9s %9s" % ("freq_hz", "A_rel", "B_rel", "B-A"))
    print("-" * 44)
    for (f, _g, ra_rel), (f2, _g2, rb_rel) in zip(ra, rb):
        if abs(math.log(f / f2)) > 1e-6:
            raise SystemExit("两个 CSV 的频率网格不一致: %g vs %g" % (f, f2))
        print("%-11.1f %9.2f %9.2f %9.2f" % (f, ra_rel, rb_rel, rb_rel - ra_rel))


def read_csv(path):
    out = []
    with open(path, "r", encoding="utf-8") as h:
        next(h)
        for line in h:
            p = line.strip().split(",")
            if len(p) < 3:
                continue
            try:
                out.append((float(p[0]), float(p[1]), float(p[2])))
            except ValueError:
                continue
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("in_wav", nargs="?")
    ap.add_argument("out_wav", nargs="?")
    ap.add_argument("--oct", type=int, default=12, help="每倍频程分级数，默认 12")
    ap.add_argument("--fmin", type=float, default=FMIN)
    ap.add_argument("--fmax", type=float, default=FMAX)
    ap.add_argument("--csv")
    ap.add_argument("--diff", nargs=2, metavar=("A.CSV", "B.CSV"))
    a = ap.parse_args()

    if a.diff:
        cmd_diff(*a.diff)
        return 0
    if not a.in_wav or not a.out_wav:
        ap.error("需要 in.wav 和 out.wav，或用 --diff")

    rows, fref = response(a.in_wav, a.out_wav, a.oct, a.fmin, a.fmax)
    print("参考点 %.1f Hz" % fref)
    print("%-11s %10s %10s" % ("freq_hz", "abs_dB", "rel_1k"))
    print("-" * 34)
    for fc, g, rel in rows:
        print("%-11.1f %10.2f %10.2f" % (fc, g, rel))
    if a.csv:
        with open(a.csv, "w", encoding="utf-8", newline="\n") as h:
            h.write("freq_hz,abs_gain_dB,rel_1kHz_dB\n")
            for fc, g, rel in rows:
                h.write("%.1f,%.3f,%.3f\n" % (fc, g, rel))
        print("\n写出", a.csv)
    return 0


if __name__ == "__main__":
    sys.exit(main())

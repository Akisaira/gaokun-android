#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""eqscan_report.py — 把 eqscan 的输出 wav 变成「槽 -> 频段 -> 增益斜率」表 + 图。

原理：eqscan 在设备上跑的是**对数扫频** 20Hz->20kHz，瞬时频率随时间单调上升。
对波形做 STFT，每一帧的能量都集中在当帧的瞬时频率附近，所以：
  ① 拿 in.wav（喂进去的扫频本体）每帧的**峰值 bin** 当瞬时频率 —— 不用解析模型，
     扫频起点/是否有静音头都不影响；
  ② 在同一个 bin 上同时取 in.wav 与配置 wav 的幅度，相除 = H(f)。
两处用同一帧、同一 bin，窗函数与幅度因子自动抵消。

为什么不用耳朵：听觉适应 + 短期记忆只有几秒 + 响度差会掩盖音色差 —— 连续 A/B 必然失效。
这个脚本一次给出全部曲线、斜率与频段，可重复、可回看、可出图。

用法：
  python eqscan_report.py <目录> [--skip 0.4] [--fmin 30] [--fmax 18000]

目录里应有 in.wav / base.wav / base_eq.txt / s<NN>_<VVV>.wav。
输出：控制台表格 + eqscan_report.md + eqscan_curves.csv + eqscan.png
"""
import argparse
import csv
import os
import re
import sys
import wave

try:
    import numpy as np
except ImportError:
    print("[FAIL] 需要 numpy。Windows 系统 py -3 里没有，用托管 venv：\n"
          "  C:/Users/Administrator/.workbuddy/binaries/python/envs/default/Scripts/python.exe",
          file=sys.stderr)
    sys.exit(1)

SR = 48000
NFFT = 8192
HOP = 1024
# 可用值上限。实测 200 可、204 起被引擎 Init 拒 -145（与槽无关），
# 所以别拿 255 当满量程去算 dB 范围 —— 那会高估 4.4 dB。
EQ_CEIL = 200
PAT = re.compile(r"^s(\d+)_(\d+)\.wav$", re.I)


def read_wav_mono(path):
    """读 wav，返回左声道 float64 数组。只要左声道：eqscan 左右同值。"""
    with wave.open(path, "rb") as w:
        nch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(w.getnframes())
    if sw != 2:
        raise SystemExit("[FAIL] %s 不是 16-bit（%d bit）" % (path, sw * 8))
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64)
    if nch > 1:
        a = a[0::nch]            # ⚠ 必须去交织取左声道（按交织缓冲直接算会把频率减半）
    return a


def stft_mag(x):
    win = np.hanning(NFFT)
    nfr = (len(x) - NFFT) // HOP + 1
    if nfr < 8:
        raise SystemExit("[FAIL] 音频太短（%d 帧）" % nfr)
    frames = np.lib.stride_tricks.as_strided(
        x, shape=(nfr, NFFT), strides=(x.strides[0] * HOP, x.strides[0])).copy()
    return np.abs(np.fft.rfft(frames * win, axis=1)), np.fft.rfftfreq(NFFT, 1.0 / SR)


def diag_curve(x_ref, Y, fbin, skip_bins=2, fmin=30.0, fmax=18000.0):
    """用参考谱 x_ref 的峰值 bin 当瞬时频率，取 (x_ref, Y) 的幅度比 -> (freqs, |H|)。"""
    nfr, nbins = x_ref.shape
    freqs, mags = [], []
    lo = int(np.searchsorted(fbin, fmin))
    hi = int(np.searchsorted(fbin, fmax))
    for i in range(nfr):
        k = int(np.argmax(x_ref[i, lo:hi + 1])) + lo
        if k < skip_bins or k + skip_bins >= nbins:
            continue
        s = slice(k - skip_bins, k + skip_bins + 1)
        mx = np.sqrt(np.mean(x_ref[i, s] ** 2))
        my = np.sqrt(np.mean(Y[i, s] ** 2))
        if mx <= 0:
            continue
        freqs.append(fbin[k])
        mags.append(my / mx)
    return np.asarray(freqs), np.asarray(mags)


def smooth_log(freqs, mags, npts=140, fmin=30.0, fmax=18000.0):
    grid = np.geomspace(fmin, fmax, npts)
    out = np.zeros(npts)
    for i, g in enumerate(grid):
        m = (freqs > g / 1.06) & (freqs < g * 1.06)
        out[i] = np.mean(mags[m]) if m.any() else np.nan
    idx = np.arange(npts)
    good = ~np.isnan(out)
    if good.sum() < 8:
        raise SystemExit("[FAIL] 有效频点太少，检查音频/参数")
    return grid, np.interp(idx, idx[good], out[good])


def db(x):
    return 20.0 * np.log10(np.maximum(x, 1e-12))


def _f(f):
    return ("%.0f Hz" % f) if f < 1000 else ("%.2f kHz" % (f / 1000.0))


def _f2(lo, hi):
    return "%s~%s" % (_f(lo), _f(hi))


def read_base_eq(path):
    """base_eq.txt -> {slot: (idx, value, center_hz)}"""
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = line.split()
        if len(p) >= 4:
            out[int(p[0])] = (int(p[1]), int(p[2]), float(p[3]))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--skip", type=float, default=0.4, help="跳过开头秒数（引擎预热）")
    ap.add_argument("--fmin", type=float, default=30.0)
    ap.add_argument("--fmax", type=float, default=18000.0)
    ap.add_argument("--thr", type=float, default=1.5, help="判定'改得动'的 |Δ| 门限 dB")
    a = ap.parse_args()

    d = a.dir
    if not os.path.isdir(d):
        raise SystemExit("[FAIL] 不是目录：%s" % d)
    ref_p = os.path.join(d, "in.wav")
    if not os.path.exists(ref_p):
        raise SystemExit("[FAIL] 缺 in.wav（eqscan 会写它）")

    print("== 1. 参考 = in.wav ==")
    nskip = int(a.skip * SR)
    Xin, fbin = stft_mag(read_wav_mono(ref_p)[nskip:])
    fq, _ = diag_curve(Xin, Xin, fbin, fmin=a.fmin, fmax=a.fmax)
    print("   STFT %s, 有效频点 %d (%.0f..%.0f Hz)"
          % (Xin.shape, len(fq), fq[0] if len(fq) else 0, fq[-1] if len(fq) else 0))

    def curve(path):
        Y, _ = stft_mag(read_wav_mono(path)[nskip:])
        if Y.shape != Xin.shape:
            raise SystemExit("[FAIL] %s 长度与 in.wav 不一致" % os.path.basename(path))
        f, m = diag_curve(Xin, Y, fbin, fmin=a.fmin, fmax=a.fmax)
        g, c = smooth_log(f, m, fmin=a.fmin, fmax=a.fmax)
        return g, db(c)

    grid, base_db = curve(os.path.join(d, "base.wav"))
    base_eq = read_base_eq(os.path.join(d, "base_eq.txt"))
    print("   基线已读；base_eq.txt 条目 %d" % len(base_eq))

    # 收集 s<slot>_<val>.wav
    probes = {}
    for fn in sorted(os.listdir(d)):
        m = PAT.match(fn)
        if m:
            probes.setdefault(int(m.group(1)), {})[int(m.group(2))] = os.path.join(d, fn)
    if not probes:
        raise SystemExit("[FAIL] 没找到 s<NN>_<VVV>.wav，eqscan 跑成功了吗？")

    print("   槽 %s；电平档 %s"
          % (sorted(probes), sorted({v for vs in probes.values() for v in vs})))

    # 逐配置算曲线
    curves = {}       # (slot, val) -> db array
    for slot, vals in probes.items():
        for val, p in vals.items():
            g, c = curve(p)
            curves[(slot, val)] = c - base_db

    print("\n== 2. 槽 -> 频段 -> 斜率 ==")
    hdr = "%-4s %8s %10s %18s %10s %9s %7s" % (
        "槽", "峰值|Δ|dB", "峰值频率", "影响频段(Δ>40%峰)", "基线值", "dB/单位", "R²")
    print(hdr)
    print("-" * len(hdr))

    rows = []
    for slot in sorted(probes):
        vals = sorted(probes[slot])
        dmat = np.array([curves[(slot, v)] for v in vals])       # (nval, npts)
        ad = np.abs(dmat).max(axis=0)
        k = int(np.argmax(ad))
        pkf = float(grid[k])
        band = ad > max(a.thr, 0.4 * ad[k])
        lo, hi = (float(grid[band][0]), float(grid[band][-1])) if band.any() \
            else (pkf, pkf)

        bval = base_eq.get(slot, (None, None, None))[1]
        # 线性拟合：ΔdB(k) vs (val - 基线值)。拿不到基线值就退化成相对最小电平
        ref = bval if bval is not None else min(vals)
        x = np.array([v - ref for v in vals], dtype=float)
        y = np.array([curves[(slot, v)][k] for v in vals], dtype=float)
        slope = r2 = float("nan")
        if np.ptp(x) > 0 and len(x) >= 2:
            A = np.vstack([x, np.ones_like(x)]).T
            sol, *_ = np.linalg.lstsq(A, y, rcond=None)
            slope = float(sol[0])
            pred = A @ sol
            ss = float(np.sum((y - y.mean()) ** 2))
            r2 = 1.0 - float(np.sum((y - pred) ** 2)) / ss if ss > 1e-12 else float("nan")

        dead = float(np.abs(dmat).max()) < a.thr
        rows.append(dict(slot=slot, pkabs=float(ad[k]), pkf=pkf, lo=lo, hi=hi, bval=bval,
                         slope=slope, r2=r2, dead=dead,
                         dmat=dmat, vals=vals))
        if dead:
            print("%-4d %8.2f %10s %18s %10s %9s %7s   <- 改不动"
                  % (slot, ad[k], "-", "-", bval if bval is not None else "-", "-", "-"))
        else:
            print("%-4d %8.2f %10s %18s %10s %9.4f %7.4f"
                  % (slot, ad[k], _f(pkf), _f2(lo, hi),
                     bval if bval is not None else "-", slope, r2))

    live = [r for r in rows if not r["dead"]]
    if live:
        s = np.array([r["slope"] for r in live], dtype=float)
        print("\n   有效槽 %d 个；dB/单位 中位 %.4f  范围 %.4f..%.4f"
              % (len(live), np.median(s), s.min(), s.max()))
        # ⚠ 不要写"满量程 0..255"：实测 >=204 会被引擎 Init 拒 -145，可用上限是 200。
        print("   ⇒ 折合 **1 单位 ≈ %.4f dB**；可用 0..%d ≈ %.1f dB"
              % (np.median(s), EQ_CEIL, np.median(s) * EQ_CEIL))

    bd = base_db - float(np.median(base_db[(grid > 300) & (grid < 3000)]))
    k = int(np.argmax(np.abs(bd)))
    print("   基线绝对曲线最大偏离输入 %.2f dB @ %s（整体形状自检）"
          % (float(bd[k]), _f(float(grid[k]))))

    # ---------- CSV ----------
    csv_p = os.path.join(d, "eqscan_curves.csv")
    with open(csv_p, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        keys = sorted(curves)
        w.writerow(["freq_hz", "base_db_rel_input", "base_db_centred"]
                   + ["s%02d_%03d" % kk for kk in keys])
        for j, f in enumerate(grid):
            w.writerow(["%.1f" % f, "%.3f" % base_db[j], "%.3f" % bd[j]]
                       + ["%.3f" % curves[kk][j] for kk in keys])
    print("\n[OK] 曲线 CSV -> %s" % csv_p)

    # ---------- Markdown ----------
    md_p = os.path.join(d, "eqscan_report.md")
    with open(md_p, "w", encoding="utf-8") as fh:
        fh.write("# eqscan：EQ 槽 -> 频段映射与增益斜率\n\n")
        fh.write("参考 `in.wav`（扫频本体，模型无关），跳过开头 %.2f s；`base` 为设备当前场景表基线。\n\n"
                 % a.skip)
        fh.write("| 槽 | 峰值\\|Δ\\| (dB) | 峰值频率 | 影响频段 | 基线值 | dB/单位 | R² |\n")
        fh.write("|---|---|---|---|---|---|---|\n")
        for r in rows:
            if r["dead"]:
                fh.write("| %d | %.2f | — | — | %s | 改不动 | — |\n"
                         % (r["slot"], r["pkabs"], r["bval"]))
            else:
                fh.write("| %d | %.2f | %s | %s | %s | %.4f | %.4f |\n"
                         % (r["slot"], r["pkabs"], _f(r["pkf"]), _f2(r["lo"], r["hi"]),
                            r["bval"], r["slope"], r["r2"]))
        if live:
            s = np.array([r["slope"] for r in live], dtype=float)
            fh.write("\n**dB/单位 中位 %.4f** ⇒ 1 单位 ≈ %.4f dB，满量程 0..255 ≈ %.1f dB。\n"
                     % (np.median(s), np.median(s), np.median(s) * 255))
        fh.write("\n基线绝对曲线（相对输入）最大偏离 %.2f dB @ %s。\n"
                 % (float(bd[k]), _f(float(grid[k]))))
    print("[OK] 报告 -> %s" % md_p)

    # ---------- 图 ----------
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(1, 3, figsize=(19, 5.6))

        ax[0].semilogx(grid, bd, lw=2, color="#c0392b")
        ax[0].axhline(0, color="#888", lw=0.8, ls="--")
        ax[0].set_title("base: EQ curve vs input (scene baseline)")
        ax[0].set_xlabel("Hz"); ax[0].set_ylabel("dB"); ax[0].grid(True, which="both", alpha=.25)
        ax[0].set_xlim(30, 18000)

        cmap = plt.get_cmap("turbo")
        for i, r in enumerate(sorted(live, key=lambda z: z["pkf"])):
            vlo, vhi = r["vals"][0], r["vals"][-1]
            ax[1].semilogx(grid, curves[(r["slot"], vhi)] - curves[(r["slot"], vlo)],
                           lw=1.6, color=cmap(i / max(1, len(live) - 1)),
                           label="slot %d  (%s,  %+.0f..%+.0f)" % (r["slot"], _f(r["pkf"]),
                                                                     vlo, vhi))
        ax[1].axhline(0, color="#888", lw=0.8, ls="--")
        ax[1].set_title("per-slot band shape: value 255 minus value 0")
        ax[1].set_xlabel("Hz"); ax[1].set_ylabel("dB"); ax[1].grid(True, which="both", alpha=.25)
        ax[1].set_xlim(30, 18000); ax[1].legend(fontsize=7, ncol=1, loc="lower left")

        for i, r in enumerate(sorted(live, key=lambda z: z["pkf"])):
            ref = r["bval"] if r["bval"] is not None else min(r["vals"])
            xs = [v - ref for v in r["vals"]]
            ys = [curves[(r["slot"], v)][int(np.argmin(np.abs(grid - r["pkf"])))] for v in r["vals"]]
            ax[2].plot(xs, ys, "o-", ms=4, lw=1.3,
                       color=cmap(i / max(1, len(live) - 1)),
                       label="slot %d  %.4f dB/u" % (r["slot"], r["slope"]))
        ax[2].axhline(0, color="#888", lw=0.8, ls="--")
        ax[2].axvline(0, color="#888", lw=0.8, ls="--")
        ax[2].set_title("linearity at band centre")
        ax[2].set_xlabel("value - baseline"); ax[2].set_ylabel("dB vs base")
        ax[2].grid(True, alpha=.25); ax[2].legend(fontsize=7)

        fig.suptitle("Histen EQ scan (gaokun3, device-side, %s)" % os.path.basename(d.rstrip("/\\")))
        fig.tight_layout(rect=[0, 0, 1, 0.95])
        png = os.path.join(d, "eqscan.png")
        fig.savefig(png, dpi=110)
        print("[OK] 图 -> %s" % png)
    except Exception as e:      # 图是加分项，缺 matplotlib 不该让整条流程失败
        print("[WARN] 出图失败（不影响上面的结论）: %s" % e)

    return 0


if __name__ == "__main__":
    sys.exit(main())

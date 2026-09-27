#!/usr/bin/env python3
"""analyze-noise-response.py -- band response from a noise measurement.

Compares one reference noise file against any number of recorded/processed
outputs and prints a band table (absolute gain and gain relative to 1 kHz).

This is the analysis half of both rigs:
  * Windows:  WASAPI loopback capture  (tools/win-measure/loopback_rec.py)
  * Ubuntu:   offline LADSPA chain run (scripts/audio/ubuntu-freq-response.sh)

No time alignment is needed: noise + Welch averaging is shift invariant, which
is exactly why the sweep method was abandoned (a 1.2 s start offset destroyed
the time->frequency mapping).

usage:
    python analyze-noise-response.py <ref.wav> <out1.wav> [out2.wav ...]
                                   [--skip 1.6] [--nfft 8192]
"""
import sys
import wave

import numpy as np

BANDS = [(30, 60), (60, 100), (100, 150), (150, 250), (250, 400), (400, 700),
         (700, 1000), (1000, 1500), (1500, 2500), (2500, 4000), (4000, 7000),
         (7000, 12000), (12000, 20000)]


def load_mono(path):
    with wave.open(path, "rb") as r:
        n = r.getnchannels()
        sr = r.getframerate()
        d = r.readframes(r.getnframes())
    return np.frombuffer(d, dtype=np.int16).astype(np.float64).reshape(-1, n).mean(1), sr


def welch(x, nfft=8192, skip=1.6, tail=0.5, sr=48000):
    x = x[int(skip * sr):len(x) - int(tail * sr)]
    step, w, acc = nfft // 2, np.hanning(nfft), []
    for i in range(0, len(x) - nfft, step):
        acc.append(np.abs(np.fft.rfft(x[i:i + nfft] * w)) ** 2)
    return np.mean(acc, axis=0), np.fft.rfftfreq(nfft, 1 / sr)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    nfft = 8192
    for a in sys.argv[1:]:
        if a.startswith("--nfft"):
            nfft = int(a.split("=")[-1]) if "=" in a else nfft
    if len(args) < 2:
        print(__doc__)
        return 1

    ref, sr = load_mono(args[0])
    pref, f = welch(ref, nfft, sr=sr)
    print("参考: %s   (%.1f s, %d Hz)" % (args[0], len(ref) / sr, sr))
    print("  频段        " + "".join("%9d-%d" % b for b in BANDS[:6]))
    for out in args[1:]:
        x, sr2 = load_mono(out)
        pout, _ = welch(x, nfft, sr=sr2)
        H = 10 * np.log10((pout + 1e-20) / (pref + 1e-20))
        norm = H[(f >= 900) & (f < 1100)].mean()
        cells = []
        for lo, hi in BANDS:
            m = (f >= lo) & (f < hi)
            cells.append(H[m].mean() if m.any() else float("nan"))
        print("\n%s" % out)
        print("  绝对增益    " + "".join("%13.1f" % c for c in cells[:6]))
        print("  相对 1kHz   " + "".join("%13.1f" % (c - norm) for c in cells[:6]))
        print("  1kHz 绝对 %+.1f dB | 全带平均 %+.1f dB" %
              (norm, H[(f > 40) & (f < 16000)].mean()))
    return 0


if __name__ == "__main__":
    sys.exit(main())

"""loopback_rec.py -- record the Windows render endpoint digitally (WASAPI loopback).

This captures exactly what Windows hands to the speaker *after* every APO
(Huawei Histen etc.), so it measures the real processing chain with no room and
no microphone colouration. Far better than the self-record path, which the mic
array's AEC erases.

usage: python loopback_rec.py <play.wav> <out.wav> <record_secs> <play_delay>
"""
import sys
import time
import wave
import threading

import numpy as np
import soundcard as sc

SR = 48000


def pick_loopback():
    spk = sc.default_speaker()
    print("default speaker   :", spk.name)
    # 1) ask for the loopback twin of the default speaker
    try:
        m = sc.get_microphone(spk.name, include_loopback=True)
        if getattr(m, "isloopback", True):
            return m
    except Exception as e:
        print("  get_microphone(speaker) failed:", e)
    # 2) fall back to any device that reports loopback
    for m in sc.all_microphones(include_loopback=True):
        if getattr(m, "isloopback", False):
            print("  using loopback device:", m.name)
            return m
    raise SystemExit("no loopback device found")


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 1
    play_wav, out_wav = sys.argv[1], sys.argv[2]
    rec_secs = float(sys.argv[3])
    delay = float(sys.argv[4])

    mic = pick_loopback()
    print("loopback device   :", mic.name)
    print("play              :", play_wav)
    print("record %.2f s, play at +%.2f s" % (rec_secs, delay))

    import winsound

    def player():
        time.sleep(delay)
        try:
            winsound.PlaySound(play_wav, winsound.SND_FILENAME)
        except Exception as e:            # noqa: BLE001
            print("  PlaySound failed:", e)

    t = threading.Thread(target=player, daemon=True)
    t.start()

    with mic.recorder(samplerate=SR, channels=2) as rec:
        data = rec.record(numframes=int(SR * rec_secs))
    t.join(timeout=1.0)

    # loopback data comes back as float32 in [-1, 1]
    peak = float(np.abs(data).max())
    rms = float(np.sqrt((data ** 2).mean()))
    print("captured %.2f s  peak=%.1f dBFS  rms=%.1f dBFS  shape=%s"
          % (len(data) / SR, 20 * np.log10(peak + 1e-12), 20 * np.log10(rms + 1e-12), data.shape))

    pcm = np.clip(data, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype(np.int16)
    with wave.open(out_wav, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print("wrote", out_wav)
    return 0


if __name__ == "__main__":
    sys.exit(main())

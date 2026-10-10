#!/usr/bin/env python3
"""Count, per labelled time range, the touches that reached the app and the
touches that were cancelled, in one or more hxsim replays.

    python3 scripts/touch/outcomes.py rec.bin RANGES sim.txt [sim2.txt ...]

RANGES labels birth times in seconds from the start of the recording
(trec.py summary prints them), e.g. "fingers:20-80,writing:95-140"; one
label may cover several ranges.  Every reported tracking id is one touch.
A touch whose last report carries MT_TOOL_PALM was cancelled: Android sends
ACTION_CANCEL, so it never becomes a click.  Any other touch reached the
app.  "flash" counts the touches that reached the app and lasted at most
100 ms, the typical shape of a tap made by a hand.

Replaying the same recording with -s hand_enabled=0 gives the numbers for
the driver without the hand map.
"""
import sys

from simcmp import parse_sim
from trec import Recording

MT_TOOL_PALM = 2


def touches(sim, t0):
    out = {}
    for fr in sim:
        for t in fr["tracks"]:
            if not t["rep"]:
                continue
            rel = (fr["t"] - t0) / 1e9
            tc = out.setdefault(t["tid"], {"t": rel, "end": rel, "tool": 0})
            tc["end"] = rel
            tc["tool"] = t["tool"]
    return out


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    t0 = Recording(sys.argv[1]).t0()
    ranges = []
    for part in sys.argv[2].split(","):
        name, rng = part.split(":")
        a, b = rng.split("-")
        ranges.append((name, float(a), float(b)))
    names = sorted({name for name, *_ in ranges})
    print(f"{'replay':28s} " + " ".join(f"{n:>34s}" for n in names))
    print(f"{'':28s} " + " ".join(f"{'reached app (flash) / cancelled':>34s}"
                                  for _ in names))
    for path in sys.argv[3:]:
        ts = touches(parse_sim(path), t0)
        cells = []
        for n in names:
            sel = [tc for tc in ts.values()
                   if any(g == n and a <= tc["t"] <= b for g, a, b in ranges)]
            app = [tc for tc in sel if tc["tool"] != MT_TOOL_PALM]
            flash = [tc for tc in app if tc["end"] - tc["t"] <= 0.1]
            cancelled = len(sel) - len(app)
            cells.append(f"{len(app):5d} ({len(flash):4d}) / {cancelled:4d}")
        print(f"{path.rsplit('/', 1)[-1]:28s} " + " ".join(f"{c:>34s}" for c in cells))


if __name__ == "__main__":
    main()

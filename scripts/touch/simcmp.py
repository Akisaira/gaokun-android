#!/usr/bin/env python3
"""Check an hxsim replay against what the device reported.

    hxsim -p params.txt rec.bin > sim.txt
    python3 scripts/touch/simcmp.py rec.bin sim.txt [T0 T1]

Each replayed grid is compared with the touch report it produced on the
device, the last SYN_REPORT before the grid's timestamp (gk3trec takes that
timestamp after the read, header flag bit 0).  Two frames agree when they
hold the same number of contacts and every replayed contact has a device
contact within 2 units.  T0 and T1 limit the check to that range, in seconds
from the start of the recording.

With the tunables that were live during the recording, and hxsim built
from the kernel tree the device was running, nearly every frame agrees; the
first disagreements are listed.  Without -r the replay starts from the
recorded processed grid, which matches best.  -r reruns preprocessing from
frame_raw as well and agrees slightly less often.
"""
import bisect
import sys

from trec import Recording


def parse_sim(path):
    frames = []
    cur = None
    for line in open(path):
        f = line.split()
        if f[0] == "F":
            cur = {"t": int(f[1]), "idx": int(f[2]), "stable": int(f[3]),
                   "report_on": int(f[4]), "mism": int(f[5]), "zones": [],
                   "peaks": [], "contacts": [], "tracks": []}
            frames.append(cur)
        elif f[0] == "Z":
            cur["zones"].append(tuple(int(v) for v in f[1:]))
        elif f[0] == "K":
            cur["peaks"].append(tuple(int(v) for v in f[1:]))
        elif f[0] == "C":
            cur["contacts"].append(tuple(int(v) for v in f[1:]))
        elif f[0] == "T":
            slot, tid, rep, x, y, gx, gy, deb, missed, age, tool = (int(v) for v in f[1:])
            cur["tracks"].append({"slot": slot, "tid": tid, "rep": rep, "x": x,
                                  "y": y, "gx": gx, "gy": gy, "deb": deb,
                                  "missed": missed, "age": age, "tool": tool})
    return frames


def same(sim_pts, dev_pts, tol=2):
    if len(sim_pts) != len(dev_pts):
        return False
    left = list(dev_pts)
    for x, y in sim_pts:
        for k, (dx, dy) in enumerate(left):
            if abs(dx - x) <= tol and abs(dy - y) <= tol:
                del left[k]
                break
        else:
            return False
    return True


def main():
    if len(sys.argv) not in (3, 5):
        print(__doc__)
        sys.exit(2)
    rec = Recording(sys.argv[1])
    if not rec.flags & 1:
        sys.exit("simcmp: header flag bit 0 is not set, so grids cannot be "
                 "matched to reports")
    sim = parse_sim(sys.argv[2])
    t0 = rec.t0()
    lo = float(sys.argv[3]) if len(sys.argv) > 3 else -1e9
    hi = float(sys.argv[4]) if len(sys.argv) > 4 else 1e9
    mt_t = [t for t, _ in rec.mt]
    n = agree = active = active_agree = 0
    first_bad = []
    for fr in sim:
        rel = (fr["t"] - t0) / 1e9
        if not lo <= rel <= hi:
            continue
        j = bisect.bisect_right(mt_t, fr["t"]) - 1
        dev = rec.mt[j][1] if j >= 0 else {}
        dev_pts = [(v["x"], v["y"]) for v in dev.values()]
        sim_pts = [(t["x"], t["y"]) for t in fr["tracks"] if t["rep"]]
        ok = same(sim_pts, dev_pts)
        n += 1
        agree += ok
        if sim_pts or dev_pts:
            active += 1
            active_agree += ok
            if not ok and len(first_bad) < 8:
                first_bad.append((rel, sim_pts, dev_pts))
    print(f"frames {n}: agree {agree} ({100 * agree / max(n, 1):.1f}%); "
          f"with contacts {active}: agree {active_agree} "
          f"({100 * active_agree / max(active, 1):.1f}%)")
    for rel, s, d in first_bad:
        print(f"  {rel:8.3f}  sim {s}  dev {d}")


if __name__ == "__main__":
    main()

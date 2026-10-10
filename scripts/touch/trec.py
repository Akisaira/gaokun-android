#!/usr/bin/env python3
"""Load gk3trec recordings (the format is described in gk3trec.c).

    python3 scripts/touch/trec.py summary FILE

"summary" lists the markers and the stretches of activity, with times in
seconds from the start of the recording, which is what simcmp.py and
outcomes.py take as time ranges.
"""
import array
import struct
import sys

REC_FRAME, REC_FRAME_RAW, REC_TOUCH, REC_PEN, REC_MARKER = 1, 2, 3, 4, 5

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
SYN_REPORT = 0
ABS_X, ABS_Y, ABS_PRESSURE = 0x00, 0x01, 0x18
ABS_MT_SLOT = 0x2F
ABS_MT_TOUCH_MAJOR = 0x30
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TOOL_TYPE = 0x37
ABS_MT_TRACKING_ID = 0x39
ABS_MT_PRESSURE = 0x3A
BTN_TOOL_PEN = 0x140
BTN_TOOL_RUBBER = 0x141
BTN_TOUCH = 0x14A

# struct input_event on arm64: struct timeval (2 x s64), u16 type, u16 code, s32 value
EVENT = struct.Struct("<qqHHi")


def grid(payload):
    """A recorded grid as array('h'), rows * cols, row-major."""
    g = array.array("h", payload)
    if sys.byteorder == "big":
        g.byteswap()
    return g


class Recording:
    def __init__(self, path):
        with open(path, "rb") as f:
            data = f.read()
        if data[:8] != b"GK3TREC1":
            raise ValueError(f"{path}: not a gk3trec file")
        self.rows, self.cols, self.flags = struct.unpack_from("<HHI", data, 8)
        self.frame_t, self.frames = [], []
        self.raw_t, self.raws = [], []
        self.touch, self.pen, self.markers = [], [], []
        off, n = 16, len(data)
        while off + 16 <= n:
            typ, ln, _res, t = struct.unpack_from("<HHIq", data, off)
            off += 16
            if off + ln > n:
                break
            payload = data[off:off + ln]
            off += ln
            if typ == REC_FRAME:
                self.frame_t.append(t)
                self.frames.append(grid(payload))
            elif typ == REC_FRAME_RAW:
                self.raw_t.append(t)
                self.raws.append(grid(payload))
            elif typ in (REC_TOUCH, REC_PEN):
                sec, usec, etype, code, value = EVENT.unpack(payload)
                ev = (sec * 1_000_000_000 + usec * 1000, etype, code, value)
                (self.touch if typ == REC_TOUCH else self.pen).append(ev)
            elif typ == REC_MARKER:
                self.markers.append((t, payload.decode(errors="replace")))
        self.mt = mt_frames(self.touch)
        self.pen_states = pen_frames(self.pen)

    def t0(self):
        """Start of the recording: the first marker, grid or touch report."""
        firsts = [t for t, _ in self.markers[:1]] + self.frame_t[:1]
        firsts += [t for t, _ in self.mt[:1]]
        return min(firsts)


def mt_frames(events):
    """Replay MT protocol B events into one snapshot per SYN_REPORT.

    Returns a list of (t_ns, {tracking_id: dict(x, y, pressure, major, tool, slot)}).
    """
    slots = {}
    cur = 0
    out = []
    for t, etype, code, value in events:
        if etype == EV_ABS:
            if code == ABS_MT_SLOT:
                cur = value
                continue
            s = slots.setdefault(cur, {"tid": -1, "x": 0, "y": 0, "pressure": 0,
                                       "major": 0, "tool": 0})
            if code == ABS_MT_TRACKING_ID:
                s["tid"] = value
            elif code == ABS_MT_POSITION_X:
                s["x"] = value
            elif code == ABS_MT_POSITION_Y:
                s["y"] = value
            elif code == ABS_MT_PRESSURE:
                s["pressure"] = value
            elif code == ABS_MT_TOUCH_MAJOR:
                s["major"] = value
            elif code == ABS_MT_TOOL_TYPE:
                s["tool"] = value
        elif etype == EV_SYN and code == SYN_REPORT:
            snap = {s["tid"]: {k: s[k] for k in ("x", "y", "pressure", "major", "tool")}
                    | {"slot": sl}
                    for sl, s in slots.items() if s["tid"] >= 0}
            out.append((t, snap))
    return out


def pen_frames(events):
    """One (t_ns, in_range, touching, x, y, pressure) per SYN_REPORT."""
    st = {"range": 0, "touch": 0, "x": 0, "y": 0, "p": 0}
    out = []
    for t, etype, code, value in events:
        if etype == EV_KEY and code in (BTN_TOOL_PEN, BTN_TOOL_RUBBER):
            st["range"] = value
        elif etype == EV_KEY and code == BTN_TOUCH:
            st["touch"] = value
        elif etype == EV_ABS and code == ABS_X:
            st["x"] = value
        elif etype == EV_ABS and code == ABS_Y:
            st["y"] = value
        elif etype == EV_ABS and code == ABS_PRESSURE:
            st["p"] = value
        elif etype == EV_SYN and code == SYN_REPORT:
            out.append((t, st["range"], st["touch"], st["x"], st["y"], st["p"]))
    return out


def segments(rec, gap_s=4.0, min_peak=600):
    """Split the recording into stretches of activity separated by gaps.

    Activity is any reported contact, the pen in range, or a grid whose
    largest cell reaches min_peak.  The recorder keeps every grid above its
    -q threshold, which lets idle noise through now and then, hence the
    higher bar here.  Returns [(t_start, t_end)].
    """
    times = [t for t, snap in rec.mt if snap]
    times += [t for t, g in zip(rec.frame_t, rec.frames) if max(g) >= min_peak]
    times += [t for t, rng, *_ in rec.pen_states if rng]
    times.sort()
    out = []
    for t in times:
        if out and t - out[-1][1] <= gap_s * 1e9:
            out[-1][1] = t
        else:
            out.append([t, t])
    return [(a, b) for a, b in out]


def summary(path):
    rec = Recording(path)
    t0 = rec.t0()
    print(f"{path}: grid {rec.rows}x{rec.cols}, frames {len(rec.frames)}, "
          f"raw {len(rec.raws)}, touch events {len(rec.touch)}, "
          f"pen events {len(rec.pen)}, MT frames {len(rec.mt)}")
    for t, label in rec.markers:
        print(f"  marker {(t - t0) / 1e9:8.2f} s  {label}")
    print("segments (gap >= 4 s):")
    for i, (a, b) in enumerate(segments(rec)):
        tids = set()
        maxc = 0
        for t, snap in rec.mt:
            if a <= t <= b:
                tids.update(snap)
                maxc = max(maxc, len(snap))
        nfr = sum(1 for t in rec.frame_t if a <= t <= b)
        pen_in = sum(1 for t, rng, *_ in rec.pen_states if a <= t <= b and rng)
        print(f"  [{i}] {(a - t0) / 1e9:7.2f}-{(b - t0) / 1e9:7.2f} s "
              f"({(b - a) / 1e9:5.1f} s): frames {nfr:5d}, touches {len(tids):4d}, "
              f"max simultaneous {maxc:2d}, pen-in-range frames {pen_in}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "summary":
        summary(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)

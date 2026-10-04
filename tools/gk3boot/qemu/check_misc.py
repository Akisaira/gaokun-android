#!/usr/bin/env python3
"""判 gk3boot 一次启动前后 misc（前 64 KiB）的变化 —— 动作模式的写盘范围与内容（设计稿 §4.12 "写盘范围最小"）。

  check_misc.py BEFORE.bin AFTER.bin [--bcab 'a=14/1/ok b=15/2'] [--rec-streak N] [--rec-flags N]
                [--rec-event fallback:a:1] [--rec-events N] [--rec-bcb-seen] [--unchanged]

只准动两处：BCAB 的槽位字段与 CRC（misc+2048 的 12–15、28–31 字节）、GK3 记录（misc+8192 起 2048 字节）。
BCB（0–2047）、BCAB 其余字节、16 KiB 起的系统区（含 virtual_ab）一个字节都不能变。
解码在这里用 Python 独立写一遍（boot_control_definition.h 的位号、README §5 的 GK3 布局），不调 libgk3core。
"""
import argparse
import struct
import sys
import zlib

fails = 0
EV = {1: "fallback", 2: "boot_corrupt", 3: "bcb_dropped", 4: "wipe_failed", 5: "refused_merging", 6: "bootloop",
      7: "noslot", 8: "migrated", 9: "bcb_ignored"}


def ok(cond, what):
    global fails
    print("  %s %s" % ("✓" if cond else "✗", what))
    if not cond:
        fails += 1


def bcab(m):
    bc = m[2048:2080]
    magic, ver = struct.unpack_from("<IB", bc, 4)
    crc_ok = struct.unpack_from("<I", bc, 28)[0] == zlib.crc32(bc[:28]) & 0xffffffff
    slots = {}
    for i, s in enumerate("ab"):
        v = struct.unpack_from("<H", bc, 12 + 2 * i)[0]
        slots[s] = (v & 15, (v >> 4) & 7, bool((v >> 7) & 1))
    return magic == 0x42414342 and ver == 1, crc_ok, slots


def fmt_slots(sl):
    return " ".join("%s=%u/%u%s" % (k, p, t, "/ok" if o else "") for k, (p, t, o) in sorted(sl.items()))


def rec(m):
    r = m[8192:10240]
    magic, ver, size, flags, dver, seq = struct.unpack_from("<IHHIII", r, 0)
    valid = magic == 0x52334B47 and ver == 1 and size == 2048 and \
        struct.unpack_from("<I", r, 2044)[0] == zlib.crc32(r[:2044]) & 0xffffffff
    head = r[26]
    evs = []
    for k in range(32):
        e = r[1024 + ((head + k) % 32) * 16:][:16]
        s, code, slot, fl, aux = struct.unpack_from("<IHBBI", e, 0)
        if s:
            evs.append((s, EV.get(code, str(code)), slot, aux))
    return dict(valid=valid, flags=flags, streak=r[20], seq=seq, events=evs, dispatch=(r[23], r[25]),
                bcb_seen=struct.unpack_from("<I", r, 356)[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--unchanged", action="store_true", help="64 KiB 逐字节不变")
    ap.add_argument("--bcab", help="写后期望的槽位，如 'a=14/1/ok b=15/2'（不写 = BCAB 逐字节不变）")
    ap.add_argument("--rec-streak", type=int)
    ap.add_argument("--rec-flags", type=lambda x: int(x, 0))
    ap.add_argument("--rec-event", help="最新一条事件 code:slot:aux，如 fallback:a:1")
    ap.add_argument("--rec-events", type=int, help="事件环里的条数")
    ap.add_argument("--rec-bcb-seen", action="store_true", help="bcb_seen = CRC32(BCB)（分派关时记下的那份）")
    ap.add_argument("--rec-dispatch", help="分派记录 why:count（why 是 gk3_bcb_kind 的数值，wipe = 3），如 3:1")
    a = ap.parse_args()
    b, c = open(a.before, "rb").read(), open(a.after, "rb").read()
    ok(len(b) == len(c) == 65536, "两份都是 64 KiB")
    diff = [i for i in range(len(b)) if b[i] != c[i]]
    print("misc 前后比对：%d 个字节变了%s" % (len(diff), "" if not diff else "（%s）" % ", ".join(
        sorted({"bcab+%d" % (i - 2048) if 2048 <= i < 2080 else "gk3rec" if 8192 <= i < 10240 else "@%d" % i
                for i in diff}, key=str)[:12])))
    if a.unchanged:
        ok(not diff, "misc 64 KiB 逐字节不变")
        return
    allowed = set(range(8192, 10240))
    if a.bcab:
        allowed |= set(range(2048 + 12, 2048 + 16)) | set(range(2048 + 28, 2048 + 32))
    stray = [i for i in diff if i not in allowed]
    ok(not stray, "只动了允许的字节（%s + GK3 记录）%s" % ("BCAB 槽位与 CRC" if a.bcab else "BCAB 不动",
                                                    "" if not stray else "；越界：%s" % stray[:16]))
    ok(b[0:2048] == c[0:2048], "BCB（0–2 KiB）原样")
    ok(b[16384:] == c[16384:], "16 KiB 起的系统区（virtual_ab 等）原样")
    bv, bcrc, bsl = bcab(b)
    av, acrc, asl = bcab(c)
    print("  BCAB 前 %s  后 %s" % (fmt_slots(bsl), fmt_slots(asl)))
    if a.bcab:
        want = {}
        for t in a.bcab.split():
            k, v = t.split("=")
            f = v.split("/")
            want[k] = (int(f[0]), int(f[1]), len(f) > 2 and f[2] == "ok")
        ok(av and acrc, "写回的 BCAB magic / version 对、CRC32（前 28 字节）对")
        ok(asl == want, "槽位 = %s" % a.bcab)
    else:
        ok(b[2048:2080] == c[2048:2080], "BCAB 逐字节不变")
    r = rec(c)
    if a.rec_streak is not None or a.rec_flags is not None or a.rec_event or a.rec_events is not None or a.rec_dispatch:
        ok(r["valid"], "GK3 记录有效（magic / version / size / CRC32）")
        print("  GK3 记录：streak=%u flags=0x%x seq=%u bcb_seen=%08x dispatch(why,count)=%s 事件=%s" % (
            r["streak"], r["flags"], r["seq"], r["bcb_seen"], r["dispatch"], r["events"]))
    if a.rec_streak is not None:
        ok(r["streak"] == a.rec_streak, "boot_streak = %d" % a.rec_streak)
    if a.rec_flags is not None:
        ok(r["flags"] == a.rec_flags, "flags = 0x%x（bit0 已迁移、bit1 回落中）" % a.rec_flags)
    if a.rec_events is not None:
        ok(len(r["events"]) == a.rec_events, "事件 %d 条" % a.rec_events)
    if a.rec_event:
        code, slot, aux = a.rec_event.split(":")
        last = r["events"][-1] if r["events"] else None
        ok(last is not None and last[1] == code and last[2] == (0xff if slot == "-" else ord(slot) - 97)
           and last[3] == int(aux), "最新事件 = %s" % a.rec_event)
    if a.rec_dispatch:
        w, n = (int(x) for x in a.rec_dispatch.split(":"))
        ok(r["dispatch"] == (w, n), "分派记录 why=%d count=%d（得到 %s）" % (w, n, r["dispatch"]))
    if a.rec_bcb_seen:
        crc = zlib.crc32(c[0:2048]) & 0xffffffff or 1
        ok(r["bcb_seen"] == crc, "bcb_seen = CRC32(BCB) = %08x" % crc)


if __name__ == "__main__":
    main()
    print("  ⇒ %s" % ("PASS" if not fails else "FAIL（%d 条）" % fails))
    sys.exit(1 if fails else 0)

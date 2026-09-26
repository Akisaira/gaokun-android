#!/usr/bin/env python3
"""汇总 AVC denial（#126，2026-09-27）。

用法：
  adb shell 'logcat -b all -d -v monotonic' > logcat.txt ; adb shell dmesg > dmesg.txt
  python3 avc-summary.py logcat.txt dmesg.txt              # permissive 普查：按主体分组、每个元组首次出现
  python3 avc-summary.py --enforcing logcat.txt dmesg.txt  # 只看 permissive=0 的（运行期试跑），带次数与对象

★ 取样先看两件事，不然会漏：
  1. 覆盖面：logcat 的 kernel 缓冲（logd 从开机就在读 kmsg）通常从 0 秒起；dmesg 的环形缓冲会滚掉开头。
  2. 审计限速：dmesg 里的 `audit_lost=` / `rate limit exceeded`。logd.rc 在 boot_completed 时
     把限速设成 5/秒（persist.logd.audit.rate 可改），开机完成那几秒最容易丢。
★ permissive 下同一个 (主体, 目标类型, 类, 权限) 只记一次：靠【改标签】修的，必须另外枚举
  全部对象（/proc/<pid>/maps、/sys/class/wakeup/*、getprop -Z …），不能只修日志里露面的那一个。
"""
import re, sys, collections

args = [a for a in sys.argv[1:] if not a.startswith('--')]
enforcing = '--enforcing' in sys.argv
rx = re.compile(r'avc:\s+denied\s+\{ ([^}]*) \} for (.*?) scontext=u:r:([^: ]+):s0\S* '
                r'tcontext=u:(?:object_r|r):([^: ]+):s0\S* tclass=(\S+) permissive=(\d)')
seen_serial = set()
first = collections.OrderedDict(); count = collections.Counter(); objs = collections.defaultdict(set)
for f in args:
    for line in open(f, errors='replace'):
        m = rx.search(line)
        if not m:
            continue
        perms, mid, s, t, c, p = m.groups()
        if enforcing != (p == '0'):
            continue
        a = re.search(r'audit\([\d.]+:(\d+)\)', line)   # 同一条记录可能同时在 dmesg 与 logcat 里
        if a:
            if a.group(1) in seen_serial:
                continue
            seen_serial.add(a.group(1))
        comm = re.search(r'comm="([^"]*)"', mid)
        name = re.search(r'(?:path|name|property|ioctlcmd)=("?[^ ]*"?)', mid)
        o = (comm.group(1) if comm else '') + ' ' + (name.group(1) if name else '')
        for perm in perms.split():
            k = (s, t, c, perm)
            count[k] += 1; objs[k].add(o.strip())
            ts = re.match(r'\s*\[?\s*(-?[\d.]+)', line)     # logcat -v monotonic 与 dmesg 的 [ 123.4] 两种格式
            first.setdefault(k, ts.group(1) if ts else '?')
by = collections.defaultdict(list)
for k in first:
    by[k[0]].append(k)
for s in sorted(by, key=lambda x: -len(by[x])):
    print(f"== {s} ({len(by[s])})")
    for k in by[s]:
        o = sorted(objs[k])
        more = f" (+{len(o) - 2})" if len(o) > 2 else ""
        print(f"  {first[k]:>9} x{count[k]:<4} {k[1]}:{k[2]} {k[3]}   {'; '.join(o[:2])}{more}")

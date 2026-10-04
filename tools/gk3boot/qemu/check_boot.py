#!/usr/bin/env python3
"""判 gk3boot（S5）一次夹具运行的 PASS / FAIL：串口输出 + gk3boot 写在 ESP 上的日志。

  check_boot.py --kind linux|real|failopen --serial SERIAL.log --logfile boot-0.txt --manifest manifest.json
                --version VER [--bootimg 期望槽的 boot.img] [--slot a|b] [--event none|fallback|forced]
                [--decision 'boot slot=_b active=_b fallback=0'] [--would-write '_b tries 6 -> 5']
                [--dt-marker STR --initrd-marker STR] [--stage misc|boot] [--proc-vector FILE]

kind：
  linux     Debian 通用内核 + 测试 initramfs：/init 打出 /proc/cmdline、dtb 标记、initrd 标记后关机
  real      真 gaokun3 boot.img：它在 QEMU 里一行也不打（没有 PL011 驱动，zboot stub 也不出声），
            只能看 QEMU -d int 的记录里 CPU 有没有跑进内核虚拟地址；另核 cmdline 与实机逐字节
  failopen  gk3boot 在 --stage 失败：写日志、冷复位，下一次 systemd-boot 进默认的直连条目（夹具里的假 Android）

cmdline 的期望值在这里用 Python 独立算一遍（mkbootimg 拼法 + 同名键去重 + 按 §4.3.1 的顺序追加），
不调 libgk3core —— 两边各算各的再对拍。逐条打印断言；有一条不过就退出码 1。
"""
import argparse
import json
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Za-z0-9]|\x1b[=>]|\r")
OURS = ("androidboot.slot_suffix", "androidboot.bootloader", "androidboot.gk3boot.event",
        "androidboot.gk3boot.entry", "androidboot.gk3boot.mode")

fails = 0


def ok(cond, what):
    global fails
    print("  %s %s" % ("✓" if cond else "✗", what))
    if not cond:
        fails += 1


def bootimg_cmdline(path):
    h = open(path, "rb").read(4096)
    return (h[64:576].split(b"\0")[0] + h[608:1632].split(b"\0")[0]).decode()


def tokens(s):
    """内核 next_arg 的分词：空白分隔，双引号里的空白不算。"""
    out, cur, q = [], "", False
    for c in s:
        if c == '"':
            q = not q
        if c in " \t\n\r" and not q:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += c
    if cur:
        out.append(cur)
    return out


def key(t):
    return t.split("=", 1)[0]


def expected_cmdline(base, slot, version, event, entry):
    t = [x for x in tokens(base) if key(x) not in OURS]
    t += ["androidboot.slot_suffix=_" + slot, "androidboot.bootloader=gk3boot-" + version,
          "androidboot.gk3boot.event=" + event]
    if entry:
        t.append("androidboot.gk3boot.entry=" + entry)
    t.append("androidboot.gk3boot.mode=observe")
    return " ".join(t)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kind", required=True, choices=["linux", "real", "failopen"])
    ap.add_argument("--label", default="")
    ap.add_argument("--serial", required=True)
    ap.add_argument("--logfile", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--bootimg")
    ap.add_argument("--slot", default="a")
    ap.add_argument("--event", default="none")
    ap.add_argument("--decision")
    ap.add_argument("--would-write")
    ap.add_argument("--dt-marker")
    ap.add_argument("--initrd-marker")
    ap.add_argument("--stage")
    ap.add_argument("--proc-vector")
    ap.add_argument("--int-log", help="real：QEMU -d int 的记录")
    ap.add_argument("--espfull", action="store_true", help="ESP 写满：没有日志文件，改读屏幕（串口）上的那份")
    a = ap.parse_args()
    m = json.load(open(a.manifest))
    s = ANSI.sub("", open(a.serial, "rb").read().decode("utf-8", "replace"))
    try:
        lg = open(a.logfile, "rb").read().decode("utf-8", "replace")
    except OSError:
        lg = ""
    if a.espfull:
        # 写日志失败不能挡启动（§4.12）：文件不该存在；屏幕上的 gk3_logf 行（不含只进文件的细节）照判
        ok(lg == "", "ESP 满：没有日志文件")
        has_full = re.search(r"^!! log: ESP free space \d+ bytes < 1048576, not writing$", s, re.M) and \
            re.search(r"^!! no log file \(screen only\); continuing$", s, re.M)
        ok(bool(has_full), "屏幕上记了 \"!! log: ESP free space … not writing\" 并继续（满盘上不建目录，免得 FAT 驱动写坏 ESP）")
        lg = s
    entry = m.get("oneshot")

    def has(text, pat, what=None):
        mm = re.search(pat, text, re.M)
        ok(mm is not None, what or pat)
        return mm

    def pos(text, pat):
        mm = re.search(pat, text, re.M)
        return mm.start() if mm else -1

    print("gk3boot 的日志（%s，%d 字节）：" % ("屏幕" if a.espfull else "ESP 上 \\EFI\\gk3boot\\log\\boot-0.txt", len(lg)))
    ok(len(lg) > 0, "日志在")
    has(lg, r"^gk3boot %s  \(S5 minimal, observe-only build" % re.escape(a.version), "版本串 %s" % a.version)
    has(lg, r"^watchdog: 120 s armed$", "看门狗 120 秒")
    has(lg, r'^load_options: "%s"$' % re.escape(m.get("gk3boot_options", "")), "收到条目的 options")
    has(lg, r"^mode: observe force_slot=", "观察模式")
    has(lg, r"^disk: gpt [0-9a-f-]{36}, \d+ partitions, misc/boot_a/boot_b/super/userdata unique, esp=p1 ",
        "定位本盘 + 主 GPT + 五个名字唯一 + ESP 对得上")
    if a.decision:
        has(lg, r"^decision: %s$" % re.escape(a.decision), "选槽决策：%s" % a.decision)
    if a.would_write:
        has(lg, r"^would \(action\): write misc\+0x800: %s \(NOT written; " % re.escape(a.would_write),
            "动作模式会扣 tries：%s（观察模式没写）" % a.would_write)

    if a.kind == "failopen":
        has(lg, r"^!! FAIL-OPEN at %s: " % re.escape(a.stage), "在 %s 这一步 fail-open" % a.stage)
        has(lg, r"^gk3boot\.result=fail-open stage=%s " % re.escape(a.stage), "结果行 result=fail-open")
        ok("handoff: LoadImage" not in lg, "没走到交接")
        print("串口输出：")
        p1 = pos(s, r"^!! FAIL-OPEN at %s" % re.escape(a.stage))
        p2 = pos(s, r'^GK3-FAKE-ANDROID booted entry="%s"' % re.escape(m["default_entry"]))
        ok(p1 >= 0, "屏幕上有 FAIL-OPEN")
        ok(p2 > p1 >= 0, "冷复位之后 systemd-boot 进了默认的直连条目 %s" % m["default_entry"])
        ok(len(re.findall(r"^gk3boot \S+  \(S5 minimal", s, re.M)) == 1, "gk3boot 只跑了一次（OneShot 读后即删，没有循环）")
        return

    # —— 交接路径 ——
    slot = a.slot
    has(lg, r"^slot: _%s \(" % slot, "启动 _%s" % slot)
    has(lg, r"^boot_%s: read [\d.]+ ms, sha1\(id\) [\d.]+ ms: OK$" % slot, "boot_%s 整份读进来、SHA1(id) 与头一致" % slot)
    base = bootimg_cmdline(a.bootimg)
    want = expected_cmdline(base, slot, a.version, a.event, entry)
    mm = has(lg, r"^cmdline\(\d+\): (.*)$", "日志里有拼好的 cmdline")
    got = mm.group(1) if mm else ""
    ok(got == want, "cmdline 与独立算出的期望逐字节一致" + ("" if got == want else "\n      得到 %s\n      期望 %s" % (got, want)))
    ok(got.count("androidboot.slot_suffix=") == 1, "slot_suffix 恰好一个（boot.img 里旧的被去掉）")
    if len(base.encode()) > 511:
        ok(True, "boot.img 的 cmdline %d 字节 > 511：头 + extra_cmdline 拼接也对" % len(base.encode()))
    has(lg, r"^handoff: LoadImage\(\d+ bytes\) SUCCESS in \d+ ms$", "缓冲区 LoadImage 内核")
    has(lg, r"^handoff: dtb \d+ bytes installed as config table ", "DTB 配置表装上")
    has(lg, r"^handoff: initrd \d+ bytes on LINUX_EFI_INITRD_MEDIA LoadFile2 ", "initrd LoadFile2 装上")
    has(lg, r"^handoff: LoadOptions %d bytes$" % ((len(want) + 1) * 2), "LoadOptions = UCS-2 cmdline + NUL")
    if not a.espfull:
        has(lg, r"^gk3boot\.result=handoff ", "交接前日志已落盘并关闭")
        ok(not re.search(r"^!! ", lg, re.M), "日志里没有错误行")

    if a.kind == "real":
        print("串口与 QEMU 异常记录（真 gaokun3 内核）：")
        ok(not re.search(r"FAIL-OPEN|StartImage returned", s), "StartImage 没有返回（没有 fail-open）")
        ok(len(re.findall(r"^gk3boot \S+  \(S5 minimal", s, re.M)) == 1, "gk3boot 只跑了一次（机器没有复位回来）")
        it = open(a.int_log, "rb").read().decode("utf-8", "replace") if a.int_log else ""
        mm = re.search(r"ELR (0xffff[0-9a-f]+)", it)
        ok(mm is not None, "CPU 跑进了内核虚拟地址（%s）：zboot 解压、ExitBootServices、进内核都发生了"
           % (mm.group(1) if mm else "没有"))
        if a.proc_vector:
            proc = open(a.proc_vector).read().strip()
            t = tokens(proc)
            old = " ".join(x for x in t if not x.startswith("initrd="))
            new = " ".join(x for x in tokens(got) if key(x) not in OURS[1:])
            ok(new == old, "去掉新增的 androidboot.bootloader / gk3boot.* 后，与实机直连条目的 /proc/cmdline（去掉 "
               "systemd-boot 加的 initrd=）逐字节一致" + ("" if new == old else "\n      得到 %s\n      实机 %s" % (new, old)))
        return

    has(lg, r"^handoff: dtb \d+ bytes installed as config table @0x[0-9a-f]+ \(replaced 0x[1-9a-f][0-9a-f]*\)$",
        "固件（acpi=off）自己先装了一张 DTB 表，gk3boot 的把它换掉")
    print("串口输出（内核 EFI stub）：")
    has(s, r"EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path", "stub 从 LoadFile2 拿到 initrd")
    has(s, r"EFI stub: Using DTB from configuration table", "stub 用的是配置表里的 DTB")
    has(s, r"EFI stub: Exiting boot services", "stub 自己 ExitBootServices（gk3boot 没有越俎代庖）")
    print("串口输出（测试 initramfs 的 /init）：")
    has(s, r"^GK3-INIT hello from the fixture initramfs", "内核起来、跑到了 initramfs 的 /init")
    mm = has(s, r"^GK3-INIT cmdline=(.*)$", "/init 打出 /proc/cmdline")
    ok(mm is not None and mm.group(1).strip() == want, "内核的 /proc/cmdline == gk3boot 的 LoadOptions（LoadOptions 通路）")
    mm = has(s, r"^GK3-INIT dt_marker=(.*)$", "/init 打出 dtb 标记")
    ok(mm is not None and mm.group(1).strip() == a.dt_marker,
       "dtb 标记 = %s（内核用的是 gk3boot 装的 dtb，不是固件自己的）" % a.dt_marker)
    mm = has(s, r"^GK3-INIT initrd_marker=(.*)$", "/init 打出 initrd 标记")
    ok(mm is not None and mm.group(1).strip() == a.initrd_marker, "initrd 标记 = %s（initrd 通路）" % a.initrd_marker)
    has(s, r"^GK3-INIT efi=present$", "/sys/firmware/efi 在（EFI 系统表 / 运行时服务随交接保留）")
    has(s, r"^GK3-INIT done, powering off$", "/init 正常走完")


if __name__ == "__main__":
    main()
    print("  ⇒ %s" % ("PASS" if not fails else "FAIL（%d 条）" % fails))
    sys.exit(1 if fails else 0)

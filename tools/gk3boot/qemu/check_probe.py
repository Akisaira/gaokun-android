#!/usr/bin/env python3
"""判一次夹具运行的 PASS / FAIL：串口输出 + 探针写在 ESP 上的日志。

  check_probe.py --scenario first|second|broken --serial SERIAL.log --manifest manifest.json \\
                 --logfile log-N.txt --log-n N --bootcount +2-1

逐条打印每个断言的结果；有一条不过就退出码 1。
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MISC_VEC = os.path.join(os.path.dirname(HERE), "test", "vectors", "misc-20261005-1791053208.bin")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Za-z0-9]|\x1b[=>]|\r")

fails = 0


def ok(cond, what):
    global fails
    print("  %s %s" % ("✓" if cond else "✗", what))
    if not cond:
        fails += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenario", required=True, choices=["first", "second", "broken", "espfull"])
    ap.add_argument("--label")
    ap.add_argument("--serial", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--logfile", help="ESP 上取回的日志（espfull 场景没有）")
    ap.add_argument("--log-n", type=int, required=True)
    ap.add_argument("--bootcount", required=True, help="期望 LoaderBootCountPath 里条目的计数后缀，如 +2-1")
    a = ap.parse_args()
    m = json.load(open(a.manifest))
    s = ANSI.sub("", open(a.serial, "rb").read().decode("utf-8", "replace"))
    # 注入按键的注释行可能把某一行串口输出劈成两半：去掉它再判
    s = re.sub(r"\n# INJECTED [^\n]*\n", "", s)

    def has(pat, what=None):
        ok(re.search(pat, s, re.M) is not None, what or pat)

    def pos(pat):
        mm = re.search(pat, s, re.M)
        return mm.start() if mm else -1

    misc_sha1 = hashlib.sha1(open(MISC_VEC, "rb").read()).hexdigest()
    broken = a.scenario == "broken"
    full = a.scenario == "espfull"

    print("串口输出：")
    has(r"^gk3probe \S+  \(read-only probe", "探针起来了，打印了版本")
    has(r"^watchdog: armed 60 s$", "看门狗 60 秒")
    has(r'^load_options: \(\d+ bytes\) "gk3probe\.hold=1 gk3probe\.keyscan=3000"$', "收到条目的 options（LoadOptions）")
    has(r"^key t=\d+ ms src=\d+ scan=0x0000 unicode=0x0067 ", "串口注入的 'g' 被按键扫描读到")
    has(r"^file_path: \\EFI\\gk3boot\\probe\\gk3probe\.efi$", "自身文件路径")
    has(r"^device_path: PciRoot\(0x0\)/Pci\(0x1,0x0\)/NVMe\(0x1,[0-9a-f-]+\)/HD\(1,GPT,%s," % m["esp_partuuid"],
        "自身设备路径 = NVMe/HD(1,GPT,实机 ESP 的 PARTUUID)")
    if full:
        # 探针所在目录本来就有（gk3probe.efi 就在里面），建 0 字节文件只占目录项、不要簇 → 失败落在第一次 Write
        has(r"^!! first write to log file: VOLUME_FULL \(continuing, screen only\)$", "ESP 满：写日志失败被记录（VOLUME_FULL）")
        has(r"^!! log file write failed: VOLUME_FULL", "收尾时再报一次，照常复位")
    else:
        has(r"^log_file: \\EFI\\gk3boot\\probe\\log-%d\.txt$" % a.log_n, "日志文件名 log-%d.txt（递增、不覆盖）" % a.log_n)
    has(r'^var LoaderBootCountPath: .*"\\loader\\entries\\gk3probe%s\.conf"$' % re.escape(a.bootcount),
        "LoaderBootCountPath = gk3probe%s.conf" % a.bootcount)
    has(r'^var LoaderEntrySelected: .*"gk3probe\.conf"$', "LoaderEntrySelected = gk3probe.conf")
    has(r'^var LoaderDevicePartUUID: .*"%s"$' % m["esp_partuuid"].upper(), "LoaderDevicePartUUID = ESP 的 PARTUUID")
    has(r'^var LoaderEntryOneShot: \(not set\)$', "OneShot 已被 systemd-boot 消费")
    has(r"^whole_disk: PciRoot\(0x0\)/Pci\(0x1,0x0\)/NVMe\(0x1,[0-9a-f-]+\)$", "ESP → 整盘（去掉 HD 节点）")
    has(r"^gpt: disk=%s entries=128 x 128 @LBA2 " % m["disk_guid"], "主 GPT 用 libgk3core 解析")
    has(r'^esp_in_gpt: p1 name="esp" partuuid MATCHES device path$', "GPT 里的 ESP 与设备路径对上")
    if not broken:
        has(r"^unique_required\(misc,boot_a,boot_b,super,userdata\): YES$", "五个名字各恰好一次")
        has(r"^misc: p4 lba=34 size=1007 KiB read 64 KiB in [\d.]+ ms sha1\(0-64K\)=%s$" % misc_sha1,
            "misc 读 64 KiB，SHA-1 与实机向量一致")
        has(r'^bcab: valid suffix="_a" nb_slot=2 merge=0 ', "BCAB 解码（实机向量）")
        has(r"^would_select \(NOT written\): boot slot=_a active=_a fallback=0 decrement=0", "模拟选槽 = _a，不扣 tries")
        has(r"^boot_b: id=%s " % m["boot_b_id"], "boot_b 头里的 id")
        has(r"^boot_b: read \d+ bytes in [\d.]+ ms .*OK \(matches header\)$", "boot_b 整份复算 SHA1(id) 一致")
    else:
        has(r"^unique boot_b    duplicate$", "重名的 boot_b 报 duplicate")
        has(r"^unique super     not found$", "缺失的 super 报 not found")
        has(r"^unique_required\(misc,boot_a,boot_b,super,userdata\): NO$", "必需名字不全唯一 → NO")
        has(r"^!! boot_b: duplicate$", "boot_b 一节记错误后跳过")
    has(r"^boot_a: id=%s " % m["boot_a_id"], "boot_a 头里的 id")
    has(r"^boot_a: read \d+ bytes in [\d.]+ ms .*OK \(matches header\)$", "boot_a 整份复算 SHA1(id) 一致")
    has(r"^EFI_USB_DEVICE_PROTOCOL\(qcom d9d9ce48\): absent$", "EFI_USB_DEVICE_PROTOCOL：absent（AAVMF 里当然没有）")
    has(r"^EFI_USBFN_IO_PROTOCOL: absent$", "EFI_USBFN_IO_PROTOCOL：absent")
    has(r"^gop handles: [1-9]", "GOP 至少一个")
    has(r"^memmap: \d+ descriptors", "内存图")
    has(r"^loadimage\[vendor-dp\]: child saw load_options_size=\d+ .* -> PASS", "缓冲区 LoadImage（厂商设备路径）+ StartImage")
    has(r"^loadimage\[null-dp\]: child saw load_options_size=\d+ .* -> PASS", "缓冲区 LoadImage（空设备路径）+ StartImage")
    if broken or full:
        need = 2 if broken else 1
        mm = re.search(r"^probe\.done errors=(\d+) ", s, re.M)
        ok(mm is not None and int(mm.group(1)) >= need,
           "出错后照样跑完（errors=%s ≥ %d）" % (mm.group(1) if mm else "?", need))
    else:
        has(r"^probe\.done errors=0 ", "跑完，errors=0")
        ok(not re.search(r"^!! ", s, re.M), "没有任何 '!!' 错误行")
    if not full:
        has(r"^log file log-%d\.txt: \d+ bytes, close=SUCCESS, read-back MATCHES$" % a.log_n, "日志写盘后读回一致")
    p_done, p_reset = pos(r"^probe\.done "), pos(r"^gk3probe: ResetSystem\(EfiResetCold\)$")
    p_fake = pos(r'^GK3-FAKE-ANDROID booted entry="%s"' % re.escape(m["default_entry"]))
    ok(0 <= p_done < p_reset < p_fake, "顺序：probe.done → ResetSystem(Cold) → 下一次启动进了 default 条目 %s" % m["default_entry"])
    has(r'^GK3-FAKE-ANDROID booted .*androidboot\.slot_suffix=_a"$', "default 条目带 androidboot.slot_suffix=_a")
    ok(s.count("gk3probe: ResetSystem") == 1, "探针只跑了一次（OneShot 只生效一次）")

    if full:
        ok(a.logfile is None or not os.path.exists(a.logfile) or os.path.getsize(a.logfile) == 0,
           "ESP 上没有日志内容（至多一个 0 字节的 log-%d.txt）" % a.log_n)
        finish(a)
    print("ESP 上的日志文件：")
    lf = open(a.logfile, "rb").read().decode("utf-8", "replace")
    ok(lf.startswith("gk3probe "), "以版本行开头")
    ok(re.search(r"\nprobe\.done errors=\d+ total=\d+ ms\n$", lf) is not None, "以 probe.done 收尾（完整写完）")
    ok(re.search(r"^  Conventional +0x[0-9a-f]+-0x[0-9a-f]+ +\d+ pages", lf, re.M) is not None,
       "含只进文件的细节行（内存图逐条）")
    ok(re.search(r"^       type=0fc63daf-8483-4772-8e79-3d69d8477de4$", lf, re.M) is not None, "含 GPT 类型 GUID 细节行")
    ok("\x1b" not in lf and "\r" not in lf, "纯文本（无转义、无 CR）")

    finish(a)


def finish(a):
    print("== %s：%s ==" % (a.label or a.scenario, "PASS" if not fails else "FAIL（%d 条）" % fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""无头跑一次 QEMU aarch64 + AAVMF，收串口输出，直到虚拟机关机或超时。

  qemu_run.py --disk DISK --vars VARS.fd --log OUT.log [--code AAVMF_CODE.fd] [--timeout 600]
              [--inject-on 'keyscan.begin' --inject 'g']

- 串口接 stdio：原样（含 ANSI 转义）写进 --log；
- 看到 --inject-on 那一行后，往串口敲 --inject 的字符（测探针的按键记录；TerminalDxe 把它变成 ConIn 按键）；
  只在第一次出现时敲 —— 第二次启动（假 Android）不受影响；
- 退出码：QEMU 正常退出（客体 ResetSystem(Shutdown)）→ 0；超时 → 124（并杀掉 QEMU）。
不带 -no-reboot：探针的 ResetSystem(EfiResetCold) 在 QEMU 里就是一次真复位，接着跑下一次启动。
"""
import argparse
import os
import re
import select
import subprocess
import sys
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Za-z0-9]|\x1b[=>]")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--disk", required=True)
    ap.add_argument("--vars", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--code", default="/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--inject-on")
    ap.add_argument("--inject", default="g")
    a = ap.parse_args()

    cmd = [
        "qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a76", "-smp", "2", "-m", "2048",
        "-nodefaults", "-no-user-config", "-display", "none",
        "-drive", "if=pflash,format=raw,unit=0,readonly=on,file=" + a.code,
        "-drive", "if=pflash,format=raw,unit=1,file=" + a.vars,
        # 本机是 NVMe（docs/hw-inventory.md）：设备路径的形状 …/NVMe(…)/HD(…) 与实机一致
        "-drive", "if=none,id=nvm,format=raw,file=" + a.disk,
        "-device", "nvme,serial=gk3fixture,drive=nvm",
        # 给 GOP（virtio-gpu）和一个 USB 键盘（ConIn 多一个物理源），探针的显示 / 按键两节才有东西可看
        "-device", "virtio-gpu-pci", "-device", "qemu-xhci", "-device", "usb-kbd",
        "-serial", "stdio", "-monitor", "none",
    ]
    t0 = time.time()
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    injected = False
    pending = b""
    rc = None
    with open(a.log, "wb") as log:
        log.write(("# " + " ".join(cmd) + "\n").encode())
        while True:
            if time.time() - t0 > a.timeout:
                p.kill()
                p.wait()
                log.write(b"\n# TIMEOUT\n")
                print("✗ QEMU 超时（%d 秒）" % a.timeout, file=sys.stderr)
                rc = 124
                break
            r, _, _ = select.select([p.stdout], [], [], 0.5)
            if r:
                b = os.read(p.stdout.fileno(), 65536)
                if not b:
                    p.wait()
                    rc = 0
                    break
                log.write(b)
                log.flush()
                pending = (pending + ANSI.sub(b"", b))[-8192:]
                if a.inject_on and not injected and a.inject_on.encode() in pending:
                    time.sleep(0.5)
                    p.stdin.write(a.inject.encode())
                    p.stdin.flush()
                    injected = True
                    log.write(("\n# INJECTED %r at %.1fs\n" % (a.inject, time.time() - t0)).encode())
            elif p.poll() is not None:
                rc = 0
                break
        log.write(("\n# qemu exit=%s after %.1fs\n" % (p.returncode, time.time() - t0)).encode())
    print("  QEMU 结束：%.1f 秒，退出码 %s%s" % (time.time() - t0, p.returncode, "，已注入按键" if injected else ""))
    sys.exit(rc)


if __name__ == "__main__":
    main()

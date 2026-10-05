#!/usr/bin/env python3
"""执行端 initramfs（fastboot.img）的 QEMU 场景测试。由 run-tests.sh 在 fbi-build 容器里调用。

  qemu_fbi.py --img fastboot.img --kernel vmlinuz --modules DIR --fake fake-fastbootd --work DIR [场景…]

每个场景起一次 QEMU（virt，TCG）：
  -kernel <Debian 通用 arm64 内核> -initrd <fastboot.img + 测试 overlay（gzip cpio 直接拼接，内核按顺序解）>
  -append "console=ttyAMA0 panic=10 gk3.mode=fastboot gk3.why=… gk3.slot=… gk3.bootver=… gk3.disk=<misc PARTUUID>"
测试 overlay 只多出：/etc/gk3-fbi/test-hook（insmod 模块、改 UDC 名、打开 trace、缩短空闲超时）、
/etc/gk3-fbi/stub.conf、/lib/modules-test/*.ko，以及（需要时）假 /bin/gk3-fastbootd。被测的 /init、gk3-fbi、
busybox 都是 fastboot.img 里原样那一份。
串口 = /dev/console = 界面输出；按键走 HMP sendkey → virtio-keyboard → evdev（与真机同一条 evdev 路径）。
"""
import argparse
import gzip
import os
import re
import socket
import struct
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
GK3 = os.path.dirname(os.path.dirname(HERE))
sys.dont_write_bytecode = True                 # 不在 qemu/ 里留 __pycache__
sys.path.insert(0, os.path.join(GK3, "qemu"))
import fixture  # noqa: E402  实机 GPT 向量、GPT 头 / 表项、BCB 写法、newc cpio

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\[[0-9;]*\]|\x1b[()][A-Za-z0-9]|\x1b[=>]")
SECTOR = 512
BOOTVER = "0.9.9-fbitest"
RESULTS = []


class Fail(Exception):
    pass


# ---------------------------------------------------------------- 盘

def mkdisk(path, misc_bytes):
    """GPT：misc 坐在 LBA 34–2047（同实机），其余五个各 1 MiB。PARTUUID / 类型 / 磁盘 GUID 照实机向量。"""
    disk_guid, real = fixture.real_gpt()
    parts = [("misc", 34, 2047)]
    lba = 2048
    for n in ("boot_a", "boot_b", "super", "userdata", "metadata"):
        parts.append((n, lba, lba + 2047))
        lba += 2048
    last_usable = lba + 2047
    total = last_usable + 1 + 33
    ents = {}
    for n, first, last in parts:
        r = real[n]
        ents[r["index"]] = fixture.gpt_entry(r["type"], r["guid"], first, last, r["attrs"], n)
    table = b"".join(ents.get(i + 1, b"\0" * 128) for i in range(128))
    tcrc = zlib.crc32(table) & 0xffffffff
    with open(path, "wb") as f:
        f.truncate(total * SECTOR)
        mbr = bytearray(SECTOR)
        struct.pack_into("<BBBBBBBBII", mbr, 446, 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, total - 1)
        mbr[510:512] = b"\x55\xaa"
        f.write(mbr)
        f.write(fixture.gpt_header(1, total - 1, 34, last_usable, 2, disk_guid, tcrc))
        f.write(table)
        f.seek((total - 33) * SECTOR)
        f.write(table)
        f.write(fixture.gpt_header(total - 1, 1, 34, last_usable, total - 33, disk_guid, tcrc))
        f.seek(34 * SECTOR)
        f.write(misc_bytes)
    import uuid
    return str(uuid.UUID(bytes_le=real["misc"]["guid"]))


# ---------------------------------------------------------------- overlay

def overlay(work, name, a, hook_extra="", stub_conf=None, fake=True, gpu=False, img=None):
    mods = [m.strip() for m in open(os.path.join(a.modules, "order")) if m.strip()]
    skip = set()
    if not gpu:
        # virtio_gpu 及其 drm 依赖只给 screen 场景（加载要好几秒）
        skip = {m for m in mods if m.startswith(("drm", "virtio-gpu", "virtio_gpu", "virtio_dma_buf"))}
    if "nodummy" in hook_extra:
        skip |= {m for m in mods if m.startswith("dummy_hcd")}
    mods = [m for m in mods if m not in skip]
    hook = ["# 测试钩子（只在测试 overlay 里有）：由 /init 在解析完 cmdline 之后 source",
            "for m in %s; do insmod /lib/modules-test/$m 2>/dev/null || echo \"[test-hook] insmod $m failed\" > /dev/console; done" % " ".join(mods),
            "GK3_UDC=dummy_udc.0", "GK3_TRACE=1", "GK3_QUIET=0",
            "echo '[test-hook] modules loaded' > /dev/console",
            # keyd 的原始事件日志也抄到串口（断言键码用）
            "( while [ ! -f /run/gk3/keys.log ]; do sleep 0.2; done; tail -f /run/gk3/keys.log > /dev/console ) &",
            hook_extra]
    ents = [("etc", 0o040755, b"", 0, 0), ("etc/gk3-fbi", 0o040755, b"", 0, 0),
            ("etc/gk3-fbi/test-hook", 0o100644, ("\n".join(hook) + "\n").encode(), 0, 0),
            ("lib", 0o040755, b"", 0, 0), ("lib/modules-test", 0o040755, b"", 0, 0)]
    for m in mods:
        ents.append(("lib/modules-test/" + m, 0o100644, open(os.path.join(a.modules, m), "rb").read(), 0, 0))
    if stub_conf is not None:
        ents.append(("etc/gk3-fbi/stub.conf", 0o100644, stub_conf.encode(), 0, 0))
    if fake:
        ents += [("bin", 0o040755, b"", 0, 0),
                 ("bin/gk3-fastbootd", 0o100755, open(a.fake, "rb").read(), 0, 0)]
    out = os.path.join(work, name + ".initrd")
    with open(out, "wb") as f:
        f.write(open(img or a.img, "rb").read())
        f.write(gzip.compress(fixture.cpio_newc(ents), mtime=0))
    return out


# ---------------------------------------------------------------- QEMU

class VM:
    def __init__(self, a, name, initrd, why, disks, slot="a", extra_append="", gpu=False):
        self.name = name
        self.log_path = os.path.join(a.work, name + ".log")
        self.mon = os.path.join(a.work, name + ".mon")
        if os.path.exists(self.mon):
            os.unlink(self.mon)
        append = ("console=ttyAMA0 panic=10 gk3.mode=fastboot gk3.why=%s gk3.slot=%s gk3.bootver=%s gk3.disk=%s %s"
                  % (why, slot, BOOTVER, a.partuuid, extra_append)).strip()
        cmd = ["qemu-system-aarch64", "-M", "virt", "-cpu", "cortex-a76", "-smp", "2", "-m", "1024",
               "-nodefaults", "-no-user-config", "-display", "none", "-no-reboot",
               "-kernel", a.kernel, "-initrd", initrd, "-append", append,
               "-serial", "stdio", "-monitor", "unix:%s,server,nowait" % self.mon,
               "-device", "virtio-keyboard-pci"]
        for i, d in enumerate(disks):
            cmd += ["-drive", "if=none,id=d%d,format=raw,readonly=on,file=%s" % (i, d),
                    "-device", "virtio-blk-pci,drive=d%d" % i]
        if gpu:
            # 与本机面板同尺寸（竖屏 1600x2560 原生，fbcon=rotate:1 转成横向）：截图与真机的行列数一致
            cmd += ["-device", "virtio-gpu-pci,xres=1600,yres=2560"]
        self.t0 = time.time()
        self.p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  bufsize=0)
        self.raw = b""
        self.text = ""
        self.pos = 0
        self.log = open(self.log_path, "wb")
        self.log.write(("# " + " ".join(cmd) + "\n").encode())
        self.exited = None

    def pump(self, wait):
        import select
        r, _, _ = select.select([self.p.stdout], [], [], wait)
        if r:
            b = os.read(self.p.stdout.fileno(), 65536)
            if not b:
                self.p.wait()
                self.exited = self.p.returncode
                return
            self.raw += b
            self.log.write(b)
            self.log.flush()
            self.text = ANSI.sub(b"", self.raw).decode("utf-8", "replace").replace("\r", "")
        elif self.p.poll() is not None:
            self.exited = self.p.returncode

    def expect(self, pat, timeout=60, regex=False):
        """从上次匹配的位置往后找；找到就把位置挪到匹配末尾。"""
        end = time.time() + timeout
        while True:
            if regex:
                m = re.compile(pat).search(self.text, self.pos)
                if m:
                    self.pos = m.end()
                    return m
            else:
                i = self.text.find(pat, self.pos)
                if i >= 0:
                    self.pos = i + len(pat)
                    return pat
            if self.exited is not None or time.time() > end:
                tail = self.text[-1500:]
                raise Fail("等不到 %r（%s，%.0f 秒）\n--- 串口尾部 ---\n%s" % (
                    pat, "QEMU 已退出" if self.exited is not None else "超时", time.time() - self.t0, tail))
            self.pump(0.3)

    def absent(self, pat, since):
        if pat in self.text[since:]:
            raise Fail("不该出现 %r" % pat)

    def hmp(self, line):
        for _ in range(50):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.mon)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise Fail("连不上 QEMU monitor")
        s.settimeout(5)
        try:
            s.recv(4096)
        except socket.timeout:
            pass
        s.sendall((line + "\n").encode())
        time.sleep(0.3)
        resp = b""
        try:
            resp = s.recv(65536)
        except socket.timeout:
            pass
        s.close()
        self.log.write(b"\n# HMP " + line.encode() + b" -> " + resp.replace(b"\r", b"") + b"\n")

    def key(self, k):
        self.log.write(("\n# SENDKEY %s at %.1fs\n" % (k, time.time() - self.t0)).encode())
        self.hmp("sendkey " + k)

    def wait_exit(self, timeout=120):
        end = time.time() + timeout
        while self.exited is None:
            if time.time() > end:
                raise Fail("QEMU 没有退出")
            self.pump(0.3)
        return self.exited

    def kill(self):
        if self.exited is None:
            self.p.kill()
            self.p.wait()
        self.log.write(("\n# end after %.1fs\n" % (time.time() - self.t0)).encode())
        self.log.close()


def ready(vm, keys=True):
    vm.expect("[test-hook] modules loaded", 120)
    vm.expect("[gk3-fbi] start: mode=fastboot")
    if keys:
        p = vm.pos
        vm.expect("[gk3-fbi] screen: page=", 60)
        keys_ready(vm)
        vm.pos = p


def keys_ready(vm):
    """先确认按键通路通了再测：QEMU 刚起来那几秒 sendkey 会丢（keyd 还没打开 event0 / 客体还没收）。
    敲一个不映射到菜单的键（左 Shift，KEY_LEFTSHIFT=42），直到 keyd 的原始事件日志里出现它。"""
    for _ in range(15):
        vm.key("shift")
        try:
            vm.expect("code=42 (?) value=1 -> -", 4)
            return
        except Fail:
            continue
    raise Fail("按键通路一直不通（keyd 没收到 KEY_LEFTSHIFT）")


def sel(vm, page, item):
    vm.expect("[gk3-fbi] screen: page=%s sel=" % page)
    vm.expect(" item=%s" % item, 10)


# ---------------------------------------------------------------- 场景

def sc_fastboot(a):
    """why=bootloader：gadget 建好、绑 UDC、被（dummy_hcd 的）主机枚举；界面；音量 / 方向键 / 电源选择；看日志；
    Restart fastboot（软重新枚举）；Power off。"""
    # 顺带测 gk3-fbi find（/init 不用它，留给排障与 gk3-fastbootd 对照）；FBI_DEBUG_HOOK 给手工排障塞额外命令
    hook = '( sleep 1; echo "[find] $(gk3-fbi find $DISK)" > /dev/console ) &\n' + os.environ.get("FBI_DEBUG_HOOK", "")
    ini = overlay(a.work, "fastboot", a, stub_conf="serve_exits=hold\n", hook_extra=hook)
    vm = VM(a, "fastboot", ini, "bootloader", [a.disk])
    try:
        vm.expect("[test-hook] modules loaded", 120)
        vm.expect("[gk3-fbi] start: mode=fastboot why=bootloader slot=a bootver=%s disk=%s" % (BOOTVER, a.partuuid), 30)
        # Debian 的通用内核没开 CONFIG_PM_WAKELOCKS（本机开了）：两种结果都算 /init 走对了
        vm.expect(r"\[gk3-fbi\] power: (wake_lock gk3fastboot held|no /sys/power/wake_lock)", 30, regex=True)
        vm.expect("[gk3-fbi] gadget: 0x18d1:0x4ee0 serial=gaokun3 ffs=/dev/usb-ffs/fastboot ready", 30)
        vm.expect("[gk3-fbi] keys: keyd started", 10)
        vm.expect("fake-fastbootd: serve #1 why=bootloader slot=a disk=%s udc=dummy_udc.0" % a.partuuid, 30)
        vm.expect("fake-fastbootd: descriptors written", 10)
        vm.expect("[gk3-fbi] gadget: bound to UDC dummy_udc.0", 30)
        # 主机侧（dummy_hcd）真的枚举到了 18d1:4ee0、序列号 gaokun3
        vm.expect("idVendor=18d1, idProduct=4ee0", 30)
        vm.expect("SerialNumber: gaokun3", 10)
        vm.expect("state=configured bound=yes", 30)
        if "[find] /dev/vda4 /dev/vda" not in vm.text:
            raise Fail("gk3-fbi find 没有找到 misc（应为 /dev/vda4 /dev/vda）")
        keys_ready(vm)
        for s in ("gaokun3 fastboot  (gk3boot %s)" % BOOTVER, "FASTBOOT MODE",
                  "Reason:  fastboot requested (adb reboot bootloader)", "Slot:    current _a",
                  "Layout:  ok (misc boot_a boot_b super userdata metadata, each exactly once)",
                  "Slot _a: bootable   priority=15 tries=1 successful  <- active",
                  "Fastboot: running", "fake: waiting for commands (serve #1)",
                  "> Reboot to Android", "Restart fastboot", "Power off",
                  "Volume up/down: move   Power: select"):
            if s not in vm.text:
                raise Fail("界面上没有 %r" % s)
        RESULTS.append("    界面：标题、原因、槽状态、USB（configured）、fastboot 状态、菜单都在；gk3-fbi find 按 PARTUUID 找到 /dev/vda4")
        # 按键：音量下 / 方向下 / 方向上 / 音量上（环绕到最后一项）
        vm.key("volumedown"); sel(vm, "main", "restart")
        vm.key("down"); sel(vm, "main", "reset")
        vm.key("up"); sel(vm, "main", "restart")
        vm.key("volumeup"); sel(vm, "main", "reboot")
        vm.key("volumeup"); sel(vm, "main", "poweroff")
        RESULTS.append("    按键：音量上/下、方向上/下移动高亮，环绕正确")
        # 看日志：音量下 ×4 从 poweroff 环绕到 log
        for _ in range(4):
            vm.key("volumedown")
        sel(vm, "main", "log")
        vm.key("power")
        vm.expect("[gk3-fbi] screen: page=log")
        time.sleep(1)
        vm.pump(0.5)
        for s in ("LOG  (any key: back)", "-- init --", "-- gk3-fastbootd --", "-- keys --", "(KEY_POWER) value=1 -> ok"):
            if s not in vm.text:
                raise Fail("日志页上没有 %r" % s)
        vm.key("esc")
        sel(vm, "main", "reboot")
        RESULTS.append("    Show log：电源键进、Esc 回；日志里记了原始键码（KEY_VOLUMEDOWN/KEY_POWER…）")
        # Restart fastboot：解绑 → 停 → 再起 → 再绑（软重新枚举）
        vm.key("volumedown"); sel(vm, "main", "restart")
        vm.key("ret")
        vm.expect("[gk3-fbi] gadget: unbound", 15)
        vm.expect("[gk3-fbi] fastbootd: stopped", 15)
        vm.expect("fake-fastbootd: serve #2", 30)
        vm.expect("[gk3-fbi] gadget: bound to UDC dummy_udc.0", 30)
        vm.expect("idVendor=18d1, idProduct=4ee0", 30)
        RESULTS.append("    Restart fastboot（回车）：解绑、停、重起、重绑，主机侧重新枚举")
        # Power off：重起之后高亮回到第一项（goto main）；音量上环绕到最后一项
        vm.key("volumeup")
        sel(vm, "main", "poweroff")
        vm.key("power")
        vm.expect("[gk3-fbi] poweroff: user chose Power off", 15)
        vm.expect("reboot: Power down", 120)
        vm.wait_exit()
        RESULTS.append("    Power off：走 poweroff -f，内核 Power down，QEMU 退出")
    finally:
        vm.kill()


def sc_missing(a):
    """why=recovery，镜像里没有 gk3-fastbootd：EXECUTOR MISSING、菜单照用；同一个 PARTUUID 出现在两块盘上 → 拒绝猜。
    选 Reboot to Android → 清 BCB 失败（没有执行端）也照样重启。"""
    # 发布的 fastboot.img 里带着真守护进程（build.sh 缺省就编进去）；"缺失"用 --no-fastbootd 打的那一份
    ini = overlay(a.work, "missing", a, fake=False, hook_extra="# nodummy", img=a.img_nofbd)
    vm = VM(a, "missing", ini, "recovery", [a.disk, a.disk2])
    try:
        ready(vm)
        vm.expect("[gk3-fbi] fastbootd: missing (/bin/gk3-fastbootd)", 30)
        sel(vm, "main", "reboot")
        for s in ("BOOT MENU", "Reason:  recovery requested - this device has no Android recovery, use this menu",
                  "Fastboot: EXECUTOR MISSING - /bin/gk3-fastbootd is not in this image",
                  "appears 2 times - refusing to guess", "> Reboot to Android", "Start fastboot",
                  "udc=dummy_udc.0 state=absent bound=no"):
            if s not in vm.text:
                raise Fail("界面上没有 %r" % s)
        RESULTS.append("    执行端缺失：界面显示 EXECUTOR MISSING，菜单照常；PARTUUID 不唯一时拒绝猜")
        vm.key("power")
        vm.expect("[gk3-fbi] bcb: clear failed", 15)
        vm.expect("reboot: Restarting system", 120)
        vm.wait_exit()
        RESULTS.append("    why=recovery 选 Reboot：先试 --clear-bcb（缺失 → 记失败），再 reboot -f")
    finally:
        vm.kill()


def sc_idle(a):
    """空闲关机：没有主机（不加载 dummy_hcd → 没有 UDC）、没有按键 GK3_IDLE_TIMEOUT 秒后关机；按一下键重新计时。"""
    ini = overlay(a.work, "idle", a, stub_conf="serve_exits=hold\n", hook_extra="GK3_IDLE_TIMEOUT=20  # nodummy")
    vm = VM(a, "idle", ini, "fastboot", [a.disk])
    try:
        ready(vm)
        vm.expect("fake-fastbootd: descriptors written", 30)
        vm.expect("[gk3-fbi] screen: page=main", 30)
        for s in ("Idle:    powers off after 20 s without a host connection or key press",
                  "udc=dummy_udc.0 state=absent bound=no"):
            if s not in vm.text:
                raise Fail("界面上没有 %r" % s)
        time.sleep(10)
        vm.key("volumedown")
        tk = time.time()
        vm.expect("[gk3-fbi] key: down", 15)
        vm.expect("[gk3-fbi] poweroff: idle: no host connection and no key press for 20s", 90)
        dt = time.time() - tk
        vm.expect("reboot: Power down", 120)
        vm.wait_exit()
        if dt < 18:
            raise Fail("按键后 %.1f 秒就关机了（应 ≥ 20）" % dt)
        RESULTS.append("    空闲关机：GK3_IDLE_TIMEOUT=20，按键后 %.1f 秒关机（按键重新计时）" % dt)
    finally:
        vm.kill()


def sc_wipe_confirm(a):
    """why=wipe，执行端说"免确认的条件不满足"（退出码 3）→ 确认页，协议不跑；选 Yes → --wipe-data --confirm → 重启。"""
    ini = overlay(a.work, "wipe-confirm", a, stub_conf="wipe_rc=3\nconfirm_rc=0\n")
    vm = VM(a, "wipe-confirm", ini, "wipe", [a.disk_wipe])
    try:
        ready(vm)
        vm.expect("fake-fastbootd: wipe-data (no confirm) -> 3", 30)
        sel(vm, "wipe_confirm", "cancel_reboot")
        for s in ("FACTORY RESET REQUESTED", "Request not verified: confirmation required",
                  "> No - keep my data and reboot to Android", "Yes - erase all user data"):
            if s not in vm.text:
                raise Fail("界面上没有 %r" % s)
        if "fake-fastbootd: serve" in vm.text:
            raise Fail("确认页上不该跑协议")
        vm.key("volumedown"); sel(vm, "wipe_confirm", "wipe")
        vm.key("power")
        vm.expect("fake-fastbootd: wipe-data confirm -> 0", 15)
        vm.expect("[gk3-fbi] reboot: user data erased", 15)
        vm.expect("reboot: Restarting system", 120)
        vm.wait_exit()
        RESULTS.append("    why=wipe 需确认：确认页（默认高亮“不擦”、不跑协议），选 Yes → --wipe-data --confirm → 重启")
    finally:
        vm.kill()


def sc_wipe_auto(a):
    """why=wipe，执行端判定免确认、擦完（退出码 0）→ 不等按键直接重启。"""
    ini = overlay(a.work, "wipe-auto", a, stub_conf="wipe_rc=0\n")
    vm = VM(a, "wipe-auto", ini, "wipe", [a.disk_wipe])
    try:
        ready(vm, keys=False)
        vm.expect("fake-fastbootd: wipe-data (no confirm) -> 0", 30)
        vm.expect("[gk3-fbi] reboot: user data erased (requested by Android)", 15)
        vm.expect("reboot: Restarting system", 120)
        vm.wait_exit()
        RESULTS.append("    why=wipe 免确认：--wipe-data 返回 0 → 直接重启，不等按键")
    finally:
        vm.kill()


def sc_wipe_decline(a):
    """why=wipe 需确认，用户选 No → --clear-bcb → 重启（否则 gk3boot 下次还送回来）。"""
    ini = overlay(a.work, "wipe-decline", a, stub_conf="wipe_rc=3\nclear_rc=0\n")
    vm = VM(a, "wipe-decline", ini, "wipe", [a.disk_wipe])
    try:
        ready(vm)
        sel(vm, "wipe_confirm", "cancel_reboot")
        vm.key("power")
        vm.expect("fake-fastbootd: clear-bcb -> 0", 15)
        vm.expect("[gk3-fbi] bcb: cleared", 10)
        vm.expect("reboot: Restarting system", 120)
        vm.wait_exit()
        if "wipe-data confirm" in vm.text:
            raise Fail("选了 No 却擦了")
        RESULTS.append("    why=wipe 用户拒绝：--clear-bcb 后重启，没有擦")
    finally:
        vm.kill()


def sc_prompt_tryagain(a):
    """why=prompt_wipe（RescueParty）：Try again → --clear-bcb → 重启。"""
    ini = overlay(a.work, "prompt-tryagain", a, stub_conf="clear_rc=0\n")
    vm = VM(a, "prompt-tryagain", ini, "prompt_wipe", [a.disk_prompt])
    try:
        ready(vm)
        sel(vm, "prompt_wipe", "tryagain")
        for s in ("ANDROID CANNOT START", "> Try again (reboot to Android)", "Factory data reset"):
            if s not in vm.text:
                raise Fail("界面上没有 %r" % s)
        if "fake-fastbootd: serve" in vm.text or "wipe-data" in vm.text:
            raise Fail("prompt_wipe 页上不该跑协议、不该擦")
        vm.key("power")
        vm.expect("fake-fastbootd: clear-bcb -> 0", 15)
        vm.expect("reboot: Restarting system", 120)
        vm.wait_exit()
        RESULTS.append("    why=prompt_wipe：RescueParty 页（不自动擦），Try again → --clear-bcb → 重启")
    finally:
        vm.kill()


def sc_prompt_reset(a):
    """why=prompt_wipe：Factory data reset → 二次确认页（默认 Cancel）→ Cancel 回主菜单 → 再进一次 → Yes → 擦 → 重启。"""
    ini = overlay(a.work, "prompt-reset", a, stub_conf="confirm_rc=0\nserve_exits=hold\n")
    vm = VM(a, "prompt-reset", ini, "prompt_wipe", [a.disk_prompt])
    try:
        ready(vm)
        sel(vm, "prompt_wipe", "tryagain")
        vm.key("volumedown"); sel(vm, "prompt_wipe", "reset")
        vm.key("power"); sel(vm, "confirm_reset", "cancel")
        if "This erases ALL user data" not in vm.text:
            raise Fail("二次确认页没有警告")
        vm.key("power"); sel(vm, "main", "reboot")
        # 主菜单上的状态：gk3-fbi 从夹具盘的 misc 里认出了 RescueParty 的 BCB
        if "BCB:     prompt_wipe" not in vm.text:
            raise Fail("主菜单的状态里没有 BCB: prompt_wipe")
        vm.key("down"); vm.key("down"); sel(vm, "main", "reset")
        vm.key("ret"); sel(vm, "confirm_reset", "cancel")
        vm.key("down"); sel(vm, "confirm_reset", "wipe")
        vm.key("ret")
        vm.expect("fake-fastbootd: wipe-data confirm -> 0", 15)
        vm.expect("reboot: Restarting system", 120)
        vm.wait_exit()
        RESULTS.append("    why=prompt_wipe：Factory data reset → 二次确认（默认 Cancel，Cancel 能退）→ Yes → 擦 → 重启")
    finally:
        vm.kill()


def sc_reenum(a):
    """协议侧退出码：11（reboot-bootloader）→ /init 重启守护进程并重新绑定；第二次 0（fastboot reboot）→ 重启。"""
    ini = overlay(a.work, "reenum", a, stub_conf="serve_exits=11,0\nserve_hold=4\n")
    vm = VM(a, "reenum", ini, "fastboot", [a.disk])
    try:
        ready(vm)
        vm.expect("[gk3-fbi] gadget: bound to UDC dummy_udc.0", 60)
        vm.expect("fake-fastbootd: serve #1 exiting with 11", 30)
        vm.expect("[gk3-fbi] fastbootd: exited rc=11", 15)
        vm.expect("fake-fastbootd: serve #2", 30)
        vm.expect("[gk3-fbi] gadget: bound to UDC dummy_udc.0", 30)
        vm.expect("restarted by host (reboot-bootloader)", 30)
        vm.expect("fake-fastbootd: serve #2 exiting with 0", 30)
        # 退出码 0 时 /init 把状态文件第一行当重启原因（真守护进程退出前写 "rebooting (host request)"，假的照写）
        vm.expect("[gk3-fbi] reboot: rebooting (host request)", 15)
        vm.expect("reboot: Restarting system", 120)
        vm.wait_exit()
        RESULTS.append("    退出码 11 → 重起守护进程 + 重绑 UDC（软重新枚举）；退出码 0 → 重启")
    finally:
        vm.kill()


def sc_crash(a):
    """守护进程连续崩溃（退出码 1）：重起两次，第 3 次停下并在界面上说明；菜单变成 Start fastboot；再从菜单关机。"""
    ini = overlay(a.work, "crash", a, stub_conf="serve_exits=1\nserve_hold=1\n", hook_extra="# nodummy")
    vm = VM(a, "crash", ini, "bootloader", [a.disk])
    try:
        ready(vm)
        vm.expect("fake-fastbootd: serve #3", 60)
        vm.expect("[gk3-fbi] fastbootd: giving up after 3 crashes", 30)
        vm.expect("Fastboot: STOPPED - exited with code 1 three times - see Show log", 15)
        vm.expect("Start fastboot", 5)
        time.sleep(3)
        if "fake-fastbootd: serve #4" in vm.text:
            raise Fail("放弃之后还在重起")
        vm.key("volumeup"); sel(vm, "main", "poweroff")
        vm.key("power")
        vm.expect("reboot: Power down", 120)
        vm.wait_exit()
        RESULTS.append("    守护进程崩溃：自动重起 2 次，第 3 次停下（界面 STOPPED、菜单 Start fastboot），不死循环")
    finally:
        vm.kill()


def ppm_to_png(ppm, png):
    d = open(ppm, "rb").read()
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", d)
    w, h = int(m.group(1)), int(m.group(2))
    px = d[m.end():]
    raw = b"".join(b"\0" + px[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    open(png, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    lit = sum(1 for i in range(0, len(px), 3 * 97) if px[i] > 128)
    return w, h, lit


def sc_screen(a):
    """fbcon（virtio-gpu + fbcon=rotate:1，同真机 cmdline）：界面画到 tty1、Terminus 32x16 字体加载成功；截一张图。"""
    ini = overlay(a.work, "screen", a, stub_conf="serve_exits=hold\n", gpu=True, hook_extra="GK3_TTY=/dev/tty1")
    vm = VM(a, "screen", ini, "bootloader", [a.disk], extra_append="fbcon=rotate:1", gpu=True)
    try:
        ready(vm)
        vm.expect("[gk3-fbi] screen: font loaded on /dev/tty1 (16x32, 512 glyphs", 60)
        vm.expect("[gk3-fbi] screen: page=main", 60)
        time.sleep(4)
        ppm = os.path.join(a.work, "screen.ppm")
        vm.hmp("screendump " + ppm)
        time.sleep(1)
        png = os.path.join(a.work, "screen.png")
        w, h, lit = ppm_to_png(ppm, png)
        m = re.search(r"\[gk3-fbi\] screen: (\d+) rows x (\d+) columns on /dev/tty1", vm.text)
        if not m:
            raise Fail("没有记录 tty1 的尺寸")
        if (m.group(1), m.group(2)) != ("50", "160"):
            raise Fail("1600x2560 + rotate:1 + 16x32 应是 50 行 x 160 列，实际 %s x %s" % (m.group(1), m.group(2)))
        if lit < 20:
            raise Fail("截图几乎全黑（亮点 %d）" % lit)
        RESULTS.append("    fbcon：Terminus 32x16 加载成功，tty1 %s 行 x %s 列（rotate:1），截图 %dx%d → %s"
                       % (m.group(1), m.group(2), w, h, os.path.relpath(png, GK3)))
        vm.key("volumeup"); sel(vm, "main", "poweroff")
        vm.key("power")
        vm.expect("reboot: Power down", 120)
        vm.wait_exit()
    finally:
        vm.kill()


SCENARIOS = [("fastboot", sc_fastboot), ("missing", sc_missing), ("idle", sc_idle),
             ("wipe-confirm", sc_wipe_confirm), ("wipe-auto", sc_wipe_auto), ("wipe-decline", sc_wipe_decline),
             ("prompt-tryagain", sc_prompt_tryagain), ("prompt-reset", sc_prompt_reset),
             ("reenum", sc_reenum), ("crash", sc_crash), ("screen", sc_screen)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", required=True)
    ap.add_argument("--img-nofbd", required=True, help="同一份源码 --no-fastbootd 打的镜像（missing 场景）")
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--modules", required=True)
    ap.add_argument("--fake", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("only", nargs="*")
    a = ap.parse_args()
    names = [n for n, _ in SCENARIOS]
    for o in a.only:
        if o not in names:
            sys.exit("不认识的场景 %s（有：%s）" % (o, " ".join(names)))

    misc = open(fixture.MISC_VEC, "rb").read()
    a.disk = os.path.join(a.work, "disk.img")
    a.partuuid = mkdisk(a.disk, misc)
    a.disk2 = os.path.join(a.work, "disk2.img")
    mkdisk(a.disk2, misc)
    a.disk_wipe = os.path.join(a.work, "disk-wipe.img")
    m = bytearray(misc)
    m[0:2048] = fixture.bcb_recovery("--wipe_data", "--reason=MasterClearConfirm", "--locale=zh-CN")
    mkdisk(a.disk_wipe, bytes(m))
    a.disk_prompt = os.path.join(a.work, "disk-prompt.img")
    m[0:2048] = fixture.bcb_recovery("--prompt_and_wipe_data", "--reason=RescueParty", "--locale=en-US")
    mkdisk(a.disk_prompt, bytes(m))
    print("▶ 夹具盘：misc PARTUUID %s（实机向量），另有同 PARTUUID 的第二块、BCB=wipe、BCB=prompt_wipe 各一块" % a.partuuid)

    fails = 0
    for n, f in SCENARIOS:
        if a.only and n not in a.only:
            continue
        t0 = time.time()
        RESULTS.clear()
        try:
            f(a)
            print("PASS %-16s %5.1fs  %s" % (n, time.time() - t0, f.__doc__.split("\n")[0]))
            for r in RESULTS:
                print(r)
        except Fail as e:
            fails += 1
            print("FAIL %-16s %5.1fs  %s\n%s" % (n, time.time() - t0, f.__doc__.split("\n")[0], e))
            print("     串口全文：%s" % os.path.relpath(os.path.join(a.work, n + ".log"), GK3))
    total = len(a.only) if a.only else len(SCENARIOS)
    print("—— %d/%d 通过 ——" % (total - fails, total))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

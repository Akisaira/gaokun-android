#!/usr/bin/env python3
"""gk3boot QEMU 夹具：造盘、做快照、比快照、写 AAVMF 变量（设计稿 §5 S3）。

在 scripts/gk3boot/gk3boot-build.Dockerfile 的容器里跑（要 mkfs.vfat / mtools / virt-fw-vars）。

  fixture.py mkdisk   --out DIR [--bootimg 完整 boot.img] [--variant normal|broken|espfull]
                      [--gk3boot-options '...'] [--boot-a IMG] [--boot-b IMG] [--misc FILE] [--corrupt-a]
  fixture.py snapshot DISK MANIFEST OUT.json
  fixture.py diff     BEFORE.json AFTER.json      只允许 ESP 上多出 \\EFI\\gk3boot\\{probe\\log-*,log\\boot-*}.txt 与条目计数改名
  fixture.py vars     IN.fd OUT.fd --oneshot NAME 往 AAVMF 变量库里写 LoaderEntryOneShot（与 boot-oneshot.sh 同一格式）
  fixture.py esp-get  DISK MANIFEST PATH OUT      从盘上的 ESP 取一个文件

gk3boot（S5）的 QEMU 测试另用这几样（qemu/run-boot-tests.sh）：
  fixture.py initramfs  --init ELF --marker STR --out FILE      最小 initramfs（newc cpio + gzip，同 Android ramdisk 的压缩）
  fixture.py fdt-mark   IN.dtb OUT.dtb NAME VALUE                给根节点加一个字符串属性（证明内核用的是我们装的 dtb）
  fixture.py mkbootimg  --kernel K --ramdisk R --dtb D --cmdline S --out F   header v2（与本机 BoardConfig 同版本、page 2048）
  fixture.py misc       --variant b-active --out FILE           从实机 misc 向量改出一份（_b 15/6 未成功，_a 14/1 已成功）

盘的样子照实机抄（tools/gk3boot/test/vectors/gpt-primary-20261005.bin）：分区号、名字、类型 GUID、
PARTUUID、磁盘 GUID、boot_a 的属性位 bit 54 都与实机一致；misc 也照实机坐在 LBA 34–2047，
内容是实机只读读出的 64 KiB（misc-20261005-1791053208.bin）。其余分区按比例缩小。
ESP 的目录结构照安装器（scripts/live/installer-lib.sh:868-960）：systemd-boot 257.13 + loader.conf +
<mid>-android-{a,b}.conf 直连条目 + <mid>/android/slot_{a,b}/；"Image" 换成 gk3-fake-android.efi。
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
GK3 = os.path.dirname(HERE)
VEC = os.path.join(GK3, "test", "vectors")
GPT_VEC = os.path.join(VEC, "gpt-primary-20261005.bin")
MISC_VEC = os.path.join(VEC, "misc-20261005-1791053208.bin")
CMDLINE_VEC = os.path.join(VEC, "proc-cmdline-20261005.txt")
EFI_BUILD = os.path.join(GK3, "build", "efi")
SDBOOT = "/usr/lib/systemd/boot/efi/systemd-bootaa64.efi"
MID = "8a29534fa802480d9fbb71aa18c01d7b"      # 实机 ESP 上的 machine-id 目录（proc-cmdline 向量里的 initrd= 路径）
SECTOR = 512
MiB = 1024 * 1024 // SECTOR                    # 扇区数

# 夹具里的分区大小（扇区）。esp 与实机同大小（614400 扇区 = 300 MiB）；boot_x 与实机同为 64 MiB；其余缩小。
LAYOUT = [  # (实机分区号, 名字, 扇区数)；misc（p4）单独放在 LBA 34
    (1, "esp", 614400),
    (2, "userdata", 16 * MiB),
    (8, "super", 16 * MiB),
    (5, "boot_a", 131072),
    (6, "boot_b", 131072),
    (10, "metadata", 16 * MiB),
    (3, "ubunturescue", 8 * MiB),
]


def die(msg):
    print("✗ " + msg, file=sys.stderr)
    sys.exit(1)


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def run(cmd, **kw):
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    r = subprocess.run(cmd, env=env, capture_output=True, text=True, **kw)
    if r.returncode:
        die("%s → %d\n%s%s" % (" ".join(cmd), r.returncode, r.stdout, r.stderr))
    return r.stdout


# ---------------------------------------------------------------- 实机 GPT 向量

def real_gpt():
    d = open(GPT_VEC, "rb").read()
    hdr = d[512:1024]
    disk_guid = hdr[56:72]
    parts = {}
    for i in range(128):
        e = d[1024 + i * 128:1024 + (i + 1) * 128]
        if e[:16] == b"\0" * 16:
            continue
        name = e[56:128].decode("utf-16-le").rstrip("\0")
        first, last, attrs = struct.unpack_from("<QQQ", e, 32)
        parts[name] = dict(index=i + 1, type=e[:16], guid=e[16:32], attrs=attrs, real_first=first, real_last=last)
    return disk_guid, parts


def gpt_entry(type_guid, part_guid, first, last, attrs, name):
    n = name.encode("utf-16-le")
    return type_guid + part_guid + struct.pack("<QQQ", first, last, attrs) + n + b"\0" * (72 - len(n))


def gpt_header(my, alt, first_usable, last_usable, entries_lba, disk_guid, entries_crc):
    h = bytearray(92)
    struct.pack_into("<8sIII", h, 0, b"EFI PART", 0x00010000, 92, 0)
    struct.pack_into("<QQQQ", h, 24, my, alt, first_usable, last_usable)
    h[56:72] = disk_guid
    struct.pack_into("<QIII", h, 72, entries_lba, 128, 128, entries_crc)
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)) & 0xffffffff)
    return bytes(h) + b"\0" * (SECTOR - 92)


# ---------------------------------------------------------------- 夹具里的文件

def mkbootimg(kernel, ramdisk, dtb, cmdline, name=b""):
    """header v2 boot.img（page 2048），id 按 mkbootimg 算。cmdline 超过 511 字节的部分按 mkbootimg 的规矩
    原样切进 extra_cmdline（头 @608[1024]），中间不加空格 —— 与 gk3_bootimg_cmdline 的拼法对应。"""
    page = 2048
    if len(cmdline) > 511 + 1023:
        die("cmdline 太长（%d）" % len(cmdline))
    s = hashlib.sha1()
    for blob in (kernel, ramdisk, b"", b"", dtb):
        s.update(blob)
        s.update(struct.pack("<I", len(blob)))
    h = bytearray(page)
    h[0:8] = b"ANDROID!"
    struct.pack_into("<IIIIIIIII", h, 8, len(kernel), 0x8000, len(ramdisk), 0x1000000, 0, 0, 0x100, page, 2)
    h[48:48 + min(len(name), 16)] = name[:16]
    h[64:64 + min(len(cmdline), 511)] = cmdline[:511]
    h[608:608 + len(cmdline[511:])] = cmdline[511:]
    h[576:596] = s.digest()
    struct.pack_into("<IQI", h, 1632, 0, 0, 1660)
    struct.pack_into("<IQ", h, 1648, len(dtb), 0x2000000)

    def pad(b):
        return b + b"\0" * (-len(b) % page)
    return bytes(h) + pad(kernel) + pad(ramdisk) + pad(dtb), s.hexdigest()


def synth_bootimg(tag):
    """合成一份 header v2 boot.img，kernel 以 MZ…zimg 开头（zboot 的样子，但不是真 PE —— LoadImage 会拒）。"""
    kernel = b"MZ\0\0zimg" + hashlib.sha256(tag.encode()).digest() * 100
    ramdisk = b"\x1f\x8b" + bytes(range(256)) * 20
    dtb = bytes.fromhex("d00dfeed") + b"\0" * 60
    cmdline = b"console=tty0 androidboot.hardware=gaokun3 gk3fixture=" + tag.encode()
    return mkbootimg(kernel, ramdisk, dtb, cmdline, tag.encode())


def bootimg_id(img):
    return img[576:596].hex()


def minimal_fdt():
    """最小合法 FDT（空根节点）：systemd-boot 的 devicetree_install 只查大小，夹具里的 'Image' 也不读它。"""
    struct_blk = struct.pack(">II", 1, 0) + struct.pack(">I", 2) + struct.pack(">I", 9)   # BEGIN_NODE "" / END_NODE / END
    rsv = b"\0" * 16
    off_rsv = 40
    off_struct = off_rsv + len(rsv)
    off_str = off_struct + len(struct_blk)
    total = off_str
    hdr = struct.pack(">IIIIIIIIII", 0xd00dfeed, total, off_struct, off_str, off_rsv, 17, 16, 0, 0, len(struct_blk))
    return hdr + rsv + struct_blk


GK3BOOT_ENTRY = "gk3boot-e4.conf"


def esp_tree(stage, variant, gk3boot_options=None):
    """在 stage 目录下摆出 ESP 的内容。返回条目文件名等信息。
    gk3boot_options 不为 None 时摆 gk3boot（S5）的 E4 条目，否则摆探针（S4）的条目。"""
    def put(rel, data):
        p = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f:
            f.write(data)

    sd = open(SDBOOT, "rb").read()
    put("EFI/BOOT/BOOTAA64.EFI", sd)
    put("EFI/systemd/systemd-bootaa64.efi", sd)
    # 实机是 timeout 15（installer-lib.sh:955-960）；夹具缩到 2 秒，别的照抄
    put("loader/loader.conf", b"timeout 2\nconsole-mode keep\neditor no\ndefault *-android-a.conf\n")
    cmd = open(CMDLINE_VEC).read().split()
    base = " ".join(t for t in cmd if not t.startswith("initrd=") and not t.startswith("androidboot.slot_suffix="))
    fake = open(os.path.join(EFI_BUILD, "gk3-fake-android.efi"), "rb").read()
    for slot in "ab":
        put("%s/android/slot_%s/Image" % (MID, slot), fake)
        put("%s/android/slot_%s/gaokun3.dtb" % (MID, slot), minimal_fdt())
        put("%s/android/slot_%s/ramdisk.img" % (MID, slot), b"\x1f\x8b" + b"\0" * 4094)
        # 与 installer-lib.sh:921-929 同一格式（title 里的 "—" 也照抄）
        put("loader/entries/%s-android-%s.conf" % (MID, slot), (
            "title      crDroid 16.0 (gaokun3) — slot _%s\n"
            "version    gaokun3-slot-%s\n"
            "sort-key   zandroid%s\n"
            "options    %s androidboot.slot_suffix=_%s\n"
            "linux      /%s/android/slot_%s/Image\n"
            "devicetree /%s/android/slot_%s/gaokun3.dtb\n"
            "initrd     /%s/android/slot_%s/ramdisk.img\n"
            % (slot, slot, slot, base, slot, MID, slot, MID, slot, MID, slot)).encode())
    if gk3boot_options is not None:
        # 与 README §10 的上机步骤同一份条目：文件名不匹配 *-android-*.conf、不带计数、title 只用 ASCII（§4.13）
        put("EFI/gk3boot/e4/gk3boot.efi", open(os.path.join(EFI_BUILD, "gk3boot.efi"), "rb").read())
        put("loader/entries/" + GK3BOOT_ENTRY, (
            "title      gk3boot E4 (observe)\n"
            "sort-key   zzgk3boot\n"
            "efi        /EFI/gk3boot/e4/gk3boot.efi\n"
            "options    %s\n" % gk3boot_options).encode())
        return dict(oneshot=GK3BOOT_ENTRY, default_entry="%s-android-a.conf" % MID, gk3boot_options=gk3boot_options)
    probe = os.path.join(EFI_BUILD, "gk3probe.efi")
    if not os.path.exists(probe):
        return dict(oneshot=None, default_entry="%s-android-a.conf" % MID)
    put("EFI/gk3boot/probe/gk3probe.efi", open(probe, "rb").read())
    # 夹具里带启动计数（+3），顺带验证 LoaderBootCountPath；OneShot 写不带计数的 id "gk3probe.conf"
    # （systemd-boot 去掉计数后比 id，boot.c:1340-1376）。上机步骤用不带计数的文件名，见 README §9。
    put("loader/entries/gk3probe+3.conf", (
        "title      gk3probe (E3) — 只读探针\n"
        "sort-key   zzgk3probe\n"
        "efi        /EFI/gk3boot/probe/gk3probe.efi\n"
        "options    gk3probe.hold=1 gk3probe.keyscan=3000\n").encode())
    return dict(oneshot="gk3probe.conf", default_entry="%s-android-a.conf" % MID)


def make_fat(stage, sectors, out, fill=False):
    with open(out, "wb") as f:
        f.truncate(sectors * SECTOR)
    run(["mkfs.vfat", "-F", "32", "-S", str(SECTOR), "-n", "ESP", out])
    for top in sorted(os.listdir(stage)):
        run(["mcopy", "-s", "-o", "-i", out, os.path.join(stage, top), "::/"])
    if fill:
        # espfull 变体：用一个文件把剩余空间正好占满 —— 探针建目录 / 写日志会 VOLUME_FULL，测"写盘失败也不能挂"
        free = int(re.search(r"([\d ]+) bytes free", run(["mdir", "-i", out, "::/"])).group(1).replace(" ", ""))
        filler = out + ".filler"
        with open(filler, "wb") as f:
            f.truncate(free)
        run(["mcopy", "-o", "-i", out, filler, "::/filler.bin"])
        os.unlink(filler)
        left = int(re.search(r"([\d ]+) bytes free", run(["mdir", "-i", out, "::/"])).group(1).replace(" ", ""))
        if left:
            die("ESP 没填满（还剩 %d 字节）" % left)


# ---------------------------------------------------------------- mkdisk

def cmd_mkdisk(a):
    os.makedirs(a.out, exist_ok=True)
    if not os.path.exists(os.path.join(EFI_BUILD, "gk3-fake-android.efi")):
        die("先 make -C tools/gk3boot/efi（缺 gk3-fake-android.efi）")
    disk_guid, real = real_gpt()
    for n in ("misc", "boot_a", "boot_b", "super", "userdata", "metadata", "esp"):
        if n not in real:
            die("实机 GPT 向量里没有 %s" % n)

    # 分区排布
    lba = 2048
    parts = []
    misc = real["misc"]
    parts.append(dict(name="misc", index=misc["index"], first=34, last=2047))
    for idx, name, sz in LAYOUT:
        parts.append(dict(name=name, index=idx, first=lba, last=lba + sz - 1))
        lba += sz
    last_usable = lba + 2048 - 1
    total = last_usable + 1 + 33
    disk_path = os.path.join(a.out, "disk.img")

    # broken 变体：多一个同名 boot_b（p7，实机上的空项），再把 super 改名 —— 探针应记录 EDUP / ENOENT 然后照常跑完
    entries_by_index = {}
    for p in parts:
        r = real[p["name"]]
        entries_by_index[p["index"]] = gpt_entry(r["type"], r["guid"], p["first"], p["last"], r["attrs"], p["name"])
    if a.variant == "broken":
        sup = next(p for p in parts if p["name"] == "super")
        r = real["super"]
        entries_by_index[8] = gpt_entry(r["type"], r["guid"], sup["first"], sup["last"], 0, "super_renamed")
        b = next(p for p in parts if p["name"] == "boot_b")
        entries_by_index[7] = gpt_entry(real["boot_b"]["type"], uuid.uuid4().bytes_le, b["first"], b["last"], 0, "boot_b")
    table = b"".join(entries_by_index.get(i + 1, b"\0" * 128) for i in range(128))
    tcrc = zlib.crc32(table) & 0xffffffff

    with open(disk_path, "wb") as f:
        f.truncate(total * SECTOR)
        # 保护 MBR
        mbr = bytearray(SECTOR)
        struct.pack_into("<BBBBBBBBII", mbr, 446, 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(total - 1, 0xffffffff))
        mbr[510:512] = b"\x55\xaa"
        f.seek(0)
        f.write(mbr)
        f.write(gpt_header(1, total - 1, 34, last_usable, 2, disk_guid, tcrc))
        f.write(table)
        f.seek((total - 33) * SECTOR)
        f.write(table)
        f.write(gpt_header(total - 1, 1, 34, last_usable, total - 33, disk_guid, tcrc))

        def at(name):
            return next(p for p in parts if p["name"] == name)

        # misc：实机 64 KiB（或 --misc 给的改过的一份）
        f.seek(at("misc")["first"] * SECTOR)
        f.write(open(a.misc or MISC_VEC, "rb").read())
        # boot_a：完整的真 boot.img（有就用），否则合成；boot_b：总是合成（两份内容不同，各验各的）
        # --boot-a / --boot-b：gk3boot 测试用的现成镜像（Debian 内核 + 测试 initramfs 重新打的包）
        if a.boot_a:
            ba = open(a.boot_a, "rb").read()
            src_a = os.path.basename(a.boot_a) + " (%d bytes)" % len(ba)
        elif a.bootimg:
            ba = open(a.bootimg, "rb").read()
            src_a = os.path.basename(a.bootimg) + " (real, %d bytes)" % len(ba)
        else:
            ba, _ = synth_bootimg("fixture-a")
            src_a = "synthetic"
        if a.corrupt_a:
            # 坏一个 kernel 字节、头里的 id 不动 → SHA1(id) 对不上（§4.3.3 的 boot_corrupt）
            ba = bytearray(ba)
            ba[2048 + 4096] ^= 0xff
            ba = bytes(ba)
            src_a += " [kernel byte 4096 flipped]"
        bb = open(a.boot_b, "rb").read() if a.boot_b else synth_bootimg("fixture-b")[0]
        for name, img in (("boot_a", ba), ("boot_b", bb)):
            p = at(name)
            if len(img) > (p["last"] - p["first"] + 1) * SECTOR:
                die("%s 放不下 %d 字节" % (name, len(img)))
            f.seek(p["first"] * SECTOR)
            f.write(img)
        # super / userdata / metadata：写一点可辨认的内容，快照比对时才有意义
        for name in ("super", "userdata", "metadata", "ubunturescue"):
            p = at(name)
            f.seek(p["first"] * SECTOR)
            f.write(("gk3fixture %s\n" % name).encode() * 64)

        # ESP
        stage = tempfile.mkdtemp()
        info = esp_tree(stage, a.variant, a.gk3boot_options)
        esp = at("esp")
        fat = os.path.join(a.out, "esp.tmp")
        make_fat(stage, esp["last"] - esp["first"] + 1, fat, fill=a.variant == "espfull")
        shutil.rmtree(stage)
        f.seek(esp["first"] * SECTOR)
        with open(fat, "rb") as g:
            shutil.copyfileobj(g, f, 4 * 1024 * 1024)
        os.unlink(fat)

    manifest = dict(
        disk=disk_path, sector=SECTOR, total_sectors=total, variant=a.variant, parts=parts,
        boot_a_id=bootimg_id(ba), boot_b_id=bootimg_id(bb), boot_a_source=src_a, mid=MID,
        disk_guid=str(uuid.UUID(bytes_le=disk_guid)),
        esp_partuuid=str(uuid.UUID(bytes_le=real["esp"]["guid"])), **info)
    with open(os.path.join(a.out, "manifest.json"), "w") as g:
        json.dump(manifest, g, indent=1)
    print("✓ 夹具盘 %s（%d MiB，变体 %s，boot_a=%s）" % (disk_path, total * SECTOR >> 20, a.variant, src_a))


# ---------------------------------------------------------------- 快照与比较

def esp_extract(disk, m, outdir):
    esp = next(p for p in m["parts"] if p["name"] == "esp")
    fat = os.path.join(outdir, ".esp.img")
    with open(disk, "rb") as f, open(fat, "wb") as g:
        f.seek(esp["first"] * SECTOR)
        left = (esp["last"] - esp["first"] + 1) * SECTOR
        while left:
            b = f.read(min(left, 4 * 1024 * 1024))
            if not b:
                break
            g.write(b)
            left -= len(b)
    # 先只读查一遍 FAT：固件 / 被测程序把 FAT 写坏了（例如目录项指回根目录、成环）时，下面的 mcopy -s
    # 会无限递归、把容器的盘写满 —— 2026-10-05 gk3boot espfull 场景真遇到过（gk3efi.c gk3_log_open_seq 的注释）
    r = subprocess.run(["fsck.fat", "-n", fat], capture_output=True, text=True)
    if r.returncode:
        os.unlink(fat)
        die("ESP 的 FAT 不一致（fsck.fat -n → %d）：\n%s" % (r.returncode, (r.stdout + r.stderr)[-1500:]))
    tree = os.path.join(outdir, "esp")
    os.makedirs(tree, exist_ok=True)
    run(["mcopy", "-s", "-n", "-i", fat, "::/*", tree])
    os.unlink(fat)
    return tree


def cmd_snapshot(a):
    m = json.load(open(a.manifest))
    snap = dict(regions={}, esp={})
    with open(a.disk, "rb") as f:
        def region(name, first, n):
            f.seek(first * SECTOR)
            h = hashlib.sha256()
            left = n * SECTOR
            while left:
                b = f.read(min(left, 4 * 1024 * 1024))
                if not b:
                    break
                h.update(b)
                left -= len(b)
            snap["regions"][name] = h.hexdigest()
        region("gpt-primary", 0, 34)
        region("gpt-backup", m["total_sectors"] - 33, 33)
        for p in m["parts"]:
            if p["name"] != "esp":
                region(p["name"], p["first"], p["last"] - p["first"] + 1)
    tmp = tempfile.mkdtemp()
    tree = esp_extract(a.disk, m, tmp)
    for root, _, files in os.walk(tree):
        for fn in files:
            p = os.path.join(root, fn)
            snap["esp"][os.path.relpath(p, tree)] = sha256(open(p, "rb").read())
    shutil.rmtree(tmp)
    json.dump(snap, open(a.out, "w"), indent=1, sort_keys=True)


def cmd_diff(a):
    b, c = json.load(open(a.before)), json.load(open(a.after))
    bad = []
    for k, v in b["regions"].items():
        if c["regions"].get(k) != v:
            bad.append("块区域 %s 变了" % k)
    added = sorted(set(c["esp"]) - set(b["esp"]))
    removed = sorted(set(b["esp"]) - set(c["esp"]))
    changed = sorted(k for k in set(b["esp"]) & set(c["esp"]) if b["esp"][k] != c["esp"][k])
    logs = [x for x in added if (x.startswith("EFI/gk3boot/probe/log-") or x.startswith("EFI/gk3boot/log/boot-"))
            and x.endswith(".txt")]
    # systemd-boot 自己做的计数改名：loader/entries/gk3probe+N[-M].conf → 另一个计数（内容不变）
    counted = ("loader/entries/gk3probe+", "loader/entries/gk3boot-e4+")
    ren_from = [x for x in removed if x.startswith(counted)]
    ren_to = [x for x in added if x.startswith(counted)]
    for x in added:
        if x not in logs and x not in ren_to:
            bad.append("ESP 上多了 %s" % x)
    for x in removed:
        if x not in ren_from:
            bad.append("ESP 上少了 %s" % x)
    for x in changed:
        bad.append("ESP 上 %s 的内容变了" % x)
    if len(ren_from) != len(ren_to) or any(b["esp"][f] != c["esp"][t] for f, t in zip(ren_from, ren_to)):
        bad.append("条目改名前后内容不同或数量不对：%s → %s" % (ren_from, ren_to))
    for x in bad:
        print("✗ " + x)
    print("  新日志：%s" % (", ".join(logs) or "（无）"))
    if ren_from:
        print("  systemd-boot 计数改名：%s → %s" % (", ".join(ren_from), ", ".join(ren_to)))
    if bad:
        sys.exit(1)
    print("✓ 盘上只多了自己的日志（misc / boot_a / boot_b / super / userdata / metadata / GPT 逐字节未变）")


# ---------------------------------------------------------------- AAVMF 变量

def cmd_vars(a):
    # LoaderEntryOneShot：属性 NV|BS|RT = 7，UTF-16LE + 双 NUL（同 scripts/boot-oneshot.sh）
    data = (a.oneshot.encode("utf-16-le") + b"\0\0").hex()
    j = dict(version=2, variables=[dict(name="LoaderEntryOneShot", guid="4a67b082-0a4c-41cf-b6c7-440b29bb8c4f",
                                        attr=7, data=data)])
    jf = a.out + ".json"
    json.dump(j, open(jf, "w"))
    run(["virt-fw-vars", "-i", a.input, "-o", a.out, "--set-json", jf])
    os.unlink(jf)
    print("✓ %s：LoaderEntryOneShot=%s" % (os.path.basename(a.out), a.oneshot))


def cmd_esp_get(a):
    m = json.load(open(a.manifest))
    tmp = tempfile.mkdtemp()
    tree = esp_extract(a.disk, m, tmp)
    src = os.path.join(tree, a.path)
    if not os.path.exists(src):
        shutil.rmtree(tmp)
        die("ESP 上没有 %s" % a.path)
    shutil.copy(src, a.out)
    shutil.rmtree(tmp)


# ---------------------------------------------------------------- gk3boot（S5）测试用的产物

def cpio_newc(entries):
    """entries: (name, mode, data, rdev_major, rdev_minor)。newc 格式（"070701"，内核 init/initramfs.c）。"""
    out = bytearray()
    ino = 1
    for name, mode, data, rmaj, rmin in entries + [("TRAILER!!!", 0, b"", 0, 0)]:
        nm = name.encode() + b"\0"
        hdr = "070701" + "".join("%08X" % v for v in (
            ino, mode, 0, 0, 2 if mode & 0o040000 else 1, 0, len(data), 0, 0, rmaj, rmin, len(nm), 0))
        out += hdr.encode() + nm
        out += b"\0" * (-len(out) % 4)
        out += data
        out += b"\0" * (-len(out) % 4)
        ino += 1
    return bytes(out)


def cmd_initramfs(a):
    import gzip
    init = open(a.init, "rb").read()
    if init[:4] != b"\x7fELF":
        die("%s 不是 ELF" % a.init)
    ents = [
        ("dev", 0o040755, b"", 0, 0), ("dev/console", 0o020600, b"", 5, 1),
        ("proc", 0o040755, b"", 0, 0), ("sys", 0o040755, b"", 0, 0),
        ("init", 0o100755, init, 0, 0), ("gk3-initrd-marker", 0o100644, a.marker.encode() + b"\n", 0, 0),
    ]
    data = gzip.compress(cpio_newc(ents), mtime=0)
    open(a.out, "wb").write(data)
    print("✓ initramfs %s（%d 字节，marker %s）" % (a.out, len(data), a.marker))


def fdt_add_root_prop(dtb, name, value):
    """给根节点开头插一个字符串属性。只支持 libfdt 的标准布局（头 / rsvmap / struct / strings 依次排）。"""
    magic, total, off_struct, off_str, off_rsv, ver, _, _, size_str, size_struct = struct.unpack_from(">10I", dtb, 0)
    if magic != 0xd00dfeed or ver < 17 or not (off_rsv < off_struct < off_str):
        die("不认识的 FDT 布局")
    if struct.unpack_from(">I", dtb, off_struct)[0] != 1 or dtb[off_struct + 4] != 0:
        die("struct 块不以根节点开头")
    ins_at = off_struct + 8                      # BEGIN_NODE + 根节点名 ""（补齐到 4 字节）
    strings = dtb[off_str:off_str + size_str]
    nameoff = len(strings)
    val = value.encode() + b"\0"
    prop = struct.pack(">III", 3, len(val), nameoff) + val + b"\0" * (-len(val) % 4)
    new_struct = dtb[off_struct:ins_at] + prop + dtb[ins_at:off_struct + size_struct]
    new_strings = strings + name.encode() + b"\0"
    head = bytearray(dtb[:off_struct])
    new_off_str = off_struct + len(new_struct)
    total = new_off_str + len(new_strings)
    struct.pack_into(">I", head, 4, total)
    struct.pack_into(">I", head, 12, new_off_str)
    struct.pack_into(">I", head, 32, len(new_strings))
    struct.pack_into(">I", head, 36, len(new_struct))
    return bytes(head) + new_struct + new_strings


def cmd_fdt_mark(a):
    d = fdt_add_root_prop(open(a.input, "rb").read(), a.name, a.value)
    open(a.out, "wb").write(d)
    print("✓ %s：根节点加 %s = \"%s\"（%d 字节）" % (a.out, a.name, a.value, len(d)))


def cmd_mkbootimg(a):
    img, sha = mkbootimg(open(a.kernel, "rb").read(), open(a.ramdisk, "rb").read(), open(a.dtb, "rb").read(),
                         a.cmdline.encode(), a.name.encode())
    open(a.out, "wb").write(img)
    print("✓ boot.img %s（%d 字节，id %s，cmdline %d 字节%s）" % (
        a.out, len(img), sha, len(a.cmdline), "，切进了 extra_cmdline" if len(a.cmdline) > 511 else ""))


def bcab_slot(prio, tries, ok):
    return prio | (tries << 4) | (int(ok) << 7)


def cmd_misc(a):
    m = bytearray(open(MISC_VEC, "rb").read())
    bc = m[2048:2080]
    if a.variant == "b-active":
        # 像 setActive(b) 之后、新槽还没开过机：_b 15/6 未成功，_a 降到 14、仍是已成功
        bc[0:3] = b"_b\0"
        struct.pack_into("<HH", bc, 12, bcab_slot(14, 1, True), bcab_slot(15, 6, False))
    else:
        die("不认识的 misc 变体 %s" % a.variant)
    struct.pack_into("<I", bc, 28, zlib.crc32(bytes(bc[:28])) & 0xffffffff)
    m[2048:2080] = bc
    open(a.out, "wb").write(m)
    print("✓ misc %s（%s，bcab %s）" % (a.out, a.variant, bytes(bc).hex()))


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("mkdisk")
    p.add_argument("--out", required=True)
    p.add_argument("--bootimg")
    p.add_argument("--variant", default="normal", choices=["normal", "broken", "espfull"])
    p.add_argument("--gk3boot-options")
    p.add_argument("--boot-a")
    p.add_argument("--boot-b")
    p.add_argument("--misc")
    p.add_argument("--corrupt-a", action="store_true")
    p = sp.add_parser("snapshot")
    p.add_argument("disk")
    p.add_argument("manifest")
    p.add_argument("out")
    p = sp.add_parser("diff")
    p.add_argument("before")
    p.add_argument("after")
    p = sp.add_parser("vars")
    p.add_argument("input")
    p.add_argument("out")
    p.add_argument("--oneshot", required=True)
    p = sp.add_parser("esp-get")
    p.add_argument("disk")
    p.add_argument("manifest")
    p.add_argument("path")
    p.add_argument("out")
    p = sp.add_parser("initramfs")
    p.add_argument("--init", required=True)
    p.add_argument("--marker", required=True)
    p.add_argument("--out", required=True)
    p = sp.add_parser("fdt-mark")
    p.add_argument("input")
    p.add_argument("out")
    p.add_argument("name")
    p.add_argument("value")
    p = sp.add_parser("mkbootimg")
    p.add_argument("--kernel", required=True)
    p.add_argument("--ramdisk", required=True)
    p.add_argument("--dtb", required=True)
    p.add_argument("--cmdline", required=True)
    p.add_argument("--name", default="")
    p.add_argument("--out", required=True)
    p = sp.add_parser("misc")
    p.add_argument("--variant", required=True)
    p.add_argument("--out", required=True)
    a = ap.parse_args()
    dict(mkdisk=cmd_mkdisk, snapshot=cmd_snapshot, diff=cmd_diff, vars=cmd_vars, esp_get=cmd_esp_get,
         initramfs=cmd_initramfs, fdt_mark=cmd_fdt_mark, mkbootimg=cmd_mkbootimg, misc=cmd_misc)[
        a.cmd.replace("-", "_")](a)


if __name__ == "__main__":
    main()

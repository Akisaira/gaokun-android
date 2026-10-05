#!/usr/bin/env python3
"""gk3-fastbootd 离线测试的夹具（S7a）。在 fbd-gk3-fastbootd-test 容器里跑（mkfs.vfat / mtools），
macOS 上不带 ESP 镜像也能跑（只出 ESP 目录树，给 --esp-dir 用）。

  fbd_fixture.py mkdisk  --layout factory|dual|dup|missing --out DISK --stage DIR [--seed N]
        造整盘镜像：主 GPT + 备份 GPT（自己写，好造重名 / 缺失的坏盘），misc 用实机向量，ESP 是 FAT32
        （mkfs.vfat + mtools，内容照安装器：loader.conf + <mid>-android-{a,b}.conf 直连条目 + <mid>/android/slot_x/）。
        其余分区填可辨认的图案（每个 4 KiB 块开头写 "<分区名>:<块号>"），好查"白名单外一个字节都没动"。
        DIR/manifest.json 记下各分区的号、起止 LBA、PARTUUID。
  fbd_fixture.py mkboot  --tag T --out F            header v2 boot.img（借 qemu/fixture.py 的 mkbootimg，id 按 mkbootimg 算）
  fbd_fixture.py extract BOOT DIR                   照 gaokun3-bootimg-extract 解出 Image / ramdisk.img / gaokun3.dtb / cmdline.txt
  fbd_fixture.py mksuper --out F --size N --slots a|b|ab|none [--seed N]
        LP 元数据 v10.2（几何区 + 2 个元数据槽，SHA-256 照 liblp/reader.cpp 算）+ 后面 N 字节里一半随机数据一半零
  fbd_fixture.py sparse  --kind K --part-size N --out F   手造的 sparse（不经主机 fastboot 重排）：
        ok（raw/fill/dontcare/crc）、oob（total 超过分区）、chunkpast（chunk 越过 total_blks）、
        rawshort（raw 长度对不上）、trailing（尾部多字节）、sum（块数合计不等）
  fbd_fixture.py sparse-expect --kind ok --base PARTFILE --out F   ok 样本写到一份旧分区内容上之后应有的样子
  fbd_fixture.py part    DISK MANIFEST NAME OUT     取一个分区（按 manifest 的 LBA）
  fbd_fixture.py sums    DISK MANIFEST [--skip a,b] 每个分区（含 GPT 区、分区之间的空隙）的 sha256，JSON
  fbd_fixture.py misc    DISK MANIFEST [--bcb none|bootloader|fastboot|recovery|wipe|wipe2|prompt]
                         [--vab none|snapshotted|merging] [--bcab real|b-unbootable|both|invalid]
                         [--rec none|plain|migrated|dispatched]       改 misc 再写回盘（--rec 在 --bcb 之后算摘要）
  fbd_fixture.py misc-dump DISK MANIFEST            打印 BCB command / recovery、BCAB 32 字节十六进制、VAB 状态
  fbd_fixture.py bcab-set-active HEX32 SLOT CUR     libboot_control SetActiveBootSlot 的 Python 版（hardware/interfaces
                                                    libboot_control.cpp:282-314），给"字节对"当独立的期望值
  fbd_fixture.py client  --port P [--download F] CMD…   原始 fastboot TCP 客户端：打印每个回应包（一行一个）
"""
import argparse
import hashlib
import json
import os
import random
import socket
import struct
import subprocess
import sys
import uuid
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
GK3 = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(GK3, "qemu"))
from fixture import mkbootimg  # noqa: E402  header v2 的那一份实现（gk3boot QEMU 夹具共用）

MISC_VEC = os.path.join(GK3, "test", "vectors", "misc-20261005-1791053208.bin")
MID = "8a29534fa802480d9fbb71aa18c01d7b"
SECTOR = 512
MiB = 1 << 20

T_ESP = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").bytes_le
T_LINUX = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4").bytes_le
T_BASIC = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7").bytes_le
T_MSR = uuid.UUID("e3c9e316-0b5c-4db8-817d-f92df00215ae").bytes_le

# (名字, MiB, 类型)。factory = 整盘安装（与实机同序：esp p1、userdata p2、救援 p3、misc p4、boot p5/p6、super、metadata）
LAYOUTS = {
    "factory": [("esp", 40, T_ESP), ("userdata", 24, T_LINUX), ("ubunturescue", 4, T_LINUX), ("misc", 1, T_LINUX),
                ("boot_a", 8, T_LINUX), ("boot_b", 8, T_LINUX), ("super", 48, T_LINUX), ("metadata", 4, T_LINUX)],
    # 双系统：复用 Windows 的 ESP（PARTLABEL "EFI system partition"），MSR + C 盘 + WinRE 都叫 "Basic data partition"
    "dual": [("EFI system partition", 40, T_ESP), ("Microsoft reserved partition", 4, T_MSR),
             ("Basic data partition", 16, T_BASIC), ("Basic data partition", 4, T_BASIC),
             ("misc", 1, T_LINUX), ("boot_a", 8, T_LINUX), ("boot_b", 8, T_LINUX), ("super", 48, T_LINUX),
             ("metadata", 4, T_LINUX), ("userdata", 24, T_LINUX)],
}
LAYOUTS["dup"] = LAYOUTS["factory"] + [("boot_a", 4, T_LINUX)]          # 重名
LAYOUTS["missing"] = [p for p in LAYOUTS["factory"] if p[0] != "metadata"]  # 缺一个


def die(m):
    print("✗ " + m, file=sys.stderr)
    sys.exit(1)


def run(cmd):
    r = subprocess.run(cmd, env=dict(os.environ, MTOOLS_SKIP_CHECK="1"), capture_output=True, text=True)
    if r.returncode:
        die("%s → %d\n%s%s" % (" ".join(cmd), r.returncode, r.stdout, r.stderr))
    return r.stdout


def gpt_entry(t, g, first, last, name):
    n = name.encode("utf-16-le")
    return t + g + struct.pack("<QQQ", first, last, 0) + n + b"\0" * (72 - len(n))


def gpt_header(my, alt, fu, lu, elba, dguid, ecrc):
    h = bytearray(92)
    struct.pack_into("<8sIII", h, 0, b"EFI PART", 0x00010000, 92, 0)
    struct.pack_into("<QQQQ", h, 24, my, alt, fu, lu)
    h[56:72] = dguid
    struct.pack_into("<QIII", h, 72, elba, 128, 128, ecrc)
    struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)) & 0xffffffff)
    return bytes(h) + b"\0" * (SECTOR - 92)


def boot_cmdline(tag):
    return ("console=tty0 androidboot.hardware=gaokun3 fbcon=rotate:1 gk3fixture=%s" % tag).encode()


def esp_files(stage, bootimgs):
    """返回 {ESP 内路径: 内容}。bootimgs = {'a': boot.img 字节, 'b': …} —— slot_x 里放这份镜像解出来的旧内核。"""
    f = {}
    f["loader/loader.conf"] = b"timeout 15\nconsole-mode keep\neditor no\ndefault *-android-a.conf\n"
    for s in "ab":
        f["loader/entries/%s-android-%s.conf" % (MID, s)] = (
            "title      Android (gaokun3) - slot _%s\nversion    gaokun3-%s\nsort-key   zandroid%s\n"
            "linux      /%s/android/slot_%s/Image\ninitrd     /%s/android/slot_%s/ramdisk.img\n"
            "devicetree /%s/android/slot_%s/gaokun3.dtb\noptions    %s androidboot.slot_suffix=_%s\n"
            % (s, s, s, MID, s, MID, s, MID, s, boot_cmdline("old-" + s).decode(), s)).encode()
        for name, data in extract(bootimgs[s]).items():
            f["%s/android/slot_%s/%s" % (MID, s, name)] = data
    f["EFI/BOOT/BOOTAA64.EFI"] = b"MZ fake systemd-boot\n"
    f["EFI/Microsoft/Boot/bootmgfw.efi"] = b"MZ fake windows boot manager\n"
    return f


def extract(img):
    """照 bootimg_extract.cpp：kernel / ramdisk / dtb 各段 + cmdline.txt（cmdline + extra 直接相接再加 \\n）"""
    ks, rs, ss, page = struct.unpack_from("<I4xI4xI8xI", img, 8)
    dtb = struct.unpack_from("<I", img, 1648)[0]
    rdo = struct.unpack_from("<I", img, 1632)[0]
    pad = lambda n: (n + page - 1) // page * page  # noqa: E731
    ko = page
    ro = ko + pad(ks)
    so = ro + pad(rs)
    do = so + pad(ss) + pad(rdo)
    cmd = img[64:64 + 512].split(b"\0")[0] + img[608:608 + 1024].split(b"\0")[0]
    return {"Image": img[ko:ko + ks], "ramdisk.img": img[ro:ro + rs], "gaokun3.dtb": img[do:do + dtb],
            "cmdline.txt": cmd + b"\n"}


def mkfat(path, size_mib, files):
    if os.path.exists(path):
        os.unlink(path)
    run(["mkfs.vfat", "-F", "32", "-n", "GK3ESP", "-C", path, str(size_mib * 1024)])
    dirs = set()
    for p in sorted(files):
        parts = p.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            d = "/".join(parts[:i])
            if d not in dirs:
                run(["mmd", "-i", path, "::/" + d])
                dirs.add(d)
        tmp = path + ".f"
        open(tmp, "wb").write(files[p])
        run(["mcopy", "-i", path, tmp, "::/" + p])
        os.unlink(tmp)


def pattern(name, nbytes):
    out = bytearray(nbytes)
    tag = name.encode()
    for off in range(0, nbytes, 4096):
        s = b"%s:%d" % (tag, off // 4096)
        out[off:off + len(s)] = s
    return bytes(out)


def cmd_mkdisk(a):
    rnd = random.Random(a.seed)
    lay = LAYOUTS[a.layout]
    os.makedirs(a.stage, exist_ok=True)
    first = 2048
    parts = []
    lba = first
    for i, (name, mib, t) in enumerate(lay):
        n = mib * MiB // SECTOR
        if name == "misc":
            n = 1007 * 1024 // SECTOR     # 实机 misc 是 1007 KiB
        parts.append(dict(index=i + 1, name=name, first=lba, last=lba + n - 1, type=t,
                          guid=uuid.UUID(int=rnd.getrandbits(128), version=4).bytes_le))
        lba += n
        lba = (lba + 2047) // 2048 * 2048
    total = lba + 2048 + 33
    dguid = uuid.UUID(int=rnd.getrandbits(128), version=4).bytes_le
    with open(a.out, "wb") as f:
        f.truncate(total * SECTOR)
    disk = open(a.out, "r+b")

    boots = {}
    for s in "ab":
        boots[s] = mkbootimg(b"MZ\0\0zimg" + hashlib.sha256(b"old" + s.encode()).digest() * 3000,
                             b"\x1f\x8b" + bytes(rnd.getrandbits(8) for _ in range(40000)),
                             bytes.fromhex("d00dfeed") + b"\0" * 2000, boot_cmdline("old-" + s), b"old")[0]
    files = esp_files(a.stage, boots)
    stage_esp = os.path.join(a.stage, "esp")
    for p, d in files.items():
        q = os.path.join(stage_esp, p)
        os.makedirs(os.path.dirname(q), exist_ok=True)
        open(q, "wb").write(d)

    have_fat = subprocess.run(["sh", "-c", "command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null"]).returncode == 0
    for p in parts:
        size = (p["last"] - p["first"] + 1) * SECTOR
        disk.seek(p["first"] * SECTOR)
        if p["type"] == T_ESP:
            if have_fat:
                fat = os.path.join(a.stage, "esp.fat")
                mkfat(fat, size // MiB, files)
                disk.write(open(fat, "rb").read())
                os.unlink(fat)
            else:
                disk.write(pattern("espdir", size))
        elif p["name"] == "misc":
            m = bytearray(open(MISC_VEC, "rb").read())
            m[0:2048] = b"\0" * 2048            # BCB 空（实机向量里本来就是空的；明确一下）
            disk.write(bytes(m) + b"\0" * (size - len(m)))
        elif p["name"] in ("boot_a", "boot_b"):
            img = boots[p["name"][-1]]
            disk.write(img + pattern(p["name"], size - len(img)))
        else:
            disk.write(pattern("%s-p%d" % (p["name"], p["index"]), size))
    ents = b"".join(gpt_entry(p["type"], p["guid"], p["first"], p["last"], p["name"]) for p in parts)
    ents += b"\0" * (128 * 128 - len(ents))
    ecrc = zlib.crc32(ents) & 0xffffffff
    last_lba = total - 1
    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(last_lba, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    disk.seek(0)
    disk.write(bytes(mbr))
    disk.write(gpt_header(1, last_lba, 34, last_lba - 33, 2, dguid, ecrc))
    disk.write(ents)
    disk.seek((last_lba - 32) * SECTOR)
    disk.write(ents)
    disk.write(gpt_header(last_lba, 1, 34, last_lba - 33, last_lba - 32, dguid, ecrc))
    disk.close()
    man = dict(layout=a.layout, sectors=total, mid=MID,
               parts=[dict(index=p["index"], name=p["name"], first=p["first"], last=p["last"],
                           partuuid=str(uuid.UUID(bytes_le=p["guid"])), esp=p["type"] == T_ESP) for p in parts])
    json.dump(man, open(os.path.join(a.stage, "manifest.json"), "w"), indent=1)
    for s in "ab":
        open(os.path.join(a.stage, "old-boot_%s.img" % s), "wb").write(boots[s])
    print("disk %s: %s, %d sectors, %d partitions, ESP %s" % (a.out, a.layout, total, len(parts),
                                                              "FAT32" if have_fat else "directory only"))


def load_man(p):
    return json.load(open(p))


def find(man, name):
    hits = [p for p in man["parts"] if p["name"] == name]
    if len(hits) != 1:
        die("manifest 里 %s 有 %d 个" % (name, len(hits)))
    return hits[0]


def read_part(disk, p):
    with open(disk, "rb") as f:
        f.seek(p["first"] * SECTOR)
        return f.read((p["last"] - p["first"] + 1) * SECTOR)


def write_part(disk, p, off, data):
    with open(disk, "r+b") as f:
        f.seek(p["first"] * SECTOR + off)
        f.write(data)


def cmd_mkboot(a):
    rnd = random.Random(a.tag)
    img, _ = mkbootimg(b"MZ\0\0zimg" + hashlib.sha256(a.tag.encode()).digest() * 20000,
                       b"\x1f\x8b" + bytes(rnd.getrandbits(8) for _ in range(300000)),
                       bytes.fromhex("d00dfeed") + bytes(rnd.getrandbits(8) for _ in range(50000)),
                       boot_cmdline(a.tag), a.tag.encode()[:16])
    open(a.out, "wb").write(img)


def cmd_extract(a):
    os.makedirs(a.dir, exist_ok=True)
    for n, d in extract(open(a.boot, "rb").read()).items():
        open(os.path.join(a.dir, n), "wb").write(d)


def lp_metadata(slot_names, maxsz=65536):
    """liblp metadata_format.h 的布局；SHA-256 的算法照 reader.cpp:85-97、:207-216、:276-279。"""
    geo = bytearray(4096)
    struct.pack_into("<II32sIII", geo, 0, 0x616c4467, 52, b"\0" * 32, maxsz, len(slot_names), 4096)
    geo[8:40] = hashlib.sha256(bytes(geo[:52])).digest()
    out = bytearray(4096) + geo + geo
    for names in slot_names:
        tab = b""
        for i, n in enumerate(names):
            tab += n.encode().ljust(36, b"\0") + struct.pack("<IIII", 1, i, 1, 0)
        h = bytearray(256)
        struct.pack_into("<IHHI", h, 0, 0x414C5030, 10, 2, 256)
        struct.pack_into("<I", h, 44, len(tab))
        h[48:80] = hashlib.sha256(tab).digest()
        struct.pack_into("<III", h, 80, 0, len(names), 52)
        struct.pack_into("<III", h, 92, len(tab), 0, 24)
        struct.pack_into("<III", h, 104, len(tab), 0, 48)
        struct.pack_into("<III", h, 116, len(tab), 0, 64)
        h[12:44] = hashlib.sha256(bytes(h)).digest()
        meta = bytes(h) + tab
        out += meta + b"\0" * (maxsz - len(meta))
    return bytes(out)


def cmd_mksuper(a):
    rnd = random.Random(a.seed)
    names = {"a": ["system_a", "vendor_a", "product_a"], "b": ["system_b", "vendor_b", "product_b"]}
    slots = [names["a"] if "a" in a.slots else [], names["b"] if "b" in a.slots else []]
    if a.slots == "none":
        meta = b"\0" * 4096 * 4
    else:
        meta = lp_metadata(slots)
    body = bytearray(a.size)
    body[:len(meta)] = meta
    # 1 MiB 起：每 2 MiB 里前 1 MiB 随机（img2simg 记成 RAW）、后 1 MiB 零（记成 FILL / DONT_CARE）
    for off in range(MiB, a.size, 2 * MiB):
        n = min(MiB, a.size - off)
        body[off:off + n] = rnd.randbytes(n)
    open(a.out, "wb").write(bytes(body))


def sparse_build(chunks, blk, total, chunk_count=None):
    out = struct.pack("<IHHHHIIII", 0xed26ff3a, 1, 0, 28, 12, blk, total,
                      len(chunks) if chunk_count is None else chunk_count, 0)
    for typ, nblk, data in chunks:
        out += struct.pack("<HHII", typ, 0, nblk, 12 + len(data)) + data
    return out


def sparse_kind(kind, part_size):
    blk = 4096
    total = part_size // blk
    raw = bytes((i * 7 + 3) & 0xff for i in range(2 * blk))
    tail = b"\x5a" * blk
    if kind in ("ok", "trailing"):
        # [raw 2][fill 3 = 0xa5a5a5a5][dontcare …][crc][raw 1]
        ch = [(0xCAC1, 2, raw), (0xCAC2, 3, b"\xa5\xa5\xa5\xa5"), (0xCAC3, total - 6, b""), (0xCAC4, 0, b"\0" * 4),
              (0xCAC1, 1, tail)]
        b = sparse_build(ch, blk, total)
        return b + (b"X" if kind == "trailing" else b"")
    if kind == "oob":       # 头说比分区多一块
        return sparse_build([(0xCAC1, 2, raw), (0xCAC3, total - 1, b"")], blk, total + 1)
    if kind == "chunkpast":  # chunk 合计越过 total_blks
        return sparse_build([(0xCAC1, 2, raw), (0xCAC3, total, b"")], blk, total)
    if kind == "rawshort":   # raw chunk 声称 3 块、只带 2 块的数据
        return sparse_build([(0xCAC1, 3, raw), (0xCAC3, total - 3, b"")], blk, total)
    if kind == "sum":        # 合计比 total 少一块
        return sparse_build([(0xCAC1, 2, raw), (0xCAC3, total - 3, b"")], blk, total)
    die("unknown sparse kind " + kind)


def cmd_sparse(a):
    open(a.out, "wb").write(sparse_kind(a.kind, a.part_size))


def cmd_sparse_expect(a):
    base = bytearray(open(a.base, "rb").read())
    blk = 4096
    raw = bytes((i * 7 + 3) & 0xff for i in range(2 * blk))
    base[0:2 * blk] = raw
    base[2 * blk:5 * blk] = b"\xa5" * (3 * blk)
    total = len(base) // blk
    base[(total - 1) * blk:total * blk] = b"\x5a" * blk
    open(a.out, "wb").write(bytes(base))


def cmd_part(a):
    man = load_man(a.manifest)
    open(a.outf, "wb").write(read_part(a.disk, find(man, a.name)))


def cmd_sums(a):
    man = load_man(a.manifest)
    skip = set(a.skip.split(",")) if a.skip else set()
    res = {}
    with open(a.disk, "rb") as f:
        parts = sorted(man["parts"], key=lambda p: p["first"])
        pos = 0
        for p in parts:
            f.seek(pos * SECTOR)
            res["gap@%d" % pos] = hashlib.sha256(f.read((p["first"] - pos) * SECTOR)).hexdigest()
            key = "p%d:%s" % (p["index"], p["name"])
            f.seek(p["first"] * SECTOR)
            n = (p["last"] - p["first"] + 1) * SECTOR
            res[key] = "skipped" if p["name"] in skip else hashlib.sha256(f.read(n)).hexdigest()
            pos = p["last"] + 1
        f.seek(pos * SECTOR)
        res["gap@%d" % pos] = hashlib.sha256(f.read()).hexdigest()
    json.dump(res, sys.stdout, indent=1, sort_keys=True)
    print()


BCAB_REAL = None


def bcab_crc(b):
    return struct.pack("<I", zlib.crc32(bytes(b[:28])) & 0xffffffff)


def slot_get(b, s):
    v = struct.unpack_from("<H", b, 12 + 2 * s)[0]
    return dict(pri=v & 15, tries=(v >> 4) & 7, ok=(v >> 7) & 1, vc=(v >> 8) & 1, rest=v & ~0x1ff)


def slot_put(b, s, d):
    v = d["rest"] | d["pri"] | d["tries"] << 4 | d["ok"] << 7 | d["vc"] << 8
    struct.pack_into("<H", b, 12 + 2 * s, v)


def cmd_misc(a):
    man = load_man(a.manifest)
    p = find(man, "misc")
    m = bytearray(read_part(a.disk, p)[:65536])
    if a.bcb:
        m[0:2048] = b"\0" * 2048
        if a.bcb == "bootloader":
            m[0:19] = b"bootonce-bootloader"
        elif a.bcb in ("fastboot", "recovery", "wipe", "wipe2", "prompt"):
            m[0:13] = b"boot-recovery"
            args = {"fastboot": "recovery\n--fastboot\n", "recovery": "recovery\n",
                    "wipe": "recovery\n--wipe_data\n--reason=MainClearConfirm\n",
                    # 另一份 wipe（原因不同 ⇒ 摘要不同）：模拟"入口记的不是这一份"
                    "wipe2": "recovery\n--wipe_data\n--reason=SomethingElse\n",
                    "prompt": "recovery\n--prompt_and_wipe_data\n--reason=RescueParty\n"}[a.bcb]
            m[64:64 + len(args)] = args.encode()
    if a.vab:
        st = {"none": 0, "snapshotted": 2, "merging": 3}[a.vab]
        v = bytearray(64)
        struct.pack_into("<BIBB", v, 0, 2, 0x56740AB0, st, 0)
        m[32768:32768 + 64] = v
    if a.bcab:
        b = m[2048:2080]
        if a.bcab == "b-unbootable":
            slot_put(b, 0, dict(pri=15, tries=1, ok=1, vc=0, rest=0))
            slot_put(b, 1, dict(pri=14, tries=0, ok=0, vc=0, rest=0))
        elif a.bcab == "both":
            slot_put(b, 0, dict(pri=15, tries=1, ok=1, vc=0, rest=0))
            slot_put(b, 1, dict(pri=14, tries=0, ok=1, vc=0, rest=0))
        b[28:32] = bcab_crc(b)
        if a.bcab == "invalid":
            b[28] ^= 0xff
        m[2048:2080] = b
    if a.rec:
        # GK3 记录 v1（gk3core.h 的布局）：none = 全零；plain = 有效、未迁移；migrated = 置迁移标记；
        # dispatched = 迁移 + 入口按【当前这份】BCB 分派过一次 wipe（why=3、count=1、摘要 = SHA-1(BCB 2048 字节)）
        r = bytearray(2048)
        if a.rec != "none":
            struct.pack_into("<IHHII", r, 0, 0x52334B47, 1, 2048, 0 if a.rec == "plain" else 1,
                             0 if a.rec == "plain" else 1)
            if a.rec == "dispatched":
                r[23] = 3          # dispatch_why = GK3_BCB_WIPE
                r[24] = 0          # dispatch_slot
                r[25] = 1          # dispatch_count
                r[28:48] = hashlib.sha1(bytes(m[0:2048])).digest()
            struct.pack_into("<I", r, 2044, zlib.crc32(bytes(r[:2044])) & 0xffffffff)
        m[8192:8192 + 2048] = r
    write_part(a.disk, p, 0, bytes(m))


EV_NAMES = ["none", "fallback", "boot_corrupt", "bcb_dropped", "wipe_failed", "refused_merging", "bootloop",
            "noslot", "migrated", "bcb_ignored"]


def rec_events(r):
    """GK3 记录的事件环，按 seq 从旧到新：["refused_merging:3", …]（名字:aux）"""
    if struct.unpack_from("<I", r, 0)[0] != 0x52334B47 or \
            struct.unpack_from("<I", r, 2044)[0] != zlib.crc32(bytes(r[:2044])) & 0xffffffff:
        return None
    ev = []
    for i in range(32):
        seq, code, slot, flags, aux = struct.unpack_from("<IHBBI", r, 1024 + 16 * i)
        if seq:
            ev.append((seq, "%s:%d" % (EV_NAMES[code] if code < len(EV_NAMES) else str(code), aux)))
    return [e for _, e in sorted(ev)]


def cmd_misc_dump(a):
    man = load_man(a.manifest)
    m = read_part(a.disk, find(man, "misc"))[:65536]
    cmd = m[0:32].split(b"\0")[0].decode("latin-1")
    rec = m[64:64 + 768].split(b"\0")[0].decode("latin-1").replace("\n", "\\n")
    vab = struct.unpack_from("<BIBB", m, 32768)
    print("bcb_command=%s" % cmd)
    print("bcb_recovery=%s" % rec)
    print("bcb_sha256=%s" % hashlib.sha256(m[:2048]).hexdigest())
    print("bcab=%s" % m[2048:2080].hex())
    print("vab_status=%d" % vab[2])
    ev = rec_events(m[8192:8192 + 2048])
    print("rec=%s" % ("invalid" if ev is None else "valid"))
    print("rec_events=%s" % ("" if ev is None else ",".join(ev)))


def cmd_bcb_expect(a):
    """一份空 BCB 经 init 的写法写成某种意图之后的 2048 字节 sha256（独立于 C 实现的期望值）"""
    m = bytearray(2048)
    if a.kind == "bootloader":
        m[0:19] = b"bootonce-bootloader"
    elif a.kind == "recovery":
        m[0:13] = b"boot-recovery"
    elif a.kind == "fastboot":
        m[0:13] = b"boot-recovery"
        m[64:64 + 20] = b"recovery\n--fastboot\n"
    print(hashlib.sha256(bytes(m)).hexdigest())


def cmd_bcab_set_active(a):
    b = bytearray.fromhex(a.hex)
    slot, cur = int(a.slot), int(a.cur)
    nb = b[9] & 7
    for i in range(nb):
        if i == slot:
            continue
        d = slot_get(b, i)
        if d["pri"] >= 15:
            d["pri"] = 14
            slot_put(b, i, d)
    d = slot_get(b, slot)
    d["pri"], d["tries"] = 15, 6
    if slot != cur:
        d["vc"] = 0
    slot_put(b, slot, d)
    b[28:32] = bcab_crc(b)
    print(b.hex())


def cmd_client(a):
    s = socket.create_connection(("127.0.0.1", a.port), timeout=30)
    s.sendall(b"FB01")
    hs = s.recv(4)
    if hs != b"FB01":
        die("handshake %r" % hs)

    def send(b):
        s.sendall(struct.pack(">Q", len(b)) + b)

    def recv():
        h = b""
        while len(h) < 8:
            c = s.recv(8 - len(h))
            if not c:
                return None
            h += c
        n = struct.unpack(">Q", h)[0]
        d = b""
        while len(d) < n:
            c = s.recv(n - len(d))
            if not c:
                return None
            d += c
        return d

    def command(c, payload=None):
        send(c.encode())
        while True:
            r = recv()
            if r is None:
                print("DISCONNECTED")
                return False
            print(r.decode("latin-1"))
            if r.startswith(b"DATA") and payload is not None:
                send(payload)
                continue
            if r[:4] in (b"OKAY", b"FAIL"):
                return r.startswith(b"OKAY")

    if a.download:
        data = open(a.download, "rb").read()
        command("download:%08x" % len(data), data)
    for c in a.cmd:
        command(c)
    s.close()


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="c", required=True)
    p = sp.add_parser("mkdisk")
    p.add_argument("--layout", required=True, choices=sorted(LAYOUTS))
    p.add_argument("--out", required=True)
    p.add_argument("--stage", required=True)
    p.add_argument("--seed", type=int, default=1)
    p = sp.add_parser("mkboot")
    p.add_argument("--tag", required=True)
    p.add_argument("--out", required=True)
    p = sp.add_parser("extract")
    p.add_argument("boot")
    p.add_argument("dir")
    p = sp.add_parser("mksuper")
    p.add_argument("--out", required=True)
    p.add_argument("--size", type=int, required=True)
    p.add_argument("--slots", default="a")
    p.add_argument("--seed", type=int, default=7)
    p = sp.add_parser("sparse")
    p.add_argument("--kind", required=True)
    p.add_argument("--part-size", type=int, required=True)
    p.add_argument("--out", required=True)
    p = sp.add_parser("sparse-expect")
    p.add_argument("--kind", default="ok")
    p.add_argument("--base", required=True)
    p.add_argument("--out", required=True)
    p = sp.add_parser("part")
    p.add_argument("disk")
    p.add_argument("manifest")
    p.add_argument("name")
    p.add_argument("outf")
    p = sp.add_parser("sums")
    p.add_argument("disk")
    p.add_argument("manifest")
    p.add_argument("--skip", default="")
    p = sp.add_parser("misc")
    p.add_argument("disk")
    p.add_argument("manifest")
    p.add_argument("--bcb")
    p.add_argument("--vab")
    p.add_argument("--bcab")
    p.add_argument("--rec", choices=["none", "plain", "migrated", "dispatched"])
    p = sp.add_parser("misc-dump")
    p.add_argument("disk")
    p.add_argument("manifest")
    p = sp.add_parser("bcb-expect")
    p.add_argument("kind")
    p = sp.add_parser("bcab-set-active")
    p.add_argument("hex")
    p.add_argument("slot")
    p.add_argument("cur")
    p = sp.add_parser("client")
    p.add_argument("--port", type=int, default=5554)
    p.add_argument("--download")
    p.add_argument("cmd", nargs="*")
    a = ap.parse_args()
    globals()["cmd_" + a.c.replace("-", "_")](a)


if __name__ == "__main__":
    main()

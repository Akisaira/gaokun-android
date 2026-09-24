#!/usr/bin/env python3
# 从内核镜像里抽出它编译时的 .config（要求 CONFIG_IKCONFIG=y —— 本机内核是开着的，
# 设备上的 /proc/config.gz 就是它）。不用上机、不用内核树。
#
#   python3 scripts/extract-kconfig.py device/huawei/gaokun3/prebuilt-boot/vmlinuz.efi > v.config
#   python3 scripts/extract-kconfig.py boot.img > v.config        # 发版的 boot.img 也行
#
# 认得三种输入：Android boot.img（v2，内核在第一页之后）、EFI zboot 的 vmlinuz.efi
# （"MZ" + @4 "zimg"，@8/@12 载荷偏移与长度，@24 压缩算法名）、未压缩的 arm64 Image（@56 "ARMd"）。
# 配置在 Image 里以 "IKCFG_ST" 开头、gzip 压缩。
#
# ★ 为什么有它：2026-09-25 要核对"这个内核能不能跑 Debian 的 systemd"（Stage 7 M0.5），
#   原计划要读设备上的 /proc/config.gz，而设备不在身边。发版内核就在仓库旁边。
import gzip, struct, sys, zlib


def kernel_of(data):
    if data[:8] == b"ANDROID!":                       # boot.img v2：kernel_size@8，page@36
        ksize, page = struct.unpack_from("<I", data, 8)[0], struct.unpack_from("<I", data, 36)[0]
        return kernel_of(data[page:page + ksize])
    if data[:2] == b"MZ" and data[4:8] == b"zimg":    # EFI zboot
        off, size = struct.unpack_from("<II", data, 8)
        comp = data[24:40].split(b"\0")[0].decode()
        payload = data[off:off + size]
        if comp == "gzip":
            return gzip.decompress(payload)
        sys.exit("!! zboot 载荷是 %s 压缩，这个脚本只认 gzip（本机内核是 gzip）" % comp)
    if data[56:60] == b"ARMd":
        return data
    sys.exit("!! 认不出这是什么镜像（不是 boot.img / zboot / arm64 Image）")


img = kernel_of(open(sys.argv[1], "rb").read())
i = img.find(b"IKCFG_ST")
if i < 0:
    sys.exit("!! 内核里没有嵌配置（CONFIG_IKCONFIG 没开）")
sys.stdout.write(zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(img[i + 8:]).decode())

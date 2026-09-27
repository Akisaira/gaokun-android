#!/usr/bin/env bash
# 造给 Windows 用户的免 U 盘安装包（gaokun3-setup.ps1 读的那个目录）+ 一个 zip。
# 由 scripts/live/build-live.sh 在构建容器里调用；也能单独跑（要 bash、python3、sha256sum）。
#
#   bash scripts/windows/build-bundle.sh --squashfs gaokun3-live.squashfs --initramfs initramfs.img \
#        --kernel Image --dtb gaokun3.dtb --sdboot systemd-bootaa64.efi --cmdline cmdline.txt \
#        [--rescue-squashfs gaokun3-rescue.squashfs] --out <目录>
#
# 布局（gaokun3-setup.ps1 按这个找东西；esp/ 与 live/ 下的每个文件都进 SHA256SUMS）：
#   gaokun3-setup.cmd / gaokun3-setup.ps1
#   esp/EFI/gaokun3/{systemd-bootaa64.efi, Image, gaokun3.dtb, initramfs.img}   → 拷进 ESP
#   esp/loader/entries/gaokun3-live.conf                                        → 拷进 ESP
#   live/gaokun3/live.squashfs、initramfs.img、install-rescue/rescue.squashfs    → 拷进 GK3LIVE 分区
#   （payload/：用户自己把发布的 boot.img / super.img.zst / install-artifacts.sha256 放这里 = 离线安装）
#
# ★ live/ 里也放一份 initramfs.img：安装器判"能装救援系统"要在介质上找到它
#   （installer-lib.sh 的 gk3_release_info），而这条路上内核与 initramfs 本来只在 ESP 上。
# ★ 启动项【不】带 gk3.dev：Windows 那边不知道 Linux 给分区起什么名字；initramfs 会逐个分区找
#   /gaokun3/live.squashfs（GK3LIVE 是 FAT32，只读挂载无副作用；BitLocker 卷挂不上，自然跳过）。
# ⓘ squashfs 里带着华为专有的 GPU zap shader —— 随包公开发布（用户 2026-09-27 定 B23 ①：随镜像发，与 ROM 同待遇 —— 已发布的 ROM 的 vendor 里本来就带着它）。
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "!! $*" >&2; exit 1; }
SQ= INIT= KERNEL= DTB= SDBOOT= CMDLINE= RSQ= OUT=
while [ $# -gt 0 ]; do
    case "$1" in
        --squashfs) SQ=$2; shift 2 ;;
        --initramfs) INIT=$2; shift 2 ;;
        --kernel) KERNEL=$2; shift 2 ;;
        --dtb) DTB=$2; shift 2 ;;
        --sdboot) SDBOOT=$2; shift 2 ;;
        --cmdline) CMDLINE=$2; shift 2 ;;
        --rescue-squashfs) RSQ=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        *) die "不认识的参数：$1" ;;
    esac
done
for v in SQ INIT KERNEL DTB SDBOOT CMDLINE OUT; do [ -n "${!v}" ] || die "缺 --$(echo "$v" | tr 'A-Z' 'a-z')"; done
for f in "$SQ" "$INIT" "$KERNEL" "$DTB" "$SDBOOT" "$CMDLINE" ${RSQ:+"$RSQ"}; do [ -f "$f" ] || die "没有 $f"; done
for f in gaokun3-setup.ps1 gaokun3-setup.cmd; do [ -f "$HERE/$f" ] || die "没有 $HERE/$f"; done
# PowerShell 5.1 要 BOM（否则中文乱码）；cmd 要 CRLF —— 入库时就是这样，这里再核一遍，免得哪次编辑器存丢了
[ "$(head -c 3 "$HERE/gaokun3-setup.ps1" | od -An -tx1 | tr -d ' ')" = efbbbf ] || die "gaokun3-setup.ps1 没有 UTF-8 BOM"
grep -q $'\r$' "$HERE/gaokun3-setup.cmd" || die "gaokun3-setup.cmd 不是 CRLF"

rm -rf "$OUT"; mkdir -p "$OUT/esp/EFI/gaokun3" "$OUT/esp/loader/entries" "$OUT/live/gaokun3"
cp "$SDBOOT" "$OUT/esp/EFI/gaokun3/systemd-bootaa64.efi"
cp "$KERNEL" "$OUT/esp/EFI/gaokun3/Image"
cp "$DTB"    "$OUT/esp/EFI/gaokun3/gaokun3.dtb"
cp "$INIT"   "$OUT/esp/EFI/gaokun3/initramfs.img"
cp "$SQ"     "$OUT/live/gaokun3/live.squashfs"
cp "$INIT"   "$OUT/live/gaokun3/initramfs.img"
[ -z "$RSQ" ] || { mkdir -p "$OUT/live/gaokun3/install-rescue"; cp "$RSQ" "$OUT/live/gaokun3/install-rescue/rescue.squashfs"; }

# 内核参数：与 U 盘、装机时的救援条目同一个函数派生（从 boot.img 的 cmdline.txt），squashfs 指到 live.squashfs
# shellcheck source=../live/installer-lib.sh
. "$HERE/../live/installer-lib.sh"
OPTS=$(gk3__rescue_cmdline "$(tr -d '\r\n' < "$CMDLINE")" | sed 's#gk3\.squash=[^ ]*#gk3.squash=/gaokun3/live.squashfs#')
case "$OPTS" in *gk3.squash=/gaokun3/live.squashfs*) ;; *) die "派生的内核参数里没有 gk3.squash：$OPTS" ;; esac
cat > "$OUT/esp/loader/entries/gaokun3-live.conf" <<EOF
title      gaokun3 installer
version    live
sort-key   gk3live
linux      /EFI/gaokun3/Image
devicetree /EFI/gaokun3/gaokun3.dtb
initrd     /EFI/gaokun3/initramfs.img
options    $OPTS
EOF
cp "$HERE/gaokun3-setup.ps1" "$HERE/gaokun3-setup.cmd" "$OUT/"
( cd "$OUT" && find esp live -type f | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
echo "   ✓ Windows 安装包 → $OUT（$(du -sh "$OUT" | cut -f1)，SHA256SUMS $(wc -l < "$OUT/SHA256SUMS") 个文件）"
# zip：squashfs 本来就压过，存储即可；其余 deflate
python3 - "$OUT" "$OUT.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
top = os.path.basename(src.rstrip('/'))
with zipfile.ZipFile(dst, 'w') as z:
    for root, _, files in os.walk(src):
        for f in sorted(files):
            p = os.path.join(root, f)
            arc = os.path.join(top, os.path.relpath(p, src))
            z.write(p, arc, zipfile.ZIP_STORED if f.endswith('.squashfs') else zipfile.ZIP_DEFLATED)
PY
echo "   ✓ $OUT.zip（$(du -h "$OUT.zip" | cut -f1)）（带华为 GPU 固件，与 ROM 同待遇，TODO B23）"

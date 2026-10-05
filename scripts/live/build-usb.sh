#!/usr/bin/env bash
# 把 Stage 7 的产物组装成一个可启动的 U 盘镜像（GPT + 单个 ESP）。
#
#   bash scripts/live/build-usb.sh \
#        --squashfs /tmp/gk3/gaokun3-live.squashfs \
#        --initramfs /tmp/gk3/initramfs.img \
#        --kernel  /path/to/vmlinuz.efi \
#        --dtb     /path/to/gaokun3.dtb \
#        --sdboot  /path/to/systemd-bootaa64.efi \
#        [--payload /path/to/release-dir] \
#        [--cmdline /path/to/cmdline.txt] \
#        [--entry "标题|附加的内核参数"]…  \
#        --out /tmp/gk3/gaokun3-live.img
#
#   --cmdline  启动项的内核参数从 boot.img 的 cmdline.txt 派生（gk3-bootimg.py 拆出来的那份），
#              过滤规则与装机时的救援条目是【同一个函数】（installer-lib.sh 的 gk3__rescue_cmdline）。
#              ⚠️ 不给就退回下面那份手抄的 —— 那正是 TODO B15 那一类漂移（它缺 himax disable_pressure）。
#   --entry    多放几个启动项（M0 用：Skia / 浸泡测试…），在开机菜单里选
#   --windows-tools <目录>  可选：把 Windows 伴随工具（目录里的 gaokun3-setup.ps1 / gaokun3-setup.cmd）放进 U 盘的
#              gaokun3-windows/ —— 从 U 盘装双系统的用户回到 Windows 后双击它安装伴随工具（boot-entry-design §4.9.15，U23）。
#              FAT 分区 Windows 能直接读；不给就不放（与原来一样）
#   --rescue-squashfs  装机时装进救援分区的镜像（rescue profile）→ U 盘的 gaokun3/install-rescue/。
#              不给的话安装器只能把 live 镜像本身当救援系统装进去（见 installer-lib.sh 的 gk3_apply）
#
# ★ 用 mtools 往 FAT 里塞文件，【不需要 root】，也不需要 loop 设备。
#   好处不只是省事：不用 root 就不会因为一次手滑把宿主机的分区写了。
#
# 写盘： sudo dd if=gaokun3-live.img of=/dev/sdX bs=4M conv=fsync status=progress
set -euo pipefail

SQUASH=; INITRAMFS=; KERNEL=; DTB=; SDBOOT=; PAYLOAD=; OUT=; SIZE_MIB=; WIFI=; CMDLINE=; RESCUE_SQ=; WINTOOLS=
ENTRIES=()
die() { echo "!! $*" >&2; exit 1; }
say() { echo; echo "══ $*"; }
ok()  { echo "   ✓ $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --squashfs)  SQUASH=$2; shift 2 ;;
        --initramfs) INITRAMFS=$2; shift 2 ;;
        --kernel)    KERNEL=$2; shift 2 ;;
        --dtb)       DTB=$2; shift 2 ;;
        --sdboot)    SDBOOT=$2; shift 2 ;;
        --payload)   PAYLOAD=$2; shift 2 ;;
        --wifi-conf) WIFI=$2; shift 2 ;;
        --cmdline)   CMDLINE=$2; shift 2 ;;
        --entry)     ENTRIES+=("$2"); shift 2 ;;
        --rescue-squashfs) RESCUE_SQ=$2; shift 2 ;;
        --windows-tools) WINTOOLS=$2; shift 2 ;;
        --release-info) RELINFO=$2; shift 2 ;;
        --size)      SIZE_MIB=$2; shift 2 ;;
        --out)       OUT=$2; shift 2 ;;
        *) die "不认识的参数：$1" ;;
    esac
done
for v in SQUASH INITRAMFS KERNEL DTB SDBOOT OUT; do
    eval "x=\${$v}"
    [ -n "$x" ] || die "缺参数 --$(echo "$v" | tr 'A-Z' 'a-z')"
done
for f in "$SQUASH" "$INITRAMFS" "$KERNEL" "$DTB" "$SDBOOT"; do
    [ -f "$f" ] || die "文件不在：$f"
done
head -c 2 "$SDBOOT" | grep -q MZ || die "$SDBOOT 不是 PE 文件"
head -c 2 "$KERNEL" | grep -q MZ || die "$KERNEL 不是 PE 文件（要 EFI stub 内核 / vmlinuz.efi）"
[ "$(od -An -tx1 -N4 "$DTB" | tr -d ' ')" = "d00dfeed" ] || die "$DTB 不是 FDT（magic 不对）"
ok "输入体检通过（PE / PE / FDT）"

for t in sgdisk mformat mmd mcopy; do
    command -v "$t" >/dev/null || die "缺工具：${t}（apt install gdisk mtools）"
done

# —— 算大小 ——
need=0
for f in "$SQUASH" "$INITRAMFS" "$KERNEL" "$DTB" "$SDBOOT"; do
    need=$(( need + $(stat -c %s "$f") ))
done
[ -n "$RESCUE_SQ" ] && { [ -f "$RESCUE_SQ" ] || die "--rescue-squashfs 不在：$RESCUE_SQ"; need=$(( need + $(wc -c < "$RESCUE_SQ") )); }
if [ -n "$PAYLOAD" ]; then
    [ -d "$PAYLOAD" ] || die "--payload 不是目录：$PAYLOAD"
    need=$(( need + $(du -sb "$PAYLOAD" | cut -f1) ))
fi
# 25% 余量 + 64 MiB 底
MIN=$(( need / 1048576 * 125 / 100 + 64 ))
SIZE_MIB=${SIZE_MIB:-$MIN}
[ "$SIZE_MIB" -ge "$MIN" ] || die "--size $SIZE_MIB MiB 不够，至少要 $MIN MiB"
say "镜像 ${SIZE_MIB} MiB（内容 $(( need / 1048576 )) MiB）"

PART_OFF=1048576   # 1 MiB 对齐
rm -f "$OUT"
truncate -s "${SIZE_MIB}M" "$OUT"

# —— GPT + ESP ——
# ⚠️ 分区名用 "esp"：本仓的 boot_control HAL 靠 by-name/esp 找 ESP
#    （install-gaokun3.sh 的注释里记过原因）。U 盘上虽然用不到，
#    但保持一致，免得两处规则不一样。
sgdisk --zap-all "$OUT" >/dev/null
sgdisk -n 1:2048:0 -t 1:ef00 -c 1:"esp" "$OUT" >/dev/null
ok "GPT + ESP 分区"

mformat -i "$OUT@@$PART_OFF" -F -v GK3LIVE ::
ok "FAT32（卷标 GK3LIVE）"

M() { mcopy -i "$OUT@@$PART_OFF" -o "$@"; }
mmd -i "$OUT@@$PART_OFF" ::/EFI ::/EFI/BOOT ::/loader ::/loader/entries ::/gaokun3

M "$SDBOOT"    ::/EFI/BOOT/BOOTAA64.EFI
M "$KERNEL"    ::/gaokun3/Image
M "$DTB"       ::/gaokun3/gaokun3.dtb
M "$INITRAMFS" ::/gaokun3/initramfs.img
M "$SQUASH"    ::/gaokun3/rescue.squashfs
ok "引导链 + 内核 + initramfs + squashfs"
if [ -n "${RELINFO:-}" ]; then M "$RELINFO" ::/gaokun3/release.txt; ok "版本信息 gaokun3/release.txt（$(sed -n 's/^GK3_INSTALLER_VERSION=//p' "$RELINFO")）"; fi

if [ -n "$RESCUE_SQ" ]; then
    mmd -i "$OUT@@$PART_OFF" ::/gaokun3/install-rescue
    M "$RESCUE_SQ" ::/gaokun3/install-rescue/rescue.squashfs
    ok "带上了给装机用的救援镜像（$(du -h "$RESCUE_SQ" | cut -f1)）"
fi

if [ -n "$PAYLOAD" ]; then
    mmd -i "$OUT@@$PART_OFF" ::/gaokun3/payload
    for f in "$PAYLOAD"/*; do
        [ -f "$f" ] || continue
        M "$f" "::/gaokun3/payload/$(basename "$f")"
    done
    ok "带上了安装载荷（$(ls -1 "$PAYLOAD" | wc -l) 个文件）"
fi

# Windows 伴随工具（可选，U23）：只放两个脚本（不到 200 KiB），不放 live —— U 盘上本来就有
if [ -n "$WINTOOLS" ]; then
    for f in gaokun3-setup.ps1 gaokun3-setup.cmd; do [ -f "$WINTOOLS/$f" ] || die "--windows-tools 里没有 $f"; done
    [ "$(head -c 3 "$WINTOOLS/gaokun3-setup.ps1" | od -An -tx1 | tr -d ' ')" = efbbbf ] || die "gaokun3-setup.ps1 没有 UTF-8 BOM（Windows PowerShell 5.1 会读成乱码）"
    mmd -i "$OUT@@$PART_OFF" ::/gaokun3-windows
    M "$WINTOOLS/gaokun3-setup.ps1" ::/gaokun3-windows/gaokun3-setup.ps1
    M "$WINTOOLS/gaokun3-setup.cmd" ::/gaokun3-windows/gaokun3-setup.cmd
    ok "带上了 Windows 伴随工具（gaokun3-windows/，预览）"
fi

# WiFi 凭据（可选）。放在【介质】上而不是镜像里 —— 公开发布的 LiveCD
# 一个字都不带，而自用的这根 U 盘带上就能开机自动联网、方便远程调试。
# ⚠️ 本仓不收这个文件。
if [ -n "$WIFI" ]; then
    [ -f "$WIFI" ] || die "--wifi-conf 指的文件不在：$WIFI"
    grep -q 'network=' "$WIFI" || die "$WIFI 不像 wpa_supplicant 配置"
    M "$WIFI" ::/gaokun3/wpa_supplicant.conf
    ok "带上了 WiFi 配置（$(grep -c 'network=' "$WIFI") 个网络）"
fi

if [ -n "$CMDLINE" ]; then
    [ -f "$CMDLINE" ] || die "--cmdline 指的文件不在：$CMDLINE"
    # shellcheck source=installer-lib.sh
    . "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
    OPTS=$(gk3__rescue_cmdline "$(tr -d '\r\n' < "$CMDLINE")")
    ok "内核参数从 $(basename "$CMDLINE") 派生"
else
    OPTS="console=tty0 clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 loglevel=4 gk3.squash=/gaokun3/rescue.squashfs"
    echo "   ⚠️ 没给 --cmdline：用脚本里手抄的内核参数（会漂，TODO B15）"
fi

TMP=$(mktemp)
{
    # ⚠️ 【不要】设 timeout 0 —— 万一起不来，用户连菜单都进不去。
    #    只有一个条目时不设 default，systemd-boot 会直接进；有变体条目时默认进主条目、多给几秒去选。
    if [ ${#ENTRIES[@]} -gt 0 ]; then echo "timeout 10"; echo "default gaokun3-live.conf"; else echo "timeout 5"; fi
    echo "console-mode keep"
    echo "editor no"
} > "$TMP"
M "$TMP" ::/loader/loader.conf

entry() {   # $1=文件名 $2=标题 $3=sort-key $4=附加参数
    cat > "$TMP" <<EOF
title      $2
version    live
sort-key   $3
linux      /gaokun3/Image
devicetree /gaokun3/gaokun3.dtb
initrd     /gaokun3/initramfs.img
options    $OPTS${4:+ $4}
EOF
    M "$TMP" "::/loader/entries/$1"
}
# ⚠️ 标题用 ASCII：开机菜单是 UEFI 固件用它自己的字体画的，一般不含中文 —— 中文标题在菜单上
#    多半是方块（没有在本机实测过，所以取稳妥的一侧）。中文只留在图形界面里，那边字体是我们带的。
entry gaokun3-live.conf "gaokun3 installer / rescue" live0 ""
i=1
for e in ${ENTRIES[@]+"${ENTRIES[@]}"}; do
    entry "gaokun3-live-$i.conf" "${e%%|*}" "live$i" "${e#*|}"
    i=$((i + 1))
done
rm -f "$TMP"
ok "启动项 $i 个"

say "体检"
LIST=$(mdir -i "$OUT@@$PART_OFF" -b ::/gaokun3 ::/EFI/BOOT ::/loader/entries 2>/dev/null)
for want in Image gaokun3.dtb initramfs.img rescue.squashfs BOOTAA64.EFI gaokun3-live.conf; do
    printf '%s' "$LIST" | grep -qi "$want" && ok "$want" || die "镜像里没有 $want"
done
echo
echo "$OUT  $(du -h "$OUT" | cut -f1)"
echo "写盘： sudo dd if=$OUT of=/dev/sdX bs=4M conv=fsync status=progress"

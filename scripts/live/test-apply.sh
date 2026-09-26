#!/usr/bin/env bash
# 安装器写盘路径的端到端测试：在 loop 设备上真装，逐项核对。
#
#   bash scripts/live/test-in-container.sh scripts/live/test-apply.sh
#   GK3_TEST_BOOTIMG=/repo/out/v0.6.2/boot.img bash scripts/live/test-in-container.sh scripts/live/test-apply.sh
#   GK3_TEST_FIXTURES=/repo/live/installer-flutter/testdata  …（顺带把探测输出存成界面的 fixture）
#
# 必须 root + loop 设备 + 能看见新出现的分区节点 —— 容器入口替你安排好了。
# ⚠️ 只动 colima 虚拟机里的 loop 设备（背后是容器里 /tmp 下的稀疏文件）。
#
# 覆盖：
#   A. 命令行版 install-gaokun3.sh：不输 ERASE 时一个字节都不写；输了就整盘装完
#   B. 双系统：盘上已有 ESP + MSR + NTFS「Basic data partition」+ 末尾 WinRE，
#      装进中间的空闲区 —— 原有分区的内容与 PARTUUID 一个都不许变、ESP 不许重新格式化
#   C. 反例，都必须【在动盘之前】拒绝：截断的 .zst、sha256 不符、在已装过的盘上再装一次；
#      以及 dry-run 一个字节都不写
#   D. 探测输出里 PARTLABEL 的空格按协议编码（"Basic data partition" 不能变成 "Basic"）
#
# ⚠️ 故意不开 pipefail：判据都显式取退出码（scripts/verify-root.sh:8-11）。
set -u
cd "$(dirname "$0")/../.."
REPO=$(pwd)
[ "$(id -u)" = 0 ] || { echo "要 root（用 scripts/live/test-in-container.sh 跑）"; exit 2; }
. scripts/live/installer-lib.sh
export GK3_ALLOW_LOOP=1

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
sha_head() { head -c "$2" "$1" | sha256sum | cut -d' ' -f1; }
fp() { sgdisk -p "$1" 2>/dev/null | grep -v '^Disk identifier'; head -c 1048576 "$1" | sha256sum; }

W=$(mktemp -d /tmp/gk3-test.XXXX)
LOOPS=()
cleanup() {
    local l m
    for m in $(findmnt -rno TARGET | grep -e "^$W" -e '^/media/gk3' | sort -r); do umount "$m" 2>/dev/null; done
    # ⚠️★ 按背后的镜像文件找 loop，【不】靠 LOOPS 数组：new_disk 是在 $(…) 里调的，
    #   它往 LOOPS 里加的东西留在子 shell 里 —— 2026-09-24 就这样漏了 58 个 loop，
    #   每个攥着一个已删除的稀疏文件，把 colima 的 98G 盘写满。
    for img in "$W"/*.img; do
        for l in $(losetup -j "$img" 2>/dev/null | cut -d: -f1); do losetup -d "$l" 2>/dev/null; done
    done
    rm -rf "$W"
}
trap cleanup EXIT
new_disk() {   # $1=名字 $2=大小 → 打印 loop 设备
    truncate -s "$2" "$W/$1.img"
    local l; l=$(losetup -fP --show "$W/$1.img") || { echo "losetup 失败" >&2; exit 2; }
    LOOPS+=("$l"); echo "$l"
}
MID=0123456789abcdef0123456789abcdef
export GK3_MACHINE_ID=$MID

# ── 造一份发布目录 ──────────────────────────────────────────────────────────
echo "═══ 0. 造发布目录 ═══"
REL=$W/rel; mkdir -p "$REL" "$W/expect"
python3 - "$REL" "$W/expect" "${GK3_TEST_BOOTIMG:-}" <<'PYEOF'
import os, shutil, struct, sys
rel, exp, real = sys.argv[1], sys.argv[2], sys.argv[3]
P = 4096
al = lambda x: (x + P - 1) // P * P
if real:
    shutil.copy(real, os.path.join(rel, "boot.img"))
else:
    # header v2，cmdline 故意超过 511 字节：mkbootimg 把前 511 放 cmdline[512]、
    # 其余放 extra_cmdline[1024] —— 拼回来必须是原样（将来 cmdline 变长时会走到这条路）
    kern = b"MZ" + os.urandom(300000)
    ramd = os.urandom(123457)
    dtb = b"\xd0\x0d\xfe\xed" + os.urandom(20001)
    cmd = ("androidboot.hardware=gaokun3 androidboot.boot_devices=soc@0/1c20000.pcie "
           "init=/init firmware_class.path=/vendor/firmware/ console=tty0 "
           "clk_ignore_unused pd_ignore_unused arm64.nopauth efi=noruntime fbcon=rotate:1 "
           "usbhid.quirks=0x12d1:0x10b8:0x20000000 " + " ".join("gk3.pad%02d=%s" % (i, "x" * 12) for i in range(25)))
    assert len(cmd) > 511
    c = cmd.encode()
    h = bytearray(P)
    h[0:8] = b"ANDROID!"
    struct.pack_into("<IIIIIIIIII", h, 8, len(kern), 0x8000, len(ramd), 0x1000000, 0, 0, 0x100, P, 2, 0)
    h[64:64 + 511] = c[:511]
    h[608:608 + len(c) - 511] = c[511:]
    struct.pack_into("<IQII", h, 1632, 0, 0, 1660, len(dtb))
    with open(os.path.join(rel, "boot.img"), "wb") as f:
        f.write(h); f.write(kern.ljust(al(len(kern)), b"\0"))
        f.write(ramd.ljust(al(len(ramd)), b"\0")); f.write(dtb.ljust(al(len(dtb)), b"\0"))
    for n, d in (("Image", kern), ("ramdisk.img", ramd), ("gaokun3.dtb", dtb)):
        open(os.path.join(exp, n), "wb").write(d)
    open(os.path.join(exp, "cmdline"), "w").write(cmd)
# super 的原始内容：256 MiB，偏移 4096 处是 LP geometry 魔数，几段随机数据，其余是零
raw = bytearray(256 << 20)
raw[4096:4100] = b"gDla"                      # 0x616c4467 小端
for off in (1 << 20, 37 << 20, 200 << 20):
    raw[off:off + (2 << 20)] = os.urandom(2 << 20)
open(os.path.join(exp, "super.raw"), "wb").write(raw)
# systemd-boot 的假件故意【不】叫 systemd-bootaa64.efi：GK3_SDBOOT 这个覆盖开关曾经
# 只在文件恰好叫这个名字时才生效（录 fixture 时才发现），这里把它钉住
for n in ("rescue.squashfs", "initramfs.img", "fake-sdboot.efi", "recovery-ramdisk.img"):
    open(os.path.join(rel if n != "fake-sdboot.efi" else exp, n), "wb").write(b"MZ" + os.urandom(65536))
open(os.path.join(rel, "wpa_supplicant.conf"), "w").write('network={\n\tssid="test"\n\tpsk="12345678"\n}\n')
open(os.path.join(rel, "authorized_keys"), "w").write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG0000000000000000000000000000000000000000000 test@gk3\n")
PYEOF
img2simg "$W/expect/super.raw" "$W/super.img" >/dev/null
zstd -q -19 --long -f "$W/super.img" -o "$REL/super.img.zst"
( cd "$REL" && sha256sum boot.img super.img.zst > install-artifacts.sha256 )
export GK3_SDBOOT=$W/expect/fake-sdboot.efi
if [ -z "${GK3_TEST_BOOTIMG:-}" ]; then
    python3 scripts/live/gk3-bootimg.py "$REL/boot.img" "$W/got" 2>/dev/null
    for n in Image ramdisk.img gaokun3.dtb; do
        [ "$(sha "$W/got/$n")" = "$(sha "$W/expect/$n")" ] || bad "合成 boot.img 解包：$n 不一致"
    done
    [ "$(tr -d '\n' < "$W/got/cmdline.txt")" = "$(cat "$W/expect/cmdline")" ] \
        && ok "合成 boot.img（cmdline $(wc -c < "$W/expect/cmdline") 字节，跨 cmdline/extra_cmdline 两段）解包逐字节一致" \
        || bad "跨段 cmdline 拼回来不一致"
else
    python3 scripts/live/gk3-bootimg.py "$REL/boot.img" "$W/expect" 2>/dev/null
    tr -d '\n' < "$W/expect/cmdline.txt" > "$W/expect/cmdline"
    ok "用真 boot.img：$GK3_TEST_BOOTIMG"
fi
ok "发布目录：boot.img + super.img.zst（$(du -h "$REL/super.img.zst" | cut -f1)，img2simg 编码）+ 校验清单 + 救援件"
CMDLINE=$(cat "$W/expect/cmdline")
RAWSZ=$(stat -c%s "$W/expect/super.raw")

# 装完之后的逐项核对。$1=盘 $2=救援 yes|no $3=ESP 节点（双系统时是别人的 ESP，不叫 esp）
verify_install() {
    local d=$1 resc=$2 esp=${3:-} n p m
    [ -n "$esp" ] || esp=$(gk3__bylabel "$d" esp)
    [ -b "$esp" ] || { bad "找不到 ESP"; return; }
    for n in misc metadata boot_a boot_b super userdata; do
        p=$(gk3__bylabel "$d" "$n"); [ -b "$p" ] || { bad "缺分区 $n"; return; }
    done
    [ "$resc" = yes ] && { p=$(gk3__bylabel "$d" gk3rescue); [ -b "$p" ] || bad "缺分区 gk3rescue"; }
    ok "分区齐全（按 PARTLABEL 解析）"
    [ "$(blkid -o value -s TYPE "$(gk3__bylabel "$d" metadata)")" = ext4 ] \
      && [ "$(blkid -o value -s TYPE "$(gk3__bylabel "$d" userdata)")" = ext4 ] \
      && ok "metadata / userdata 是 ext4" || bad "文件系统类型不对"
    p=$(gk3__bylabel "$d" super)
    [ "$(sha_head "$p" "$RAWSZ")" = "$(sha "$W/expect/super.raw")" ] \
        && ok "super 前 $((RAWSZ >> 20)) MiB 与原始镜像 sha256 一致（经 .zst → gk3-unsparse 流式写入）" \
        || bad "super 内容不对"
    for n in boot_a boot_b; do
        [ "$(sha_head "$(gk3__bylabel "$d" $n)" "$(stat -c%s "$REL/boot.img")")" = "$(sha "$REL/boot.img")" ] \
            || { bad "$n 内容不对"; return; }
    done; ok "boot_a / boot_b == boot.img"
    [ "$(head -c $((GK3_MISC_MIB << 20)) "$(gk3__bylabel "$d" misc)" | tr -d '\0' | wc -c)" = 0 ] \
        && ok "misc 全零" || bad "misc 不是全零"

    m=$W/mnt-esp; mkdir -p "$m"; mount -o ro "$esp" "$m" || { bad "ESP 挂不上"; return; }
    [ "$(sha "$m/EFI/BOOT/BOOTAA64.EFI")" = "$(sha "$GK3_SDBOOT")" ] && ok "EFI/BOOT/BOOTAA64.EFI = systemd-boot" || bad "BOOTAA64.EFI 不对"
    grep -qx 'default \*-android-a.conf' "$m/loader/loader.conf" && ok "loader.conf default = *-android-a.conf" || bad "loader.conf default 不对"
    for s in a b; do
        for n in Image gaokun3.dtb ramdisk.img; do
            [ "$(sha "$m/$MID/android/slot_$s/$n")" = "$(sha "$W/expect/$n")" ] || { bad "slot_$s/$n 不对"; umount "$m"; return; }
        done
        [ "$(sed -n 's/^options *//p' "$m/loader/entries/$MID-android-$s.conf")" = "$CMDLINE androidboot.slot_suffix=_$s" ] \
            || { bad "slot_$s 启动项 options 不是 boot.img 的 cmdline + slot_suffix"; umount "$m"; return; }
    done
    ok "两个槽：内核/dtb/ramdisk 与 boot.img 里的一致；options = boot.img 的 cmdline + slot_suffix"
    [ -f "$m/$MID/android/slot_a/recovery-ramdisk.img" ] && [ ! -e "$m/loader/entries/$MID-recovery-a.conf" ] \
        && ok "recovery ramdisk 铺了、但启动项默认不建" || bad "recovery 的处理不对"
    if [ "$resc" = yes ]; then
        local want; want=$(gk3__rescue_cmdline "$CMDLINE")
        [ "$(sed -n 's/^options *//p' "$m/loader/entries/$MID-rescue.conf")" = "$want" ] \
          && ! grep -q 'androidboot\.' "$m/loader/entries/$MID-rescue.conf" \
          && grep -q 'usbhid.quirks' "$m/loader/entries/$MID-rescue.conf" \
          && [ "$(sha "$m/$MID/rescue/initramfs.img")" = "$(sha "$REL/initramfs.img")" ] \
            && ok "救援启动项：cmdline 从 boot.img 派生（去掉 androidboot.*、保留 usbhid.quirks），initramfs 正确" \
            || bad "救援启动项不对"
    fi
    umount "$m"
    if [ "$resc" = yes ]; then
        m=$W/mnt-resc; mkdir -p "$m"; mount -o ro "$(gk3__bylabel "$d" gk3rescue)" "$m"
        [ "$(sha "$m/gaokun3/rescue.squashfs")" = "$(sha "$REL/rescue.squashfs")" ] \
          && [ "$(stat -c%a "$m/gaokun3/wpa_supplicant.conf")" = 600 ] \
            && ok "救援分区：squashfs 正确、WiFi 配置权限 600" || bad "救援分区内容不对"
        # 公开的 live 镜像不带公钥 —— 救援系统要能远程进去，公钥得跟着装进来
        [ "$(sha "$m/gaokun3/authorized_keys")" = "$(sha "$REL/authorized_keys")" ] && [ "$(stat -c%a "$m/gaokun3/authorized_keys")" = 600 ] \
            && ok "救援分区：ssh 公钥带进来了（600）" || bad "救援分区里没有 ssh 公钥"
        umount "$m"
    fi
}

# ── A. 命令行版，整盘 ───────────────────────────────────────────────────────
echo "═══ A. install-gaokun3.sh 整盘安装 ═══"
DA=$(new_disk a 40G)
sgdisk -o "$DA" >/dev/null                            # 一张空 GPT，"原来的盘"
BEFORE=$(fp "$DA")
echo nope | DISK=$DA GK3_SKIP_PREFLIGHT=1 bash scripts/install-gaokun3.sh "$REL" >"$W/a0.log" 2>&1; rc=$?
[ "$rc" != 0 ] && [ "$(fp "$DA")" = "$BEFORE" ] && grep -q 'gk3rescue' "$W/a0.log" \
    && ok "不输 ERASE：退出码 ${rc}、盘上一个字节没变（且事先打印了含 gk3rescue 的新布局）" \
    || { bad "不输 ERASE 时 rc=$rc 或盘被改了"; tail -5 "$W/a0.log"; }
echo ERASE | DISK=$DA GK3_SKIP_PREFLIGHT=1 bash scripts/install-gaokun3.sh "$REL" >"$W/a1.log" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "输了 ERASE：装完（退出码 0）"; verify_install "$DA" yes
else bad "整盘安装失败 rc=$rc"; tail -20 "$W/a1.log" | sed 's/^/      /'; fi
grep -q '^PROGRESS 100 ' "$W/a1.log" && ok "进度走到 100" || bad "进度没走到 100"
[ "$(grep -c '^PROGRESS [3-6][0-9] 写入 super' "$W/a1.log")" -ge 5 ] \
    && ok "写 super 期间有 $(grep -c '^PROGRESS [3-6][0-9] 写入 super' "$W/a1.log") 行进度（simg2img 那里是几分钟的沉默）" \
    || bad "写 super 期间没有进度"
ls /tmp/gpt-backup-"$(basename "$DA")"-*.bin >/dev/null 2>&1 && ok "动盘前备份了分区表" || bad "没有分区表备份"

# ── B. 双系统 ──────────────────────────────────────────────────────────────
echo "═══ B. 双系统：装进 Windows 盘中间的空闲区 ═══"
DB=$(new_disk b 40G)
TOT=$(blockdev --getsz "$DB"); LAST=$(( TOT - 34 )); WRS=$(( (LAST - 2097152 + 1) / 2048 * 2048 ))
sgdisk -o \
  -n 1:2048:+300M -t 1:ef00 -c 1:"EFI system partition" \
  -n 2:0:+16M     -t 2:0c01 -c 2:"Microsoft reserved partition" \
  -n 3:0:+4G      -t 3:0700 -c 3:"Basic data partition" \
  -n 4:$WRS:$LAST -t 4:2700 -c 4:"Basic data partition" "$DB" >/dev/null 2>&1
partprobe "$DB" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1
mkfs.vfat -F 32 -n SYSTEM "${DB}p1" >/dev/null
head -c 1048576 /dev/urandom > "$W/bootmgfw.efi"; head -c 700000 /dev/urandom > "$W/winfallback.efi"
mmd -i "${DB}p1" ::/EFI ::/EFI/Microsoft ::/EFI/Microsoft/Boot ::/EFI/Boot
mcopy -i "${DB}p1" "$W/bootmgfw.efi" ::/EFI/Microsoft/Boot/bootmgfw.efi
mcopy -i "${DB}p1" "$W/winfallback.efi" ::/EFI/Boot/bootaa64.efi
mkntfs -Q -F -L Windows "${DB}p3" >/dev/null 2>&1
head -c 1048576 /dev/urandom | dd of="${DB}p4" conv=notrunc status=none
declare -A H PU
for n in 2 3 4; do H[$n]=$(sha "${DB}p$n"); done
for n in 1 2 3 4; do PU[$n]=$(sgdisk -i "$n" "$DB" 2>/dev/null | awk '/unique GUID/{print $4}'); done
ESP_UUID=$(blkid -o value -s UUID "${DB}p1")

PROBE=$(gk3_probe 2>/dev/null | awk -v d="$DB" '$2=="path="d || index($0, "disk="d" ") || index($0, "path="d"p")')
printf '%s\n' "$PROBE" | sed 's/^/    /'
printf '%s\n' "$PROBE" | grep -q "name=Basic%20data%20partition " && printf '%s\n' "$PROBE" | grep -q "name=EFI%20system%20partition " \
    && ok "PARTLABEL 里的空格按协议编码（name=Basic%20data%20partition），不会被切成 \"Basic\"" || bad "PARTLABEL 编码不对"
printf '%s\n' "$PROBE" | grep -q "os=winre" && ok "认出 WinRE（os=winre）" || bad "没认出 WinRE"
FREE=$(printf '%s\n' "$PROBE" | grep '^FREE ' | sort -t= -k5 -n | tail -1)
RS=$(gk3__f "$FREE" start); RE=$(gk3__f "$FREE" end)
[ -n "$RS" ] && ok "空闲区 [$RS, $RE]（$(gk3__f "$FREE" size_mib) MiB）" || bad "没探到空闲区"
if [ -n "${GK3_TEST_FIXTURES:-}" ]; then
    mkdir -p "$GK3_TEST_FIXTURES"
    printf '%s\n' "$PROBE" | sed -e "s#$DB#/dev/nvme0n1#g" -e 's#/dev/nvme0n1p\([0-9]\)#/dev/nvme0n1p\1#g' \
        > "$GK3_TEST_FIXTURES/probe-windows.txt"
    ok "fixture → $GK3_TEST_FIXTURES/probe-windows.txt（loop 名换成了 nvme0n1）"
fi

gk3_apply --disk "$DB" --mode alongside --rescue no --release "$REL" \
          --region-start "$RS" --region-end "$RE" --esp "${DB}p1" >"$W/b.log" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "双系统安装完成"
    verify_install "$DB" no "${DB}p1"
else bad "双系统安装失败 rc=$rc"; tail -20 "$W/b.log" | sed 's/^/      /'; fi
same=1; for n in 2 3 4; do [ "$(sha "${DB}p$n")" = "${H[$n]}" ] || { same=0; bad "p$n 的内容变了"; }; done
[ "$same" = 1 ] && ok "MSR / NTFS / WinRE 三个分区逐字节未变"
same=1; for n in 1 2 3 4; do [ "$(sgdisk -i "$n" "$DB" 2>/dev/null | awk '/unique GUID/{print $4}')" = "${PU[$n]}" ] || same=0; done
[ "$same" = 1 ] && ok "四个原有分区的 PARTUUID 都没变（Windows 的 BCD 靠它）" || bad "有 PARTUUID 变了"
[ "$(blkid -o value -s UUID "${DB}p1")" = "$ESP_UUID" ] && ok "ESP 没被重新格式化（卷序列号 $ESP_UUID 未变）" || bad "ESP 被格式化了"
EI=$(gk3_esp_info "${DB}p1")
printf '%s' "$EI" | grep -q 'windows=yes gaokun3=yes' && ok "装完后 gk3_esp_info：$EI" || bad "gk3_esp_info 不对：$EI"
m=$W/mnt-b; mkdir -p "$m"; mount -o ro "${DB}p1" "$m"
[ "$(sha "$m/EFI/Microsoft/Boot/bootmgfw.efi")" = "$(sha "$W/bootmgfw.efi")" ] && ok "Windows 引导（EFI/Microsoft/Boot/bootmgfw.efi）还在、未变" || bad "Windows 引导被动了"
[ "$(sha "$m/EFI/BOOT/BOOTAA64.EFI.before-gaokun3")" = "$(sha "$W/winfallback.efi")" ] \
    && ok "原来的回落引导 bootaa64.efi 已留成 .before-gaokun3" || bad "原来的回落引导没备份"
umount "$m"
# 读盘上【实际】的起止扇区，不读方案 —— 方案对不等于落盘对
inside=0 outside=""
for n in $(sgdisk -p "$DB" | awk '/^ *[0-9]+ /{print $1}'); do
    case "$(sgdisk -i "$n" "$DB" | grep '^Partition name:' | cut -d"'" -f2)" in
        misc|metadata|boot_a|boot_b|super|userdata) ;; *) continue ;;
    esac
    s=$(sgdisk -i "$n" "$DB" | awk '/^First sector:/{print $3}'); e=$(sgdisk -i "$n" "$DB" | awk '/^Last sector:/{print $3}')
    if [ "$s" -ge "$RS" ] && [ "$e" -le "$RE" ]; then inside=$((inside+1)); else outside="$outside p$n[$s,$e]"; fi
done
[ "$inside" = 6 ] && [ -z "$outside" ] && ok "6 个新分区在盘上的起止扇区全部落在空闲区内" || bad "新分区：区内 $inside 个，越界：${outside:-无}"
BEFORE=$(fp "$DB")
OUT=$(gk3_apply --disk "$DB" --mode alongside --rescue no --release "$REL" \
          --region-start "$RS" --region-end "$RE" --esp "${DB}p1" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q 'partlabel-conflict' && [ "$(fp "$DB")" = "$BEFORE" ] \
    && ok "在已装过的盘上再装一次：partlabel-conflict 拒绝，盘没动" || bad "重复安装没被拦住（rc=${rc}）"

# ── C. 反例：都必须在动盘之前拒绝 ───────────────────────────────────────────
echo "═══ C. 反例 ═══"
DC=$(new_disk c 40G); sgdisk -o "$DC" >/dev/null; BEFORE=$(fp "$DC")
try() {   # $1=说明 $2=发布目录 $3=期望的报错片段
    local out rc; out=$(gk3_apply --disk "$DC" --mode wipe --rescue no --release "$2" 2>&1); rc=$?
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$3" && [ "$(fp "$DC")" = "$BEFORE" ]; then
        ok "$1：拒绝且盘没动（$(printf '%s\n' "$out" | grep '^!!' | tail -1 | cut -c4-)）"
    else bad "$1：rc=${rc}，或报错不对，或盘被改了"; printf '%s\n' "$out" | tail -4 | sed 's/^/      /'; fi
}
R1=$W/rel-trunc; mkdir "$R1"; cp "$REL/boot.img" "$R1/"
head -c $(( $(stat -c%s "$REL/super.img.zst") * 2 / 3 )) "$REL/super.img.zst" > "$R1/super.img.zst"
try "截断的 super.img.zst（没有校验清单）" "$R1" "zstd -t"
R2=$W/rel-sha; mkdir "$R2"; cp "$REL"/boot.img "$REL"/super.img.zst "$REL"/install-artifacts.sha256 "$R2/"
printf 'X' | dd of="$R2/boot.img" bs=1 seek=100000 conv=notrunc status=none
try "boot.img 与校验清单不符" "$R2" "sha256"
R3=$W/rel-nosuper; mkdir "$R3"; cp "$REL/boot.img" "$R3/"
try "缺 super" "$R3" "super.img"
R4=$W/rel-badboot; mkdir "$R4"; cp "$REL/super.img.zst" "$R4/"; head -c 5000 "$REL/boot.img" > "$R4/boot.img"
try "boot.img 被截断" "$R4" "boot.img 拆不开"
# 双系统的 ESP 检查也必须在动盘之前：Windows 默认建的 ESP 只有 100 MiB，放不下我们要的
# GK3_ESP_NEED_MIB —— 这在真实世界里是最常见的一种"装不了"，不是边角情况
DE=$(new_disk e 40G)
sgdisk -o -n 1:2048:+100M -t 1:ef00 -c 1:"EFI system partition" \
          -n 2:0:+4G -t 2:0700 -c 2:"Basic data partition" "$DE" >/dev/null 2>&1
partprobe "$DE" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1
mkfs.vfat -F 32 "${DE}p1" >/dev/null 2>&1; mkntfs -Q -F "${DE}p2" >/dev/null 2>&1
FE=$(gk3_probe 2>/dev/null | grep "^FREE disk=$DE " | tail -1)
BEFORE_E=$(fp "$DE")
tryb() {  # $1=说明 $2=--esp $3=期望的报错片段
    local out rc; out=$(gk3_apply --disk "$DE" --mode alongside --rescue no --release "$REL" \
        --region-start "$(gk3__f "$FE" start)" --region-end "$(gk3__f "$FE" end)" --esp "$2" 2>&1); rc=$?
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$3" && [ "$(fp "$DE")" = "$BEFORE_E" ]; then
        ok "$1：拒绝且盘没动（$(printf '%s\n' "$out" | grep '^!!' | tail -1 | cut -c4-)）"
    else bad "$1：rc=${rc}，或报错不对，或盘被改了"; printf '%s\n' "$out" | tail -3 | sed 's/^/      /'; fi
}
EI=$(gk3_esp_info "${DE}p1")
[ "$(gk3__f "$EI" free_mib)" -lt "$(gk3__f "$EI" need_mib)" ] && printf '%s' "$EI" | grep -q 'windows=no' \
    && ok "gk3_esp_info 事先就报出来了：$EI" || bad "gk3_esp_info 不对：$EI"
tryb "Windows 默认的 100 MiB ESP" "${DE}p1" "ESP 空间不够"
tryb "--esp 指向 NTFS 分区" "${DE}p2" "不是 FAT"
tryb "--esp 指向不存在的节点" "${DE}p9" "要 --esp"
OUT=$(GK3_DRYRUN=1 gk3_apply --disk "$DC" --mode wipe --rescue yes --release "$REL" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$OUT" | grep -q '^DRY: sgdisk --zap-all' && [ "$(fp "$DC")" = "$BEFORE" ] \
    && ok "dry-run：列出了 $(printf '%s\n' "$OUT" | grep -c '^DRY:') 条命令，盘一个字节没变" || bad "dry-run 不对（rc=${rc}）"

# ── D. 免 U 盘：安装器就跑在目标盘上 ─────────────────────────────────────────
# 用户 2026-09-25：LiveCD 的初衷之一是【免 U 盘安装】，并且要能装双系统。于是"介质与目标同盘"
# 是正经流程，不是边角：Windows 里缩出空闲区、建一个放 live 的小分区（这里是 p4 GK3LIVE），
# 从它起安装器。规则：双系统放行（只往空闲区建分区）、整盘清空拒绝、介质分区不可缩。
echo "═══ D. 免 U 盘：安装器就跑在目标盘上（介质与目标同盘）═══"
DD=$(new_disk d 40G)
TOT=$(blockdev --getsz "$DD"); LAST=$(( TOT - 34 )); WRS=$(( (LAST - 2097152 + 1) / 2048 * 2048 ))
sgdisk -o \
  -n 1:2048:+300M -t 1:ef00 -c 1:"EFI system partition" \
  -n 2:0:+16M     -t 2:0c01 -c 2:"Microsoft reserved partition" \
  -n 3:0:+4G      -t 3:0700 -c 3:"Basic data partition" \
  -n 4:0:+1G      -t 4:0700 -c 4:"Basic data partition" \
  -n 5:$WRS:$LAST -t 5:2700 -c 5:"Basic data partition" "$DD" >/dev/null 2>&1
partprobe "$DD" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1
mkfs.vfat -F 32 -n SYSTEM "${DD}p1" >/dev/null; mkntfs -Q -F -L Windows "${DD}p3" >/dev/null 2>&1
mkfs.vfat -F 32 -n GK3LIVE "${DD}p4" >/dev/null
mkdir -p /media/gk3 && mount "${DD}p4" /media/gk3 && mkdir -p /media/gk3/gaokun3
head -c 1048576 /dev/urandom > /media/gk3/gaokun3/live.squashfs; LIVE_SHA=$(sha /media/gk3/gaokun3/live.squashfs); sync
PU4=$(sgdisk -i 4 "$DD" 2>/dev/null | awk '/unique GUID/{print $4}')
PROBE=$(gk3_probe 2>/dev/null | awk -v d="$DD" '$2=="path="d || index($0, "disk="d" ") || index($0, "path="d"p")')
printf '%s\n' "$PROBE" | grep -q "^DISK path=$DD .*medium=yes" && printf '%s\n' "$PROBE" | grep -q "^PART path=${DD}p4 .*medium=yes" \
    && ! printf '%s\n' "$PROBE" | grep -q "^PART path=${DD}p3 .*medium=yes" \
    && ok "gk3_probe：整块盘 medium=yes，且只有 p4（安装器所在）标 medium=yes" || bad "medium 标得不对"
SI=$(gk3_shrink_info "${DD}p4" 2>&1)
printf '%s' "$SI" | grep -q 'can=no why=mounted' && ok "介质分区不可缩：$SI" || bad "介质分区居然可缩：$SI"
BEFORE_D=$(fp "$DD")
OUT=$(gk3_shrink "${DD}p4" 600 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(fp "$DD")" = "$BEFORE_D" ] && ok "gk3_shrink 自己也拒绝缩介质分区，盘没动" || bad "gk3_shrink 缩了介质分区（rc=${rc}）"
OUT=$(gk3_apply --disk "$DD" --mode wipe --rescue no --release "$REL" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q '锯掉' && [ "$(fp "$DD")" = "$BEFORE_D" ] \
    && ok "整盘清空介质所在的盘：拒绝且盘没动" || bad "整盘清空没被拦住（rc=${rc}）"
FREE=$(printf '%s\n' "$PROBE" | grep '^FREE ' | sort -t= -k5 -n | tail -1)
RS=$(gk3__f "$FREE" start); RE=$(gk3__f "$FREE" end)
gk3_apply --disk "$DD" --mode alongside --rescue no --release "$REL" \
          --region-start "$RS" --region-end "$RE" --esp "${DD}p1" >"$W/d.log" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "双系统装进同一块盘的空闲区：完成（介质分区一直挂着）"
    verify_install "$DD" no "${DD}p1"
else bad "双系统安装失败 rc=$rc"; tail -20 "$W/d.log" | sed 's/^/      /'; fi
findmnt -rn -S "${DD}p4" -T /media/gk3 >/dev/null && [ "$(sha /media/gk3/gaokun3/live.squashfs)" = "$LIVE_SHA" ] \
    && [ "$(sgdisk -i 4 "$DD" 2>/dev/null | awk '/unique GUID/{print $4}')" = "$PU4" ] \
    && ok "介质分区：还挂着、live.squashfs 内容未变、PARTUUID 未变" || bad "介质分区被动了"
umount /media/gk3

# ── F. 重新安装 ────────────────────────────────────────────────────────────
# 用户 2026-09-25：盘上已经有我们的 Android 时，整盘清空（免 U 盘时会锯掉安装器）和双系统（会建出
# 第二套同名分区）都走不通。重新安装 = 不改分区表、复用现有分区：写新系统，默认格式化 /data。
echo "═══ F. 重新安装：复用 A 节装好的那块盘 ═══"
ESPA=$(gk3__bylabel "$DA" esp); UDA=$(gk3__bylabel "$DA" userdata)
mk=$W/mnt-f; mkdir -p "$mk"
mount "$UDA" "$mk" && echo "用户的数据" > "$mk/marker.txt" && umount "$mk"
# 故意写坏：重装之后必须又对了（证明真的重写了，而不是"本来就对"）
head -c 1048576 /dev/urandom | dd of="$(gk3__bylabel "$DA" boot_a)" conv=notrunc status=none
head -c 1048576 /dev/urandom | dd of="$(gk3__bylabel "$DA" super)" bs=1M seek=0 conv=notrunc status=none
# ESP 只留约 100 MiB 空闲：比新装要求的 150 少 —— 已经装过的机器上就是这种情况（我们的文件占着地方）
mount "$ESPA" "$mk"; FREEA=$(df -m "$mk" | awk 'NR==2{print $4}')
dd if=/dev/zero of="$mk/filler.bin" bs=1M count=$(( FREEA - 100 )) status=none; sync; umount "$mk"
BEFORE_F=$(sgdisk -p "$DA" | grep -v '^Disk identifier')
P=$(gk3_plan --disk "$DA" --mode reinstall --rescue yes --esp "$ESPA" --keep-data yes)
printf '%s\n' "$P" | grep -q '^PLAN op=reuse name=userdata .*action=keep' && printf '%s\n' "$P" | grep -q '^PLAN op=reuse name=super .*action=write' \
    && [ "$(printf '%s\n' "$P" | grep -c '^PLAN op=reuse')" = 7 ] && ! printf '%s\n' "$P" | grep -q '^PLAN op=mkpart' \
    && ok "gk3_plan reinstall：7 个分区全是 reuse（userdata=keep、super=write），没有 mkpart" || { bad "reinstall 方案不对"; printf '%s\n' "$P" | sed 's/^/      /'; }
gk3_apply --disk "$DA" --mode reinstall --rescue yes --release "$REL" --esp "$ESPA" --keep-data yes >"$W/f1.log" 2>&1; rc=$?
if [ "$rc" = 0 ]; then ok "保留数据的重新安装：完成（ESP 只剩约 100 MiB 也放行）"; verify_install "$DA" yes "$ESPA"
else bad "保留数据的重新安装失败 rc=$rc"; tail -15 "$W/f1.log" | sed 's/^/      /'; fi
[ "$(sgdisk -p "$DA" | grep -v '^Disk identifier')" = "$BEFORE_F" ] && ok "分区表逐字节没变（不改分区表）" || bad "分区表变了"
mount -o ro "$UDA" "$mk" && { [ "$(cat "$mk/marker.txt" 2>/dev/null)" = "用户的数据" ] && ok "保留数据：userdata 里的文件还在" || bad "保留数据却丢了文件"; umount "$mk"; }
gk3_apply --disk "$DA" --mode reinstall --rescue yes --release "$REL" --esp "$ESPA" >"$W/f2.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "默认（清除数据）的重新安装：完成" || { bad "清除数据的重新安装失败 rc=$rc"; tail -10 "$W/f2.log" | sed 's/^/      /'; }
mount -o ro "$UDA" "$mk" && { [ ! -e "$mk/marker.txt" ] && ok "默认清除数据：userdata 被格式化了" || bad "说好清除数据，文件还在"; umount "$mk"; }
# 反例：目标分区挂着（安装器要是从它上面跑的，写它就是锯地板）→ 动盘之前拒绝
mount -o ro "$UDA" "$mk"; SB=$(sha_head "$(gk3__bylabel "$DA" boot_a)" 1048576)
OUT=$(gk3_apply --disk "$DA" --mode reinstall --rescue yes --release "$REL" --esp "$ESPA" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q '还挂着' && [ "$(sha_head "$(gk3__bylabel "$DA" boot_a)" 1048576)" = "$SB" ] \
    && ok "目标分区挂着：拒绝，boot_a 没被碰" || bad "挂着的分区没被拦住（rc=${rc}）"
umount "$mk"
OUT=$(gk3_plan --disk "$DC" --mode reinstall --rescue no --esp /dev/null 2>&1)
printf '%s' "$OUT" | grep -q '^PLANERR msg=reinstall-missing names=misc,metadata,boot_a,boot_b,super,userdata' \
    && ok "不是一套完整的安装：PLANERR 列出缺的分区" || bad "缺分区没被报出来：$OUT"
mount "$ESPA" "$mk" && rm -f "$mk/filler.bin" && umount "$mk"
# ★★ 2026-09-26 M4b 真机：live 的 machine-id 是每次开机现生成的，而这个测试一直导出同一个 GK3_MACHINE_ID ——
#   所以没抓到"重新安装在 ESP 上另开一个目录、又写一整套内核"（真机上把 ESP 写满了，slot_b 的 ramdisk
#   截断、启动项是空文件，安装却报告成功）。下面三条是那次的三个面。
OTHER=fedcba9876543210fedcba9876543210
GK3_MACHINE_ID=$OTHER gk3_apply --disk "$DA" --mode reinstall --rescue yes --release "$REL" --esp "$ESPA" >"$W/f3.log" 2>&1; rc=$?
mount -o ro "$ESPA" "$mk"
NA=$(ls "$mk"/loader/entries/*-android-a.conf 2>/dev/null | wc -l); NB=$(ls "$mk"/loader/entries/*-android-b.conf 2>/dev/null | wc -l)
[ "$rc" = 0 ] && [ ! -e "$mk/$OTHER" ] && [ "$NA" = 1 ] && [ "$NB" = 1 ] && [ -s "$mk/loader/entries/$MID-android-b.conf" ] \
    && ok "machine-id 换了（live 每次开机都换）：仍写进 ESP 上现有的目录，每个槽恰好一个启动项" \
    || { bad "machine-id 换了：rc=$rc，新目录 $([ -e "$mk/$OTHER" ] && echo 有 || echo 无)，a=$NA b=$NB"; tail -5 "$W/f3.log" | sed 's/^/      /'; }
umount "$mk"
# 另一个目录下留着我们的启动项（M4b 那次留下的局面）：default 的通配会同时匹配 → 必须停用
mount "$ESPA" "$mk" && cp "$mk/loader/entries/$MID-android-b.conf" "$mk/loader/entries/$OTHER-android-b.conf" && umount "$mk"
gk3_apply --disk "$DA" --mode reinstall --rescue yes --release "$REL" --esp "$ESPA" --keep-data yes >"$W/f4.log" 2>&1; rc=$?
mount -o ro "$ESPA" "$mk"
[ "$rc" = 0 ] && [ ! -e "$mk/loader/entries/$OTHER-android-b.conf" ] && [ -e "$mk/loader/entries/$OTHER-android-b.conf.disabled" ] \
    && [ "$(ls "$mk"/loader/entries/*-android-b.conf | wc -l)" = 1 ] \
    && ok "别的目录下的 *-android-b.conf：改名停用（.disabled），default 的通配只剩一个匹配" || bad "重复的启动项没被停用（rc=$rc）"
umount "$mk"
# ESP 上没有我们的目录（要写一整套新文件）、空闲又少：旧的检查（重新安装只要 16 MiB）会放行，然后写满 ESP。
# 两道新闸各验一次：① 放不下要写的量 ② 放得下，但装完之后 OTA postinstall 的门槛（空闲 + 槽里旧文件 > 56 MiB）过不了
# （这里的测试内核只有 1 MiB 左右，所以①要把 ESP 塞到几乎满）
esp_left() {   # $1=留多少 MiB 空闲
    mount "$ESPA" "$mk" && rm -f "$mk/filler.bin" && rm -rf "$mk/$MID" "$mk"/loader/entries/*-android-* \
        && dd if=/dev/zero of="$mk/filler.bin" bs=1M count=$(( $(df -m "$mk" | awk 'NR==2{print $4}') - $1 )) status=none; sync; umount "$mk"
}
SB=$(sha_head "$(gk3__bylabel "$DA" super)" 1048576)
esp_left 0
OUT=$(GK3_MACHINE_ID=$OTHER gk3_apply --disk "$DA" --mode reinstall --rescue yes --release "$REL" --esp "$ESPA" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q 'ESP 空间不够：要写' && [ "$(sha_head "$(gk3__bylabel "$DA" super)" 1048576)" = "$SB" ] \
    && ok "ESP 放不下一整套新文件：按真要写的量算，动盘之前拒绝（super 没被碰）" \
    || { bad "ESP 不够却没在动盘前拦住（rc=${rc}）"; printf '%s\n' "$OUT" | tail -3 | sed 's/^/      /'; }
esp_left 30
OUT=$(GK3_MACHINE_ID=$OTHER gk3_apply --disk "$DA" --mode reinstall --rescue yes --release "$REL" --esp "$ESPA" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q '以后的系统更新（OTA）会因为 ESP 空间不够失败' && [ "$(sha_head "$(gk3__bylabel "$DA" super)" 1048576)" = "$SB" ] \
    && ok "ESP 放得下但装完只剩约 27 MiB：OTA 的门槛过不了，同样动盘之前拒绝" \
    || { bad "OTA 余量没拦住（rc=${rc}）"; printf '%s\n' "$OUT" | tail -3 | sed 's/^/      /'; }
mount "$ESPA" "$mk" && rm -f "$mk/filler.bin" && umount "$mk"
# ★ 真机的布局（2026-09-25 从设备的 sysfs 读的，按比例缩小）：misc 只有 1007 KiB、从第 34 扇区起
#   （GPT 表之后那段空隙）；没有 gk3rescue；安装器从 p3（ubunturescue）上跑。第一版的方案按 MiB 比，
#   把 misc 判成 0 MiB"太小"，重新安装在真机上整个走不通 —— 离线的测试盘都是我们自己的 4 MiB 布局，没抓到。
DR=$(new_disk r 28G)
sgdisk -o -a 1 -n 4:34:2047 -c 4:misc -t 4:8300 "$DR" >/dev/null 2>&1
sgdisk -a 2048 -n 1:2048:+300M -t 1:ef00 -c 1:esp -n 2:0:+9G -c 2:userdata -n 3:0:+1G -c 3:ubunturescue \
       -n 5:0:+64M -c 5:boot_a -n 6:0:+64M -c 6:boot_b -n 8:0:+12G -c 8:super -n 10:0:+32M -c 10:metadata "$DR" >/dev/null 2>&1
partprobe "$DR" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1
mkfs.vfat -F 32 -n ESP "${DR}p1" >/dev/null; mkfs.ext4 -q -F -L userdata "${DR}p2"; mkfs.ext4 -q -F -L ubunturescue "${DR}p3"
head -c 1031168 /dev/urandom | dd of="${DR}p4" conv=notrunc status=none     # misc 里先放点垃圾：必须被清零
mkdir -p /media/gk3 && mount "${DR}p3" /media/gk3 && mkdir -p /media/gk3/gaokun3
MK=$(( $(blockdev --getsize64 "${DR}p4") / 1024 ))
P=$(gk3_plan --disk "$DR" --mode reinstall --rescue no --esp "${DR}p1")
printf '%s\n' "$P" | grep -q "^PLAN op=reuse name=misc .*size_kib=$MK " && printf '%s\n' "$P" | grep -q '^PLANSUM mode=reinstall' \
    && ok "真机布局（misc ${MK} KiB，从第 34 扇区起）：重新安装的方案成立" || { bad "真机布局的方案不成立"; printf '%s\n' "$P" | sed 's/^/      /'; }
BEFORE_R=$(sgdisk -p "$DR" | grep -v '^Disk identifier')
gk3_apply --disk "$DR" --mode reinstall --rescue no --release "$REL" --esp "${DR}p1" >"$W/r.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "真机布局：重新安装完成（安装器所在的 p3 一直挂着）" || { bad "真机布局的重新安装失败 rc=$rc"; tail -8 "$W/r.log" | sed 's/^/      /'; }
[ "$(head -c $(( MK * 1024 )) "${DR}p4" | tr -d '\0' | wc -c)" = 0 ] && ok "1007 KiB 的 misc 整个清零了（不再按 4 MiB 写爆）" || bad "misc 没清干净"
[ "$(sgdisk -p "$DR" | grep -v '^Disk identifier')" = "$BEFORE_R" ] && findmnt -rn -S "${DR}p3" -T /media/gk3 >/dev/null \
    && ok "分区表没变，p3 还挂着" || bad "真机布局：分区表变了或 p3 被动了"
umount /media/gk3

# ── G. 手动调整磁盘 ────────────────────────────────────────────────────────
# 用户 2026-09-25："能给的都给" —— 删除 / 新建 / 格式化 / 缩小 / 扩大。每个操作都要守住：
# ESP 不动、挂着的不动、越界的不做；删除不抹数据（分区表备份还原回去就在）；扩大保住 PARTUUID 与数据。
echo "═══ G. 手动调整磁盘 ═══"
DG=$(new_disk g 16G)
sgdisk -o -n 1:2048:+300M -t 1:ef00 -c 1:"EFI system partition" -n 2:0:+3G -t 2:0700 -c 2:"Basic data partition" \
       -n 3:0:+2G -t 3:8300 -c 3:linux "$DG" >/dev/null 2>&1
partprobe "$DG" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1
mkfs.vfat -F 32 "${DG}p1" >/dev/null; mkntfs -Q -F -L Data "${DG}p2" >/dev/null 2>&1; mkfs.ext4 -q -F "${DG}p3"
mg=$W/mnt-g; mkdir -p "$mg"
ntfs-3g "${DG}p2" "$mg" && head -c 20971520 /dev/urandom > "$mg/win.bin" && NT_SHA=$(sha "$mg/win.bin") && umount "$mg"
PU2=$(sgdisk -i 2 "$DG" | awk '/unique GUID/{print $4}')
gfail() {   # $1=说明 $2=期望的报错片段 $3…=命令：必须失败、报对原因、分区表一个字节不变
    local what=$1 want=$2; shift 2
    local before out rc; before=$(sgdisk -p "$DG" | grep -v '^Disk identifier')
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$want" && [ "$(sgdisk -p "$DG" | grep -v '^Disk identifier')" = "$before" ]; then
        ok "$what：拒绝且分区表没动"; else bad "$what：rc=$rc，或报错不对，或分区表变了"; printf '%s\n' "$out" | tail -2 | sed 's/^/      /'; fi
}
gfail "删 ESP" "EFI 系统分区" gk3_part_delete "${DG}p1"
gfail "格式化 ESP" "EFI 系统分区" gk3_part_format "${DG}p1" ext4
mount "${DG}p3" "$mg"; gfail "删挂着的分区" "正挂着" gk3_part_delete "${DG}p3"; umount "$mg"
gk3_part_delete "${DG}p3" >"$W/g1.log" 2>&1 && ! [ -b "${DG}p3" ] && [ "$(sgdisk -i 2 "$DG" | awk '/unique GUID/{print $4}')" = "$PU2" ] \
    && grep -q '^RESULT op=delete' "$W/g1.log" && ok "删 p3：分区没了，别的分区 PARTUUID 没变" || { bad "删 p3 不对"; tail -3 "$W/g1.log"; }
ls /tmp/gpt-before-delete-"$(basename "$DG")"-*.bin >/dev/null 2>&1 && ok "删之前备份了分区表" || bad "删之前没备份分区表"
FREEG=$(gk3__probe_parts "$DG" "$(blockdev --getsz "$DG")" | grep '^FREE ' | head -1); FS=$(gk3__f "$FREEG" start)
gfail "新建时压到别的分区" "不在任何一段空闲区里" gk3_part_create --disk "$DG" --start 616448 --size-mib 1024 --fs ext4
OUT=$(gk3_part_create --disk "$DG" --start "$FS" --size-mib 1024 --fs ext4 2>/dev/null); NP=$(printf '%s' "$OUT" | sed -n 's/^RESULT op=create part=\([^ ]*\).*/\1/p')
[ -b "$NP" ] && [ "$(blkid -o value -s TYPE "$NP")" = ext4 ] && [ "$(( $(blockdev --getsize64 "$NP") >> 20 ))" = 1024 ] \
    && [ $(( $(sgdisk -i "$(cat /sys/class/block/$(basename "$NP")/partition)" "$DG" | awk '/^First sector:/{print $3}') % 2048 )) = 0 ] \
    && ok "在空闲区新建 1 GiB ext4：$NP（对齐 1 MiB）" || bad "新建分区不对：$OUT"
gk3_part_format "$NP" vfat >/dev/null 2>&1 && [ "$(blkid -o value -s TYPE "$NP")" = vfat ] \
    && sgdisk -i "$(cat /sys/class/block/$(basename "$NP")/partition)" "$DG" | grep -q 'EBD0A0A2' \
    && ok "格式化成 FAT32：类型也跟着改成 Basic data" || bad "格式化不对"
gk3_part_format "$NP" ext4 >/dev/null 2>&1; mount "$NP" "$mg" && head -c 10485760 /dev/urandom > "$mg/f.bin" && X_SHA=$(sha "$mg/f.bin") && umount "$mg"
PUN=$(sgdisk -i "$(cat /sys/class/block/$(basename "$NP")/partition)" "$DG" | awk '/unique GUID/{print $4}')
gk3_part_resize "$NP" 2048 >"$W/g2.log" 2>&1; rc=$?
mount -o ro "$NP" "$mg"; SZ=$(df -m "$mg" | awk 'NR==2{print $2}'); GOT=$(sha "$mg/f.bin"); umount "$mg"
[ "$rc" = 0 ] && [ "$(( $(blockdev --getsize64 "$NP") >> 20 ))" = 2048 ] && [ "$SZ" -gt 1900 ] && [ "$GOT" = "$X_SHA" ] \
    && [ "$(sgdisk -i "$(cat /sys/class/block/$(basename "$NP")/partition)" "$DG" | awk '/unique GUID/{print $4}')" = "$PUN" ] \
    && ok "扩大 ext4 1 → 2 GiB：分区与文件系统都变大（df ${SZ} MiB），文件没变，PARTUUID 没变" || { bad "扩大 ext4 不对（rc=$rc df=$SZ）"; tail -3 "$W/g2.log"; }
gk3_part_resize "$NP" 1024 >"$W/g3.log" 2>&1 && [ "$(( $(blockdev --getsize64 "$NP") >> 20 ))" = 1024 ] \
    && mount -o ro "$NP" "$mg" && [ "$(sha "$mg/f.bin")" = "$X_SHA" ] && umount "$mg" \
    && ok "缩小 ext4 2 → 1 GiB（走 gk3_shrink）：文件没变" || { bad "缩小不对"; tail -3 "$W/g3.log"; umount "$mg" 2>/dev/null; }
# NTFS 扩大：它后面紧挨着的是新建的那个分区 —— 先删掉，腾出紧挨的空闲
gk3_part_delete "$NP" >/dev/null 2>&1
gk3_part_resize "${DG}p2" 4096 >"$W/g4.log" 2>&1; rc=$?
ntfs-3g -o ro "${DG}p2" "$mg" && GOT=$(sha "$mg/win.bin") && NSZ=$(df -m "$mg" | awk 'NR==2{print $2}') && umount "$mg"
[ "$rc" = 0 ] && [ "$(( $(blockdev --getsize64 "${DG}p2") >> 20 ))" = 4096 ] && [ "$GOT" = "$NT_SHA" ] && [ "$NSZ" -gt 3900 ] \
    && [ "$(sgdisk -i 2 "$DG" | awk '/unique GUID/{print $4}')" = "$PU2" ] \
    && ok "扩大 NTFS 3 → 4 GiB：文件没变，PARTUUID 没变（Windows 的 BCD 靠它）" || { bad "扩大 NTFS 不对（rc=$rc df=$NSZ）"; tail -3 "$W/g4.log"; }
gfail "扩到比后面的空闲还大" "紧挨着的空闲不够" gk3_part_resize "${DG}p2" 30000

# ── E. 网络安装 ────────────────────────────────────────────────────────────
echo "═══ E. 网络安装：下载一整套发布文件，再走同一条写盘路径 ═══"
# 迷你 HTTP 服务器：range 模式支持 "Range: bytes=N-"（R2 支持；Python 自带的 http.server 不支持）
cat > "$W/srv.py" <<'SRVEOF'
import http.server, os, sys
root, port, rng, log = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "range", sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_HEAD(self):   # gk3__ota_variant 用 HEAD 量安装文件的大小（R2 支持）
        p = os.path.join(root, self.path.lstrip("/"))
        if not os.path.isfile(p): self.send_error(404); return
        self.send_response(200); self.send_header("Content-Length", str(os.path.getsize(p))); self.end_headers()
    def do_GET(self):
        p = os.path.join(root, self.path.lstrip("/"))
        if not os.path.isfile(p): self.send_error(404); return
        data = open(p, "rb").read(); start = 0
        r = self.headers.get("Range")
        open(log, "a").write("%s %s\n" % (self.path, r or "-"))
        if rng and r and r.startswith("bytes="):
            start = int(r[6:].split("-")[0])
            if start >= len(data): self.send_response(416); self.end_headers(); return
            self.send_response(206); self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
        else:
            self.send_response(200)
        self.send_header("Content-Length", str(len(data) - start)); self.end_headers()
        try: self.wfile.write(data[start:])
        except (BrokenPipeError, ConnectionResetError): pass   # curl 拿到 200 就放弃续传、主动断开
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
SRVEOF
SRV=$W/srv; mkdir -p "$SRV/good" "$SRV/bad"
cp "$REL/boot.img" "$REL/super.img.zst" "$REL/install-artifacts.sha256" "$SRV/good/"
# 校验清单里再挂一个 OTA zip 的名字（发版的清单就是这样），好验 version= 能取出来
echo "0000000000000000000000000000000000000000000000000000000000000000  crDroidAndroid-16.0-20260916-gaokun3-v12.11.zip" >> "$SRV/good/install-artifacts.sha256"
cp "$SRV/good/"* "$SRV/bad/"; printf 'X' | dd of="$SRV/bad/boot.img" bs=1 seek=4096 conv=notrunc status=none
python3 "$W/srv.py" "$SRV" 18081 range "$W/srv-range.log" & SRVPID1=$!
python3 "$W/srv.py" "$SRV" 18082 norange "$W/srv-norange.log" & SRVPID2=$!
sleep 1
RI=$(gk3_release_info "$SRV/good")
printf '%s' "$RI" | grep -q 'boot=yes super=zst sha256=yes' && printf '%s' "$RI" | grep -q 'version=crDroidAndroid-16.0-20260916-gaokun3-v12.11 ' \
    && ok "gk3_release_info：$(printf '%s' "$RI" | cut -c1-120)" || bad "gk3_release_info 不对：$RI"
DL=$W/dl; OUT=$(gk3_net_release http://127.0.0.1:18081/good/ "$DL" 2>"$W/e.err"); rc=$?
same=1; for f in boot.img super.img.zst; do [ "$(sha "$DL/$f")" = "$(sha "$REL/$f")" ] || same=0; done
[ "$rc" = 0 ] && [ "$same" = 1 ] && printf '%s' "$OUT" | grep -q '^RELEASE .*source=net' \
    && ok "gk3_net_release：两个文件逐字节一致、打出 RELEASE 记录" || { bad "网络下载 rc=$rc"; tail -5 "$W/e.err"; }
P=$(awk '$1=="PROGRESS"{print $2}' "$W/e.err" | tr '\n' ' ')
printf '%s\n' $P | awk 'NR>1 && $1<prev{bad=1} {prev=$1} END{exit bad}' && [ "$(printf '%s\n' $P | tail -1)" = 100 ] \
    && ok "进度单调、走到 100（$(printf '%s\n' $P | wc -l | tr -d ' ') 行）" || bad "进度不对：$P"
# 断点续传：目标目录里先放半截 super，看它是不是真的发了 Range
DL2=$W/dl2; mkdir -p "$DL2"; head -c $(( $(stat -c%s "$REL/super.img.zst") / 3 )) "$REL/super.img.zst" > "$DL2/super.img.zst"
: > "$W/srv-range.log"
gk3_net_release http://127.0.0.1:18081/good/ "$DL2" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sha "$DL2/super.img.zst")" = "$(sha "$REL/super.img.zst")" ] && grep -q '^/good/super.img.zst bytes=[1-9]' "$W/srv-range.log" \
    && ok "断点续传：发了 $(grep '^/good/super.img.zst' "$W/srv-range.log" | cut -d' ' -f2)，续完 sha256 一致" || bad "续传不对（rc=${rc}）：$(tr '\n' ' ' < "$W/srv-range.log")"
# 服务器不支持 Range：半截文件必须被丢掉重下，而不是永远卡在 curl 的 33 上
DL3=$W/dl3; mkdir -p "$DL3"; head -c 12345 "$REL/super.img.zst" > "$DL3/super.img.zst"
gk3_net_release http://127.0.0.1:18082/good/ "$DL3" >/dev/null 2>"$W/e3.err"; rc=$?
[ "$rc" = 0 ] && [ "$(sha "$DL3/super.img.zst")" = "$(sha "$REL/super.img.zst")" ] && grep -q '不支持断点续传' "$W/e3.err" \
    && ok "服务器不支持续传：丢掉半截、从头下完，sha256 一致" || { bad "无 Range 服务器时 rc=$rc"; tail -3 "$W/e3.err"; }
OUT=$(gk3_net_release http://127.0.0.1:18081/bad/ "$W/dl4" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q 'boot.img 的 sha256 不符' \
    && ok "服务器上的 boot.img 被改过：拒绝" || bad "被改过的文件居然通过了（rc=${rc}）"
# 版本列表：variants.txt 还没发布（真机上 404）→ 退回 OTA 清单，推出"最新发布"，base 指向 install/<zip 名>/
ZN=crDroidAndroid-16.0-20260916-gaokun3-v12.11
mkdir -p "$SRV/ota" "$SRV/install/$ZN"; cp "$SRV/good/"* "$SRV/install/$ZN/"
printf '{"response":[{"filename":"%s.zip","download":"http://127.0.0.1:18081/builds/%s.zip","version":"12.11"}]}' "$ZN" "$ZN" > "$SRV/ota/gaokun3.json"
VM=$(GK3_MANIFEST_URL=http://127.0.0.1:18081/installer/variants.txt GK3_OTA_JSON_URL=http://127.0.0.1:18081/ota/gaokun3.json gk3_net_manifest 2>"$W/vm.err"); rc=$?
WANT_MIB=$(( ( $(stat -c%s "$REL/boot.img") + $(stat -c%s "$REL/super.img.zst") ) / 1048576 ))
[ "$rc" = 0 ] && printf '%s' "$VM" | grep -q "^VARIANT id=latest name=crDroid%2012.11 .*base=http://127.0.0.1:18081/install/$ZN/ size_mib=$WANT_MIB latest=yes" \
    && ok "版本清单 404 → 退回 OTA 清单：最新发布 v12.11，base 与大小（${WANT_MIB} MiB）都对" || { bad "OTA 退回不对（rc=$rc）：$VM"; tail -3 "$W/vm.err"; }
BASE=$(printf '%s' "$VM" | sed -n 's/.* base=\([^ ]*\).*/\1/p'); DL5=$W/dl5
gk3_net_release "$BASE" "$DL5" >/dev/null 2>&1 && [ "$(sha "$DL5/super.img.zst")" = "$(sha "$REL/super.img.zst")" ] \
    && ok "推出来的 base 能直接交给 gk3_net_release 下载（sha256 一致）" || bad "推出来的 base 下载不了"
OUT=$(GK3_MANIFEST_URL=http://127.0.0.1:18081/nope GK3_OTA_JSON_URL=http://127.0.0.1:18081/nope2 gk3_net_manifest 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q '都不可用' && ok "两份清单都取不到：报出两个地址" || bad "两份都取不到时报错不对：$OUT"
kill $SRVPID1 $SRVPID2 2>/dev/null
# 下载下来的目录交给 gk3_apply —— 网络安装与 U 盘安装是同一条写盘路径
DN=$(new_disk n 40G); sgdisk -o "$DN" >/dev/null 2>&1
gk3_apply --disk "$DN" --mode wipe --rescue no --release "$DL" >"$W/n.log" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sha_head "$(gk3__bylabel "$DN" super)" "$RAWSZ")" = "$(sha "$W/expect/super.raw")" ] \
    && ok "用下载下来的目录真装一遍：成功，super 逐字节正确" || { bad "网络安装的 apply 失败 rc=$rc"; tail -5 "$W/n.log"; }

echo
echo "═══ 通过 $PASS · 失败 $FAIL ═══"
[ "$FAIL" -eq 0 ]


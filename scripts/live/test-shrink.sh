#!/usr/bin/env bash
# gk3_shrink 的端到端测试：真的建 NTFS / ext4，真的缩，然后验数据。
#
# ★ 这个测试的重点【不是】"缩完大小对不对"，而是三件会毁数据的事：
#     1. 缩完文件还在不在（逐文件 md5）
#     2. PARTUUID 有没有变（变了 Windows 就起不来）
#     3. 空间是不是真的释放出来了（不然缩了也白缩）
#
# 要 root（loop + mount）。在构建机上跑，不需要目标硬件。
set -u
cd "$(dirname "$0")/../.."
. scripts/live/installer-lib.sh

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ "$(id -u)" = 0 ] || { echo "要 root"; exit 2; }
for t in sgdisk mkfs.ntfs ntfsresize mkfs.ext4 resize2fs losetup blockdev; do
    command -v "$t" >/dev/null || { echo "缺 $t"; exit 2; }
done

IMG=/tmp/shrink-test.img
rm -f "$IMG"; truncate -s 20G "$IMG"
LOOP=$(losetup -fP --show "$IMG")
trap 'umount /tmp/sm 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; rm -f "$IMG"' EXIT
echo "假盘 $LOOP"

sgdisk --zap-all "$LOOP" >/dev/null 2>&1
sgdisk -n 1:2048:+10G -t 1:0700 -c 1:Windows "$LOOP" >/dev/null 2>&1
sgdisk -n 2:0:+5G     -t 2:8300 -c 2:Data    "$LOOP" >/dev/null 2>&1
partprobe "$LOOP" 2>/dev/null; sleep 1

P1=${LOOP}p1; P2=${LOOP}p2
mkfs.ntfs -f -L WINTEST "$P1" >/dev/null 2>&1 || { echo "mkfs.ntfs 失败"; exit 1; }
mkfs.ext4 -q -F -L DATATEST "$P2" >/dev/null 2>&1 || { echo "mkfs.ext4 失败"; exit 1; }

# 写进去一些可校验的东西
mkdir -p /tmp/sm
seed_files() {
    local mnt=$1 i
    for i in 1 2 3 4 5; do
        head -c $((i * 7 * 1024 * 1024)) /dev/urandom > "$mnt/file$i.bin"
    done
    (cd "$mnt" && md5sum file*.bin > MD5SUMS)
    sync
}
mount "$P1" /tmp/sm && seed_files /tmp/sm && umount /tmp/sm
mount "$P2" /tmp/sm && seed_files /tmp/sm && umount /tmp/sm
echo "两个分区都写好了测试数据"

check_files() {
    local part=$1 name=$2
    mount "$part" /tmp/sm 2>/dev/null || { bad "$name 缩完挂不上了"; return 1; }
    if (cd /tmp/sm && md5sum -c MD5SUMS >/dev/null 2>&1); then
        ok "$name 缩完文件逐个 md5 一致（$(ls /tmp/sm/file*.bin | wc -l) 个）"
    else
        bad "$name 缩完文件校验不过 —— 数据坏了"
    fi
    umount /tmp/sm
}

uuid_of() { sgdisk -i "$1" "$LOOP" 2>/dev/null | grep '^Partition unique GUID:' | awk '{print $4}'; }

echo "═══ 1. 问最小能缩到多少 ═══"
gk3_shrink_info "$P1" | sed 's/^/  /'
gk3_shrink_info "$P2" | sed 's/^/  /'

echo "═══ 2. 缩 NTFS：10 GiB -> 6 GiB ═══"
U1=$(uuid_of 1)
if gk3_shrink "$P1" 6144 >/dev/null 2>&1; then
    NEW=$(( $(blockdev --getsize64 "$P1") / 1048576 ))
    [ "$NEW" -le 6200 ] && ok "分区变成 ${NEW} MiB" || bad "分区还是 ${NEW} MiB"
    [ "$(uuid_of 1)" = "$U1" ] && ok "PARTUUID 未变" || bad "PARTUUID 变了！"
    check_files "$P1" NTFS
else
    bad "缩 NTFS 失败"
fi

echo "═══ 3. 缩 ext4：5 GiB -> 3 GiB ═══"
U2=$(uuid_of 2)
sgdisk -A 2:set:0 -A 2:set:63 "$LOOP" >/dev/null 2>&1      # 恢复分区那种属性：平台必需 + 不分配盘符
A2=$(sgdisk -i 2 "$LOOP" 2>/dev/null | awk '/^Attribute flags:/{print $3}')
if gk3_shrink "$P2" 3072 >/dev/null 2>&1; then
    NEW=$(( $(blockdev --getsize64 "$P2") / 1048576 ))
    [ "$NEW" -le 3100 ] && ok "分区变成 ${NEW} MiB" || bad "分区还是 ${NEW} MiB"
    [ "$(uuid_of 2)" = "$U2" ] && ok "PARTUUID 未变" || bad "PARTUUID 变了！"
    [ "$(sgdisk -i 2 "$LOOP" 2>/dev/null | awk '/^Attribute flags:/{print $3}')" = "$A2" ] && [ "$A2" = 8000000000000001 ] \
        && ok "GPT 属性位原样带过去了（${A2}）" || bad "属性位丢了（原来 ${A2}）"
    check_files "$P2" ext4
else
    bad "缩 ext4 失败"
fi

echo "═══ 4. 空间真的释放出来了吗 ═══"
FREE=$(GK3_ALLOW_LOOP=1 gk3_probe 2>/dev/null | grep "^FREE disk=$LOOP" | awk '{for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="size_mib")s+=a[2]}}END{print s+0}')
[ "${FREE:-0}" -ge 5000 ] && ok "空闲空间 ${FREE} MiB（期望 ≥5000）" || bad "只释放出 ${FREE:-0} MiB"

echo "═══ 5. 拒绝缩到太小 ═══"
gk3_shrink "$P2" 100 >/dev/null 2>&1 && bad "缩到 100 MiB 居然通过了" || ok "缩到 100 MiB 被拒"

# ★ 2026-09-27 审查查出、按 ntfs-3g 源码核实：原先 --info / --no-action 带 --force（一个就放过脏卷），而休眠
#   ntfsresize 根本看不出来（NTFS_MNT_FORENSIC）。Windows 的快速启动默认开着 —— 这是双系统用户的常态，不是边角。
echo "═══ 6. 脏卷与休眠的 Windows：拒绝，盘不动 ═══"
SZ1=$(blockdev --getsize64 "$P1")
ntfsfix "$P1" >/dev/null 2>&1      # ntfsfix 会置上 dirty 位，让 Windows 下次开机跑 chkdsk（ntfsfix.c:299-318）
I=$(gk3_shrink_info "$P1" 2>/dev/null)
printf '%s' "$I" | grep -q 'can=no why=ntfs-dirty' && ok "脏卷：探测报 why=ntfs-dirty" || bad "脏卷没认出来：$I"
gk3_shrink "$P1" 5500 >/dev/null 2>&1 && bad "脏卷居然缩了" || ok "脏卷：gk3_shrink 拒绝"
ntfsfix -d "$P1" >/dev/null 2>&1
mount "$P1" /tmp/sm && { printf 'HIBR' > /tmp/sm/hiberfil.sys; head -c 65532 /dev/zero >> /tmp/sm/hiberfil.sys; sync; umount /tmp/sm; }
I=$(gk3_shrink_info "$P1" 2>/dev/null)
printf '%s' "$I" | grep -q 'can=no why=ntfs-hibernated' && ok "休眠（hiberfil.sys 开头 HIBR）：探测报 why=ntfs-hibernated" || bad "休眠没认出来：$I"
OUT=$(gk3_shrink "$P1" 5500 2>&1) && bad "休眠的卷居然缩了" || ok "休眠：gk3_shrink 拒绝"
OUT=$(gk3__ntfs_trial_mount "$P1" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$OUT" | grep -q '休眠' && ok "终审（ntfs-3g 读写挂一次）也认出休眠" || bad "ntfs-3g 终审没认出休眠（rc=${rc}）：$OUT"
[ "$(blockdev --getsize64 "$P1")" = "$SZ1" ] && ok "分区大小没变" || bad "分区大小变了"
check_files "$P1" "NTFS（被拒之后）"
# ⚠️ 休眠的卷普通 mount 会退回只读，rm 静默失败 —— 得用 remove_hiberfile（真实世界里这等于丢掉 Windows 的休眠会话）
mount -t ntfs-3g -o remove_hiberfile "$P1" /tmp/sm && { [ ! -e /tmp/sm/hiberfil.sys ] || rm -f /tmp/sm/hiberfil.sys; umount /tmp/sm; }
gk3__ntfs_trial_mount "$P1" 2>/dev/null && ok "干净的卷：终审放行" || bad "干净的卷被终审拦住了"

# ★ 2026-09-27：Windows 11 的"设备加密"常常默认开着，而 Android 的空间改到安装器里缩（用户：安装安装器只划自己的空间）——
#   加密的 D: 是那条路上最常见的"缩不了"，原因必须报对（原先报 fs-not-shrinkable，界面说"文件系统不支持"）
echo "═══ 7. BitLocker 卷：报 why=bitlocker ═══"
BIMG=/tmp/bitlocker-test.img; rm -f "$BIMG"; truncate -s 64M "$BIMG"; BL=$(losetup -fP --show "$BIMG")
python3 - "$BL" <<'PYEOF'
# 造一个 libblkid 认得出的 BitLocker（Win7+）卷头：util-linux 2.41 libblkid/src/superblocks/bitlocker.c 的判据 ——
# 偏移 0 是 "\xeb\x58\x90-FVE-FS-"，偏移 176 是 FVE 元数据的位置（非 0、64 对齐），那里再有一个 "-FVE-FS-" 块头
import sys, struct
META = 0x10000
with open(sys.argv[1], 'r+b') as f:
    b = bytearray(512)
    b[0:11] = b'\xeb\x58\x90-FVE-FS-'
    struct.pack_into('<H', b, 11, 512); b[13] = 8
    struct.pack_into('<Q', b, 176, META)
    b[510:512] = b'\x55\xaa'
    f.write(b)
    m = bytearray(64 + 48)
    m[0:8] = b'-FVE-FS-'; struct.pack_into('<H', m, 10, 2)
    struct.pack_into('<IIII', m, 64, 48, 1, 48, 48)
    f.seek(META); f.write(m)
PYEOF
[ "$(blkid -p -o value -s TYPE "$BL")" = BitLocker ] && ok "造的卷头 blkid 认作 BitLocker" || bad "blkid 没认出造的 BitLocker 卷头"
gk3_shrink_info "$BL" 2>/dev/null | grep -q 'fs=BitLocker .*can=no why=bitlocker' && ok "gk3_shrink_info：can=no why=bitlocker" || bad "BitLocker 卷的原因不对：$(gk3_shrink_info "$BL" 2>&1)"
losetup -d "$BL"; rm -f "$BIMG"

echo
echo "═══ 通过 $PASS · 失败 $FAIL ═══"
[ "$FAIL" -eq 0 ]

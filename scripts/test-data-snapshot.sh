#!/usr/bin/env bash
# 在特权 Debian 容器里验证 data-snapshot-live.sh 的远端部分（任何能跑 docker --privileged 的机器）：
#   造一块 GPT 盘（三个分区的 PARTUUID 与真机相同）→ backup → 模拟 A17 改 /data、misc、metadata → restore
#   → 与原状逐项比对（SELinux 标签 / 属主 / 权限 / 硬链接 / 符号链接 / 稀疏文件），media 与 ota_package 不受影响。
#   bash scripts/test-data-snapshot.sh
# ⚠️ colima 只共享家目录：工作目录放在本仓 out/ 下。容器退出前 losetup -D —— 残留的 loop 会让 PARTUUID 重复，
#    脚本会（正确地）拒绝工作。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
W="$REPO/out/snaptest"; mkdir -p "$W"
sed -n '/^REMOTE$/q;p' "$REPO/scripts/data-snapshot-live.sh" | sed -n "/<<'REMOTE'/,\$p" | tail -n +2 > "$W/remote.sh"
sed -n '/^#--- 容器内 ---$/,$p' "$0" | tail -n +2 > "$W/test.sh"
docker run --rm --privileged -v "$W":/t debian:trixie bash -c 'bash /t/test.sh; rc=$?; losetup -D; exit $rc'
exit $?
#--- 容器内 ---
set -euo pipefail
apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tar zstd python3 e2fsprogs fdisk util-linux >/dev/null
IMG=/tmp/disk.img; truncate -s 700M $IMG
sfdisk -q $IMG <<P
label: gpt
size=600MiB, name=userdata, uuid=4ba36282-f11a-4b1e-b3a4-37940c2319b4
size=2014, name=misc, uuid=53912ab2-33ac-49d2-a099-94fed8664a26
size=32MiB, name=metadata, uuid=2660e57f-f5f6-4ece-b818-2f25b075394c
P
L=$(losetup -fP --show $IMG); b=$(basename $L)
for p in /sys/class/block/${b}p*; do n=$(basename $p); [ -b /dev/$n ] || mknod /dev/$n b $(cut -d: -f1 $p/dev) $(cut -d: -f2 $p/dev); done
mkfs.ext4 -q -L userdata ${L}p1; mkfs.ext4 -q -L metadata ${L}p3
head -c $((2014*512)) /dev/urandom > /tmp/misc.orig; dd if=/tmp/misc.orig of=${L}p2 bs=512 status=none
M=/tmp/u; mkdir -p $M; mount ${L}p1 $M
mkdir -p $M/{app,data,media/0,system,misc/wifi,user_de/0,dalvik-cache,ota_package,local/tmp,data/com.game/files}
echo pkgs > $M/system/packages.xml; echo game > $M/data/com.game/files/save.dat; echo big > $M/media/0/photo.jpg
echo ota > $M/ota_package/payload.bin; echo "with space" > "$M/local/tmp/a b.txt"
truncate -s 50M $M/data/com.game/files/sparse.bin; echo tail >> $M/data/com.game/files/sparse.bin
ln -s /data/app $M/local/link; ln $M/system/packages.xml $M/system/hard.xml
setfattr() { python3 -c 'import os,sys; os.setxattr(sys.argv[1], sys.argv[2], sys.argv[3].encode()+b"\0", follow_symlinks=False)' "$@"; }
setfattr $M/system security.selinux u:object_r:system_data_file:s0; setfattr $M/system security.selinux u:object_r:system_data_file:s0
setfattr $M/system/packages.xml security.selinux u:object_r:system_data_file:s0
setfattr $M/data/com.game security.selinux u:object_r:app_data_file:s0:c512,c768
setfattr $M/data/com.game/files/save.dat security.selinux u:object_r:app_data_file:s0:c512,c768
setfattr $M/local/link security.selinux u:object_r:shell_data_file:s0
chown -R 10234:10234 $M/data/com.game; chmod 0700 $M/data/com.game; chown 1000:1000 $M/system/packages.xml
MM=/tmp/m; mkdir -p $MM; mount ${L}p3 $MM; mkdir -p $MM/ota; echo state > $MM/ota/x; umount $MM
manifest() { python3 - "$1" <<'PY'
import os,sys,hashlib
root=sys.argv[1]
for d,ds,fs in os.walk(root):
    rel=os.path.relpath(d,root)
    if rel.split(os.sep)[0] in ('media','gk3-snap','ota_package','lost+found'): ds[:]=[]; continue
    for n in sorted(ds+fs):
        if d==root and n in ('gk3-snap','lost+found'): continue
        p=os.path.join(d,n); st=os.lstat(p)
        try: x=os.getxattr(p,'security.selinux',follow_symlinks=False)
        except OSError: x=b''
        h=''
        if os.path.isfile(p) and not os.path.islink(p): h=hashlib.sha256(open(p,'rb').read()).hexdigest()[:16]
        if os.path.islink(p): h='->'+os.readlink(p)
        print(os.path.relpath(p,root), oct(st.st_mode), st.st_uid, st.st_gid, st.st_nlink, st.st_size, h, x)
PY
}
manifest $M > /tmp/before.txt; umount $M
export GK3_SNAP_MARGIN_KIB=1024
echo "=== backup"; bash /t/remote.sh backup a16
echo "=== status"; bash /t/remote.sh status
SN=$(mount ${L}p1 $M && ls $M/gk3-snap | head -1)
# 模拟 A17 动 /data：改、删、加，misc / metadata 也写
echo upgraded > $M/system/packages.xml; rm -rf $M/data/com.game; mkdir -p $M/data/com.new; echo a17 > $M/a17-only
echo photo2 > $M/media/0/new.jpg; umount $M
dd if=/dev/zero of=${L}p2 bs=512 count=10 conv=notrunc status=none
mount ${L}p3 $MM; echo changed > $MM/ota/x; umount $MM
echo "=== restore $SN"; bash /t/remote.sh restore $SN
mount ${L}p1 $M; manifest $M > /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt && echo "✓ userdata 逐项一致（$(wc -l < /tmp/before.txt) 项，含 SELinux 标签 / 属主 / 权限 / 硬链接 / 符号链接 / 稀疏文件）"
[ -f $M/media/0/new.jpg ] && [ -f $M/media/0/photo.jpg ] && echo "✓ media 未被动过（A17 期间新增的文件还在）"
[ ! -e $M/a17-only ] && echo "✓ A17 新增的根目录文件已清掉"
cmp ${L}p2 /tmp/misc.orig && echo "✓ misc 逐字节一致"
mount ${L}p3 $MM; [ "$(cat $MM/ota/x)" = state ] && echo "✓ metadata 已回滚"
du -k --apparent-size $M/data/com.game/files/sparse.bin; du -k $M/data/com.game/files/sparse.bin

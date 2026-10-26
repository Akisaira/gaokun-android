#!/usr/bin/env bash
# ============================================================================
# data-snapshot-android.sh — 在跑着的 Android 里给 /data 做快照（不重启）。恢复走 live：
#   bash scripts/data-snapshot-live.sh <live IP> restore <快照名> --yes
#
#   bash scripts/data-snapshot-android.sh backup [标签]      # 默认标签 a16；会 stop / start 一次 framework
#   bash scripts/data-snapshot-android.sh selftest           # /data/local/tmp 下造测试树打包、容器里解包逐项比对；不停 framework
#
# 工具：Debian arm64 的 GNU tar 1.35 + zstd 1.5.7，连同 glibc 与依赖库一起推到 /data/local/tmp/gk3-gnutar/，
#   用 glibc 自己的 ld-linux-aarch64.so.1 --library-path 跑（Android 没有 glibc）。包在本机 out/gnutar-android/，
#   没有就用 docker 从 debian:trixie 现取（见 bundle()）。
#
# ★ 为什么不用设备自带的 toybox tar（2026-10-26 实测，别再走回头路）：
#   · toybox 0.8.12 的 `tar --selinux` 有内存越界：整份 /data 打两次都在中途 Segmentation fault（42 GB / 60 GB 处，位置不固定）；
#     按目录拆开打，48 个顶层条目里 11 次段错误，misc / vendor 上还把标签的一截（"ata_file:s0"）当成文件名去打开 ——
#     没崩的那些归档里文件名 / 标签也不可信。
#   · 它的 --sparse 也不生效（同一个空洞文件加不加归档一样大）。
#   · 设备自带的 zstd 编译时没开多线程：不加 --single-thread 连 -T1 都报 "error 11 : Unsupported parameter"。
#   GNU tar 用 --xattrs 原样存全部 xattr（security.selinux 及 App 目录上的 user.inode_cache 等），格式与
#   data-snapshot-live.sh 自己 backup 的一致，那边的 restore 在容器里整轮验证过。
#
# ★ /data 下的两个挂载点（rc2e 上 /proc/self/mountinfo）：
#   · /data/user/0 是 /data/data 的 bind mount（同 dev:ino）—— 同一个文件系统，--one-file-system 拦不住；
#     不排除就把 App 数据打两遍（约 16 GB），恢复时还会两份互相覆盖 ⇒ --exclude='./user/0/*'，只留空目录。
#   · /data/local/tmp/efivars 挂着 efivarfs（boot-oneshot.sh 挂的）—— 别的文件系统，--one-file-system 跳过内容。
#
# 一致性：打包前 `stop`（停 zygote ⇒ system_server 与全部 App 退出，数据库不再被写），打完 `start`；USB adb 不受影响。
# 没保存的：socket（运行时创建；GNU tar 报 "socket ignored"）。/data 是不加密 ext4、fstab 没开 quota ⇒ 没有密钥与 project id。
# 范围与 data-snapshot-live.sh 一致：userdata 除 media / ota_package / gk3-snap / lost+found 外全部；metadata 整个 tar；
#   misc 原样 dd。放在 /data/gk3-snap/<名字>/（root 0700）。
# ============================================================================
set -euo pipefail
SER=${SER:-gaokun3}
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$REPO/out/gnutar-android"
D=/data/local/tmp/gk3-gnutar
S() { adb -s "$SER" shell "$@" | tr -d '\r'; }
die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }
CMD="${1:?用法见文件头}"; TAG="${2:-a16}"

bundle() {
    if [ ! -x "$BUNDLE/tar" ]; then
        echo "── 现取 GNU tar / zstd（debian:trixie arm64）"
        mkdir -p "$BUNDLE"
        docker run --rm -v "$BUNDLE":/o debian:trixie bash -c '
apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tar zstd >/dev/null 2>&1
mkdir -p /o/lib; cp /usr/bin/tar /usr/bin/zstd /o/
for b in /usr/bin/tar /usr/bin/zstd; do ldd $b; done | awk "/=>/ {print \$3} /ld-linux/ {print \$1}" | sort -u | while read l; do cp -L $l /o/lib/; done' \
            || die "取不到 GNU tar 包（要 docker，且 arm64 主机或 binfmt）"
    fi
    adb -s "$SER" shell "rm -rf $D" >/dev/null
    adb -s "$SER" push "$BUNDLE" "$D" >/dev/null || die "推不上 $D"
    S "chmod 755 $D/tar $D/zstd $D/lib/ld-linux-aarch64.so.1"
    S "$D/lib/ld-linux-aarch64.so.1 --library-path $D/lib $D/tar --version | head -1" | grep -q 'GNU tar' || die "GNU tar 在设备上跑不起来"
}

# 设备端公用片段
REMOTE_FN='
D=/data/local/tmp/gk3-gnutar
R() { $D/lib/ld-linux-aarch64.so.1 --library-path $D/lib "$@"; }
gtar() { R $D/tar "$@"; }
gzst() { R $D/zstd "$@"; }
# $1=根目录 $2=输出 其余=额外 tar 参数；只容忍 socket 警告
tarit() {
    root=$1; out=$2; shift 2
    ( cd "$root" && gtar --xattrs --xattrs-include="*" --acls --numeric-owner --one-file-system "$@" -cpf - . 2>"$out.stderr" ) \
        | gzst -T0 -3 -q -o "$out" || true
    bad=$(grep -v -e "socket ignored" "$out.stderr" || true)
    [ -z "$bad" ] || { echo "✗ tar 报错：$bad"; exit 1; }
    echo "  跳过的 socket：$(grep -c "socket ignored" "$out.stderr" || true) 个"
    rm -f "$out.stderr"
    gzst -tq "$out" || { echo "✗ zstd -t 不过：$out"; exit 1; }
}
'
UD_EXCL="--exclude=./media --exclude=./ota_package --exclude=./gk3-snap --exclude=./lost+found --exclude=./user/0/*"

[ "$(S id -u)" = 0 ] || die "adb shell 不是 root"

case "$CMD" in
selftest)
    bundle
    S "set -e; $REMOTE_FN
T=/data/local/tmp/gk3-snapselftest; rm -rf \$T; mkdir -p \$T/src/app/files \$T/src/sys \$T/src/user/0 \$T/src/data/x
echo hello > \$T/src/sys/a.xml; ln \$T/src/sys/a.xml \$T/src/sys/a-hard.xml; ln -s ../sys/a.xml \$T/src/app/link
echo inuser > \$T/src/user/0/should-be-excluded
dd if=/dev/zero of=\$T/src/app/files/sparse.bin bs=1 count=0 seek=50M 2>/dev/null; echo tail >> \$T/src/app/files/sparse.bin
chown -R 10234:10234 \$T/src/app; chmod 2771 \$T/src/app; chmod 0600 \$T/src/sys/a.xml
chcon u:object_r:app_data_file:s0:c512,c768 \$T/src/app \$T/src/app/files \$T/src/app/files/sparse.bin
chcon -h u:object_r:system_data_file:s0 \$T/src/app/link
setfattr -n user.inode_cache -v 42 \$T/src/app
tarit \$T/src \$T/out.tar.zst $UD_EXCL
cd \$T/src && find . ! -path './user/0/*' | sort | while read p; do printf '%s %s %s\n' \"\$(stat -c '%n %a %u %g %h %s' \"\$p\")\" \"\$(ls -Zd \"\$p\" | cut -d' ' -f1)\" \"\$( [ -f \"\$p\" ] && [ ! -L \"\$p\" ] && sha256sum \"\$p\" | cut -c1-16)\"; done > \$T/manifest.txt
ls -l \$T/out.tar.zst"
    W="$REPO/out/snaptest"; mkdir -p "$W"
    adb -s "$SER" pull /data/local/tmp/gk3-snapselftest/out.tar.zst "$W/selftest.tar.zst" >/dev/null
    adb -s "$SER" pull /data/local/tmp/gk3-snapselftest/manifest.txt "$W/selftest-manifest.txt" >/dev/null
    S 'rm -rf /data/local/tmp/gk3-snapselftest'
    docker run --rm --privileged -v "$W":/t debian:trixie bash -c '
apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tar zstd e2fsprogs attr >/dev/null 2>&1
truncate -s 200M /tmp/i; mkfs.ext4 -q -b 4096 /tmp/i; mkdir /tmp/m; mount -o loop /tmp/i /tmp/m
cd /tmp/m && zstd -dcq /t/selftest.tar.zst | tar --selinux --xattrs --xattrs-include="*" --acls --numeric-owner -xpf - || exit 1
find . -mindepth 1 -path ./lost+found -prune -o -print | sort | while read p; do
  lbl=$(getfattr -h --only-values -n security.selinux "$p" 2>/dev/null | tr -d "\0")
  h=$( [ -f "$p" ] && [ ! -L "$p" ] && sha256sum "$p" | cut -c1-16)
  printf "%s %s %s\n" "$(stat -c "%n %a %u %g %h %s" "$p")" "$lbl" "$h"; done > /tmp/after.txt
grep -v "^\. " /t/selftest-manifest.txt > /tmp/before.txt
diff /tmp/before.txt /tmp/after.txt && echo "✓ 设备上 GNU tar 打包 → 容器解包：$(wc -l < /tmp/after.txt) 项逐项一致（权限含 setgid / 属主 / 硬链接数 / 大小 / 标签含 MLS 类别 / 内容）"
[ -d user/0 ] && [ -z "$(ls -A user/0)" ] && echo "✓ user/0 只留了空目录（bind mount 的内容没进归档）"
[ "$(getfattr --only-values -n user.inode_cache app 2>/dev/null)" = 42 ] && echo "✓ user.* xattr 也保下来了"
echo "稀疏：$(du -k app/files/sparse.bin | cut -f1) KiB 实占（逻辑 50 MiB）"
cd /; umount /tmp/m; losetup -D' ;;

backup)
    bundle
    NAME="$TAG-$(date -u +%Y%m%d-%H%M%S)"
    OUT=/data/gk3-snap/$NAME
    need=$(S 'cd /data && du -sk $(ls -A | grep -v -x -e media -e ota_package -e gk3-snap -e lost+found -e user) 2>/dev/null | awk "{s+=\$1} END {print s}"')
    avail=$(S 'df -k /data | tail -1' | awk '{print $4}')
    [ "$avail" -gt $((need + 10*1024*1024)) ] || die "空间不够：源约 $((need/1024)) MiB + 10 GiB 余量，只剩 $((avail/1024)) MiB"
    echo "── 源约 $((need/1024/1024)) GiB（不含 user/0 这份 bind mount），剩 $((avail/1024/1024)) GiB"
    echo "── stop framework"
    S 'stop'
    for i in $(seq 1 30); do S 'pidof system_server >/dev/null' || break; sleep 1; done
    S 'pidof system_server >/dev/null' && { S start; die "system_server 30 秒没退，已 start 回去"; }
    ok "system_server / zygote 已停"
    restart() { echo "── start framework"; S start >/dev/null 2>&1 || true; }
    trap restart EXIT
    t0=$(date +%s)
    S "set -e; $REMOTE_FN
install -d -m 700 $OUT
echo '── userdata'
tarit /data $OUT/userdata.tar.zst $UD_EXCL
cd /data
n_src=\$(find . -xdev \\( -path ./media -o -path ./ota_package -o -path ./gk3-snap -o -path ./lost+found -o -path './user/0/*' \\) -prune -o ! -type s -print | wc -l)
gzst -dcq $OUT/userdata.tar.zst | gtar -tf - > $OUT/list.txt
n_tar=\$(wc -l < $OUT/list.txt)
[ \"\$n_src\" = \"\$n_tar\" ] || { echo \"✗ 条目数对不上：源 \$n_src（不含 socket）vs 归档 \$n_tar\"; exit 1; }
echo \"✓ 条目数一致：\$n_tar\"
n_u0=\$(grep -c '^\\./user/0/.' $OUT/list.txt || true)
[ \"\$n_u0\" = 0 ] || { echo \"✗ 归档里有 \$n_u0 条 ./user/0/ 下的东西（bind mount 没排除掉）\"; exit 1; }
n_lbl=\$(gzst -dcq $OUT/userdata.tar.zst | grep -a -c 'SCHILY.xattr.security.selinux=' || true)
[ \"\$n_lbl\" -ge \"\$n_tar\" ] || { echo \"✗ 带 SELinux 标签的条目 \$n_lbl < 总条目 \$n_tar\"; exit 1; }
echo \"✓ 每一条都带 SELinux 标签（\$n_lbl 个标签头）\"
echo '── metadata'; tarit /metadata $OUT/metadata.tar.zst --exclude=./lost+found
dd if=/dev/block/by-name/misc of=$OUT/misc.img bs=512 2>/dev/null
cd $OUT && sha256sum userdata.tar.zst metadata.tar.zst misc.img > SHA256SUMS
{ echo created_utc=\$(date -u +%FT%TZ); echo format=gnu-tar-xattrs; echo entries=\$n_tar
  echo build=\$(getprop ro.build.date.utc); echo slot=\$(getprop ro.boot.slot_suffix)
  echo packages_xml_sha256=\$(sha256sum /data/system/packages.xml | cut -d' ' -f1); } > INFO
chmod 600 *; ls -l"
    echo "── 总用时 $(( $(date +%s) - t0 )) 秒"
    trap - EXIT; restart
    ok "快照 ${NAME} 完成（/data/gk3-snap/${NAME}）" ;;
*) die "未知命令 $CMD" ;;
esac

#!/usr/bin/env bash
# ============================================================================
# data-snapshot-android.sh — 在跑着的 Android 里给 /data 做快照（不重启）。恢复走 live：
#   bash scripts/data-snapshot-live.sh <live IP> restore <快照名> --yes
#
#   bash scripts/data-snapshot-android.sh backup [标签]      # 默认标签 a16；会 stop / start 一次 framework
#   bash scripts/data-snapshot-android.sh selftest           # 只在 /data/local/tmp 下造测试树打包，不停 framework
#
# 为什么能在 Android 里做（2026-10-26 实测）：
#   · toybox 0.8.12 的 tar 有 --selinux：标签写成 PAX 的 RHT.security.selinux，GNU tar 1.35 --selinux 能原样恢复
#     （设备上打的样本在容器里解到 ext4 上核过标签 / 属主 / 权限 / setgid）。zstd 在 /system_ext/bin（编译时没开多线程：不加 --single-thread 连 -T1 都报 "error 11 : Unsupported parameter"）。
#   · 一致性：打包前 `stop` 停掉 zygote ⇒ system_server 与全部 App 退出，数据库不再被写；打完 `start`。
#     adbd 不受影响（USB adb 一直在）。
#   · 没保存的：user.* xattr（App 目录上的 user.inode_cache / user.inode_code_cache —— 存的是 cache 目录的
#     inode 号，恢复后 inode 本来就变了；installd 开机 prepareAppData 时重写，未逐行核实）；socket 文件
#     （toybox 报 "unknown file type '140000'" 后跳过；都是运行时创建的）。
#   · toybox 的 --sparse 实际不生效（同一个 50 MiB 空洞文件加不加它归档一样大）⇒ 空洞按全零进归档（zstd 压得很小），
#     恢复后实占满。10-26 查过 /data（除 media / ota_package）没有 > 50 MiB 的稀疏文件，影响可忽略。
#   · /data 是不加密 ext4、fstab 没开 quota ⇒ 没有密钥与 project id 要保。
#
# 范围与 data-snapshot-live.sh 一致：userdata 除 media / ota_package / gk3-snap / lost+found 外全部；
#   metadata 整个 tar；misc 原样 dd。放在 /data/gk3-snap/<名字>/（root 0700）。
# ============================================================================
set -euo pipefail
SER=${SER:-gaokun3}
S() { adb -s "$SER" shell "$@" | tr -d '\r'; }
die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }
CMD="${1:?用法见文件头}"; TAG="${2:-a16}"

[ "$(S id -u)" = 0 ] || die "adb shell 不是 root"
S 'command -v zstd >/dev/null && tar --help 2>&1 | grep -q -- --selinux' || die "设备上没有 zstd 或 tar 不支持 --selinux"

# 设备端：打包一个目录下的若干条目；只容忍 socket 的报错
REMOTE_TAR='
tarit() { # $1=根目录 $2=输出 $3...=条目
    root=$1; out=$2; shift 2
    err=$out.stderr
    ( cd "$root" && tar --selinux --sparse -cf - "$@" 2>"$err" ) | zstd --single-thread -1 -q -o "$out" || true
    bad=$(grep -v -e "unknown file type .140000." -e "^tar: had errors" "$err" || true)
    [ -z "$bad" ] || { echo "✗ tar 报错：$bad"; exit 1; }
    echo "  跳过的 socket：$(grep -c "140000" "$err" || true) 个"
    rm -f "$err"
    zstd -tq "$out" || { echo "✗ zstd -t 不过：$out"; exit 1; }
}
'

case "$CMD" in
selftest)
    S "set -e; $REMOTE_TAR
T=/data/local/tmp/gk3-snapselftest; rm -rf \$T; mkdir -p \$T/src/app/files \$T/src/sys
echo hello > \$T/src/sys/a.xml; ln \$T/src/sys/a.xml \$T/src/sys/a-hard.xml; ln -s ../sys/a.xml \$T/src/app/link
dd if=/dev/zero of=\$T/src/app/files/sparse.bin bs=1 count=0 seek=50M 2>/dev/null; echo tail >> \$T/src/app/files/sparse.bin
chown -R 10234:10234 \$T/src/app; chmod 2771 \$T/src/app; chmod 0600 \$T/src/sys/a.xml
chcon u:object_r:app_data_file:s0:c512,c768 \$T/src/app \$T/src/app/files \$T/src/app/files/sparse.bin
chcon -h u:object_r:system_data_file:s0 \$T/src/app/link
tarit \$T/src \$T/out.tar.zst app sys
cd \$T/src && find . | sort | while read p; do printf '%s %s %s\n' \"\$(stat -c '%n %a %u %g %h %s' \"\$p\")\" \"\$(ls -Zd \"\$p\" | cut -d' ' -f1)\" \"\$( [ -f \"\$p\" ] && [ ! -L \"\$p\" ] && sha256sum \"\$p\" | cut -c1-16)\"; done > \$T/manifest.txt
ls -l \$T/out.tar.zst"
    W="$(cd "$(dirname "$0")/.." && pwd)/out/snaptest"; mkdir -p "$W"
    adb -s "$SER" pull /data/local/tmp/gk3-snapselftest/out.tar.zst "$W/selftest.tar.zst" >/dev/null
    adb -s "$SER" pull /data/local/tmp/gk3-snapselftest/manifest.txt "$W/selftest-manifest.txt" >/dev/null
    S 'rm -rf /data/local/tmp/gk3-snapselftest'
    docker run --rm --privileged -v "$W":/t debian:trixie bash -c '
apt-get update -qq >/dev/null; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tar zstd e2fsprogs attr >/dev/null 2>&1
truncate -s 200M /tmp/i; mkfs.ext4 -q /tmp/i; mkdir /tmp/m; mount -o loop /tmp/i /tmp/m
cd /tmp/m && zstd -dcq /t/selftest.tar.zst | tar --selinux --xattrs --xattrs-include="*" --numeric-owner -xpf - || exit 1
find . -mindepth 1 -path ./lost+found -prune -o -print | sort | while read p; do
  lbl=$(getfattr -h --only-values -n security.selinux "$p" 2>/dev/null | tr -d "\0")
  h=$( [ -f "$p" ] && [ ! -L "$p" ] && sha256sum "$p" | cut -c1-16)
  printf "%s %s %s\n" "$(stat -c "%n %a %u %g %h %s" "$p")" "$lbl" "$h"; done > /tmp/after.txt
grep -v "^\. " /t/selftest-manifest.txt > /tmp/before.txt
nd() { awk "{ if (\$2 ~ /^[0-9]+\$/ && system(\"test -d /tmp/m/\" \$1) == 0) \$6 = \"-\"; print }" "$1"; }
nd /tmp/before.txt > /tmp/b2; nd /tmp/after.txt > /tmp/a2; mv /tmp/b2 /tmp/before.txt; mv /tmp/a2 /tmp/after.txt
diff /tmp/before.txt /tmp/after.txt && echo "✓ toybox 打包 → GNU tar 恢复：$(wc -l < /tmp/after.txt) 项逐项一致（权限含 setgid / 属主 / 硬链接数 / 大小 / 标签含 MLS 类别 / 内容）"
echo "稀疏：$(du -k /tmp/m/app/files/sparse.bin | cut -f1) KiB 实占（逻辑 50 MiB）"
cd /; umount /tmp/m; losetup -D' ;;

backup)
    NAME="$TAG-$(date -u +%Y%m%d-%H%M%S)"
    OUT=/data/gk3-snap/$NAME
    need=$(S 'cd /data && du -sk $(ls -A | grep -v -x -e media -e ota_package -e gk3-snap -e lost+found) 2>/dev/null | awk "{s+=\$1} END {print s}"')
    avail=$(S 'df -k /data | tail -1' | awk '{print $4}')
    [ "$avail" -gt $((need + 10*1024*1024)) ] || die "空间不够：源约 $((need/1024)) MiB + 10 GiB 余量，只剩 $((avail/1024)) MiB"
    echo "── 源约 $((need/1024/1024)) GiB，剩 $((avail/1024/1024)) GiB"
    echo "── stop framework"
    S 'stop'
    for i in $(seq 1 30); do S 'pidof system_server >/dev/null' || break; sleep 1; done
    S 'pidof system_server >/dev/null' && { S start; die "system_server 30 秒没退，已 start 回去"; }
    ok "system_server / zygote 已停"
    restart() { S start >/dev/null 2>&1 || true; }
    trap restart EXIT
    t0=$(date +%s)
    S "set -e; $REMOTE_TAR
install -d -m 700 $OUT
cd /data; L=\$(ls -A | grep -v -x -e media -e ota_package -e gk3-snap -e lost+found)
echo \"── userdata：\$(echo \$L | wc -w) 个顶层条目\"
tarit /data $OUT/userdata.tar.zst \$L
n_src=\$(find \$L -xdev ! -type s | wc -l)
n_tar=\$(zstd -dcq $OUT/userdata.tar.zst | tar -tf - | wc -l)
[ \"\$n_src\" = \"\$n_tar\" ] || { echo \"✗ 条目数对不上：源 \$n_src（不含 socket）vs 归档 \$n_tar\"; exit 1; }
echo \"✓ 条目数一致：\$n_tar\"
echo '── metadata'; tarit /metadata $OUT/metadata.tar.zst \$(cd /metadata && ls -A | grep -v -x lost+found)
dd if=/dev/block/by-name/misc of=$OUT/misc.img bs=512 2>/dev/null
cd $OUT && sha256sum userdata.tar.zst metadata.tar.zst misc.img > SHA256SUMS
{ echo created_utc=\$(date -u +%FT%TZ); echo format=toybox-tar-selinux; echo entries=\$n_tar
  echo build=\$(getprop ro.build.date.utc); echo slot=\$(getprop ro.boot.slot_suffix)
  echo packages_xml_sha256=\$(sha256sum /data/system/packages.xml | cut -d' ' -f1); } > INFO
chmod 600 *; ls -l"
    echo "── 用时 $(( $(date +%s) - t0 )) 秒；start framework"
    trap - EXIT; S start
    ok "快照 $NAME 完成（/data/gk3-snap/$NAME）" ;;
*) die "未知命令 $CMD" ;;
esac

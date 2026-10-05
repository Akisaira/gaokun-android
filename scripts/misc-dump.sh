#!/usr/bin/env bash
# 只读：把设备 misc 分区前 64 KiB 拉到本机，用主机版 gk3-misc 解码（BCB / BCAB / VAB / GK3 记录）。
#
#   bash scripts/misc-dump.sh            # 解码
#   bash scripts/misc-dump.sh --raw F    # 另存原始 64 KiB 到 F（做基线、事后比对）
#
# 统一启动入口设计稿 §4.15（S11）。gk3-misc 不进 ROM，是 tools/gk3boot/misc/ 的主机工具，第一次用会自动编。
# 需要设备侧 root（发布构建经 KSU 的 adb shell 即 root）。
set -uo pipefail
SER=${SER:-gaokun3}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "✗ $*" >&2; exit 1; }
RAW=""
[ "${1:-}" = "--raw" ] && { RAW=${2:?--raw 要一个文件名}; }
TOOL=$ROOT/tools/gk3boot/build/gk3-misc
[ -x "$TOOL" ] || make -s -C "$ROOT/tools/gk3boot" gk3-misc >/dev/null || die "编 gk3-misc 失败"
[ "$(adb -s "$SER" shell id -u 2>/dev/null | tr -d '\r')" = 0 ] || die "adb 连不上 $SER 或不是 root"
T=$(mktemp -t misc-dump.XXXXXX)
trap 'rm -f "$T"' EXIT
# exec-out 走二进制通道（shell 会把 \n 改成 \r\n）
adb -s "$SER" exec-out 'dd if=/dev/block/by-name/misc bs=65536 count=1 2>/dev/null' > "$T"
[ "$(wc -c < "$T" | tr -d ' ')" = 65536 ] || die "只读到 $(wc -c < "$T") 字节，期望 65536"
echo "misc 0–64 KiB sha1 $(shasum "$T" | cut -c1-40)"
[ -n "$RAW" ] && { cp "$T" "$RAW" && echo "原始数据另存到 $RAW"; }
"$TOOL" dump "$T"

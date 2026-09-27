#!/usr/bin/env bash
# 发安装器（预览）：随 ROM 的发布附带（用户 2026-09-27）。在 Mac 上跑 —— live 镜像只能在 arm64 容器里造，
# 构建机上的 scripts/release.sh 做不了这一半。
#
#   bash scripts/live/release-installer.sh --boot-img <要发布的那一版的 boot.img> --rom v0.6.3-alpha \
#        --firmware out/vendor-firmware                       # 只造、不传 → out/release-installer/<安装器版本>/
#   … --upload v0.6.3-alpha                                    # 再传到那个 GitHub release（⚠️ 发布要用户点头）
#
# ★ --boot-img 必须是【要发布的那一版】的 boot.img（与 release.sh --no-build 同一个道理：发的就是验过的那一份）。
#   live 与 Android 共用这个内核；安装时写进 ESP 的内核来自安装载荷，不是这个。
# ★ 不带 --with-rescue：装进救援分区的就是 live 镜像本身 —— 它在真机上起过十几次（M0、M4b），还能重新安装；
#   单独的 rescue profile 在真机上一次没起过（Stage 7 M4.5 的事）。
# ★ 不带 --m0：M0 的变体启动项是开发用的。
# ⓘ 镜像里带华为的 GPU zap shader —— 与 ROM 同待遇（TODO B23，用户 2026-09-27 定）。
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
die() { echo "✗ $*" >&2; exit 1; }
say() { echo; echo "══ $*"; }
ok()  { echo "   ✓ $*"; }

BOOTIMG= ROM= FW= UPLOAD= PAYLOAD=
while [ $# -gt 0 ]; do
    case "$1" in
        --boot-img) BOOTIMG=$2; shift 2 ;;
        --rom)      ROM=$2; shift 2 ;;
        --firmware) FW=$2; shift 2 ;;
        --payload)  PAYLOAD=$2; shift 2 ;;      # 可选：把一整个发布目录放进 U 盘（离线装），镜像会大 1.3 GB
        --upload)   UPLOAD=$2; shift 2 ;;
        *) die "不认识的参数：$1" ;;
    esac
done
[ -f "$BOOTIMG" ] || die "要 --boot-img <要发布的那一版的 boot.img>"
[ -n "$ROM" ] || die "要 --rom <这个安装器随哪个 ROM 版本发，例如 v0.6.3-alpha>"
[ -d "$FW" ] || die "要 --firmware <GPU 固件目录>（adb pull /vendor/firmware out/vendor-firmware）"
# 发出去的东西必须对应一个提交：工作区有改动就停（镜像里的 GK3_GIT 会带 -dirty，发布说明对不上号）
[ -z "$(git -C "$REPO" status --porcelain)" ] || die "工作区有没提交的改动 —— 先提交（发出去的镜像要对应一个提交）"

VER=$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$REPO/live/installer-flutter/pubspec.yaml")
[ -n "$VER" ] || die "读不到安装器版本（live/installer-flutter/pubspec.yaml）"
OUT=$REPO/out/release-installer/$VER
say "安装器 ${VER}（随 ROM ${ROM}）· git $(git -C "$REPO" rev-parse --short=12 HEAD)"

say "1. 构建"
bash "$REPO/scripts/live/build-flutter.sh" >/dev/null || die "build-flutter.sh 失败"
ok "图形安装器"
bash "$REPO/scripts/live/build-live.sh" --boot-img "$BOOTIMG" --firmware "$FW" ${PAYLOAD:+--release "$PAYLOAD" --payload} \
    > "$REPO/out/release-installer-build.log" 2>&1 || { tail -20 "$REPO/out/release-installer-build.log"; die "build-live.sh 失败（全文 out/release-installer-build.log）"; }
ok "live 镜像 + Windows 安装包（日志 out/release-installer-build.log）"

say "2. 核对"
L=$REPO/out/live
grep -q "^GK3_INSTALLER_VERSION=$VER$" "$L/release.txt" || die "release.txt 里的版本不是 $VER"
! grep -q '^GK3_GIT=.*-dirty' "$L/release.txt" || die "release.txt 说工作区有改动（-dirty）"
grep -q "^GK3_BOOTIMG_SHA256=$(shasum -a 256 "$BOOTIMG" | cut -d' ' -f1)$" "$L/release.txt" || die "镜像的内核不是来自给的 boot.img"
[ -f "$L/gaokun3-windows/release.txt" ] && cmp -s "$L/release.txt" "$L/gaokun3-windows/release.txt" || die "Windows 安装包里的 release.txt 不对"
# 开发用的东西不许混进发布版
! grep -rqs 'gaokun3 M0' "$L/.entries" || die "带着 M0 的变体启动项（.entries 不空）"
ok "版本、提交、内核来源都对；没有 M0 变体"

say "3. 打包 → $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
B=gaokun3-installer-$VER
cp "$L/release.txt" "$OUT/$B-release.txt"
xz -T0 -6 -c "$L/gaokun3-live.img" > "$OUT/$B-usb.img.xz"
xz -t "$OUT/$B-usb.img.xz" || die "xz 自检没过"
cp "$L/gaokun3-windows.zip" "$OUT/$B-windows.zip"
# dd 之后要核对的是【解压后】的镜像，所以两个都列
IMG_SHA=$(shasum -a 256 "$L/gaokun3-live.img" | cut -d' ' -f1)
# ⚠️ GitHub 上附件名就是文件名（"文件#标签" 的 # 后面只是显示标签）—— 所以直接叫带版本的名字，不和 ROM 的清单撞
( cd "$OUT" && shasum -a 256 "$B-usb.img.xz" "$B-windows.zip" "$B-release.txt" > "$B-SHA256SUMS"
  echo "$IMG_SHA  $B-usb.img" >> "$B-SHA256SUMS" )
ls -la "$OUT"; cat "$OUT/$B-SHA256SUMS"

if [ -z "$UPLOAD" ]; then
    cat <<EOF

造好了，没有上传。上传到 GitHub release ${ROM}（⚠️ 发布要用户点头）：
  bash scripts/live/release-installer.sh --boot-img $BOOTIMG --rom $ROM --firmware $FW --upload $ROM
EOF
    exit 0
fi

say "4. 上传到 GitHub release $UPLOAD"
gh release view "$UPLOAD" >/dev/null || die "GitHub 上没有 release ${UPLOAD}（先发 ROM：release.sh --no-build）"
gh release upload "$UPLOAD" --clobber "$OUT/$B-usb.img.xz" "$OUT/$B-windows.zip" "$OUT/$B-release.txt" "$OUT/$B-SHA256SUMS" \
    || die "gh release upload 失败"
# ★ 判据看服务器上的字节数，不看 gh 的输出（CLAUDE.md 运维坑 1：gh release upload 报过 uploaded 而什么都没传）
for f in "$B-usb.img.xz" "$B-windows.zip" "$B-release.txt" "$B-SHA256SUMS"; do
    want=$(wc -c < "$OUT/$f" | tr -d ' ')
    got=$(gh release view "$UPLOAD" --json assets --jq ".assets[] | select(.name == \"$f\") | .size")
    [ "$got" = "$want" ] && ok "${f}：服务器上 $got 字节" || die "${f}：服务器上是 ${got:-没有}，本地 $want"
done

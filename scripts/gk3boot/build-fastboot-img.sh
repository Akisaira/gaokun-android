#!/usr/bin/env bash
# 宿主一键：在 arm64 Docker（本机 colima）里打执行端 initramfs fastboot.img（设计稿 boot-entry-design.md §5 S7b）。
#
#   bash scripts/gk3boot/build-fastboot-img.sh                     产物 tools/gk3boot/build/fastboot/fastboot.img
#   GK3_FASTBOOTD=/path/gk3-fastbootd bash scripts/gk3boot/build-fastboot-img.sh
#       带上协议守护进程（静态 aarch64）。不给时自动找 tools/gk3boot/build/fastbootd/gk3-fastbootd，
#       也没有就打一份"只有界面"的（屏幕上显示 EXECUTOR MISSING）。
#   GK3_DEBIAN_MIRROR=http://mirrors.ustc.edu.cn/debian …         换源（只影响第一次建镜像）
#
# 可复现：SOURCE_DATE_EPOCH 取 HEAD 的提交时间（工作区有改动时也一样 —— 判"是不是同一份"看 sha256，别看时间）。
# 镜像 / 容器名都带 fbi- 前缀：另一个会话（gk3-fastbootd）可能同时在用同一个 colima。
# 不碰设备、不碰构建机。用完 colima 要不要停，先看 `docker ps` 有没有别人的容器。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IMG=${GK3_DOCKER_PREFIX:-}fbi-gk3boot-build   # GK3_DOCKER_PREFIX：与别的会话共用 colima 时给镜像 / 容器名加前缀
OUTREL=tools/gk3boot/build/fastboot

docker info >/dev/null 2>&1 || { echo "✗ docker 不通 —— 本机先 colima start" >&2; exit 2; }

echo "▶ 构建环境镜像 ${IMG}（scripts/gk3boot/fbi-build.Dockerfile）"
docker build -q -t "$IMG" ${GK3_DEBIAN_MIRROR:+--build-arg GK3_DEBIAN_MIRROR=$GK3_DEBIAN_MIRROR} \
    -f "$ROOT/scripts/gk3boot/fbi-build.Dockerfile" "$ROOT/scripts/gk3boot" >/dev/null \
    || { echo "✗ 镜像构建失败（网络？试 GK3_DEBIAN_MIRROR=…）" >&2; exit 1; }

FBD=${GK3_FASTBOOTD:-}
[ -z "$FBD" ] && [ -f "$ROOT/tools/gk3boot/build/fastbootd/gk3-fastbootd" ] && FBD=$ROOT/tools/gk3boot/build/fastbootd/gk3-fastbootd
MNT=(); ARGS=()
if [ -n "$FBD" ]; then
    [ -f "$FBD" ] || { echo "✗ $FBD 不存在" >&2; exit 2; }
    MNT=(-v "$(cd "$(dirname "$FBD")" && pwd)/$(basename "$FBD"):/fbd/gk3-fastbootd:ro")
    ARGS=(--fastbootd /fbd/gk3-fastbootd)
    echo "▶ 带上 gk3-fastbootd：$FBD"
fi
EPOCH=$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)

docker run --rm --name "${GK3_DOCKER_PREFIX:-}fbi-build-$$" -v "$ROOT:/src" ${MNT[@]+"${MNT[@]}"} -e SOURCE_DATE_EPOCH="$EPOCH" -w /src "$IMG" \
    bash tools/gk3boot/initramfs/build.sh --out "$OUTREL" ${ARGS[@]+"${ARGS[@]}"}
f=$ROOT/$OUTREL/fastboot.img
[ -s "$f" ] || { echo "✗ 没有产物 $f" >&2; exit 1; }
echo "   宿主路径：$f  $(stat -f %z "$f" 2>/dev/null || stat -c %s "$f") 字节  sha256 $(shasum -a 256 "$f" | cut -d' ' -f1)"

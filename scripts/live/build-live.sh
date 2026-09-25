#!/usr/bin/env bash
# 在 Mac 上造 gaokun3 的 live U 盘镜像（或救援镜像）：arm64 容器里依次跑
# build-rootfs.sh → build-initramfs.sh → 拆 boot.img → build-usb.sh。
#
#   bash scripts/live/build-flutter.sh                 # 先有图形安装器（live 要）
#   bash scripts/live/build-live.sh --boot-img out/test-bootimg/boot.img [--m0]
#   bash scripts/live/build-live.sh --release <发布目录> --payload      # 带上安装载荷
#   bash scripts/live/build-live.sh --profile rescue --boot-img … --ssh-key ~/.ssh/id_ed25519.pub
#
#   --boot-img  内核 / dtb / 内核参数的来源：live 与 Android 共用同一个内核
#               （docs/stage7-live-installer.md §2.3）。给 --release 时默认用里面的 boot.img
#   --payload   把 --release 目录整个放进 U 盘（/gaokun3/payload/），装机就不用联网
#   --m0        多放几个启动项给真机 M0 用（见下面 M0_ENTRIES）
#
# 产物 → out/live/：gaokun3-<profile>.squashfs · initramfs.img · gaokun3-live.img · packages-<profile>.lock
# packages-<profile>.lock 另拷一份到 scripts/live/ —— 入库，两次构建之间 diff 它就知道变了什么。
#
# ⚠️ --privileged：mmdebstrap 的 root 模式要在 chroot 里挂 proc/sys/dev。只动容器自己的文件系统。
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
die() { echo "✗ $*" >&2; exit 1; }
say() { echo; echo "══ $*"; }

PROFILE=live; REL=; BOOTIMG=; PAYLOAD=; M0=; SSH_KEY=; WIFI=
while [ $# -gt 0 ]; do
    case "$1" in
        --profile)   PROFILE=$2; shift 2 ;;
        --release)   REL=$2; shift 2 ;;
        --boot-img)  BOOTIMG=$2; shift 2 ;;
        --payload)   PAYLOAD=1; shift ;;
        --m0)        M0=1; shift ;;
        --ssh-key)   SSH_KEY=$2; shift 2 ;;
        --wifi-conf) WIFI=$2; shift 2 ;;
        *) die "不认识的参数：$1" ;;
    esac
done
[ -n "$BOOTIMG" ] || { [ -n "$REL" ] && BOOTIMG=$REL/boot.img; }
[ -n "$BOOTIMG" ] && [ -f "$BOOTIMG" ] || die "要 --boot-img <boot.img>（或 --release <含 boot.img 的发布目录>）"
[ -z "$PAYLOAD" ] || [ -n "$REL" ] || die "--payload 要配 --release <发布目录>"
case "$PROFILE" in live|rescue) ;; *) die "--profile 只能是 live 或 rescue" ;; esac
[ "$PROFILE" = rescue ] || [ -x "$REPO/out/installer-flutter-linux-arm64/gk3_installer" ] \
    || die "先跑 scripts/live/build-flutter.sh（live 要图形安装器）"
docker info >/dev/null 2>&1 || die "docker 没在跑（colima start）"
[ "$(docker info --format '{{.Architecture}}')" = aarch64 ] || die "docker 不是 arm64"

# 容器里看得见的路径：仓库只读挂在 /repo，输入文件另外挂
abs() { (cd "$(dirname "$1")" && echo "$(pwd)/$(basename "$1")"); }
MOUNTS=(-v "$REPO:/repo:ro" -v "$REPO/out/live:/outlive" -v "$(abs "$BOOTIMG"):/in/boot.img:ro")
[ -n "$PAYLOAD" ] && MOUNTS+=(-v "$(cd "$REL" && pwd):/in/payload:ro")
[ -n "$SSH_KEY" ] && MOUNTS+=(-v "$(abs "$SSH_KEY"):/in/ssh.pub:ro")
[ -n "$WIFI" ] && MOUNTS+=(-v "$(abs "$WIFI"):/in/wpa.conf:ro")
mkdir -p "$REPO/out/live"

H=$(shasum -a 256 "$REPO/scripts/live/live-build.Dockerfile" 2>/dev/null || sha256sum "$REPO/scripts/live/live-build.Dockerfile")
TAG="gk3-live-build:${H:0:12}"
docker image inspect "$TAG" >/dev/null 2>&1 || { say "构建 live 构建环境 ${TAG}"; docker build -q -t "$TAG" -f "$REPO/scripts/live/live-build.Dockerfile" "$REPO/scripts/live" >/dev/null; }

# ★ M0 的变体启动项（docs/stage7-flutter-debian.md 的 M0 验收）：
#   渲染后端两条都要测（Impeller 是 3.47.2 的默认，#192915 说它在弱 GPU 上闪）；浸泡要持续出帧、
#   RSS 每 5 秒记到 U 盘的 gaokun3/diag/soak-*.log；旋转方向是推理出来的，反方向也放一个
#   ⚠️ 标题用 ASCII：开机菜单由 UEFI 固件的字体画，一般不含中文（见 build-usb.sh）
M0_ENTRIES=(
    "M0: Skia (Impeller off)|gk3.renderer=skia"
    "M0: soak test, Impeller|gk3.soak=1"
    "M0: soak test, Skia|gk3.soak=1 gk3.renderer=skia"
    "M0: rotate the other way (transform 90)|gk3.rotate=90"
)
# 条目逐行写进文件、挂进容器，在里面读成数组。
# ⚠️ 不用 printf %q + eval：第一版这么传，Mac 的 bash 3.2 与容器里的 bash 5 对 UTF-8 字节的
#    转义不一致，标题成了乱码。跨 shell 版本的转义不可信，文件不会出这种事。
ENTRIES_FILE=$REPO/out/live/.entries
: > "$ENTRIES_FILE"
[ -n "$M0" ] && printf '%s\n' "${M0_ENTRIES[@]}" > "$ENTRIES_FILE"

say "在容器里构建（${PROFILE}）"
docker run --rm --privileged "${MOUNTS[@]}" \
    -e PROFILE="$PROFILE" -e PAYLOAD="$PAYLOAD" -e HAVE_KEY="$SSH_KEY" -e HAVE_WIFI="$WIFI" \
    "$TAG" bash -euo pipefail -c '
    O=/build/out; mkdir -p $O /build/boot
    # 仓库只读挂进来；构建脚本按自己所在目录找 overlay 与清单，所以拷一份可写的
    cp -a /repo/scripts /build/scripts
    mkdir -p /build/out-installer && [ "$PROFILE" = rescue ] || cp -a /repo/out/installer-flutter-linux-arm64/. /build/out-installer/
    bash /build/scripts/live/build-rootfs.sh --profile "$PROFILE" --out $O --installer /build/out-installer \
        ${HAVE_KEY:+--ssh-key /in/ssh.pub} ${HAVE_WIFI:+--wifi-conf /in/wpa.conf}
    bash /build/scripts/live/build-initramfs.sh --busybox $O/busybox.static --firmware $O/fw --out $O
    python3 /build/scripts/live/gk3-bootimg.py /in/boot.img /build/boot
    EA=(); while IFS= read -r e; do [ -n "$e" ] && EA+=(--entry "$e"); done < /outlive/.entries
    bash /build/scripts/live/build-usb.sh --squashfs $O/gaokun3-$PROFILE.squashfs --initramfs $O/initramfs.img \
        --kernel /build/boot/Image --dtb /build/boot/gaokun3.dtb --sdboot $O/systemd-bootaa64.efi \
        --cmdline /build/boot/cmdline.txt ${PAYLOAD:+--payload /in/payload} ${EA[@]+"${EA[@]}"} --out $O/gaokun3-live.img
    cp $O/gaokun3-$PROFILE.squashfs $O/initramfs.img $O/gaokun3-live.img $O/packages-$PROFILE.lock /outlive/
'
cp "$REPO/out/live/packages-$PROFILE.lock" "$REPO/scripts/live/packages-$PROFILE.lock"
say "产物（out/live/）"
ls -lh "$REPO/out/live/"
echo
echo "写 U 盘（⚠️ 先确认 /dev/diskN 是 U 盘；macOS：diskutil list）："
echo "  sudo dd if=out/live/gaokun3-live.img of=/dev/rdiskN bs=4m && sync"

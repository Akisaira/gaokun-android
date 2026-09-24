#!/usr/bin/env bash
# 造 gaokun3 救援/LiveCD 的根文件系统（Alpine aarch64）→ squashfs。
#
#   sudo bash scripts/live/build-rootfs.sh --profile rescue --out /tmp/gk3live \
#        --ssh-key ~/.ssh/ed25519.pub
#
# profile：
#   rescue  无图形，只有 ssh + 分区/文件系统工具。装在内置盘上。
#   live    rescue + 图形安装器。做成 U 盘。
#
# ⚠️ 必须 root（要 chroot、要建设备节点）。
# ⚠️ 交叉构建（在 x86_64 上造 aarch64）需要 qemu-user-static + binfmt；
#    脚本会先检查，缺了就明确报错，而不是让 apk 在半路吐一堆看不懂的东西。
#
# 设计取舍见 docs/stage7-live-installer.md。
set -euo pipefail

# ---- 钉死的上游 ----------------------------------------------------------
ALPINE_BRANCH=v3.24
ALPINE_VER=3.24.1
ALPINE_ARCH=aarch64
ROOTFS_SHA256=f55a90f69052c5bd6f92cb09a8f47065970830b194c917a006fb94028e721259
MIRROR=https://dl-cdn.alpinelinux.org/alpine

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LIVE=$REPO/scripts/live

PROFILE=rescue
OUT=
SSH_KEY=
SDBOOT=
WIFI_CONF=
KEEP=

die() { echo "!! $*" >&2; exit 1; }
say() { echo; echo "══ $*"; }
ok()  { echo "   ✓ $*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE=$2; shift 2 ;;
        --out)     OUT=$2; shift 2 ;;
        --ssh-key) SSH_KEY=$2; shift 2 ;;
        --sdboot)  SDBOOT=$2; shift 2 ;;
        --wifi-conf) WIFI_CONF=$2; shift 2 ;;
        --keep)    KEEP=1; shift ;;
        *) die "不认识的参数：$1" ;;
    esac
done

[ -n "$OUT" ] || die "要 --out <目录>"
case "$PROFILE" in rescue|live) ;; *) die "--profile 只能是 rescue 或 live" ;; esac
[ "$(id -u)" = 0 ] || die "要 root（chroot + mknod）"

for t in curl tar chroot mksquashfs cpio sha256sum; do
    command -v "$t" >/dev/null || die "缺工具：${t}（Debian/Ubuntu: apt install squashfs-tools cpio curl）"
done

WORK=$OUT/work-$PROFILE
ROOTFS=$WORK/rootfs
mkdir -p "$OUT" "$WORK"

# ---- 1. 取 minirootfs -----------------------------------------------------
say "1. Alpine $ALPINE_VER $ALPINE_ARCH minirootfs"
TARBALL=$OUT/alpine-minirootfs-$ALPINE_VER-$ALPINE_ARCH.tar.gz
if [ ! -f "$TARBALL" ]; then
    curl -fSL -o "$TARBALL" \
        "$MIRROR/$ALPINE_BRANCH/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_VER-$ALPINE_ARCH.tar.gz"
fi
# ★ 钉的是【我们查过的那个 hash】，不是从镜像现拉一个 .sha256 再比 ——
#   后者只能证明"文件和这个镜像说的一致"，证明不了它没被换过。
GOT=$(sha256sum "$TARBALL" | cut -d' ' -f1)
[ "$GOT" = "$ROOTFS_SHA256" ] || die "minirootfs 校验和不对：$GOT"
ok "校验和一致"

rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
tar -xzf "$TARBALL" -C "$ROOTFS"
ok "解开到 $ROOTFS"

# ---- 2. 交叉构建准备 ------------------------------------------------------
HOST_ARCH=$(uname -m)
NEED_QEMU=0
if [ "$HOST_ARCH" != "aarch64" ]; then
    NEED_QEMU=1
    QEMU=$(command -v qemu-aarch64-static || true)
    [ -n "$QEMU" ] || die "在 $HOST_ARCH 上造 aarch64 需要 qemu-aarch64-static（apt install qemu-user-static）"
    grep -q 'aarch64' /proc/sys/fs/binfmt_misc/status 2>/dev/null || true
    [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
        || die "binfmt 里没有 qemu-aarch64（apt install binfmt-support 或 systemctl restart systemd-binfmt）"
    cp "$QEMU" "$ROOTFS/usr/bin/"
    ok "qemu-aarch64-static 已放进 chroot"
else
    ok "宿主就是 aarch64，不需要 qemu"
fi

# ---- 3. apk ---------------------------------------------------------------
say "2. 装包"
cat > "$ROOTFS/etc/apk/repositories" <<EOF
$MIRROR/$ALPINE_BRANCH/main
$MIRROR/$ALPINE_BRANCH/community
EOF
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

mount -t proc  none "$ROOTFS/proc"
mount --rbind /sys  "$ROOTFS/sys"
mount --rbind /dev  "$ROOTFS/dev"
cleanup() {
    umount -lR "$ROOTFS/dev"  2>/dev/null || true
    umount -lR "$ROOTFS/sys"  2>/dev/null || true
    umount -l  "$ROOTFS/proc" 2>/dev/null || true
}
trap cleanup EXIT

pkglist() { grep -vE '^\s*(#|$)' "$1" | tr '\n' ' '; }
PKGS=$(pkglist "$LIVE/pkgs-common.txt")
[ "$PROFILE" = live ] && PKGS="$PKGS $(pkglist "$LIVE/pkgs-live.txt")"

chroot "$ROOTFS" /sbin/apk update
# shellcheck disable=SC2086
chroot "$ROOTFS" /sbin/apk add $PKGS
ok "装了 $(echo $PKGS | wc -w) 个包"

# ---- 4. 铺 overlay --------------------------------------------------------
say "3. 配置"
copy_overlay() {
    [ -d "$1" ] || return 0
    cp -a "$1"/. "$ROOTFS"/
    ok "铺了 $(basename "$1")"
}
copy_overlay "$LIVE/overlay-common"
[ "$PROFILE" = rescue ] && copy_overlay "$LIVE/overlay-rescue"
[ "$PROFILE" = live ]   && copy_overlay "$LIVE/overlay-live"

if [ "$PROFILE" = live ]; then
    echo "gaokun3-live" > "$ROOTFS/etc/hostname"
else
    echo "gaokun3-rescue" > "$ROOTFS/etc/hostname"
fi

# ★ 开机自启：不用 rc-update（要跑目标架构的脚本），直接建符号链接。
#   OpenRC 的 runlevel 就是一堆指向 /etc/init.d/* 的符号链接，没有别的状态。
# ⚠️★ 必须【显式】把标准服务也挂上，不能假设 minirootfs 已经配好了 ——
#   minirootfs 是给 chroot 用的，它的 runlevel 基本是空的。
#   2026-08-23 上机吃过这个亏：只加了自己的服务，结果 localmount 之类根本
#   不在 runlevel 里。
# ★★ udev 对 live profile 是【必需】的，不是可选优化：
#   libinput 不直接读 evdev —— 它要靠 udev 的 input_id 规则打上的属性
#   （ID_INPUT / ID_INPUT_TOUCHSCREEN）才知道一个设备是什么，还要
#   USEC_INITIALIZED 这个"udevd 处理完了"的标记。没有 udevd 就报
#   "udev device never initialized"，界面画得出来但一个触摸事件都没有。
#   ⚠️ 我一度以为换成 libinput 的 path 后端就能绕开 udev —— 错的。
#     path 后端只改变【怎么枚举】，不改变【是否需要设备元数据】。
#   ⚠️ 设备节点是 devtmpfs 建的，所以 /dev/input/event* 一直都在 ——
#     "节点存在"很容易被误读成"设备可用"。
UDEV_SVCS=""
[ "$PROFILE" = live ] && UDEV_SVCS="udev udev-trigger"
for svc in devfs dmesg sysfs hwdrivers $UDEV_SVCS; do
    ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/sysinit/$svc" 2>/dev/null || true
done
mkdir -p "$ROOTFS/etc/runlevels/default" "$ROOTFS/etc/runlevels/boot"
for svc in hostname bootmisc syslog localmount hwclock modules sysctl seedrng urandom procfs; do
    [ -f "$ROOTFS/etc/init.d/$svc" ] && ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/boot/$svc"
done
for svc in gk3-wifi gk3-sshd gk3-diag dbus avahi-daemon haveged; do
    [ -f "$ROOTFS/etc/init.d/$svc" ] && ln -sf "/etc/init.d/$svc" "$ROOTFS/etc/runlevels/default/$svc"
done
ok "OpenRC 服务已挂到 runlevel"
echo "   ── sysinit: $(ls "$ROOTFS/etc/runlevels/sysinit" 2>/dev/null | tr '
' ' ')"
echo "   ── boot   : $(ls "$ROOTFS/etc/runlevels/boot"    2>/dev/null | tr '
' ' ')"
echo "   ── default: $(ls "$ROOTFS/etc/runlevels/default" 2>/dev/null | tr '
' ' ')"

# ---- 4b. LiveCD 的 tty1 接线 ----------------------------------------------
# ⚠️★ 第一版把安装器编进了镜像却【没有任何东西去拉起它】，实机启动后停在
#    login 提示符。镜像里有个二进制不等于它会跑 —— 这一步就是那根线。
if [ "$PROFILE" = live ]; then
    [ -f "$ROOTFS/etc/inittab" ] || die "镜像里没有 /etc/inittab"
    # tty1 交给安装器；tty2 留一个 getty 当逃生口
    sed -i 's|^tty1::respawn:.*|tty1::respawn:/usr/bin/gk3-installer-session|' "$ROOTFS/etc/inittab"
    grep -q 'gk3-installer-session' "$ROOTFS/etc/inittab" || die "inittab 的 tty1 行没改上（上游格式变了？）"
    grep -q '^tty2::respawn:' "$ROOTFS/etc/inittab" ||         echo 'tty2::respawn:/sbin/getty 38400 tty2' >> "$ROOTFS/etc/inittab"
    ok "tty1 交给图形安装器，tty2 留了 getty"
fi

# ---- 5. ssh 公钥 ----------------------------------------------------------
if [ -n "$SSH_KEY" ]; then
    [ -f "$SSH_KEY" ] || die "--ssh-key 指的文件不在：$SSH_KEY"
    case "$(head -c 4 "$SSH_KEY")" in
        ssh-|ecds) ;;
        *) die "$SSH_KEY 看着不像公钥 —— ⚠️ 别把私钥装进镜像" ;;
    esac
    mkdir -p "$ROOTFS/root/.ssh"
    cp "$SSH_KEY" "$ROOTFS/root/.ssh/authorized_keys"
    chmod 700 "$ROOTFS/root/.ssh"; chmod 600 "$ROOTFS/root/.ssh/authorized_keys"
    ok "已装入 ssh 公钥：$(cut -d' ' -f3 "$SSH_KEY" 2>/dev/null || echo '(无注释)')"
else
    # ⚠️ 公开发布的 live 镜像【不能】带任何人的公钥。
    [ "$PROFILE" = rescue ] && echo "   ⚠️ 没给 --ssh-key —— 这个救援镜像将【无法 ssh 登录】"
fi

# ---- 5-bis. 解锁 root 账户 ----------------------------------------------
# ⚠️★ 这一步不是"顺手加的"，是 2026-08-23 上机实测踩出来的：
#   Alpine 的 /etc/shadow 里 root 是 `root:*::0:::::`，而 `*` 在 OpenSSH 眼里
#   等于【账户已停用】。配上我们自己写的 `UsePAM no`，sshd 会在
#   **检查公钥之前**就拒绝登录 —— 钥匙、权限位、sshd_config 全都是对的，
#   照样 Permission denied。
#   ★ 而且它还会误导排查：对被拒的账户，sshd 会【故意通告全部认证方式】
#     （避免泄露账户是否存在），于是 `password` 出现在列表里，
#     看起来像"我的 sshd_config 没生效"。第一轮我就是这么判错的。
#
# 做法：把密码字段清空（Alpine 官方 ISO 也是这么干的）。安全性：
#   * 网络侧仍然只认公钥 —— sshd_config 里 PasswordAuthentication no
#     且 PermitEmptyPasswords no
#   * 控制台可以直接登录 —— 对一个救援/安装系统这是【需要的】：
#     网络起不来的时候，本地控制台是最后一条路。
#     而能碰到本机键盘的人本来就能引导任意系统，没有增加实际攻击面。
sed -i 's/^root:[^:]*:/root::/' "$ROOTFS/etc/shadow"
grep -q '^root::' "$ROOTFS/etc/shadow" || die "root 账户没解锁成功"
ok "root 账户已解锁（网络侧仍然只认公钥）"

# ---- 5a. ssh 主机密钥 -----------------------------------------------------
# rescue 是【给一个人用的私有镜像】，构建时生成主机密钥 → 每次开机指纹不变，
# 自动化不会撞 host key 变更。
# ⚠️ live 是【公开发布】的，绝对不能预置主机密钥 —— 所有人共用一把私钥
#    等于没有加密。那种情况下 /etc/init.d/gk3-sshd 会在首次启动时现生成。
if [ "$PROFILE" = rescue ]; then
    chroot "$ROOTFS" /usr/bin/ssh-keygen -A
    n=$(ls "$ROOTFS"/etc/ssh/ssh_host_*_key 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] || die "主机密钥没生成出来"
    ok "预置了 $n 把 ssh 主机密钥（指纹跨重启不变）"
else
    rm -f "$ROOTFS"/etc/ssh/ssh_host_*
    ok "live 镜像不带主机密钥（首次启动时现生成）"
fi

# ---- 5b. WiFi 凭据（可选）------------------------------------------------
# ⚠️ 本仓的规矩：WiFi 凭据不入库。这里也只从【命令行给的文件】读，
#    而且首选是让凭据留在启动介质上（见 /etc/init.d/gk3-wifi 的注释），
#    镜像本身可以一个字都不带。
if [ -n "$WIFI_CONF" ]; then
    [ -f "$WIFI_CONF" ] || die "--wifi-conf 指的文件不在：$WIFI_CONF"
    grep -q 'network=' "$WIFI_CONF" || die "$WIFI_CONF 里没有 network={...}，不像 wpa_supplicant 配置"
    install -Dm600 "$WIFI_CONF" "$ROOTFS/etc/wpa_supplicant/wpa_supplicant.conf"
    ok "已装入 WiFi 配置（$(grep -c 'network=' "$WIFI_CONF") 个网络）"
else
    echo "   ⓘ 没给 --wifi-conf —— 开机时会去启动介质上找"
    echo "     /media/gk3/gaokun3/wpa_supplicant.conf"
fi

# ---- 6. systemd-boot（安装器要往目标机 ESP 上写它）-----------------------
if [ -n "$SDBOOT" ]; then
    [ -f "$SDBOOT" ] || die "--sdboot 指的文件不在：$SDBOOT"
    head -c 2 "$SDBOOT" | grep -q MZ || die "$SDBOOT 不是 PE 文件"
    install -Dm644 "$SDBOOT" "$ROOTFS/usr/share/gaokun3/systemd-bootaa64.efi"
    ok "带上了 systemd-bootaa64.efi（$(stat -c %s "$SDBOOT") 字节）"
else
    echo "   ⚠️ 没给 --sdboot —— 安装器将无法给目标机装引导链"
fi

# ---- 6b. 安装器后端 --------------------------------------------------------
# 图形安装器与命令行安装器共用它。放进镜像，图形前端默认从这里加载。
install -Dm644 "$LIVE/installer-lib.sh" "$ROOTFS/usr/share/gaokun3/installer-lib.sh"
# 库调用的三个辅助脚本必须放在它旁边（installer-lib.sh 里的 GK3_LIBDIR）
for f in gk3-unsparse.py gk3-bootimg.py gk3-wpa-scan.py; do
    install -Dm755 "$LIVE/$f" "$ROOTFS/usr/share/gaokun3/$f"
done
ok "带上了安装器后端 installer-lib.sh 与它的三个辅助脚本"

# ---- 6c. 图形安装器（只有 live profile 需要）------------------------------
# ★ 在 chroot 【里面】编，所以编出来的就是目标架构的二进制 —— 不需要
#   交叉工具链，也不会出现"宿主能编、目标跑不了"。交叉构建时靠 qemu-user。
if [ "$PROFILE" = live ]; then
    say "6c. 编译图形安装器"
    chroot "$ROOTFS" /sbin/apk add --no-cache build-base pkgconf         cairo-dev pango-dev libdrm-dev libinput-dev eudev-dev >/dev/null 2>&1         || die "装不上安装器的构建依赖"
    mkdir -p "$ROOTFS/build"
    cp "$REPO/live/installer/gk3-installer.c" "$REPO/live/installer/drm_backend.inc" "$REPO/live/installer/gk3-strings.h"        "$REPO/live/installer/Makefile" "$ROOTFS/build/"
    chroot "$ROOTFS" /bin/sh -c "cd /build && make drm" || die "安装器编不过"
    # ★ 断言文案真的编进去了。gk3-strings.h 撞了 POSIX 标准头的名字，
    #   一旦漏拷会静默包含系统头 —— 编译期报"宏未声明"，但如果哪天宏名恰好
    #   不冲突，就会编出一个文案全空的界面。这条断言防的是后者。
    grep -q "$(sed -n 's/^WELCOME.TITLE = //p' "$REPO/live/installer/strings.zh.txt" | head -c 12)"          "$ROOTFS/build/gk3-installer" || die "编出来的二进制里找不到界面文案"
    install -Dm755 "$ROOTFS/build/gk3-installer" "$ROOTFS/usr/bin/gk3-installer"
    rm -rf "$ROOTFS/build"
    # ⚠️ 构建依赖装完就卸掉：它们有几百 MB，而镜像目标是 ≤120 MiB。
    chroot "$ROOTFS" /sbin/apk del build-base pkgconf cairo-dev pango-dev         libdrm-dev libinput-dev eudev-dev >/dev/null 2>&1 || true
    ok "安装器已编入镜像"
fi

# ---- 7. 断言（在做成 squashfs 之前，别把坏镜像做出来）--------------------
say "4. 体检"
# ⚠️★ 必须在 chroot 【里面】查。第一版在外面 `[ -e $ROOTFS/sbin/init ]`，
#    而那是个指向 /bin/busybox 的【绝对符号链接】—— 从宿主看它解析到宿主的
#    /bin/busybox，于是好端端的东西被判成"缺失"。当时 6 个失败里有 5 个是
#    这一个原因（init、两个 runlevel 链接、以及两个路径猜错的）。
# ⚠️★ 而且查【命令】而不是【路径】：sgdisk 在 /usr/bin、mkfs.vfat 在 /sbin，
#    路径这种东西不该由我们来记。
BAD=0
in_ch() { chroot "$ROOTFS" /bin/sh -c "$1" >/dev/null 2>&1; }
need_cmd()  { if in_ch "command -v $1"; then ok "命令 $1"; else echo "   ✗ 缺命令 $1"; BAD=1; fi; }
need_path() { if in_ch "[ -e '$1' ]"; then ok "$1"; else echo "   ✗ 缺 $1"; BAD=1; fi; }
# ⚠️ 多个候选路径要【逐个】试。第一版把它们塞进同一个 `ls a b`，
#    而 ls 只要有一个参数不匹配就返回非零 —— 于是固件明明在
#    /lib/firmware 下，却因为 /usr/lib/firmware 不存在而被判成缺失。
need_glob() {
    for pat in "$@"; do
        if in_ch "ls $pat"; then ok "$pat"; return; fi
    done
    echo "   ✗ 这些都没有匹配：$*"; BAD=1
}

echo "   ── 诊断：/etc/init.d 里有 ──"
chroot "$ROOTFS" /bin/sh -c 'ls /etc/init.d' 2>/dev/null | tr '
' ' ' | fold -w 100 -s | sed 's/^/     /'
echo
echo "   ── 诊断：默认 runlevel ──"
chroot "$ROOTFS" /bin/sh -c 'ls /etc/runlevels/default' 2>/dev/null | tr '
' ' ' | sed 's/^/     /'
echo

need_path /sbin/init
need_cmd  sshd
need_cmd  sgdisk
need_cmd  parted
need_cmd  resize2fs
need_cmd  mkfs.ext4
need_cmd  mkfs.vfat
need_cmd  mkfs.f2fs
need_cmd  ntfsresize
need_cmd  simg2img          # ★ super.img 是 sparse，没它装不了 Android
need_cmd  wpa_supplicant
need_cmd  dhcpcd
need_cmd  iw
need_path /bin/busybox.static
need_path /etc/init.d/gk3-wifi
need_path /etc/runlevels/default/gk3-wifi
need_path /etc/runlevels/default/gk3-sshd
need_path /etc/runlevels/default/gk3-diag  # 没网时唯一的取证通路
need_path /usr/share/gaokun3/installer-lib.sh
need_path /usr/share/gaokun3/gk3-unsparse.py   # 没有它 super 写不进去（.zst 走管道）
need_path /usr/share/gaokun3/gk3-bootimg.py
need_path /usr/share/gaokun3/gk3-wpa-scan.py
need_cmd  python3
need_path /etc/runlevels/boot/localmount     # gk3-* 排在它后面；缺了会打乱顺序
need_path /etc/runlevels/sysinit/devfs
# ★ 断言两个服务【没有】硬依赖：`need` 一旦指向不存在的服务，
#   OpenRC 会静默不启动它 —— 这是 2026-08-23 那次"起来了但没网没 ssh"的真凶。
# ⚠️ 判据要锚定行首的实际指令 —— 第一版写成 `grep -q "need "`，
#    结果匹配到了我自己在注释里写的"不能用 need"，当场自我误报。
if in_ch 'grep -qE "^[[:space:]]*need " /etc/init.d/gk3-wifi /etc/init.d/gk3-sshd'; then
    echo "   ✗ gk3-wifi/gk3-sshd 里还有 need 硬依赖"; BAD=1
else ok "gk3-* 只用 after 排序依赖，没有 need"; fi
# ★ 这条断言的由来见上面第 5 步：root 锁着的话，公钥、权限、配置全对也登不进去，
#   而症状（Permission denied + 通告了 password）会把人引向完全错误的方向。
if in_ch 'grep -q "^root::" /etc/shadow'; then ok "root 账户未锁定"; else echo "   ✗ root 账户是锁定的 —— ssh 公钥登录会被直接拒绝"; BAD=1; fi
# ⚠️ 只有给了 --ssh-key 才该有它。公开发布的 live 镜像【故意不带任何人的公钥】——
#    带了等于所有人共用一把钥匙。第一版把它写成无条件断言，于是 live 构建必然失败。
if [ -n "$SSH_KEY" ]; then need_path /root/.ssh/authorized_keys; else
    ok "没装公钥（live 镜像本该如此）"; fi
# ★ ath11k 固件：没有它 wlan0 根本不出现，而"没网"在这台机器上等于"救援失效"。
#   ⚠️ 不写死目录 —— linux-firmware 在 /lib 还是 /usr/lib、压不压缩，各版本不同。
# ★ Alpine 的固件是 .zst 压缩的 —— 通配符必须带 *。
#   已核实本机内核 CONFIG_FW_LOADER_COMPRESS_ZSTD=y，直接认压缩固件。
need_glob '/lib/firmware/ath11k/WCN6855/*/amss.bin*'    '/usr/lib/firmware/ath11k/WCN6855/*/amss.bin*'
need_glob '/lib/firmware/ath11k/WCN6855/*/board-2.bin*' '/usr/lib/firmware/ath11k/WCN6855/*/board-2.bin*'
need_glob '/lib/firmware/ath11k/WCN6855/*/m3.bin*'      '/usr/lib/firmware/ath11k/WCN6855/*/m3.bin*'
if [ "$PROFILE" = live ]; then
    need_glob '/usr/lib/libcairo.so.*'
    need_glob '/usr/lib/libinput.so.*'
    need_glob '/usr/share/fonts/*/wqy*' '/usr/share/fonts/wqy*/*'
    need_path /usr/bin/gk3-installer   # 没有它 LiveCD 就只是个救援系统
    need_path /usr/bin/gk3-installer-session
    # ★ 没有这两个服务，触摸就是死的（见上面第 3 节的说明）
    need_path /etc/runlevels/sysinit/udev
    need_path /etc/runlevels/sysinit/udev-trigger
    # ★ 断言那根线真的接上了 —— 二进制在镜像里不等于它会跑
    if in_ch 'grep -q gk3-installer-session /etc/inittab'; then ok 'inittab 的 tty1 指向安装器'; else echo '   ✗ inittab 没接安装器'; BAD=1; fi
fi
[ $BAD -eq 0 ] || die "体检没过 —— 不出镜像。上面缺的东西要么包名错了，要么 apk 装失败被吞了。"

# ---- 8. 出 squashfs -------------------------------------------------------
say "5. 打包"
rm -f "$ROOTFS/etc/resolv.conf"
[ "$NEED_QEMU" = 1 ] && rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
chroot_clean() { rm -rf "$ROOTFS/var/cache/apk"/* "$ROOTFS/tmp"/*; }
cleanup; trap - EXIT; chroot_clean

# initramfs 要的静态 busybox：在删 rootfs 之前先抠出来
cp "$ROOTFS/bin/busybox.static" "$OUT/busybox.static"
ok "留下 busybox.static 给 initramfs 用"

# ★★ WiFi 固件也要抠出来给 initramfs。
# ⚠️★ 【假说，尚未证实】ath11k 是内建驱动（CONFIG_ATH11K=y，实机核对过）。
#   如果它在 switch_root 之前 probe，那时根还是 initramfs，squashfs 里的
#   固件还不存在 —— probe 失败后驱动不会重试，wlan0 就永远不出现。
#   2026-08-23 上机现象：救援系统起来了，但用户在屏幕上看到"网卡起不来"。
#
#   ⚠️ 但这个解释有一处对不上，必须记下来：Android 的 cmdline 上是
#   `firmware_class.path=/vendor/firmware/`，而 /vendor 在早期同样没挂上 ——
#   Android 却能成。**这说明 ath11k 的 probe 本来就是延后的**
#   （PCIe/电源域晚上电 + deferred_probe_timeout=10）。
#   果真如此的话，救援系统里 probe 也会晚于 switch_root，squashfs 里的固件
#   本该够得着，那真因就另有其他。
#
#   ★ 所以把固件放进 initramfs 是【消除一个变量】，不是已确诊的修复。
#   真正能定案的是 gk3-diag 写回介质的 `dmesg | grep ath11k`。
# ⚠️ 只带本机真正用得到的那颗芯片。整个 ath11k 目录有 7 款芯片、约 23 MiB，
#    而 initramfs 要放进只剩几十 MB 的 ESP —— 收窄到 WCN6855 只要约 3 MiB。
#    换机器就改这个变量（gaokun3 是 WCN6855，实测 hw2.0 与 hw2.1 都要带：
#    驱动会按 board id 选，事先说不准是哪一个）。
FW_CHIPS=${FW_CHIPS:-ath11k/WCN6855}
rm -rf "$OUT/fw"; mkdir -p "$OUT/fw/lib/firmware"
for chip in $FW_CHIPS; do
    src=$ROOTFS/lib/firmware/$chip
    [ -d "$src" ] || die "rootfs 里没有 /lib/firmware/$chip —— initramfs 会造出一个没网的救援系统"
    mkdir -p "$OUT/fw/lib/firmware/$(dirname "$chip")"
    cp -a "$src" "$OUT/fw/lib/firmware/$(dirname "$chip")/"
done
ok "留下固件给 initramfs：${FW_CHIPS}（$(du -sh "$OUT/fw" | cut -f1)）"

SQUASH=$OUT/gaokun3-$PROFILE.squashfs
rm -f "$SQUASH"
mksquashfs "$ROOTFS" "$SQUASH" -comp zstd -Xcompression-level 19 -noappend -no-progress
ok "$SQUASH  $(du -h "$SQUASH" | cut -f1)"

[ -n "$KEEP" ] || rm -rf "$ROOTFS"

# 这个脚本是 sudo 跑的，产物会归 root —— 而下一步 build-initramfs.sh
# 【不需要 root】。不还回去的话下一步只会得到一句 "Permission denied"。
if [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER" "$OUT" 2>/dev/null || true
    ok "产物归还给 $SUDO_USER"
fi
echo
echo "下一步：bash scripts/live/build-initramfs.sh --busybox $OUT/busybox.static --firmware $OUT/fw --out $OUT"

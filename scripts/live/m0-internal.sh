#!/usr/bin/env bash
# M0 不用 U 盘：把 live 系统放到内置盘上【旧救援 Ubuntu 那个分区】（p3），ESP 上加【非默认】的启动项，
# 用一次性启动（LoaderEntryOneShot）进去。下一次重启自动回到 Android 的默认槽。
#
#   bash scripts/live/m0-internal.sh check      # 只读：找分区、量空间、核内核配置、看凭据在不在
#   bash scripts/live/m0-internal.sh prepare    # 放文件 + 写启动项（★ 不重启、不改 default）
#   bash scripts/boot-oneshot.sh gaokun3-m0.conf && adb -s "$SER" reboot    ← ⚠️ 要用户同意
#   bash scripts/live/m0-internal.sh logs       # 回到 Android 之后：取回 p3:/gaokun3/diag/ → out/m0/diag/
#   bash scripts/live/m0-internal.sh remove     # 撤掉启动项、initramfs 与 live.squashfs
#
#   SER=192.168.10.239:5555 bash scripts/live/m0-internal.sh check      # 走 TCP adb 时
#
# ★ 先例：Alpine 版 M0 就是这么做的 —— squashfs 放 p3、ESP 上一个非默认的 rescue-alpine.conf、
#   一条 LoaderEntryOneShot 进去（docs/stage7-live-installer.md:204-224）。
# ★ 这条路比 U 盘还好的一点：p3 上有 WiFi 配置的话，live 系统一起来就连上网，放进去的公钥让
#   开发机能 ssh 进去量浸泡数据 —— 人只需要看屏幕、摸触摸。
# ★ 为什么装不坏内置盘：live 系统是从 nvme0n1 上的分区启动的，gk3_probe 把整块内置盘标成
#   medium=yes，界面上禁用它；gk3_apply 的安全闸 1 也拒绝整盘清空介质所在的盘。
#
# ⚠️ 设备现在没有回落槽（_a 不可启动，#122 §1）—— 但这里【不碰】任何 Android 分区、不改 default：
#    live 起不来时 initramfs 60 秒后自己重启（或者长按电源键），回到 default 的 _b。
# ⚠️ 挂载点用私有的名字（/mnt/gaokun3_m0_*），不叫 /mnt/esp（CLAUDE.md 操作禁忌 4）。
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SER=${SER:-gaokun3}
LIVE=$REPO/out/live
M0=$REPO/out/m0
ESPM=/mnt/gaokun3_m0_esp
P3M=/mnt/gaokun3_m0_p3
SQ_NAME=live.squashfs
S() { adb -s "$SER" shell "$@" | tr -d '\r'; }
die() { echo "✗ $*" >&2; exit 1; }
say() { echo; echo "══ $*"; }
ok()  { echo "   ✓ $*"; }
warn(){ echo "   ⚠️ $*"; }

S true >/dev/null 2>&1 || die "adb 连不上 ${SER}（走 TCP：SER=192.168.10.239:5555；找设备：bash scripts/find-device.sh）"
[ "$(S getprop ro.crdroid.device)" = gaokun3 ] || die "$SER 不是 gaokun3（局域网里那台小米手机也开着 5555）"
[ "$(S id -u)" = 0 ] || die "需要 adbd 以 root 运行（adb -s $SER root）"

umount_all() { S "umount $ESPM 2>/dev/null; umount $P3M 2>/dev/null; rmdir $ESPM $P3M 2>/dev/null; true" >/dev/null; }
trap umount_all EXIT

# 找放 live 的分区：按【内容】认 —— 上面有 Alpine M0 留下的 /gaokun3/rescue.squashfs 的那个。
# 不写死分区号：hw-inventory.md 第 8 节那张表之后又加过 boot_a/boot_b。
# 只看【没挂载】的 ext4 分区，只读挂载。GK3_M0_PART=/dev/block/nvme0n1pN 可以直接指定。
find_part() {
    if [ -n "${GK3_M0_PART:-}" ]; then echo "$GK3_M0_PART"; return; fi
    S "mkdir -p $P3M
       for d in /dev/block/nvme0n1p*; do
         grep -q \"^\$d \" /proc/mounts && continue
         n=\$(readlink -f \$d); grep -q \"^\$n \" /proc/mounts && continue
         blkid \$d 2>/dev/null | grep -q 'TYPE=\"ext4\"' || continue
         mount -t ext4 -o ro \$d $P3M 2>/dev/null || continue
         [ -f $P3M/gaokun3/rescue.squashfs ] && { umount $P3M; echo \$d; break; }
         umount $P3M
       done; rmdir $P3M 2>/dev/null; true"
}

esp_info() {   # 挂 ESP（只读），打印 MID 与 slot_b 的内核、options、空闲
    S "mkdir -p $ESPM; mount -t vfat -o ro /dev/block/by-name/esp $ESPM 2>/dev/null || exit 1
       MID=\$(ls $ESPM | grep -E '^[0-9a-f]{32}\$' | head -1); echo MID=\$MID
       echo FREE_KB=\$(df -k $ESPM | tail -1 | awk '{print \$4}')
       echo DEFAULT=\$(sed -n 's/^default *//p' $ESPM/loader/loader.conf)
       for f in Image gaokun3.dtb; do [ -f $ESPM/\$MID/android/slot_b/\$f ] && echo HAVE_\$(echo \$f | tr -c 'A-Za-z0-9\n' _)=yes; done
       e=\$(ls $ESPM/loader/entries/*-android-b.conf 2>/dev/null | head -1); echo ENTRY_B=\$(basename \"\$e\")
       echo OPTS_B=\$(sed -n 's/^options *//p' \"\$e\")
       echo ENTRIES=\$(ls $ESPM/loader/entries/ | tr '\n' ' ')
       umount $ESPM"
}

cmd=${1:-check}
case "$cmd" in
check|prepare)
    say "1. 放 live 的分区"
    PART=$(find_part | tail -1)
    [ -n "$PART" ] || die "没找到带 /gaokun3/rescue.squashfs 的 ext4 分区。指定：GK3_M0_PART=/dev/block/nvme0n1pN"
    KNODE=$(S "readlink -f $PART"); KNAME=${KNODE##*/}
    ok "${PART}（内核节点 /dev/${KNAME}）"
    S "mkdir -p $P3M; mount -t ext4 -o ro $PART $P3M && { df -h $P3M | tail -1; ls -la $P3M/gaokun3/; umount $P3M; }" | sed 's/^/     /'
    P3_FREE_KB=$(S "mkdir -p $P3M; mount -t ext4 -o ro $PART $P3M && df -k $P3M | tail -1 | awk '{print \$4}'; umount $P3M" | tail -1)
    HAVE_WIFI=$(S "mkdir -p $P3M; mount -t ext4 -o ro $PART $P3M && { [ -f $P3M/gaokun3/wpa_supplicant.conf ] && echo yes || echo no; }; umount $P3M" | tail -1)
    [ "$HAVE_WIFI" = yes ] && ok "p3 上有 gaokun3/wpa_supplicant.conf —— live 起来会自己连 WiFi，开发机能 ssh 进去" \
        || warn "p3 上没有 WiFi 配置 —— live 起来连不上网，M0 只能看屏幕（数据回到 Android 后用 logs 取）"

    say "2. ESP"
    INFO=$(esp_info) || die "挂不上 ESP（/dev/block/by-name/esp）"
    printf '%s\n' "$INFO" | grep -v '^OPTS_B=' | sed 's/^/     /'
    eval "$(printf '%s\n' "$INFO" | grep -E '^(MID|FREE_KB|HAVE_Image|HAVE_gaokun3_dtb)=')"
    OPTS_B=$(printf '%s\n' "$INFO" | sed -n 's/^OPTS_B=//p')
    [ -n "${MID:-}" ] || die "ESP 上找不到 machine-id 目录"
    [ "${HAVE_Image:-}" = yes ] && [ "${HAVE_gaokun3_dtb:-}" = yes ] || die "ESP 上 $MID/android/slot_b/ 缺内核或 dtb"
    [ -n "$OPTS_B" ] || die "读不到 slot_b 启动项的 options"
    INIT_KB=$(( $(wc -c < "$LIVE/initramfs.img" 2>/dev/null || echo 0) / 1024 + 1 ))
    [ "${FREE_KB:-0}" -gt $(( INIT_KB + 512 )) ] && ok "ESP 空闲 ${FREE_KB} KiB，initramfs 要 ${INIT_KB} KiB" \
        || die "ESP 只剩 ${FREE_KB:-?} KiB，放不下 ${INIT_KB} KiB 的 initramfs"

    say "3. 内核：slot_b 的内核能不能跑 systemd（抽它自己的 .config）"
    mkdir -p "$M0"
    S "mkdir -p $ESPM; mount -t vfat -o ro /dev/block/by-name/esp $ESPM && cp $ESPM/$MID/android/slot_b/Image /data/local/tmp/gk3-m0-Image; umount $ESPM" >/dev/null
    adb -s "$SER" pull /data/local/tmp/gk3-m0-Image "$M0/slot_b-Image" >/dev/null && S "rm -f /data/local/tmp/gk3-m0-Image" >/dev/null
    if python3 "$REPO/scripts/extract-kconfig.py" "$M0/slot_b-Image" > "$M0/slot_b.config" 2>/dev/null; then
        miss=""
        for o in DEVTMPFS CGROUPS INOTIFY_USER SIGNALFD TIMERFD EPOLL UNIX SYSFS PROC_FS FHANDLE NET_NS USER_NS SQUASHFS OVERLAY_FS BLK_DEV_LOOP EXT4_FS; do
            grep -q "^CONFIG_$o=y" "$M0/slot_b.config" || miss="$miss $o"
        done
        [ -z "$miss" ] && ok "systemd 的硬性要求与 squashfs/overlay/loop/ext4 都是 =y（$(grep -m1 '^# Linux' "$M0/slot_b.config" | cut -c3-)）" \
            || die "slot_b 的内核缺：$miss"
    else warn "抽不出 slot_b 内核的配置（没开 IKCONFIG？）—— 按 v0.6.2 的审计结果继续（stage7-flutter-debian.md §5.3）"; fi

    say "4. 本地产物"
    for f in gaokun3-live.squashfs initramfs.img; do [ -f "$LIVE/$f" ] || die "没有 $LIVE/${f}（先跑 scripts/live/build-live.sh）"; done
    SQ_KB=$(( $(wc -c < "$LIVE/gaokun3-live.squashfs") / 1024 ))
    ok "squashfs $((SQ_KB / 1024)) MiB，initramfs ${INIT_KB} KiB"
    [ "${P3_FREE_KB:-0}" -gt $(( SQ_KB + 65536 )) ] && ok "p3 空闲 $((P3_FREE_KB / 1024)) MiB，够" || die "p3 空间不够放 squashfs"

    # 启动项的内核参数：从 slot_b 启动项派生（它由 OTA postinstall 从 boot.img 同步），过滤规则与
    # 装机时的救援条目是同一个函数；再把 squashfs 指到 p3，并【只】让 initramfs 去碰这一个分区
    # （ext4 即使只读挂载也可能回放日志，扫描所有分区不如直接指定）
    . "$REPO/scripts/live/installer-lib.sh"
    BASE=$(gk3__rescue_cmdline "$OPTS_B" | sed "s#gk3.squash=[^ ]*#gk3.squash=/gaokun3/$SQ_NAME gk3.dev=/dev/$KNAME#")
    say "5. 启动项（非默认；标题 ASCII —— 开机菜单由固件字体画）"
    echo "     options  $BASE"
    ENTRIES=(
        "gaokun3-m0.conf|gaokun3 M0: live installer|"
        "gaokun3-m0-skia.conf|gaokun3 M0: Skia (Impeller off)|gk3.renderer=skia"
        "gaokun3-m0-soak.conf|gaokun3 M0: soak test, Impeller|gk3.soak=1"
        "gaokun3-m0-soak-skia.conf|gaokun3 M0: soak test, Skia|gk3.soak=1 gk3.renderer=skia"
        "gaokun3-m0-rot90.conf|gaokun3 M0: rotate the other way|gk3.rotate=90"
    )
    for e in "${ENTRIES[@]}"; do
        f=${e%%|*}
        # ⚠️★ 文件名【不能】匹配 boot_control HAL 改写 default 用的 *-android-a.conf / *-android-b.conf
        #    （device/huawei/gaokun3/boot_control/EspSlot.cpp:42 写 default 的通配、:60 认 ESP 的通配）
        case "$f" in *-android-a.conf|*-android-b.conf) die "条目名 $f 会被 HAL 当成 Android 槽" ;; esac
        echo "     $f"
    done
    [ "$cmd" = check ] && { echo; echo "只读检查完毕。准备（不重启）：bash scripts/live/m0-internal.sh prepare"; exit 0; }

    say "6. 放文件（p3 读写挂载）"
    S "mkdir -p $P3M; mount -t ext4 $PART $P3M && mkdir -p $P3M/gaokun3" >/dev/null || die "p3 挂不成读写"
    adb -s "$SER" push "$LIVE/gaokun3-live.squashfs" "$P3M/gaokun3/$SQ_NAME" >/dev/null || die "推 squashfs 失败"
    # ★ 判据看产物：字节数 + sha256（CLAUDE.md 运维坑 1 —— scp 曾经退出码 0 而文件只有 77%）
    want=$(shasum -a 256 "$LIVE/gaokun3-live.squashfs" | cut -d' ' -f1)
    got=$(S "sha256sum $P3M/gaokun3/$SQ_NAME" | cut -d' ' -f1)
    [ "$want" = "$got" ] && ok "live.squashfs sha256 一致（${want:0:16}…）" || die "live.squashfs 的 sha256 不对：$got"
    # 公钥：开发机专用的一对（out/m0/，不动 ~/.ssh）；p3 上已有 authorized_keys 就【追加】不覆盖
    [ -f "$M0/ssh_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C "gaokun3-m0@$(hostname -s)" -f "$M0/ssh_ed25519"
    adb -s "$SER" push "$M0/ssh_ed25519.pub" /data/local/tmp/gk3-m0.pub >/dev/null
    # ⓘ p3 的根目录属 uid 1001、gaokun3/ 是 777 —— sshd 的 StrictModes 本来会因此拒绝这把钥匙。
    #   不在这里改 p3 的权限：镜像里的 gk3-ssh-keys 开机时把它并进 /root/.ssh，绕开了介质的属主问题。
    #   ⚠️ 那是 2026-09-25 下午才加的，这之前构建的 squashfs 里没有它（那时介质上的公钥登不进去）。
    S "f=$P3M/gaokun3/authorized_keys; touch \$f; grep -qF \"\$(cat /data/local/tmp/gk3-m0.pub)\" \$f || cat /data/local/tmp/gk3-m0.pub >> \$f
       chmod 600 \$f; chown 0:0 \$f; rm -f /data/local/tmp/gk3-m0.pub; sync; umount $P3M" >/dev/null
    ok "公钥 out/m0/ssh_ed25519.pub → p3:/gaokun3/authorized_keys（ssh -i out/m0/ssh_ed25519 root@<ip>）"

    say "7. ESP：initramfs + 启动项"
    S "mkdir -p $ESPM; mount -t vfat /dev/block/by-name/esp $ESPM && mkdir -p $ESPM/$MID/live" >/dev/null || die "ESP 挂不成读写"
    adb -s "$SER" push "$LIVE/initramfs.img" "$ESPM/$MID/live/initramfs.img" >/dev/null || die "推 initramfs 失败"
    want=$(shasum -a 256 "$LIVE/initramfs.img" | cut -d' ' -f1)
    [ "$(S "sha256sum $ESPM/$MID/live/initramfs.img" | cut -d' ' -f1)" = "$want" ] && ok "initramfs sha256 一致" || die "initramfs 的 sha256 不对"
    TMP=$(mktemp); i=0
    for e in "${ENTRIES[@]}"; do
        f=${e%%|*}; rest=${e#*|}; title=${rest%%|*}; extra=${rest#*|}
        cat > "$TMP" <<EOF
title      $title
version    gaokun3-m0
sort-key   zzm0$i
linux      /$MID/android/slot_b/Image
devicetree /$MID/android/slot_b/gaokun3.dtb
initrd     /$MID/live/initramfs.img
options    $BASE${extra:+ $extra}
EOF
        adb -s "$SER" push "$TMP" "$ESPM/loader/entries/$f" >/dev/null || die "写 $f 失败"
        i=$((i + 1))
    done
    rm -f "$TMP"
    S "sync; umount $ESPM" >/dev/null
    DEF=$(esp_info | sed -n 's/^DEFAULT=//p')
    ok "写了 $i 个启动项；default 仍是 ${DEF}（没动）"
    cat <<EOF

准备完毕，没有重启。进 M0（⚠️ 要用户在场并同意）：
  bash scripts/boot-oneshot.sh gaokun3-m0.conf          # 或 gaokun3-m0-soak.conf 等
  adb -s $SER reboot
起不来：initramfs 60 秒后自己重启，或长按电源键 → 回到 default（${DEF}）。
回到 Android 后取结果：bash scripts/live/m0-internal.sh logs
EOF
    ;;
logs)
    PART=$(find_part | tail -1); [ -n "$PART" ] || die "没找到放 live 的分区"
    mkdir -p "$M0/diag"
    S "mkdir -p $P3M; mount -t ext4 -o ro $PART $P3M && tar -C $P3M/gaokun3 -cf /data/local/tmp/gk3-m0-diag.tar diag 2>/dev/null; umount $P3M" >/dev/null
    adb -s "$SER" pull /data/local/tmp/gk3-m0-diag.tar "$M0/diag.tar" >/dev/null || die "p3 上没有 gaokun3/diag/（live 还没跑过？）"
    S "rm -f /data/local/tmp/gk3-m0-diag.tar" >/dev/null
    tar -C "$M0" -xf "$M0/diag.tar" && rm -f "$M0/diag.tar"
    ok "→ $M0/diag/"; ls -la "$M0/diag/"
    ;;
remove)
    INFO=$(esp_info) || die "挂不上 ESP"; eval "$(printf '%s\n' "$INFO" | grep '^MID=')"
    S "mkdir -p $ESPM; mount -t vfat /dev/block/by-name/esp $ESPM && rm -f $ESPM/loader/entries/gaokun3-m0*.conf && rm -rf $ESPM/$MID/live; sync; umount $ESPM" >/dev/null
    ok "ESP：删了 gaokun3-m0*.conf 与 $MID/live/"
    PART=$(find_part | tail -1)
    [ -n "$PART" ] && S "mkdir -p $P3M; mount -t ext4 $PART $P3M && rm -f $P3M/gaokun3/$SQ_NAME; sync; umount $P3M" >/dev/null \
        && ok "p3：删了 gaokun3/${SQ_NAME}（diag/ 与 authorized_keys 留着）"
    ;;
*) die "用法：$0 check|prepare|logs|remove" ;;
esac

#!/system/bin/sh
#
# A/B OTA 的 postinstall 钩子：把刚刷好的那个槽的内核（与 recovery）搬到 ESP 上。
#
# 背景：本机按 Android 分区规范有 boot_a / boot_b，update_engine 会像刷别的
# 分区一样把标准 Android boot 镜像刷进去。但引导链是 UEFI + systemd-boot，
# 它【读不了】Android boot 镜像 —— 只会从 ESP 按 BLS 条目加载文件。
# 所以过渡期在这里补一步：从 boot_<目标槽> 解出 kernel/ramdisk/dtb，
# 放到 ESP 上该槽专属的目录。
#   boot 分区 = 唯一真相源；ESP 上的文件 = 派生物。
# 两个槽的 BLS 条目【永久】指向各自的 slot_a/ slot_b，所以这里只放文件、
# 不改条目，也就绝不会碰到正在运行的那个槽 —— 回滚天然安全。
#
# recovery 走同一条路，但它【没有自己的分区】（安装器把剩余空间全给了
# userdata，已装机器没有余地再切），所以它的 ramdisk 作为文件随 vendor 走
# payload，在这里铺到 ESP 并派生出一个 BLS 条目。
# ★ 于是已装的机器一次普通 OTA 就能拿到 recovery，不必重装。
#
# 自研的 EFI 加载器（读 misc 选槽 + 解析 boot 镜像 + 装 initrd/DTB 协议）
# 就位之后，本脚本连同 ESP 上那些派生文件一起退役。
#
# ★ 参数是 update_engine 给的，不是猜的：
#   system/update_engine/payload_consumer/postinstall_runner_action.cc:355-357
#     argv[1] = target_slot（整数，0=_a 1=_b）  argv[2] = 状态 fd
#
# 退出码非 0 会让整个 OTA 失败。这是【故意的】：宁可更新失败，也不能让某个槽
# 位上出现"新 system + 旧内核"的组合。
set -u

TARGET_SLOT="${1:-}"
case "$TARGET_SLOT" in
    0) SUFFIX=a ;;
    1) SUFFIX=b ;;
    *) echo "postinstall: 目标槽位参数无效: '$TARGET_SLOT'"; exit 1 ;;
esac

# 本脚本随【新的】vendor 分区被挂到 /postinstall，所以同目录下的解包器
# 也是新的那一份 —— 与新 boot 镜像的格式必然匹配。
HERE="$(dirname "$0")"
EXTRACT="$HERE/gaokun3-bootimg-extract"
BOOT_DEV="/dev/block/by-name/boot_$SUFFIX"
ESP_DEV=/dev/block/by-name/esp
MNT=/mnt/gaokun3_ota_esp

log()  { echo "postinstall: $*"; }
fail() { log "失败: $*"; [ -n "${MOUNTED:-}" ] && { sync; umount "$MNT" 2>/dev/null; }; exit 1; }

log "目标槽位 = _$SUFFIX"

[ -x "$EXTRACT" ] || fail "$EXTRACT 不存在或不可执行"
[ -e "$BOOT_DEV" ] || fail "$BOOT_DEV 不存在（boot_a/boot_b 分区建了吗？）"
# ★ 2026-09-14（用户反馈 #1：v0.6.0 四次 OTA 全部死在这里）：by-name/esp 这个链接只在 GPT 分区名
#   （PARTLABEL）正好是 esp 时才有。手工分区 / 双系统的人往往只打了 vfat 卷标（比如 GAOKUN3ESP），
#   链接不存在，OTA 就在最后一步失败。所以不再依赖名字：找不到链接时【按内容】探测 ——
#   扫所有 vfat 分区，只读挂上，看谁有 loader/entries/*-android-*.conf。多个 ESP（比如 Windows 的）
#   也能分开：只有我们的那个有 android 条目。
find_esp() {
    if [ -e /dev/block/by-name/esp ]; then echo /dev/block/by-name/esp; return 0; fi
    log "by-name/esp 不存在（PARTLABEL 不是 esp —— 手工分区常见），改为按内容探测 vfat 分区"
    PROBE=/mnt/gaokun3_esp_probe; mkdir -p "$PROBE" || return 1
    for d in /dev/block/nvme*n*p* /dev/block/sd*[0-9] /dev/block/mmcblk*p*; do
        [ -b "$d" ] || continue
        toybox blkid "$d" 2>/dev/null | grep -q 'TYPE="vfat"' || continue
        mount -o ro -t vfat "$d" "$PROBE" 2>/dev/null || continue
        if ls "$PROBE"/loader/entries/*-android-*.conf >/dev/null 2>&1; then
            umount "$PROBE"; log "按内容找到 ESP = $d"; echo "$d"; return 0
        fi
        umount "$PROBE"
    done
    return 1
}
ESP_DEV=$(find_esp) || fail "找不到 ESP：没有 /dev/block/by-name/esp（PARTLABEL=esp），扫描 vfat 分区也没有含 loader/entries/*-android-*.conf 的那个"

mkdir -p "$MNT" || fail "mkdir $MNT"
mount -t vfat "$ESP_DEV" "$MNT" || fail "挂载 ESP"
MOUNTED=1

# systemd-boot 的布局是 <ESP>/<machine-id>/…，machine-id 不固定，按模式找
MID=$(ls "$MNT" | grep -E '^[0-9a-f]{32}$' | head -1)
[ -n "$MID" ] || fail "ESP 上找不到 machine-id 目录"
DEST="$MNT/$MID/android/slot_$SUFFIX"
mkdir -p "$DEST" || fail "mkdir $DEST"
log "目标目录 = $DEST"

# ★ 先看空间：ESP 只有 300 MiB，还要和固件自己那个 73 MiB 的
#   Persisted_Capsules.bin 共处。空间不够必须【当场失败】，
#   而不是写出一个被截断的内核 —— 那会变成一台不开机的机器。
#   目标目录里的旧文件会被覆盖，所以它们占的空间算作可用。
avail_kb=$(df -k "$MNT" | tail -1 | awk '{print $4}')
for f in Image ramdisk.img gaokun3.dtb recovery-ramdisk.img; do
    [ -f "$DEST/$f" ] && avail_kb=$((avail_kb + $(stat -c%s "$DEST/$f") / 1024))
done
log "可用（含将被覆盖的旧文件）约 ${avail_kb} KB"
# zboot 内核 13 + ramdisk 13 + dtb 0.2 + recovery ramdisk 15 ≈ 42 MB，留 56 MB 余量
[ "$avail_kb" -gt 57344 ] || \
    fail "ESP 空间不足（需约 56 MB）。清掉 <ESP>/$MID/android/ 下的 *.bak-* 再试"

# 解包器自己会写临时文件再改名，并逐段核对长度
"$EXTRACT" "$BOOT_DEV" "$DEST" || fail "从 $BOOT_DEV 解包失败"

# ── 把 boot.img 里的 cmdline 同步进该槽的启动项 ──────────────────────────────
# ★ 2026-09-16（#116 §17）：此前这里只换 Image/ramdisk/dtb，启动项的 options 行
#   是装机当天写死的、以后永远不动。于是 BOARD_KERNEL_CMDLINE 的任何改动都会进
#   boot.img（解出来的 cmdline.txt 里有），却【永远到不了】实际启动用的 .conf ——
#   v0.6.2 的 himax_hx83121a_spi.disable_pressure=0 就是这么静默丢掉的。
#   现在 options = cmdline.txt 的内容 + slot_suffix，与 boot.img 永远一致。
#   写法与 recovery 条目一样：临时文件再改名；cmdline.txt 缺失或为空则保留旧 options。
ENT="$MNT/loader/entries/$MID-android-$SUFFIX.conf"
if [ -s "$DEST/cmdline.txt" ] && [ -f "$ENT" ]; then
    NEWCMD=$(tr -d '\r\n' < "$DEST/cmdline.txt")
    case " $NEWCMD " in
        *" androidboot.slot_suffix="*) ;;                       # 万一 cmdline 已带，不重复
        *) NEWCMD="$NEWCMD androidboot.slot_suffix=_$SUFFIX" ;;
    esac
    if awk -v cmd="$NEWCMD" '/^options[[:space:]]/ { print "options    " cmd; next } { print }'            "$ENT" > "$ENT.new" && grep -q "^options " "$ENT.new"; then
        mv -f "$ENT.new" "$ENT"
        log "启动项 options 已同步为 boot.img 的 cmdline（$(wc -c < "$DEST/cmdline.txt") 字节）"
    else
        rm -f "$ENT.new"
        log "⚠️ 同步 options 失败，保留旧启动项（内核仍能起，但 cmdline 改动不会生效）"
    fi
else
    log "⚠️ 没有 cmdline.txt 或找不到 $ENT，启动项 options 未更新"
fi

# ── recovery ────────────────────────────────────────────────────────────────
# ★ recovery 与系统【共用同一个内核和 dtb】（实测 recovery.img 里的 kernel 与
#   boot.img 里的 sha256 完全相同），所以条目直接复用该槽刚解出来的
#   Image 与 gaokun3.dtb，ESP 上只多一个 ramdisk。
REC_SRC="$HERE/../boot/recovery-ramdisk.img"
if [ -f "$REC_SRC" ]; then
    log "铺设 recovery ramdisk"
    if cp "$REC_SRC" "$DEST/.recovery-ramdisk.new" &&
       mv -f "$DEST/.recovery-ramdisk.new" "$DEST/recovery-ramdisk.img"; then
        # ★ 条目【从该槽的 android 条目派生】，只替换 initrd/title/version/sort-key。
        #   这样 cmdline（含 slot_suffix）永远与主条目一致，不会漂 —— 本仓已被
        #   BOARD_KERNEL_CMDLINE 与 BLS 条目漂移各教育过一次。
        #   recovery 不需要特殊 cmdline：实测它内嵌的 cmdline 与 boot 的完全相同，
        #   是 ramdisk 决定它是 recovery。
        SRC_ENT="$MNT/loader/entries/$MID-android-$SUFFIX.conf"
        DST_ENT="$MNT/loader/entries/$MID-recovery-$SUFFIX.conf"
        # ⚠️★ 默认【不】创建 recovery 启动项 —— 2026-08-20 实测这个 ramdisk 在本机
        #   会进复位循环（Android 一次都没进，启动原因历史里没有新条目），
        #   而且不留 panic 记录（本机 init 的服务级失败是主动 reboot() 而不是
        #   panic，所以 init_fatal_panic + efi_pstore 抓不到）。
        #   条目一旦存在，用户在 15 秒菜单里误选一次就要跑到机器旁按电源键 ——
        #   在验证通过之前不能把这个坑发出去。
        #   要调试就设 persist.vendor.gaokun3.recovery_entry=1 再触发一次 OTA/部署。
        if [ "$(getprop persist.vendor.gaokun3.recovery_entry 2>/dev/null)" != "1" ]; then
            log "recovery 启动项按默认跳过（未验证会复位循环）；"
            log "  要调试请 setprop persist.vendor.gaokun3.recovery_entry 1"
        elif [ -f "$SRC_ENT" ]; then
            sed -e "s|^initrd .*|initrd     /$MID/android/slot_$SUFFIX/recovery-ramdisk.img|" \
                -e "s|^title .*|title      Recovery (gaokun3) — slot _$SUFFIX|" \
                -e "s|^version .*|version    gaokun3-recovery-$SUFFIX|" \
                -e "s|^sort-key .*|sort-key   zzrecovery$SUFFIX|" \
                "$SRC_ENT" > "$DST_ENT" &&
                log "recovery 条目已写: $MID-recovery-$SUFFIX.conf"
        else
            log "警告: 找不到 ${SRC_ENT}，跳过 recovery 条目"
        fi
    else
        log "警告: recovery ramdisk 写入失败，recovery 条目不会更新"
    fi
else
    log "vendor 里没有 recovery-ramdisk.img，跳过 recovery（旧 vendor 会这样）"
fi

sync
umount "$MNT" || log "警告: umount 失败（数据已 sync）"
log "完成：_$SUFFIX 槽的内核已就位"
exit 0

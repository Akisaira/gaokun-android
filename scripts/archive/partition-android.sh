#!/usr/bin/env bash
#
# 在 Ego 的内置 NVMe 上划出 Android 分区 —— MateBook E Go (gaokun3)
#
#   sudo bash partition-android.sh backup     # 备份 GPT（先做这个）
#   sudo bash partition-android.sh status     # 看现状和可用空间
#   sudo bash partition-android.sh plan       # 打印将要执行的操作（不动手）
#   sudo bash partition-android.sh commit     # 真正建分区
#   sudo bash partition-android.sh restore <备份文件>   # 出事了恢复分区表
#
# 这是整个项目里唯一会写内置盘的脚本。设计原则：
#   - 默认什么都不做，必须显式 commit
#   - commit 前强制要求已有备份
#   - 只在【未分配空间】里建新分区，绝不改动/删除任何现有分区
#   - 任何一步校验失败立刻退出
#
# ⚠️ 压缩 p4（NTFS "Data"）不由本脚本负责 —— 见 status 的提示。
#    用 Windows 自带的磁盘管理压缩最安全，它对自己的 NTFS 最了解。

set -uo pipefail

DISK=/dev/nvme0n1
BACKUP_DIR=/root/gpt-backup

# 目标分区（PARTLABEL 是我们自己设的，所以 Android 的 by-name 可用）
SUPER_LABEL=super;    SUPER_SIZE=12G
DATA_LABEL=userdata;  DATA_SIZE=64G
META_LABEL=metadata;  META_SIZE=32M

# Android 的分区类型 GUID：用通用的 Linux filesystem data
TYPE_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4

die() { echo "错误: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "需要 root"
command -v sgdisk >/dev/null || die "缺 sgdisk（apt install gdisk）"
[ -b "$DISK" ] || die "$DISK 不存在"

# ---------------------------------------------------------------- 安全检查
assert_not_in_use() {
    # 绝不能在从内置盘启动的系统上跑这个脚本
    local root_src
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null)
    case "$root_src" in
        "$DISK"*) die "根文件系统就在 $DISK 上。必须从 U 盘启动后再运行本脚本。" ;;
    esac
    # 目标盘上不能有已挂载的分区
    local mounted
    mounted=$(lsblk -nro NAME,MOUNTPOINT "$DISK" | awk 'NF>1 {print "  /dev/"$1" -> "$2}')
    if [ -n "$mounted" ]; then
        echo "以下分区当前已挂载，请先卸载："; echo "$mounted"
        die "目标盘上有已挂载的分区"
    fi
}

free_sectors() {
    # sgdisk -F/-E 给出最大空闲块的首/末扇区
    local first last
    first=$(sgdisk -F "$DISK" 2>/dev/null | tail -1)
    last=$(sgdisk -E "$DISK" 2>/dev/null | tail -1)
    echo "$first $last"
}

# ------------------------------------------------------------------ backup
cmd_backup() {
    mkdir -p "$BACKUP_DIR"
    local ts f
    ts=$(date +%Y%m%d-%H%M%S)
    f="$BACKUP_DIR/gpt-$ts"

    sgdisk --backup="$f.bin" "$DISK" || die "sgdisk 备份失败"
    sgdisk -p "$DISK" > "$f.txt" 2>&1
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,PARTUUID,LABEL "$DISK" >> "$f.txt" 2>&1
    sfdisk -d "$DISK" > "$f.sfdisk" 2>/dev/null

    echo "已备份到:"
    ls -la "$f".* | sed 's/^/  /'
    echo
    echo "校验备份可读:"
    sgdisk --print-mbr="$f.bin" >/dev/null 2>&1 && echo "  ✅ .bin 可解析" || echo "  ⚠️ .bin 校验跳过"
    [ -s "$f.txt" ] && echo "  ✅ .txt 非空 ($(wc -l < "$f.txt") 行)"
    [ -s "$f.sfdisk" ] && echo "  ✅ .sfdisk 非空"
    echo
    echo "⚠️ 强烈建议把这几个文件也拷一份到别的机器上。"
}

# ------------------------------------------------------------------ status
cmd_status() {
    echo "════════ 当前分区表 ════════"
    sgdisk -p "$DISK" 2>/dev/null | sed 's/^/  /'
    echo
    echo "════════ 文件系统视角 ════════"
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,LABEL,MOUNTPOINT "$DISK" | sed 's/^/  /'
    echo
    echo "════════ 未分配空间 ════════"
    read -r first last <<<"$(free_sectors)"
    if [ -z "$first" ] || [ -z "$last" ] || [ "$first" -ge "$last" ] 2>/dev/null; then
        echo "  没有可用的未分配空间"
        echo
        echo "  需要先压缩 p4（NTFS \"Data\"，336.6G）腾出约 80G。"
        echo "  推荐做法：启动到 Windows -> 磁盘管理 -> 右键 Data 卷 -> 压缩卷 -> 输入 81920 (MB)"
        echo "  用 Windows 自带工具最安全，它对自己的 NTFS 最了解；"
        echo "  ntfsresize 也能做，但没有必要冒这个险。"
    else
        local sectors bytes
        sectors=$((last - first + 1))
        bytes=$((sectors * 512))
        echo "  首扇区: $first"
        echo "  末扇区: $last"
        echo "  大小:   $((bytes / 1024 / 1024 / 1024)) GiB"
        echo
        local need=$((12 + 64 + 1))
        if [ $((bytes / 1024 / 1024 / 1024)) -lt $need ]; then
            echo "  ⚠️ 不足 ${need} GiB，还需继续压缩"
        else
            echo "  ✅ 足够（需要约 ${need} GiB）"
        fi
    fi
    echo
    echo "════════ 备份 ════════"
    if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/*.bin >/dev/null 2>&1; then
        ls -la "$BACKUP_DIR"/*.bin | sed 's/^/  /'
    else
        echo "  ❌ 还没有备份 —— commit 前必须先跑 backup"
    fi
}

# -------------------------------------------------------------------- plan
cmd_plan() {
    echo "════════ 将要执行的操作 ════════"
    echo "  目标盘: $DISK"
    echo "  只在未分配空间里【新建】以下分区，不改动任何现有分区："
    echo
    printf "    %-12s %-8s %s\n" "PARTLABEL" "大小" "用途"
    printf "    %-12s %-8s %s\n" "$SUPER_LABEL" "$SUPER_SIZE" "system/system_ext/product/vendor（动态分区）"
    printf "    %-12s %-8s %s\n" "$DATA_LABEL"  "$DATA_SIZE"  "/data"
    printf "    %-12s %-8s %s\n" "$META_LABEL"  "$META_SIZE"  "加密元数据"
    echo
    echo "  类型 GUID 统一用 $TYPE_GUID (Linux filesystem data)"
    echo
    echo "  PARTLABEL 是我们自己设的，所以 Android 的 /dev/block/by-name/* 可用"
    echo "  —— 现有 Windows 分区的 PARTLABEL 全是 'Basic data partition'，不唯一，"
    echo "     那才是之前判断要用 PARTUUID 的原因。"
    echo
    echo "  确认无误后执行: sudo bash $0 commit"
}

# ------------------------------------------------------------------ commit
cmd_commit() {
    assert_not_in_use

    ls "$BACKUP_DIR"/*.bin >/dev/null 2>&1 || die "没有找到 GPT 备份，先运行: $0 backup"

    read -r first last <<<"$(free_sectors)"
    [ -n "$first" ] && [ -n "$last" ] && [ "$first" -lt "$last" ] || die "没有可用的未分配空间，先压缩 p4"
    local avail_gib=$(( (last - first + 1) * 512 / 1024 / 1024 / 1024 ))
    [ "$avail_gib" -ge 77 ] || die "未分配空间只有 ${avail_gib} GiB，需要约 77 GiB"

    # 已存在同名 PARTLABEL 就中止，避免重复建
    for l in "$SUPER_LABEL" "$DATA_LABEL" "$META_LABEL"; do
        if lsblk -nro PARTLABEL "$DISK" | grep -qx "$l"; then
            die "已存在 PARTLABEL=$l 的分区，中止（避免重复建）"
        fi
    done

    echo "最后确认："
    cmd_plan
    echo
    read -r -p "输入 YES 继续（其他任何输入都会中止）: " ans
    [ "$ans" = "YES" ] || die "已取消"

    # 找三个未使用的分区号
    #
    # 注意：不能写成 n1=$(next_free) 这种形式 —— 命令替换在子 shell 里执行，
    # 函数内对 used 的更新传不回父 shell，三次调用会拿到同一个号。
    # 这里全程在当前 shell 里算。
    local n1 n2 n3 i
    local -a used_arr=() nums=()
    mapfile -t used_arr < <(sgdisk -p "$DISK" 2>/dev/null | awk '/^ *[0-9]+ /{print $1}')
    i=1
    while [ "${#nums[@]}" -lt 3 ]; do
        local taken=0 u
        for u in "${used_arr[@]}"; do [ "$u" = "$i" ] && { taken=1; break; }; done
        if [ "$taken" -eq 0 ]; then nums+=("$i"); used_arr+=("$i"); fi
        i=$((i + 1))
        [ "$i" -gt 128 ] && die "找不到空闲分区号"
    done
    n1=${nums[0]}; n2=${nums[1]}; n3=${nums[2]}
    [ "$n1" != "$n2" ] && [ "$n2" != "$n3" ] && [ "$n1" != "$n3" ] || die "分区号计算错误: $n1 $n2 $n3"

    echo
    echo "建分区 $n1=$SUPER_LABEL  $n2=$DATA_LABEL  $n3=$META_LABEL"
    sgdisk \
        -n "${n1}:0:+${SUPER_SIZE}" -t "${n1}:${TYPE_GUID}" -c "${n1}:${SUPER_LABEL}" \
        -n "${n2}:0:+${DATA_SIZE}"  -t "${n2}:${TYPE_GUID}" -c "${n2}:${DATA_LABEL}" \
        -n "${n3}:0:+${META_SIZE}"  -t "${n3}:${TYPE_GUID}" -c "${n3}:${META_LABEL}" \
        "$DISK" || die "sgdisk 建分区失败"

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 2

    echo
    echo "════════ 结果 ════════"
    lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,PARTUUID "$DISK" | sed 's/^/  /'
    echo
    echo "下一步："
    echo "  1. dd super.img 到 /dev/disk/by-partlabel/$SUPER_LABEL"
    echo "  2. mkfs.ext4 -L $DATA_LABEL /dev/disk/by-partlabel/$DATA_LABEL"
    echo "  3. mkfs.ext4 -L $META_LABEL /dev/disk/by-partlabel/$META_LABEL"
}

# ----------------------------------------------------------------- restore
cmd_restore() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || die "用法: $0 restore <备份文件.bin>"
    assert_not_in_use
    echo "⚠️ 将用 $f 覆盖 $DISK 的分区表"
    read -r -p "输入 YES 继续: " ans
    [ "$ans" = "YES" ] || die "已取消"
    sgdisk --load-backup="$f" "$DISK" || die "恢复失败"
    partprobe "$DISK" 2>/dev/null || true
    echo "已恢复。当前分区表："
    sgdisk -p "$DISK" | sed 's/^/  /'
}

case "${1:-status}" in
    backup)  cmd_backup ;;
    status)  cmd_status ;;
    plan)    cmd_plan ;;
    commit)  cmd_commit ;;
    restore) cmd_restore "${2:-}" ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
esac

# gaokun3 安装器后端。被两个前端共用：
#   * scripts/install-gaokun3.sh   命令行
#   * live/installer-flutter/      图形安装器（LiveCD）
#
# ★ 一套实现两个前端，是因为本仓反复吃过"两份拷贝各自漂移"的亏。
#   ⚠️ 这句话写下之后很长时间里并不成立：install-gaokun3.sh 根本没 source 这个
#      文件，两份实现各自漂了 —— 救援分区 24 GiB vs 1 GiB、loader.conf 的 default
#      一个指救援一个指 Android、cmdline 一份从 boot.img 取一份手抄且已过时。
#      2026-09-24 收拢：命令行版现在只是这个库外面的一层薄壳。
#
# 全部输出都是【面向机器的行记录】：`键=值` 一行一条，前缀标明类型。
# 人看的信息一律走 stderr；进度是 stderr 上的 `PROGRESS <百分比> <说明>`。
#
# ★ 值里不会有空格：自由文本字段（分区名、卷标、磁盘型号、SSID）一律经
#   gk3__enc 做百分号编码（% → %25，空格 → %20，制表符 → %09）。
#   原因：Windows 建的分区 PARTLABEL 全是 "Basic data partition"
#   （docs/hw-inventory.md 第 8 节），而 PART 记录里 name= 和 fslabel=
#   两个自由文本字段都夹在中间 —— "最后一个键吃到行尾"救不了两个。
#   ⇒ 解析规则就一条：按空格切，每个值再做 %-解码。
#
# ⚠️ 需要 bash（PIPESTATUS、数组）。前端一律 `bash -c '. installer-lib.sh && …'`。
#
#   . installer-lib.sh
#   gk3_preflight                  # 这台机器能不能装（型号 / BIOS / Secure Boot / 工具）
#   gk3_probe                      # 列出磁盘 / 分区 / 空闲区
#   gk3_esp_info <分区>            # 现有 ESP 的剩余空间、上面有没有 Windows（双系统之前问）
#   gk3_release_info [目录]        # 发布目录 / 安装 U 盘里带了什么（镜像、救援系统、版本）
#   gk3_net_release <url> <目录>   # 网络安装：下载一整套发布文件并逐个校验
#   gk3_plan  <参数…>              # 算出分区方案（纯计算，不碰磁盘）
#   gk3_apply <参数…>              # 执行（唯一会写盘的函数）

if [ -z "${BASH_VERSION:-}" ]; then
    echo "!! installer-lib.sh 需要 bash" >&2
    return 1 2>/dev/null || exit 1
fi

# ── 布局常量 ────────────────────────────────────────────────────────────────
# 说明见 install-gaokun3.sh 顶部那段（为什么 esp 必须叫 esp、
# 为什么 misc 挂载点必须是 /misc 等等）。
GK3_ESP_MIB=300
GK3_MISC_MIB=4
GK3_METADATA_MIB=32
GK3_SUPER_MIB=12288
GK3_BOOT_MIB=64          # 每个槽位；与 BoardConfig 的 BOARD_BOOTIMAGE_PARTITION_SIZE 对齐
# ★ 救援系统从 24 GiB 降到 1 GiB —— Stage 7 之后它是 55 MiB 的 squashfs，
#   不再是一整套装在盘上的 Ubuntu。1 GiB 给日后换更大的镜像留足余量。
GK3_RESCUE_MIB=1024
GK3_USERDATA_MIN_MIB=8192

# 双系统安装时，ESP 里至少要能放下我们的两个槽位（内核+ramdisk+dtb ×2）
GK3_ESP_NEED_MIB=150
# 重新安装时 ESP 上我们的文件是【覆盖】不是新增：只给内核 / ramdisk 变大留余量
GK3_ESP_REINSTALL_NEED_MIB=16
# OTA postinstall 的门槛：ESP 空闲 + 目标槽目录里将被覆盖的旧文件 > 56 MiB
# （device/huawei/gaokun3/bin/gaokun3-ota-postinstall.sh:93-96）。装完之后要还能 OTA
GK3_ESP_OTA_NEED_KIB=57344

# 这个库所在的目录。gk3-unsparse.py / gk3-bootimg.py / gk3-wpa-scan.py 跟它放在一起
# （仓库里是 scripts/live/，live 镜像里是 /usr/share/gaokun3/）。
GK3_LIBDIR=${GK3_LIBDIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

gk3_log()  { echo "$*" >&2; }
gk3_die()  { echo "!! $*" >&2; return 1; }
gk3_prog() { echo "PROGRESS $1 $2" >&2; }   # $1=百分比 $2=说明

# 协议的百分号编码（见文件头）。
gk3__enc() { printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e "s/$(printf '\t')/%09/g"; }

# 安装介质（/media/gk3，见 initramfs-init:119-120）所在的整块盘；不是从介质启动就是空串。
gk3__medium_disk() {
    local dev pk
    dev=$(findmnt -no SOURCE /media/gk3 2>/dev/null || echo "")
    [ -n "$dev" ] || return 0
    pk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    [ -n "$pk" ] && echo "/dev/$pk"
    return 0
}

# ── 探测 ────────────────────────────────────────────────────────────────────
# 输出：
#   DISK path=/dev/nvme0n1 size_mib=488386 model=... removable=0 tran=nvme|usb medium=no|yes
#   PART path=/dev/nvme0n1p1 num=1 start=2048 end=616447 size_mib=300 \
#        type=<GUID> name=esp fs=vfat fslabel=... os=windows|linux|android| medium=no|yes
#   （PART 的 medium=yes：安装器就是从这个分区跑起来的 —— 挂在 /media/gk3 的那个）
#   FREE disk=/dev/nvme0n1 start=616448 end=… size_mib=…
#   （model / name / fslabel 已百分号编码）
gk3_probe() {
    local d
    for d in /sys/block/*; do
        local name; name=$(basename "$d")
        # ⚠️ 正常情况下跳过 loop —— 没人往 loop 设备装系统。但测试需要它，
        #    所以给一个显式开关：GK3_ALLOW_LOOP=1。
        #    （否则 test-shrink.sh 没法用 gk3_probe 验"空间释放出来了没有"，
        #     只能另写一套算法，而那就等于测了两份不同的逻辑。）
        case "$name" in
            loop*)  [ "${GK3_ALLOW_LOOP:-0}" = 1 ] || continue ;;
            ram*|zram*|dm-*|sr*|md*) continue ;;
        esac
        [ -e "/dev/$name" ] || continue
        local sectors; sectors=$(cat "$d/size" 2>/dev/null || echo 0)
        [ "$sectors" -gt 0 ] || continue
        # 512 字节扇区 → MiB
        local size_mib=$(( sectors / 2048 ))
        [ "$size_mib" -ge 1024 ] || continue      # 小于 1 GiB 的不当安装目标
        local model removable tran medium=no
        # 型号去掉首尾空白（NVMe 的 model 属性右侧补空格补到 40 字节），中间的空格编码保留。
        # 原先 tr -d ' ' 会把 "SAMSUNG MZ9L…" 挤成 "SAMSUNGMZ9L…"。
        model=$(head -1 "$d/device/model" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        removable=$(cat "$d/removable" 2>/dev/null || echo 0)
        # tran=usb：界面据此标"外接盘"—— USB 硬盘盒的 removable 常常是 0，靠它认不出来
        tran=$(lsblk -dno TRAN "/dev/$name" 2>/dev/null | head -1 | tr -d ' ')
        # medium=yes：安装器就是从这块盘启动的。gk3_apply 的安全闸 1 会拒绝整盘清空它；
        # 界面应当【一开始】就把它标出来，而不是等用户选完、确认完再报错。
        [ "/dev/$name" = "$(gk3__medium_disk)" ] && medium=yes
        echo "DISK path=/dev/$name size_mib=$size_mib model=$(gk3__enc "${model:-?}") removable=$removable tran=${tran:-?} medium=$medium"
        gk3__probe_parts "/dev/$name" "$sectors"
    done
}

# ⚠️ 用 sgdisk 而不是 lsblk：我们要的是【分区表层面】的起止扇区和类型 GUID，
#    而且要能算出空闲区间 —— lsblk 不报空闲区间。
gk3__probe_parts() {
    local disk=$1 total_sectors=$2
    command -v sgdisk >/dev/null || { gk3_log "缺 sgdisk，跳过 $disk 的分区探测"; return 0; }

    local first_usable last_usable
    first_usable=$(sgdisk -p "$disk" 2>/dev/null | sed -n 's/^First usable sector is \([0-9]*\).*/\1/p')
    last_usable=$(sgdisk -p "$disk" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p')
    [ -n "$first_usable" ] || first_usable=2048
    [ -n "$last_usable" ] || last_usable=$(( total_sectors - 2048 ))

    # 收集分区，按起始扇区排序
    local tmp; tmp=$(mktemp)
    sgdisk -p "$disk" 2>/dev/null | awk '/^ *[0-9]+ /{print $1" "$2" "$3}' | sort -k2 -n > "$tmp"

    local cursor=$first_usable num start end medium_part
    medium_part=$(findmnt -no SOURCE /media/gk3 2>/dev/null || echo "")
    while read -r num start end; do
        [ -n "$num" ] || continue
        if [ "$start" -gt "$cursor" ]; then
            gk3__emit_free "$disk" "$cursor" $(( start - 1 ))
        fi
        local part; part=$(gk3_partpath "$disk" "$num")
        local ptype pname fstype fslabel
        ptype=$(sgdisk -i "$num" "$disk" 2>/dev/null | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')
        pname=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep "^Partition name:" | cut -d"'" -f2)
        fstype=$(blkid -o value -s TYPE "$part" 2>/dev/null || echo "")
        fslabel=$(blkid -o value -s LABEL "$part" 2>/dev/null || echo "")
        # 也报 KiB：本机 misc 只有 1007 KiB（GPT 头之后那段闲置空间），
        # 只报 MiB 会显示成 "0 MiB"，界面上看着像个空分区。
        # 实测发现的 —— 合成数据里没有这种小分区。
        echo "PART path=$part num=$num start=$start end=$end" \
             "size_mib=$(( (end - start + 1) / 2048 )) size_kib=$(( (end - start + 1) / 2 ))" \
             "type=${ptype:-?} name=$(gk3__enc "$pname") fs=${fstype:-} fslabel=$(gk3__enc "$fslabel")" \
             "os=$(gk3__guess_os "$part" "$ptype" "$pname" "$fstype")" \
             "medium=$([ -n "$medium_part" ] && [ "$(readlink -f "$medium_part")" = "$(readlink -f "$part")" ] && echo yes || echo no)"
        cursor=$(( end + 1 ))
    done < "$tmp"
    rm -f "$tmp"

    if [ "$cursor" -lt "$last_usable" ]; then
        gk3__emit_free "$disk" "$cursor" "$last_usable"
    fi
}

gk3__emit_free() {
    local disk=$1 start=$2 end=$3
    local mib=$(( (end - start + 1) / 2048 ))
    # 小于 16 MiB 的碎片没有意义，不报（GPT 对齐留下的缝隙）
    [ "$mib" -ge 16 ] || return 0
    echo "FREE disk=$disk start=$start end=$end size_mib=$mib"
}

# 认出分区上大概是什么系统 —— 只用于界面提示，不参与任何判断逻辑
gk3__guess_os() {
    local part=$1 ptype=$2 pname=$3 fstype=$4
    case "$pname" in
        esp) echo "esp"; return ;;
        super|userdata|metadata|misc|boot_a|boot_b) echo "android"; return ;;
    esac
    case "$ptype" in
        C12A7328-F81F-11D2-BA4B-00A0C93EC93B) echo "esp"; return ;;
        DE94BBA4-06D1-4D40-A16A-BFD50179D6AC) echo "winre"; return ;;
        E3C9E316-0B5C-4DB8-817D-F92DF00215AE) echo "msr"; return ;;
    esac
    case "$fstype" in
        ntfs) echo "windows" ;;
        ext4|ext3|btrfs|xfs) echo "linux" ;;
        f2fs) echo "android" ;;
        vfat) echo "fat" ;;
        crypto_LUKS) echo "luks" ;;
        *) echo "" ;;
    esac
}

# nvme 是 p1，sd 是 1
gk3_partpath() {
    case "$1" in
        *[0-9]) echo "$1p$2" ;;
        *)      echo "$1$2" ;;
    esac
}

# ── 预检 ────────────────────────────────────────────────────────────────────
# 这台机器能不能装。一项一行：
#   CHECK id=root       ok=yes|no
#   CHECK id=uefi       ok=yes|no
#   CHECK id=model      ok=yes|no|unknown value=GK-W7X
#   CHECK id=bios       ok=yes value=2.16          （只报版本，不拦 —— 见下）
#   CHECK id=secureboot ok=yes|no|unknown value=disabled|enabled
#   CHECK id=tools      ok=yes|no         missing=a,b
# ok=no 的项前端必须拦住；unknown 只警告 —— 读不到 ≠ 不合格（例如内核没开 DMIID）。
#
# ★ 型号 / BIOS 的读取点：/sys/class/dmi/id/{product_name,bios_version}
#   （drivers/firmware/dmi-id.c:42-47，要 CONFIG_DMIID，Kconfig 默认 y），
#   读不到时退回内核启动日志里那行 "Hardware name: HUAWEI GK-W7X/GK-W7X-PCB, BIOS 2.16 …"
#   （本机实测原文见 docs/hw-inventory.md:33）。
# ★ BIOS【不限制】（2026-09-25 用户：已有人验证过，不依赖 BIOS 版本）。原先只认 2.16、拒绝 2.17，
#   理由几经改写（最早的"两版触摸 SPI 总线与 GPIO 编号不同"比错了表，#120 §4）。现在只报版本号，
#   永远 ok=yes —— 出问题时 bug 报告里要有它，但它不再是装不装的条件。
#   型号仍然拦：GK3_SKIP_MODEL_CHECK=1 放行（gaokun2 是另一台机器、另一套 EC 协议，别装）。
# ★ Secure Boot：EFI 全局变量 SecureBoot，GUID 是 EFI_GLOBAL_VARIABLE_GUID
#   8be4df61-93ca-11d2-aa0d-00e098032b8c（include/linux/efi.h 里的定义，
#   Debian 6.12 头文件 :368）。efivarfs 的文件 = 4 字节属性 + 1 字节值。
#   ⚠️ 从【我们的】live U 盘启动时这项必然是 disabled（内核没签名，开着就起不来），
#      它真正拦的是"从通用的 Ubuntu/Debian live U 盘跑命令行版"那条路。
gk3_preflight() {
    local v f dmesg_hw=""
    gk3__hwline() {
        [ -n "$dmesg_hw" ] || dmesg_hw=$(dmesg 2>/dev/null | grep -m1 'Hardware name:' || true)
        printf '%s' "$dmesg_hw"
    }

    [ "$(id -u)" = 0 ] && echo "CHECK id=root ok=yes" || echo "CHECK id=root ok=no"
    [ -d /sys/firmware/efi ] && echo "CHECK id=uefi ok=yes" || echo "CHECK id=uefi ok=no"

    v=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    [ -n "$v" ] || v=$(gk3__hwline | sed -n 's/.*Hardware name: [^ ]* \([^/,]*\).*/\1/p')
    if [ "${GK3_SKIP_MODEL_CHECK:-0}" = 1 ]; then
        echo "CHECK id=model ok=unknown value=$(gk3__enc "${v:-?}") skipped=yes"
    else case "$v" in
        GK-W7X) echo "CHECK id=model ok=yes value=$v" ;;
        "")     echo "CHECK id=model ok=unknown value=" ;;
        *)      echo "CHECK id=model ok=no value=$(gk3__enc "$v")" ;;
    esac; fi

    v=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
    [ -n "$v" ] || v=$(gk3__hwline | sed -n 's/.*, BIOS \([^ ]*\).*/\1/p')
    echo "CHECK id=bios ok=yes value=$(gk3__enc "${v:-?}")"

    f=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    v=$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')
    case "$v" in
        0) echo "CHECK id=secureboot ok=yes value=disabled" ;;
        1) echo "CHECK id=secureboot ok=no value=enabled" ;;
        *) echo "CHECK id=secureboot ok=unknown value=" ;;
    esac

    local t missing=""
    for t in sgdisk partprobe blkid lsblk findmnt mkfs.vfat mkfs.ext4 dd od zstd python3; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing,$t"
    done
    missing=${missing#,}
    [ -z "$missing" ] && echo "CHECK id=tools ok=yes" || echo "CHECK id=tools ok=no missing=$missing"
    return 0
}

# ── 方案计算 ────────────────────────────────────────────────────────────────
# 纯计算，不碰磁盘 —— 所以可以在任何机器上跑、可以单元测。
#
#   gk3_plan --disk /dev/nvme0n1 --mode wipe|alongside|reinstall --rescue yes|no \
#            [--region-start S --region-end E] [--esp PATH] [--userdata-mib N] [--keep-data yes|no]
#
# 输出（顺序即执行顺序）：
#   PLAN op=wipe    disk=...
#   PLAN op=mkpart  num=0 name=super start=... end=... type=... size_mib=...
#   PLAN op=useesp  path=/dev/nvme0n1p1
#   PLAN op=reuse   name=super path=/dev/nvme0n1p6 num=6 start=... end=... size_mib=... action=write|format|keep
#                   （只有 reinstall：不改分区表，逐个复用盘上现有的分区）
#   PLANSUM total_mib=... userdata_mib=... rescue=yes|no mode=... [keep_data=yes|no]
# 失败：
#   PLANERR msg=...
#
# ⚠️ 所有分区起始都对齐到 1 MiB（2048 扇区）。不对齐会让 NVMe 的写放大变差，
#    而且 sgdisk 会自己挪，挪完之后我们算出来的 end 就对不上了。
GK3_CUR=0
GK3_TYPE_ESP=ef00
GK3_TYPE_DATA=8300

gk3_plan() {
    local disk="" mode="wipe" rescue="no" rstart="" rend="" esp="" ud_mib="" keep="no"
    while [ $# -gt 0 ]; do
        case "$1" in
            --disk) disk=$2; shift 2 ;;
            --keep-data) keep=$2; shift 2 ;;
            --mode) mode=$2; shift 2 ;;
            --rescue) rescue=$2; shift 2 ;;
            --region-start) rstart=$2; shift 2 ;;
            --region-end) rend=$2; shift 2 ;;
            --esp) esp=$2; shift 2 ;;
            --userdata-mib) ud_mib=$2; shift 2 ;;
            --disk-size-mib) GK3_FAKE_DISK_MIB=$2; shift 2 ;;   # 只给自测用
            *) echo "PLANERR msg=unknown-arg:$1"; return 1 ;;
        esac
    done
    [ -n "$disk" ] || { echo "PLANERR msg=no-disk"; return 1; }
    if [ "$mode" = reinstall ]; then
        gk3__plan_reinstall "$disk" "$rescue" "$keep" "$esp"; return $?
    fi

    # ⚠️★ ① 分区名查重。Android 的 first-stage mount 走 by-name/super，那是
    #   ueventd 按 PARTLABEL 建的符号链接 —— 重名时哪个赢【不确定】。在一块
    #   已经装过我们系统的盘上跑 alongside，就会建出第二个 super、第二个
    #   userdata，然后开机随机挂错分区。整盘模式不用查（分区表会被清空）。
    #   ⚠️ 取名字用 cut 不用 sed 反捕获 —— 第一版用了 sed 的反向引用，那个
    #      反斜杠在写文件的路上被吃成 0x01 控制字符，于是守卫看着在那儿
    #      却从不触发。实机验出来的。
    if [ "$mode" != wipe ] && command -v sgdisk >/dev/null; then
        local dup="" nm n
        for n in $(sgdisk -p "$disk" 2>/dev/null | awk '/^ *[0-9]+ /{print $1}'); do
            nm=$(sgdisk -i "$n" "$disk" 2>/dev/null | grep "^Partition name:" | cut -d"'" -f2)
            [ "$nm" = esp ] && continue
            case " misc metadata boot_a boot_b super userdata gk3rescue " in
                *" $nm "*) dup="$dup $nm" ;;
            esac
        done
        if [ -n "$dup" ]; then
            echo "PLANERR msg=partlabel-conflict names=$(echo $dup | tr " " ",")"
            return 1
        fi
    fi

    # ⚠️★ ⑤ MBR 盘。sgdisk 会把 MBR 盘【静默转成 GPT】，原布局当场没了。
    #   老 Windows 装机大多是 MBR，所以这不是理论风险。
    if command -v sgdisk >/dev/null; then
        if sgdisk -p "$disk" 2>&1 | grep -qi "MBR only"; then
            echo "PLANERR msg=mbr-disk"
            return 1
        fi
    fi

    local cur last
    if [ "$mode" = wipe ]; then
        local total_mib=${GK3_FAKE_DISK_MIB:-}
        if [ -z "$total_mib" ]; then
            local sectors; sectors=$(cat "/sys/block/$(basename "$disk")/size" 2>/dev/null || echo 0)
            total_mib=$(( sectors / 2048 ))
        fi
        [ "$total_mib" -gt 0 ] || { echo "PLANERR msg=cannot-size-disk"; return 1; }
        cur=2048
        last=$(( total_mib * 2048 - 2048 ))       # 尾部给备份 GPT 留 1 MiB
        echo "PLAN op=wipe disk=$disk"
    else
        [ -n "$rstart" ] && [ -n "$rend" ] || { echo "PLANERR msg=alongside-needs-region"; return 1; }
        # 起点向上对齐到 1 MiB
        cur=$(( (rstart + 2047) / 2048 * 2048 ))
        last=$rend
        if [ -z "$esp" ]; then
            echo "PLANERR msg=alongside-needs-existing-esp"; return 1
        fi
        echo "PLAN op=useesp path=$esp need_mib=$GK3_ESP_NEED_MIB"
    fi

    local avail_mib=$(( (last - cur + 1) / 2048 ))

    # 固定开销
    local fixed=$(( GK3_MISC_MIB + GK3_METADATA_MIB + GK3_BOOT_MIB * 2 + GK3_SUPER_MIB ))
    [ "$mode" = wipe ] && fixed=$(( fixed + GK3_ESP_MIB ))
    [ "$rescue" = yes ] && fixed=$(( fixed + GK3_RESCUE_MIB ))

    local need=$(( fixed + GK3_USERDATA_MIN_MIB ))
    if [ "$avail_mib" -lt "$need" ]; then
        echo "PLANERR msg=not-enough-space avail_mib=$avail_mib need_mib=$need"
        return 1
    fi

    # userdata 吃掉剩下的（除非调用方指定）
    local userdata_mib=$(( avail_mib - fixed ))
    if [ -n "$ud_mib" ]; then
        [ "$ud_mib" -ge "$GK3_USERDATA_MIN_MIB" ] || { echo "PLANERR msg=userdata-too-small min_mib=$GK3_USERDATA_MIN_MIB"; return 1; }
        [ "$ud_mib" -le "$userdata_mib" ] || { echo "PLANERR msg=userdata-too-big max_mib=$userdata_mib"; return 1; }
        userdata_mib=$ud_mib
    fi

    # ⚠️ 顺序即磁盘顺序，userdata 必须最后 —— 这样以后扩容不用挪任何东西。
    #    （本仓 M6 扩 /data 时正是靠这一点。）
    GK3_CUR=$cur
    if [ "$mode" = wipe ]; then
        gk3__emit_part "$disk" esp      "$GK3_ESP_MIB"      "$GK3_TYPE_ESP"
    fi
    gk3__emit_part "$disk" misc     "$GK3_MISC_MIB"     "$GK3_TYPE_DATA"
    gk3__emit_part "$disk" metadata "$GK3_METADATA_MIB" "$GK3_TYPE_DATA"
    gk3__emit_part "$disk" boot_a   "$GK3_BOOT_MIB"     "$GK3_TYPE_DATA"
    gk3__emit_part "$disk" boot_b   "$GK3_BOOT_MIB"     "$GK3_TYPE_DATA"
    gk3__emit_part "$disk" super    "$GK3_SUPER_MIB"    "$GK3_TYPE_DATA"
    if [ "$rescue" = yes ]; then
        gk3__emit_part "$disk" gk3rescue "$GK3_RESCUE_MIB" "$GK3_TYPE_DATA"
    fi
    gk3__emit_part "$disk" userdata "$userdata_mib"     "$GK3_TYPE_DATA"

    # ★ 最后一条不能越过可用区尾部。fixed+userdata 的算术上面已经保证了，
    #   但这里【再独立验一次】—— 算错的代价是写到别人的分区上。
    if [ "$(( GK3_CUR - 1 ))" -gt "$last" ]; then
        echo "PLANERR msg=plan-overruns-region end=$(( GK3_CUR - 1 )) limit=$last"
        return 1
    fi

    echo "PLANSUM mode=$mode rescue=$rescue avail_mib=$avail_mib fixed_mib=$fixed userdata_mib=$userdata_mib"
}

# 重新安装（用户 2026-09-25）：盘上已经有我们的 Android 时，另外两种方式都走不通 ——
# 整盘清空会锯掉安装器自己（免 U 盘时它就在这块盘上），双系统会建出第二套同名分区。
# 这里不改分区表，按 PARTLABEL 认出现有的每个分区，逐个决定：写新系统 / 格式化 / 保留。
# ★ 每个名字必须【恰好一个】：零个 = 不是一套完整的安装；两个 = 不知道写哪个
#   （by-name 链接重名时哪个赢不确定，见上面分区名查重的注释）。
# ⚠️ 纯计算，不碰盘；目标分区挂没挂着、是不是安装器所在的分区，由 gk3_apply 在动盘之前查。
gk3__plan_reinstall() {
    local disk=$1 rescue=$2 keep=$3 esp=$4
    command -v sgdisk >/dev/null || { echo "PLANERR msg=no-sgdisk"; return 1; }
    [ -n "$esp" ] || { echo "PLANERR msg=reinstall-needs-esp"; return 1; }
    local table="" n nm
    for n in $(sgdisk -p "$disk" 2>/dev/null | awk '/^ *[0-9]+ /{print $1}'); do
        nm=$(sgdisk -i "$n" "$disk" 2>/dev/null | grep "^Partition name:" | cut -d"'" -f2)
        table="$table$nm $n
"
    done
    local want="misc metadata boot_a boot_b super userdata" miss="" dup="" c
    [ "$rescue" = yes ] && want="$want gk3rescue"
    for nm in $want; do
        c=$(printf '%s' "$table" | awk -v x="$nm" '$1 == x' | wc -l | tr -d ' ')
        [ "$c" = 0 ] && miss="$miss $nm"
        [ "$c" -gt 1 ] && dup="$dup $nm"
    done
    [ -z "$dup" ] || { echo "PLANERR msg=reinstall-duplicate names=$(echo $dup | tr ' ' ',')"; return 1; }
    [ -z "$miss" ] || { echo "PLANERR msg=reinstall-missing names=$(echo $miss | tr ' ' ',')"; return 1; }

    echo "PLAN op=useesp path=$esp need_mib=$GK3_ESP_REINSTALL_NEED_MIB"
    local st en mib kib act min fixed=0 ud=0
    for nm in $want; do
        n=$(printf '%s' "$table" | awk -v x="$nm" '$1 == x {print $2}')
        st=$(sgdisk -i "$n" "$disk" 2>/dev/null | awk '/^First sector:/{print $3}')
        en=$(sgdisk -i "$n" "$disk" 2>/dev/null | awk '/^Last sector:/{print $3}')
        kib=$(( (en - st + 1) / 2 )); mib=$(( kib / 1024 ))
        # ⚠️ 下限按 KiB 比。2026-09-25 真机：本机的 misc 只有 1007 KiB（放在 GPT 头之后那段空隙里，
        #    Android 天天在用），按 MiB 取整是 0 ——"misc 太小"把重新安装整个拦住了。
        #    misc 的下限取实测在用的那个量级（1000 KiB）：更小的没验证过，不放行。
        case "$nm" in
            super) min=$(( GK3_SUPER_MIB * 1024 )); act=write ;;
            boot_a|boot_b) min=$(( GK3_BOOT_MIB * 1024 )); act=write ;;
            misc) min=1000; act=write ;;
            gk3rescue) min=$(( GK3_RESCUE_MIB * 1024 )); act=write ;;
            metadata) min=$(( GK3_METADATA_MIB * 1024 )); [ "$keep" = yes ] && act=keep || act=format ;;
            userdata) min=$(( GK3_USERDATA_MIN_MIB * 1024 )); [ "$keep" = yes ] && act=keep || act=format ;;
        esac
        # 新系统要装得下：super / boot 比这一版要的小，写到一半才会发现
        [ "$kib" -ge "$min" ] || { echo "PLANERR msg=reinstall-part-small name=$nm have_kib=$kib need_kib=$min"; return 1; }
        echo "PLAN op=reuse name=$nm path=$(gk3_partpath "$disk" "$n") num=$n start=$st end=$en size_mib=$mib size_kib=$kib action=$act"
        if [ "$nm" = userdata ]; then ud=$mib; else fixed=$(( fixed + mib )); fi
    done
    echo "PLANSUM mode=reinstall rescue=$rescue keep_data=$keep avail_mib=$(( fixed + ud )) fixed_mib=$fixed userdata_mib=$ud"
}

# 打印一条 mkpart 记录，并把游标 GK3_CUR 推到下一个 1 MiB 边界。
#
# ⚠️★ 第一版是"回显新游标"，调用方写 `cur=$(gk3__emit_part …)` ——
#   于是 **PLAN 行也被 $() 吞进变量里**，一条都没到 stdout，
#   而 cur 变成了带换行的字符串，下一次算术当场 unbound variable。
#   自测（test-plan.sh）一跑就抓到了。函数既要输出数据又要回传值时，
#   **走全局变量，别混用 stdout**。
gk3__emit_part() {
    local disk=$1 name=$2 mib=$3 type=$4
    local start=$GK3_CUR
    local end=$(( start + mib * 2048 - 1 ))
    echo "PLAN op=mkpart disk=$disk num=0 name=$name start=$start end=$end size_mib=$mib type=$type"
    GK3_CUR=$(( end + 1 ))
}

# ── 执行 ────────────────────────────────────────────────────────────────────
# 这是【唯一】会写盘的函数。
#
#   gk3_apply --disk X --mode wipe|alongside|reinstall --rescue yes|no --release DIR \
#             [--region-start S --region-end E --esp PATH] [--userdata-mib N] [--keep-data yes|no]
#   reinstall：不改分区表，复用盘上现有的那套分区（gk3__plan_reinstall）；--keep-data yes 不格式化
#   userdata / metadata（默认格式化 —— 跨版本降级时保留的数据可能起不来）
#
# 发布目录 = GitHub Release / R2 的 install/<VER>/ 下载下来的那一份：
#   boot.img                         必需
#   super.img.zst 或 super.img       必需（前者是发版产物，后者是构建机 out/ 里的）
#   recovery-ramdisk.img             可选（发版不带，见 docs/INSTALL.md）
#   systemd-bootaa64.efi             可选（live 镜像自带 /usr/share/gaokun3/ 那份）
#   rescue.squashfs + initramfs.img  --rescue yes 时必需；发布目录里没有就用
#                                    启动介质上的（/media/gk3/gaokun3/，build-usb.sh 放的）
#   wpa_supplicant.conf              可选，装进救援分区
#
# 进度打在 stderr：`PROGRESS <百分比> <说明>`，其余是日志。
#
# ⚠️★ GK3_DRYRUN=1 时【只打印不执行】。写这个开关不是为了方便 ——
#   是因为这段代码一旦错了就是别人的一整块盘，而它没法在 CI 里跑。
#   任何改动都应当先用 dry-run 看一遍要执行的命令序列。
#
# ⚠️★ 所有输入【在第一次写盘之前】验完。原先 systemd-boot 和散装内核文件的
#   检查排在写完 super 之后 —— 缺一个就是分区表已改、super 已写、然后死在
#   引导链那一步，留下一块半装的盘（本函数下面 ESP 那段的注释警告过同一件事）。
# ESP 上 <machine-id>/ 用哪个目录。$1=挂载点 $2=没有现成目录时用的名字
# ★ 必须与 OTA postinstall 找目录的规则【一致】：第一个 32 位十六进制的目录
#   （device/huawei/gaokun3/bin/gaokun3-ota-postinstall.sh:79，`ls | grep | head -1`）——
#   不一致的话 OTA 写进一个目录、启动项指着另一个。
# ⚠️★ 2026-09-26 M4b 实测：这里原先直接用【正在跑的系统】的 /etc/machine-id。live 的 machine-id
#   是 systemd 每次开机现生成的，于是重新安装在 ESP 上另开了一个目录、又写了一整套内核
#   （46 MB），ESP 写满，slot_b 的 ramdisk 截断在 2.8 MB、它的启动项是空文件 —— 而安装报告成功；
#   default 的通配 *-android-b.conf 从此同时匹配新旧两个条目，下一次 OTA 就是抛硬币。
gk3__esp_pick_mid() {
    local d; d=$(LC_ALL=C ls "$1" 2>/dev/null | grep -E '^[0-9a-f]{32}$' | head -1)
    echo "${d:-$2}"
}

# 往 ESP 上写一组文件还要多少 KiB。$1=挂载点，其余是 <ESP 上的相对路径>=<源文件>。
# 同一路径上已有的文件会被覆盖，只算变大的那部分；每个文件按 4 KiB 簇向上取整
gk3__esp_delta_kib() {
    local m=$1 t src new old kib=0; shift
    for t in "$@"; do
        src=${t#*=}; t=${t%%=*}
        new=$(wc -c < "$src"); old=0
        [ -f "$m/$t" ] && old=$(wc -c < "$m/$t")
        [ "$new" -gt "$old" ] && kib=$(( kib + (new - old + 4095) / 4096 * 4 ))
    done
    echo "$kib"
}

# 写完之后从【介质】读回来核对：卸下、丢掉这块设备的缓存（blockdev --flushbufs）、只读挂回去逐个 cmp。
# 挂着直接 cmp 读的是页缓存 —— 介质在回写时才报的错那样看不出来（2026-09-27 审查）。
#   gk3__verify_on <分区> <文件系统类型> <分区上的相对路径>=<源文件> …
gk3__verify_on() {
    local dev=$1 fst=$2 m w bad=""; shift 2
    blockdev --flushbufs "$dev" 2>/dev/null
    m=$(mktemp -d)
    mount -o ro -t "$fst" "$dev" "$m" 2>/dev/null || { rmdir "$m"; gk3_die "写完之后 $dev 挂不回来"; return 1; }
    for w in "$@"; do
        cmp -s "$m/${w%%=*}" "${w#*=}" || { bad=${w%%=*}; break; }
    done
    umount "$m"; rmdir "$m" 2>/dev/null
    [ -z "$bad" ] || { gk3_die "$dev 上的 $bad 与源文件不一致（读回来核对没过）"; return 1; }
    echo "${dev}：$# 个文件从介质读回核对一致" >&2
}

gk3_apply() {
    local disk="" mode=wipe rescue=no rel="" rstart="" rend="" esp="" ud_mib="" keep=no
    while [ $# -gt 0 ]; do
        case "$1" in
            --disk) disk=$2; shift 2 ;;
            --keep-data) keep=$2; shift 2 ;;
            --mode) mode=$2; shift 2 ;;
            --rescue) rescue=$2; shift 2 ;;
            --release) rel=$2; shift 2 ;;
            --region-start) rstart=$2; shift 2 ;;
            --region-end) rend=$2; shift 2 ;;
            --esp) esp=$2; shift 2 ;;
            --userdata-mib) ud_mib=$2; shift 2 ;;
            *) gk3_die "apply: 不认识的参数 $1"; return 1 ;;
        esac
    done
    [ -n "$disk" ] || { gk3_die "apply 要 --disk"; return 1; }
    [ -n "$rel" ] && [ -d "$rel" ] || { gk3_die "apply 要 --release <目录>"; return 1; }

    local DRY=${GK3_DRYRUN:-0}
    # ⚠️ 回显走 stderr：stdout 只留给行记录（文件头的协议）。原先 "+ 命令" 与
    #    各种说明都 echo 到 stdout —— 前端靠"长得不像记录"才没被它们骗过去。
    gk3__run() {
        if [ "$DRY" = 1 ]; then echo "DRY: $*" >&2; else
            echo "+ $*" >&2
            "$@" >&2 || { gk3_die "失败：$*"; return 1; }
        fi
    }

    # ── 输入：全部在动盘之前验完 ─────────────────────────────────────────
    gk3_prog 1 "检查安装文件"
    [ -f "$rel/boot.img" ] || { gk3_die "发布目录里没有 boot.img"; return 1; }
    local super_src
    if   [ -f "$rel/super.img.zst" ]; then super_src=$rel/super.img.zst
    elif [ -f "$rel/super.img" ];     then super_src=$rel/super.img
    else gk3_die "发布目录里既没有 super.img.zst 也没有 super.img"; return 1; fi

    local sdboot
    if [ -n "${GK3_SDBOOT:-}" ]; then
        # 显式指定的就用它，叫什么名字都行（原先按文件名找，于是这个开关只在文件
        # 恰好叫 systemd-bootaa64.efi 时才生效 —— 录 fixture 时才发现）
        [ -f "$GK3_SDBOOT" ] || { gk3_die "GK3_SDBOOT 指的文件不存在：$GK3_SDBOOT"; return 1; }
        sdboot=$GK3_SDBOOT
    else
        sdboot=$(gk3__find_file systemd-bootaa64.efi /usr/share/gaokun3 "$rel" /usr/lib/systemd/boot/efi) \
            || { gk3_die "找不到 systemd-bootaa64.efi（Debian：apt install systemd-boot-efi）"; return 1; }
    fi

    local r_squash="" r_initrd=""
    if [ "$rescue" = yes ]; then
        # ★ 找救援镜像的顺序：发布目录 → U 盘上专门放的救援镜像（gaokun3/install-rescue/，
        #   build-usb.sh --rescue-squashfs）→ 最后才是 U 盘上正在跑的这个。
        #   ⚠️ 最后那个是 live 镜像本身（带图形安装器、开机 tty1 就起它、185 MiB），不是
        #      rescue profile（104 MiB、只有 ssh 与工具）—— 只是"有总比没有好"的兜底。
        r_squash=$(gk3__find_file rescue.squashfs "$rel" /media/gk3/gaokun3/install-rescue /media/gk3/gaokun3) \
            || { gk3_die "选了装救援系统，但发布目录和启动介质上都没有 rescue.squashfs"; return 1; }
        r_initrd=$(gk3__find_file initramfs.img "$rel" /media/gk3/gaokun3) \
            || { gk3_die "选了装救援系统，但发布目录和启动介质上都没有 initramfs.img"; return 1; }
    fi

    local t
    for t in sgdisk partprobe blkid lsblk mkfs.vfat mkfs.ext4 python3; do
        command -v "$t" >/dev/null || { gk3_die "缺工具：$t"; return 1; }
    done
    case "$super_src" in *.zst) command -v zstd >/dev/null || { gk3_die "缺工具：zstd"; return 1; } ;; esac

    # ★ 完整性也在动盘之前验。下载断在一半的 super.img.zst 能通过上面所有检查，
    #   要到流式写盘写到一半才暴露 —— 那时分区表已经改了。有发版的校验清单
    #   （install-artifacts.sha256，scripts/release.sh 生成）就逐个核；没有清单时
    #   .zst 至少完整试解一遍（zstd -t，几秒钟）。
    if [ -f "$rel/install-artifacts.sha256" ]; then
        gk3_prog 1 "核对 sha256"
        local want f got
        while read -r want f; do
            f=${f#\*}
            [ -f "$rel/$f" ] || continue          # 清单里的 OTA zip 装机用不到，没下就算了
            case "$f" in boot.img|super.img.zst|super.img) ;; *) continue ;; esac
            got=$(sha256sum "$rel/$f" 2>/dev/null | cut -d' ' -f1)
            [ -n "$got" ] || got=$(shasum -a 256 "$rel/$f" | cut -d' ' -f1)
            [ "$got" = "$want" ] || { gk3_die "$f 的 sha256 与发版清单不符 —— 下载不完整或被改过（盘还没动过）"; return 1; }
            echo "${f}：sha256 与发版清单一致" >&2
        done < "$rel/install-artifacts.sha256"
    elif [ "${super_src%.zst}" != "$super_src" ]; then
        gk3_prog 1 "试解 super.img.zst"
        zstd -tq --long=31 "$super_src" \
            || { gk3_die "super.img.zst 不完整（zstd -t 没通过）—— 重新下载（盘还没动过）"; return 1; }
    fi

    # boot.img 当场拆开：拆不开说明镜像有问题 —— 而此刻盘还一个字节都没动。
    # （拆包逻辑与设备侧 bootimg_extract.cpp 同源，见 gk3-bootimg.py 的文件头）
    local parts; parts=$(mktemp -d)
    python3 "$GK3_LIBDIR/gk3-bootimg.py" "$rel/boot.img" "$parts" \
        || { rm -rf "$parts"; gk3_die "boot.img 拆不开 —— 盘还没动过"; return 1; }
    # ★ cmdline 取自 boot.img（BOARD_KERNEL_CMDLINE），不在这里另抄一份：
    #   这里原先手抄的那份缺 androidboot.boot_devices（首阶段 by-name 解析靠它）、
    #   init=/init、himax disable_pressure=0 等（TODO B15）。
    local cmdline; cmdline=$(tr -d '\r\n' < "$parts/cmdline.txt")

    # ── 双系统：别人的 ESP 在动盘之前验完 ────────────────────────────────
    # ⚠️★ 2026-09-24 loop 端到端测试抓到：这里原先在【写完分区表之后】才按
    #   PARTLABEL 找名叫 "esp" 的分区 —— 而 Windows 的 ESP 叫 "EFI system partition"，
    #   于是双系统模式在任何一台 Windows 机器上都必然失败，并留下一串建了一半的
    #   分区。空间检查也排在分区表之后（下面格式化那段的注释说过为什么那样不行）。
    #   双系统的 apply 此前从未真跑过：真盘上验过的只是 gk3_plan 的方案计算。
    # ESP 上 <machine-id>/ 的名字：双系统 / 重新安装在动盘前按现有 ESP 选（gk3__esp_pick_mid），
    # 整盘清空时 ESP 是新格式化的，在写引导链时再选（那时没有现成目录 → 用这个）
    local esp_mid="" mid_fb=${GK3_MACHINE_ID:-$(cat /etc/machine-id 2>/dev/null || echo 8a29534fa802480d9fbb71aa18c01d7b)}
    # 要往 ESP 上写的文件：<相对路径>=<源>。算空间与写完之后逐个核对用的是同一份清单
    gk3__esp_files() {
        local sl f
        echo "EFI/BOOT/BOOTAA64.EFI=$sdboot"
        echo "EFI/systemd/systemd-bootaa64.efi=$sdboot"
        for sl in a b; do
            for f in Image gaokun3.dtb ramdisk.img; do echo "$1/android/slot_$sl/$f=$parts/$f"; done
            [ ! -f "$rel/recovery-ramdisk.img" ] || echo "$1/android/slot_$sl/recovery-ramdisk.img=$rel/recovery-ramdisk.img"
        done
        [ "$rescue" != yes ] || echo "$1/rescue/initramfs.img=$r_initrd"
    }
    if [ "$mode" != wipe ]; then
        [ -n "$esp" ] && [ -b "$esp" ] || { rm -rf "$parts"; gk3_die "双系统模式要 --esp <现有 ESP 的分区节点>，给的是 '${esp}'"; return 1; }
        if [ "$DRY" != 1 ]; then
            local etype efs
            efs=$(blkid -o value -s TYPE "$esp" 2>/dev/null)
            # ⚠️ 不用 lsblk -o PARTTYPE：它要 udev 数据库，没有 udev 时是空串（容器里实测）。
            #    blkid -p 是 libblkid 直接读分区表，救援系统里也成立。
            etype=$(blkid -p -o value -s PART_ENTRY_TYPE "$esp" 2>/dev/null | tr 'a-f' 'A-F')
            [ "$efs" = vfat ] || { rm -rf "$parts"; gk3_die "$esp 不是 FAT 文件系统（是 '${efs}'）—— 不像一个 ESP"; return 1; }
            [ "$etype" = C12A7328-F81F-11D2-BA4B-00A0C93EC93B ] \
                || { rm -rf "$parts"; gk3_die "$esp 的分区类型不是 EFI System（是 '${etype}'）"; return 1; }
            # ⚠️★ ② 真的去量它有多少空闲。原先只在 plan 里打一行 need_mib=150
            #   却从不验证 —— 不够的话分区表已经改完、super 已经写完，然后死在
            #   装引导链那一步，留下一块半装的盘。
            local em fm; em=$(mktemp -d)
            if mount -o ro -t vfat "$esp" "$em" 2>/dev/null; then
                fm=$(df -m "$em" | awk 'NR==2{print $4}')
                # ★ 按【真要写的文件】算（2026-09-26 M4b 之后）：新文件减去同一路径上会被覆盖的旧文件
                esp_mid=$(gk3__esp_pick_mid "$em" "$mid_fb")
                local -a efl; mapfile -t efl < <(gk3__esp_files "$esp_mid")
                local need_kib free_kib slot_kib
                need_kib=$(( $(gk3__esp_delta_kib "$em" "${efl[@]}") + 256 ))    # 256：启动项、loader.conf
                if [ -f "$em/EFI/BOOT/BOOTAA64.EFI" ] && [ ! -e "$em/EFI/BOOT/BOOTAA64.EFI.before-gaokun3" ] \
                   && ! cmp -s "$em/EFI/BOOT/BOOTAA64.EFI" "$sdboot"; then        # 原件要留一份（见写引导链那一段）
                    need_kib=$(( need_kib + $(wc -c < "$em/EFI/BOOT/BOOTAA64.EFI") / 1024 + 4 ))
                fi
                free_kib=$(df -k "$em" | awk 'NR==2{print $4}')
                slot_kib=$(( $(cat "$parts/Image" "$parts/gaokun3.dtb" "$parts/ramdisk.img" | wc -c) / 1024 ))
                umount "$em"; rmdir "$em" 2>/dev/null
                echo "ESP 上用目录 ${esp_mid}；要写 $(( need_kib / 1024 )) MiB（已扣掉会被覆盖的同名文件），空闲 $(( free_kib / 1024 )) MiB" >&2
                if [ "$free_kib" -lt "$need_kib" ]; then
                    rm -rf "$parts"
                    gk3_die "ESP 空间不够：要写 $(( need_kib / 1024 )) MiB，只有 $(( free_kib / 1024 )) MiB。请先清理 EFI 分区（盘还没动过）"
                    return 1
                fi
                if [ $(( free_kib - need_kib + slot_kib )) -le "$GK3_ESP_OTA_NEED_KIB" ]; then
                    rm -rf "$parts"
                    gk3_die "ESP 装得下，但装完只剩 $(( (free_kib - need_kib) / 1024 )) MiB —— 以后的系统更新（OTA）会因为 ESP 空间不够失败。请先清理 EFI 分区（盘还没动过）"
                    return 1
                fi
                # 重新安装是【覆盖】ESP 上我们自己的文件，不是新增 —— 按 150 MiB 要求的话，一台已经装过的
                # 机器（我们的文件占了一百多 MiB）会被误判成"空间不够"
                local eneed=$GK3_ESP_NEED_MIB; [ "$mode" = reinstall ] && eneed=$GK3_ESP_REINSTALL_NEED_MIB
                echo "现有 ESP $esp 空闲 ${fm} MiB（需要 ${eneed}）" >&2
                if [ "${fm:-0}" -lt "$eneed" ]; then
                    rm -rf "$parts"
                    gk3_die "ESP 空间不够：只有 ${fm} MiB，需要 ${eneed} MiB。请先在原系统里清理 EFI 分区（盘还没动过）"
                    return 1
                fi
            else
                rmdir "$em" 2>/dev/null; rm -rf "$parts"
                gk3_die "挂不上现有 ESP $esp —— 不敢往一个读不了的 ESP 上装引导链（盘还没动过）"
                return 1
            fi
        fi
    fi

    # ── 安全闸 1：不能整盘清空自己正跑在上面的那块盘 ─────────────────────
    # ⚠️ 安装器要么从 U 盘跑、要么从内置盘上的某个分区跑（救援分区，或者免 U 盘安装时
    #    放 live 的那个分区）。后者做整盘清空等于把自己脚下的地板锯掉 —— 而且是【跑到一半】
    #    才死，盘已经毁了。★ 双系统（alongside）不受这道闸：它只往空闲区里建新分区，
    #    不碰任何已有分区 —— 免 U 盘装双系统正是"介质与目标同盘"的情形，必须放行。
    local medium_disk; medium_disk=$(gk3__medium_disk)
    if [ "$mode" = wipe ] && [ -n "$medium_disk" ] && [ "$medium_disk" = "$disk" ]; then
        rm -rf "$parts"
        gk3_die "拒绝：安装介质就在目标盘 $disk 上，整盘清空会锯掉自己脚下的地板"
        return 1
    fi

    # ── 安全闸 2：目标盘上不能有已挂载的分区 ────────────────────────────
    local mounted
    mounted=$(lsblk -nro MOUNTPOINT "$disk" 2>/dev/null | grep -v '^$' | tr '\n' ' ')
    if [ -n "$mounted" ] && [ "$mode" = wipe ]; then
        rm -rf "$parts"
        gk3_die "拒绝：$disk 上还有挂载着的分区（${mounted}）"
        return 1
    fi

    # ── 方案 ────────────────────────────────────────────────────────────
    gk3_prog 2 "计算分区方案"
    local plan
    plan=$(gk3_plan --disk "$disk" --mode "$mode" --rescue "$rescue" --keep-data "$keep" \
                    ${rstart:+--region-start "$rstart"} ${rend:+--region-end "$rend"} \
                    ${esp:+--esp "$esp"} ${ud_mib:+--userdata-mib "$ud_mib"}) \
        || { echo "$plan"; rm -rf "$parts"; return 1; }
    if printf '%s\n' "$plan" | grep -q '^PLANERR'; then
        printf '%s\n' "$plan" | grep '^PLANERR'; rm -rf "$parts"; return 1
    fi

    # ── 安全闸 3（重新安装）：要写的分区一个都不能挂着 ─────────────────────
    # 首先是安装器自己所在的那个（免 U 盘时它就在这块盘上）。整盘清空有安全闸 1，双系统只碰空闲区；
    # 重新安装却是往【已有】分区里写 —— 所以逐个查。
    if [ "$mode" = reinstall ]; then
        local rp busy=""
        for rp in $(printf '%s\n' "$plan" | grep '^PLAN op=reuse' | sed 's/.* path=\([^ ]*\).*/\1/'); do
            findmnt -rn -S "$rp" >/dev/null 2>&1 && busy="$busy $rp"
        done
        if [ -n "$busy" ]; then
            rm -rf "$parts"
            gk3_die "拒绝：要重写的分区还挂着（${busy# }）—— 安装器是不是就从它上面跑的？"
            return 1
        fi
    fi

    # ── 建分区 ──────────────────────────────────────────────────────────
    # ⚠️★ ④ 动手之前先把分区表备份到介质上。出事能一条命令还原：
    #     sgdisk --load-backup=<文件> <盘>
    #   代价是几十 KB 和一秒钟；没有它的话，改错分区表就只能靠猜。
    if [ "$DRY" != 1 ] && [ "$mode" != reinstall ]; then
        gk3__gpt_backup "$disk" apply
    fi

    if [ "$mode" = reinstall ]; then
        echo "重新安装：不改分区表，复用现有的 $(printf '%s\n' "$plan" | grep -c '^PLAN op=reuse') 个分区" >&2
    else
    gk3_prog 5 "写分区表"
    if printf '%s\n' "$plan" | grep -q '^PLAN op=wipe'; then
        gk3__run sgdisk --zap-all "$disk" || return 1
    fi
    local line name start end ptype
    while read -r line; do
        case "$line" in "PLAN op=mkpart"*) ;; *) continue ;; esac
        name=$(gk3__f "$line" name); start=$(gk3__f "$line" start)
        end=$(gk3__f "$line" end);   ptype=$(gk3__f "$line" type)
        gk3__run sgdisk -n "0:${start}:${end}" -t "0:${ptype}" -c "0:${name}" "$disk" || return 1
    done <<EOF
$(printf '%s\n' "$plan")
EOF
    gk3__run partprobe "$disk" || true
    [ "$DRY" = 1 ] || sleep 2
    fi

    # ── 格式化 ──────────────────────────────────────────────────────────
    gk3_prog 15 "格式化"
    # ⚠️★ 每一个分区节点都必须【解析成功且确实是块设备】才往下走。
    #   loop 设备实测暴露过：partprobe 还没沉降时 gk3__bylabel 会返回空串，
    #   于是命令变成 `dd of=` / `mkfs.ext4 -F ""` —— 那种情况下会发生什么
    #   完全不可预料，而此时分区表已经写下去了，盘已经不是原来的盘。
    #   **宁可在这里停住，也不能带着空路径继续。**
    local p_esp p_meta p_data p_super p_boota p_bootb p_resc p_misc
    if [ "$mode" = wipe ]; then
        p_esp=$(gk3__need_part "$disk" esp "$mode") || return 1
    else
        p_esp=$esp    # 别人的 ESP：名字不归我们管（Windows 叫它 "EFI system partition"）
    fi
    p_misc=$(gk3__need_part "$disk" misc "$mode")   || return 1
    p_meta=$(gk3__need_part "$disk" metadata "$mode")   || return 1
    p_data=$(gk3__need_part "$disk" userdata "$mode")   || return 1
    p_super=$(gk3__need_part "$disk" super "$mode")     || return 1
    p_boota=$(gk3__need_part "$disk" boot_a "$mode")    || return 1
    p_bootb=$(gk3__need_part "$disk" boot_b "$mode")    || return 1
    if [ "$rescue" = yes ]; then
        p_resc=$(gk3__need_part "$disk" gk3rescue "$mode") || return 1
    fi

    if [ "$mode" = wipe ]; then
        gk3__run mkfs.vfat -F 32 -n ESP "$p_esp" || return 1
    else
        echo "复用现有 ESP：${p_esp}（不格式化；空间与类型在动盘之前已验过）" >&2
    fi
    if [ "$mode" = reinstall ] && [ "$keep" = yes ]; then
        echo "保留用户数据：userdata（${p_data}）与 metadata（${p_meta}）不格式化" >&2
    else
        gk3__run mkfs.ext4 -q -F -L metadata "$p_meta" || return 1
        gk3__run mkfs.ext4 -q -F -L userdata "$p_data" || return 1
    fi
    # misc 必须是全零：libboot_control 读到坏 CRC 才会初始化一份新的 bootloader_control。
    # ⚠️ 按分区的【实际大小】清零，不按 GK3_MISC_MIB：重新安装时复用的 misc 可能比 4 MiB 小
    #    （本机 1007 KiB）—— 按 4 MiB 写会在写满之后报 No space left，整个安装失败在这一步
    local misc_kib; misc_kib=$(( $(blockdev --getsize64 "$p_misc" 2>/dev/null || echo $(( GK3_MISC_MIB << 20 ))) / 1024 ))
    # conv=nocreat：节点要是在这之前被 udev 删了又没建回来，dd 会在 /dev 里新建一个普通文件、写成功、盘上什么也没有（审查 #4）
    gk3__run dd if=/dev/zero of="$p_misc" bs=1024 count="$misc_kib" conv=fsync,nocreat status=none || return 1
    [ "$rescue" = yes ] && { gk3__run mkfs.ext4 -q -F -L gk3rescue "$p_resc" || return 1; }

    # ── 写 super（30% → 70%，进度由 gk3-unsparse.py 按块推进）──────────
    gk3_prog 30 "写入 super"
    gk3__write_super "$super_src" "$p_super" || return 1

    gk3_prog 70 "写入 boot_a / boot_b"
    gk3__run dd if="$rel/boot.img" of="$p_boota" bs=4M conv=fsync,nocreat status=none || return 1
    gk3__run dd if="$rel/boot.img" of="$p_bootb" bs=4M conv=fsync,nocreat status=none || return 1
    # 写过的节点必须还是块设备 —— 否则上面那些字节进了内存里的一个文件（gk3-unsparse 同理：它会 O_CREAT）
    if [ "$DRY" != 1 ]; then
        local wn
        for wn in "$p_misc" "$p_boota" "$p_bootb" "$p_super"; do
            [ -b "$wn" ] || { gk3_die "$wn 已经不是块设备了 —— 写进去的东西不在盘上（udev 在写盘期间重建了节点？）"; return 1; }
        done
    fi

    # ── 引导链 ──────────────────────────────────────────────────────────
    # ⚠️ 少了这一步，前面所有东西都写对了，机器照样起不来 —— 这台机器是 UEFI，
    #    内核/dtb/ramdisk 是 ESP 上的【普通文件】，不在 boot 分区里被引导。
    #    （boot_a/boot_b 有内容是为了让 update_engine 的 A/B 流程完整。）
    gk3_prog 80 "安装引导链"
    local mid=$esp_mid
    # ⚠️ 挂载点用 mktemp，不用 /mnt/esp —— CLAUDE.md 操作禁忌 4：共享的挂载点
    #    会被另一个 shell 里"顺手看一眼"的人 umount 掉，于是这一步静默失败。
    local mnt; mnt=$(mktemp -d)
    gk3__run mount -t vfat "$p_esp" "$mnt" || return 1
    # 整盘清空：ESP 是刚格式化的，没有现成目录 → 用 machine-id
    [ -n "$mid" ] || mid=$(gk3__esp_pick_mid "$mnt" "$mid_fb")
    # ★ 每一个写 ESP 的动作都查结果（2026-09-26 M4b：ESP 写满，cp 失败被忽略，安装照样报告成功）
    esp_fail() { gk3_die "写 ESP 失败：$1 —— ESP 空间不够，或者介质出了错（${p_esp}）"; umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null; }

    if [ "$DRY" != 1 ]; then
        mkdir -p "$mnt/EFI/BOOT" "$mnt/EFI/systemd" "$mnt/loader/entries" \
                 "$mnt/$mid/android/slot_a" "$mnt/$mid/android/slot_b" || { esp_fail "建目录"; return 1; }
        # ⚠️ 别的 <machine-id> 目录下我们的启动项：default 的通配 *-android-<槽>.conf 会同时匹配它们，
        #   开机走哪个看 systemd-boot 的排序（M4b 那次留下的就是这种局面）。改名停用（systemd-boot 只读 *.conf），不删
        local e
        for e in "$mnt"/loader/entries/*-android-[ab].conf; do
            [ -e "$e" ] || continue
            case "${e##*/}" in "$mid"-android-*) continue ;; esac
            mv "$e" "$e.disabled" || { esp_fail "停用 ${e##*/}"; return 1; }
            echo "停用了另一个目录的启动项 ${e##*/} → ${e##*/}.disabled（默认项的通配会同时匹配它）" >&2
        done
        # --no-variables 那条路的等价物：固件实际走的是可移动介质回落路径
        # EFI/BOOT/BOOTAA64.EFI（内核带 efi=noruntime，不指望 EFI 启动变量）
        #
        # ⚠️ 双系统时这个位置上原本是【别人的】回落引导（Windows 装机会放一份
        #   bootmgfw.efi 的拷贝）。覆盖前留一份 —— 当年手工迁移就是这么做的
        #   （scripts/archive/esp-migrate-to-internal.sh:120-128 的 .bak-windows）。
        #   systemd-boot 会自己认出 EFI/Microsoft/Boot/bootmgfw.efi 并列进菜单，
        #   所以 Windows 照样能进；留这一份是给"想把一切恢复原样"的人。
        #   （FAT 不分大小写：EFI/Boot/bootaa64.efi 就是这个文件。）
        #   只在第一次装时留：重装不能拿我们自己的 systemd-boot 把原件覆盖掉。
        local f
        for f in EFI/BOOT/BOOTAA64.EFI loader/loader.conf; do
            if [ -f "$mnt/$f" ] && [ ! -e "$mnt/$f.before-gaokun3" ] \
               && ! cmp -s "$mnt/$f" "$sdboot"; then
                cp -p "$mnt/$f" "$mnt/$f.before-gaokun3" || { esp_fail "备份 $f"; return 1; }
                echo "原有的 $f 已备份为 $f.before-gaokun3" >&2
            fi
        done
        cp "$sdboot" "$mnt/EFI/BOOT/BOOTAA64.EFI" || { esp_fail "BOOTAA64.EFI"; return 1; }
        cp "$sdboot" "$mnt/EFI/systemd/systemd-bootaa64.efi" || { esp_fail "systemd-bootaa64.efi"; return 1; }
        local slot
        for slot in a b; do
            cp "$parts/Image" "$parts/gaokun3.dtb" "$parts/ramdisk.img" "$mnt/$mid/android/slot_$slot/" || { esp_fail "slot_$slot 的内核 / dtb / ramdisk"; return 1; }
            # 文件名是承重的：boot_control HAL 按 *-android-a.conf / *-android-b.conf
            # 改写 loader.conf 的 default（EspSlot.cpp:41-43）；OTA postinstall 只改
            # options 那一行、只往 slot_<后缀>/ 写这三个文件名。改一边就要改另一边。
            cat > "$mnt/loader/entries/$mid-android-$slot.conf" <<ENTRY || { esp_fail "启动项 $mid-android-$slot.conf"; return 1; }
title      crDroid 16.0 (gaokun3) — slot _$slot
version    gaokun3-slot-$slot
sort-key   zandroid$slot
options    $cmdline androidboot.slot_suffix=_$slot
linux      /$mid/android/slot_$slot/Image
devicetree /$mid/android/slot_$slot/gaokun3.dtb
initrd     /$mid/android/slot_$slot/ramdisk.img
ENTRY
        done

        # Android recovery：发版不带（docs/INSTALL.md），自己编了才有。
        # ⚠️★ 启动项默认【不】建：2026-08-20 实测它在本机进复位循环且不留 panic 记录，
        #   15 秒菜单里误选一次就得有人跑到机器旁按电源键。ramdisk 照样铺（无害）。
        if [ -f "$rel/recovery-ramdisk.img" ]; then
            for slot in a b; do
                cp "$rel/recovery-ramdisk.img" "$mnt/$mid/android/slot_$slot/" || { esp_fail "slot_$slot 的 recovery-ramdisk"; return 1; }
                if [ "${GK3_ENABLE_RECOVERY_ENTRY:-0}" = 1 ]; then
                    sed -e "s|^initrd .*|initrd     /$mid/android/slot_$slot/recovery-ramdisk.img|" \
                        -e "s|^title .*|title      Recovery (gaokun3) — slot _$slot|" \
                        -e "s|^version .*|version    gaokun3-recovery-$slot|" \
                        -e "s|^sort-key .*|sort-key   zzrecovery$slot|" \
                        "$mnt/loader/entries/$mid-android-$slot.conf" \
                        > "$mnt/loader/entries/$mid-recovery-$slot.conf" || { esp_fail "recovery 启动项"; return 1; }
                fi
            done
        fi

        # ★ 默认落点是 slot_a；救援系统装了的话它排在前面（sort-key linux1），
        #   但【不设成 default】—— 默认必须是能用的系统。
        #   （命令行版原先把救援设成 default，理由是"默认落点要能远程接入"。
        #    但 boot_control HAL 在 Android 第一次标记启动成功时就会把 default
        #    改写成 *-android-<槽>.conf（EspSlot.cpp:120-172）—— 那个选择只活到
        #    第一次开机，代价却是每个新用户第一次重启落进一个他不认识的系统。）
        cat > "$mnt/loader/loader.conf" <<LOADER || { esp_fail "loader.conf"; return 1; }
timeout 15
console-mode keep
editor no
default *-android-a.conf
LOADER
        if [ "$rescue" = yes ]; then
            mkdir -p "$mnt/$mid/rescue" || { esp_fail "建救援目录"; return 1; }
            cp "$r_initrd" "$mnt/$mid/rescue/initramfs.img" || { esp_fail "救援系统的 initramfs"; return 1; }
            # ⚠️ 标题用 ASCII：开机菜单由 UEFI 固件的字体画，一般不含中文（原先的"救援系统（Alpine，
            #    全内存）"从没在本机菜单上看过，取稳妥的一侧）。
            # 救援系统与 Android 共用内核与 dtb（docs/stage7-live-installer.md §2.3），
            # 只多一个 initramfs；cmdline 从 Android 那份派生（见 gk3__rescue_cmdline）
            cat > "$mnt/loader/entries/$mid-rescue.conf" <<RESC || { esp_fail "救援启动项"; return 1; }
title      gaokun3 rescue (runs from RAM)
version    gaokun3-rescue
sort-key   linux1
linux      /$mid/android/slot_a/Image
devicetree /$mid/android/slot_a/gaokun3.dtb
initrd     /$mid/rescue/initramfs.img
options    $(gk3__rescue_cmdline "$cmdline")
RESC
        fi
        sync
        for slot in a b; do
            [ -s "$mnt/loader/entries/$mid-android-$slot.conf" ] || { esp_fail "启动项 $mid-android-$slot.conf 是空的"; return 1; }
        done
    else
        echo "DRY: 往 $p_esp 写 systemd-boot、两个 Android 启动项（options=$cmdline …）、内核/dtb/ramdisk" >&2
    fi
    gk3__run umount "$mnt" || { gk3_die "ESP 卸不下来（${p_esp}）—— 写进去的东西可能没落盘"; return 1; }
    rmdir "$mnt" 2>/dev/null || true
    if [ "$DRY" != 1 ]; then
        # ★ 写完逐个核对（cp 没报错不等于文件是全的），从介质读回来
        local -a wl
        mapfile -t wl < <(gk3__esp_files "$mid")
        gk3__verify_on "$p_esp" vfat "${wl[@]}" || return 1
    fi

    # ── 救援系统 ────────────────────────────────────────────────────────
    if [ "$rescue" = yes ]; then
        gk3_prog 92 "写入救援系统"
        local rmnt; rmnt=$(mktemp -d)
        gk3__run mount "$p_resc" "$rmnt" || return 1
        # ★ 每一步都查（2026-09-27 审查：原先全不查，救援系统坏了要等到真要用它的那天才知道；
        #   重新安装时分区刚被格式化过，写失败等于把一个好的救援系统换成了坏的）
        resc_fail() { gk3_die "写救援分区失败：$1（${p_resc}）"; umount "$rmnt" 2>/dev/null; rmdir "$rmnt" 2>/dev/null; }
        local -a rfl=("gaokun3/rescue.squashfs=$r_squash")
        if [ "$DRY" != 1 ]; then
            mkdir -p "$rmnt/gaokun3" || { resc_fail "建目录"; return 1; }
            cp "$r_squash" "$rmnt/gaokun3/rescue.squashfs" || { resc_fail "rescue.squashfs"; return 1; }
            # ⚠️ WiFi 凭据【不打包进镜像】：安装器把用户当前用的那份复制过去，
            #    这样救援系统一开机就能连上同一个网。见 gk3-wifi 的注释。
            #    来源按优先级：发布目录里放的 → 安装器里刚连上的（gk3_wifi_connect 写的）
            #    → 做 U 盘时放在介质上的。
            local wconf
            if wconf=$(gk3__find_file wpa_supplicant.conf "$rel" "$GK3_RUNDIR" /media/gk3/gaokun3); then
                install -Dm600 "$wconf" "$rmnt/gaokun3/wpa_supplicant.conf" || { resc_fail "WiFi 配置"; return 1; }
                rfl+=("gaokun3/wpa_supplicant.conf=$wconf")
                echo "救援系统的 WiFi 配置取自 $wconf" >&2
            else
                echo "警告：没有 WiFi 配置可带给救援系统 —— 它开机后连不上网，只能在机器旁操作" >&2
            fi
            # ★ ssh 公钥同理：公开的 live 镜像不带任何人的公钥，所以从它装出来的救援系统本来
            #   【远程进不去】—— 而远程接入正是救援系统存在的意义。来源按优先级：发布目录里放的
            #   → 安装 U 盘上用户放的 → 正在跑的这个系统自己的（私人构建的镜像带了 --ssh-key）。
            #   救援系统开机时把 /media/gk3/gaokun3/authorized_keys 并进 /root/.ssh（overlay 里的 gk3-ssh-keys）。
            local akeys=""
            akeys=$(gk3__find_file authorized_keys "$rel" /media/gk3/gaokun3) \
                || { [ -s /root/.ssh/authorized_keys ] && akeys=/root/.ssh/authorized_keys; } || true
            if [ -n "$akeys" ]; then
                install -Dm600 "$akeys" "$rmnt/gaokun3/authorized_keys" || { resc_fail "ssh 公钥"; return 1; }
                rfl+=("gaokun3/authorized_keys=$akeys")
                echo "救援系统的 ssh 公钥取自 ${akeys}（$(grep -c '^ssh-\|^ecdsa-' "$akeys") 把）" >&2
            else
                echo "警告：没有 ssh 公钥可带给救援系统 —— 只能在机器旁登录（放一份到 U 盘的 gaokun3/authorized_keys）" >&2
            fi
            sync
        fi
        gk3__run umount "$rmnt" || { gk3_die "救援分区卸不下来（${p_resc}）"; return 1; }
        rmdir "$rmnt" 2>/dev/null || true
        if [ "$DRY" != 1 ]; then
            gk3__verify_on "$p_resc" ext4 "${rfl[@]}" || return 1
        fi
    fi

    rm -rf "$parts"
    gk3_prog 100 "完成"
    return 0
}

# 在几个目录里按顺序找一个文件，找到就打印完整路径。空目录参数跳过。
gk3__find_file() {
    local name=$1 d; shift
    for d in "$@"; do
        [ -n "$d" ] || continue
        [ -f "$d/$name" ] && { echo "$d/$name"; return 0; }
    done
    return 1
}

# 写 super。输入是 .zst（发版产物）或 super.img（sparse 或 raw）。
# ⚠️ 不用 simg2img：它喂管道会失败（理由见 gk3-unsparse.py 文件头），
#    而 .zst 要么走管道、要么先落一份临时文件 —— 12 GiB 的 tmpfs 我们没有。
gk3__write_super() {
    local src=$1 dst=$2
    if [ "${GK3_DRYRUN:-0}" = 1 ]; then echo "DRY: 展开 $src → ${dst}（gk3-unsparse.py）"; return 0; fi
    local us="$GK3_LIBDIR/gk3-unsparse.py"
    case "$src" in
        *.zst)
            # ⚠️ 两段的退出码都要看（CLAUDE.md 运维坑 1：只看管道尾巴会漏）。
            #    下载断在一半的 .zst → zstd 报错且提前 EOF → unsparse 也报错；
            #    反过来 unsparse 先死时 zstd 会吃 SIGPIPE。
            #    --long=31 只是放宽解压时允许的窗口上限，不多占内存（release.sh 用 -19 --long 压）。
            zstd -dc --long=31 "$src" | python3 "$us" --progress 30 40 "$dst"
            local -a rc=( "${PIPESTATUS[@]}" )
            if [ "${rc[0]}" != 0 ] || [ "${rc[1]}" != 0 ]; then
                gk3_die "super 写入失败（zstd=${rc[0]} gk3-unsparse=${rc[1]}）—— .zst 下载完整吗？"
                return 1
            fi ;;
        *)
            if head -c4 "$src" | od -An -tx1 | tr -d ' \n' | grep -qi '^3aff26ed$'; then
                python3 "$us" --progress 30 40 "$dst" < "$src" || { gk3_die "super 展开失败"; return 1; }
            else
                echo "super.img 不是 sparse 格式，直接写" >&2
                dd if="$src" of="$dst" bs=4M conv=fsync,nocreat status=none || { gk3_die "dd super 失败"; return 1; }
            fi ;;
    esac
    # ★ 判格式不判校验和：偏移 4096 处必须是 LP geometry 魔数。
    #   ⚠️ 命令行版一直有这道检查（install-gaokun3.sh 原 :131-132），这个库里漏了。
    #      dd 了 sparse 镜像的 super "看着字节都对"却没有 LP 元数据，
    #      Android 首阶段挂载失败后主动 reboot()，不留任何日志（docs/stage2-findings.md §1）。
    local lp; lp=$(dd if="$dst" bs=1 skip=4096 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ "$lp" != "67446c61" ]; then
        gk3_die "super 偏移 4096 处不是 LP geometry 魔数（读到 '${lp}'）—— 写进去的不是一份能用的 super"
        return 1
    fi
    echo "super：LP geometry 魔数正确" >&2
}

# 救援系统的 cmdline：从 Android 那份（boot.img 里的 BOARD_KERNEL_CMDLINE）派生，
# 去掉只给 Android 用的参数，再加上救援 initramfs 自己的。
# ★ 不另抄一份：原先手抄的那份缺 usbhid.quirks（键盘盖）和 himax disable_pressure=0 ——
#   和 Android 那份（TODO B15）是同一种漂移。
gk3__rescue_cmdline() {
    local keep
    keep=$(printf '%s\n' "$1" | tr ' ' '\n' \
           | grep -v -e '^androidboot\.' -e '^init=' -e '^firmware_class\.path=' -e '^$' \
           | tr '\n' ' ')
    echo "${keep}loglevel=4 panic=10 gk3.squash=/gaokun3/rescue.squashfs"
}

# 解析分区节点，解析不出来就直接失败。
# dry-run 时分区还不存在，回一个明显是占位的名字，好让打印出来的命令可读。
gk3__need_part() {
    local disk=$1 want=$2 mode=$3 path
    if [ "${GK3_DRYRUN:-0}" = 1 ]; then echo "<${want}分区>"; return 0; fi
    path=$(gk3__bylabel "$disk" "$want")
    if [ -z "$path" ]; then
        gk3_die "分区 $want 没解析出来（$disk 上找不到这个 PARTLABEL）"; return 1
    fi
    # ⚠️ 分区节点的出现是异步的（udev / devtmpfs），刚写完分区表时它可能还没到。
    #    第一版在这里直接判死，结果 loop 设备实测必然失败 —— 而 lsblk 明明
    #    看得见分区。**"还没出现"和"不存在"是两回事**：等它，别判它死。
    local i=0
    while [ ! -b "$path" ] && [ $i -lt 50 ]; do
        [ $i -eq 0 ] && command -v udevadm >/dev/null && udevadm settle --timeout=5 2>/dev/null
        sleep 0.2; i=$((i+1))
    done
    if [ ! -b "$path" ]; then
        gk3_die "$path 等了 10 秒还不是块设备 —— 分区表写下去了但内核没认"; return 1
    fi
    gk3__node_matches "$disk" "$path" || return 1
    echo "$path"
}

# 从一行 key=value 里取值
gk3__f() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
}

# 按 PARTLABEL 找分区节点。⚠️ 不用 /dev/disk/by-partlabel —— 救援系统里
# 没有 udev 规则时那个目录可能不存在；直接问 sgdisk 才是确定的。
gk3__bylabel() {
    local disk=$1 want=$2 n
    for n in $(sgdisk -p "$disk" 2>/dev/null | awk '/^ *[0-9]+ /{print $1}'); do
        if [ "$(sgdisk -i "$n" "$disk" 2>/dev/null | grep "^Partition name:" | cut -d"'" -f2)" = "$want" ]; then
            gk3_partpath "$disk" "$n"; return 0
        fi
    done
    echo ""
}

# ── 缩分区 ──────────────────────────────────────────────────────────────────
#
# ★ 这是安装器里【唯一会去动用户现有数据】的操作，纪律高于别处：
#
#   1. 最小能缩到多少【问文件系统】，不自己猜（ntfsresize --info / resize2fs -P）
#   2. NTFS 必须是干净卸载的。ntfsresize 自己会拒绝带 dirty 位的卷 ——
#      **不要绕过它**。脏 NTFS 缩 = 数据损坏，而用户往往是因为 Windows
#      快速启动/休眠才脏的，他自己都不知道盘是脏的。
#   3. 先演练通过，再真做
#   4. **先缩文件系统，再缩分区**。反了就是把文件系统截断 —— 直接丢数据
#   5. 重建分区时保住 PARTUUID：Windows 的 BCD 按 PARTUUID 找系统盘，
#      换了它 Windows 就起不来（分区还在、数据还在，但引导指向不存在的 UUID）

# ── NTFS：Windows 休眠 / 快速启动 / 没关干净 ─────────────────────────────────
# ⚠️★ 2026-09-27 审查查出、按 ntfs-3g 2022.10.3（packages-live.lock 里那一版）的源码核实：
#   * ntfsresize【看不出】Windows 在休眠（快速启动的"关机"也是休眠，而它默认开着）：它按 NTFS_MNT_FORENSIC
#     打开卷（ntfsprogs/ntfsresize.c:2888），这个标志正好跳过休眠与 $LogFile 两项检查（libntfs-3g/volume.c:1286）
#   * 原先还给 --info / --no-action 加了 --force —— 而脏卷那一道一个 --force 就放行（ntfsresize.c:2946-2948）；
#     真做时的 --force --force 再喂一个 y，连"确认"（ntfsresize.c:4656）一起替用户答了
#   这样的卷缩了，Windows 醒来时它缓存里的元数据与盘上对不上 = 损坏。上面"不要绕过它"那条纪律，代码自己没守住。
#   现在：只读的探测看 hiberfil.sys（与 ntfs-3g 自己的判据相同，volume.c:832-833）+ 不带 --force 的 --info；
#   真动手之前再让 ntfs-3g 读写挂一次（它做全套检查，挂成只读 = 不安全）；ntfsresize 只给一个 --force，stdin 接 /dev/null。

# hiberfil.sys 开头是 hibr / HIBR ⇒ Windows 休眠着。ntfscat 只读打开卷，不写任何东西
gk3__ntfs_hibernated() {
    case "$(ntfscat "$1" /hiberfil.sys 2>/dev/null | head -c 4 | od -An -tx1 | tr -d ' \n')" in
        68696272|48494252) return 0 ;;    # "hibr" / "HIBR"
    esac
    return 1
}

# 动手之前的终审：让 ntfs-3g 按读写挂一次再卸下 —— 休眠与 $LogFile 没关干净这两项它都查，判据就是库里那一套。
# ⚠️ 判据是"挂成了只读"，不是退出码：读写挂载默认带 NTFS_MNT_MAY_RDONLY（src/ntfs-3g.c:4031-4033），
#    卷不安全时它【退回只读、照样返回 0】（libntfs-3g/volume.c:1286-1315 的 need_fallback_ro）。
# ⚠️ norecover：不加的话，$LogFile 没关干净时它会"修好"—— 清空日志（volume.c:1296-1302）。这正是要避免的写入。
# no_detach：让它在前台跑，卸下之后 wait 它 —— 它把卷真正关好之前，不能让 ntfsresize 去开同一个设备
gk3__ntfs_trial_mount() {
    local part=$1 m pid rc i opts=""
    m=$(mktemp -d)
    ntfs-3g -o no_detach,norecover "$part" "$m" 2>/dev/null &
    pid=$!
    for i in $(seq 1 100); do
        findmnt -rn "$m" >/dev/null 2>&1 && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if findmnt -rn "$m" >/dev/null 2>&1; then
        opts=$(findmnt -rn -o OPTIONS "$m")
        umount "$m" 2>/dev/null || fusermount3 -u "$m" 2>/dev/null || fusermount -u "$m" 2>/dev/null
    fi
    wait "$pid"; rc=$?
    rmdir "$m" 2>/dev/null
    if [ "$rc" = 0 ] && [ -n "$opts" ]; then
        case ",$opts," in
            *,rw,*) return 0 ;;
        esac
        # 退回了只读 = 不安全。是哪一种：自己再看一眼 hiberfil.sys（只读）
        if gk3__ntfs_hibernated "$part"; then rc=14; else rc=15; fi
    fi
    case "$rc" in
        14) gk3_die "Windows 处于休眠或“快速启动”状态（${part}）—— 这时改它的大小会损坏 Windows 的数据。回 Windows 关掉快速启动、用“关机”退出，再试（盘没动过）" ;;
        15) gk3_die "这个 NTFS 分区上次没有正常关机（${part}，日志里有没做完的操作）—— 回 Windows 正常开关机一次，再试（盘没动过）" ;;
        *)  gk3_die "ntfs-3g 挂不上 ${part}（退出码 ${rc}）—— 不敢改它的大小（盘没动过）" ;;
    esac
    return 1
}

# 问文件系统"最小能缩到多少 MiB"。问不出来就报 can=no —— 不猜。
gk3_shrink_info() {
    local part=$1 fs cur_mib min_mib can why out b bs blocks
    if [ ! -b "$part" ]; then
        echo "SHRINK part=$part can=no why=not-a-block-device"; return 1
    fi
    fs=$(blkid -o value -s TYPE "$part" 2>/dev/null)
    cur_mib=$(( $(blockdev --getsize64 "$part" 2>/dev/null || echo 0) / 1048576 ))
    can=no; why=""; min_mib=""
    # ⚠️ 挂着的分区一律不缩 —— 首先是安装器自己所在的那个（live 从内置盘跑时，它就在目标盘上：
    #    免 U 盘装双系统正是这种情况）。ntfsresize 本来也拒绝挂着的卷，resize2fs 对挂着的 ext4
    #    缩小会失败，但【先问、先说清楚】比让工具半路报错好。
    if findmnt -rn -S "$part" >/dev/null 2>&1; then
        echo "SHRINK part=$part fs=${fs:-none} cur_mib=$cur_mib min_mib=0 can=no why=mounted"; return 1
    fi
    case "$fs" in
        ntfs)
            if ! command -v ntfsresize >/dev/null; then
                why=no-ntfsresize
            elif gk3__ntfs_hibernated "$part"; then
                why=ntfs-hibernated
            else
                # ⚠️ 不加 --force：它就是脏卷检查的开关（见上面"NTFS：Windows 休眠"那一段）
                out=$(ntfsresize --info "$part" 2>&1)
                if [ $? -ne 0 ]; then
                    # ⚠️ 最常见的原因是卷脏（Windows 快速启动/休眠）。
                    #    这不是该绕过的错误，是该转达给用户的错误。
                    # 脏卷时 ntfsresize 的原话是 "Volume is scheduled for check"（ntfsresize.c:2948）
                    case "$out" in
                        *"scheduled for check"*|*dirty*|*Dirty*|*unclean*)  why=ntfs-dirty ;;
                        *"resize support"*)         why=ntfs-unsupported ;;
                        *)                          why=ntfsresize-failed ;;
                    esac
                else
                    b=$(printf '%s' "$out" | grep -o 'You might resize at [0-9]* bytes' | grep -o '[0-9]*')
                    if [ -n "$b" ]; then
                        min_mib=$(( b / 1048576 + 1 )); can=yes
                    else
                        why=cannot-parse-min
                    fi
                fi
            fi ;;
        ext2|ext3|ext4)
            if ! command -v resize2fs >/dev/null; then
                why=no-resize2fs
            else
                bs=$(dumpe2fs -h "$part" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')
                blocks=$(resize2fs -P "$part" 2>/dev/null | grep -o '[0-9]*$')
                if [ -n "$bs" ] && [ -n "$blocks" ]; then
                    min_mib=$(( blocks * bs / 1048576 + 1 )); can=yes
                else
                    why=cannot-parse-min
                fi
            fi ;;
        "") why=no-filesystem ;;
        *)  why=fs-not-shrinkable ;;
    esac
    echo "SHRINK part=$part fs=${fs:-none} cur_mib=$cur_mib min_mib=${min_mib:-0} can=$can why=$why"
    [ "$can" = yes ]
}

# 真的缩。$2 是目标大小（MiB）。
# ⚠️ 这个函数会改用户的数据，所以它自己把所有前提再验一遍，不依赖调用方。
gk3_shrink() {
    local part=$1 target_mib=$2
    local info fs cur min floor disk num pu pl pt start end bk newpu newmib rc
    info=$(gk3_shrink_info "$part") || { echo "$info"; return 1; }
    fs=$(gk3__f "$info" fs); cur=$(gk3__f "$info" cur_mib); min=$(gk3__f "$info" min_mib)

    # 余量：至少给文件系统留 512 MiB。缩到贴着最小值，用户开机就没地方
    # 写页面文件了 —— 那是"能装上但不能用"。
    floor=$(( min + 512 ))
    if [ "$target_mib" -lt "$floor" ]; then
        gk3_die "目标 ${target_mib} MiB 太小：最小 ${min} + 512 余量 = ${floor} MiB"; return 1
    fi
    if [ "$target_mib" -ge "$cur" ]; then
        gk3_die "目标 ${target_mib} MiB 不小于当前 ${cur} MiB，没必要缩"; return 1
    fi

    disk=/dev/$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
    num=$(cat "/sys/class/block/$(basename "$part")/partition" 2>/dev/null)
    if [ ! -b "$disk" ] || [ -z "$num" ]; then
        gk3_die "认不出 $part 属于哪块盘的第几个分区"; return 1
    fi

    # ★ 保住身份：PARTUUID（Windows BCD 靠它）、PARTLABEL、类型 GUID
    pu=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition unique GUID:' | awk '{print $4}')
    pl=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition name:' | cut -d"'" -f2)
    pt=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition GUID code:' | awk '{print $4}')
    if [ -z "$pu" ] || [ -z "$pt" ]; then
        gk3_die "读不到分区 $num 的 GUID —— 不敢重建它"; return 1
    fi
    local pattr; pattr=$(gk3__part_attr "$disk" "$num")
    echo "分区 $num 身份：PARTUUID=$pu 类型=$pt 名字=${pl:-(无)} 属性=${pattr:-?}" >&2

    gk3_prog 5 "备份分区表"
    gk3__gpt_backup "$disk" shrink; bk=${GK3_GPT_BK:-（没有备份）}

    # ── 第 1 步：缩文件系统（演练 → 真做）───────────────────────────────
    gk3_prog 15 "演练缩小文件系统"
    case "$fs" in
        ntfs)
            gk3__ntfs_trial_mount "$part" || return 1
            if ! ntfsresize --no-action --size "${target_mib}M" "$part" >/dev/null 2>&1 </dev/null; then
                gk3_die "ntfsresize 演练没通过 —— 不往下做"; return 1
            fi
            gk3_prog 30 "缩小 NTFS"
            # 一个 --force = 替用户答"确认"那一问（ntfsresize.c:4656）。脏卷的话它先被脏卷检查吃掉，
            # 确认那一问就会去读 stdin —— 接的是 /dev/null，于是停下。别再喂 y
            if ! ntfsresize --force --size "${target_mib}M" "$part" >/dev/null 2>&1 </dev/null; then
                gk3_die "缩小 NTFS 失败 —— 分区表还没动过，数据应当完好"; return 1
            fi ;;
        ext2|ext3|ext4)
            gk3_prog 20 "检查文件系统（resize2fs 要求）"
            e2fsck -fp "$part" >/dev/null 2>&1; rc=$?
            # e2fsck 返回 1/2 表示"修好了"；>=4 才是真出事
            if [ "$rc" -ge 4 ]; then
                gk3_die "e2fsck 报错（${rc}），不敢缩"; return 1
            fi
            gk3_prog 30 "缩小 ext 文件系统"
            if ! resize2fs "$part" "${target_mib}M" >/dev/null 2>&1; then
                gk3_die "resize2fs 失败 —— 分区表还没动过"; return 1
            fi ;;
        *) gk3_die "不支持缩 $fs"; return 1 ;;
    esac

    # ── 第 2 步：缩分区（文件系统已经小了，这一步才安全）────────────────
    gk3_prog 70 "改分区表"
    start=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^First sector:' | awk '{print $3}')
    if [ -z "$start" ]; then
        gk3_die "读不到分区 $num 的起始扇区"; return 1
    fi
    end=$(( start + target_mib * 2048 - 1 ))
    if ! sgdisk -d "$num" "$disk" >/dev/null 2>&1; then
        gk3_die "删旧分区项失败"; return 1
    fi
    if ! sgdisk -n "${num}:${start}:${end}" -t "${num}:${pt}" -u "${num}:${pu}" "$disk" >/dev/null 2>&1; then
        gk3_die "重建分区项失败 —— 分区表备份在 $bk"; return 1
    fi
    # 分区名丢了的话 by-name 找不到它（userdata / metadata 丢了名字，以后重新安装就找不到）
    if [ -n "$pl" ] && ! sgdisk -c "${num}:${pl}" "$disk" >/dev/null 2>&1; then
        gk3_die "分区名 $pl 没写回去 —— 分区表备份在 $bk"; return 1
    fi
    gk3__part_attr_restore "$disk" "$num" "$pattr" || return 1
    gk3__settle "$disk"

    # ── 第 3 步：验 ─────────────────────────────────────────────────────
    gk3_prog 90 "复核"
    newpu=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition unique GUID:' | awk '{print $4}')
    if [ "$newpu" != "$pu" ]; then
        gk3_die "PARTUUID 变了（$pu -> ${newpu}）—— Windows 会起不来"; return 1
    fi
    newmib=$(( $(blockdev --getsize64 "$part" 2>/dev/null || echo 0) / 1048576 ))
    [ "$newmib" = "$target_mib" ] \
        || { gk3_die "分区 $num 现在是 ${newmib} MiB，不是要的 ${target_mib} MiB（内核没看到新分区表？）—— 文件系统已缩到 ${target_mib} MiB，数据完好；重启后看一眼"; return 1; }
    echo "分区 ${num}：${cur} MiB -> ${newmib} MiB（PARTUUID 未变）" >&2
    gk3_prog 100 "缩小完成"
    return 0
}

# ── 网络 ────────────────────────────────────────────────────────────────────
#
# ⚠️ 这台机器【只有 WiFi】。所以"配网"不是可选步骤 —— 网络安装、下载变体、
#    甚至装完之后的远程救援，全都压在这一条链上。
#
# 走 wpa_supplicant 的控制接口（wpa_cli），不自己解析 iw scan：
# 连接状态、密码错、DHCP 有没有拿到地址，wpa_supplicant 都已经知道了，
# 自己再实现一遍只会实现出一个不一致的版本。

GK3_WPA_CTRL=/run/wpa_supplicant
# 连上之后那份配置放这里（gk3_apply 从这里捡去装进救援分区）；测试换成临时目录
GK3_RUNDIR=${GK3_RUNDIR:-/run/gaokun3}

# 无线网卡的名字。给了 GK3_WIFI_IF 就用它；否则 wlan0 —— live/rescue 镜像屏蔽了 systemd 的可预测命名
# （overlay 的 /etc/systemd/network/99-default.link → /dev/null）；再否则认第一块有 wireless/ 的网卡。
# ⚠️ 不能写死 wlan0：M0 第一轮（2026-09-25）Debian 的 systemd-udevd 把它改名成了 wlP6p1s0，
#    于是 gk3-wifi 以为 ath11k 没起来。每次调用现查（网卡可能在 source 之后才出现，比如重绑之后）。
gk3__wifi_if() {
    local n
    [ -n "${GK3_WIFI_IF:-}" ] && { echo "$GK3_WIFI_IF"; return; }
    [ -e /sys/class/net/wlan0 ] && { echo wlan0; return; }
    for n in /sys/class/net/*; do [ -d "$n/wireless" ] && { echo "${n##*/}"; return; }; done
    echo wlan0
}

# 确保 wlan0 起来、wpa_supplicant 在跑且带控制接口。
gk3_wifi_up() {
    local ifc; ifc=$(gk3__wifi_if)
    if [ ! -e "/sys/class/net/$ifc" ]; then
        gk3_die "没有 $ifc —— ath11k 没起来（看 dmesg | grep ath11k）"; return 1
    fi
    ip link set "$ifc" up 2>/dev/null
    if wpa_cli -i "$ifc" -p "$GK3_WPA_CTRL" status >/dev/null 2>&1; then
        return 0    # 已经在跑
    fi
    # 起一个只带控制接口的实例，网络等下用 wpa_cli 加
    local cfg=/tmp/gk3-wpa.conf
    printf 'ctrl_interface=%s\nupdate_config=1\n' "$GK3_WPA_CTRL" > "$cfg"
    wpa_supplicant -B -i "$ifc" -c "$cfg" >/dev/null 2>&1
    local i=0
    while ! wpa_cli -i "$ifc" -p "$GK3_WPA_CTRL" status >/dev/null 2>&1; do
        i=$((i+1)); [ "$i" -gt 20 ] && { gk3_die "wpa_supplicant 起不来"; return 1; }
        sleep 0.5
    done
}

# 扫描。输出（字段含义见 gk3-wpa-scan.py 的文件头），按信号从强到弱：
#   WIFI signal=<dBm> secure=yes|no auth=open|owe|wep|psk|sae|eap ssid_hex=<原始字节> ssid=<已编码>
# ★ 解析交给 gk3-wpa-scan.py：wpa_supplicant 把 32–126 以外的字节都转成 \xNN
#   （中文 SSID 全是转义串），且 scan_results 是制表符分隔的 —— 原先的 awk 按
#   任意空白切、再用单空格拼回，"My  Net" 会变成 "My Net"，于是连不上。
gk3_wifi_scan() {
    gk3_wifi_up || return 1
    local ifc; ifc=$(gk3__wifi_if)
    wpa_cli -i "$ifc" -p "$GK3_WPA_CTRL" scan >/dev/null 2>&1
    sleep 3
    wpa_cli -i "$ifc" -p "$GK3_WPA_CTRL" scan_results 2>/dev/null \
        | python3 "$GK3_LIBDIR/gk3-wpa-scan.py"
}

# 连接。$1=SSID（或 hex:<gk3_wifi_scan 给的 ssid_hex>）$2=密码（空 = 开放网络）
#       $3=hidden：隐藏网络（不广播 SSID，扫描列表里没有它，用户手输名字）
#
# ★ 隐藏网络要网络块里的 scan_ssid=1（加全局的 ap_scan=1 —— 那是默认值，我们没改它）：
#   Debian wpasupplicant 2.10-24 的 README.Debian:521-523。它让 wpa_supplicant 发带这个 SSID 的探测请求，
#   不广播的 AP 才会应答。连上之后存下来的配置也要带上，否则装好的救援系统一开机又找不到它。
#
# ★ 优先用 hex:<…>。wpa_supplicant 的网络配置里，不带引号的 SSID 就是十六进制
#   （wpa-2.10 src/utils/common.c:679-686）—— 任意字节都不会被引号、空格、
#   转义搞坏，中文 / GBK 编码的 SSID 也一样。
# ★ 连上之后把这份配置写到 $GK3_RUNDIR/wpa_supplicant.conf：gk3_apply 会把它
#   装进救援分区，于是装好的救援系统一开机就能连上同一个网 —— 否则就是
#   "救援起来了但网没起来 = 一台连不上的机器"（docs/stage7-live-installer.md:200-202）。
gk3_wifi_connect() {
    local ssid=$1 psk=${2:-} hidden=${3:-} ssid_cfg show
    case "$hidden" in ''|hidden) ;; *) gk3_die "第三个参数只能是 hidden：$hidden"; return 1 ;; esac
    case "$ssid" in
        hex:*) ssid_cfg=${ssid#hex:}
               case "$ssid_cfg" in ''|*[!0-9a-fA-F]*) gk3_die "SSID 的十六进制写法不对：$ssid_cfg"; return 1 ;; esac
               [ $(( ${#ssid_cfg} % 2 )) = 0 ] || { gk3_die "SSID 的十六进制长度是奇数"; return 1; }
               # 802.11 的 SSID 最长 32 字节（手输的隐藏网络名可能超 —— 中文一个字就 3 字节）
               [ ${#ssid_cfg} -le 64 ] || { gk3_die "网络名最长 32 字节，这个是 $(( ${#ssid_cfg} / 2 )) 字节"; return 1; }
               show="所选网络" ;;
        *)     ssid_cfg="\"$ssid\""; show=$ssid ;;
    esac
    # ⚠️ 长度不对时 wpa_supplicant 直接拒绝（wpa_supplicant/config.c:571，要 8–63 个字符）。
    #    原先这里把 set_network 的返回值扔掉了，于是密码太短要白等 20 秒超时，
    #    然后报"密码错？信号弱？"—— 一个本可以立刻说清楚的错误。
    if [ -n "$psk" ] && { [ ${#psk} -lt 8 ] || [ ${#psk} -gt 63 ]; }; then
        gk3_die "WiFi 密码要 8–63 个字符，这个是 ${#psk} 个"; return 1
    fi
    gk3_wifi_up || return 1
    local ifc W; ifc=$(gk3__wifi_if)
    W="wpa_cli -i $ifc -p $GK3_WPA_CTRL"
    local id
    id=$($W add_network 2>/dev/null | tail -1)
    case "$id" in ''|*[!0-9]*) gk3_die "add_network 失败"; return 1 ;; esac
    [ "$($W set_network "$id" ssid "$ssid_cfg" 2>/dev/null | tail -1)" = OK ] \
        || { gk3_die "wpa_supplicant 不接受这个 SSID"; return 1; }
    if [ -n "$psk" ]; then
        [ "$($W set_network "$id" psk "\"$psk\"" 2>/dev/null | tail -1)" = OK ] \
            || { gk3_die "wpa_supplicant 不接受这个密码（含控制字符？）"; return 1; }
    else
        $W set_network "$id" key_mgmt NONE >/dev/null 2>&1
    fi
    if [ -n "$hidden" ]; then
        [ "$($W set_network "$id" scan_ssid 1 2>/dev/null | tail -1)" = OK ] \
            || { gk3_die "wpa_supplicant 不接受 scan_ssid"; return 1; }
    fi
    $W enable_network "$id" >/dev/null 2>&1
    $W select_network "$id" >/dev/null 2>&1

    gk3_prog 20 "正在连接 $show"
    local i=0 st
    while [ "$i" -lt 40 ]; do
        st=$($W status 2>/dev/null | sed -n 's/^wpa_state=//p')
        case "$st" in
            COMPLETED) break ;;
            # ⚠️ 密码错的表现是反复回到 SCANNING/DISCONNECTED，不会有明确报错。
            #    所以只能靠超时判断 —— 这一点要在界面上说清楚。
            *) : ;;
        esac
        i=$((i+1)); sleep 0.5
    done
    [ "$st" = COMPLETED ] || { gk3_die "连不上 ${show}（密码错？信号弱？）"; return 1; }

    gk3_prog 60 "取 IP 地址"
    dhcpcd -n "$ifc" >/dev/null 2>&1 || dhcpcd "$ifc" >/dev/null 2>&1
    i=0
    while [ "$i" -lt 30 ]; do
        ip -4 addr show "$ifc" 2>/dev/null | grep -q 'inet ' && break
        i=$((i+1)); sleep 0.5
    done
    ip -4 addr show "$ifc" 2>/dev/null | grep -q 'inet ' \
        || { gk3_die "连上了但没拿到 IP（DHCP 没响应？）"; return 1; }
    # 存一份给 gk3_apply 装进救援分区（0600：里面是明文密码，和原先
    # "把用户当前用的那份 wpa_supplicant.conf 复制过去"是同一个设计）
    ( umask 077; mkdir -p "$GK3_RUNDIR"
      { echo "ctrl_interface=$GK3_WPA_CTRL"
        echo "update_config=1"
        echo "network={"
        echo "	ssid=$ssid_cfg"
        [ -z "$hidden" ] || echo "	scan_ssid=1"
        if [ -n "$psk" ]; then echo "	psk=\"$psk\""; else echo "	key_mgmt=NONE"; fi
        echo "}"; } > "$GK3_RUNDIR/wpa_supplicant.conf" ) 2>/dev/null || true
    gk3_prog 100 "已连接"
    gk3_net_status
}

gk3_net_status() {
    local ifc ip4 ssid; ifc=$(gk3__wifi_if)
    ip4=$(ip -4 addr show "$ifc" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
    ssid=$(wpa_cli -i "$ifc" -p "$GK3_WPA_CTRL" status 2>/dev/null | sed -n 's/^ssid=//p')
    echo "NET if=$ifc ip=${ip4:-none} ssid=$(gk3__enc "${ssid:-none}") online=$([ -n "$ip4" ] && echo yes || echo no)"
}

# ── 网络安装 ────────────────────────────────────────────────────────────────
#
# ⚠️ 变体是【构建期】决定的：KSU 要编进内核、GApps 要进 super。
#    安装器只是"挑一个已经构建好的镜像下载"，不是在设备上组装。
#    清单托管在 R2（和 OTA 用同一套布局）。
#
# 清单格式（一行一个变体，值按协议百分号编码）：
#   VARIANT id=stock name=标准版 desc=... base=https://ota.072172.xyz/install/<VER>/ size_mib=...
# ★ base= 指向一个【发布目录】，就是 release.sh 已经在传的那套 R2 布局
#   install/<VER>/{boot.img, super.img.zst, install-artifacts.sha256}
#   （scripts/release.sh:154-172）—— 不另打包，也就不会有第二份可能漂的东西。

GK3_MANIFEST_URL=${GK3_MANIFEST_URL:-https://ota.072172.xyz/installer/variants.txt}
# 介质上的变体清单（同一格式）：有就先列它 —— 局域网里的镜像（一次下载、装多台）、自建源、离线环境里的测试。
# 2026-09-27 加：网络安装在真机上的第一次实测，就是用它把开发机当下载源
GK3_LOCAL_MANIFEST=${GK3_LOCAL_MANIFEST:-/media/gk3/gaokun3/variants.txt}
# 设备"系统更新"读的那份（release.sh 每次发版都更新它）—— 变体清单取不到时从它推出"最新发布"
GK3_OTA_JSON_URL=${GK3_OTA_JSON_URL:-https://ota.072172.xyz/ota/gaokun3.json}

# ⚠️★ 2026-09-25 真机：variants.txt 还【没发布过】（要等发版流程生成它，404）—— 网络安装在版本页必然
#    "无法获取版本列表"。退回 OTA 清单：它一定在（设备天天读），且安装文件就在同一个桶的
#    install/<zip 名去掉 .zip>/（release.sh 同一次上传，scripts/release.sh:154-172）。
gk3_net_manifest() {
    local url=${1:-$GK3_MANIFEST_URL} out local_n=0
    command -v curl >/dev/null || { gk3_die "没有 curl"; return 1; }
    if [ -f "$GK3_LOCAL_MANIFEST" ]; then
        local_n=$(grep -c '^VARIANT ' "$GK3_LOCAL_MANIFEST")
        echo "介质上的变体清单 ${GK3_LOCAL_MANIFEST}：$local_n 个" >&2
        grep '^VARIANT ' "$GK3_LOCAL_MANIFEST"
    fi
    if out=$(curl -fsSL --max-time 30 "$url" 2>/dev/null) && printf '%s\n' "$out" | grep -q '^VARIANT '; then
        printf '%s\n' "$out" | grep '^VARIANT '; return 0
    fi
    echo "变体清单取不到（${url}）—— 退回 OTA 清单 $GK3_OTA_JSON_URL" >&2
    gk3__ota_variant && return 0
    # 线上两份都取不到：介质上有就够了（局域网 / 离线），否则才算失败
    [ "$local_n" -gt 0 ] && return 0
    gk3_die "取不到版本列表：变体清单（${url}）与 OTA 清单（${GK3_OTA_JSON_URL}）都不可用"; return 1
}

# 从 OTA 清单推出一个变体（latest=yes）：名字取版本号，大小用 HEAD 量（安装文件的 Content-Length 之和）
gk3__ota_variant() {
    local js line name ver host base size=0 f n
    js=$(curl -fsSL --max-time 30 "$GK3_OTA_JSON_URL" 2>/dev/null) || { echo "OTA 清单取不到" >&2; return 1; }
    # ⚠️ 用 | 分隔：版本号可能是空的，按空格 read 会让后面的字段整体串位
    line=$(printf '%s' "$js" | python3 -c 'import json, sys, urllib.parse as u
r = json.load(sys.stdin)["response"][0]; d = u.urlsplit(r["download"])
print("|".join([r["filename"].removesuffix(".zip"), str(r.get("version", "")), d.scheme + "://" + d.netloc]))' 2>/dev/null) \
        || { echo "OTA 清单解析不了" >&2; return 1; }
    IFS='|' read -r name ver host <<EOF
$line
EOF
    [ -n "$name" ] && [ -n "$host" ] || { echo "OTA 清单里没有最新版本" >&2; return 1; }
    base=$host/install/$name/
    curl -fsI --max-time 30 "${base}install-artifacts.sha256" >/dev/null 2>&1 \
        || { echo "最新版本 $name 在 $base 下没有安装文件" >&2; return 1; }
    for f in boot.img super.img.zst; do
        n=$(curl -fsI --max-time 30 "$base$f" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" {print $2}' | tail -1)
        size=$(( size + ${n:-0} ))
    done
    echo "VARIANT id=latest name=$(gk3__enc "crDroid ${ver:-$name}") desc= base=$base size_mib=$(( size / 1048576 )) latest=yes"
}

# curl 的进度表 → PROGRESS 行（百分比变了才出一行）。$1=起点 $2=跨度 $3=文件名
# ⚠️★ 2026-09-27 真机网络安装：原先是 tr '\r' '\n' | awk —— 1.2 GiB 下了两分半，进度一行也没出来，结束时才一起吐
#   （屏幕上的进度条停在 5%、最后跳到 95%）。tr 往管道写是块缓冲的；换成 awk 自己按 \r 切也不行：
#   mawk（Debian 的默认 awk）读管道同样攒块，实测三行进度全在最后一刻出来（-W interactive 又只认 \n）。
#   bash 的 read 从管道逐字节读，读到一条就处理一条。curl 每次刷新是 "\r<一行>"，表头与最后一行带 \n
gk3__curl_meter() {
    local lo=$1 sp=$2 n=$3 rec line pct last=0
    while IFS= read -r -d $'\r' rec || [ -n "$rec" ]; do
        while IFS= read -r line; do
            pct=${line#"${line%%[![:space:]]*}"}; pct=${pct%%[[:space:]]*}
            case "$pct" in ''|*[!0-9]*) continue ;; esac
            [ "$pct" -gt "$last" ] || continue
            last=$pct
            echo "PROGRESS $(( lo + pct * sp * 90 / 10000 )) 下载 ${n}（${pct}%）"
        done <<< "$rec"
    done
}

# 下载并校验。$1=url $2=目标文件 $3=期望 sha256（可空）[$4=进度起点 $5=进度跨度]
# （起点/跨度让调用方把这一个文件的 0–100% 映射到总进度里的一段）
gk3_net_fetch() {
    local url=$1 dst=$2 want=${3:-} lo=${4:-0} span=${5:-100} name rc
    name=$(basename "$dst")
    gk3_prog "$lo" "开始下载 $name"
    gk3__curl() {   # $1 = 续传参数（空 = 从头）
        # ⚠️ 用 --continue-at 支持断点续传：这台机器的 WAN 只有 1–2 MB/s，
        #    1.2 GB 要十几分钟，中途断一次全部重来是不可接受的。
        curl -fL --retry 3 --retry-delay 2 ${1:+--continue-at "$1"} -o "$dst" "$url" 2>&1 \
            | gk3__curl_meter "$lo" "$span" "$name" >&2
        # ⚠️★ 取 curl 自己的退出码，不看管道尾巴（CLAUDE.md 运维坑 1）。原先只判
        #   [ -f "$dst" ] —— 断在 77% 的文件也"存在"，于是报下载完成。
        return "${PIPESTATUS[0]}"
    }
    gk3__curl -; rc=$?
    if [ "$rc" = 33 ]; then
        # 服务器不支持续传（HTTP Range）。原先会留着这个半截文件，以后每次重试都 33，
        # 永远卡在这里 —— 只能删掉从头来。
        gk3_log "服务器不支持断点续传，从头下载 $name"
        rm -f "$dst"; gk3__curl ""; rc=$?
    fi
    [ -f "$dst" ] || { gk3_die "下载失败（curl 退出码 ${rc}）"; return 1; }
    if [ "$rc" != 0 ]; then
        # 续传一个其实已经下完的文件时服务器回 416，curl 报错而文件是好的 ——
        # 有 sha256 就让校验来裁决，没有就只能按失败算
        [ -n "$want" ] || { gk3_die "下载失败（curl 退出码 ${rc}），且没有 sha256 可以核对"; return 1; }
        gk3_log "curl 退出码 ${rc}，交给 sha256 裁决"
    fi
    if [ -n "$want" ]; then
        gk3_prog $(( lo + span * 95 / 100 )) "校验 $name"
        local got; got=$(sha256sum "$dst" | cut -d' ' -f1)
        # ⚠️ 不符就删掉（2026-09-27 审查）：留着的话，下一次 --continue-at 会接在一个坏的（或另一个版本的）前缀后面，
        #   永远对不上 —— 在同一次会话里换一个版本再装，boot.img 同样大小续传 416、super 接错前缀，就是这样卡死的
        [ "$got" = "$want" ] || { rm -f "$dst"; gk3_die "$name 的 sha256 不符：$got != ${want}（下载不完整或被篡改；已删掉，重试会从头下载）"; return 1; }
        gk3_log "${name}：sha256 校验通过"
    fi
    gk3_prog $(( lo + span )) "$name 下载完成"
}

# 下载一整套发布文件到 <目标目录>，逐个按 install-artifacts.sha256 校验。
#   gk3_net_release <base-url> <目标目录>
# 之后 gk3_apply --release <目标目录> 照常装 —— 网络安装和 U 盘安装走的是同一条写盘路径。
# ⚠️ 1.2 GiB 的 super.img.zst 放 tmpfs（/run）没问题：本机 15.7 GiB 内存，而展开是
#    流式写盘的（gk3-unsparse.py），不需要 12 GiB 的中间文件。
# ⚠️ 校验清单与镜像来自同一台服务器 —— 它防的是下载不完整（本机 WAN 1–2 MB/s，
#    断线是常态），不是防一台恶意的服务器；那一层靠 HTTPS。
gk3_net_release() {
    local base=${1%/} dst=$2 f want
    [ -n "$base" ] && [ -n "$dst" ] || { gk3_die "用法：gk3_net_release <base-url> <目标目录>"; return 1; }
    mkdir -p "$dst" || return 1
    gk3_prog 0 "取校验清单"
    curl -fsSL --retry 3 --max-time 60 -o "$dst/install-artifacts.sha256" "$base/install-artifacts.sha256" \
        || { gk3_die "取不到校验清单：$base/install-artifacts.sha256"; return 1; }
    # 先小后大：boot.img 失败的话，不必先等 1.2 GiB 下完才知道
    for f in boot.img super.img.zst; do
        want=$(awk -v n="$f" '{sub(/^\*/, "", $2)} $2==n{print $1}' "$dst/install-artifacts.sha256")
        [ -n "$want" ] || { gk3_die "校验清单里没有 $f"; return 1; }
        # 进度：boot.img 占 0–5%，super 占 5–100%
        if [ "$f" = boot.img ]; then gk3_net_fetch "$base/$f" "$dst/$f" "$want" 0 5 || return 1
        else                          gk3_net_fetch "$base/$f" "$dst/$f" "$want" 5 95 || return 1; fi
    done
    gk3_prog 100 "发布文件已就绪"
    echo "RELEASE dir=$(gk3__enc "$dst") source=net"
}

# 看一个发布目录里有什么（默认：安装 U 盘上 build-usb.sh 放 payload 的位置）。
#   RELEASE dir=… boot=yes|no super=zst|img|no sha256=yes|no rescue=yes|no version=… super_mib=…
#   rescue=yes：rescue.squashfs 与 initramfs.img 都找得到（发布目录里，或启动介质上）
#   version：从校验清单里那个 OTA zip 的名字取（crDroidAndroid-16.0-<日期>-gaokun3-v12.11）
gk3_release_info() {
    local d=${1:-/media/gk3/gaokun3/payload} boot=no super=no sha=no rescue=no ver="" smib=0
    [ -f "$d/boot.img" ] && boot=yes
    if   [ -f "$d/super.img.zst" ]; then super=zst; smib=$(( $(stat -c%s "$d/super.img.zst" 2>/dev/null || wc -c < "$d/super.img.zst") / 1048576 ))
    elif [ -f "$d/super.img" ];     then super=img; smib=$(( $(stat -c%s "$d/super.img" 2>/dev/null || wc -c < "$d/super.img") / 1048576 )); fi
    if [ -f "$d/install-artifacts.sha256" ]; then
        sha=yes
        ver=$(awk '{sub(/^\*/, "", $2)} $2 ~ /\.zip$/ {sub(/\.zip$/, "", $2); print $2; exit}' "$d/install-artifacts.sha256")
    fi
    gk3__find_file rescue.squashfs "$d" /media/gk3/gaokun3/install-rescue /media/gk3/gaokun3 >/dev/null \
        && gk3__find_file initramfs.img "$d" /media/gk3/gaokun3 >/dev/null && rescue=yes
    echo "RELEASE dir=$(gk3__enc "$d") boot=$boot super=$super sha256=$sha rescue=$rescue version=$(gk3__enc "${ver:-?}") super_mib=$smib"
}

# 看一个现有 ESP 的状况（只读挂载）。双系统之前界面要用它判断"装不装得下"，
# 并且在用户往下走【之前】就写明原因 —— 而不是等 gk3_apply 在动盘前一刻才拒绝。
#   ESP part=… size_mib=… free_mib=… need_mib=150 windows=yes|no gaokun3=yes|no mountable=yes|no
#   windows=yes：EFI/Microsoft/Boot/bootmgfw.efi 在 —— 装完之后 systemd-boot 会把它列进菜单
#   gaokun3=yes：上面已经有我们的启动项（重装 / 已经装过）
# ★ Windows 默认建的 ESP 只有 100 MiB，放不下 GK3_ESP_NEED_MIB —— 这是双系统最常见的
#   "装不了"，不是边角情况（scripts/live/test-apply.sh 的 C 组有这条）。
gk3_esp_info() {
    local part=$1 m free size win=no ours=no
    [ -b "$part" ] || { gk3_die "不是块设备：$part"; return 1; }
    size=$(( $(blockdev --getsize64 "$part" 2>/dev/null || echo 0) / 1048576 ))
    m=$(mktemp -d)
    if ! mount -o ro -t vfat "$part" "$m" 2>/dev/null; then
        rmdir "$m"; echo "ESP part=$part size_mib=$size free_mib=0 need_mib=$GK3_ESP_NEED_MIB windows=no gaokun3=no mountable=no"
        return 0
    fi
    free=$(df -m "$m" | awk 'NR==2{print $4}')
    # vfat 挂载本来就不分大小写，不用自己列大小写组合
    [ -f "$m/EFI/Microsoft/Boot/bootmgfw.efi" ] && win=yes
    ls "$m"/loader/entries/*-android-*.conf >/dev/null 2>&1 && ours=yes
    umount "$m"; rmdir "$m"
    echo "ESP part=$part size_mib=$size free_mib=${free:-0} need_mib=$GK3_ESP_NEED_MIB windows=$win gaokun3=$ours mountable=yes"
}

# 一次问完整块盘上所有分区能不能缩。
# ⚠️ 界面那边原来是逐个分区调 gk3_shrink_info，每次都要 fork 一个 shell 并
#    source 整个库 —— 8 个分区就是 8 次。合成一个调用。
gk3_shrink_scan() {
    local disk=$1 n part
    [ -b "$disk" ] || { gk3_die "不是块设备：$disk"; return 1; }
    for n in $(sgdisk -p "$disk" 2>/dev/null | awk '/^ *[0-9]+ /{print $1}'); do
        part=$(gk3_partpath "$disk" "$n")
        [ -b "$part" ] || continue
        gk3_shrink_info "$part" || true
    done
}

# ── 手动调整磁盘（用户 2026-09-25："能给的都给"）─────────────────────────────
# 参考别的安装器：Windows 安装程序在选盘页直接给 删除 / 格式化 / 新建 / 扩展，每一步立即生效；
# Ubuntu（新的桌面安装器也是 Flutter 写的）在"安装类型"最后一项进手动分区。这里入口学 Ubuntu
# （安装方式页最后一项"手动调整磁盘"），执行学 Windows：每个操作单独确认、立即执行 —— 攒到最后一起做，
# 中途失败时留下的中间状态讲不清楚。
#
#   gk3_part_delete <分区>
#   gk3_part_format <分区> ext4|vfat|ntfs
#   gk3_part_create --disk D --start <扇区> --size-mib N --fs ext4|vfat|ntfs|none
#   gk3_part_resize <分区> <目标 MiB>      变小走 gk3_shrink；变大 = 并进紧挨在后面的空闲
# 成功时 stdout 一行 RESULT op=… part=…；失败走 gk3_die（盘没动过时会说）。
#
# ★ 共同的闸（gk3__edit_guard）：块设备；不是 ESP（删或格式化它，盘上所有系统都起不来 —— 要重建 ESP
#   就用整盘清空）；没挂着（首先是安装器所在的那个分区）；动手之前把分区表备份到介质。
# ★ 删除【不】抹文件系统签名：分区表备份还原回去，数据就还在（Windows 的删除也是这样）。
GK3_ESP_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

gk3__edit_guard() {    # $1=分区 → 设 GK3_E_DISK / GK3_E_NUM
    local part=$1
    [ -b "$part" ] || { gk3_die "不是块设备：$part"; return 1; }
    if [ "$(blkid -p -o value -s PART_ENTRY_TYPE "$part" 2>/dev/null | tr 'a-f' 'A-F')" = "$GK3_ESP_GUID" ]; then
        gk3_die "$part 是 EFI 系统分区：动它，盘上所有系统都起不来（要重建 ESP，用整盘清空）"; return 1
    fi
    if findmnt -rn -S "$part" >/dev/null 2>&1; then
        gk3_die "$part 正挂着（安装器是不是就从它上面跑的？）—— 不动它"; return 1
    fi
    GK3_E_DISK=/dev/$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
    GK3_E_NUM=$(cat "/sys/class/block/$(basename "$part")/partition" 2>/dev/null)
    [ -b "$GK3_E_DISK" ] && [ -n "$GK3_E_NUM" ] || { gk3_die "认不出 $part 属于哪块盘的第几个分区"; return 1; }
}

# 分区的 GPT 属性位（16 位十六进制）。重建分区项时要原样带过去 —— Windows 恢复分区靠它们
# （"平台必需" / "不分配盘符"；2026-09-27 审查）
gk3__part_attr() { sgdisk -i "$2" "$1" 2>/dev/null | awk '/^Attribute flags:/{print $3}'; }
gk3__part_attr_restore() {    # $1=盘 $2=号 $3=原来的属性位
    [ -z "$3" ] || [ "$3" = 0000000000000000 ] && return 0
    sgdisk -A "$2:=:$3" "$1" >/dev/null 2>&1 && [ "$(gk3__part_attr "$1" "$2")" = "$3" ] \
        || { gk3_die "分区 $2 的属性位 $3 没带回去"; return 1; }
}

# 动盘之前备份分区表到介质（出事一条命令还原）。gk3_apply / gk3_shrink / 调整磁盘共用这一份；路径留在 GK3_GPT_BK。
# ⚠️ "还原：sgdisk --load-backup=" 这几个字界面在认（screens_finish.dart 的失败页），别改
gk3__gpt_backup() {    # $1=盘 $2=标签
    local disk=$1 dir=/media/gk3/gaokun3
    mount -o remount,rw /media/gk3 2>/dev/null || true
    [ -d "$dir" ] && [ -w "$dir" ] || dir=/tmp
    GK3_GPT_BK="$dir/gpt-before-$2-$(basename "$disk")-$(date +%Y%m%d-%H%M%S).bin"
    if sgdisk --backup="$GK3_GPT_BK" "$disk" >/dev/null 2>&1; then
        sync
        echo "分区表备份：${GK3_GPT_BK}（还原：sgdisk --load-backup=$GK3_GPT_BK ${disk}）" >&2
        # 2026-09-27 审查：落到 /tmp 的备份在内存里，重启就没了 —— 说清楚，别让人以为有还原点
        [ "$dir" != /tmp ] || echo "警告：安装介质写不进去，分区表只备份到了内存里（${GK3_GPT_BK}），重启就没了 —— 要留着就先把它拷走" >&2
    else
        GK3_GPT_BK=""
        echo "警告：分区表备份失败（继续，但出事就没有还原点了）" >&2
    fi
}

gk3__settle() { partprobe "$1" 2>/dev/null || true; command -v udevadm >/dev/null && udevadm settle --timeout=5 2>/dev/null; sleep 1; }

gk3__wait_node() {     # 分区节点是异步出现的："还没出现"和"不存在"是两回事（gk3__need_part 的注释）
    local i=0; while [ ! -b "$1" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; [ -b "$1" ] || return 1
    local d; d=$(gk3__disk_of "$1") && gk3__node_matches "$d" "$1"
}

# 分区所在的整块盘（/dev/nvme0n1p5 → /dev/nvme0n1，/dev/loop3p2 → /dev/loop3），按 sysfs 找，不按名字猜
gk3__disk_of() {
    local n; n=$(readlink -f "/sys/class/block/${1##*/}/.." 2>/dev/null) || return 1
    [ -b "/dev/${n##*/}" ] && echo "/dev/${n##*/}"
}

# ⚠️ 节点存在不等于它对：partprobe 失败时（有分区被占着），内核还拿着【旧】分区表，同号的节点指着旧的起点 ——
#   往它上面 mkfs / dd 就写进了别处（2026-09-27 审查）。拿内核看到的起点 / 大小（sysfs，512 字节为单位）
#   对一遍盘上的分区表（sgdisk，逻辑扇区为单位）。$1=盘 $2=分区节点
gk3__node_matches() {
    local disk=$1 path=$2 n ss kst ksz st en
    n=${path##*[!0-9]}
    ss=$(( $(blockdev --getss "$disk" 2>/dev/null || echo 512) / 512 ))
    kst=$(cat "/sys/class/block/${path##*/}/start" 2>/dev/null); ksz=$(cat "/sys/class/block/${path##*/}/size" 2>/dev/null)
    st=$(sgdisk -i "$n" "$disk" 2>/dev/null | awk '/^First sector:/{print $3}')
    en=$(sgdisk -i "$n" "$disk" 2>/dev/null | awk '/^Last sector:/{print $3}')
    [ -n "$kst" ] && [ -n "$st" ] || return 0          # 读不到就不拦（不在这里制造新的失败）
    if [ "$kst" != $(( st * ss )) ] || [ "$ksz" != $(( (en - st + 1) * ss )) ]; then
        gk3_die "内核看到的 ${path}（起点 ${kst}、${ksz} 扇区）与盘上的分区表（${st}–${en}）对不上 —— 新分区表没生效（有分区被占着？）。重启后再来"
        return 1
    fi
}

gk3__mkfs() {          # $1=分区 $2=ext4|vfat|ntfs
    case "$2" in
        ext4) mkfs.ext4 -q -F "$1" ;;
        vfat) mkfs.vfat -F 32 "$1" >/dev/null ;;
        ntfs) mkntfs -Q -F "$1" >/dev/null 2>&1 ;;   # -Q 快速（不清零整个分区）
        *) return 2 ;;
    esac
}

# 分区类型跟着文件系统走：Windows 只认 Basic data，Linux 的认 Linux filesystem
gk3__type_for_fs() { case "$1" in vfat|ntfs) echo 0700 ;; *) echo 8300 ;; esac; }

gk3_part_delete() {
    local part=$1
    gk3__edit_guard "$part" || return 1
    gk3_prog 10 "备份分区表"
    gk3__gpt_backup "$GK3_E_DISK" delete
    gk3_prog 50 "删除分区 $part"
    sgdisk -d "$GK3_E_NUM" "$GK3_E_DISK" >/dev/null 2>&1 || { gk3_die "删分区项失败（分区表备份见上）"; return 1; }
    gk3__settle "$GK3_E_DISK"
    gk3_prog 100 "完成"
    echo "RESULT op=delete part=$part"
}

gk3_part_format() {
    local part=$1 fs=$2 tool
    case "$fs" in ext4) tool=mkfs.ext4 ;; vfat) tool=mkfs.vfat ;; ntfs) tool=mkntfs ;; *) gk3_die "不支持的文件系统：$fs"; return 1 ;; esac
    command -v "$tool" >/dev/null || { gk3_die "缺工具：$tool"; return 1; }
    gk3__edit_guard "$part" || return 1
    gk3_prog 20 "格式化 $part 为 $fs"
    gk3__mkfs "$part" "$fs" || { gk3_die "格式化 $part 失败"; return 1; }
    # 类型码没改过去的话，格式化成 NTFS 的分区 Windows 不认（审查 #8）—— 文件系统已经建好，说清楚
    sgdisk -t "$GK3_E_NUM:$(gk3__type_for_fs "$fs")" "$GK3_E_DISK" >/dev/null 2>&1 \
        || { gk3_die "已格式化成 ${fs}，但分区类型码没改过去（sgdisk -t 失败）—— 别的系统可能不认它"; return 1; }
    gk3__settle "$GK3_E_DISK"
    gk3_prog 100 "完成"
    echo "RESULT op=format part=$part fs=$fs"
}

gk3_part_create() {
    local disk="" start="" mib="" fs=ext4 name
    while [ $# -gt 0 ]; do
        case "$1" in
            --disk) disk=$2; shift 2 ;; --start) start=$2; shift 2 ;;
            --size-mib) mib=$2; shift 2 ;; --fs) fs=$2; shift 2 ;;
            *) gk3_die "create: 不认识的参数 $1"; return 1 ;;
        esac
    done
    [ -b "$disk" ] && [ -n "$start" ] && [ -n "$mib" ] || { gk3_die "create 要 --disk --start --size-mib"; return 1; }
    case "$fs" in ext4|vfat|ntfs|none) ;; *) gk3_die "不支持的文件系统：$fs"; return 1 ;; esac
    # 起点对齐到 1 MiB；整段必须落在【某一段】空闲区里 —— 空闲区用 gk3_probe 同一套算法算，不另写一份
    local st=$(( (start + 2047) / 2048 * 2048 )) en ok="" line a b
    en=$(( st + mib * 2048 - 1 ))
    while read -r line; do
        [ -n "$line" ] || continue
        a=$(gk3__f "$line" start); b=$(gk3__f "$line" end)
        [ "$st" -ge "$a" ] && [ "$en" -le "$b" ] && ok=1
    done <<EOF
$(gk3__probe_parts "$disk" "$(cat "/sys/block/$(basename "$disk")/size" 2>/dev/null || echo 0)" | grep '^FREE ')
EOF
    [ -n "$ok" ] || { gk3_die "扇区 [$st, $en] 不在任何一段空闲区里 —— 会压到别的分区（盘没动过）"; return 1; }
    case "$fs" in vfat|ntfs) name="Basic data partition" ;; *) name=linux ;; esac
    gk3_prog 10 "备份分区表"
    gk3__gpt_backup "$disk" create
    gk3_prog 30 "新建分区（${mib} MiB）"
    sgdisk -n "0:$st:$en" -t "0:$(gk3__type_for_fs "$fs")" -c "0:$name" "$disk" >/dev/null 2>&1 || { gk3_die "sgdisk 建分区失败"; return 1; }
    gk3__settle "$disk"
    # sgdisk -n 0 自己挑编号：按起始扇区找回来
    local num part
    num=$(sgdisk -p "$disk" 2>/dev/null | awk -v s="$st" '/^ *[0-9]+ /{ if ($2 == s) print $1 }')
    part=$(gk3_partpath "$disk" "$num")
    [ -n "$num" ] && gk3__wait_node "$part" || { gk3_die "新分区的节点没出现（${part}）"; return 1; }
    if [ "$fs" != none ]; then
        gk3_prog 60 "格式化为 $fs"
        gk3__mkfs "$part" "$fs" || { gk3_die "格式化新分区 $part 失败（分区已建好）"; return 1; }
    fi
    gk3_prog 100 "完成"
    echo "RESULT op=create part=$part fs=$fs size_mib=$mib"
}

gk3_part_resize() {
    local part=$1 target=$2 cur
    [ -b "$part" ] || { gk3_die "不是块设备：$part"; return 1; }
    cur=$(( $(blockdev --getsize64 "$part" 2>/dev/null || echo 0) / 1048576 ))
    if [ "$target" -lt "$cur" ]; then
        gk3__edit_guard "$part" || return 1
        gk3_shrink "$part" "$target" || return 1
        echo "RESULT op=shrink part=$part size_mib=$target"; return 0
    fi
    [ "$target" -gt "$cur" ] || { gk3_die "目标大小与现在一样（${cur} MiB）"; return 1; }
    gk3__grow "$part" "$target"
}

# 扩大：先扩分区项（同一个起点、同一个 PARTUUID / 名字 / 类型 —— 与 gk3_shrink 同一种重建），再扩文件系统。
# 只能并进【紧挨在后面】的空闲：要把前面的空间也并进来就得挪数据，那是另一个量级的风险，不做。
gk3__grow() {
    local part=$1 target=$2 fs disk num st en pu pl pt next last lim newend rc
    gk3__edit_guard "$part" || return 1
    disk=$GK3_E_DISK; num=$GK3_E_NUM
    fs=$(blkid -o value -s TYPE "$part" 2>/dev/null)
    case "$fs" in
        ext2|ext3|ext4) command -v resize2fs >/dev/null || { gk3_die "缺工具：resize2fs"; return 1; } ;;
        ntfs) command -v ntfsresize >/dev/null || { gk3_die "缺工具：ntfsresize"; return 1; } ;;
        *) gk3_die "不支持扩大 ${fs:-没有文件系统的分区}（只支持 ext 与 NTFS）"; return 1 ;;
    esac
    st=$(sgdisk -i "$num" "$disk" 2>/dev/null | awk '/^First sector:/{print $3}')
    en=$(sgdisk -i "$num" "$disk" 2>/dev/null | awk '/^Last sector:/{print $3}')
    pu=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition unique GUID:' | awk '{print $4}')
    pl=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition name:' | cut -d"'" -f2)
    pt=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition GUID code:' | awk '{print $4}')
    local pattr; pattr=$(gk3__part_attr "$disk" "$num")
    [ -n "$st" ] && [ -n "$pu" ] && [ -n "$pt" ] || { gk3_die "读不到分区 $num 的起点 / GUID —— 不敢重建它"; return 1; }
    next=$(sgdisk -p "$disk" 2>/dev/null | awk -v e="$en" '/^ *[0-9]+ /{ if ($2 > e && (n == "" || $2 < n)) n = $2 } END { print n }')
    last=$(sgdisk -p "$disk" 2>/dev/null | sed -n 's/.*last usable sector is \([0-9]*\).*/\1/p')
    lim=$(( ${next:-$(( last + 1 ))} - 1 ))
    newend=$(( st + target * 2048 - 1 ))
    if [ "$newend" -gt "$lim" ]; then
        gk3_die "后面紧挨着的空闲不够：最多能扩到 $(( (lim - st + 1) / 2048 )) MiB（盘没动过）"; return 1
    fi
    if [ "$fs" = ntfs ]; then
        # 与缩小同一条纪律：脏卷（Windows 快速启动 / 休眠）不碰 —— ntfsresize --info 先问一遍
        gk3__ntfs_trial_mount "$part" || return 1
        ntfsresize --info "$part" >/dev/null 2>&1 </dev/null || { gk3_die "ntfsresize 检查没通过（卷脏？回 Windows 关掉快速启动、正常关机）—— 盘没动过"; return 1; }
    fi
    gk3_prog 10 "备份分区表"
    gk3__gpt_backup "$disk" grow
    gk3_prog 30 "扩大分区项"
    sgdisk -d "$num" "$disk" >/dev/null 2>&1 || { gk3_die "删旧分区项失败"; return 1; }
    sgdisk -n "$num:$st:$newend" -t "$num:$pt" -u "$num:$pu" "$disk" >/dev/null 2>&1 \
        || { gk3_die "重建分区项失败 —— 用上面的分区表备份还原"; return 1; }
    if [ -n "$pl" ]; then
        sgdisk -c "$num:$pl" "$disk" >/dev/null 2>&1 || { gk3_die "分区名 $pl 没写回去 —— 用上面的分区表备份还原"; return 1; }
    fi
    gk3__part_attr_restore "$disk" "$num" "$pattr" || return 1
    gk3__settle "$disk"
    gk3__wait_node "$part" || { gk3_die "分区节点没回来（${part}）"; return 1; }
    # 内核看到的必须已经是新大小 —— 否则 resize2fs / ntfsresize 会说"不用改"然后退出 0，报一个假的"扩大完成"
    [ "$(blockdev --getsize64 "$part" 2>/dev/null)" = "$(( target * 1048576 ))" ] \
        || { gk3_die "内核还没看到新的分区大小（${part}）—— 分区项已扩大，文件系统没动；重启后再扩一次"; return 1; }
    gk3_prog 60 "扩大文件系统"
    case "$fs" in
        ntfs) ntfsresize --force "$part" >/dev/null 2>&1 </dev/null || { gk3_die "扩大 NTFS 失败（分区项已扩大，文件系统还是原来的大小，数据完好）"; return 1; } ;;
        *)
            e2fsck -fp "$part" >/dev/null 2>&1; rc=$?
            [ "$rc" -lt 4 ] || { gk3_die "e2fsck 报错（${rc}），不敢扩"; return 1; }
            resize2fs "$part" >/dev/null 2>&1 || { gk3_die "resize2fs 失败（分区项已扩大，文件系统还是原来的大小，数据完好）"; return 1; } ;;
    esac
    [ "$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition unique GUID:' | awk '{print $4}')" = "$pu" ] \
        || { gk3_die "PARTUUID 变了 —— Windows 会起不来"; return 1; }
    gk3_prog 100 "完成"
    echo "RESULT op=grow part=$part size_mib=$target"
}

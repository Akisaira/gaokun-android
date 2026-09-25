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
#        type=<GUID> name=esp fs=vfat fslabel=... os=windows|linux|android|
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

    local cursor=$first_usable num start end
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
             "os=$(gk3__guess_os "$part" "$ptype" "$pname" "$fstype")"
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
#   CHECK id=bios       ok=yes|no|unknown value=2.16
#   CHECK id=secureboot ok=yes|no|unknown value=disabled|enabled
#   CHECK id=tools      ok=yes|no         missing=a,b
# ok=no 的项前端必须拦住；unknown 只警告 —— 读不到 ≠ 不合格（例如内核没开 DMIID）。
#
# ★ 型号 / BIOS 的读取点：/sys/class/dmi/id/{product_name,bios_version}
#   （drivers/firmware/dmi-id.c:42-47，要 CONFIG_DMIID，Kconfig 默认 y），
#   读不到时退回内核启动日志里那行 "Hardware name: HUAWEI GK-W7X/GK-W7X-PCB, BIOS 2.16 …"
#   （本机实测原文见 docs/hw-inventory.md:33）。
# ★ BIOS 只认 2.16。⚠️ 拒绝 2.17 的理由【不是】"两版触摸的 SPI 总线和 GPIO 编号不同" ——
#   那个说法比的那份 DSDT_217 其实是 8cx Gen 2（SC8180X）的表，不是本机的下一版
#   （docs/stage4-findings.md #120 §4）。真实理由只是：上游触摸驱动按 2.16 开发，
#   2.17 上没人验证过。所以界面上说"未验证"，别说"不兼容"。
#   GK3_SKIP_BIOS_CHECK=1 可以放行（给知道自己在做什么的人），此时报 unknown；
#   型号同理：GK3_SKIP_MODEL_CHECK=1（gaokun2 是另一台机器、另一套 EC 协议，别装）。
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
    if [ "${GK3_SKIP_BIOS_CHECK:-0}" = 1 ]; then
        echo "CHECK id=bios ok=unknown value=$(gk3__enc "${v:-?}") skipped=yes"
    else case "$v" in
        2.16) echo "CHECK id=bios ok=yes value=$v" ;;
        2.17) echo "CHECK id=bios ok=no value=$v why=bios-untested" ;;
        "")   echo "CHECK id=bios ok=unknown value=" ;;
        *)    echo "CHECK id=bios ok=unknown value=$(gk3__enc "$v") why=bios-untested" ;;
    esac; fi

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
#   gk3_plan --disk /dev/nvme0n1 --mode wipe|alongside --rescue yes|no \
#            [--region-start S --region-end E] [--esp PATH] [--userdata-mib N]
#
# 输出（顺序即执行顺序）：
#   PLAN op=wipe    disk=...
#   PLAN op=mkpart  num=0 name=super start=... end=... type=... size_mib=...
#   PLAN op=useesp  path=/dev/nvme0n1p1
#   PLANSUM total_mib=... userdata_mib=... rescue=yes|no mode=...
# 失败：
#   PLANERR msg=...
#
# ⚠️ 所有分区起始都对齐到 1 MiB（2048 扇区）。不对齐会让 NVMe 的写放大变差，
#    而且 sgdisk 会自己挪，挪完之后我们算出来的 end 就对不上了。
GK3_CUR=0
GK3_TYPE_ESP=ef00
GK3_TYPE_DATA=8300

gk3_plan() {
    local disk="" mode="wipe" rescue="no" rstart="" rend="" esp="" ud_mib=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --disk) disk=$2; shift 2 ;;
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
#   gk3_apply --disk X --mode wipe|alongside --rescue yes|no --release DIR \
#             [--region-start S --region-end E --esp PATH] [--userdata-mib N]
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
gk3_apply() {
    local disk="" mode=wipe rescue=no rel="" rstart="" rend="" esp="" ud_mib=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --disk) disk=$2; shift 2 ;;
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
                umount "$em"; rmdir "$em" 2>/dev/null
                echo "现有 ESP $esp 空闲 ${fm} MiB（需要 ${GK3_ESP_NEED_MIB}）" >&2
                if [ "${fm:-0}" -lt "$GK3_ESP_NEED_MIB" ]; then
                    rm -rf "$parts"
                    gk3_die "ESP 空间不够：只有 ${fm} MiB，需要 ${GK3_ESP_NEED_MIB} MiB。请先在原系统里清理 EFI 分区（盘还没动过）"
                    return 1
                fi
            else
                rmdir "$em" 2>/dev/null; rm -rf "$parts"
                gk3_die "挂不上现有 ESP $esp —— 不敢往一个读不了的 ESP 上装引导链（盘还没动过）"
                return 1
            fi
        fi
    fi

    # ── 安全闸 1：不能写自己正跑在上面的那块盘 ──────────────────────────
    # ⚠️ 安装器要么从 U 盘跑、要么从内置盘的救援分区跑。后者做整盘清空
    #    等于把自己脚下的地板锯掉 —— 而且是【跑到一半】才死，盘已经毁了。
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
    plan=$(gk3_plan --disk "$disk" --mode "$mode" --rescue "$rescue" \
                    ${rstart:+--region-start "$rstart"} ${rend:+--region-end "$rend"} \
                    ${esp:+--esp "$esp"} ${ud_mib:+--userdata-mib "$ud_mib"}) \
        || { echo "$plan"; rm -rf "$parts"; return 1; }
    if printf '%s\n' "$plan" | grep -q '^PLANERR'; then
        printf '%s\n' "$plan" | grep '^PLANERR'; rm -rf "$parts"; return 1
    fi

    # ── 建分区 ──────────────────────────────────────────────────────────
    # ⚠️★ ④ 动手之前先把分区表备份到介质上。出事能一条命令还原：
    #     sgdisk --load-backup=<文件> <盘>
    #   代价是几十 KB 和一秒钟；没有它的话，改错分区表就只能靠猜。
    if [ "$DRY" != 1 ]; then
        local bkdir bk
        bkdir=/media/gk3/gaokun3
        mount -o remount,rw /media/gk3 2>/dev/null || true
        [ -d "$bkdir" ] && [ -w "$bkdir" ] || bkdir=/tmp
        bk="$bkdir/gpt-backup-$(basename "$disk")-$(date +%Y%m%d-%H%M%S).bin"
        if sgdisk --backup="$bk" "$disk" >/dev/null 2>&1; then
            echo "分区表已备份到 ${bk}（还原：sgdisk --load-backup=$bk ${disk}）" >&2
        else
            echo "警告：分区表备份失败（继续，但出事就没有还原点了）" >&2
        fi
        sync
    fi

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
    gk3__run mkfs.ext4 -q -F -L metadata "$p_meta" || return 1
    gk3__run mkfs.ext4 -q -F -L userdata "$p_data" || return 1
    # misc 必须是全零：libboot_control 读到坏 CRC 才会初始化一份新的 bootloader_control
    gk3__run dd if=/dev/zero of="$p_misc" bs=1M count="$GK3_MISC_MIB" conv=fsync status=none || return 1
    [ "$rescue" = yes ] && { gk3__run mkfs.ext4 -q -F -L gk3rescue "$p_resc" || return 1; }

    # ── 写 super（30% → 70%，进度由 gk3-unsparse.py 按块推进）──────────
    gk3_prog 30 "写入 super"
    gk3__write_super "$super_src" "$p_super" || return 1

    gk3_prog 70 "写入 boot_a / boot_b"
    gk3__run dd if="$rel/boot.img" of="$p_boota" bs=4M conv=fsync status=none || return 1
    gk3__run dd if="$rel/boot.img" of="$p_bootb" bs=4M conv=fsync status=none || return 1

    # ── 引导链 ──────────────────────────────────────────────────────────
    # ⚠️ 少了这一步，前面所有东西都写对了，机器照样起不来 —— 这台机器是 UEFI，
    #    内核/dtb/ramdisk 是 ESP 上的【普通文件】，不在 boot 分区里被引导。
    #    （boot_a/boot_b 有内容是为了让 update_engine 的 A/B 流程完整。）
    gk3_prog 80 "安装引导链"
    local mid; mid=${GK3_MACHINE_ID:-$(cat /etc/machine-id 2>/dev/null || echo 8a29534fa802480d9fbb71aa18c01d7b)}
    # ⚠️ 挂载点用 mktemp，不用 /mnt/esp —— CLAUDE.md 操作禁忌 4：共享的挂载点
    #    会被另一个 shell 里"顺手看一眼"的人 umount 掉，于是这一步静默失败。
    local mnt; mnt=$(mktemp -d)
    gk3__run mount -t vfat "$p_esp" "$mnt" || return 1

    if [ "$DRY" != 1 ]; then
        mkdir -p "$mnt/EFI/BOOT" "$mnt/EFI/systemd" "$mnt/loader/entries" \
                 "$mnt/$mid/android/slot_a" "$mnt/$mid/android/slot_b"
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
                cp -p "$mnt/$f" "$mnt/$f.before-gaokun3"
                echo "原有的 $f 已备份为 $f.before-gaokun3" >&2
            fi
        done
        cp "$sdboot" "$mnt/EFI/BOOT/BOOTAA64.EFI"
        cp "$sdboot" "$mnt/EFI/systemd/systemd-bootaa64.efi"
        local slot
        for slot in a b; do
            cp "$parts/Image" "$parts/gaokun3.dtb" "$parts/ramdisk.img" "$mnt/$mid/android/slot_$slot/"
            # 文件名是承重的：boot_control HAL 按 *-android-a.conf / *-android-b.conf
            # 改写 loader.conf 的 default（EspSlot.cpp:41-43）；OTA postinstall 只改
            # options 那一行、只往 slot_<后缀>/ 写这三个文件名。改一边就要改另一边。
            cat > "$mnt/loader/entries/$mid-android-$slot.conf" <<ENTRY
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
                cp "$rel/recovery-ramdisk.img" "$mnt/$mid/android/slot_$slot/"
                if [ "${GK3_ENABLE_RECOVERY_ENTRY:-0}" = 1 ]; then
                    sed -e "s|^initrd .*|initrd     /$mid/android/slot_$slot/recovery-ramdisk.img|" \
                        -e "s|^title .*|title      Recovery (gaokun3) — slot _$slot|" \
                        -e "s|^version .*|version    gaokun3-recovery-$slot|" \
                        -e "s|^sort-key .*|sort-key   zzrecovery$slot|" \
                        "$mnt/loader/entries/$mid-android-$slot.conf" \
                        > "$mnt/loader/entries/$mid-recovery-$slot.conf"
                fi
            done
        fi

        # ★ 默认落点是 slot_a；救援系统装了的话它排在前面（sort-key linux1），
        #   但【不设成 default】—— 默认必须是能用的系统。
        #   （命令行版原先把救援设成 default，理由是"默认落点要能远程接入"。
        #    但 boot_control HAL 在 Android 第一次标记启动成功时就会把 default
        #    改写成 *-android-<槽>.conf（EspSlot.cpp:120-172）—— 那个选择只活到
        #    第一次开机，代价却是每个新用户第一次重启落进一个他不认识的系统。）
        cat > "$mnt/loader/loader.conf" <<LOADER
timeout 15
console-mode keep
editor no
default *-android-a.conf
LOADER
        if [ "$rescue" = yes ]; then
            mkdir -p "$mnt/$mid/rescue"
            cp "$r_initrd" "$mnt/$mid/rescue/initramfs.img"
            # ⚠️ 标题用 ASCII：开机菜单由 UEFI 固件的字体画，一般不含中文（原先的"救援系统（Alpine，
            #    全内存）"从没在本机菜单上看过，取稳妥的一侧）。
            # 救援系统与 Android 共用内核与 dtb（docs/stage7-live-installer.md §2.3），
            # 只多一个 initramfs；cmdline 从 Android 那份派生（见 gk3__rescue_cmdline）
            cat > "$mnt/loader/entries/$mid-rescue.conf" <<RESC
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
    else
        echo "DRY: 往 $p_esp 写 systemd-boot、两个 Android 启动项（options=$cmdline …）、内核/dtb/ramdisk" >&2
    fi
    gk3__run umount "$mnt" || true
    rmdir "$mnt" 2>/dev/null || true

    # ── 救援系统 ────────────────────────────────────────────────────────
    if [ "$rescue" = yes ]; then
        gk3_prog 92 "写入救援系统"
        local rmnt; rmnt=$(mktemp -d)
        gk3__run mount "$p_resc" "$rmnt" || return 1
        if [ "$DRY" != 1 ]; then
            mkdir -p "$rmnt/gaokun3"
            cp "$r_squash" "$rmnt/gaokun3/rescue.squashfs"
            # ⚠️ WiFi 凭据【不打包进镜像】：安装器把用户当前用的那份复制过去，
            #    这样救援系统一开机就能连上同一个网。见 gk3-wifi 的注释。
            #    来源按优先级：发布目录里放的 → 安装器里刚连上的（gk3_wifi_connect 写的）
            #    → 做 U 盘时放在介质上的。
            local wconf
            if wconf=$(gk3__find_file wpa_supplicant.conf "$rel" /run/gaokun3 /media/gk3/gaokun3); then
                install -Dm600 "$wconf" "$rmnt/gaokun3/wpa_supplicant.conf"
                echo "救援系统的 WiFi 配置取自 $wconf" >&2
            else
                echo "警告：没有 WiFi 配置可带给救援系统 —— 它开机后连不上网，只能在机器旁操作" >&2
            fi
            # ★ ssh 公钥同理：公开的 live 镜像不带任何人的公钥，所以从它装出来的救援系统本来
            #   【远程进不去】—— 而远程接入正是救援系统存在的意义。来源按优先级：发布目录里放的
            #   → 安装 U 盘上用户放的 → 正在跑的这个系统自己的（私人构建的镜像带了 --ssh-key）。
            #   救援系统的 sshd 认 /media/gk3/gaokun3/authorized_keys（overlay 里的 sshd_config）。
            local akeys=""
            akeys=$(gk3__find_file authorized_keys "$rel" /media/gk3/gaokun3) \
                || { [ -s /root/.ssh/authorized_keys ] && akeys=/root/.ssh/authorized_keys; } || true
            if [ -n "$akeys" ]; then
                install -Dm600 "$akeys" "$rmnt/gaokun3/authorized_keys"
                echo "救援系统的 ssh 公钥取自 ${akeys}（$(grep -c '^ssh-\|^ecdsa-' "$akeys") 把）" >&2
            else
                echo "警告：没有 ssh 公钥可带给救援系统 —— 只能在机器旁登录（放一份到 U 盘的 gaokun3/authorized_keys）" >&2
            fi
            sync
        fi
        gk3__run umount "$rmnt" || true
        rmdir "$rmnt" 2>/dev/null || true
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
                dd if="$src" of="$dst" bs=4M conv=fsync status=none || { gk3_die "dd super 失败"; return 1; }
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

# 问文件系统"最小能缩到多少 MiB"。问不出来就报 can=no —— 不猜。
gk3_shrink_info() {
    local part=$1 fs cur_mib min_mib can why out b bs blocks
    if [ ! -b "$part" ]; then
        echo "SHRINK part=$part can=no why=not-a-block-device"; return 1
    fi
    fs=$(blkid -o value -s TYPE "$part" 2>/dev/null)
    cur_mib=$(( $(blockdev --getsize64 "$part" 2>/dev/null || echo 0) / 1048576 ))
    can=no; why=""; min_mib=""
    case "$fs" in
        ntfs)
            if ! command -v ntfsresize >/dev/null; then
                why=no-ntfsresize
            else
                out=$(ntfsresize --info --force "$part" 2>&1)
                if [ $? -ne 0 ]; then
                    # ⚠️ 最常见的原因是卷脏（Windows 快速启动/休眠）。
                    #    这不是该绕过的错误，是该转达给用户的错误。
                    case "$out" in
                        *dirty*|*Dirty*|*unclean*)  why=ntfs-dirty ;;
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
    echo "分区 $num 身份：PARTUUID=$pu 类型=$pt 名字=${pl:-(无)}" >&2

    gk3_prog 5 "备份分区表"
    mount -o remount,rw /media/gk3 2>/dev/null || true
    bk=/media/gk3/gaokun3/gpt-before-shrink-$(date +%Y%m%d-%H%M%S).bin
    [ -d /media/gk3/gaokun3 ] || bk=/tmp/gpt-before-shrink.bin
    if sgdisk --backup="$bk" "$disk" >/dev/null 2>&1; then
        echo "分区表备份：${bk}（还原：sgdisk --load-backup=$bk ${disk}）" >&2
    else
        echo "警告：分区表备份失败" >&2
    fi

    # ── 第 1 步：缩文件系统（演练 → 真做）───────────────────────────────
    gk3_prog 15 "演练缩小文件系统"
    case "$fs" in
        ntfs)
            if ! ntfsresize --no-action --force --size "${target_mib}M" "$part" >/dev/null 2>&1; then
                gk3_die "ntfsresize 演练没通过 —— 不往下做"; return 1
            fi
            gk3_prog 30 "缩小 NTFS"
            # 两个 --force 是 ntfsresize 自己的要求（第二次是确认），不是硬来
            if ! printf 'y\n' | ntfsresize --force --force --size "${target_mib}M" "$part" >/dev/null 2>&1; then
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
    [ -n "$pl" ] && sgdisk -c "${num}:${pl}" "$disk" >/dev/null 2>&1
    partprobe "$disk" 2>/dev/null || true
    sleep 1

    # ── 第 3 步：验 ─────────────────────────────────────────────────────
    gk3_prog 90 "复核"
    newpu=$(sgdisk -i "$num" "$disk" 2>/dev/null | grep '^Partition unique GUID:' | awk '{print $4}')
    if [ "$newpu" != "$pu" ]; then
        gk3_die "PARTUUID 变了（$pu -> ${newpu}）—— Windows 会起不来"; return 1
    fi
    newmib=$(( $(blockdev --getsize64 "$part" 2>/dev/null || echo 0) / 1048576 ))
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

GK3_WIFI_IF=${GK3_WIFI_IF:-wlan0}
GK3_WPA_CTRL=/run/wpa_supplicant

# 确保 wlan0 起来、wpa_supplicant 在跑且带控制接口。
gk3_wifi_up() {
    local ifc=$GK3_WIFI_IF
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
    local ifc=$GK3_WIFI_IF
    wpa_cli -i "$ifc" -p "$GK3_WPA_CTRL" scan >/dev/null 2>&1
    sleep 3
    wpa_cli -i "$ifc" -p "$GK3_WPA_CTRL" scan_results 2>/dev/null \
        | python3 "$GK3_LIBDIR/gk3-wpa-scan.py"
}

# 连接。$1=SSID（或 hex:<gk3_wifi_scan 给的 ssid_hex>）$2=密码（空 = 开放网络）
#
# ★ 优先用 hex:<…>。wpa_supplicant 的网络配置里，不带引号的 SSID 就是十六进制
#   （wpa-2.10 src/utils/common.c:679-686）—— 任意字节都不会被引号、空格、
#   转义搞坏，中文 / GBK 编码的 SSID 也一样。
# ★ 连上之后把这份配置写到 /run/gaokun3/wpa_supplicant.conf：gk3_apply 会把它
#   装进救援分区，于是装好的救援系统一开机就能连上同一个网 —— 否则就是
#   "救援起来了但网没起来 = 一台连不上的机器"（docs/stage7-live-installer.md:200-202）。
gk3_wifi_connect() {
    local ssid=$1 psk=${2:-} ssid_cfg show
    case "$ssid" in
        hex:*) ssid_cfg=${ssid#hex:}
               case "$ssid_cfg" in ''|*[!0-9a-fA-F]*) gk3_die "SSID 的十六进制写法不对：$ssid_cfg"; return 1 ;; esac
               [ $(( ${#ssid_cfg} % 2 )) = 0 ] || { gk3_die "SSID 的十六进制长度是奇数"; return 1; }
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
    local ifc=$GK3_WIFI_IF W
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
    ( umask 077; mkdir -p /run/gaokun3
      { echo "ctrl_interface=$GK3_WPA_CTRL"
        echo "update_config=1"
        echo "network={"
        echo "	ssid=$ssid_cfg"
        if [ -n "$psk" ]; then echo "	psk=\"$psk\""; else echo "	key_mgmt=NONE"; fi
        echo "}"; } > /run/gaokun3/wpa_supplicant.conf ) 2>/dev/null || true
    gk3_prog 100 "已连接"
    gk3_net_status
}

gk3_net_status() {
    local ifc=$GK3_WIFI_IF ip4 ssid
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

gk3_net_manifest() {
    local url=${1:-$GK3_MANIFEST_URL}
    command -v curl >/dev/null || { gk3_die "没有 curl"; return 1; }
    local out
    out=$(curl -fsSL --max-time 30 "$url" 2>/dev/null) || { gk3_die "取不到清单：$url"; return 1; }
    printf '%s\n' "$out" | grep '^VARIANT ' || { gk3_die "清单里一个 VARIANT 都没有"; return 1; }
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
            | tr '\r' '\n' \
            | awk -v lo="$lo" -v sp="$span" -v n="$name" \
                '/^ *[0-9]/{ if ($1+0 > 0) { printf "PROGRESS %d 下载 %s（%d%%）\n", lo + $1*sp*90/10000, n, $1; fflush() } }' >&2
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
        [ "$got" = "$want" ] || { gk3_die "$name 的 sha256 不符：$got != ${want}（下载不完整或被篡改；重跑会从断点续传）"; return 1; }
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

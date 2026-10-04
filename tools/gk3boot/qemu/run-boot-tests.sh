#!/usr/bin/env bash
# gk3boot.efi（S5 最小版、观察模式）的 QEMU 夹具测试（容器内；宿主上用 scripts/gk3boot/test-boot.sh 一键跑）。
#
#   bash qemu/run-boot-tests.sh [real linux-a linux-b force-a badsha miscerr]   默认全跑（没有真 boot.img 时跳过 real）
#
# 环境：BOOT_VERSION（gk3boot 版本串）、BOOTIMG（真 gaokun3 boot.img，可无）、GK3_TEST_KERNEL（通用 arm64 vmlinuz，可无 →
#       qemu/fetch-test-kernel.sh 从 Debian 取一份进 build/cache/）
#
# 每个场景都是：造夹具盘 → LoaderEntryOneShot=gk3boot-e4.conf → QEMU（AAVMF + systemd-boot 257.13）→ 收串口 →
# 盘前后比对（只准多出 \EFI\gk3boot\log\boot-*.txt）→ check_boot.py 判定。
#
#   real     boot_a = 真 gaokun3 boot.img（zboot 内核），实机 misc，条目 options 与上机 E4 完全相同（gk3.slot=a）：
#            决策、读盘、SHA1、cmdline 与实机 /proc/cmdline 逐字节对拍；交接后它在 virt 上一行也不打（没有 PL011 驱动，
#            zboot stub 也不出声 —— 走 systemd-boot 直连条目时同样如此），只能从 QEMU -d int 看 CPU 进了内核虚拟地址，45 秒后停掉
#   linux-a  boot_a = Debian 通用内核 + 测试 initramfs + 带标记的 QEMU dtb，实机 misc（_a 已成功）→ /init 打出 cmdline、
#            dtb 标记、initrd 标记 → 关机：DTB 表、LoadFile2、LoadOptions 三条通路都通。acpi=off：固件自己也装 DTB 表，要被盖掉
#   linux-b  misc 改成 _b 15/6 未成功 → 决策选 _b、"会扣 tries 6→5" 但观察模式不写（盘比对：misc 逐字节未变）；
#            boot_b 的 cmdline 超过 511 字节（头 + extra_cmdline 拼接）且带一个旧的 androidboot.slot_suffix（要被替换）
#   force-a  同 linux-b 的 misc，条目 options 加 gk3.slot=a → 决策照算照记，实际启动 _a（event=forced）
#   strictnx linux-a 换 AAVMF 的 strict-NX 固件（镜像保护最严的 edk2 配置）：缓冲区 LoadImage 的内核会不会被拒
#   espfull  linux-a + ESP 一个字节都不剩：建日志目录 VOLUME_FULL，记在屏幕上，照样交接（写日志失败不能挡启动）
#   badsha   boot_a 坏一个 kernel 字节（头里的 id 不变）→ SHA1(id) 不对 → fail-open：写日志、冷复位 → 下一次进默认直连条目
#   miscerr  QEMU blkdebug 让 misc 那段盘读出 EIO → fail-open，同上
set -uo pipefail
cd "$(dirname "$0")/.."
O=build/qemu-boot
C=build/cache/linux
P=$O/prep
BOOT_VERSION=${BOOT_VERSION:-dev}
CODE=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
CODE_NX=/usr/share/AAVMF/AAVMF_CODE.secboot.strictnx.fd
VARS0=/usr/share/AAVMF/AAVMF_VARS.fd
FX="python3 qemu/fixture.py"
PROC_VEC=test/vectors/proc-cmdline-20261005.txt
SCEN=("$@")
if [ ${#SCEN[@]} -eq 0 ]; then
    SCEN=(linux-a linux-b force-a strictnx espfull badsha miscerr)
    [ -n "${BOOTIMG:-}" ] && [ -f "$BOOTIMG" ] && SCEN=(real "${SCEN[@]}")
fi
RESULTS=()
say() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

echo "▶ 构建 EFI（gnu-efi $(dpkg-query -W -f='${Version}' gnu-efi)，systemd-boot $(dpkg-query -W -f='${Version}' systemd-boot-efi)，" \
     "QEMU $(dpkg-query -W -f='${Version}' qemu-system-arm)，AAVMF $(dpkg-query -W -f='${Version}' qemu-efi-aarch64)）"
make -s -C efi VERSION="${VERSION:-dev}" BOOT_VERSION="$BOOT_VERSION" 2>&1 | grep -v 'LOAD segment with RWX' || exit 1
[ -f build/efi/gk3boot.efi ] || { echo "✗ 没有 gk3boot.efi"; exit 1; }

# ---------------------------------------------------------------- 准备：测试内核、initramfs、dtb、boot.img
say "准备测试载荷"
if [ -n "${GK3_TEST_KERNEL:-}" ]; then
    mkdir -p "$C" && cp "$GK3_TEST_KERNEL" "$C/vmlinuz" && echo "GK3_TEST_KERNEL $(sha256sum "$C/vmlinuz" | cut -c1-16)…" > "$C/vmlinuz.version"
fi
bash qemu/fetch-test-kernel.sh "$C" || { echo "✗ 取不到测试内核（离线？给 GK3_TEST_KERNEL=…，或 GK3_DEBIAN_MIRROR=…）"; exit 1; }
rm -rf "$P" && mkdir -p "$P"
gcc -static -nostdlib -ffreestanding -fno-stack-protector -fno-pie -no-pie -O2 -Wall -Werror \
    -Wl,--build-id=none -o "$P/init" qemu/init.c || exit 1
RUN=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
IMARK=gk3-initrd-$RUN
$FX initramfs --init "$P/init" --marker "$IMARK" --out "$P/initramfs.cpio.gz" || exit 1
python3 qemu/qemu_run.py --dumpdtb "$P/virt.dtb" --machine-opts acpi=off || exit 1
for s in a b; do
    $FX fdt-mark "$P/virt.dtb" "$P/dtb-$s.dtb" gk3,fixture-marker "gk3boot-dtb-$s-$RUN" || exit 1
done
# boot_a：普通长度；boot_b：> 511 字节（切进 extra_cmdline）+ 一个旧的 slot_suffix（gk3_cmdline_android 要换掉它）
CL_A="console=ttyAMA0 panic=-1 androidboot.hardware=gaokun3 gk3fixture=linux-a"
PAD=$(printf 'x%.0s' $(seq 1 560))
CL_B="console=ttyAMA0 panic=-1 androidboot.hardware=gaokun3 androidboot.slot_suffix=_z gk3pad=$PAD gk3fixture=linux-b"
$FX mkbootimg --kernel "$C/vmlinuz" --ramdisk "$P/initramfs.cpio.gz" --dtb "$P/dtb-a.dtb" --cmdline "$CL_A" \
    --name linux-a --out "$P/linux-a.img" || exit 1
$FX mkbootimg --kernel "$C/vmlinuz" --ramdisk "$P/initramfs.cpio.gz" --dtb "$P/dtb-b.dtb" --cmdline "$CL_B" \
    --name linux-b --out "$P/linux-b.img" || exit 1
$FX misc --variant b-active --out "$P/misc-b-active.bin" || exit 1

# ---------------------------------------------------------------- 一次运行
# run_one 名字 目录 [qemu_run 额外参数...] -- [check_boot 参数...]
run_one() {
    local name=$1 d=$2 rc=0
    shift 2
    local q=() c=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do q+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    c=("$@")
    $FX snapshot "$d/disk.img" "$d/manifest.json" "$d/before.json" || return 1
    $FX vars "$d/vars.fd" "$d/vars.fd.new" --oneshot gk3boot-e4.conf >/dev/null && mv "$d/vars.fd.new" "$d/vars.fd" || return 1
    python3 qemu/qemu_run.py --code "$CODE" --disk "$d/disk.img" --vars "$d/vars.fd" --log "$d/serial.log" \
        --timeout 900 "${q[@]}" || rc=1
    $FX snapshot "$d/disk.img" "$d/manifest.json" "$d/after.json" || return 1
    echo "盘的前后比对："
    local out r
    out=$($FX diff "$d/before.json" "$d/after.json"); r=$?
    printf '%s\n' "$out" | sed 's/^/  /'
    [ $r = 0 ] || rc=1
    rm -f "$d/boot-0.txt"
    if [ "$name" = espfull ]; then
        $FX esp-get "$d/disk.img" "$d/manifest.json" "EFI/gk3boot/log/boot-0.txt" "$d/boot-0.txt" 2>/dev/null
    else
        $FX esp-get "$d/disk.img" "$d/manifest.json" "EFI/gk3boot/log/boot-0.txt" "$d/boot-0.txt" || rc=1
    fi
    python3 qemu/check_boot.py --label "$name" --serial "$d/serial.log" --logfile "$d/boot-0.txt" \
        --manifest "$d/manifest.json" --version "$BOOT_VERSION" "${c[@]}" || rc=1
    return $rc
}

fresh() {   # $1 目录，其余是 mkdisk 参数
    local d=$1
    shift
    rm -rf "$d" && mkdir -p "$d"
    $FX mkdisk --out "$d" "$@" >/dev/null || return 1
    cp "$VARS0" "$d/vars.fd"
}

OBS="gk3.observe=1 gk3.hold=1"
for s in "${SCEN[@]}"; do
    d=$O/$s
    case $s in
    real)
        say "real：真 gaokun3 boot.img（$(basename "${BOOTIMG:-?}")）→ 决策 / SHA1 / cmdline 与实机对拍 → 交给 zboot stub"
        fresh "$d" --bootimg "$BOOTIMG" --gk3boot-options "$OBS gk3.slot=a" && \
        run_one real "$d" --stop-on "handoff: StartImage" --stop-delay 45 --trace-int "$d/int.log" -- \
            --kind real --bootimg "$BOOTIMG" --slot a --event forced \
            --decision "boot slot=_a active=_a fallback=0" --proc-vector "$PROC_VEC" --int-log "$d/int.log" ;;
    linux-a)
        say "linux-a：通用 arm64 内核经 H2 起到 initramfs（DTB 表 / LoadFile2 / LoadOptions）"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --gk3boot-options "$OBS" && \
        run_one linux-a "$d" --machine-opts acpi=off -- \
            --kind linux --bootimg "$P/linux-a.img" --slot a --event none \
            --decision "boot slot=_a active=_a fallback=0" \
            --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK" ;;
    linux-b)
        say "linux-b：misc 选 _b（会扣 tries，但观察模式不写）+ 长 cmdline + 旧 slot_suffix"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --misc "$P/misc-b-active.bin" \
            --gk3boot-options "$OBS" && \
        run_one linux-b "$d" --machine-opts acpi=off -- \
            --kind linux --bootimg "$P/linux-b.img" --slot b --event none \
            --decision "boot slot=_b active=_b fallback=0" --would-write "_b tries 6 -> 5" \
            --dt-marker "gk3boot-dtb-b-$RUN" --initrd-marker "$IMARK" ;;
    force-a)
        say "force-a：同 linux-b 的 misc，gk3.slot=a 强制 _a"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --misc "$P/misc-b-active.bin" \
            --gk3boot-options "$OBS gk3.slot=a" && \
        run_one force-a "$d" --machine-opts acpi=off -- \
            --kind linux --bootimg "$P/linux-a.img" --slot a --event forced \
            --decision "boot slot=_b active=_b fallback=0" --would-write "_b tries 6 -> 5" \
            --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK" ;;
    strictnx)
        say "strictnx：linux-a 换 AAVMF strict-NX 固件"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --gk3boot-options "$OBS" && \
        run_one strictnx "$d" --machine-opts acpi=off --code "$CODE_NX" -- \
            --kind linux --bootimg "$P/linux-a.img" --slot a --event none \
            --decision "boot slot=_a active=_a fallback=0" \
            --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK" ;;
    espfull)
        say "espfull：ESP 写满 —— 日志写不进去，照样启动"
        fresh "$d" --variant espfull --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --gk3boot-options "$OBS" && \
        run_one espfull "$d" --machine-opts acpi=off -- \
            --kind linux --espfull --bootimg "$P/linux-a.img" --slot a --event none \
            --decision "boot slot=_a active=_a fallback=0" \
            --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK" ;;
    badsha)
        say "badsha：boot_a 的 SHA1(id) 对不上 → fail-open → 默认直连条目"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --corrupt-a --gk3boot-options "$OBS" && \
        run_one badsha "$d" -- --kind failopen --stage boot --decision "boot slot=_a active=_a fallback=0" ;;
    miscerr)
        say "miscerr：misc 读出 EIO（QEMU blkdebug）→ fail-open → 默认直连条目"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --gk3boot-options "$OBS" && {
            # misc 在 LBA 34–2047；gk3boot 读前 64 KiB（LBA 34–161）。注入点选 LBA 154：避开 GPT（0–33）、
            # 也避开 PartitionDxe 在 misc 这个子分区上探 MBR / GPT / El Torito / UDF 时读的几处（≤ LBA 106）
            printf '[inject-error]\nevent = "read_aio"\nerrno = "5"\nsector = "154"\n' > "$d/blkdebug.cfg"
            run_one miscerr "$d" --blkdebug "$d/blkdebug.cfg" -- --kind failopen --stage misc; } ;;
    *) echo "✗ 不认识的场景 $s"; false ;;
    esac
    r=$?
    RESULTS+=("$s=$([ $r = 0 ] && echo PASS || echo FAIL)")
done

echo
echo "══ 汇总：${RESULTS[*]}"
echo "   测试内核：$(cat "$C/vmlinuz.version" 2>/dev/null)"
echo "   gk3boot：tools/gk3boot/build/efi/gk3boot.efi  $(sha256sum build/efi/gk3boot.efi | cut -d' ' -f1)"
echo "   串口与日志：tools/gk3boot/build/qemu-boot/<场景>/serial.log、boot-0.txt"
case " ${RESULTS[*]} " in *=FAIL*) exit 1 ;; esac
exit 0

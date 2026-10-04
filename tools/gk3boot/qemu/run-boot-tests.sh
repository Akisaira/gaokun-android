#!/usr/bin/env bash
# gk3boot.efi（S5：观察模式 + 动作模式）的 QEMU 夹具测试（容器内；宿主上用 scripts/gk3boot/test-boot.sh 一键跑）。
#
#   bash qemu/run-boot-tests.sh [real linux-a … action-normal action-tries …]   默认全跑（没有真 boot.img 时跳过 real）
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
#   （以上 8 个 = E4 那一轮，观察模式、经 OneShot 进入；fail-open 现在会写 OneShot 指向直连条目 <mid>-android-a.conf）
#
# 动作模式（README §11）：gk3boot 是【默认条目】gk3boot-android-<x>[+N].conf（sort-key 0gk3，loader.conf 的
# default "*-android-<x>.conf" 先命中它），不写 OneShot；同一块盘、同一个变量库连开几次，每次都比对 misc 前后（check_misc.py）：
#   action-normal    实机 misc（_a 已成功）→ 正常启动 _a；BCB / BCAB / VAB 逐字节不变，只多一份 GK3 记录（streak=1）；
#                    ESP 上没有新日志、屏幕上一行不打
#   action-tries     _b 15/3 未成功、"Android"从不标成功：第 1–3 次各扣 1（3→2→1→0，CRC 对），第 4 次落到 _a
#                    （event=fallback、记 GK3 事件、写一份日志），第 5 次仍在 _a 但不再重复记（没有新日志）
#   failopen-oneshot 默认条目 gk3boot-android-b+3.conf、boot_b 的 SHA1 坏 → 写 OneShot=<mid>-android-b.conf → 复位进直连条目；
#                    跑两次：OneShot 用过即删（变量库里查不到），第二次又回到 gk3boot（默认条目）、再 fail-open 一次；条目计数 +3→+2-1→+1-2
#   bcb-present      BCB = boot-recovery --wipe_data，分派关 → 照常启动 _a、BCB 原样；第一次记 BCB_IGNORED 事件 + 日志，第二次不重复
#   vab-merging      VAB 合并中、active 槽 _b 不可启动 → 不回落到 _a（守卫），fail-open 到 _b 的直连条目；misc 一个字节不变
#   bcb-dispatch     gk3.dispatch=1 + 已迁移的 GK3 记录 + wipe BCB → 决定"进执行端 why=wipe 第 1 次"，只记录、BCB 原样、照常启动
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
    SCEN=(linux-a linux-b force-a strictnx espfull badsha miscerr
          action-normal action-tries failopen-oneshot bcb-present vab-merging bcb-dispatch)
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
for v in b-active b-try3 b-ok bcb-wipe bcb-wipe-migrated merging; do
    $FX misc --variant $v --out "$P/misc-$v.bin" || exit 1
done

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

# 动作模式的一次启动：act_run 场景 目录 序号。用全局数组 Q（qemu_run 额外参数）、C（check_boot 参数）、
# M（check_misc 参数）。盘和变量库接着上一次用（这才是"每次开机"）；gk3boot 是默认条目，不写 OneShot。
act_run() {
    local name=$1 d=$2 k=$3 rc=0 r out nl
    say "$name #$k"
    $FX snapshot "$d/disk.img" "$d/manifest.json" "$d/before-$k.json" || return 1
    $FX misc-get "$d/disk.img" "$d/manifest.json" "$d/misc-before-$k.bin" || return 1
    python3 qemu/qemu_run.py --code "$CODE" --disk "$d/disk.img" --vars "$d/vars.fd" --log "$d/serial-$k.log" \
        --timeout 900 "${Q[@]}" || rc=1
    $FX snapshot "$d/disk.img" "$d/manifest.json" "$d/after-$k.json" || return 1
    $FX misc-get "$d/disk.img" "$d/manifest.json" "$d/misc-after-$k.bin" || return 1
    echo "盘的前后比对（misc 交给 check_misc.py）："
    out=$($FX diff "$d/before-$k.json" "$d/after-$k.json" --allow-misc --new-logs-out "$d/newlogs-$k.txt"); r=$?
    printf '%s\n' "$out" | sed 's/^/  /'
    [ $r = 0 ] || rc=1
    rm -f "$d/log-$k.txt"
    [ "$(wc -l < "$d/newlogs-$k.txt")" -le 1 ] || { echo "✗ 一次启动多出不止一份日志"; rc=1; }
    nl=$(head -1 "$d/newlogs-$k.txt")
    if [ -n "$nl" ]; then $FX esp-get "$d/disk.img" "$d/manifest.json" "$nl" "$d/log-$k.txt" || rc=1; fi
    python3 qemu/check_boot.py --label "$name#$k" --serial "$d/serial-$k.log" --logfile "$d/log-$k.txt" \
        --manifest "$d/manifest.json" --version "$BOOT_VERSION" --mode action "${C[@]}" || rc=1
    echo "misc（BEFORE → AFTER）："
    python3 qemu/check_misc.py "$d/misc-before-$k.bin" "$d/misc-after-$k.bin" "${M[@]}" || rc=1
    return $rc
}

# 变量库里 systemd-boot 的 LoaderEntryOneShot 已经没了（用过即删，boot.c:1637-1640）、条目计数改名到了 $2
oneshot_gone() {   # $1 目录 $2 期望的条目文件名
    local v
    v=$($FX vars-get "$1/vars.fd" LoaderEntryOneShot)
    printf '  %s LoaderEntryOneShot = %s\n' "$([ "$v" = "(absent)" ] && echo ✓ || echo ✗)" "$v"
    python3 - "$1" "$2" "${3:-}" <<'PY' || return 1
import json, sys, glob
d, want = sys.argv[1], sys.argv[2]
k = sorted(glob.glob(d + "/after-*.json"))[-1]
names = [x for x in json.load(open(k))["esp"] if x.startswith("loader/entries/gk3boot-")]
good = names == ["loader/entries/" + want]
print("  %s 条目 = %s（期望 %s）" % ("✓" if good else "✗", names, want))
sys.exit(0 if good else 1)
PY
    [ "$v" = "(absent)" ]
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
    action-normal)
        say "action-normal：动作模式、默认条目；_a 已成功 → 正常启动，misc 只多 GK3 记录，ESP 零写入"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --gk3boot-options "gk3.hold=1" \
            --gk3boot-entry gk3boot-android-a.conf && {
            Q=(--machine-opts acpi=off)
            C=(--kind linux --bootimg "$P/linux-a.img" --slot a --event none --entry gk3boot-android-a.conf --streak 1
               --no-log --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK")
            M=(--rec-streak 1 --rec-flags 0 --rec-events 0)
            act_run "$s" "$d" 1; } ;;
    action-tries)
        say "action-tries：_b 15/3 未成功，Android 从不标成功 → 扣 3 次、第 4 次回落 _a、第 5 次不重复记"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --misc "$P/misc-b-try3.bin" \
            --gk3boot-options "gk3.observe=0 gk3.hold=1" --gk3boot-entry gk3boot-android-b.conf \
            --loader-default '*-android-b.conf' && {
            r=0
            Q=(--machine-opts acpi=off)
            for k in 1 2 3; do
                C=(--kind linux --bootimg "$P/linux-b.img" --slot b --event none --entry gk3boot-android-b.conf --streak $k
                   --no-log --dt-marker "gk3boot-dtb-b-$RUN" --initrd-marker "$IMARK")
                M=(--bcab "a=14/1/ok b=15/$((3 - k))" --rec-streak $k --rec-flags 0 --rec-events 0)
                act_run "$s" "$d" $k || r=1
            done
            C=(--kind linux --bootimg "$P/linux-a.img" --slot a --event fallback --entry gk3boot-android-b.conf --streak 4
               --decision "boot slot=_a active=_b fallback=1"
               --log-has '^note: fallback: active slot _b is not bootable .* -> booting _a; GK3 event fallback recorded$'
               --log-has '^misc: BCAB not written \(slot already successful\)$'
               --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK")
            M=(--rec-streak 4 --rec-flags 0x2 --rec-events 1 --rec-event fallback:a:1)
            act_run "$s" "$d" 4 || r=1
            C=(--kind linux --bootimg "$P/linux-a.img" --slot a --event fallback --entry gk3boot-android-b.conf --streak 5
               --no-log --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK")
            M=(--rec-streak 5 --rec-flags 0x2 --rec-events 1 --rec-event fallback:a:1)
            act_run "$s" "$d" 5 || r=1
            [ $r = 0 ]; } ;;
    failopen-oneshot)
        say "failopen-oneshot：gk3boot 是默认条目（+3），boot_b 坏 → OneShot 指向直连条目 → 复位后进它，只进一次"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --corrupt-b --misc "$P/misc-b-ok.bin" \
            --gk3boot-options "gk3.hold=1" --gk3boot-entry 'gk3boot-android-b+3.conf' \
            --loader-default '*-android-b.conf' && {
            r=0
            mid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mid"])' "$d/manifest.json")
            Q=()
            for k in 1 2; do
                C=(--kind failopen --stage boot --oneshot "$mid-android-b.conf" --entry "gk3boot-android-b+$((3 - k))-$k.conf"
                   --decision "boot slot=_b active=_b fallback=0"
                   --log-has '^!! FAIL-OPEN at boot: boot_b: SHA1\(id\) MISMATCH'
                   --log-has "^mode: action dispatch=off force_slot=- hint=_b \(from entry name\) hold=1 s entry=gk3boot-android-b\+$((3 - k))-$k\.conf$")
                M=(--rec-streak $k --rec-flags 0 --rec-events 0)
                act_run "$s" "$d" $k || r=1
                echo "OneShot 用过即删、条目计数："
                oneshot_gone "$d" "gk3boot-android-b+$((3 - k))-$k.conf" || r=1
            done
            [ $r = 0 ]; } ;;
    bcb-present)
        say "bcb-present：BCB = boot-recovery --wipe_data，分派关 → 照常启动、BCB 原样，同一份 BCB 只记一次"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --misc "$P/misc-bcb-wipe.bin" \
            --gk3boot-options "gk3.observe=0 gk3.hold=1" --gk3boot-entry gk3boot-android-a.conf && {
            r=0
            Q=(--machine-opts acpi=off)
            C=(--kind linux --bootimg "$P/linux-a.img" --slot a --event none --entry gk3boot-android-a.conf --streak 1
               --log-has '^bcb: kind=wipe command="boot-recovery" args=3$'
               --log-has '^note: bcb: kind=wipe command="boot-recovery" present; dispatch is off \(E-K7\): NOT consumed, NOT cleared, booting Android'
               --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK")
            M=(--rec-streak 1 --rec-flags 0 --rec-events 1 --rec-event bcb_ignored:-:3 --rec-bcb-seen)
            act_run "$s" "$d" 1 || r=1
            C=(--kind linux --bootimg "$P/linux-a.img" --slot a --event none --entry gk3boot-android-a.conf --streak 2
               --no-log --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK")
            M=(--rec-streak 2 --rec-flags 0 --rec-events 1 --rec-event bcb_ignored:-:3 --rec-bcb-seen)
            act_run "$s" "$d" 2 || r=1
            [ $r = 0 ]; } ;;
    vab-merging)
        say "vab-merging：VAB 合并中、_b 不可启动 → 守卫：不回落 _a，fail-open 到 _b 的直连条目"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --misc "$P/misc-merging.bin" \
            --gk3boot-options "gk3.hold=1" --gk3boot-entry gk3boot-android-b.conf --loader-default '*-android-b.conf' && {
            mid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["mid"])' "$d/manifest.json")
            Q=()
            C=(--kind failopen --stage decision --oneshot "$mid-android-b.conf" --entry gk3boot-android-b.conf
               --decision "merging slot=_b active=_b fallback=0"
               --log-has '^vab: valid merge_status=3 source=_a$'
               --log-has 'refusing to fall back to _a \(§4.3.2-4\)')
            M=(--unchanged)
            act_run "$s" "$d" 1; } ;;
    bcb-dispatch)
        say "bcb-dispatch：gk3.dispatch=1 + 已迁移记录 + wipe → 决定进执行端（第 1 次），只记录、BCB 原样、照常启动"
        fresh "$d" --boot-a "$P/linux-a.img" --boot-b "$P/linux-b.img" --misc "$P/misc-bcb-wipe-migrated.bin" \
            --gk3boot-options "gk3.dispatch=1 gk3.hold=1" --gk3boot-entry gk3boot-android-a.conf && {
            Q=(--machine-opts acpi=off)
            C=(--kind linux --bootimg "$P/linux-a.img" --slot a --event none --entry gk3boot-android-a.conf --streak 1
               --log-has '^mode: action dispatch=on '
               --log-has '^note: dispatch: action=executor why=wipe count=1 -> this build has no executor \(S7\): recorded only, BCB left as is, booting Android$'
               --dt-marker "gk3boot-dtb-a-$RUN" --initrd-marker "$IMARK")
            M=(--rec-streak 1 --rec-flags 1 --rec-events 0 --rec-dispatch 3:1)
            act_run "$s" "$d" 1; } ;;
    *) echo "✗ 不认识的场景 $s"; false ;;
    esac
    r=$?
    RESULTS+=("$s=$([ $r = 0 ] && echo PASS || echo FAIL)")
done

echo
echo "══ 汇总：${RESULTS[*]}"
echo "   测试内核：$(cat "$C/vmlinuz.version" 2>/dev/null)"
echo "   gk3boot：tools/gk3boot/build/efi/gk3boot.efi  $(sha256sum build/efi/gk3boot.efi | cut -d' ' -f1)"
echo "   串口与日志：tools/gk3boot/build/qemu-boot/<场景>/serial[-<次>].log、boot-0.txt / log-<次>.txt"
case " ${RESULTS[*]} " in *=FAIL*) exit 1 ;; esac
exit 0

#!/usr/bin/env bash
# gk3probe 的 QEMU 夹具测试（容器内；宿主上用 scripts/gk3boot/test-probe.sh 一键跑）。
#
#   bash qemu/run-tests.sh [first second strictnx broken espfull]     默认五个场景全跑
#
# 环境：VERSION（探针里打印的版本串）、BOOTIMG（完整 boot.img，可无 → boot_a 用合成镜像）
#
# 场景（设计稿 §6 E3 的离线预演，E0）：
#   first     与实机同构的盘 + LoaderEntryOneShot=gk3probe.conf → 探针跑完、ResetSystem(Cold)
#             → 第二次启动自动进 default 的 *-android-a.conf；盘上只多 log-0.txt
#   second    同一块盘、同一个变量库再来一次 → log-1.txt（不覆盖 log-0）、计数 +2-1 → +1-2
#   strictnx  换 AAVMF 的 strict-NX 固件（镜像保护最严的 edk2 配置）重跑 first，看 gnu-efi 产物会不会被拒
#   broken    GPT 里 boot_b 重名、super 缺失 → 探针记录错误、照样跑完并复位
#   espfull   ESP 被占满 → 写日志 VOLUME_FULL，记录后照样跑完并复位（"写入失败也不能挂"）
set -uo pipefail
cd "$(dirname "$0")/.."
O=build/qemu
VERSION=${VERSION:-dev}
CODE=/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd
CODE_NX=/usr/share/AAVMF/AAVMF_CODE.secboot.strictnx.fd
VARS0=/usr/share/AAVMF/AAVMF_VARS.fd
SCEN=("$@")
[ ${#SCEN[@]} -gt 0 ] || SCEN=(first second strictnx broken espfull)
FX="python3 qemu/fixture.py"
RESULTS=()

say() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

echo "▶ 构建 EFI（gnu-efi $(dpkg-query -W -f='${Version}' gnu-efi)，systemd-boot $(dpkg-query -W -f='${Version}' systemd-boot-efi)，" \
     "QEMU $(dpkg-query -W -f='${Version}' qemu-system-arm)，AAVMF $(dpkg-query -W -f='${Version}' qemu-efi-aarch64)）"
make -s -C efi VERSION="$VERSION" 2>&1 | grep -v 'LOAD segment with RWX' || exit 1
[ -f build/efi/gk3probe.efi ] || { echo "✗ 没有产物"; exit 1; }

BOOTARG=()
[ -n "${BOOTIMG:-}" ] && [ -f "$BOOTIMG" ] && BOOTARG=(--bootimg "$BOOTIMG")

# 一次运行：$1 场景名 $2 目录 $3 固件 $4 日志序号 $5 期望计数后缀 $6 check 用的场景
run_one() {
    local name=$1 d=$2 code=$3 n=$4 bc=$5 chk=$6 rc=0
    $FX snapshot "$d/disk.img" "$d/manifest.json" "$d/before-$name.json" || return 1
    $FX vars "$d/vars.fd" "$d/vars.fd.new" --oneshot gk3probe.conf >/dev/null && mv "$d/vars.fd.new" "$d/vars.fd" || return 1
    python3 qemu/qemu_run.py --code "$code" --disk "$d/disk.img" --vars "$d/vars.fd" --log "$d/serial-$name.log" \
        --timeout 600 --inject-on keyscan.begin || rc=1
    $FX snapshot "$d/disk.img" "$d/manifest.json" "$d/after-$name.json" || return 1
    echo "盘的前后比对："
    local out r
    out=$($FX diff "$d/before-$name.json" "$d/after-$name.json"); r=$?
    printf '%s\n' "$out" | sed 's/^/  /'
    [ $r = 0 ] || rc=1
    rm -f "$d/log-$n.txt"
    if [ "$chk" = espfull ]; then
        $FX esp-get "$d/disk.img" "$d/manifest.json" "EFI/gk3boot/probe/log-$n.txt" "$d/log-$n.txt" 2>/dev/null
    else
        $FX esp-get "$d/disk.img" "$d/manifest.json" "EFI/gk3boot/probe/log-$n.txt" "$d/log-$n.txt" || rc=1
    fi
    python3 qemu/check_probe.py --scenario "$chk" --label "$name" --serial "$d/serial-$name.log" \
        --manifest "$d/manifest.json" --logfile "$d/log-$n.txt" --log-n "$n" --bootcount "$bc" || rc=1
    return $rc
}

fresh() {   # $1 目录 $2 变体
    rm -rf "$1" && mkdir -p "$1"
    $FX mkdisk --out "$1" --variant "$2" "${BOOTARG[@]}" || return 1
    cp "$VARS0" "$1/vars.fd"
}

for s in "${SCEN[@]}"; do
    case $s in
    first)
        say "first：OneShot → 探针 → 冷复位 → default 的 Android 条目"
        fresh $O/normal normal && run_one first $O/normal $CODE 0 +2-1 first ;;
    second)
        say "second：同一块盘再跑一次（日志序号递增、不覆盖）"
        [ -f $O/normal/disk.img ] || { fresh $O/normal normal && run_one first $O/normal $CODE 0 +2-1 first >/dev/null; }
        run_one second $O/normal $CODE 1 +1-2 second ;;
    strictnx)
        say "strictnx：AAVMF strict-NX 固件"
        fresh $O/strictnx normal && run_one strictnx $O/strictnx $CODE_NX 0 +2-1 first ;;
    broken)
        say "broken：boot_b 重名 + super 缺失"
        fresh $O/broken broken && run_one broken $O/broken $CODE 0 +2-1 broken ;;
    espfull)
        say "espfull：ESP 一个字节都不剩（写日志失败也不能挂）"
        fresh $O/espfull espfull && run_one espfull $O/espfull $CODE 0 +2-1 espfull ;;
    *) echo "✗ 不认识的场景 $s"; false ;;
    esac
    r=$?
    RESULTS+=("$s=$([ $r = 0 ] && echo PASS || echo FAIL)")
done

echo
echo "══ 汇总：${RESULTS[*]}"
echo "   探针：tools/gk3boot/build/efi/gk3probe.efi  $(sha256sum build/efi/gk3probe.efi | cut -d' ' -f1)"
echo "   串口与日志：tools/gk3boot/build/qemu/<场景>/serial-*.log、log-*.txt"
case " ${RESULTS[*]} " in *=FAIL*) exit 1 ;; esac
exit 0

#!/usr/bin/env bash
# 在真机上验证内置麦克风的修复（PR #10 + 维护者跟进，docs/stage4-findings.md #127 / TODO B24）——
# 【不刷机、不重启】：bind-mount 换上带 0051/0052 的 HAL 二进制与仓库里的策略 XML，重启音频 HAL 与 audioserver，
# 用 gaokun3-mic-smoke 从应用视角录几段，最后撤掉 bind-mount、再重启两个服务。设备重启也会回到原样。
#
#   SER=<ip>:5555 bash scripts/audio/mic-verify.sh <带补丁的 HAL 二进制> [gaokun3-mic-smoke]
#
#   HAL 二进制：构建机上 crdroid-tree-fixes.py 打好 [13]/[14] 之后 `m com.android.hardware.audio`，取
#     out/target/product/gaokun3/apex/com.android.hardware.audio/bin/hw/android.hardware.audio.service-aidl.example
#   gaokun3-mic-smoke（device/huawei/gaokun3/audio/tools/mic-smoke.c）：`m gaokun3-mic-smoke`，或直接用 NDK：
#     $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang -O2 -Wall -Werror \
#         -o gaokun3-mic-smoke mic-smoke.c -laaudio -lm
#
# ★ 顺序：先在【原版】上录一遍（复现 44 字节空录音 —— 基线不对，后面的"修好了"就没有意义），再换、再录。
# ★ 录音不出声，不打扰旁人（MEMORY：宿舍环境）；录下的 WAV 留在设备的 /data/local/tmp/micverify/，拉回本机 out/micverify/。
# ⚠️ bind-mount 要做在 init 的挂载命名空间里（nsenter -t 1 -m），否则 init 拉起的 HAL / audioserver 看不见。
set -uo pipefail
SER=${SER:?SER=<ip>:5555}
HAL=${1:?用法：$0 <带补丁的 HAL 二进制> [gaokun3-mic-smoke]}
SMOKE=${2:-$(cd "$(dirname "$0")/../.." && pwd)/out/micverify/gaokun3-mic-smoke}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
XML=$REPO/device/huawei/gaokun3/audio/primary_audio_policy_configuration.xml
OUT=$REPO/out/micverify/$(date +%Y%m%d-%H%M%S)
D=/data/local/tmp/micverify
HAL_ON_DEV=/apex/com.android.hardware.audio/bin/hw/android.hardware.audio.service-aidl.example
XML_ON_DEV=/vendor/etc/primary_audio_policy_configuration.xml
S() { adb -s "$SER" shell "$@" | tr -d '\r'; }
die() { echo "✗ $*" >&2; exit 1; }
say() { echo; echo "══ $*"; }
mkdir -p "$OUT"

[ -f "$HAL" ] && [ -f "$SMOKE" ] && [ -f "$XML" ] || die "缺文件：$HAL / $SMOKE / $XML"
S true >/dev/null 2>&1 || die "adb 连不上 $SER"
[ "$(S getprop ro.crdroid.device)" = gaokun3 ] || die "$SER 不是 gaokun3"
[ "$(S id -u)" = 0 ] || die "要 adb root"

say "0. 设备与硬件的事实（只读）"
S "getprop ro.build.version.incremental; getprop ro.boot.slot_suffix; getenforce" | sed 's/^/   /'
for d in 2 3; do echo "   tinypcminfo -D 0 -d $d:"; S "tinypcminfo -D 0 -d $d 2>&1 | grep -iE 'channels|rate|capture' | head -6" | sed 's/^/     /'; done
S "ls -la $HAL_ON_DEV $XML_ON_DEV" | sed 's/^/   /'

adb -s "$SER" push "$SMOKE" $D/gaokun3-mic-smoke >/dev/null 2>&1 || { S "mkdir -p $D"; adb -s "$SER" push "$SMOKE" $D/gaokun3-mic-smoke >/dev/null; }
S "chmod 755 $D/gaokun3-mic-smoke"

# 录音矩阵：系统录音机那种（44.1k 单声道）、原生（48k 双声道）、VoIP（16k 单声道 communication）、AAudio 独占低延迟（原先会去 MMAP 的 stub）
CASES=(
  "rec441m|-r 44100 -c 1 -t 5"
  "raw48s|-r 48000 -c 2 -t 5"
  "voip16m|-r 16000 -c 1 -p communication -t 5"
  "lowlat48m|-r 48000 -c 1 -m lowlat -s exclusive -t 5"
)
run_cases() {   # $1=标签（before/after）
    local tag=$1 c name args
    S "logcat -c" >/dev/null
    for c in "${CASES[@]}"; do
        name=${c%%|*}; args=${c#*|}
        echo "   ── ${name}（${args}）" | tee -a "$OUT/$tag.txt"
        S "$D/gaokun3-mic-smoke $args $D/$tag-$name.wav 2>&1" | sed 's/^/     /' | tee -a "$OUT/$tag.txt"
    done
    S "logcat -d" > "$OUT/$tag-logcat.txt"
    echo "   logcat 里的关键行："
    grep -E 'getCardAndDeviceId|MonoPipe capacity|incomplete data|cannot set hw params|pcm_is_ready|proxy_open|MMAP|mmap' "$OUT/$tag-logcat.txt" | sed 's/^/     /' | tail -20
    S "dumpsys media.audio_flinger 2>/dev/null | grep -E '^Output thread|^Input thread|Latency|HAL frame count|Sample rate' | head -30" > "$OUT/$tag-flinger.txt"
}
restart_audio() {
    # init 会把两个都拉起来；HAL 先、audioserver 后（audioserver 起来时去连 HAL）
    S "kill \$(pidof android.hardware.audio.service-aidl.example) 2>/dev/null; sleep 1; kill \$(pidof audioserver) 2>/dev/null; sleep 4"
    S "pidof android.hardware.audio.service-aidl.example >/dev/null && pidof audioserver >/dev/null" \
        || { sleep 4; S "pidof android.hardware.audio.service-aidl.example >/dev/null && pidof audioserver >/dev/null" || die "音频服务没起来（重启设备即可恢复）"; }
}
# 设备上"真正在用"的那份：init 命名空间里的文件 + 正在跑的 HAL 进程的 exe（adb 的命名空间不算数）
dev_sha() { S "nsenter -t 1 -m -- sha256sum $1 | cut -c1-16"; }
hal_exe_sha() { S "sha256sum /proc/\$(pidof android.hardware.audio.service-aidl.example)/exe | cut -c1-16"; }
undo() {
    # ⚠️ 先停 HAL 再卸：HAL 正从被 bind 的那个文件上跑着，普通 umount 会 EBUSY（2026-09-28 第一次跑就这样，
    #    脚本没看出来、还以为撤掉了）。停了 init 也可能立刻把它拉起来，所以再用 umount -l 兜底。
    S "kill \$(pidof android.hardware.audio.service-aidl.example) 2>/dev/null
       nsenter -t 1 -m -- umount $HAL_ON_DEV 2>/dev/null || nsenter -t 1 -m -- umount -l $HAL_ON_DEV 2>/dev/null
       nsenter -t 1 -m -- umount $XML_ON_DEV 2>/dev/null || nsenter -t 1 -m -- umount -l $XML_ON_DEV 2>/dev/null; true" >/dev/null
    restart_audio
}

say "1. 基线：原版 HAL + 原版策略"
run_cases before

say "2. 换上带 0051/0052 的 HAL 与仓库里的策略 XML（bind-mount，不改盘上任何东西）"
ORIG_HAL=$(dev_sha $HAL_ON_DEV); ORIG_XML=$(dev_sha $XML_ON_DEV); NEW_HAL=$(shasum -a 256 "$HAL" | cut -c1-16)
echo "   HAL sha256：本机 ${NEW_HAL} · 设备原版 ${ORIG_HAL}；策略 XML 设备原版 ${ORIG_XML}"
[ "$NEW_HAL" != "$ORIG_HAL" ] || die "设备上跑的已经是这份 HAL（上次没撤干净？先重启设备或手动 umount）"
adb -s "$SER" push "$HAL" $D/hal.bin >/dev/null && adb -s "$SER" push "$XML" $D/primary_audio_policy_configuration.xml >/dev/null || die "推文件失败"
S "chmod 755 $D/hal.bin; chmod 644 $D/primary_audio_policy_configuration.xml; chcon --reference=$HAL_ON_DEV $D/hal.bin 2>/dev/null; chcon --reference=$XML_ON_DEV $D/primary_audio_policy_configuration.xml 2>/dev/null; true"
trap undo EXIT
S "nsenter -t 1 -m -- mount --bind $D/hal.bin $HAL_ON_DEV && nsenter -t 1 -m -- mount --bind $D/primary_audio_policy_configuration.xml $XML_ON_DEV" || die "bind-mount 失败"
restart_audio
[ "$(hal_exe_sha)" = "$NEW_HAL" ] || die "换上之后跑的 HAL 不是本机那份（$(hal_exe_sha)）"
echo "   换上之后正在跑的 HAL：${NEW_HAL} ✓"

say "3. 修复之后"
run_cases after

say "4. 撤掉 bind-mount、重启音频服务 → 回到原样"
trap - EXIT
undo
H1=$(dev_sha $HAL_ON_DEV); X1=$(dev_sha $XML_ON_DEV); E1=$(hal_exe_sha)
if [ "$H1" = "$ORIG_HAL" ] && [ "$E1" = "$ORIG_HAL" ] && [ "$X1" = "$ORIG_XML" ]; then
    echo "   回到原样 ✓（HAL 文件 / 正在跑的 HAL = ${H1}，XML = ${X1}）"
else
    echo "   ✗ 没回到原样：HAL 文件 ${H1} · 正在跑 ${E1} · XML ${X1}（原版 ${ORIG_HAL} / ${ORIG_XML}）—— 重启设备即可恢复" >&2
    RESTORE_FAIL=1
fi

adb -s "$SER" pull $D "$OUT/wav" >/dev/null 2>&1 && S "rm -f $D/*.wav" >/dev/null
say "结果（${OUT}）"
printf '   %-12s %-28s %s\n' 用例 修复前 修复后
for c in "${CASES[@]}"; do
    name=${c%%|*}
    r() { awk -v n="── ${name}（" 'index($0, n) { f = 1; next } f && /RESULT:/ { sub(/.*RESULT: /, ""); print; exit }' "$OUT/$1.txt"; }
    printf '   %-12s %-28s %s\n' "$name" "$(r before)" "$(r after)"
done
exit ${RESTORE_FAIL:-0}

#!/bin/bash
# OTA postinstall（device/huawei/gaokun3/bin/gaokun3-ota-postinstall.sh）的离线测试：选直连条目（OTA-9 + S9 的排除规则）
# 与统一启动入口一节（gk3_deploy）。
#
#   bash tools/gk3boot/test/postinstall/run.sh     （或 make -C tools/gk3boot postinstall-test）
#
# 做法（harness.sh）：脚本原样拷出来，只把 /dev/block/by-name/、/mnt/gaokun3_ota_esp、/mnt/gaokun3_esp_probe 换成测试目录；
# mount / umount / getprop / df / stat / sync / toybox 用桩（mount 不真挂，ESP 就是个目录），解包器换成写死内容的桩。
# 每个场景用 mksh（设备上的 /system/bin/sh 是 mksh）、dash、ksh 各跑一遍 —— 找不到的 shell 跳过（brew install mksh）。
# 最后（hal-test 编过的话）把 postinstall 第一次部署写出的 ESP 交给 HAL 的开机完成逻辑：同版本同模式应零写入
# （= 两边条目正文逐字节一致、"是否已是想要的样子"判据一致）。
#
# ⚠️ 测的是 shell 逻辑：真 vfat、toybox 的各命令细节、SELinux（postinstall 跑在旧槽策略下）要上机看。
set -u
G=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
H=$G/test/postinstall
export GK3_PI_WORK=$G/build/postinstall-test
P=$GK3_PI_WORK; rm -rf "$P"; mkdir -p "$P"
EFI=$P/fake.efi; { printf 'MZ'; head -c 3000 /dev/zero | tr '\0' x; } > "$EFI"
V1=0.9.0-test.g0123456789ab
MID=8a29534fa802480d9fbb71aa18c01d7b
E=$P/run/esp/loader/entries
PASS=0; FAIL=0
ok()  { echo "    ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "    ✗ $*"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
sc() {   # sc <名字> <mode> <vendor 版本或空>
    S=$P/sc-$1; rm -rf "$S"; mkdir -p "$S"; bash "$H/mkesp.sh" "$S"
    printf '%s' "$2" > "$S/mode"
    if [ -n "$3" ]; then mkdir -p "$S/vendor/boot/gk3boot"; cp "$EFI" "$S/vendor/boot/gk3boot/gk3boot.efi"; echo "$3" > "$S/vendor/boot/gk3boot/version"; fi
}
act() {   # act <场景> <版本> <observe> <条目文件名…>：放现役 / 上一版条目（与 HAL 的 EntryText 同格式）
    S=$P/sc-$1; v=$2; o=$3; shift 3
    mkdir -p "$S/esp/EFI/gk3boot/$v"; cp "$EFI" "$S/esp/EFI/gk3boot/$v/gk3boot.efi"
    for n in "$@"; do x=${n#gk3*-android-}; x=${x%%[.+]*}
      printf 'title      Android\nversion    gk3boot-%s\nsort-key   0gk3\nefi        /EFI/gk3boot/%s/gk3boot.efi\noptions    gk3.observe=%s gk3.hint=%s\n' "$v" "$v" "$o" "$x" > "$S/esp/loader/entries/$n"
    done
}
go() { OUT=$(bash "$H/harness.sh" "$SH" "$P/sc-$1" 1 2>&1); RC=$(echo "$OUT" | LC_ALL=C sed -n 's/^RC=//p'); }
gk() { (cd "$E" && ls | grep -E '^gk3' | tr '\n' ' '); }

for SH in mksh dash ksh; do
command -v "$SH" >/dev/null || { echo "════════ ${SH}：没装，跳过"; continue; }
echo "════════ $SH"

echo "  D1 直连 a/b + 祝福过的 gk3boot-android-b.conf + gk3prev-android-b.conf + 一个前缀多一位的假直连条目（OTA-9 只认 <32 位 hex>）"
sc d1 observe ""
act d1 "$V1" 1 gk3boot-android-b.conf gk3prev-android-b.conf
cp "$P/sc-d1/esp/loader/entries/$MID-android-b.conf" "$P/sc-d1/esp/loader/entries/X$MID-android-b.conf"
go d1
chk "RC=0、选中的是直连条目" '[ "$RC" = 0 ] && echo "$OUT" | grep -q "启动项 = $MID-android-b.conf"'
chk "直连条目 options 同步、内核写进 slot_b" 'grep -q "^options    console=tty0 foo=bar androidboot.slot_suffix=_b" "$E/$MID-android-b.conf" && [ "$(cat "$P/run/esp/$MID/android/slot_b/Image")" = IMAGE ]'
chk "gk3boot / gk3prev 条目没被碰（vendor 不带入口）" 'grep -q "^options    gk3.observe=1 gk3.hint=b" "$E/gk3boot-android-b.conf" && [ -f "$E/gk3prev-android-b.conf" ]'

echo "  P1 没设属性（off）、ESP 上没有入口 ⇒ 什么都不做"
sc p1 "" "$V1"; go p1
chk "RC=0、没有 gk3 条目、没有 EFI/gk3boot" '[ "$RC" = 0 ] && [ -z "$(gk)" ] && [ ! -e "$P/run/esp/EFI/gk3boot" ]'

echo "  P2 observe、第一次部署"
sc p2 observe "$V1"; go p2
chk "RC=0、条目 = +3 ×2" '[ "$RC" = 0 ] && [ "$(gk)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf " ]'
chk "二进制写好、与 vendor 一致、没有 .new" 'cmp -s "$EFI" "$P/run/esp/EFI/gk3boot/$V1/gk3boot.efi" && ! find "$P/run/esp" -name "*.new" | grep -q .'
chk "条目正文" '[ "$(cat "$E/gk3boot-android-b+3.conf")" = "$(printf "title      Android (gk3boot observe)\nversion    gk3boot-%s\nsort-key   0gk3\nefi        /EFI/gk3boot/%s/gk3boot.efi\noptions    gk3.observe=1 gk3.hint=b" $V1 $V1)" ]'
chk "直连条目照常同步、内核照常写" 'grep -q "^options    console=tty0 foo=bar androidboot.slot_suffix=_b" "$E/$MID-android-b.conf" && [ "$(cat "$P/run/esp/$MID/android/slot_b/Image")" = IMAGE ]'
rm -rf "$P/p2-esp"; cp -R "$P/run/esp" "$P/p2-esp"

echo "  P3 observe、ESP 上已是这一版这个模式（一个祝福过、一个 +2-1）、有陈旧 .staged ⇒ 条目不动、清 .staged"
sc p3 observe "$V1"; act p3 "$V1" 1 gk3boot-android-a.conf gk3boot-android-b+2-1.conf
printf 'x\n' > "$P/sc-p3/esp/loader/entries/gk3boot-android-a.conf.staged"
go p3
chk "条目不变、陈旧 .staged 被清" '[ "$RC" = 0 ] && [ "$(gk)" = "gk3boot-android-a.conf gk3boot-android-b+2-1.conf " ]'

echo "  P4 action、ESP 上是同版本 observe ⇒ 写 .staged（observe=0），现役不动"
sc p4 action "$V1"; act p4 "$V1" 1 gk3boot-android-a.conf gk3boot-android-b.conf; go p4
chk "现役 + .staged ×2" '[ "$(gk)" = "gk3boot-android-a.conf gk3boot-android-a.conf.staged gk3boot-android-b.conf gk3boot-android-b.conf.staged " ]'
chk ".staged 是 observe=0、title Android" 'grep -q "^options    gk3.observe=0 gk3.hint=a$" "$E/gk3boot-android-a.conf.staged" && grep -q "^title      Android$" "$E/gk3boot-android-a.conf.staged"'

echo "  P5 vendor 是新版 V2、ESP 上现役 V1 ⇒ V2 目录 + .staged，V1 原样"
sc p5 action V2; act p5 "$V1" 0 gk3boot-android-a.conf gk3boot-android-b.conf; go p5
chk "V1、V2 目录都在" '[ -f "$P/run/esp/EFI/gk3boot/$V1/gk3boot.efi" ] && [ -f "$P/run/esp/EFI/gk3boot/V2/gk3boot.efi" ]'
chk ".staged 指 V2、现役仍指 V1" 'grep -qF "/EFI/gk3boot/V2/gk3boot.efi" "$E/gk3boot-android-b.conf.staged" && grep -qF "/EFI/gk3boot/$V1/" "$E/gk3boot-android-b.conf"'

echo "  P6 off、ESP 上有现役 / +3 / gk3prev / .staged ⇒ 条目全删、目录留着"
sc p6 off "$V1"; act p6 "$V1" 0 gk3boot-android-a.conf gk3boot-android-b+3.conf gk3prev-android-a.conf gk3boot-android-b.conf.staged; go p6
chk "没有 gk3 条目、目录还在、直连条目还在" '[ "$RC" = 0 ] && [ -z "$(gk)" ] && [ -d "$P/run/esp/EFI/gk3boot/$V1" ] && [ -f "$E/$MID-android-a.conf" ]'

echo "  P7 非法模式 ⇒ 不动"
sc p7 Action "$V1"; act p7 "$V1" 0 gk3boot-android-a.conf; go p7
chk "条目不变、RC=0" '[ "$RC" = 0 ] && [ "$(gk)" = "gk3boot-android-a.conf " ]'

echo "  P8 vendor 不带入口 ⇒ 不动"
sc p8 action ""; act p8 "$V1" 0 gk3boot-android-a.conf; go p8
chk "条目不变、RC=0" '[ "$RC" = 0 ] && [ "$(gk)" = "gk3boot-android-a.conf " ]'

echo "  P9 空间账：可用 42000 KB（够内核、不够内核 + 入口）"
sc p9 observe "$V1"; FREE_KB=42000 go p9
chk "observe ⇒ 空间不足、RC=1" '[ "$RC" = 1 ]'
sc p9 off "$V1"; FREE_KB=42000 go p9
chk "off ⇒ 照常通过" '[ "$RC" = 0 ]'

echo "  P10 写二进制失败（EFI/gk3boot 是个文件）⇒ 不部署、OTA 照样成功"
sc p10 action "$V1"; mkdir -p "$P/sc-p10/esp/EFI"; echo x > "$P/sc-p10/esp/EFI/gk3boot"; go p10
chk "RC=0、没有 gk3 条目" '[ "$RC" = 0 ] && [ -z "$(gk)" ]'

echo "  P11 版本串不合法 ⇒ 不部署"
sc p11 action 'bad/ver'; go p11
chk "RC=0、没有条目" '[ "$RC" = 0 ] && [ -z "$(gk)" ]'
done

D=$G/build/hal-test/driver
if [ -x "$D" ] && [ -d "$P/p2-esp" ]; then
    echo "════════ 交叉：postinstall 第一次部署的 ESP → HAL 开机完成逻辑（${D}）"
    T=$G/build/hal-test/t
    rm -rf "$T"; mkdir -p "$T/vendor/boot/gk3boot"; cp -R "$P/p2-esp" "$T/esp"
    cp "$EFI" "$T/vendor/boot/gk3boot/gk3boot.efi"; echo "$V1" > "$T/vendor/boot/gk3boot/version"
    "$D" nomisc "$T/misc.img"
    mv "$T/esp/loader/entries/gk3boot-android-b+3.conf" "$T/esp/loader/entries/gk3boot-android-b+2-1.conf"
    printf 'persist.vendor.gaokun3.gk3boot=observe\nro.boot.gk3boot.entry=gk3boot-android-b+2-1.conf\n' > "$T/props"
    OUT=$(GK3T_PROPS="$T/props" "$D" run 2>/dev/null)
    chk "第一次经入口开机：只 bless（条目 = a+3、b）" '[ "$(cd "$T/esp/loader/entries" && ls | grep ^gk3 | tr "\n" " ")" = "gk3boot-android-a+3.conf gk3boot-android-b.conf " ]'
    printf 'persist.vendor.gaokun3.gk3boot=observe\nro.boot.gk3boot.entry=gk3boot-android-b.conf\n' > "$T/props"
    OUT=$(GK3T_PROPS="$T/props" "$D" run 2>/dev/null)
    chk "再开一次：HAL 判'已是想要的样子'、只读挂、零写入" 'echo "$OUT" | grep -q "^mounts: ro=1 rw=0$" && echo "$OUT" | grep -q "^bootentry.version=$V1$"'
else
    echo "════════ 交叉：跳过（先 bash tools/gk3boot/test/hal/run.sh 编出 HAL 的主机测试程序）"
fi
echo "══ postinstall：通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]

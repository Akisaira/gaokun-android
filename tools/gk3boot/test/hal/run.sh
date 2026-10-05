#!/bin/bash
# boot_control HAL 开机完成线程（device/huawei/gaokun3/boot_control/Gk3Boot.cpp）的主机场景测试。
#
#   bash tools/gk3boot/test/hal/run.sh        （或 make -C tools/gk3boot hal-test）
#
# 做法：把 Gk3Boot.cpp 原样编成主机程序 —— 只把三个设备路径（/vendor/boot/gk3boot/、
# /dev/block/by-name/misc、ESP 挂载点 /mnt/gaokun3_esp）用 sed 换成测试目录；libbase 用 stub/ 里的
# 最小桩（属性是一张表，WaitForProperty 轮询它）；EspSlot 换成 espstub.cpp（不真挂载、只数挂了几次只读 /
# 读写）；bionic 有、macOS 没有的 O_DIRECT / TEMP_FAILURE_RETRY 由 shim.h 补。ASan + UBSan。
# 场景（S1–S14）覆盖：零写入（只读挂）、首次部署、bless、清 streak 与事件、升级轮换成 gk3prev、
# 未祝福的旧版不升格、模式切换、.staged 激活、OTA 回滚丢弃 .staged、off 撤除、实验条目与 log/ 不回收、
# 非法模式、缺直连条目、vendor 没带入口、观察模式的 cmdline fallback、ESP 挂不上。
#
# ⚠️ 测的是逻辑，不是 Android：SELinux、真 vfat（大小写、rename 覆盖）、O_DIRECT 对齐、属性服务都要上机看。
set -eu
G=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)        # tools/gk3boot
REPO=$(cd "$G/../.." && pwd)
H=$G/test/hal
B=$G/build/hal-test; T=$B/t; D=$B/driver
rm -rf "$B"; mkdir -p "$B/src"
BC=$REPO/device/huawei/gaokun3/boot_control
sed -e "s#\"/vendor/boot/gk3boot/#\"$T/vendor/boot/gk3boot/#g" -e "s#\"/dev/block/by-name/misc\"#\"$T/misc.img\"#" \
    "$BC/Gk3Boot.cpp" > "$B/src/Gk3Boot.cpp"
[ "$(grep -c "$T" "$B/src/Gk3Boot.cpp")" -ge 3 ] || { echo "路径替换没生效（Gk3Boot.cpp 里的常量改名了？）"; exit 1; }
sed -e "s#\"/mnt/gaokun3_esp\"#\"$T/esp\"#" "$BC/EspSlot.h" > "$B/src/EspSlot.h"
grep -q "$T/esp" "$B/src/EspSlot.h" || { echo "EspSlot.h 的 kEspRoot 替换没生效"; exit 1; }
cp "$BC/Gk3Boot.h" "$B/src/"
for f in "$G"/core/src/*.c; do
    clang -std=gnu17 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -I"$G/core/include" -c "$f" -o "$B/$(basename "$f" .c).o"
done
CXXF=(-std=c++20 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined
      -include "$H/shim.h" -I"$H/stub" -I"$B/src" -I"$G/core/include")
clang++ "${CXXF[@]}" -c "$B/src/Gk3Boot.cpp" -o "$B/Gk3Boot.o"
clang++ "${CXXF[@]}" -c "$H/espstub.cpp" -o "$B/espstub.o"
clang++ "${CXXF[@]}" -c "$H/driver.cpp" -o "$B/driver.o"
clang++ -fsanitize=address,undefined "$B"/*.o -o "$D"
set +e
MID=8a29534fa802480d9fbb71aa18c01d7b
PASS=0; FAIL=0
md5q() { if command -v md5 >/dev/null; then md5 -q "$1"; else md5sum "$1" | cut -d' ' -f1; fi; }
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

fresh() {   # 全新：直连 a/b、vendor 版本 $1（空 = vendor 没带 gk3boot）、misc 无记录
    rm -rf "$T"; mkdir -p "$T/esp/loader/entries" "$T/esp/EFI/BOOT"
    for s in a b; do printf 'title crDroid\nsort-key zandroid%s\nlinux /%s/android/slot_%s/Image\n' $s $MID $s > "$T/esp/loader/entries/$MID-android-$s.conf"; done
    vendor "$1"
    "$D" nomisc "$T/misc.img"
}
vendor() {
    rm -rf "$T/vendor"
    [ -n "$1" ] || return 0
    mkdir -p "$T/vendor/boot/gk3boot"
    { printf 'MZ'; head -c 3000 /dev/zero | tr '\0' "${2:-x}"; } > "$T/vendor/boot/gk3boot/gk3boot.efi"
    echo "$1" > "$T/vendor/boot/gk3boot/version"
}
run() {   # run <mode> <entry> [event]
    { echo "persist.vendor.gaokun3.gk3boot=$1"; [ -n "$2" ] && echo "ro.boot.gk3boot.entry=$2"; [ -n "${3:-}" ] && echo "ro.boot.gk3boot.event=$3"; } > "$T/props"
    OUT=$(GK3T_PROPS="$T/props" "$D" run 2>"$T/log"); echo "$OUT" | sed 's/^/    /'
}
p() { echo "$OUT" | sed -n "s/^bootentry\.$1=//p"; }
mounts() { echo "$OUT" | sed -n 's/^mounts: //p'; }
ls_e() { (cd "$T/esp/loader/entries" && ls | grep -E '^gk3' | tr '\n' ' '); }
snap() { (cd "$T/esp" && find . -type f | LC_ALL=C sort | while read -r f; do md5q "$f"; echo " $f"; done); }

echo "═ S1 off、什么都没部署、直连开机、misc 无记录 ⇒ 只读挂、零写入"
fresh V1; S0=$(snap); run off ""
chk "mode=off via=direct bypassed=0" '[ "$(p mode)" = off ] && [ "$(p via)" = direct ] && [ "$(p bypassed)" = 0 ]'
chk "只读挂一次、没有读写挂" '[ "$(mounts)" = "ro=1 rw=0" ]'
chk "ESP 一字未改" '[ "$(snap)" = "$S0" ]'
chk "streak 为空（无记录）、notify 空、error 空" '[ -z "$(p streak)" ] && [ -z "$(p notify)" ] && [ -z "$(p error)" ]'
chk "done 有值" '[ -n "$(p done)" ]'

echo "═ S2 设成 observe 重启（直连开机）⇒ 部署 V1、两个 +3 条目"
run observe ""
chk "mode=observe version=V1" '[ "$(p mode)" = observe ] && [ "$(p version)" = V1 ]'
chk "条目 = gk3boot-android-{a,b}+3.conf" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf " ]'
chk "二进制与 vendor 相同" 'cmp -s "$T/esp/EFI/gk3boot/V1/gk3boot.efi" "$T/vendor/boot/gk3boot/gk3boot.efi"'
chk "条目内容（observe、hint、sort-key、efi）" 'grep -q "^options    gk3.observe=1 gk3.hint=b$" "$T/esp/loader/entries/gk3boot-android-b+3.conf" && grep -q "^sort-key   0gk3$" "$T/esp/loader/entries/gk3boot-android-b+3.conf" && grep -q "^efi        /EFI/gk3boot/V1/gk3boot.efi$" "$T/esp/loader/entries/gk3boot-android-b+3.conf"'
chk "bypassed=0（部署之前没有入口）" '[ "$(p bypassed)" = 0 ]'
chk "读写挂一次" '[ "$(mounts)" = "ro=1 rw=1" ]'
chk "没有残留 .new" '! find "$T/esp" -name "*.new" | grep -q .'

echo "═ S3 经 gk3boot-android-b+2-1 开机（systemd-boot 改过名）、GK3 streak=3、有未通知的 fallback ⇒ bless + 清零 + 通知"
mv "$T/esp/loader/entries/gk3boot-android-b+3.conf" "$T/esp/loader/entries/gk3boot-android-b+2-1.conf"
"$D" mkmisc "$T/misc.img" 3 bcb_ignored fallback:notified fallback
run observe gk3boot-android-b+2-1.conf
chk "bless：b 去掉计数，a 仍是 +3" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b.conf " ]'
chk "via=gk3boot streak=3 notify=fallback" '[ "$(p via)" = gk3boot ] && [ "$(p streak)" = 3 ] && [ "$(p notify)" = fallback ]'
"$D" dump "$T/misc.img" > "$T/dump"; sed 's/^/    /' "$T/dump"
chk "misc：streak=0、三条事件全部已通知、同块里记录之后的字节原样" 'grep -q "streak=0" "$T/dump" && ! grep -q "notified=0" "$T/dump" && grep -q "preserved: yes" "$T/dump"'

echo "═ S3b 同一状态再开一次（已祝福、streak 已是 0）⇒ 零写入"
S0=$(snap); M0=$(md5q "$T/misc.img"); run observe gk3boot-android-b.conf
chk "只读挂、ESP 与 misc 都没变" '[ "$(mounts)" = "ro=1 rw=0" ] && [ "$(snap)" = "$S0" ] && [ "$(md5q "$T/misc.img")" = "$M0" ]'
chk "notify 空、streak=0" '[ -z "$(p notify)" ] && [ "$(p streak)" = 0 ]'

echo "═ S4 OTA 到带 V2 的系统（新槽 vendor = V2）⇒ V1（祝福过）变 gk3prev，V2 +3"
vendor V2 y; run observe gk3boot-android-b.conf
chk "条目 = gk3boot +3 ×2、gk3prev ×2" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf gk3prev-android-a.conf gk3prev-android-b.conf " ]'
chk "gk3prev 指向 V1、sort-key 0gk3prev、title" 'grep -q "^efi        /EFI/gk3boot/V1/gk3boot.efi$" "$T/esp/loader/entries/gk3prev-android-a.conf" && grep -q "^sort-key   0gk3prev$" "$T/esp/loader/entries/gk3prev-android-a.conf" && grep -q "^title      Android (previous loader)$" "$T/esp/loader/entries/gk3prev-android-a.conf"'
chk "V1、V2 两个目录都在" '[ -f "$T/esp/EFI/gk3boot/V1/gk3boot.efi" ] && [ -f "$T/esp/EFI/gk3boot/V2/gk3boot.efi" ]'
chk "mode=observe version=V2" '[ "$(p mode)" = observe ] && [ "$(p version)" = V2 ]'

echo "═ S5 V2 还没被祝福（全带计数）就又来 V3 ⇒ 不升格 V2，gk3prev 仍是 V1，V2 目录被回收"
vendor V3 z; run observe ""
chk "gk3prev 仍指 V1" 'grep -q "/EFI/gk3boot/V1/" "$T/esp/loader/entries/gk3prev-android-b.conf"'
chk "现役 V3 +3" 'grep -q "/EFI/gk3boot/V3/" "$T/esp/loader/entries/gk3boot-android-a+3.conf"'
chk "V2 目录没了，V1、V3 在" '[ ! -e "$T/esp/EFI/gk3boot/V2" ] && [ -d "$T/esp/EFI/gk3boot/V1" ] && [ -d "$T/esp/EFI/gk3boot/V3" ]'
chk "bypassed=1（入口在、这次直连）" '[ "$(p bypassed)" = 1 ]'

echo "═ S6 同一版本 observe → action ⇒ 重写 +3、gk3.observe=0、title Android；gk3prev 不动"
mv "$T/esp/loader/entries/gk3boot-android-a+3.conf" "$T/esp/loader/entries/gk3boot-android-a+1-2.conf"
run action gk3boot-android-a+1-2.conf
chk "条目 = +3 ×2 + gk3prev ×2" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf gk3prev-android-a.conf gk3prev-android-b.conf " ]'
chk "options gk3.observe=0、title Android" 'grep -q "^options    gk3.observe=0 gk3.hint=a$" "$T/esp/loader/entries/gk3boot-android-a+3.conf" && grep -q "^title      Android$" "$T/esp/loader/entries/gk3boot-android-a+3.conf"'
chk "gk3prev 仍指 V1" 'grep -q "/EFI/gk3boot/V1/" "$T/esp/loader/entries/gk3prev-android-a.conf"'

echo "═ S7 postinstall 留下的 .staged（V4）+ 新槽 vendor = V4 ⇒ 激活：V3 祝福过 → gk3prev，V4 +3，.staged 没了"
mv "$T/esp/loader/entries/gk3boot-android-a+3.conf" "$T/esp/loader/entries/gk3boot-android-a.conf"   # V3 在 a 上被祝福过
mkdir -p "$T/esp/EFI/gk3boot/V4"; vendor V4 w; cp "$T/vendor/boot/gk3boot/gk3boot.efi" "$T/esp/EFI/gk3boot/V4/"
for s in a b; do printf 'title Android\nsort-key 0gk3\nefi /EFI/gk3boot/V4/gk3boot.efi\noptions gk3.observe=0 gk3.hint=%s\n' $s > "$T/esp/loader/entries/gk3boot-android-$s.conf.staged"; done
run action gk3boot-android-a.conf
chk "条目 = +3 ×2 + gk3prev ×2，没有 .staged" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf gk3prev-android-a.conf gk3prev-android-b.conf " ]'
chk "gk3prev → V3、现役 → V4" 'grep -q "/EFI/gk3boot/V3/" "$T/esp/loader/entries/gk3prev-android-a.conf" && grep -q "/EFI/gk3boot/V4/" "$T/esp/loader/entries/gk3boot-android-b+3.conf"'
chk "V1 目录被回收（不再有人引用），V3、V4 在" '[ ! -e "$T/esp/EFI/gk3boot/V1" ] && [ -d "$T/esp/EFI/gk3boot/V3" ] && [ -d "$T/esp/EFI/gk3boot/V4" ]'

echo "═ S8 OTA 回滚：盘上有 V9 的 .staged，而跑的系统是 V4 ⇒ 删 .staged、回收 V9，现役 V4 不动"
mv "$T/esp/loader/entries/gk3boot-android-a+3.conf" "$T/esp/loader/entries/gk3boot-android-a.conf"
mkdir -p "$T/esp/EFI/gk3boot/V9"; echo x > "$T/esp/EFI/gk3boot/V9/gk3boot.efi"
for s in a b; do printf 'efi /EFI/gk3boot/V9/gk3boot.efi\noptions gk3.observe=0\n' > "$T/esp/loader/entries/gk3boot-android-$s.conf.staged"; done
run action gk3boot-android-a.conf
chk "没有 .staged、V9 没了、现役仍 V4（a 已祝福、b +3）" '! ls "$T/esp/loader/entries" | grep -q staged && [ ! -e "$T/esp/EFI/gk3boot/V9" ] && [ "$(ls_e)" = "gk3boot-android-a.conf gk3boot-android-b+3.conf gk3prev-android-a.conf gk3prev-android-b.conf " ]'

echo "═ S9 手放的实验条目引用的目录不回收；log/ 不回收；off ⇒ 我们的条目与目录全撤"
mkdir -p "$T/esp/EFI/gk3boot/e4" "$T/esp/EFI/gk3boot/log"; echo x > "$T/esp/EFI/gk3boot/e4/gk3boot.efi"; echo l > "$T/esp/EFI/gk3boot/log/boot-0.txt"
printf 'title e4\nefi \\EFI\\gk3boot\\e4\\gk3boot.efi\n' > "$T/esp/loader/entries/gk3boot-e4.conf"
run off gk3boot-android-a.conf
chk "我们的条目全没了，实验条目还在" '[ "$(ls_e)" = "gk3boot-e4.conf " ]'
chk "V3/V4 没了；e4、log 还在" '[ ! -e "$T/esp/EFI/gk3boot/V3" ] && [ ! -e "$T/esp/EFI/gk3boot/V4" ] && [ -f "$T/esp/EFI/gk3boot/e4/gk3boot.efi" ] && [ -f "$T/esp/EFI/gk3boot/log/boot-0.txt" ]'
chk "直连条目还在" '[ -f "$T/esp/loader/entries/$MID-android-a.conf" ] && [ -f "$T/esp/loader/entries/$MID-android-b.conf" ]'
chk "mode=off" '[ "$(p mode)" = off ]'

echo "═ S10 非法模式 ⇒ 不动 ESP、报错"
run action ""; S0=$(snap); run Action ""
chk "ESP 没变、mode=action（现状）、error 提到属性" '[ "$(snap)" = "$S0" ] && [ "$(p mode)" = action ] && echo "$(p error)" | grep -q gk3boot'

echo "═ S11 没有直连条目 ⇒ 不部署"
fresh V1; rm "$T/esp/loader/entries/"*-android-?.conf; run observe ""
chk "没有 gk3 条目、error 提到直连条目、mode=off" '[ -z "$(ls_e)" ] && echo "$(p error)" | grep -q "machine-id" && [ "$(p mode)" = off ]'

echo "═ S12 vendor 没带 gk3boot ⇒ 不部署、不撤"
fresh ""; run observe ""
chk "没有条目、error=no /vendor…" '[ -z "$(ls_e)" ] && echo "$(p error)" | grep -q "no /vendor"'

echo "═ S13 观察模式（misc 无记录）+ cmdline event=fallback ⇒ notify=fallback"
fresh V1; run observe "" ; run observe gk3boot-android-a+2-1.conf fallback
chk "notify=fallback event=fallback" '[ "$(p notify)" = fallback ] && [ "$(p event)" = fallback ]'

echo "═ S14 ESP 挂不上 ⇒ error、mode=unknown，misc 照样清"
fresh V1; "$D" mkmisc "$T/misc.img" 2
export GK3T_NOMOUNT=1; run action ""; unset GK3T_NOMOUNT
chk "error=cannot mount ESP、streak=2 已清" 'echo "$(p error)" | grep -q "cannot mount" && [ "$(p mode)" = unknown ] && "$D" dump "$T/misc.img" | grep -q "streak=0"'

echo "═ ASan/UBSan 报告"
chk "日志里没有 sanitizer 报错" '! grep -q "ERROR: AddressSanitizer\|runtime error" "$T/log"'
echo "══ 通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]

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
# S15–S23：执行端 fastboot.img（随入口部署 / 轮换 / 整目录回收、坏了重写、空间不够或不是 gzip 时不挡入口、
# vendor 不带时删同版本目录里陈旧的那份）与非默认条目 gk3boot-tools.conf（只在 action + 执行端就位时部署、
# 跟着现役换版本、observe / off 时删、指着旧目录时改回来）。ESP 剩余空间用 shim.h 的 GK3T_ESP_FREE_KB 假装。
#
# S24–S30（S15 双系统）：windows / loader_replaced / default / default_pending / menu 的导出（只读）、请求线程
# （next_windows / default_windows / default_android，ring → ack，没有 Windows / 没有记录 / ESP 挂不上 / 不认识的请求）、
# 关机标记 --gk3-mark-poweroff（重启、非动作模式、直连、默认 Android、未应用的 set_default、没有记录）、新事件进 notify。
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
vfb() {   # vfb <KB> [填充字符]：给 vendor 加一份执行端 fastboot.img（gzip 魔数开头）
    { printf '\037\213\010'; head -c $(($1 * 1024)) /dev/zero | tr '\0' "${2:-f}"; } > "$T/vendor/boot/gk3boot/fastboot.img"
}
run() {   # run <mode> <entry> [event]
    { echo "persist.vendor.gaokun3.gk3boot=$1"; [ -n "$2" ] && echo "ro.boot.gk3boot.entry=$2"; [ -n "${3:-}" ] && echo "ro.boot.gk3boot.event=$3"
      [ -n "${XPROPS:-}" ] && printf '%s\n' $XPROPS; } > "$T/props"
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

# ── 执行端 fastboot.img 与 gk3boot-tools.conf（S15–S23）──
TOOLS_V() { printf 'title      Android fastboot / boot menu\nversion    gk3boot-%s\nsort-key   0gk3tools\nefi        /EFI/gk3boot/%s/gk3boot.efi\noptions    gk3.action=fastboot\n' "$1" "$1"; }
TE=$T/esp/loader/entries
fbeq() { cmp -s "$T/esp/EFI/gk3boot/$1/fastboot.img" "$T/vendor/boot/gk3boot/fastboot.img"; }

echo "═ S15 action、vendor V1 带 fastboot.img、第一次部署 ⇒ 二进制 + 执行端 + +3 ×2 + gk3boot-tools.conf"
fresh V1; vfb 300 f; run action ""
chk "条目 = +3 ×2 + gk3boot-tools.conf" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf gk3boot-tools.conf " ]'
chk "fastboot.img 与 vendor 逐字节相同、没有 .new" 'fbeq V1 && ! find "$T/esp" -name "*.new" | grep -q .'
chk "gk3boot-tools.conf 正文逐字节" '[ "$(cat "$TE/gk3boot-tools.conf")" = "$(TOOLS_V V1)" ]'
chk "mode=action version=V1 error 空" '[ "$(p mode)" = action ] && [ "$(p version)" = V1 ] && [ -z "$(p error)" ]'

echo "═ S15b 经 gk3boot-tools.conf 进执行端再回 Android ⇒ 不 bless、不算 bypassed、via=gk3boot；bless 之后再开零写入"
S0=$(snap); run action gk3boot-tools.conf
chk "via=gk3boot bypassed=0、ESP 没变（只读挂）" '[ "$(p via)" = gk3boot ] && [ "$(p bypassed)" = 0 ] && [ "$(snap)" = "$S0" ] && [ "$(mounts)" = "ro=1 rw=0" ]'
mv "$TE/gk3boot-android-a+3.conf" "$TE/gk3boot-android-a+2-1.conf"; run action gk3boot-android-a+2-1.conf
S0=$(snap); run action gk3boot-android-a.conf
chk "bless 之后再开：只读挂、零写入（fastboot.img 与 tools 都判'已是这一版'）" '[ "$(mounts)" = "ro=1 rw=0" ] && [ "$(snap)" = "$S0" ]'

echo "═ S16 OTA 到 V2（带执行端）⇒ V1 → gk3prev、tools 跟着换到 V2、两个目录各有自己的 fastboot.img"
vendor V2 y; vfb 310 g; run action gk3boot-android-a.conf
chk "条目 = +3 ×2 + tools + gk3prev ×2" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf gk3boot-tools.conf gk3prev-android-a.conf gk3prev-android-b.conf " ]'
chk "tools → V2" '[ "$(cat "$TE/gk3boot-tools.conf")" = "$(TOOLS_V V2)" ]'
chk "V2/fastboot.img = vendor、V1/ 的 gk3boot.efi + fastboot.img 还在（gk3prev 那一版）" 'fbeq V2 && [ -f "$T/esp/EFI/gk3boot/V1/fastboot.img" ] && [ -f "$T/esp/EFI/gk3boot/V1/gk3boot.efi" ]'

echo "═ S17 同版本 action → observe ⇒ tools 删掉、fastboot.img 照样在（文件规则与 gk3boot.efi 相同）"
run observe ""
chk "没有 tools、+3 ×2 是 observe" '! [ -e "$TE/gk3boot-tools.conf" ] && grep -q "gk3.observe=1" "$TE/gk3boot-android-a+3.conf"'
chk "V2/fastboot.img 还在" 'fbeq V2'

echo "═ S18 回到 action、ESP 上 V2/fastboot.img 被改坏 ⇒ 重写、tools 回来"
printf 'junk' > "$T/esp/EFI/gk3boot/V2/fastboot.img"; run action ""
chk "fastboot.img 重写成 vendor 那份、tools → V2" 'fbeq V2 && [ "$(cat "$TE/gk3boot-tools.conf")" = "$(TOOLS_V V2)" ]'
chk "error 空" '[ -z "$(p error)" ]'

echo "═ S19 tools 指着一个旧目录（手改 / 半路断电）⇒ 改回现役那一版、旧目录没人引用就回收"
mkdir -p "$T/esp/EFI/gk3boot/V0"; echo x > "$T/esp/EFI/gk3boot/V0/gk3boot.efi"; TOOLS_V V0 > "$TE/gk3boot-tools.conf"; run action ""
chk "tools → V2、V0 被回收、V1（gk3prev）还在" '[ "$(cat "$TE/gk3boot-tools.conf")" = "$(TOOLS_V V2)" ] && [ ! -e "$T/esp/EFI/gk3boot/V0" ] && [ -d "$T/esp/EFI/gk3boot/V1" ]'

echo "═ S20 新槽 vendor V3 不带执行端（ESP 上 V3/ 里却有一份陈旧的 fastboot.img）⇒ 入口照常换到 V3、tools 删、陈旧那份删"
for s in a b; do mv "$TE/gk3boot-android-$s+3.conf" "$TE/gk3boot-android-$s.conf"; done   # V2 祝福过
vendor V3 z; mkdir -p "$T/esp/EFI/gk3boot/V3"; printf 'stale' > "$T/esp/EFI/gk3boot/V3/fastboot.img"; run action gk3boot-android-b.conf
chk "条目 = +3 ×2 + gk3prev ×2（→ V2），没有 tools" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf gk3prev-android-a.conf gk3prev-android-b.conf " ] && grep -q "/EFI/gk3boot/V2/" "$TE/gk3prev-android-a.conf"'
chk "V3/ 只剩 gk3boot.efi；V1 回收；V2 带着它的 fastboot.img 留着" '[ "$(ls "$T/esp/EFI/gk3boot/V3")" = gk3boot.efi ] && [ ! -e "$T/esp/EFI/gk3boot/V1" ] && [ -f "$T/esp/EFI/gk3boot/V2/fastboot.img" ]'
chk "error 空" '[ -z "$(p error)" ]'

echo "═ S21 ESP 空间不够写 fastboot.img（剩 1000 KB < 600 KB + 1 MiB）⇒ 入口照常部署、不写执行端、不建 tools、error 说清楚"
fresh V4; vfb 600 h; export GK3T_ESP_FREE_KB=1000; run action ""
chk "+3 ×2、没有 tools、没有 fastboot.img（也没有 .new）" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf " ] && [ ! -e "$T/esp/EFI/gk3boot/V4/fastboot.img" ] && ! find "$T/esp" -name "*.new" | grep -q .'
chk "mode=action version=V4、error 提到 fastboot.img" '[ "$(p mode)" = action ] && [ "$(p version)" = V4 ] && echo "$(p error)" | grep -q "fastboot.img: ESP too full"'
mv "$TE/gk3boot-android-a+3.conf" "$TE/gk3boot-android-a.conf"; run action gk3boot-android-a.conf
S0=$(snap); run action gk3boot-android-a.conf
chk "空间一直不够时：再开机只读挂、零写入（空间在 dry 那遍就判了）" '[ "$(mounts)" = "ro=1 rw=0" ] && [ "$(snap)" = "$S0" ]'
unset GK3T_ESP_FREE_KB; run action gk3boot-android-a.conf
chk "空间回来了 ⇒ 补上 fastboot.img 与 tools" 'fbeq V4 && [ "$(cat "$TE/gk3boot-tools.conf")" = "$(TOOLS_V V4)" ]'

echo "═ S22 vendor 的 fastboot.img 不是 gzip ⇒ 入口照常部署、不写执行端、不建 tools"
fresh V5; printf 'PK not gzip, just some bytes' > "$T/vendor/boot/gk3boot/fastboot.img"; run action ""
chk "+3 ×2、没有 tools、没有 fastboot.img、error=not gzip" '[ "$(ls_e)" = "gk3boot-android-a+3.conf gk3boot-android-b+3.conf " ] && [ ! -e "$T/esp/EFI/gk3boot/V5/fastboot.img" ] && echo "$(p error)" | grep -q "not gzip"'

echo "═ S23 off ⇒ tools 与其他入口条目一起删、目录（含 fastboot.img）整个回收"
fresh V6; vfb 100 i; run action ""
chk "前提：tools 已部署" '[ -f "$TE/gk3boot-tools.conf" ]'
run off ""
chk "没有任何 gk3 条目、EFI/gk3boot/V6 没了" '[ -z "$(ls_e)" ] && [ ! -e "$T/esp/EFI/gk3boot/V6" ]'

# ── S15 双系统：动作 6（windows / loader_replaced / default / menu 导出）、动作 7（请求线程）、关机标记 ──
WIN=$T/esp/EFI/Microsoft/Boot
winesp() {   # ESP 上放 Windows 的启动管理器；回落路径与 systemd-boot 同一份字节（= 安装器装好的样子）
    mkdir -p "$WIN" "$T/esp/EFI/systemd"; printf 'MZwindows' > "$WIN/bootmgfw.efi"
    printf 'MZsdboot' > "$T/esp/EFI/BOOT/BOOTAA64.EFI"; cp "$T/esp/EFI/BOOT/BOOTAA64.EFI" "$T/esp/EFI/systemd/systemd-bootaa64.efi"
}
req() { OUT=$(GK3T_PROPS="$T/props" "$D" request "$1" 2>>"$T/log"); echo "$OUT" | sed 's/^/    /'; }
ack() { echo "$OUT" | sed -n 's/^ack=//p'; }
dumpm() { "$D" dump "$T/misc.img" | head -1; }

echo "═ S24 有 Windows、默认 Windows（入口写的缓存）⇒ windows=1 default=windows；没有 Windows ⇒ windows=0；纯 Android 开机仍零写入"
fresh V1; "$D" mkmisc "$T/misc.img" 0; "$D" recset "$T/misc.img" default_os=2; run action ""; mv "$TE/gk3boot-android-a+3.conf" "$TE/gk3boot-android-a.conf"
winesp; S0=$(snap); M0=$(md5q "$T/misc.img"); run action gk3boot-android-a.conf
chk "windows=1 default=windows default_pending 空 menu=0（分派关）" '[ "$(p windows)" = 1 ] && [ "$(p default)" = windows ] && [ -z "$(p default_pending)" ] && [ "$(p menu)" = 0 ]'
chk "notify 不含 loader_replaced（回落路径就是 systemd-boot）" '! echo "$(p notify)" | grep -q loader_replaced'
chk "只读挂、ESP 与 misc 都没变（动作 6 只读）" '[ "$(mounts)" = "ro=1 rw=0" ] && [ "$(snap)" = "$S0" ] && [ "$(md5q "$T/misc.img")" = "$M0" ]'
rm -rf "$T/esp/EFI/Microsoft"; run action gk3boot-android-a.conf
chk "删掉 Windows ⇒ windows=0" '[ "$(p windows)" = 0 ]'

echo "═ S25 有 Windows 且 BOOTAA64.EFI 被换成别的（Windows 修复 / 更新）⇒ notify 带 loader_replaced、只通知不修"
winesp; printf 'MZbootmgfw-copy' > "$T/esp/EFI/BOOT/BOOTAA64.EFI"; S0=$(snap); run action gk3boot-android-a.conf
chk "notify 含 loader_replaced" 'echo "$(p notify)" | grep -q loader_replaced'
chk "ESP 一字未改（不修）" '[ "$(snap)" = "$S0" ] && [ "$(mounts)" = "ro=1 rw=0" ]'
cp "$T/esp/EFI/systemd/systemd-bootaa64.efi" "$T/esp/EFI/BOOT/BOOTAA64.EFI"

echo "═ S26 menu：经入口开机 + ro.boot.gk3boot.dispatch=1 + 现役那一版的 fastboot.img 在 ESP 上 ⇒ menu=1；缺一样就 0"
fresh V7; vfb 50 m; run action ""; mv "$TE/gk3boot-android-a+3.conf" "$TE/gk3boot-android-a.conf"
XPROPS="ro.boot.gk3boot.dispatch=1" run action gk3boot-android-a.conf
chk "dispatch=1 + via=gk3boot + 执行端在 ⇒ menu=1" '[ "$(p menu)" = 1 ] && [ "$(p via)" = gk3boot ]'
run action gk3boot-android-a.conf
chk "分派关 ⇒ menu=0" '[ "$(p menu)" = 0 ]'
XPROPS="ro.boot.gk3boot.dispatch=1" run action ""
chk "直连开机（没经过入口）⇒ menu=0" '[ "$(p menu)" = 0 ]'
rm "$T/esp/EFI/gk3boot/V7/fastboot.img"; rm "$T/vendor/boot/gk3boot/fastboot.img"
XPROPS="ro.boot.gk3boot.dispatch=1" run action gk3boot-android-a.conf
chk "没有执行端 ⇒ menu=0" '[ "$(p menu)" = 0 ]'

echo "═ S27 请求 next_windows：有 Windows + 有记录 ⇒ 写 next=windows、ack ok；没有 Windows / 没有记录 ⇒ 报错、不写"
fresh V1; winesp; "$D" mkmisc "$T/misc.img" 0; : > "$T/props"; req next_windows
chk "ack = next_windows:ok:…、ring 清回 0" 'ack | grep -q "^next_windows:ok:" && [ "$(echo "$OUT" | sed -n "s/^ring=//p")" = 0 ]'
chk "misc：next=3（windows），streak / 事件不动" 'dumpm | grep -q "streak=0 next=3 set_default=0"'
rm -rf "$T/esp/EFI/Microsoft"; "$D" mkmisc "$T/misc.img" 0; M0=$(md5q "$T/misc.img"); req next_windows
chk "没有 Windows ⇒ error:no-windows、misc 不变" 'ack | grep -q "^next_windows:error:no-windows:" && [ "$(md5q "$T/misc.img")" = "$M0" ]'
winesp; "$D" nomisc "$T/misc.img"; M0=$(md5q "$T/misc.img"); req next_windows
chk "没有 GK3 记录（入口没在动作模式下跑过）⇒ error:no-record、不建记录" 'ack | grep -q "^next_windows:error:no-record:" && [ "$(md5q "$T/misc.img")" = "$M0" ]'
req bogus
chk "不认识的请求 ⇒ error:unknown-request" 'ack | grep -q "^bogus:error:unknown-request:"'
export GK3T_NOMOUNT=1; "$D" mkmisc "$T/misc.img" 0; req next_windows; unset GK3T_NOMOUNT
chk "ESP 挂不上 ⇒ error:esp" 'ack | grep -q "^next_windows:error:esp:"'

echo "═ S28 请求 default_windows / default_android ⇒ 写 set_default、default_pending 跟着变；入口没应用之前再改 = 覆盖"
fresh V1; winesp; "$D" mkmisc "$T/misc.img" 0; req default_windows
chk "ack ok、set_default=1、default_pending=windows" 'ack | grep -q "^default_windows:ok:" && dumpm | grep -q "set_default=1" && [ "$(echo "$OUT" | sed -n "s/^default_pending=//p")" = windows ]'
rm -rf "$T/esp/EFI/Microsoft"; req default_android
chk "改回 Android 不要求 Windows 在：ack ok、set_default=2" 'ack | grep -q "^default_android:ok:" && dumpm | grep -q "set_default=2"'
run action ""
chk "开机完成时导出 default_pending=android（入口还没应用）" '[ "$(p default_pending)" = android ]'

echo "═ S29 关机标记（rc 的 on shutdown → --gk3-mark-poweroff）"
po() {   # po <sys.powerctl> <ro.boot.gk3boot.mode>
    printf 'sys.powerctl=%s\nro.boot.gk3boot.mode=%s\n' "$1" "$2" > "$T/props"
    OUT=$(GK3T_PROPS="$T/props" "$D" poweroff 2>>"$T/log")
}
fresh V1; "$D" mkmisc "$T/misc.img" 0; "$D" recset "$T/misc.img" default_os=2
po reboot action
chk "重启 ⇒ 不写、返回 0" '[ "$OUT" = rc=0 ] && dumpm | grep -q "clean_poweroff=0"'
po shutdown,userrequested observe
chk "这次不是经动作模式的入口开的机（没有预置 OneShot）⇒ 不写" 'dumpm | grep -q "clean_poweroff=0"'
po shutdown,userrequested ""
chk "直连开机 ⇒ 不写" 'dumpm | grep -q "clean_poweroff=0"'
po shutdown,userrequested action
chk "关机 + 动作模式 + 默认 Windows ⇒ clean_poweroff=1、rc=0" '[ "$OUT" = rc=0 ] && dumpm | grep -q "clean_poweroff=1"'
"$D" mkmisc "$T/misc.img" 0; "$D" recset "$T/misc.img" default_os=1; po shutdown action
chk "默认 Android ⇒ 不写" 'dumpm | grep -q "clean_poweroff=0"'
"$D" recset "$T/misc.img" default_os=1 set_default=1; po shutdown action
chk "缓存 Android 但已请求 Windows（入口下次先应用）⇒ 写" 'dumpm | grep -q "clean_poweroff=1"'
"$D" nomisc "$T/misc.img"; M0=$(md5q "$T/misc.img"); po shutdown action
chk "没有记录 ⇒ 不建、rc=0" '[ "$OUT" = rc=0 ] && [ "$(md5q "$T/misc.img")" = "$M0" ]'

echo "═ S30 入口记的 intent_dropped / default_reset 进 notify；to_windows / default_set 不打扰"
fresh V1; "$D" mkmisc "$T/misc.img" 0 to_windows default_set intent_dropped default_reset; run observe ""
chk "notify = intent_dropped,default_reset" '[ "$(p notify)" = "intent_dropped,default_reset" ]'
"$D" dump "$T/misc.img" > "$T/dump"
chk "四条全部置已通知" '! grep -q "notified=0" "$T/dump"'

echo "═ ASan/UBSan 报告"
chk "日志里没有 sanitizer 报错" '! grep -q "ERROR: AddressSanitizer\|runtime error" "$T/log"'
echo "══ 通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]

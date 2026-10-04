#!/usr/bin/env bash
# 用本机上的 payload.bin 给 gaokun3 装 OTA（update_engine 的 file:// 通路）。
#
#   bash scripts/install-ota-local.sh --check     # 只检查前提，不动机器
#   bash scripts/install-ota-local.sh --go        # 真装
#
# ⚠️★★ **装机前必须确认现场有人能按电源键** —— 新槽从没启动过这版系统，
#   万一硬挂死（不 panic）没有远程办法救。本仓为此付过两次账（#79 / #83）。
#
# ★ 为什么要有这个脚本：装机路上有三颗地雷，每一颗都"看着毫无关系"：
#  1. `update_engine` **拒绝在 overlayfs 生效时工作**（`kOverlayfsenabledError(64)`）。
#     要先 `adb enable-verity` **并重启**。⚠️ 它会报
#     "boot_b does not look like a vbmeta footer"，无害。
#     ⚠️ 这一步会连带抹掉用 `adb remount` 推上去的东西（比如临时的 audio-route.sh）
#     —— 那正是本次装 ROM 要接手的内容，所以是预期行为。
#  2. ★★ `update_engine` 把新槽标成 active 之后，**boot_control HAL 会立刻把
#     ESP 的 `default` 改成新槽的条目**（M20 实测）。新槽起不来就连回落都没有了。
#     **重启前必须把 `default` 掰回已知可用的那个槽，只用 oneshot 过去。**
#  3. 这个版本的 `update_engine_client` **没有 `--status`**（M17 实测），
#     而且 `--update` 是**异步**的：它提交完就返回（实测 82 ms），
#     真正的进度只在 logcat 里。⚠️ 别拿 `bootctl get-active-boot-slot`
#     当完成判据 —— **active slot 在【开始】时就切过去了**，见第 3 段注释。
#     实测一次完整装机 93 秒（1.345 GB，含 postinstall）。
set -uo pipefail
SER=${SER:-gaokun3}
MODE=${1:---check}
# ⚠️★ 挂载点故意用一个【别人不会碰】的名字（2026-09-14 踩的）：此前用 /mnt/esp，装机中途我另开一个
#   adb shell 看进度、顺手 mount/umount 了同一个 /mnt/esp ⇒ 脚本第 4 步看到的是空目录、
#   "ESP 上没有 -android-a.conf" 而停手；而 boot_control 已把 default 改成新槽，安全网没做上。
#   ★ 与"ESP 上的 default 是谁改的"同一类问题：共享的可变状态要么私有、要么加锁，这里选私有。
A() { adb -s "$SER" "$@"; }
S() { adb -s "$SER" shell "$@"; }
die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }

echo "═══ 1. 前提检查 ═══"
S true >/dev/null 2>&1 || die "adb 连不上 $SER"
CUR=$(S getprop ro.boot.slot_suffix | tr -d '\r')
ok "当前槽 $CUR · 内核 $(S 'cat /proc/version' | grep -o '#[0-9]*' | tr -d '\r') · 构建 $(S getprop ro.build.date.utc | tr -d '\r')"

[ "$(S id -u | tr -d '\r')" = "0" ] || die "需要 root：开发构建 adb shell setprop service.adb.root 1 && adb root；发布构建（ro.debuggable=0）上 KSU 的 adb root 是否还能用待上机核实（libadbroot 是否依赖 ro.debuggable），这些开发脚本只保证在开发构建上可用"

# ★ 2026-09-29（SELinux 第七轮审计）：update_engine 自己打开 --payload 给的文件，而它读不了
#   /data/local/tmp（shell_data_file，policy-query DENY）—— enforcing 下这个脚本会失败。
#   它能读的是 /data/ota_package（ota_package_file）。照旧 push 到 /data/local/tmp，这里挪过去：
#   同一个文件系统，mv 是瞬时的；mv 保留旧标签，所以要 restorecon。
OTA=/data/ota_package
# --check 不动机器：只报告文件在哪；真挪在 --go 里（下面 ota_move）。
for f in payload.bin payload_properties.txt; do
    if S "[ -f $OTA/$f ]"; then :
    elif S "[ -f /data/local/tmp/$f ]"; then echo "  $f 在 /data/local/tmp，--go 时挪进 $OTA"
    else die "设备上缺 ${f}（/data/local/tmp 与 $OTA 都没有）—— 先从 OTA zip 里解出来 push 过去"
    fi
done
ok "payload 与 properties 都在设备上"
ota_move() {
    for f in payload.bin payload_properties.txt; do
        if S "[ -f /data/local/tmp/$f ]"; then
            S "mv -f /data/local/tmp/$f $OTA/$f && chown system:cache $OTA/$f && chmod 0660 $OTA/$f && restorecon $OTA/$f" \
                || die "把 /data/local/tmp/$f 挪进 $OTA 失败"
        fi
        S "ls -Z $OTA/$f" | grep -q ota_package_file || die "$OTA/$f 的标签不是 ota_package_file"
    done
    ok "payload 与 properties 已在 ${OTA}（ota_package_file）"
}

# ⚠️ overlayfs 必须是关的
if S 'mount' | grep -q "overlay on /vendor"; then
    echo "⚠️ overlayfs 还生效着 —— update_engine 会直接拒绝（错误码 64）"
    echo "   要跑：adb enable-verity && adb reboot，然后重新执行本脚本"
    [ "$MODE" = "--go" ] && die "先处理 overlayfs"
else
    ok "overlayfs 未生效"
fi

DEF=$(S 'mkdir -p /mnt/gaokun3_ota_install; mount -t vfat /dev/block/by-name/esp /mnt/gaokun3_ota_install 2>/dev/null; grep ^default /mnt/gaokun3_ota_install/loader/loader.conf' | tr -d '\r')
ok "ESP 的 $DEF"

# ★ ESP 空间（TODO B13，#110）：postinstall 要求"可用 + 目标槽将被覆盖的旧文件 > 56 MB"，
#   不够就在最后一步失败，而那看起来像"新版本有问题"。2026-09-14 本机被三周的实验槽位
#   （slot_cam / slot_cam4）吃到只剩 4.5 MB 可用（合计 47 MB），差 9 MB 就翻车。
#   这里提前算同一笔账，并把 slot_a/slot_b 之外的目录点名 —— 那些就是该删的实验残留。
case "$CUR" in _a) TGT=b ;; _b) TGT=a ;; *) die "看不懂当前槽 '$CUR'" ;; esac
# ⚠️ 远端命令整体放在【单引号】里，TGT 用拼接注入：双引号会让本地 bash 先展开 $4 / $(…)（第一版就是这么炸的）。
ESP_KB=$(S 'TGT='"$TGT"'; MID=$(ls /mnt/gaokun3_ota_install | grep -E "^[0-9a-f]{32}$" | head -1); a=$(df -k /mnt/gaokun3_ota_install | tail -1 | awk "{print \$4}"); for f in Image ramdisk.img gaokun3.dtb recovery-ramdisk.img; do p=/mnt/gaokun3_ota_install/$MID/android/slot_$TGT/$f; [ -f $p ] && a=$((a + $(stat -c %s $p) / 1024)); done; echo $a' | tr -d '\r' | tail -1)
EXTRA=$(S 'MID=$(ls /mnt/gaokun3_ota_install | grep -E "^[0-9a-f]{32}$" | head -1); ls -d /mnt/gaokun3_ota_install/$MID/android/*/ 2>/dev/null | grep -v "/slot_[ab]/$" | xargs -r du -sk 2>/dev/null' | tr -d '\r')
if [ "${ESP_KB:-0}" -gt 57344 ]; then
    ok "ESP 给目标槽 slot_$TGT 的空间约 $((ESP_KB/1024)) MB（含将被覆盖的旧文件；postinstall 要 56 MB）"
else
    echo "✗ ESP 只够 $((ESP_KB/1024)) MB，postinstall 要 56 MB —— 会在最后一步失败"
    [ -n "$EXTRA" ] && { echo "  slot_a/slot_b 之外的目录（实验残留，KB）："; echo "$EXTRA" | sed 's/^/    /'; }
    S 'umount /mnt/gaokun3_ota_install 2>/dev/null'
    die "先清 ESP（连同 loader/entries/ 里指向它们的条目）再来"
fi
[ -n "$EXTRA" ] && { echo "⚠️ ESP 上有 slot_a/slot_b 之外的目录（KB），验收完记得删："; echo "$EXTRA" | sed 's/^/    /'; }

if [ "$MODE" != "--go" ]; then
    echo; echo "（--check 模式，没有改动任何东西。确认现场有人能按电源键后用 --go）"
    S 'umount /mnt/gaokun3_ota_install 2>/dev/null'
    exit 0
fi

echo "═══ 2. 下发更新 ═══"
ota_move
HDRS=$(S "cat $OTA/payload_properties.txt" | tr -d '\r' | tr '\n' '|' | sed 's/|$//')
S "update_engine_client --payload=file://$OTA/payload.bin --update --headers=\"\$(cat $OTA/payload_properties.txt)\"" 2>&1 | tail -5

echo "═══ 3. 等装完 ═══"
# ⚠️★ 判据踩过一次坑（2026-09-12）：原先用 "active slot 是否切换"，而
#   **update_engine 在【开始】时就把 active slot 切过去了**，不是结束时。
#   于是第一次检查就命中，第 4 步在装到 40% 时提前跑掉 —— 而且它长得
#   和真正的成功一模一样。★ 本仓 #49/#73 反复记过：**判据要问"两种结果下
#   它会不会不同"**，一个在开始就已经成立的观测量是零证据。
#   现在只认 update_engine 自己写的终态行，**并且成功/失败两种都匹配**
#   （只 grep 成功标记的话，装失败会表现为"一直等"，与"还在装"无法区分）。
#   ⚠️★ 第二次踩：我改判据时写成 grep "ErrorCode::k[A-Za-z]+"，结果命中了
#   **中间步骤**那几行（"finished UpdateBootFlagsAction with code
#   ErrorCode::kSuccess"），开装 3 秒就报"终态"。★ update_engine 每个
#   action 结束都打一行 ErrorCode —— **只有带 "finished last action" 的
#   那行才是终态**。真正的成功标记是 update_attempter_android.cc:770 的
#   "Update successfully applied, waiting to reboot."
DONE=""
for i in $(seq 1 180); do
    # ⚠️★ 第三次踩（2026-09-14）：logcat 里【上一轮】残留的 "finished last action
    #   CleanupPreviousUpdateAction ... kSuccess" 让脚本在装到 30% 时就报"最后一个 action 成功"，
    #   接着第 4 步把 default 掰回去 —— 而真正装完后 boot_control 又把 default 改成新槽，安全网等于没做。
    #   ★ 只认 update_attempter_android.cc:770 的 "Update successfully applied"（成功）与
    #   "Update failed" / 非 kSuccess 的 ErrorCode（失败）；"finished last action" 一律不算。
    L=$(A logcat -d 2>/dev/null | grep "update_engine" \
        | grep -E "Update successfully applied|Update failed|ErrorCode::k[A-Za-z]+\)? *$" \
        | grep -v "kSuccess" | tail -1 | tr -d '\r')
    if [ -n "$L" ]; then DONE="$L"; break; fi
    sleep 5
done
if   [ -z "$DONE" ];                       then die "等了 15 分钟没等到终态行 —— 自己看 adb logcat | grep update_engine"
elif echo "$DONE" | grep -q "Update successfully applied"; then ok "装完：${DONE#*] }"
else die "装失败：${DONE#*] }"
fi

echo "═══ 4. ⚠️ 把 default 掰回已知可用的槽，只用 oneshot 过去 ═══"
echo "   （boot_control HAL 刚把它改成新槽了 —— 这一步是安全网）"
# ⚠️★ 这里也踩过一次（同一天）：原先写 "default *-android${CUR}.conf"，
#   而 CUR 是 "_b"（带下划线），真实条目名却是 "<machine-id>-android-b.conf"
#   （连字符）。于是 default 被写成一个【匹配不到任何条目】的 glob ——
#   安全网静默失效，而输出看起来完全正常。
#   ★ 规矩：写 glob 之前先确认它在真实目录上匹配得到东西，匹配不到就 die。
SLOT=${CUR#_}                       # _b -> b
GLOB="*-android-${SLOT}.conf"
S "ls /mnt/gaokun3_ota_install/loader/entries/ | grep -q -- '-android-${SLOT}\.conf'" \
    || die "ESP 上没有 -android-${SLOT}.conf 这个条目，glob '$GLOB' 会写成死链 —— 停手"
ok "glob '$GLOB' 在 ESP 上匹配得到条目"
S "sed -i 's|^default .*|default ${GLOB}|' /mnt/gaokun3_ota_install/loader/loader.conf; sync; grep ^default /mnt/gaokun3_ota_install/loader/loader.conf" 2>&1 | tr -d '\r'
echo
echo "⬜ 剩下的手工两步（故意不自动做）："
echo "   1) 写 LoaderEntryOneShot 指向新槽的条目"
echo "   2) adb reboot，然后验收：uname / getprop ro.build.date.utc / tinymix 看 PA"
S 'sync; umount /mnt/gaokun3_ota_install 2>/dev/null'

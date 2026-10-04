#!/usr/bin/env bash
#
# 取出本机的 Google Services Framework Android ID —— 注册"未认证设备"要用它。
#
# ★ 为什么需要：自编 ROM 的 GMS 不在 Google 的认证设备库里，Play 商店会显示
#   "设备未经 Play 保护机制认证"，部分应用（含 Play 商店本身的一些功能）会受限。
#   解法是把这台机器的 Android ID 登记到 https://www.google.com/android/uncertified/
#   —— 一次性、免费、用自己的 Google 账号做。见 docs/INSTALL.md 的"Google 认证"一节。
#
# ⚠️★ 这个 ID 是**设备标识**，与账号绑定。**不要把它写进本仓或任何公开地方**
#   （本仓是公开仓库，同 WiFi 密码/SSID/构建机 IP 的纪律）。本脚本只打印，不落盘。
#
# ⚠️ 它要 root：ID 存在 GMS 的私有目录里。依次试三条路，哪条先拿到 uid 0 用哪条：
#   1. `adb root`（开发构建）；2. 先 `setprop service.adb.root 1` 再 `adb root`（本机的老办法）；
#   3. KSU 的 `su -c`（发布构建 ro.debuggable=0（B1）上 adb root 可能不可用，
#      要先装 ReSukiSU 管理器、给 Shell（com.android.shell）授 root）。
#   ⬜ 第 3 条（发布构建上 su -c 读 GMS 私有目录）**未实测**，待上机核实。
#   读法：用 `adb exec-out` 把 Checkin.xml 整份拿回本机、在本机解析（不在设备上套 sed，避免嵌套引号）；
#   内容只留在变量里，不落盘。
#   ⚠️ 新版 GMS（本机 16_202505）**不再往 com.google.android.gsf 的 gservices.db 写**，
#      所以网上那条 `sqlite3 .../gsf/databases/gservices.db` 的老办法在这里查不到东西
#      （实测 `content query --uri content://com.google.android.gsf.gservices` 也是 No result found）。
#      真实位置是 com.google.android.gms 的 shared_prefs/Checkin.xml。
#
# 用法：bash scripts/google/gsf-android-id.sh [adb-serial]

set -uo pipefail
SER=${1:-${SER:-gaokun3}}
A() { adb -s "$SER" "$@"; }
S() { adb -s "$SER" shell "$@"; }

die() { echo "✗ $*" >&2; exit 1; }

S true >/dev/null 2>&1 || die "adb 连不上 $SER"
A root >/dev/null 2>&1 || true
[ "$(S id -u | tr -d '\r')" = "0" ] || {
    S setprop service.adb.root 1 >/dev/null 2>&1
    A root >/dev/null 2>&1 || true
}

CHECKIN=/data/data/com.google.android.gms/shared_prefs/Checkin.xml
# R "<命令>"：以 root 在设备上跑一条命令，stdout 原样带回（exec-out 不经 pty，不加 \r）。
#   ⚠️ <命令> 里不能有单引号 —— su 路径要把它包进 su -c '…'。
if [ "$(S id -u | tr -d '\r')" = "0" ]; then
    R() { A exec-out "$1"; }
elif [ "$(S "su -c 'id -u'" 2>/dev/null | tr -d '\r')" = "0" ]; then
    # ⬜ 发布构建上这条路未实测（KSU 给 com.android.shell 授 root 之后应当可用）
    R() { A exec-out "su -c '$1'"; }
else
    die "需要 root。开发构建：adb root（本机要先 adb shell setprop service.adb.root 1 && adb root）；发布构建（ro.debuggable=0，B1）：装 ReSukiSU 管理器，给 Shell（com.android.shell）授 root 后重跑"
fi

# 整份 XML 拿回本机、本机解析。只留在变量里，不落盘。
XML=$(R "cat $CHECKIN 2>/dev/null" | tr -d '\r')
ID=$(printf '%s\n' "$XML" | sed -n 's/.*name="android_id" *>\([0-9]*\)<.*/\1/p' | head -1)

if [ -z "$ID" ]; then
    echo "✗ 没读到 android_id。可能的原因："
    echo "   * 还没登录 Google 账号，或 GMS 还没完成一次 checkin（联网后等几分钟）"
    echo "   * 刚恢复出厂设置 —— checkin 之后 ID 会变，要重新登记"
    R "ls $CHECKIN 2>&1" | tr -d '\r' | sed 's/^/   /'
    exit 1
fi

LAST=$(printf '%s\n' "$XML" | sed -n 's/.*CheckinService_lastCheckinSuccessTime" value="\([0-9]*\)".*/\1/p' | head -1)
echo "Android ID : $ID"
[ -n "$LAST" ] && echo "上次 checkin : $(date -r $((LAST/1000)) 2>/dev/null || echo "$LAST ms")"
cat <<TXT

去这里登记（用这台机器上登录的那个 Google 账号）：
    https://www.google.com/android/uncertified/

登记后一般几分钟到几小时生效；之后清一次 Play 商店数据再开：
    adb -s $SER shell pm clear com.android.vending

⚠️ 恢复出厂设置 / 清 GMS 数据之后 ID 会变，要重新登记。
⚠️ 这只解决"设备未经 Play 保护机制认证"。**Play Integrity（银行类应用的强校验）
   仍然过不了** —— 那要求 bootloader 上锁 + Google 签名的系统，本机做不到。
TXT

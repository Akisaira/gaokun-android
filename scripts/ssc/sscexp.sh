#!/system/bin/sh
# SSC 实验循环：停 SLPI -> 起 SLPI -> 用自定义根目录起 hexagonrpcd -> 测传感器
# 用法: sscexp.sh <sensor名> [等待秒数]
# 前提: /data/local/tmp/hr 已按本次实验准备好
#
# ⚠️ 2026-09-23 三处修正（每一处都让这个循环在当天产出过假阴性）：
#   1. 写一次 stop 不一定停得下来。sysfs 的 stop 只是给 rproc->power 减一
#      （remoteproc_core.c:1997），而 init.gaokun3.rc 在【每次】sys.boot_completed=1
#      时都对三颗 DSP 写 start —— 已在运行时那只是加一。开机后引用数就是 2，
#      每做一次 framework 软重启再 +1。所以这里循环写 stop 直到真的 offline。
#   2. 先停 sensors HAL。它在 SLPI 重启期间不断重试，#37 记过那种 churn 会把
#      传感器枚举整个弄坏。收工脚本（README）负责把它拉回来。
#   3. SLPI 起来后 hexagonrpcd 要【再重启一次】，SEE 才会注册传感器：
#      只起一次时连 accel 都是"没有提供者"（阳性对照失败），重启一次后立刻恢复。
R=/sys/class/remoteproc/remoteproc0
ROOT=/data/local/tmp/hr
SENSOR="$1"
WAIT="${2:-45}"

[ -d "$ROOT" ] || { echo "FAIL: $ROOT 不存在"; exit 1; }

start_rpcd() {
    setsid nohup /vendor/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R "$ROOT" >/dev/null 2>&1 </dev/null &
}

stop vendor.sensors-gaokun3 2>/dev/null
stop vendor.hexagonrpcd-sdsp 2>/dev/null
sleep 1
pkill hexagonrpcd 2>/dev/null
sleep 1

n=0
while [ "$(cat $R/state)" != offline ] && [ $n -lt 6 ]; do
    echo stop > $R/state 2>/dev/null
    n=$((n+1)); sleep 3
done
ST=$(cat $R/state)
[ "$ST" = "offline" ] || { echo "FAIL: 写了 $n 次 stop，SLPI 仍没停下 (state=$ST)"; exit 1; }
echo "（写了 $n 次 stop 才停下 —— 多出来的是 init 泄漏的引用）"

echo start > $R/state || { echo "FAIL: 写 start 失败"; exit 1; }
sleep 6
ST=$(cat $R/state)
[ "$ST" = "running" ] || { echo "FAIL: SLPI 没起来 (state=$ST)"; exit 1; }
[ -e /dev/fastrpc-sdsp ] || { echo "FAIL: 无 /dev/fastrpc-sdsp"; exit 1; }

start_rpcd
sleep 10
pkill hexagonrpcd 2>/dev/null
sleep 2
start_rpcd
sleep "$WAIT"
pgrep hexagonrpcd >/dev/null || { echo "FAIL: hexagonrpcd 没活着"; exit 1; }

echo "--- 测 $SENSOR ---"
timeout 90 gaokun3-ssc-test "$SENSOR" 2>&1 | tail -4

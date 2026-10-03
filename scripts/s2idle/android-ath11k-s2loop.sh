#!/system/bin/sh
# issue #16 / patches/0070 验证：ath11k 断电挂起/恢复循环，看固件每次都能重新下载、Wi-Fi 每次都能恢复。
# ⚠️ 必须是 pm_test=platform：devices 档不跑 suspend_late/resume_early，ath11k 既不断电也不重载、停了影子定时器 ⇒ Wi-Fi 必坏（2026-10-04 踩过）
# 用法（root）：setsid nohup sh android-ath11k-s2loop.sh <pm_test 次数> <真实 s2idle 次数> <同网段可 ping 的主机> &
# 案卷 docs/stage4-findings.md #131。
# ⚠️ role=device 时挂起会整板复位（gaokun3-usbrole.sh 顶部）⇒ 先切 host，结束切回 device（USB adb 期间断开）。
N=${1:-10}; NR=${2:-3}; PEER=${3:?第三个参数：同网段一台能 ping 的主机（别猜网关：Android 的默认路由在策略路由表里）}
D=/data/local/tmp/mhi-test; mkdir -p $D; L=$D/log; : > $L
S=/sys/class/usb_role/a600000.usb-role-switch/role
say() { echo "[$(date +%H:%M:%S) up=$(cut -d' ' -f1 /proc/uptime)] $*" >> $L; sync; }
mark() { echo "MHITEST $*" > /dev/kmsg; }
since() { dmesg | sed -n "/MHITEST $1 begin/,\$p"; }   # ★ 只看本轮标记之后：dmesg 环形缓冲会写满，按全量计数会失真
wifi_ok() {  # $1=label。最多等 60 秒：本轮之后重新关联 + ping 通 PEER
  i=0; while [ $i -lt 30 ]; do
    since $1 | grep -q "wlan0: associated" && ping -c1 -W1 $PEER >/dev/null 2>&1 && { echo "$((i*2))s"; return 0; }
    sleep 2; i=$((i+1)); done; echo FAIL; return 1; }
cycle() {  # $1 = platform | none
  case "$(cat $S)" in *"[host]"*|host) ;; *) say "ABORT: 挂起前 role=[$(cat $S)] 不是 host —— device 角色挂起会整板复位"; finish; exit 1 ;; esac
  echo $1 > /sys/power/pm_test
  RC=1; TRY=0
  while [ $RC -ne 0 ] && [ $TRY -lt 6 ]; do
    TRY=$((TRY+1))
    [ "$1" = none ] && { echo 0 > /sys/class/rtc/rtc0/wakealarm; echo +20 > /sys/class/rtc/rtc0/wakealarm; }
    T0=$(cut -d. -f1 /proc/uptime); echo mem > /sys/power/state; RC=$?; T1=$(cut -d. -f1 /proc/uptime)
    [ $RC -ne 0 ] && { say "   rc=$RC（尝试 $TRY，多半 -EBUSY）"; sleep 5; }
  done
  echo none > /sys/power/pm_test
  return $RC
}
say "START N=$N NR=$NR kernel=$(uname -v) peer=$PEER"
say "buddyinfo DMA: $(grep DMA /proc/buddyinfo | grep -v DMA32)"
say "wake_lock: $(cat /sys/power/wake_lock)"
# ★ 开发机 allow_suspend=0 ⇒ gaokun3_usbfollow 在跑：host 下约 6 秒没下游设备就切回 device（gaokun3-usbrole.sh follow），
#   而 device 角色下挂起 = 整板静默复位。2026-10-04 前两轮的"第 2 次循环复位"就是它。测试期间停掉它。
setprop ctl.stop gaokun3_usbfollow; sleep 1
say "usbfollow=[$(getprop init.svc.gaokun3_usbfollow)]"
echo host > $S; sleep 3
say "role=[$(cat $S)] udc=[$(ls /sys/class/udc 2>/dev/null)]"
case "$(cat $S)" in *host*) ;; *) say "ABORT: 切不到 host"; setprop ctl.start gaokun3_usbfollow; exit 1 ;; esac
pass=0; fail=0
finish() {
  echo device > $S; sleep 3; setprop ctl.start gaokun3_usbfollow
  say "role=[$(cat $S)] udc=[$(ls /sys/class/udc 2>/dev/null)] state=[$(cat /sys/class/udc/a600000.usb/state 2>/dev/null)] usbfollow=[$(getprop init.svc.gaokun3_usbfollow)]"
}
run() {  # $1=mode $2=label
  mark "$2 begin"
  cycle $1; rc=$?
  w=$(wifi_ok $2)
  fw=$(since $2 | grep -c "ath11k_pci.*fw_version")
  bad=$(since $2 | grep -c -E "page allocation failure|failed to power up mhi|failed to early resume|DPM device timeout|did not load")
  mark "$2 end"
  if [ $rc -eq 0 ] && [ "$w" != FAIL ] && [ $bad -eq 0 ] && [ $fw -ge 1 ]; then pass=$((pass+1)); r=PASS; else fail=$((fail+1)); r=FAIL; fi
  say "$r $2 rc=$rc wifi=$w fw_reload=$fw errlines=$bad"
  dmesg > $D/dmesg-$2.txt; logcat -d -b main,system -t 400 > $D/logcat-$2.txt 2>/dev/null
  say "   wlan0=[$(ip -4 addr show wlan0 | awk '/inet/{print $2}')] supplicant=[$(pidof wpa_supplicant)] link=[$(cat /sys/class/net/wlan0/operstate 2>/dev/null)]"; sync
}
i=1; while [ $i -le $N ]; do run platform "pmtest-$i"; i=$((i+1)); done
i=1; while [ $i -le $NR ]; do run none "real-$i"; i=$((i+1)); done
say "buddyinfo DMA: $(grep DMA /proc/buddyinfo | grep -v DMA32)"
say "suspend_stats: success=$(cat /sys/kernel/debug/suspend_stats 2>/dev/null | grep -m1 success)"
finish
dmesg | grep -E "MHITEST|ath11k|mhi |PM: suspend|page allocation" > $D/dmesg-filtered.txt
say "DONE pass=$pass fail=$fail"

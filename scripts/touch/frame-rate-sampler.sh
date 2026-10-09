#!/system/bin/sh
# 触摸帧率的时间分辨采样：每 0.1 s 记一次驱动的帧计数器，同时录原始 evdev，离线对齐。
# 为什么要有它：algo/stats 的 frames 只有总数 —— 2026-10-10 一段 36.6 s 的游戏里只处理了 3846 帧（120 Hz 应为 4392），
# 但 evdev 只在手指按着时有事件，看不出帧是在落指、按住还是空闲时丢的。
#
#   frame-rate-sampler.sh [需要的触摸帧数，默认 4000（约 33 s 按着）] [最长秒数，默认 300]
# 产物：/data/local/tmp/frs.log（realtime 秒 frames frames_reported contacts tracks_new irq 计数）、/data/local/tmp/frs.bin（evdev）、
#       结束标记 /data/local/tmp/frs.done。evdev 时间戳也是 CLOCK_REALTIME，两边可以直接对齐。
NEED=${1:-4000}; LIMIT=${2:-300}
A=/sys/bus/spi/devices/spi0.0/algo
T=/data/local/tmp
EV=$(grep -A8 'Name="Himax' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
[ -n "$EV" ] || { echo '找不到 Himax 触摸节点' >&2; exit 1; }
IRQ=$(grep -i himax /proc/interrupts | cut -d: -f1 | tr -d ' ')
echo $$ > $T/frs.pid
rm -f $T/frs.done
: > $T/frs.log
cat /dev/input/$EV > $T/frs.bin &
CAT=$!
trap 'kill $CAT 2>/dev/null; exit 1' INT TERM
get() { grep "^$1 " $A/stats | tr -s ' ' | cut -d' ' -f2; }
r0=$(get frames_reported)
end=$(( $(date +%s) + LIMIT ))
while [ "$(date +%s)" -lt $end ]; do
    r=$(get frames_reported)
    echo "$(date +%s.%N) $(get frames) $r $(get contacts) $(get tracks_new) $(grep "^ *$IRQ:" /proc/interrupts | tr -s ' ' | cut -d' ' -f3)" >> $T/frs.log
    [ $((r - r0)) -ge $NEED ] && break
    sleep 0.1
done
kill $CAT 2>/dev/null
echo DONE > $T/frs.done

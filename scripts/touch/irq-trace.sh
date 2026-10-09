#!/system/bin/sh
# 触摸停扫的 ftrace 取证（独立 instance，不碰全局 tracing / perfetto）：
#   硬中断 irq_handler_entry（只要触摸那根）+ 中断线程的 sched_wakeup / sched_switch。
# 一个 80 ms 的空档里：硬中断也没来 ⇒ IC 没出帧（或线程没跑完、电平中断一直屏蔽着 —— 看线程状态区分）；
# 硬中断来了、线程迟迟不上 CPU ⇒ 调度；线程上了 CPU 却很久才睡回去 ⇒ 处理本身（spi_sync 等 SPI 完成）。
#
#   irq-trace.sh [需要的触摸帧数，默认 4000] [最长秒数，默认 300]
# 产物：/data/local/tmp/irqtrace.txt，结束标记 /data/local/tmp/irqtrace.done
NEED=${1:-4000}; LIMIT=${2:-300}
T=/data/local/tmp
A=/sys/bus/spi/devices/spi0.0/algo
I=/sys/kernel/tracing/instances/gk3touch
IRQ=$(grep -i himax /proc/interrupts | cut -d: -f1 | tr -d ' ')
TID=$(for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = "irq/$IRQ-himax-spi-ts" ] && basename $p; done | head -1)
[ -n "$IRQ" ] && [ -n "$TID" ] || { echo "找不到触摸中断 / 中断线程（irq=$IRQ tid=$TID）" >&2; exit 1; }
rm -f $T/irqtrace.done
mkdir -p $I
echo 0 > $I/tracing_on
echo mono > $I/trace_clock
echo 8192 > $I/buffer_size_kb
echo > $I/trace
echo "irq==$IRQ" > $I/events/irq/irq_handler_entry/filter
echo "pid==$TID" > $I/events/sched/sched_wakeup/filter
echo "prev_pid==$TID || next_pid==$TID" > $I/events/sched/sched_switch/filter
echo 1 > $I/events/irq/irq_handler_entry/enable
echo 1 > $I/events/sched/sched_wakeup/enable
echo 1 > $I/events/sched/sched_switch/enable
cleanup() {
    echo 0 > $I/tracing_on
    cat $I/trace > $T/irqtrace.txt
    echo 0 > $I/events/enable
    rmdir $I 2>/dev/null
    echo DONE > $T/irqtrace.done
}
trap 'cleanup; exit 1' INT TERM
get() { grep "^$1 " $A/stats | tr -s ' ' | cut -d' ' -f2; }
r0=$(get frames_reported)
echo "irq=$IRQ tid=$TID start $(cat /proc/uptime)" > $T/irqtrace.meta
echo 1 > $I/tracing_on
end=$(( $(date +%s) + LIMIT ))
while [ "$(date +%s)" -lt $end ]; do
    [ $(( $(get frames_reported) - r0 )) -ge $NEED ] && break
    sleep 1
done
cleanup

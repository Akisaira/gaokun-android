#!/system/bin/sh
# 事件驱动的多预设采集（capture-ab.sh 的通用版）：每段按【收到多少触摸数据】切换，用户什么时候开始都行。
# 结束（或被 kill）时把动过的旋钮恢复成开始时的值。
#
#   capture-presets.sh <每段字节数> 'A:track_lost_frames=3,track_jump_dist2=0' 'B:track_lost_frames=1,...' ...
#
# 产物：/data/local/tmp/ts_<标签>.bin（原始 evdev）、ts_<标签>.stats（段前段后的 algo/stats）、
#       进度 /data/local/tmp/tsp.progress，结束标记 /data/local/tmp/tsp.done。
NEED=${1:?每段字节数}; shift
A=/sys/bus/spi/devices/spi0.0/algo
EV=$(grep -A8 'Name="Himax' /proc/bus/input/devices | grep -o 'event[0-9]*' | head -1)
[ -n "$EV" ] || { echo '找不到 Himax 触摸节点' >&2; exit 1; }
DEV=/dev/input/$EV
T=/data/local/tmp
LIMIT=600            # 每段最多等 600 秒
echo $$ > $T/tsp.pid
rm -f $T/tsp.done $T/tsp.log

# 记下所有会动到的旋钮的原值
KNOBS=$(for p in "$@"; do echo "${p#*:}" | tr ',' '\n' | cut -d= -f1; done | sort -u)
ORIG=""
for k in $KNOBS; do ORIG="$ORIG $k=$(cat $A/$k)"; done
restore() { for kv in $ORIG; do echo "${kv#*=}" > $A/${kv%%=*}; done; echo "restored$ORIG" >> $T/tsp.log; }
trap 'restore; exit 1' INT TERM

for p in "$@"; do
    tag=${p%%:*}
    for kv in $(echo "${p#*:}" | tr ',' ' '); do echo "${kv#*=}" > $A/${kv%%=*}; done
    f=$T/ts_$tag.bin
    { echo "== $p"; cat $A/stats; } > $T/ts_$tag.stats
    : > "$f"
    cat "$DEV" > "$f" &
    CAT=$!
    i=0
    while [ $i -lt $LIMIT ]; do
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        [ "$sz" -ge "$NEED" ] && break
        echo "$tag $sz/$NEED" > $T/tsp.progress
        sleep 1; i=$((i+1))
    done
    kill $CAT 2>/dev/null
    { echo "== after"; cat $A/stats; } >> $T/ts_$tag.stats
    echo "$tag done $(stat -c %s "$f")" >> $T/tsp.log
done
restore
echo DONE > $T/tsp.done

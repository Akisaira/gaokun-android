#!/vendor/bin/sh
#
# 音频/蓝牙死锁取证看门狗（stage4-findings.md #38）。
#
# 为什么要有它：#38 是用户实机报告的"长期运行后音频与蓝牙可能死锁"，
# 而我们**一次都没复现过**。它的诊断建议全是推导出来的，不是观测。
# 现实是死锁发生时用户只会重启，证据就没了 —— 所以证据必须【自动】留下。
#
# 探针刻意做得很便宜：只读 /proc 里的线程状态。每 60 秒一次、每次几毫秒。
# ⚠️ 2026-09-27（#126）：取证部分删掉了 logcat 与 dumpsys —— 这个脚本跑在 vendor 域
#   （gaokun3_hangdump），而 Treble 的 neverallow 不许 vendor 域执行 /system/bin/logcat
#   （logcat_exec）、也不许它打开 /dev/binder（dumpsys 要）。permissive 下它们能跑，
#   enforcing 下只会留下空文件。binder 那一段改读 binderfs 的 state（见 sepolicy/gaokun3_scripts.te 末尾）。
#
# 判据不是"出现 D 状态"（短暂的 D 很正常），而是
# **同一个 tid 连续三次采样都在 D**（= 卡住至少两分钟）。
# 不可中断睡眠正是内核侧死锁/DSP 通路卡住的特征。
#
# 每次启动最多产出一份 dump：服务是 oneshot + disabled、只在 boot_completed 时起一次，取完证就 exit。
# 盘上只留最近 5 份（KEEP），不会把 /data 撑爆。
# ⓘ 2026-09-29 删掉了 `.done` 标记：它在 /data 上跨重启保留、从没人删 ⇒ 第一次取证之后看门狗
#   就永久不跑了（与"每次启动一份"相反）；而"每次启动一份"本来就由上面那两点保证，标记是多余的。

PATH=/system/bin:/vendor/bin
export PATH

DIR=/data/vendor/gaokun3
KEEP=5
INTERVAL=60
STRIKES_NEEDED=3

mkdir -p $DIR 2>/dev/null
# 只留最近 KEEP 份（ls -t 新的在前）
ls -dt $DIR/hangdump-* 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do rm -rf "$old"; done

# 关注的进程：音频服务端、蓝牙、以及我们自己的 DSP 文件服务器
# （#38 的推断是三者共用 QRTR/FastRPC 那条通路）。
watched_pids() {
    # ⚠️ 2026-09-29：原先的 android.hardware.bluetooth 一个进程都匹配不上（pidof 按完整名），
    #   蓝牙 HAL 真名是 android.hardware.bluetooth-service.default；并补上音频 HAL 两个进程。
    for n in audioserver com.android.bluetooth android.hardware.bluetooth-service.default \
             android.hardware.audio.service-aidl.example android.hardware.audio.effect.service-aidl.example \
             hexagonrpcd; do
        pidof "$n" 2>/dev/null
    done
}

# 返回当前处于 D 状态的 tid 列表
d_state_tids() {
    for p in $(watched_pids); do
        for t in /proc/$p/task/*; do
            [ -d "$t" ] || continue
            # /proc/<tid>/stat 第 3 个字段是状态；进程名里可能有空格，
            # 所以从右括号之后再切。
            st=$(sed -e 's/.*) //' -e 's/ .*//' "$t/stat" 2>/dev/null)
            [ "$st" = "D" ] && basename "$t"
        done
    done
}

collect() {
    U=$(cut -d. -f1 /proc/uptime)
    O=$DIR/hangdump-$U
    mkdir -p $O
    log -t hangdump "检测到疑似死锁，取证到 $O"

    { echo "uptime: $(cat /proc/uptime)"; echo "卡住的 tid: $STUCK"; } > $O/00-summary.txt
    for t in $STUCK; do
        {
            echo "=== tid $t ==="
            cat /proc/$t/comm    2>/dev/null
            cat /proc/$t/wchan   2>/dev/null; echo
            echo "--- status ---"; cat /proc/$t/status 2>/dev/null
        } >> $O/01-stuck-threads.txt 2>&1
    done

    # 只列被看的那几个进程：vendor 域读不到别的进程的 /proc（`ps -A` 会每个进程报一条 denial、
    #   结果也只剩这几个）。/proc/<tid>/stack 要 CAP_SYS_ADMIN + ptrace，vendor 域拿不到，已删。
    L=$(watched_pids | tr -s ' \n' ',' | sed 's/^,//;s/,$//')
    [ -n "$L" ] && ps -T -o PID,TID,S,NAME -p "$L" > $O/02-ps.txt 2>&1
    # -S：走 syslog(2)（sepolicy 给了 kernel:system syslog_read）；默认的 /dev/kmsg 是 kmsg_device，不给。
    dmesg -S | tail -800 > $O/03-dmesg.txt 2>&1

    # QRTR 服务表：#38 第 3 步。少了哪个服务就指向哪个 DSP。
    timeout 10 gaokun3-qrtr-lookup > $O/04-qrtr.txt 2>&1

    # 音频数据面还活着吗（内核侧 vs 上层的分水岭，#38 第 1 步）
    for f in /proc/asound/card0/pcm*/sub0/status; do
        { echo "== $f"; timeout 5 cat "$f"; } >> $O/05-pcm.txt 2>&1
    done

    # binder：只读 binderfs 的 state —— 每个进程的 binder 线程与挂起中的事务，
    #   "谁在等谁"正是查死锁要的。它的类型是 binderfs_logs，userdebug 上可读
    #   （system/sepolicy private/domain.te:739 的豁免；本机只编 userdebug）。
    # ⚠️ 2026-09-27 改（#126）：此前读的 transactions / failed_transaction_log 在 domain.te:558-568
    #   里只许 dumpstate / system_server 等读；debugfs 回落那条 neverallow 没有任何豁免。都删了。
    BL=/dev/binderfs/binder_logs
    { echo "== $BL/state（前 2000 行）"; timeout 5 head -2000 $BL/state; } > $O/06-binder.txt 2>&1

    # ✗ logcat / dumpsys 已删（vendor 域做不到，见文件开头）。死锁现场的 logcat 要靠用户
    #   事后 `adb logcat -d` 或 bug report —— 取证目录里的时间戳（目录名就是 uptime）用来对齐。

    sync
    log -t hangdump "取证完成：${O}（本次启动不再重复采集）"
}

PREV=""
STRIKES=0
while true; do
    sleep $INTERVAL
    NOW=$(d_state_tids)
    [ -z "$NOW" ] && { PREV=""; STRIKES=0; continue; }

    # 与上一次采样求交集：只有【同一个 tid】持续卡住才算数
    SAME=""
    for t in $NOW; do
        for q in $PREV; do [ "$t" = "$q" ] && SAME="$SAME $t"; done
    done
    PREV="$NOW"

    if [ -z "$SAME" ]; then STRIKES=0; continue; fi
    STRIKES=$((STRIKES + 1))
    log -t hangdump "同一 tid 持续 D 状态（第 $STRIKES/$STRIKES_NEEDED 次）:$SAME"
    if [ $STRIKES -ge $STRIKES_NEEDED ]; then
        STUCK="$SAME"
        collect
        exit 0
    fi
done

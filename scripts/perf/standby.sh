#!/usr/bin/env bash
# B7 / PERF-3 / PERF-4：待机与长稳采样 —— 宿主机侧的启停与取回。设备侧的采样器是同目录的 standby-sampler.sh。
#
#   SER=gaokun3 bash scripts/perf/standby.sh once     # 只读采一行打到屏幕（不在设备上写任何东西）
#   SER=gaokun3 bash scripts/perf/standby.sh start    # 推采样器到 /data/local/tmp/gk3-standby/ 并常驻
#   SER=gaokun3 bash scripts/perf/standby.sh status   # 在不在跑、记了几行、最后三行
#   SER=gaokun3 bash scripts/perf/standby.sh pull [目录]   # 取回日志（默认 out/standby/<时间>/）并出摘要
#   SER=gaokun3 bash scripts/perf/standby.sh stop     # 停（按 pid 文件，核对过命令行才杀）
#
# 典型用法（docs/release-checklist.md 的 C 档；要用户在场拔线）：
#   1. 插着线 start（会提示当前 allow_suspend；开发机持久 0 的话要【用户决定】临时改 1，本脚本不 setprop）
#   2. 拔 USB → 息屏放 8 小时（拔线后 USB adb 断开，采样器照跑：setsid + nohup，日志每行 sync）
#   3. 插回 → pull（摘要里有掉电百分比 / mAh、挂起次数、qcom_stats 增量）→ stop
#   采样器不会跨重启存活；中途要是重启了，pull 会把【现在的】boot reason history 一起取回，
#   对照日志最后一行就能分清是断电（电量耗尽 / 复位）还是正常关机。
#
# ⚠️ 不用 pkill -f / pgrep -f（CLAUDE.md 运维坑 3）：停的时候按 pid 文件，并先核对 /proc/<pid>/cmdline。
# ⚠️ 要 root：qcom_stats 在 debugfs。adb 本身是 root（开发构建）就直接跑；否则走 su -c（KernelSU 要先给 shell 授权）。
set -u
export MSYS_NO_PATHCONV=1
HERE=$(cd "$(dirname "$0")" && pwd)
SER=${SER:-${SERIAL:-}}
ADB="adb ${SER:+-s $SER}"
D=/data/local/tmp/gk3-standby
SAMPLER=$HERE/standby-sampler.sh

# 设备上以 root 跑一段命令
if [ "$($ADB shell id -u 2>/dev/null | tr -d '\r')" = 0 ]; then
    RSH() { $ADB shell "$1"; }
    RSTDIN() { $ADB shell "sh -s -- $1"; }
else
    RSH() { printf '%s\n' "$1" | $ADB shell su -c sh; }
    RSTDIN() { $ADB shell "su -c 'sh -s -- $1'"; }
fi
R() { RSH "$1" 2>/dev/null | tr -d '\r'; }

alive() {  # 打印在跑的采样器 pid（核对过命令行），不在跑则空
    R "p=\$(cat $D/pid 2>/dev/null); [ -n \"\$p\" ] && tr '\\0' ' ' < /proc/\$p/cmdline 2>/dev/null | grep -q standby-sampler && echo \$p"
}

# 摘要：首行 vs 末行（电量、挂起次数、qcom_stats），外加 ev 计数与 hb 行里 PID 有没有变
summarize() {
    awk '
    function kv(line, k,   r) { if (match(line, "(^| )" k "=[^ ]*")) { r = substr(line, RSTART, RLENGTH); sub(/^ /, "", r); sub(k "=", "", r); return r } return "" }
    function cnt(v) { split(v, a, "/"); return a[1] + 0 }
    /^t=/ { n++; if (n == 1) f = $0; l = $0; ev[kv($0, "ev")]++
            if (kv($0, "ev") == "hb" || kv($0, "ev") == "stop") { if (h == "") h = $0; hl = $0 } }
    END {
        if (n == 0) { print "（日志是空的）"; exit }
        e0 = kv(f, "epoch"); e1 = kv(l, "epoch"); hrs = (e1 - e0) / 3600
        printf "时间：%s → %s（%.2f 小时，%d 行：start %d / wake %d / hb %d / stop %d）\n", kv(f, "t"), kv(l, "t"), hrs, n, ev["start"], ev["wake"], ev["hb"], ev["stop"]
        c0 = kv(f, "cap"); c1 = kv(l, "cap"); q0 = kv(f, "charge_now"); q1 = kv(l, "charge_now")
        printf "电量：%s%% → %s%%（%+d 点", c0, c1, c1 - c0
        if (hrs > 0) printf "，%.2f 点/小时", (c0 - c1) / hrs
        printf "）；charge_now %s → %s µAh（%+.0f mAh）\n", q0, q1, (q1 - q0) / 1000
        printf "供电：开头 ac=%s %s，结尾 ac=%s %s（插着电的这段不算待机掉电）\n", kv(f, "ac"), kv(f, "bstat"), kv(l, "ac"), kv(l, "bstat")
        printf "挂起：success %s → %s（%+d 次），fail %s → %s\n", kv(f, "ss_ok"), kv(l, "ss_ok"), kv(l, "ss_ok") - kv(f, "ss_ok"), kv(f, "ss_fail"), kv(l, "ss_fail")
        split("aosd cxsd ddr slpi adsp cdsp", qs, " ")
        printf "qcom_stats 次数增量："
        for (i = 1; i <= 6; i++) printf "%s %+d  ", qs[i], cnt(kv(l, qs[i])) - cnt(kv(f, qs[i]))
        printf "ddr_lpm %+d\n", kv(l, "ddr_lpm") - kv(f, "ddr_lpm")
        if (h != "") {
            split("p_ss p_sf p_audioserver p_audiohal p_camhal p_senshal", ps, " ")
            printf "进程（PID/RSS kB/fd，首个心跳 → 最后一个）：\n"
            for (i = 1; i <= 6; i++) printf "  %-14s %s → %s\n", ps[i], kv(h, ps[i]), kv(hl, ps[i])
            printf "dropbox（采样开始以来）：system_server_crash %s，tombstone %s，system_app_crash %s\n", kv(hl, "db_ss_crash"), kv(hl, "db_tombstone"), kv(hl, "db_app_crash")
        }
        printf "最后一行的 boot_history：%s\n", kv(l, "boot_history")
    }' "$1"
}

case ${1:-} in
once)
    RSTDIN once < "$SAMPLER" | tr -d '\r'
    ;;
start)
    p=$(alive); [ -n "$p" ] && { echo "已经在跑（pid ${p}）。先 stop 或直接 status。"; exit 1; }
    # 上一轮的日志挪开（不删），这一轮的摘要只算这一轮
    R "mkdir -p $D; [ -f $D/standby.log ] && mv $D/standby.log $D/standby-\$(date +%Y%m%d-%H%M%S).log" >/dev/null
    $ADB push "$SAMPLER" /data/local/tmp/standby-sampler.sh.tmp >/dev/null || { echo "push 失败"; exit 1; }
    R "mv /data/local/tmp/standby-sampler.sh.tmp $D/standby-sampler.sh && chmod 0755 $D/standby-sampler.sh"
    # 推上去的和本地的是同一份吗（看产物，不看命令退出码）
    l=$(shasum -a 256 "$SAMPLER" | awk '{print $1}'); r=$(R "sha256sum $D/standby-sampler.sh" | awk '{print $1}')
    [ "$l" = "$r" ] || { echo "设备上的采样器 sha256 与本地不一致：$r vs $l"; exit 1; }
    # POLL / HB 可从宿主机环境传进去（亮屏硬解 1 小时那种测法要更密的心跳：HB=300）
    R "cd /; POLL=${POLL:-5} HB=${HB:-1800} setsid nohup sh $D/standby-sampler.sh run $D </dev/null >/dev/null 2>&1 &"
    sleep 2
    p=$(alive)
    [ -n "$p" ] || { echo "没起来：$D/pid 不在或进程不对"; exit 1; }
    echo "采样器在跑：pid ${p}，日志 $D/standby.log"
    R "tail -1 $D/standby.log" | cut -c1-200
    a=$(R "getprop persist.vendor.gaokun3.allow_suspend")
    if [ "$a" != 1 ]; then
        echo "⚠️ persist.vendor.gaokun3.allow_suspend = [$a]：这台机器不会挂起，采到的只有心跳。"
        echo "   要测待机，请【用户决定】后手动 setprop 成 1（测完改回），本脚本不替你改。"
    fi
    echo "下一步：拔 USB → 息屏。插回后：SER=$SER bash $0 pull"
    ;;
status)
    p=$(alive)
    [ -n "$p" ] && echo "在跑：pid $p" || echo "没在跑"
    echo "日志行数：$(R "wc -l < $D/standby.log 2>/dev/null")"
    R "tail -3 $D/standby.log 2>/dev/null" | cut -c1-240
    ;;
pull)
    OUT=${2:-out/standby/$(date +%Y%m%d-%H%M%S)}
    mkdir -p "$OUT"
    R "cat $D/standby.log" > "$OUT/standby.log"
    n_r=$(R "wc -l < $D/standby.log" | tr -d ' '); n_l=$(wc -l < "$OUT/standby.log" | tr -d ' ')
    [ "$n_r" = "$n_l" ] || echo "⚠️ 行数对不上：设备 ${n_r}，本地 ${n_l}（传输断了？重跑 pull）"
    R "getprop persist.sys.boot.reason.history; echo; getprop sys.boot.reason; cat /proc/uptime" > "$OUT/boot-now.txt"
    echo "取回 $n_l 行 → $OUT/standby.log"
    echo "--- 摘要 ---"
    summarize "$OUT/standby.log" | tee "$OUT/summary.txt"
    echo "--- 现在的 boot reason（对照上面最后一行：变了 = 中途重启过）---"
    head -3 "$OUT/boot-now.txt"
    ;;
stop)
    p=$(alive)
    [ -n "$p" ] || { echo "没在跑"; exit 0; }
    R "kill $p"
    sleep $(( ${POLL:-5} + 2 ))   # 采样器在 sleep 里收到 TERM，要等这一轮 sleep 结束才写 stop 行
    [ -z "$(alive)" ] && echo "已停（pid ${p}）" || { echo "还在跑（pid ${p}）"; exit 1; }
    ;;
*)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac

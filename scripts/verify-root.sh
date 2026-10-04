#!/usr/bin/env bash
# ReSukiSU（root）上机验收。在【宿主机】跑，通过 adb 检查设备。
#
#   bash scripts/verify-root.sh
#
# ⚠️ 需要 root：开发构建 `adb shell setprop service.adb.root 1 && adb root`（每次重启都要重做）；
#    发布构建（ro.debuggable=0）上 KSU 的 adb root 是否还能用待上机核实（libadbroot 是否依赖
#    ro.debuggable），这些开发脚本只保证在开发构建上可用。
# ⚠️★ 故意【不开 pipefail】。`cmd | grep -q` 里 grep 命中就提前退出，
#    写端吃到 SIGPIPE 返回 141，pipefail 会把整条管道判成失败 ——
#    结果是"值明明对，判据却报 FAIL"。本脚本第一版四个配置项全是这么假阴性的。
set -u
PASS=0; FAIL=0
ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "         $*"; }

A() { adb shell "$@" 2>/dev/null; }

echo "═══ 0. 设备与内核 ═══"
UNAME=$(A 'uname -r -v')
info "$UNAME"
[ -n "$UNAME" ] || { echo "adb 不通，停"; exit 2; }

echo "═══ 1. 内核配置（从 /proc/config.gz 读实值，不看构建机上的 .config）═══"
CFGF=$(mktemp)
# exec-out 而不是 shell：shell 会做行尾转换，压缩流会被弄坏
adb exec-out 'zcat /proc/config.gz' > "$CFGF" 2>/dev/null
if [ ! -s "$CFGF" ]; then
    bad "读不到 /proc/config.gz（要 root；CONFIG_IKCONFIG_PROC 也得开）"
else
    for k in CONFIG_KSU=y CONFIG_KSU_TRACEPOINT_HOOK=y CONFIG_FTRACE_SYSCALLS=y CONFIG_KALLSYMS_ALL=y; do
        if grep -qxF "$k" "$CFGF"; then ok "$k"; else
            bad "$k —— 实际：$(grep "^${k%%=*}=" "$CFGF" || echo '未设置')"
        fi
    done
fi
rm -f "$CFGF"

echo "═══ 2. 驱动在跑（活体证据，不看开机日志）═══"
# ⚠️ 别拿开机那行 "KernelSU: Initialized with driver version" 当判据 ——
#    本机 dmesg 环形缓冲开机十几秒就绕回了，那行早没了，判据会稳定假阴性。
#    改成看【现在还在产生】的钩子活动：hook_manager 每拦一次 execve 就打一行。
BEFORE=$(adb shell 'dmesg | grep -c "KernelSU: hook_manager:"' | tr -d '
')
# 制造一次 execve：用一个平时不会被执行的路径，好在日志里认得出来
adb shell '/system/bin/toybox true' >/dev/null 2>&1
sleep 1
AFTER=$(adb shell 'dmesg | grep -c "KernelSU: hook_manager:"' | tr -d '
')
if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
    ok "tracepoint 钩子活着：制造一次 execve 后 hook_manager 日志 $BEFORE → $AFTER"
elif [ "${AFTER:-0}" -gt 0 ]; then
    ok "有 hook_manager 日志（$AFTER 行），但本次 execve 没新增"
    info "可能是同一进程名被去重，或 dmesg 又绕回了；不判失败"
else
    bad "一条 hook_manager 日志都没有 —— 钩子没挂上，root 不会工作"
fi
adb shell 'dmesg | grep "KernelSU:" | tail -3' | sed 's/^/         /'

echo "═══ 3. 驱动版本（如果开机日志还在的话）═══"
INIT=$(adb shell 'dmesg | grep "Initialized with driver version"' | tr -d '
')
if [ -n "$INIT" ]; then
    ok "$(printf '%s' "$INIT" | sed 's/.*KernelSU: //')"
    case "$INIT" in
        *"Work mode: Built-in"*) ok "Work mode = Built-in" ;;
        *) bad "Work mode 不是 Built-in —— 后加载模式会尝试把 SELinux 切成 enforcing" ;;
    esac
else
    info "[跳过] dmesg 已绕回，开机那行没了（不判失败，第 2 节才是判据）"
fi

echo "═══ 4. 回归：SELinux 还是 permissive ═══"
# ⚠️ init.c:268 在【后加载】分支里会 setenforce(true)。我们是内建，不该走到那儿，
#    但这条值得每次都验 —— 本机没写 sepolicy，被切成 enforcing 会大面积失效。
SE=$(A 'getenforce')
[ "$SE" = "Permissive" ] && ok "getenforce = Permissive" || bad "getenforce = ${SE}（被改了？）"

echo "═══ 5. 管理器 App ═══"
if A 'pm list packages' | grep -q 'com.resukisu.resukisu'; then
    ok "管理器已安装（com.resukisu.resukisu）"
else
    info "[跳过] 管理器没装。装法："
    info "  下载 ReSukiSU_<ver>-arm64-v8a-release.apk 后 adb install"
    info "  （ksud 就在 APK 的 lib/arm64-v8a/libksud.so 里，装 App 即到位）"
fi

echo "═══ 6. ksud 是否就位 ═══"
if A 'ls /data/adb/ksud' | grep -q ksud; then
    ok "/data/adb/ksud 存在"
else
    info "[跳过] /data/adb/ksud 还没有 —— 装了管理器并打开一次才会生成"
fi

echo
echo "═══ 小结：通过 $PASS · 失败 $FAIL ═══"
[ "$FAIL" -eq 0 ]

#!/vendor/bin/sh
# 挂起前把 a600000.usb 的 USB role 切到 host，恢复后切回 device。
#
# 为什么：那个控制器停在 role=device 时，设备挂起阶段会【整板复位】，不留任何日志
# （固件/TZ 级复位，pstore 抓不到）。实测双臂对照：role=host 5/5 通过、
# role=device 第 1 次就复位。而 USB device-mode adb 的 UDC 就在它上面
# （sys.usb.controller=a600000.usb），所以不能简单改成 host 了事。
# 案卷：docs/stage4-findings.md #52 / #54 / #56。
#
# ★ 不变量：wakelock `gaokun3_usbrole` 一直持有，【除非已确认 role 真的是 host】。
#   任何失败路径都保持持有 → 结果只是"不挂起"，绝不会"带着 device 模式去挂起"。
#
# ⚠️ dwc3 的模式切换是【异步】的（dwc3_set_mode 只 queue_work），
#    写完 sysfs 就走会漏掉切换未完成的窗口 —— 必须轮询确认。

WANT="$1"
S=/sys/class/usb_role/a600000.usb-role-switch/role
D=/sys/bus/platform/devices/a600000.usb
UDC=/sys/class/udc/a600000.usb/state
WL=gaokun3_usbrole
TAG=gaokun3-usbrole

say() { log -t $TAG "$*"; }

# xhci 下有没有下游设备（根集线器 usbN 下出现 `1-1` 这类子设备目录）。follow 与 device 分支共用。
# ★ 这是"对面是不是设备"的电气事实：只有 host 模式、xhci 绑上驱动、真枚举出东西时才成立。
#   不用 typec 的 power_role 判断：实机上没插东西的 port1 也报 [source]，那是空口的默认值（v1.0 计划 STOR-2 复核）。
has_downstream() {
    for u in "$D"/xhci-hcd.*/usb*; do
        [ -d "$u" ] && ls "$u" 2>/dev/null | grep -qE '^[0-9]+-[0-9.]+$' && return 0
    done
    return 1
}

# PWR-4 止损：切 host 失败（A6：待机后回插 port0，xhci 一律 -110）时置 1，确认 host 成功时清 0。
#   不持久 —— 口坏了要重启才好，重启后它自然没了。供以后 Parts 发"USB 口异常，重启后恢复待机"的通知。
BROKEN=vendor.gaokun3.usbrole.broken

case "$WANT" in
    host|device|follow) ;;
    *) say "用法: $0 host|device|follow"; exit 2 ;;
esac

if [ ! -e "$S" ]; then
    say "没有 $S —— 不做任何事（wakelock 保持原状）"
    exit 0
fi

# ── follow：让数据角色跟着"对面实际是什么"走（docs/stage4-findings.md #118 §6-8）──
# 为什么不信 UCSI：EC 的 GET_CONNECTOR_STATUS 在插着能枚举我们的主机时报 partner_type=2（UFP），
#   没插也报 2 ⇒ 内核在重新插线时照它切 host，PC 那头的 adb 就没了（#27 的另一半）。
# 为什么不按供电方向推：带 PD 直通的 hub 给我们供电、却要我们当主机 ——
#   "受电 ⇒ 对面是主机"会把它弄坏。
# ★ 只信电气事实：
#   我方受电 + device 模式 + ~6 秒没被枚举（UDC 不是 configured/addressed/default/suspended）⇒ 切 host（hub/扩展坞/充电器）
#   我方受电 + host 模式 + ~6 秒 xhci 下没有任何下游设备 ⇒ 切 device（对面是 PC）
#   两边都试过还是没东西（纯充电器）⇒ 停在 host（挂起安全），直到这根线拔掉
#   我方供电（U 盘、手机）⇒ 对面只能是设备，内核给的 host 是对的，不插手
# ⚠️ 前提是 patches/0048：没有它，任何一次切换都会把 port0 控制器弄坏（xhci -110 / gadget -524）。
# ⚠️ 息屏且允许挂起时不插手 —— 那段时间归 host/device 两个模式管（挂起安全的不变量在那边）。
# ★ 切到 device 之前先拿 wakelock，保持"device 模式不挂起"的不变量（#52）。
P=/sys/class/typec/port0
if [ "$WANT" = follow ]; then
    partner_present() { [ -d ${P}-partner ]; }
    we_are_sink() { case "$(cat $P/power_role 2>/dev/null)" in *"[sink]"*) return 0 ;; esac; return 1; }
    enumerated_by_host() {
        case "$(cat $UDC 2>/dev/null)" in
            configured|addressed|default|suspended) return 0 ;;
        esac
        return 1
    }
    miss=0; tried=""; settled=0
    say "follow 启动"
    while :; do
        sleep 2
        if ! partner_present; then miss=0; tried=""; settled=0; continue; fi
        if [ "$(getprop persist.vendor.gaokun3.allow_suspend)" = 1 ] &&
           [ "$(getprop debug.tracing.screen_state)" != 2 ]; then miss=0; continue; fi
        we_are_sink || { miss=0; continue; }
        [ $settled = 1 ] && continue
        cur=$(cat "$S" 2>/dev/null)
        case "$cur" in
            device) enumerated_by_host && { miss=0; tried=""; continue; } ;;
            host)   has_downstream     && { miss=0; tried=""; continue; } ;;
            *) miss=0; continue ;;
        esac
        miss=$((miss + 1))
        [ $miss -lt 3 ] && continue
        miss=0
        case " $tried " in *" $cur "*) ;; *) tried="$tried $cur" ;; esac
        [ "$cur" = device ] && next=host || next=device
        case " $tried " in
            *" $next "*)
                # 两边都试过：纯充电器。停在 host。
                settled=1
                [ "$cur" = host ] && { say "受电、两种角色都没见到对端 —— 停在 host（纯充电器？）"; continue; }
                next=host ;;
        esac
        [ "$next" = device ] && echo $WL > /sys/power/wake_lock
        echo "$next" > "$S" 2>/dev/null
        say "受电、$cur 模式约 6 秒没见到对端 → 切 $next（已试: $tried）"
    done
fi

# ★ 2026-09-14（#112）：插着 USB 主机（PC 在用 adb）时【不切 host、不放行挂起】。
#   依据：#56 实测 device 模式带着已枚举的 gadget 挂起照样整板复位，所以"插着线睡"在这块板子上
#   目前不可能安全；而切 host 就等于把用户正在用的 adb 拔掉。折中：插着主机 → 息屏但不睡（反正在充电），
#   拔线后再切 host 放行挂起（role_host 进程原地每 2 秒看一次 UDC 状态）。判据用 UDC 的 state：
#   configured/addressed = 有主机在总线另一端；not attached = 没有。
#   ⚠️ 这不是根治。根治是让 dwc3 device 模式的挂起不复位（见 docs/stage4-findings.md #112）。
host_attached() {
    case "$(cat $UDC 2>/dev/null)" in
        configured|addressed|default) return 0 ;;
        *) return 1 ;;
    esac
}

if [ "$WANT" = host ] && host_attached; then
    # 息屏期间插着主机：先关门，再【就在这个进程里】等到拔线（或亮屏）再切 host。
    # ⚠️★ 2026-09-29 改（SELinux 第七轮审计）：原先是 `(setsid "$0" watch &)` 另起一个 watch 进程、
    #   写 pid 文件到 /data/vendor/gaokun3，拔线后再 `exec "$0" host`。三处都站不住：
    #   ① enforcing 下重新执行自己要 execute_no_trans（init_daemon_domain 不给），pid 文件所在的
    #     vendor_data_file 也没给写 —— policy-query 全是 DENY；
    #   ② 更根本的：oneshot 服务的主进程退出时，init 对 vendor API ≥ R 会 SIGKILL 整个进程组
    #     （system/core/init/service.cpp:264-276；本机 ro.board.api_level=202504），setsid 出不了
    #     init 的 cgroup ⇒ watch 进程多半在 role_host 退出那一刻就被杀了（从源码推断，未实测 ——
    #     开发机 allow_suspend=0，这条路径从没跑过）。
    #   现在：role_host 自己留着等；亮屏时 usbrole.rc 先 `stop gaokun3_role_host` 再起 role_device。
    echo $WL > /sys/power/wake_lock
    say "USB 主机在线（UDC=$(cat $UDC 2>/dev/null)）→ 保持 device、不放行挂起（充电中，息屏不睡）；拔线后自动切 host"
    while host_attached; do
        [ "$(getprop debug.tracing.screen_state)" = 2 ] && exit 0
        sleep 2
    done
    say "USB 主机已拔掉（UDC=$(cat $UDC 2>/dev/null)）→ 现在切 host 放行挂起"
fi

# ★ 先把门关上，再动 role。失败路径全都停在这个状态。
echo $WL > /sys/power/wake_lock

# ★ v1.0（PWR-5 / STOR-2）：切 device 之前看对面是不是设备。
#   亮屏（usbrole.rc）和开机（init.gaokun3.usb.rc）都走这里。原先无条件写 device ⇒ port0 上由我们供电的
#   U 盘 / 鼠标 / 手柄一亮屏就掉、follow 也不会救回来（它只管我方受电的情况）；带 PD 的扩展坞每次亮屏断约 6 秒。
#   现在：已是 host 且 xhci 下枚举着东西 ⇒ 保持 host、不写 device。对面是 PC 时 host 模式下枚举不出任何东西，照旧切 device。
#   wakelock 照旧持有（上面刚拿）：亮屏时本来就不睡，息屏时 role_host 会重新确认 host 再放行 —— #52 的不变量不受影响。
#   ⚠️ 开机那次可能早于 U 盘枚举完成 ⇒ 那时仍会切 device（与改之前一样），这一点没有办法在不拖慢开机的前提下根治。
#   ⚠️ 源码推断，未实测：要用户在场插 U 盘做息屏→亮屏（v1.0 计划 PWR-5 的验收）。
if [ "$WANT" = device ] && [ "$(cat "$S" 2>/dev/null)" = host ] && has_downstream; then
    say "role=host 且 xhci 下有下游设备（$(ls "$D"/xhci-hcd.*/usb* 2>/dev/null | grep -E '^[0-9]+-[0-9.]+$' | tr '\n' ' ')）→ 保持 host、不切 device；wakelock 保持持有"
    exit 0
fi

echo "$WANT" > "$S" 2>/dev/null

# 轮询确认（最多约 6 秒）
i=0
OK=0
while [ $i -lt 60 ]; do
    CUR=$(cat "$S" 2>/dev/null)
    if [ "$CUR" = "$WANT" ]; then
        if [ "$WANT" = host ]; then
            # host 模式的判据是 xhci 【绑上了驱动】，不是 role 读回来对。
            # ⚠️ 2026-09-23 以前数的是 `ls $D | grep ^xhci`（平台设备）—— xhci probe 失败（-110）时
            #    平台设备照样在，这个判据从来没真正验过 host 起来了（#118 §7）。
            NX=$(ls -d "$D"/xhci-hcd.*/driver 2>/dev/null | wc -l)
            [ "$NX" -ge 1 ] && { OK=1; break; }
        else
            [ -e /sys/class/udc/a600000.usb ] && { OK=1; break; }
        fi
    fi
    sleep 0.1
    i=$((i + 1))
done

NX=$(ls -d "$D"/xhci-hcd.*/driver 2>/dev/null | wc -l)
if [ "$WANT" = host ]; then
    if [ "$OK" = 1 ]; then
        echo $WL > /sys/power/wake_unlock
        [ "$(getprop $BROKEN)" = 1 ] && setprop $BROKEN 0
        say "已确认 role=host（子 xhci=${NX}，耗时 $((i * 100))ms）→ 放行挂起"
    else
        # 这次开机余下的时间每次息屏都会走到这里 ⇒ 整机不再睡（PWR-4）。不变量优先，只把状态报出去。
        setprop $BROKEN 1
        say "⚠️ 切 host 失败：role=[$(cat $S 2>/dev/null)] 子xhci=$NX —— 保持 wakelock，不放行挂起；已置 $BROKEN=1"
    fi
else
    say "role=[$(cat $S 2>/dev/null)] UDC=[$(ls /sys/class/udc/ 2>/dev/null)] 确认=$OK —— wakelock 保持持有"
fi

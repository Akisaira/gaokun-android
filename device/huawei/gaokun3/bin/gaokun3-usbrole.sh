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
#   不持久 —— 口坏了要重启才好，重启后它自然没了。Parts 据此发"USB 口异常，重启后恢复"的通知（UsbPortNotifier）。
BROKEN=vendor.gaokun3.usbrole.broken

# ── USB-2（v1.0，2026-10-05）：port0 在 host 时让 adbd 的 USB 传输停下 ──────────────
# 现象（1.0.0-dev.1 实机 dmesg）：port0 停在 host 时每秒一组 init 的 "symlink … File exists" +
#   "write …/UDC … Device or resource busy"，外加 f_fs 的 "read descriptors" / "bcdVersion"。
# 谁在每秒重设 sys.usb.ffs.ready —— adbd 自己（LineageOS packages_modules_adb lineage-23.2 的上游副本）：
#   · daemon/usb.cpp:274-282：UsbFfsConnection 的监视线程等 FUNCTIONFS_BIND 只等 1 秒，等不到就断开重来；
#   · daemon/usb.cpp:742-766：usb_ffs_open_thread 随即重开 functionfs —— daemon/usb_ffs.cpp:282-302 重写描述符
#     （f_fs 打 "read descriptors"）并 SetProperty("sys.usb.ffs.ready", "1")；
#   · 同值 setprop 也会触发（init 无条件 NotifyPropertyChange），于是 init.usb.configfs.rc:20-24 每秒重跑一遍：
#     symlink 已存在、写 UDC 失败 —— host 模式下 a600000.usb 这个 UDC 根本不存在，configfs 的 gadget 驱动是
#     match_existing_only（linux v7.2-rc2 drivers/usb/gadget/configfs.c:1985），注册时找不到 UDC 就返回 -EBUSY
#     （drivers/usb/gadget/udc/core.c:1733-1737），udc_name 随即清空（configfs.c:295-303）⇒ 不会挂起等待，下一秒再来。
# 上游早就留了开关，正是为这种情况：usb.cpp:728-740 —— "When the device is acting as a USB host, we'll be unable
#   to bind to the USB gadget…"，读 sys.usb.adb.disabled，为真就在 open_functionfs 之后停在 PropertyMonitor 里等它
#   变回假（:751-755）；init.usb.rc:23-24（refs/lineage-system-core/rootdir/）把 vendor.sys.usb.adb.disabled 拷过去。
# ⇒ 我们按【实际角色】设它：host ⇒ 1，device ⇒ 0。只停 adbd 的 USB 传输：不动 sys.usb.config（B1 的「USB 调试」
#   开关语义、init.gaokun3.usb.rc 里 init.svc.adbd 的桥接都不受影响），TCP / 无线调试照常。
#   切回 device、设回 0 之后：adbd 起连接 → 1 秒等不到 BIND → 重开 ffs → ffs.ready=1 → init 写 UDC（此时 UDC 已在）
#   → 绑上，USB adb 约 1–2 秒回来 —— 与现在"切回 device 后靠每秒重试碰上"是同一条路，只是 host 期间不再空转。
# 属性链：本脚本 setprop vendor.gaokun3.usbrole.adb_pause（vendor_gaokun3_prop，本域有 set_prop）→ etc/usbrole.rc
#   用两条字面量触发器 setprop vendor.sys.usb.adb.disabled（vendor_default_prop：只有 init / vendor_init 能设，
#   refs/lineage-sepolicy/private/domain.te:802；vendor_init 有 set_prop，vendor_init.te:306）→ init.usb.rc 拷成
#   sys.usb.adb.disabled（system_prop，adbd 能读：core_property_type，private/domain.te:461/467）。
# ⚠️ 读源码得出、未上机。判据见 etc/usbrole.rc 的 USB-2 一段。
ADB_PAUSE=vendor.gaokun3.usbrole.adb_pause
adb_gate() {
    r=""
    read -r r 2>/dev/null < "$S"
    case "$r" in
        host)   want=1 ;;
        device) want=0 ;;
        *) return 0 ;;
    esac
    [ "$(getprop $ADB_PAUSE)" = "$want" ] && return 0
    setprop $ADB_PAUSE $want
    if [ $want = 1 ]; then
        say "role=host ⇒ $ADB_PAUSE=1（adbd 的 USB 传输停下，不再每秒重绑 UDC，USB-2）"
    else
        say "role=device ⇒ $ADB_PAUSE=0（adbd 的 USB 传输恢复，USB-2）"
    fi
}

# ── USB-1（v1.0，2026-10-05）：插电脑时 port0 落成【我方供电】、数据连不上 ─────────────
# 现象（10-05 实机，插 Mac：DRP 对 DRP、对端不支持 PD）：port0 有时协商成我方供电（power_role=[source]），平板给电脑
#   充电，内核随之定成 host，两边都不枚举 ⇒ USB adb 不出现。下面的 follow 只在我方受电时纠偏，这种情况不管。
#   拔插一次即恢复（当场验证：重插后 [sink]、UDC configured）。
# 主动换成受电方走不通：UCSI 的 ucsi_pr_swap 要对端支持 PD，非 PD 时交换后复位连接器并返回 -EPROTO
#   （refs/linux-v7.2-rc2/drivers/usb/typec/ucsi/ucsi.c:1607-1650）⇒ 只能请用户重插：
#   我方供电 + 对端不支持 PD + 没有数据连接（host 且 xhci 下无设备，或 device 且没被主机枚举）持续约 6 秒
#   ⇒ 置 vendor.gaokun3.usbrole.reversed=1，Parts（UsbPortNotifier）弹"平板正在给对方供电，请拔下重插"；
#   条件不再成立 / 拔线 ⇒ 清 0。
# "对端不支持 PD"的判据：port0-partner/supports_usb_power_delivery = no，或 port0/power_operation_mode 不是
#   usb_power_delivery（typec class：linux v7.2-rc2 drivers/usb/typec/class.c:799-807、:1917-1925）。
#   ⚠️ 没用 usb_power_delivery_revision = 0.0：1.0.0-dev.1 实机插着 Mac（Mac 供电、有 PD 合同）时对端读到的
#   就是 supports_usb_power_delivery=yes、revision=0.0、power_operation_mode=usb_power_delivery —— 这台的 EC 不报
#   PD 版本，拿 0.0 当"无 PD"会把有 PD 的对端也算进去。
# 不算的：accessory_mode 不是 none 的对端（模拟音频 / 调试附件）。
# ⚠️ 也会命中"只取电、不是 USB 设备"的东西（USB 风扇 / 灯）—— 通知的措辞因此写成"若连的是电脑"。
REVERSED=vendor.gaokun3.usbrole.reversed

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
    we_are_source() { case "$(cat $P/power_role 2>/dev/null)" in *"[source]"*) return 0 ;; esac; return 1; }
    enumerated_by_host() {
        case "$(cat $UDC 2>/dev/null)" in
            configured|addressed|default|suspended) return 0 ;;
        esac
        return 1
    }
    # USB-1：对端不支持 PD（判据与理由见文件开头 USB-1 一段）
    partner_no_pd() {
        case "$(cat ${P}-partner/accessory_mode 2>/dev/null)" in ""|none) ;; *) return 1 ;; esac
        [ "$(cat ${P}-partner/supports_usb_power_delivery 2>/dev/null)" = no ] && return 0
        m=$(cat $P/power_operation_mode 2>/dev/null)
        [ -n "$m" ] && [ "$m" != usb_power_delivery ]
    }
    # USB-1：我方供电、对端无 PD、而且没有任何数据连接
    source_no_data() {
        # 口已坏（A6，broken=1）时插 U 盘也会"我方供电 + host + 无下游"，别再叠一条误导的"方向反了"（审查建议修 4）
        [ "$(getprop $BROKEN)" = 1 ] && return 1
        we_are_source || return 1
        partner_no_pd || return 1
        case "$(cat "$S" 2>/dev/null)" in
            host)   has_downstream && return 1 ;;
            device) enumerated_by_host && return 1 ;;
            *) return 1 ;;
        esac
        return 0
    }
    rev_last=""
    set_reversed() {   # $1 = 0/1；只在变化时 setprop（本进程记着上次的值，免得每 2 秒 fork 一次 getprop）
        [ "$rev_last" = "$1" ] && return 0
        rev_last=$1
        rv=$(getprop $REVERSED)
        [ "$rv" = "$1" ] && return 0
        [ "$1" = 0 ] && [ -z "$rv" ] && return 0
        setprop $REVERSED "$1"
        if [ "$1" = 1 ]; then
            say "$REVERSED=1：我方供电、对端无 PD、约 6 秒没有数据连接 ⇒ 请用户重插（USB-1）"
        else
            say "$REVERSED=0（USB-1 解除）"
        fi
    }
    miss=0; tried=""; settled=0; srcmiss=0; last_role=""; gate_n=0
    say "follow 启动"
    while :; do
        sleep 2
        # USB-2：角色一变（包括内核 / UCSI 自己切的）就同步 adbd 的 USB 暂停开关；另外约每分钟对一次账。
        cur_role=""; read -r cur_role 2>/dev/null < "$S"
        gate_n=$((gate_n + 1))
        if [ "$cur_role" != "$last_role" ] || [ $gate_n -ge 30 ]; then
            adb_gate; last_role=$cur_role; gate_n=0
        fi
        if ! partner_present; then miss=0; tried=""; settled=0; srcmiss=0; set_reversed 0; continue; fi
        if [ "$(getprop persist.vendor.gaokun3.allow_suspend)" = 1 ] &&
           [ "$(getprop debug.tracing.screen_state)" != 2 ]; then miss=0; continue; fi
        if ! we_are_sink; then
            miss=0
            # USB-1：连续 3 轮（约 6 秒）都是"我方供电、无 PD、无数据" ⇒ 置 1；一轮不成立就清
            if source_no_data; then
                srcmiss=$((srcmiss + 1))
                [ $srcmiss -ge 3 ] && set_reversed 1
            else
                srcmiss=0; set_reversed 0
            fi
            continue
        fi
        srcmiss=0; set_reversed 0
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
        # 不在这里 adb_gate：dwc3 切换是异步的，下一轮（2 秒后）按读回的角色同步（见循环开头）
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
    adb_gate     # USB-2：停在 host ⇒ adbd 的 USB 传输停下（开机那次尤其要紧：follow 还没起来）
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
adb_gate         # USB-2：按读回来的实际角色同步（切不成时角色没变，它也就不动）
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

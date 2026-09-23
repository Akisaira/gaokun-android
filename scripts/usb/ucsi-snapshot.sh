#!/usr/bin/env bash
# 一次抓下两个 USB-C 口"EC 说了什么"与"实际是什么"，用来给 UCSI 数据角色的 quirk 取证。
#
#   bash scripts/usb/ucsi-snapshot.sh [<adb 序列号，默认 192.168.10.239:5555>] [场景说明]
#
# 每换一种插法（PC / U 盘 / 纯充电器 / 扩展坞 / 什么都不插）跑一次。
# 判据：EC 的 partner_type（1=DFP 对方是主机，2=UFP 对方是设备）要和
#       UDC state（configured = 真有主机在另一端）对得上。
#
# 字段位置（v7.2-rc2 drivers/usb/typec/ucsi/ucsi.h:353-366）：
#   CONNECTED bit19 · PWR_DIR bit20（0=我方是受电方）· PARTNER_TYPE bits29-31
# 命令格式：GET_CONNECTOR_STATUS=0x12，连接器号在 bit16 起（ucsi.h:133,146）；
#   debugfs 放行这条命令（debugfs.c:54）。只读查询，不改任何状态。
#
# 2026-09-23 第一个数据点（port1 插着能枚举我们的主机、PD 充电）：
#   dword0=0x400b4000 connected=1 pwr_dir=0 partner_type=2  ← 实际对方是主机，应为 1
#   而 port2 什么都没插也报 partner_type=2 —— 这个字段可能是常数，不是"反了"。
set -u
D=${1:-192.168.10.239:5555}
NOTE=${2:-}
adb -s "$D" root >/dev/null 2>&1

echo "=== $(date '+%F %T') ${NOTE:+— $NOTE}"
adb -s "$D" shell '
U=$(ls -d /sys/kernel/debug/usb/ucsi/*/ 2>/dev/null | head -1)
[ -n "$U" ] || { echo "!! 没有 UCSI debugfs"; exit 1; }
for c in 1 2; do
    printf "0x%x" $(( (c<<16) | 0x12 )) > ${U}command
    echo "con$c $(cat ${U}response)"
done
for p in /sys/class/typec/port0 /sys/class/typec/port1; do
    echo "sysfs $(basename $p) data_role=[$(cat $p/data_role)] power_role=[$(cat $p/power_role)] partner=$([ -d $p-partner ] && echo yes || echo no)"
done
echo "usb_role $(cat /sys/class/usb_role/*/role 2>/dev/null)  udc $(cat /sys/class/udc/*/state 2>/dev/null)"
' | tr -d '\r' | while read -r l; do
    case "$l" in
    con*)
        c=${l%% *}; r=$(echo "$l" | grep -oE '0x[0-9a-f]{32}')
        python3 -c "
lo=int('${r:18:16}',16); d0=lo&0xffffffff
t={0:'?',1:'DFP(对方是主机)',2:'UFP(对方是设备)',3:'有源线',4:'有源线+UFP',5:'调试附件',6:'音频附件'}
print('%s EC: dword0=0x%08x connected=%d pwr_dir=%d(%s) partner_type=%d %s' % ('$c', d0, (d0>>19)&1, (d0>>20)&1,
      '我方受电' if not (d0>>20)&1 else '我方供电', (d0>>29)&7, t.get((d0>>29)&7,'?')))" ;;
    *) echo "$l" ;;
    esac
done

#!/usr/bin/env bash
# 在 Ego 的 Ubuntu 里跑：只读挂载 Windows 分区，认出传感器芯片型号。
#
# 为什么要这么干（docs/stage4/stage6 反复记过）：
#   本机 DTS 里【没有任何】加速度计/磁力计/光感节点（grep 全空），所以
#   Android 侧 `dumpsys sensorservice` 是 "No Sensors on the device"，
#   连带没有自动旋转与自动亮度。但这台是 Windows 平板，出厂一定有这些器件
#   —— 只是主线内核不知道它们在哪条总线、什么地址。
#   识别芯片型号是往 DTS 里加节点的【第一步】，而型号只有 Windows 驱动知道。
#
# 全程只读，不写 Windows 分区。
set -uo pipefail
WIN=${WIN:-/dev/nvme0n1p3}
MNT=/mnt/winprobe

sudo -n mkdir -p "$MNT"
if ! mountpoint -q "$MNT"; then
  # ro + 忽略 hibernate/dirty 标志，纯读不修复
  sudo -n mount -t ntfs3 -o ro,noatime "$WIN" "$MNT" 2>/dev/null \
    || sudo -n mount -t ntfs   -o ro,noatime "$WIN" "$MNT" 2>/dev/null \
    || { echo "挂不上 ${WIN}（ntfs3/ntfs-3g 都不行）"; exit 1; }
fi
echo "已只读挂载 $WIN -> $MNT"
echo

echo "════ 1) DriverStore 里与传感器有关的驱动包 ════"
sudo -n ls "$MNT/Windows/System32/DriverStore/FileRepository" 2>/dev/null \
  | grep -iE 'sensor|accel|gyro|magn|compass|als|light|hid|icm|bmi|bmc|lis[23]|kx[0-9]|stk[0-9]|apds|tcs[0-9]|opt[0-9]|ltr[0-9]|qcom.*sensor' \
  | sort -u
echo

echo "════ 2) INF 里出现的传感器芯片关键字（含出现次数）════"
sudo -n grep -rlisE 'accelerometer|magnetometer|ambient light|gyroscope' \
     "$MNT/Windows/INF" 2>/dev/null | head -30 | while read -r f; do
  echo "--- $f"
  sudo -n grep -hoiE '(ICM[0-9]{5}|BMI[0-9]{3}|BMA[0-9]{3}|BMM[0-9]{3}|LIS[0-9A-Z]{3,6}|KX[0-9]{3}|AK[0-9]{4}|MMC[0-9]{4}|STK[0-9]{4}|APDS[0-9]{4}|TCS[0-9]{4}|LTR[0-9]{3,4}|OPT[0-9]{4}|TSL[0-9]{4}|VCNL[0-9]{4}|HID_DEVICE_UP:[0-9A-Fx]+_U:[0-9A-Fx]+)' "$f" 2>/dev/null | sort -u | sed 's/^/      /'
done
echo

echo "════ 3) ACPI/HID 硬件 ID（这些直接对应 DTS 里要写的 compatible）════"
sudo -n grep -rhoiE 'ACPI\(QCOM|HUAW|INTC|BOSC|STMI|KIOX|ELAN|SMO)[0-9A-F]{4}' \
     "$MNT/Windows/INF" 2>/dev/null | tr 'a-z' 'A-Z' | sort | uniq -c | sort -rn | head -30
echo

echo "════ 4) 传感器相关驱动 .sys 文件名 ════"
sudo -n find "$MNT/Windows/System32/drivers" -maxdepth 1 -iname '*sensor*' -o -maxdepth 1 -iname '*accel*' \
     -o -maxdepth 1 -iname '*als*' -o -maxdepth 1 -iname '*hid*' 2>/dev/null | sed 's|.*/|      |' | sort -u
echo

echo "════ 5) 卸载 ════"
sudo -n umount "$MNT" && echo "已卸载（Windows 分区未被修改）"

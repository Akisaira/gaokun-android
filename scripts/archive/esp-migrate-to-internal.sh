#!/system/bin/sh
# 把 systemd-boot 引导链装进【内置 ESP】(nvme0n1p1)，让机器不再依赖 U 盘。
#
# 背景：整条引导链（含 crdroid.conf 与全部内核）原本【只在 U 盘 sda1 的 ESP 上】，
# 内置 ESP 里只有 Windows 的引导器 —— 拔掉 U 盘，Android 完全无法启动。
# 这是「抹掉 Windows 只留 Android」的前置阻塞：不先搬引导链就删 Windows，
# 机器会彻底开不了机。
#
# 纯增量：不删除、不修改任何 Windows 文件。唯一被覆盖的是 EFI/Boot/bootaa64.efi
# （可移动介质回落路径），而且先备份成 bootaa64.efi.bak-windows。
# ★ 实测那份原文件是 3120168 B，与 EFI/Microsoft/Boot/bootmgfw.efi 字节数完全相同
#   —— 它就是 Windows Boot Manager 的副本，而 bootmgfw.efi 本体没被动过。
#
# 在【Android 里以 root 运行】（adb shell setprop service.adb.root 1 && adb root）：
#     adb push scripts/esp-migrate-to-internal.sh /data/local/tmp/
#     adb shell sh /data/local/tmp/esp-migrate-to-internal.sh
# 幂等：重复跑不会覆盖已有的备份。
#
# 回滚（一条命令）：
#     mount -t vfat -o rw /dev/block/nvme0n1p1 /mnt/esp_int
#     cp /mnt/esp_int/EFI/Boot/bootaa64.efi.bak-windows /mnt/esp_int/EFI/Boot/bootaa64.efi
#   （其余全是新增文件，留着也不影响任何东西）
set -u
MID=8a29534fa802480d9fbb71aa18c01d7b
U=/mnt/esp_usb
I=/mnt/esp_int
fail() { echo "!!! $1"; exit 1; }

mkdir -p $U $I
mountpoint -q $U || mount -t vfat -o ro  /dev/block/sda1      $U || fail "挂不上 U 盘 ESP"
mountpoint -q $I && umount $I
mount -t vfat -o rw /dev/block/nvme0n1p1 $I || fail "挂不上内置 ESP(rw)"
echo "已挂载：$U (ro)  $I (rw)"
echo "内置 ESP 空闲: $(df -k $I | tail -1 | awk '{print int($4/1024)}') MiB"
echo

echo "════ 1) 建目录 ════"
mkdir -p "$I/EFI/systemd" "$I/loader/entries" "$I/$MID/android" "$I/$MID/7.2.0-rc2-gaokun3+" || fail "建目录失败"

echo "════ 2) 搬内核载荷（大文件先走；此时引导路径尚未改动）════"
copy() {  # copy <相对路径>
    s="$U/$1"; d="$I/$1"
    [ -f "$s" ] || fail "源文件不存在: $s"
    cp "$s" "$d" || fail "复制失败: $1"
    sa=$(sha256sum "$s" | cut -d' ' -f1)
    da=$(sha256sum "$d" | cut -d' ' -f1)
    [ "$sa" = "$da" ] || fail "校验不符: $1"
    printf "  OK  %-52s %8d B\n" "$1" "$(stat -c%s "$d")"
}
copy "$MID/android/Image-kb23"
copy "$MID/android/ramdisk-crdroid.img"
copy "$MID/android/sc8280xp-huawei-gaokun3.dtb"
copy "$MID/7.2.0-rc2-gaokun3+/linux"
copy "$MID/7.2.0-rc2-gaokun3+/initrd.img-7.2.0-rc2-gaokun3+"
copy "$MID/7.2.0-rc2-gaokun3+/dtb-otg.dtb"
sync
echo "  搬完后空闲: $(df -k $I | tail -1 | awk '{print int($4/1024)}') MiB"
echo

echo "════ 3) 写 loader 配置 ════"
cp "$U/loader/entries.srel" "$I/loader/entries.srel" || fail "entries.srel"

# 默认项 = Ubuntu 救援系统。纪律不变：**默认必须落在能远程接入的系统上**，
# 这样 Android 挂死时拍一下电源键就自动回落，不需要有人在机器边。
#
# ⚠️★ 这里有过一次代价不小的判断失误，写下来免得重蹈：
#   装完引导链后我读 EFI 变量 LoaderDevicePartUUID 得到 d5cb76b5-…（= U 盘 sda1），
#   据此认为"固件永远优先 U 盘，内置这份只在 U 盘不在时才用到"，
#   于是把默认项设成了 Android。**删掉 Windows 分区之后这个变量变成了
#   825eaf3a-…（= 内置盘 nvme0n1p1）** —— 固件当场翻转成优先内置盘，
#   而它的默认项是 Android，于是自动回落的安全网悄无声息地断了，
#   症状只是"莫名其妙进了 Android"，极难联想到根因。
#   **教训：引导优先级不是一次测定就永久成立的事实，动过分区表必须重读。**
#
# 前提：内置盘上要真的有一个不依赖 U 盘的 Ubuntu（本仓做法是把活动根
# rsync 到 nvme0n1p3，hostname 改成 gaokun3-rescue 便于一眼分辨）。
# 若还没有，就把默认项暂时留给 U 盘上的 Ubuntu，别留给 Android。
#
# 进 Android：sudo bootctl set-oneshot <mid>-int-crdroid.conf 后重启，
#            或开机时在 15 秒菜单里手选。
cat > "$I/loader/loader.conf" <<'CONF'
default 8a29534fa802480d9fbb71aa18c01d7b-int-ubuntu.conf
timeout 15
console-mode keep
editor no
CONF

# Android：与 U 盘上的 crdroid.conf 完全同一套 cmdline
cat > "$I/loader/entries/$MID-int-crdroid.conf" <<'CONF'
title      >>> crDroid 16.0【内置盘引导】<<<
version    crdroid-16.0-kb23-internal
sort-key   zandroid0
options    androidboot.flash.locked=0 androidboot.verifiedbootstate=orange iommu.passthrough=0 iommu.strict=0 androidboot.hardware=gaokun3 androidboot.boot_devices=soc@0/1c20000.pcie androidboot.selinux=permissive androidboot.veritymode=disabled firmware_class.path=/vendor/firmware/ init=/init printk.devkmsg=on deferred_probe_timeout=10 console=tty0 clk_ignore_unused pd_ignore_unused arm64.nopauth efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000
linux      /8a29534fa802480d9fbb71aa18c01d7b/android/Image-kb23
devicetree /8a29534fa802480d9fbb71aa18c01d7b/android/sc8280xp-huawei-gaokun3.dtb
initrd     /8a29534fa802480d9fbb71aa18c01d7b/android/ramdisk-crdroid.img
CONF

# Ubuntu 救援：rootfs 仍在 U 盘 sda2 上，所以【拔掉 U 盘这条起不来】。
# 留着是为了「U 盘在、但固件改走内置盘」时救援路径不断。
cat > "$I/loader/entries/$MID-int-ubuntu.conf" <<'CONF'
title      Ubuntu 7.2.0-rc2【内置盘引导 · 需 U 盘 rootfs】
version    7.2.0-rc2-gaokun3+-otg-internal
machine-id 8a29534fa802480d9fbb71aa18c01d7b
sort-key   linux2
options    root=UUID=a2447957-fc4d-40d4-ab64-faf74f697471 clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1 systemd.machine_id=8a29534fa802480d9fbb71aa18c01d7b
linux      /8a29534fa802480d9fbb71aa18c01d7b/7.2.0-rc2-gaokun3+/linux
devicetree /8a29534fa802480d9fbb71aa18c01d7b/7.2.0-rc2-gaokun3+/dtb-otg.dtb
initrd     /8a29534fa802480d9fbb71aa18c01d7b/7.2.0-rc2-gaokun3+/initrd.img-7.2.0-rc2-gaokun3+
CONF
sync
echo "  loader.conf + 2 个条目已写入"
echo "  （Windows Boot Manager 由 systemd-boot 自动发现，无需条目）"
echo

echo "════ 4) 最后一步：装 systemd-boot 本体 ════"
cp "$U/EFI/systemd/systemd-bootaa64.efi" "$I/EFI/systemd/systemd-bootaa64.efi" || fail "systemd-boot 复制失败"

# ★ 回落路径。先备份 Windows 那份，再覆盖。
if [ ! -f "$I/EFI/Boot/bootaa64.efi.bak-windows" ]; then
    cp "$I/EFI/Boot/bootaa64.efi" "$I/EFI/Boot/bootaa64.efi.bak-windows" || fail "备份失败"
    echo "  已备份原 bootaa64.efi -> bootaa64.efi.bak-windows ($(stat -c%s "$I/EFI/Boot/bootaa64.efi.bak-windows") B)"
else
    echo "  备份已存在，跳过（幂等）"
fi
cp "$U/EFI/systemd/systemd-bootaa64.efi" "$I/EFI/Boot/bootaa64.efi" || fail "写回落路径失败"
sync
echo "  EFI/Boot/bootaa64.efi 已换成 systemd-boot ($(stat -c%s "$I/EFI/Boot/bootaa64.efi") B)"
echo

echo "════ 5) 终检 ════"
echo "内置 ESP 剩余空闲: $(df -k $I | tail -1 | awk '{print int($4/1024)}') MiB"
echo "--- 目录树 ---"
find "$I/EFI" "$I/loader" "$I/$MID" -type f | sed "s|$I|  |"
echo "--- Windows 文件仍在 ---"
ls -la "$I/EFI/Microsoft/Boot/bootmgfw.efi" 2>/dev/null || echo "  ⚠️ 找不到 bootmgfw.efi"
sync
umount $I && echo "内置 ESP 已卸载"
umount $U && echo "U 盘 ESP 已卸载（全程只读，未修改）"

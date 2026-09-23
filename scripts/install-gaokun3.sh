#!/usr/bin/env bash
#
# gaokun-android installer — Huawei MateBook E Go (SC8280XP / gaokun3)
#
# Run this from ANY arm64 Linux live environment on the target machine
# (Ubuntu/Debian arm64 live USB is fine). It repartitions the internal NVMe,
# writes Android, installs systemd-boot, and installs the Linux rescue system
# that doubles as this machine's recovery partition.
#
#     sudo ./install-gaokun3.sh /path/to/release-dir
#
# ⚠️ THIS ERASES THE INTERNAL DISK. Everything on it — Windows included.
#
# ────────────────────────────────────────────────────────────────────────────
# Why the layout looks the way it does
#
# This machine is UEFI, not fastboot. There are no A/B boot partitions, no
# recovery partition and no serial console. systemd-boot loads the kernel,
# DTB and ramdisk as plain files from the ESP.
#
#   esp          300M   systemd-boot + kernels + ramdisks.
#                       ★ PARTLABEL must be exactly "esp": the boot_control
#                         HAL finds it through /dev/block/by-name/esp to mirror
#                         the active A/B slot into loader.conf. The customary
#                         name "EFI system partition" has spaces and cannot be
#                         used by-name. UEFI identifies the ESP by partition
#                         *type* GUID, so renaming it is harmless.
#   misc         4M     bootloader_control (A/B slot state). Required:
#                       get_misc_blk_device() only accepts an fstab entry whose
#                       mount point is exactly "/misc" — there is no by-name
#                       fallback — and libboot_control cannot start without it.
#   metadata    32M     Android metadata.
#   super       12G     system/system_ext/product/vendor, A/B (Virtual A/B, so
#                       one physical copy plus COW snapshots in userdata).
#   rescue      24G     A full Linux. This is the recovery environment: it is
#                       the default boot entry, so a hung Android is one power
#                       button press away from a system you can SSH into.
#   userdata    rest    /data
#
# Order on disk matters: userdata is last so it can be grown later without
# moving anything.
# ────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REL="${1:-}"
DISK="${DISK:-/dev/nvme0n1}"
MID="${MID:-$(cat /etc/machine-id 2>/dev/null || echo 8a29534fa802480d9fbb71aa18c01d7b)}"

SUPER_SIZE_MIB=12288
RESCUE_SIZE_MIB=24576
ESP_SIZE_MIB=300
MISC_SIZE_MIB=4
# boot_a / boot_b：标准 Android boot 镜像（header v2，kernel+ramdisk+dtb 一体）。
# 内容约 27 MiB；64 MiB 与 BoardConfig.mk 的 BOARD_BOOTIMAGE_PARTITION_SIZE 对齐。
BOOT_SIZE_MIB=64
METADATA_SIZE_MIB=32

die() { echo "!! $*" >&2; exit 1; }
say() { echo; echo "══ $*"; }

# ── preflight ──────────────────────────────────────────────────────────────
[ "$(id -u)" = 0 ] || die "run as root"
[ -n "$REL" ] || die "usage: $0 <release-dir>"
[ -d "$REL" ] || die "no such directory: $REL"
[ -b "$DISK" ] || die "no such disk: $DISK"

for t in sgdisk partprobe mkfs.ext4 mkfs.vfat simg2img bootctl rsync python3; do
    command -v "$t" >/dev/null || die "missing tool: $t (apt install gdisk android-sdk-libsparse-utils dosfstools systemd-boot rsync)"
done

need() { [ -f "$REL/$1" ] || die "release is missing $1"; }
need super.img
# ★ boot.img 是标准 Android boot 镜像，会同时写进 boot_a 与 boot_b。
#   ESP 上给 systemd-boot 用的那三个文件由它解包而来（见下面的 ESP 段）——
#   boot 分区是唯一真相源。
need boot.img

say "Target disk"
sgdisk -p "$DISK" || true
cat <<EOF

This will DESTROY every partition on $DISK, including any Windows install.
There is no undo. Type exactly: ERASE
EOF
read -r confirm
[ "$confirm" = "ERASE" ] || die "aborted"

# ── partition ──────────────────────────────────────────────────────────────
say "Partitioning $DISK"
sgdisk --zap-all "$DISK"
sgdisk \
    -n "1:0:+${ESP_SIZE_MIB}M"      -t 1:ef00 -c 1:"esp" \
    -n "2:0:+${MISC_SIZE_MIB}M"     -t 2:8300 -c 2:"misc" \
    -n "3:0:+${METADATA_SIZE_MIB}M" -t 3:8300 -c 3:"metadata" \
    -n "4:0:+${SUPER_SIZE_MIB}M"    -t 4:8300 -c 4:"super" \
    -n "7:0:+${BOOT_SIZE_MIB}M"     -t 7:8300 -c 7:"boot_a" \
    -n "8:0:+${BOOT_SIZE_MIB}M"     -t 8:8300 -c 8:"boot_b" \
    -n "5:0:+${RESCUE_SIZE_MIB}M"   -t 5:8300 -c 5:"rescue" \
    -n "6:0:0"                      -t 6:8300 -c 6:"userdata" \
    "$DISK"
partprobe "$DISK"; sleep 2
sgdisk -p "$DISK"

p() { echo "${DISK}p$1"; }   # nvme naming
[ -b "$(p 1)" ] || die "kernel did not pick up the new table"

# ── filesystems ────────────────────────────────────────────────────────────
say "Creating filesystems"
mkfs.vfat -F 32 -n GAOKUN3ESP "$(p 1)"
# misc is raw. Zero it so libboot_control sees an invalid CRC and initialises
# a fresh bootloader_control block on first boot.
dd if=/dev/zero of="$(p 2)" bs=1M count="$MISC_SIZE_MIB" status=none
mkfs.ext4 -q -F -L metadata "$(p 3)"
mkfs.ext4 -q -F -L rescue   "$(p 5)"
mkfs.ext4 -q -F -L userdata "$(p 6)"

# ── android ────────────────────────────────────────────────────────────────
say "Writing super"
# ⚠️ super.img is an Android *sparse* image. dd'ing it produces a partition
# that looks byte-identical to the file yet has no LP metadata, and Android
# then resets during first-stage mount with nothing in any log. Judge by
# format, not by checksum: magic 3aff26ed at offset 0 means sparse.
magic=$(dd if="$REL/super.img" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
if [ "$magic" = "3aff26ed" ]; then
    simg2img "$REL/super.img" "$(p 4)"
else
    echo "  (not sparse — writing raw)"
    dd if="$REL/super.img" of="$(p 4)" bs=64M conv=fsync status=progress
fi
sync
lp=$(dd if="$(p 4)" bs=1 skip=4096 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$lp" = "67446c61" ] || die "super has no LP geometry magic at offset 4096 (got '$lp')"
echo "  LP geometry magic OK"

# ── boot_a / boot_b ────────────────────────────────────────────────────────
# Standard Android boot images, written to both slots so either one boots a
# freshly installed machine. update_engine owns them from here on: `boot` is
# in AB_OTA_PARTITIONS, so a kernel change ships as an ordinary OTA.
say "Writing boot_a / boot_b"
for n in 7 8; do
    dd if="$REL/boot.img" of="$(p $n)" bs=4M conv=fsync status=none
done
sync
echo "  boot.img -> $(p 7) and $(p 8)"

# The bootloader here is systemd-boot, which cannot read an Android boot
# image — it loads plain files from the ESP. So unpack the image and put the
# pieces on the ESP, once per slot. The boot partitions stay the source of
# truth; these are derived copies, refreshed by the OTA postinstall hook
# (vendor/bin/gaokun3-ota-postinstall.sh) on every update.
#
# ⚠️ This mirrors device/huawei/gaokun3/bootimg/bootimg_extract.cpp, which is
# what runs on the device. Two implementations because they run in different
# worlds (a plain Linux live image here, Android there). Both were checked
# against the same boot.img and produce byte-identical output.
say "Unpacking boot.img for systemd-boot"
BOOTPARTS=$(mktemp -d)
python3 - "$REL/boot.img" "$BOOTPARTS" <<'PYEOF'
import struct, sys, os
img, out = sys.argv[1], sys.argv[2]
with open(img, "rb") as f:
    hdr = f.read(1664)
    if hdr[:8] != b"ANDROID!":
        sys.exit("not an Android boot image (bad magic)")
    u32 = lambda off: struct.unpack_from("<I", hdr, off)[0]
    kernel_size, ramdisk_size, second_size = u32(8), u32(16), u32(24)
    page, ver = u32(36), u32(40)
    if ver != 2:
        sys.exit("expected boot header v2, got %d" % ver)
    recovery_dtbo_size, dtb_size = u32(1632), u32(1648)
    align = lambda x: (x + page - 1) // page * page
    off = page
    parts = []
    for size, name in ((kernel_size, "Image"), (ramdisk_size, "ramdisk.img")):
        parts.append((off, size, name))
        off += align(size)
    off += align(second_size) + align(recovery_dtbo_size)
    parts.append((off, dtb_size, "gaokun3.dtb"))
    for start, size, name in parts:
        if size == 0:
            sys.exit("%s is empty in the boot image" % name)
        f.seek(start)
        data = f.read(size)
        if len(data) != size:
            sys.exit("short read for %s" % name)
        with open(os.path.join(out, name), "wb") as o:
            o.write(data)
        print("  %-12s %10d bytes" % (name, size))
    # cmdline[512] @64 + extra_cmdline[1024] @608, each NUL-terminated — the same
    # "%.*s%.*s" concatenation bootimg_extract.cpp writes to cmdline.txt on the device.
    cstr = lambda b: b.split(b"\0", 1)[0].decode("ascii")
    cmdline = cstr(hdr[64:576]) + cstr(hdr[608:1632])
    with open(os.path.join(out, "cmdline.txt"), "w") as o:
        o.write(cmdline)
    print("  %-12s %10d bytes" % ("cmdline.txt", len(cmdline)))
PYEOF
[ -s "$BOOTPARTS/Image" ] || die "boot.img unpack produced no kernel"
[ -s "$BOOTPARTS/cmdline.txt" ] || die "boot.img carries no kernel command line"

# ── rescue system ──────────────────────────────────────────────────────────
say "Installing the rescue system"
mkdir -p /mnt/rescue && mount "$(p 5)" /mnt/rescue
if [ -f "$REL/rescue-rootfs.tar.zst" ]; then
    zstd -dc "$REL/rescue-rootfs.tar.zst" | tar -C /mnt/rescue -xf -
else
    # No prebuilt rootfs shipped: clone the live environment we are running in.
    # rsync, not dd — the source is a mounted, running filesystem, and dd would
    # capture it mid-write. -x keeps us on one filesystem, which also skips
    # /proc /sys /dev /run and the ESP without needing excludes.
    echo "  no rescue-rootfs.tar.zst in the release — cloning this live system"
    rsync -aHAXx --numeric-ids / /mnt/rescue/
    mkdir -p /mnt/rescue/{proc,sys,dev,run,tmp,boot/efi,mnt,media}
    chmod 1777 /mnt/rescue/tmp
fi
RESCUE_UUID=$(blkid -s UUID -o value "$(p 5)")
ESP_UUID=$(blkid -s UUID -o value "$(p 1)")
cat > /mnt/rescue/etc/fstab <<EOF
UUID=$RESCUE_UUID  /         ext4  errors=remount-ro,noatime  0 1
UUID=$ESP_UUID     /boot/efi vfat  defaults,nofail,x-systemd.device-timeout=10s  0 2
EOF
echo "gaokun3-rescue" > /mnt/rescue/etc/hostname
sed -i 's/^127\.0\.1\.1.*/127.0.1.1\tgaokun3-rescue/' /mnt/rescue/etc/hosts 2>/dev/null || true

# ── bootloader ─────────────────────────────────────────────────────────────
say "Installing systemd-boot"
mkdir -p /mnt/esp && mount "$(p 1)" /mnt/esp
bootctl --esp-path=/mnt/esp install --no-variables
# --no-variables because these kernels boot with efi=noruntime; do not depend on
# EFI variables existing. The removable-media fallback path EFI/BOOT/BOOTAA64.EFI
# that bootctl writes is what this firmware actually uses.

# One directory per slot. The OTA postinstall hook writes only into the
# directory of the slot it just flashed, so an update can never touch the
# kernel the machine is currently running — that is what makes rollback safe.
mkdir -p "/mnt/esp/$MID/android/slot_a" "/mnt/esp/$MID/android/slot_b"          "/mnt/esp/$MID/rescue"
for sl in a b; do
    cp "$BOOTPARTS/Image"       "/mnt/esp/$MID/android/slot_$sl/Image"
    cp "$BOOTPARTS/gaokun3.dtb" "/mnt/esp/$MID/android/slot_$sl/gaokun3.dtb"
    cp "$BOOTPARTS/ramdisk.img" "/mnt/esp/$MID/android/slot_$sl/ramdisk.img"
done
# Android recovery, if the release ships it. It shares the kernel and DTB with
# the system — verified identical, sha256 for sha256 — so only the ramdisk is
# extra. Optional so that older release directories still install.
if [ -f "$REL/recovery-ramdisk.img" ]; then
    for sl in a b; do
        cp "$REL/recovery-ramdisk.img" "/mnt/esp/$MID/android/slot_$sl/recovery-ramdisk.img"
    done
    echo "  recovery ramdisk installed for both slots"
else
    echo "  (no recovery-ramdisk.img in the release — skipping recovery)"
fi

# The rescue Linux runs the same kernel; it just gets its own initrd.
cp "$BOOTPARTS/Image"       "/mnt/esp/$MID/rescue/Image"
cp "$BOOTPARTS/gaokun3.dtb" "/mnt/esp/$MID/rescue/gaokun3.dtb"
[ -f /boot/initrd.img ] && cp /boot/initrd.img "/mnt/esp/$MID/rescue/initrd.img" || \
  cp "$(ls -1t /boot/initrd.img-* 2>/dev/null | head -1)" "/mnt/esp/$MID/rescue/initrd.img"

# The command line comes from boot.img (BOARD_KERNEL_CMDLINE), not from a copy
# kept here. A hand-kept copy lived here until 2026-09-23 and had already drifted:
# it lacked himax_hx83121a_spi.disable_pressure=0, so fresh v0.6.2 installs had
# no touch contact-size axes until their first OTA (docs/TODO.md B15). The OTA
# postinstall hook derives its entry the same way, so both paths now agree.
ANDROID_CMDLINE=$(tr -d '\r\n' < "$BOOTPARTS/cmdline.txt")
echo "  kernel command line: $ANDROID_CMDLINE"

# One entry per A/B slot, each pointing at its own slot directory — the kernel
# is slotted now, exactly like the dynamic partitions inside super. The
# boot_control HAL switches between them by rewriting `default` in loader.conf,
# matching on the glob *-android-a.conf / *-android-b.conf, so these filenames
# are load-bearing.
#
# The paths below are also load-bearing: the OTA postinstall hook writes
# Image / gaokun3.dtb / ramdisk.img into slot_<suffix> under exactly these
# names, so an entry and its hook have to agree. Change one, change both.
for s in a b; do
    cat > "/mnt/esp/loader/entries/$MID-android-$s.conf" <<EOF
title      crDroid 16.0 (gaokun3) — slot _$s
version    gaokun3-slot-$s
sort-key   zandroid$s
options    $ANDROID_CMDLINE androidboot.slot_suffix=_$s
linux      /$MID/android/slot_$s/Image
devicetree /$MID/android/slot_$s/gaokun3.dtb
initrd     /$MID/android/slot_$s/ramdisk.img
EOF
done

# ⚠️★ recovery 的启动项默认【不】创建。2026-08-20 实测这个 recovery ramdisk 在本机
#   会进复位循环（Android 一次都没进），而且不留 panic 记录 —— 本机 init 的服务级
#   失败是主动 reboot() 而非 panic，所以 init_fatal_panic + efi_pstore 抓不到。
#   条目一旦存在，谁在 15 秒菜单里误选一次就得跑到机器旁按电源键。
#   ramdisk 照样铺（无害，14 MB），将来验证通过再默认打开。
#   要调试：ENABLE_RECOVERY_ENTRY=1 ./install-gaokun3.sh …
if [ "${ENABLE_RECOVERY_ENTRY:-0}" = 1 ]; then
  for s in a b; do
      [ -f "/mnt/esp/$MID/android/slot_$s/recovery-ramdisk.img" ] || continue
      sed -e "s|^initrd .*|initrd     /$MID/android/slot_$s/recovery-ramdisk.img|" \
          -e "s|^title .*|title      Recovery (gaokun3) — slot _$s|" \
          -e "s|^version .*|version    gaokun3-recovery-$s|" \
          -e "s|^sort-key .*|sort-key   zzrecovery$s|" \
          "/mnt/esp/loader/entries/$MID-android-$s.conf" \
          > "/mnt/esp/loader/entries/$MID-recovery-$s.conf"
  done
else
    echo "  (recovery boot entry skipped — known to reset-loop; set ENABLE_RECOVERY_ENTRY=1 to create it)"
fi

cat > "/mnt/esp/loader/entries/$MID-rescue.conf" <<EOF
title      Linux rescue (gaokun3)
version    gaokun3-rescue
sort-key   linux
options    root=UUID=$RESCUE_UUID rootwait clk_ignore_unused pd_ignore_unused \
arm64.nopauth iommu.passthrough=0 iommu.strict=0 modprobe.blacklist=simpledrm \
efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 \
consoleblank=0 loglevel=4
linux      /$MID/rescue/Image
devicetree /$MID/rescue/gaokun3.dtb
initrd     /$MID/rescue/initrd.img
EOF

# ★ Default = the rescue system, not Android.
#
# The rule is: whatever boots by default must be something you can reach
# remotely. Android hanging is then one power-button press away from a shell,
# with nobody needing to be near the machine. Booting Android by default
# would give a nicer out-of-box experience and throw that away.
#
# To boot Android: pick it from the 15-second menu, or from the rescue system
#   sudo bootctl set-oneshot <machine-id>-android-a.conf && reboot
#
# ⚠️ The boot_control HAL rewrites this `default` line to *-android-a.conf the
# first time Android marks a boot successful — that is correct A/B behaviour
# and how it survives an OTA slot switch. If you want the rescue system to
# stay the default on a development machine, set it back after first boot.
cat > /mnt/esp/loader/loader.conf <<EOF
default $MID-rescue.conf
timeout 15
console-mode keep
editor no
EOF

sync
umount /mnt/esp
umount /mnt/rescue

say "Done"
cat <<EOF

Installed on $DISK:
  esp       $(p 1)
  misc      $(p 2)
  metadata  $(p 3)
  super     $(p 4)
  boot_a    $(p 7)   (Android boot image, in AB_OTA_PARTITIONS)
  boot_b    $(p 8)
  rescue    $(p 5)   (default boot entry, hostname gaokun3-rescue)
  userdata  $(p 6)

Reboot, then pick "crDroid 16.0 (gaokun3) — slot _a" from the menu.

First boot takes a couple of minutes. Afterwards:
  * connect Wi-Fi once by hand. That is the only manual step left: the
    framework permanently disables a network it has decided has no internet,
    and only a user-initiated connection with a password clears that. Every
    other setting that used to need a post-flash script is now in the image.
EOF

#!/bin/bash
# 造一个假 ESP + 假 vendor，把 gaokun3-ota-postinstall.sh 换掉路径后用指定的 shell（mksh / dash / ksh）跑。
#   harness.sh <shell> <场景目录> [目标槽 0|1]
# 场景目录里：esp/（初始 ESP 内容）、mode（persist.vendor.gaokun3.gk3boot 的值，可无）、vendor/（boot/gk3boot/…，可无）
set -u
SH=$1; SC=$2; SLOT=${3:-1}
W=${GK3_PI_WORK:?}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
R=$W/run; rm -rf "$R"; mkdir -p "$R/bin" "$R/stub" "$R/dev" "$R/mnt"
cp -R "$SC/esp" "$R/esp"
mkdir -p "$R/boot"; [ -d "$SC/vendor/boot" ] && cp -R "$SC/vendor/boot/." "$R/boot/"
# 假块设备：存在即可
touch "$R/dev/esp" "$R/dev/boot_a" "$R/dev/boot_b"
sed -e "s#/dev/block/by-name/#$R/dev/#g" \
    -e "s#/mnt/gaokun3_ota_esp#$R/esp#g" \
    -e "s#/mnt/gaokun3_esp_probe#$R/mnt/probe#g" \
    "$REPO/device/huawei/gaokun3/bin/gaokun3-ota-postinstall.sh" > "$R/bin/gaokun3-ota-postinstall.sh"
cat > "$R/bin/gaokun3-bootimg-extract" <<'EOF'
#!/bin/sh
d=$2; printf 'IMAGE' > "$d/Image"; printf 'RD' > "$d/ramdisk.img"; printf 'DTB' > "$d/gaokun3.dtb"
printf 'console=tty0 foo=bar' > "$d/cmdline.txt"
EOF
chmod +x "$R/bin/gaokun3-bootimg-extract"
# 桩：mount 只在 -o ro 探测时"成功"并把探测挂载点链到假 ESP；真挂载是 no-op（MNT 已经是假 ESP）
cat > "$R/stub/mount" <<EOF
#!/bin/sh
for a in "\$@"; do last=\$a; done
case "\$last" in */mnt/probe) rm -rf "\$last"; ln -s "$R/esp" "\$last" ;; esac
exit 0
EOF
cat > "$R/stub/umount" <<EOF
#!/bin/sh
case "\$1" in */mnt/probe) rm -f "\$1"; mkdir -p "\$1" ;; esac
exit 0
EOF
MODE=""; [ -f "$SC/mode" ] && MODE=$(cat "$SC/mode")
cat > "$R/stub/getprop" <<EOF
#!/bin/sh
case "\$1" in persist.vendor.gaokun3.gk3boot) printf '%s\n' "$MODE" ;; *) echo "" ;; esac
EOF
FREE=${FREE_KB:-200000}
cat > "$R/stub/df" <<EOF
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted"
echo "fake 300000 1 $FREE 1% /x"
EOF
cat > "$R/stub/stat" <<'EOF'
#!/bin/sh
# 只实现 stat -c%s FILE
f=$2; wc -c < "$f" | tr -d ' '
EOF
cat > "$R/stub/toybox" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$R/stub/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$R/stub/"*
PATH="$R/stub:$PATH" "$SH" "$R/bin/gaokun3-ota-postinstall.sh" "$SLOT" 3>&1
echo "RC=$?"
echo "── ESP 之后："
(cd "$R/esp" && find . -type f -o -type l | LC_ALL=C sort)

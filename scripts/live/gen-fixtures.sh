#!/usr/bin/env bash
# 用【真后端】录图形安装器的 fixture（界面在 Mac 上开发、golden 出图时回放它们）。
#
#   bash scripts/live/test-in-container.sh scripts/live/gen-fixtures.sh
#   GK3_TEST_BOOTIMG=/repo/out/…/boot.img …   （用真发版 boot.img，进度里的大小更像真的）
#
# 产物：live/installer-flutter/testdata/<场景>/{index.txt, *.txt}，格式见 record-fixture.py。
#
# ★ 为什么录而不是手写：手写的 fixture 是"界面对着一份想象中的协议开发"。
#   本仓协议里有好几处不显然（百分号编码、PLANERR 走 stdout、PROGRESS 走 stderr、
#   gk3__run 往 stdout 回显 "+ 命令"），手写一定会写成作者以为的样子。
#   手写的只有容器里做不到的几项（common/ 里：预检、连 WiFi、下载清单），
#   index.txt 里逐条标了"手写"和理由。
#
# 场景：
#   factory       出厂布局（docs/hw-inventory.md 第 8 节），整盘都是 Windows，没有空闲区
#   windows-free  factory 上【真跑一次 gk3_shrink】把 Data 缩掉 80 GiB 之后 → 走双系统
#   blank         一块空盘 → 走整盘
#   android       blank 上真装一遍之后（"已经装过"：双系统应被 partlabel-conflict 拒绝）
set -u
cd "$(dirname "$0")/../.."
[ "$(id -u)" = 0 ] || { echo "要 root（用 scripts/live/test-in-container.sh 跑）"; exit 2; }
. scripts/live/installer-lib.sh
export GK3_ALLOW_LOOP=1 GK3_MACHINE_ID=0123456789abcdef0123456789abcdef
OUT=live/installer-flutter/testdata
W=$(mktemp -d /tmp/gk3-fix.XXXX)
LOOPS=()
cleanup() {
    local m l
    for m in $(findmnt -rno TARGET | grep -e "^$W" -e '^/media/gk3' | sort -r); do umount "$m" 2>/dev/null; done
    # ⚠️★ 按背后的镜像文件找 loop，【不】靠 LOOPS 数组：new_disk 是在 $(…) 里调的，
    #   它往 LOOPS 里加的东西留在子 shell 里 —— 2026-09-24 就这样漏了 58 个 loop，
    #   每个攥着一个已删除的稀疏文件，把 colima 的 98G 盘写满。
    for img in "$W"/*.img; do
        for l in $(losetup -j "$img" 2>/dev/null | cut -d: -f1); do losetup -d "$l" 2>/dev/null; done
    done
    rm -rf "$W"
}
trap cleanup EXIT
new_disk() { truncate -s "$2" "$W/$1.img"; local l; l=$(losetup -fP --show "$W/$1.img"); LOOPS+=("$l"); echo "$l"; }
settle() { partprobe "$1" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1; }

# ── 安装介质：一个假 U 盘挂在 /media/gk3，好让 gk3_probe 真的报出 medium=yes ────
STICK=$(new_disk stick 7680M)
sgdisk -o -n 1:2048:0 -t 1:ef00 -c 1:esp "$STICK" >/dev/null 2>&1; settle "$STICK"
mkfs.vfat -F 32 -n GK3LIVE "${STICK}p1" >/dev/null
mkdir -p /media/gk3 && mount "${STICK}p1" /media/gk3 && mkdir -p /media/gk3/gaokun3

# ── 发布目录（与 test-apply.sh 同一套造法；super 做成 12 GiB，进度数字才像真的）──
REL=$W/rel; mkdir -p "$REL"
if [ -n "${GK3_TEST_BOOTIMG:-}" ]; then cp "$GK3_TEST_BOOTIMG" "$REL/boot.img"
else python3 - "$REL" <<'PYEOF'
import os, struct, sys
rel = sys.argv[1]; P = 4096; al = lambda x: (x + P - 1) // P * P
kern, ramd, dtb = b"MZ" + os.urandom(300000), os.urandom(123457), b"\xd0\x0d\xfe\xed" + os.urandom(20001)
c = b"androidboot.hardware=gaokun3 androidboot.boot_devices=soc@0/1c20000.pcie init=/init console=tty0 clk_ignore_unused efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000"
h = bytearray(P); h[0:8] = b"ANDROID!"
struct.pack_into("<IIIIIIIIII", h, 8, len(kern), 0x8000, len(ramd), 0x1000000, 0, 0, 0x100, P, 2, 0)
h[64:64 + len(c)] = c; struct.pack_into("<IQII", h, 1632, 0, 0, 1660, len(dtb))
with open(os.path.join(rel, "boot.img"), "wb") as f:
    f.write(h); [f.write(x.ljust(al(len(x)), b"\0")) for x in (kern, ramd, dtb)]
PYEOF
fi
truncate -s 12288M "$W/super.raw"
printf 'gDla' | dd of="$W/super.raw" bs=1 seek=4096 conv=notrunc status=none
for off in 1 900 4000 9000; do head -c 16777216 /dev/urandom | dd of="$W/super.raw" bs=1M seek=$off conv=notrunc status=none; done
img2simg "$W/super.raw" "$W/super.img" >/dev/null && rm "$W/super.raw"
zstd -q -19 --long -f "$W/super.img" -o "$REL/super.img.zst" && rm "$W/super.img"
( cd "$REL" && sha256sum boot.img super.img.zst > install-artifacts.sha256 )
# 发版的校验清单里还有 OTA zip 那一行（scripts/release.sh:136），gk3_release_info 从它取版本名
echo "65905f68074595215edac60616e2f633fb0c6db7fcab6ffb06f38e155b511e92  crDroidAndroid-16.0-20260916-gaokun3-v12.11.zip" >> "$REL/install-artifacts.sha256"
for n in rescue.squashfs initramfs.img; do head -c 65536 /dev/urandom > "/media/gk3/gaokun3/$n"; done
head -c 65536 /dev/urandom > "$W/sdboot.efi"; export GK3_SDBOOT=$W/sdboot.efi

# ── 录制 ─────────────────────────────────────────────────────────────────
# rec <场景> <盘> <文件名> <界面会发出的调用（用 nvme0n1 写）> [实际执行的命令]
rec() {
    local sc=$1 d=$2 name=$3 call=$4 real=${5:-}
    local dir=$OUT/$sc; mkdir -p "$dir"
    [ -n "$real" ] || real=$(printf '%s' "$call" | sed "s#/dev/nvme0n1#$d#g")
    python3 scripts/live/record-fixture.py "$dir/$name" \
        --sub "${STICK}p=/dev/sda" --sub "$STICK=/dev/sda" --sub "$d=/dev/nvme0n1" \
        --sub "$REL=/media/gk3/gaokun3/payload" --sub "$W=/tmp" \
        -- bash -c ". scripts/live/installer-lib.sh && $real"
    printf '%-78s %s\n' "$call" "$name" >> "$dir/index.txt"
}
# 探测只留这块盘和 U 盘（容器里还看得见 colima 虚拟机自己的 vda 与别的 loop），
# 并把 loop 报不出来的两个字段按真机填上：内置盘 tran=nvme，U 盘 tran=usb removable=1
probe_of() {
    printf '%s' "gk3_probe | awk -v d='$1' -v u='$STICK' '
      (\$1==\"DISK\" && \$2==\"path=\"d) { sub(/tran=[^ ]*/, \"tran=nvme\"); print; next }
      (\$1==\"DISK\" && \$2==\"path=\"u) { sub(/tran=[^ ]*/, \"tran=usb\"); sub(/removable=0/, \"removable=1\"); print; next }
      (\$1==\"PART\" && (index(\$2, \"path=\"d\"p\")==1 || index(\$2, \"path=\"u\"p\")==1)) { print; next }
      (\$1==\"FREE\" && (\$2==\"disk=\"d || \$2==\"disk=\"u)) { print }'"
}
header() {   # $1=场景 $2=说明
    mkdir -p "$OUT/$1"; rm -f "$OUT/$1"/*.txt
    { echo "# 场景：$1 —— $2"
      echo "# 录制：scripts/live/gen-fixtures.sh，$(date +%F)，Debian $(cat /etc/debian_version) 容器，loop 设备"
      echo "# 替换：loop 设备 → /dev/nvme0n1（内置盘）与 /dev/sda（安装 U 盘，挂在 /media/gk3）；"
      echo "#       DISK 行的 tran= 按真机填（loop 报不出来）；U 盘的 removable 填 1。其余一律原样。"
      echo "# 格式：<界面发出的调用>  <文件>。找不到精确匹配时用 '<函数> *' 那一行。"; } > "$OUT/$1/index.txt"
}

echo "═══ factory ═══"
DF=$(new_disk factory 488386M)
TOT=$(blockdev --getsz "$DF"); LAST=$(( TOT - 34 ))
E7=$LAST;                       S7=$(( (E7 - 2097152 + 1) / 2048 * 2048 ))
E6=$(( S7 - 1 ));               S6=$(( (E6 - 18 * 2097152 + 1) / 2048 * 2048 ))
E5=$(( S6 - 1 ));               S5=$(( (E5 - 2097152 + 1) / 2048 * 2048 ))
sgdisk -o \
  -n 1:2048:+300M -t 1:ef00 -c 1:"EFI system partition" \
  -n 2:0:+16M     -t 2:0c01 -c 2:"Microsoft reserved partition" \
  -n 3:0:+120G    -t 3:0700 -c 3:"Basic data partition" \
  -n 4:0:$(( S5 - 1 )) -t 4:0700 -c 4:"Basic data partition" \
  -n 5:$S5:$E5 -t 5:0700 -c 5:"Basic data partition" \
  -n 6:$S6:$E6 -t 6:0700 -c 6:"Basic data partition" \
  -n 7:$S7:$E7 -t 7:2700 -c 7:"Basic data partition" "$DF" >/dev/null 2>&1
settle "$DF"
mkfs.vfat -F 32 -n SYSTEM "${DF}p1" >/dev/null; mkfs.vfat -F 32 -n WINPE "${DF}p5" >/dev/null
mkntfs -Q -F -L Windows "${DF}p3" >/dev/null 2>&1; mkntfs -Q -F -L Data   "${DF}p4" >/dev/null 2>&1
mkntfs -Q -F -L Onekey  "${DF}p6" >/dev/null 2>&1; mkntfs -Q -F -L WinRE  "${DF}p7" >/dev/null 2>&1
# ESP 里放 Windows 的引导件与一块"固件胶囊"，占到接近出厂的用量（hw-inventory.md 第 8ter 节：188 MiB 空闲）
mmd -i "${DF}p1" ::/EFI ::/EFI/Microsoft ::/EFI/Microsoft/Boot ::/EFI/Boot
head -c 1572864  /dev/urandom > "$W/f1"; mcopy -i "${DF}p1" "$W/f1" ::/EFI/Microsoft/Boot/bootmgfw.efi
head -c 29360128 /dev/urandom > "$W/f2"; mcopy -i "${DF}p1" "$W/f2" ::/EFI/Microsoft/Boot/BCD-and-fonts.bin
head -c 1572864  /dev/urandom > "$W/f3"; mcopy -i "${DF}p1" "$W/f3" ::/EFI/Boot/bootaa64.efi
head -c 73400320 /dev/urandom > "$W/f4"; mcopy -i "${DF}p1" "$W/f4" ::/Persisted_Capsules.bin
# NTFS 里放一点真数据，好让"最小能缩到多少"不是 0（mount 走 ntfs-3g）
for n in 3 4; do mkdir -p "$W/n$n"; ntfs-3g "${DF}p$n" "$W/n$n" 2>/dev/null \
    && dd if=/dev/zero of="$W/n$n/data.bin" bs=1M count=$(( n == 3 ? 1024 : 2048 )) status=none; umount "$W/n$n" 2>/dev/null; done
header factory "出厂布局（docs/hw-inventory.md 第 8 节），整盘都是 Windows，没有空闲区"
rec factory "$DF" probe.txt           "gk3_probe" "$(probe_of "$DF")"
rec factory "$DF" esp_info.txt        "gk3_esp_info /dev/nvme0n1p1"
rec factory "$DF" shrink_scan.txt     "gk3_shrink_scan /dev/nvme0n1"
rec factory "$DF" plan-wipe-rescue.txt   "gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue yes"
rec factory "$DF" plan-wipe-norescue.txt "gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue no"
# Data 336.6 GiB → 缩掉 80 GiB
DATA_MIB=$(( $(blockdev --getsize64 "${DF}p4") / 1048576 )); TARGET=$(( DATA_MIB - 81920 ))
rec factory "$DF" shrink.txt          "gk3_shrink /dev/nvme0n1p4 $TARGET"
echo "gk3_shrink *                                                                   shrink.txt" >> "$OUT/factory/index.txt"

echo "═══ windows-free ═══"
header windows-free "factory 上真跑了一次 gk3_shrink（Data 缩掉 80 GiB）之后 —— 走双系统"
rec windows-free "$DF" probe.txt       "gk3_probe" "$(probe_of "$DF")"
rec windows-free "$DF" esp_info.txt    "gk3_esp_info /dev/nvme0n1p1"
rec windows-free "$DF" shrink_scan.txt "gk3_shrink_scan /dev/nvme0n1"
FREE=$(bash -c ". scripts/live/installer-lib.sh && $(probe_of "$DF")" | grep '^FREE ' | sort -t= -k5 -n | tail -1)
RS=$(gk3__f "$FREE" start); RE=$(gk3__f "$FREE" end)
for r in yes no; do
  rec windows-free "$DF" "plan-along-rescue-$r.txt" \
      "gk3_plan --disk /dev/nvme0n1 --mode alongside --rescue $r --region-start $RS --region-end $RE --esp /dev/nvme0n1p1"
done
rec windows-free "$DF" plan-wipe-rescue.txt "gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue yes"
rec windows-free "$DF" apply-along.txt \
    "gk3_apply --disk /dev/nvme0n1 --mode alongside --rescue yes --release /media/gk3/gaokun3/payload --region-start $RS --region-end $RE --esp /dev/nvme0n1p1" \
    "gk3_apply --disk $DF --mode alongside --rescue yes --release $REL --region-start $RS --region-end $RE --esp ${DF}p1"
echo "gk3_apply *                                                                    apply-along.txt" >> "$OUT/windows-free/index.txt"

echo "═══ blank ═══"
DB=$(new_disk blank 488386M); sgdisk -o "$DB" >/dev/null 2>&1; settle "$DB"
header blank "一块空盘（只有一张空 GPT）—— 走整盘"
rec blank "$DB" probe.txt                "gk3_probe" "$(probe_of "$DB")"
rec blank "$DB" plan-wipe-rescue.txt     "gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue yes"
rec blank "$DB" plan-wipe-norescue.txt   "gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue no"
rec blank "$DB" plan-wipe-small.txt      "gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue yes --userdata-mib 100"
rec blank "$DB" apply-wipe.txt \
    "gk3_apply --disk /dev/nvme0n1 --mode wipe --rescue yes --release /media/gk3/gaokun3/payload" \
    "gk3_apply --disk $DB --mode wipe --rescue yes --release $REL"
echo "gk3_apply *                                                                    apply-wipe.txt" >> "$OUT/blank/index.txt"

echo "═══ android ═══"
header android "blank 上真装了一遍之后（已经装过）—— 双系统应被 partlabel-conflict 拒绝"
rec android "$DB" probe.txt       "gk3_probe" "$(probe_of "$DB")"
rec android "$DB" esp_info.txt    "gk3_esp_info /dev/nvme0n1p1"
rec android "$DB" plan-along.txt  "gk3_plan --disk /dev/nvme0n1 --mode alongside --rescue no --region-start 2048 --region-end 4096 --esp /dev/nvme0n1p1"
rec android "$DB" plan-wipe-rescue.txt "gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue yes"

echo "═══ common（与盘无关）═══"
C=$OUT/common; mkdir -p "$C"; rm -f "$C"/*.txt
{ echo "# 与盘无关的调用。所有场景找不到时都回落到这里。"
  echo "# ⚠️ 标了「手写」的几条是容器里做不到的：不是这台机器（没有 DMI）、没有 wlan0、下载清单还不存在。"
  echo "#    它们照着真实输出的格式写：预检的值取自 docs/hw-inventory.md:33 的实测 dmesg。"; } > "$C/index.txt"
# 手写：预检（容器不是 gaokun3）
cat > "$C/preflight-ok.txt" <<'EOF'
O CHECK id=root ok=yes
O CHECK id=uefi ok=yes
O CHECK id=model ok=yes value=GK-W7X
O CHECK id=bios ok=yes value=2.16
O CHECK id=secureboot ok=yes value=disabled
O CHECK id=tools ok=yes
X 0
EOF
cat > "$C/preflight-bios217.txt" <<'EOF'
O CHECK id=root ok=yes
O CHECK id=uefi ok=yes
O CHECK id=model ok=yes value=GK-W7X
O CHECK id=bios ok=no value=2.17 why=bios-untested
O CHECK id=secureboot ok=no value=enabled
O CHECK id=tools ok=yes
X 0
EOF
printf '%-78s %s\n' "gk3_preflight" "preflight-ok.txt   # 手写（容器不是 gaokun3）" >> "$C/index.txt"
# 录：WiFi 扫描 —— 跑的是真 gk3-wpa-scan.py，输入是按 printf_encode 编码的合成 scan_results
python3 - > "$W/scan_results" <<'PYEOF'
def enc(b):
    m = {0x22: '\\"', 0x5C: '\\\\', 0x09: '\\t'}
    return "".join(m[x] if x in m else chr(x) if 32 <= x <= 126 else "\\x%02x" % x for x in b)
print("bssid / frequency / signal level / flags / ssid")
for i, (f, s, fl, n) in enumerate([
    (5180, -42, "[WPA2-PSK-CCMP][ESS]", "宿舍网-5G".encode()), (2412, -63, "[WPA2-PSK-CCMP][ESS]", "宿舍网".encode()),
    (5745, -55, "[WPA2-PSK-CCMP][WPA3-SAE-CCMP][ESS]", b"TP-LINK_8A3F"), (2437, -70, "[ESS]", b"CMCC-WEB"),
    (5200, -58, "[WPA2-EAP-CCMP][ESS]", b"eduroam"), (2462, -77, "[WPA2-PSK-CCMP][ESS]", "隔壁 的 网".encode()),
    (5240, -84, "[WPA2-PSK-CCMP][ESS]", b"ChinaNet-xk9q")]):
    print("aa:bb:cc:00:00:%02x\t%d\t%d\t%s\t%s" % (i, f, s, fl, enc(n)))
PYEOF
python3 scripts/live/record-fixture.py "$C/wifi_scan.txt" -- python3 scripts/live/gk3-wpa-scan.py < "$W/scan_results" 2>/dev/null \
  || python3 scripts/live/record-fixture.py "$C/wifi_scan.txt" -- bash -c "python3 scripts/live/gk3-wpa-scan.py < $W/scan_results"
printf '%-78s %s\n' "gk3_wifi_scan" "wifi_scan.txt   # 录（真 gk3-wpa-scan.py，合成的 scan_results）" >> "$C/index.txt"
# 手写：连 WiFi（容器里没有 wlan0）—— 进度与结尾的 NET 记录照 gk3_wifi_connect 的输出写
cat > "$C/wifi_connect-ok.txt" <<'EOF'
E PROGRESS 20 正在连接 所选网络
D 1200
E PROGRESS 60 取 IP 地址
D 900
E PROGRESS 100 已连接
O NET if=wlan0 ip=192.168.10.239 ssid=宿舍网-5G online=yes
X 0
EOF
cat > "$C/wifi_connect-fail.txt" <<'EOF'
E PROGRESS 20 正在连接 所选网络
D 1500
E !! 连不上 所选网络（密码错？信号弱？）
X 1
EOF
printf '%-78s %s\n' "gk3_wifi_connect *" "wifi_connect-ok.txt   # 手写（容器里没有 wlan0）" >> "$C/index.txt"
cat > "$C/net_status-off.txt" <<'EOF'
O NET if=wlan0 ip=none ssid=none online=no
X 0
EOF
printf '%-78s %s\n' "gk3_net_status" "net_status-off.txt   # 手写" >> "$C/index.txt"
# 录：发布目录 / 安装 U 盘里带了什么
python3 scripts/live/record-fixture.py "$C/release_info.txt" --sub "$REL=/media/gk3/gaokun3/payload" \
    -- bash -c ". scripts/live/installer-lib.sh && gk3_release_info $REL"
printf '%-78s %s\n' "gk3_release_info" "release_info.txt   # 录" >> "$C/index.txt"
python3 scripts/live/record-fixture.py "$C/release_info-none.txt" -- bash -c ". scripts/live/installer-lib.sh && gk3_release_info /media/gk3/gaokun3/payload"
echo "#  release_info-none.txt：U 盘里没有镜像（界面测试用 overrides 选它）" >> "$C/index.txt"
# 录：网络安装的下载（本地起一个支持 Range 的服务器，内容就是上面那份发布目录）
cat > "$W/srv.py" <<'SRVEOF'
import http.server, os, sys
root = sys.argv[1]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(s, *a, **k): super().__init__(*a, directory=root, **k)
    def log_message(s, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", 18090), H).serve_forever()
SRVEOF
python3 "$W/srv.py" "$W" & SRVPID=$!; sleep 1
python3 scripts/live/record-fixture.py "$C/net_release.txt" --sub "http://127.0.0.1:18090/rel=https://ota.072172.xyz/install/crDroidAndroid-16.0-20260916-gaokun3-v12.11" --sub "$W/dl=/run/gaokun3/payload" \
    -- bash -c ". scripts/live/installer-lib.sh && gk3_net_release http://127.0.0.1:18090/rel/ $W/dl"
kill $SRVPID 2>/dev/null
printf '%-78s %s\n' "gk3_net_release *" "net_release.txt   # 录（本地服务器，内容是上面那份发布目录）" >> "$C/index.txt"
# 手写：变体清单（ota.072172.xyz/installer/variants.txt 还不存在 —— 要等发版流程生成它）
# 格式见 installer-lib.sh 的 gk3_net_manifest：base= 指向 R2 上现成的 install/<VER>/ 目录
cat > "$C/net_manifest.txt" <<'EOF'
O VARIANT id=stock name=标准版 desc=不带%20Google%20服务，不带%20root。最接近%20AOSP。 base=https://ota.072172.xyz/install/crDroidAndroid-16.0-20260916-gaokun3-v12.11/ size_mib=1245
O VARIANT id=gapps name=带%20Google%20服务 desc=预装%20GApps。首次开机要登录%20Google%20账号并按%20docs/INSTALL.md%20做一次认证。 base=https://ota.072172.xyz/install/example-gapps/ size_mib=1611
O VARIANT id=ksu name=带%20root（KernelSU） desc=内核内置%20KernelSU。适合要调试或改系统的人。 base=https://ota.072172.xyz/install/example-ksu/ size_mib=1252
X 0
EOF
printf '%-78s %s\n' "gk3_net_manifest" "net_manifest.txt   # 手写（清单 URL 还不存在）" >> "$C/index.txt"

echo; echo "fixture 写到 $OUT/："
find "$OUT" -name '*.txt' | sort | sed 's/^/  /'

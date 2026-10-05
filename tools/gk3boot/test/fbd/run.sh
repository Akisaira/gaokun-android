#!/usr/bin/env bash
# gk3-fastbootd 离线端到端测试（S7a）—— 在 fbd-gk3-fastbootd-test 容器里跑（--privileged：要 loop 盘和 vfat 挂载）。
# 由 scripts/gk3boot/test-fastbootd.sh 调；也可以在容器里手动：bash tools/gk3boot/test/fbd/run.sh [组名…]
#
# 被测的是发布形态的静态二进制（make fastbootd-static），主机端是 Debian 包里的真 fastboot（android-platform-tools 34）；
# 主机端做不出来的畸形输入（坏 sparse、logical 名字、reboot-fastboot 原始命令）用 fbd_fixture.py client 直接发协议包。
# 盘：loop 设备（losetup -P）挂着 fbd_fixture.py 造的整盘镜像 —— 出厂布局、双系统布局、重名坏盘、缺分区坏盘、两块好盘、克隆盘。
# 每组结束都对整盘做分区级 sha256（含 GPT 区和分区间空隙），断言白名单之外一个字节都没变。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
GK3=$(cd "$HERE/../.." && pwd)
FX="python3 $HERE/fbd_fixture.py"
W=${FBD_WORK:-/tmp/fbd}
# FBD_ASAN=1：被测的换成 ASan + UBSan 的主机版（同一份源码，-O1 -g），抓内存错误；缺省测发布形态的静态版
# （守护进程是被 SIGTERM 结束的常驻进程，泄漏检查没有意义 ⇒ detect_leaks=0）
export ASAN_OPTIONS=detect_leaks=0
if [ "${FBD_ASAN:-0}" = 1 ]; then BIN=$W/build/gk3-fastbootd; BIN_TARGET=fastbootd; else BIN=$W/build/gk3-fastbootd.static; BIN_TARGET=fastbootd-static; fi
PORT=5554
F="fastboot -s tcp:127.0.0.1:$PORT"
MAXDL=0x1000000         # 16 MiB：让 40 MiB 的 super 被主机切成多片 sparse
PASS=0
FAILN=0
FAILED=()
LOOPS=()
DPID=

rm -rf "$W"
mkdir -p "$W/build" "$W/run"

ok()   { PASS=$((PASS + 1)); echo "  ✓ $*"; }
bad()  { FAILN=$((FAILN + 1)); FAILED+=("$CUR: $*"); echo "  ✗ $*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
group() { CUR=$1; echo; echo "■ $1"; }

cleanup() {
    stop_daemon
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done
}
trap cleanup EXIT

# attach <镜像> <变量名>：挂成 loop 盘（带分区扫描），设备名放进那个变量。
# ★ 不能写成 L=$(attach …)：命令替换是子 shell，LOOPS+= 会丢，trap 就拆不掉 loop（第一版就这么漏过 8 个）。
# ★ 容器的 /dev 是启动时拷的静态快照：新分配的 /dev/loopN 节点可能不存在（losetup 报 "device node … is lost"），
#   先按 7:N 补一个。分区节点不用管：守护进程自己从 /sys 查 maj:min、在 rundir 里 mknod（fb_disk_part_node）。
attach() {
    local l n try
    for try in 1 2 3 4 5; do     # 与别的会话抢同一个空闲 loop 时重试
        l=$(losetup -f 2>/dev/null | tail -1)
        [ -n "$l" ] || { echo "losetup -f 失败" >&2; exit 2; }
        n=${l#/dev/loop}
        [ -b "$l" ] || mknod "$l" b 7 "$n" || { echo "mknod $l 失败" >&2; exit 2; }
        if losetup -P "$l" "$1" 2>/dev/null; then
            LOOPS+=("$l")
            printf -v "$2" '%s' "$l"
            return 0
        fi
        sleep 0.2
    done
    echo "losetup $1 失败" >&2
    exit 2
}

# start_daemon <cmdline> <参数…>：后台起守护进程，等它 ready
start_daemon() {
    local cl=$1; shift
    stop_daemon
    echo "$cl" > "$W/cmdline"
    : > "$W/reboot.txt"
    "$BIN" --no-usb --tcp="$PORT" --cmdline="$W/cmdline" --rundir="$W/run" --test-reboot="$W/reboot.txt" \
        --max-download="$MAXDL" --log="$W/daemon.log" "$@" 2>>"$W/daemon.stderr" &
    DPID=$!
    for _ in $(seq 1 100); do
        grep -q ' ready$' "$W/daemon.log" 2>/dev/null && return 0
        kill -0 "$DPID" 2>/dev/null || { echo "守护进程退出了"; tail -20 "$W/daemon.log"; return 1; }
        sleep 0.05
    done
    echo "守护进程 5 秒内没有 ready"
    return 1
}
stop_daemon() {
    if [ -n "$DPID" ]; then
        kill "$DPID" 2>/dev/null
        wait "$DPID" 2>/dev/null
        DPID=
    fi
    cat "$W/daemon.log" >> "$W/daemon-all.log" 2>/dev/null
    : > "$W/daemon.log"
}

fb()  { $F "$@" > "$W/out" 2>&1; local r=$?; cat "$W/out" >> "$W/fastboot.log"; return $r; }
fbc() { $FX client --port "$PORT" "$@" > "$W/out" 2>&1; cat "$W/out" >> "$W/fastboot.log"; }
out_has() { grep -qF -- "$1" "$W/out"; }
getv()  { $F getvar "$1" 2>&1 | sed -n "s/^$1: //p" | head -1; }

sums()  { $FX sums "$1" "$2" > "$3"; }
same_except() {  # same_except <前> <后> <允许变的键的正则>
    python3 - "$1" "$2" "$3" <<'EOF'
import json, re, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
allow = re.compile(sys.argv[3]) if sys.argv[3] else None
bad = [k for k in a if a[k] != b.get(k) and not (allow and allow.search(k))]
if bad:
    print("changed:", bad)
    sys.exit(1)
EOF
}
part_off() { python3 -c "import json,sys;m=json.load(open('$1'));p=[p for p in m['parts'] if p['name']=='$2'][0];print(p['first']*512)"; }
part_uuid() { python3 -c "import json,sys;m=json.load(open('$1'));p=[p for p in m['parts'] if p['name']=='$2'][0];print(p['partuuid'])"; }
esp_get() {  # esp_get <盘> <manifest> <ESP 名> <ESP 内路径> <输出>
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$1@@$(part_off "$2" "$3")" "::/$4" "$5" 2>/dev/null
}

echo "▶ 编译：gk3-fastbootd（$BIN_TARGET，gcc）+ 主机单测"
make -s -C "$GK3" B="$W/build" CC=gcc FBD_VER="${FBD_VER:-test}" "$BIN_TARGET" fbd-unit > "$W/build.log" 2>&1 \
    || { cat "$W/build.log"; echo "✗ 编译 / 单测失败"; exit 1; }
grep 'test_fbd' "$W/build.log"
echo "  二进制 $(stat -c%s "$BIN") 字节；$(file -b "$BIN" | cut -d, -f1-2,4)"

echo "▶ 夹具"
$FX mkdisk --layout factory --out "$W/a.img" --stage "$W/a" --seed 11 >/dev/null
$FX mkdisk --layout dual    --out "$W/d.img" --stage "$W/d" --seed 12 >/dev/null
$FX mkdisk --layout dup     --out "$W/x.img" --stage "$W/x" --seed 13 >/dev/null
$FX mkdisk --layout missing --out "$W/m.img" --stage "$W/m" --seed 14 >/dev/null
$FX mkdisk --layout factory --out "$W/b1.img" --stage "$W/b1" --seed 21 >/dev/null
$FX mkdisk --layout factory --out "$W/b2.img" --stage "$W/b2" --seed 22 >/dev/null
$FX mkdisk --layout factory --out "$W/c1.img" --stage "$W/c1" --seed 31 >/dev/null
$FX mkdisk --layout factory --out "$W/c2.img" --stage "$W/c2" --seed 31 >/dev/null   # 克隆：PARTUUID 全同
$FX mkboot --tag new-a --out "$W/boot-new-a.img"
$FX mkboot --tag new-b --out "$W/boot-new-b.img"
$FX mksuper --out "$W/super-a.raw" --size $((40 << 20)) --slots a
$FX mksuper --out "$W/super-ab.raw" --size $((40 << 20)) --slots ab --seed 8
img2simg "$W/super-a.raw" "$W/super-a.simg" >/dev/null
img2simg "$W/super-ab.raw" "$W/super-ab.simg" >/dev/null
SUPER_SZ=$((48 << 20))
for k in ok oob chunkpast rawshort trailing sum; do
    $FX sparse --kind $k --part-size "$SUPER_SZ" --out "$W/sp-$k.simg"
done
$FX sparse --kind ok --part-size $((4 << 20)) --out "$W/sp-ok-meta.simg"
head -c $((5 << 20)) /dev/urandom > "$W/raw-5m.img"
head -c $((1 << 20)) /dev/urandom > "$W/junk-boot.img"
attach "$W/a.img" LA; attach "$W/d.img" LD; attach "$W/x.img" LX; attach "$W/m.img" LM
attach "$W/b1.img" LB1; attach "$W/b2.img" LB2; attach "$W/c1.img" LC1; attach "$W/c2.img" LC2
echo "  loop：factory=$LA dual=$LD dup=$LX missing=$LM 两块好盘=$LB1,$LB2 克隆=$LC1,$LC2"
MA=$W/a/manifest.json
MISC_A=$(part_uuid "$MA" misc)
CL_A="console=tty0 gk3.mode=fastboot gk3.why=bootloader gk3.slot=a gk3.bootver=gk3boot-test gk3.disk=$MISC_A"

# ======================================================================== 传输开关
group "TCP 默认关（发布形态）"
echo "console=tty0" > "$W/cl-notcp"
"$BIN" --no-usb --cmdline="$W/cl-notcp" --rundir="$W/run" --disks="$LA" > "$W/notcp.log" 2>&1
rc=$?
check "没有 --tcp、cmdline 没有 gk3.fbtcp=1 ⇒ 不监听，退出码 1（得到 $rc）" test $rc = 1
check "日志说明没有可用传输" grep -q 'no transport could be started' "$W/notcp.log"
echo "console=tty0 gk3.fbtcp=1 gk3.disk=$MISC_A" > "$W/cl-tcp"
"$BIN" --no-usb --cmdline="$W/cl-tcp" --rundir="$W/run" --disks="$LA" --test-reboot="$W/reboot.txt" > "$W/tcp-on.log" 2>&1 &
p=$!
sleep 0.5
check "cmdline gk3.fbtcp=1 ⇒ 5554 在监听，getvar product 通" sh -c "$F getvar product 2>&1 | grep -q 'product: gaokun3'"
kill $p; wait $p 2>/dev/null

# ======================================================================== getvar
group "getvar（出厂布局，cmdline 指定 gk3.disk）"
start_daemon "$CL_A" --disks="$LA,$LB1" || exit 1
sums "$W/a.img" "$MA" "$W/s0.json"
fb getvar all
for kv in version:0.4 version-bootloader:gk3boot-test product:gaokun3 serialno:gaokun3 secure:no unlocked:yes \
          is-userspace:yes max-download-size:0x1000000 slot-count:2 current-slot:a has-slot:boot:yes has-slot:super:no \
          slot-successful:a:yes slot-successful:b:no slot-unbootable:a:no slot-unbootable:b:yes slot-retry-count:a:1 \
          slot-retry-count:b:0 partition-size:super:0x3000000 partition-size:boot_a:0x800000 partition-type:userdata:raw \
          partition-type:metadata:raw is-logical:super:no super-partition-name:super snapshot-update-status:none \
          gk3-why:bootloader gk3-disk-ok:yes "gk3-esp-default:*-android-a.conf"; do
    check "getvar all 含 $kv" out_has "(bootloader) $kv"
done
check "getvar all 的 gk3-disk 是 $LA" grep -qE "^\(bootloader\) gk3-disk:.*/$(basename "$LA")\$" "$W/out"
check "getvar all 里没有 esp / misc / ubunturescue" sh -c "! grep -qE ':(esp|misc|ubunturescue)[:]' '$W/out'"
fb getvar nosuchvar; check "未知变量 → FAIL Unknown variable" out_has "Unknown variable"
fb getvar partition-size:esp; check "partition-size:esp → FAIL（协议里不存在）" out_has "Could not find partition"
fb getvar partition-size:misc; check "partition-size:misc → FAIL" out_has "Could not find partition"
check "getvar current-slot = a" test "$(getv current-slot)" = a
check "battery-* 读不到就 FAIL（容器里没有电池），不影响别的" sh -c "! $F getvar battery-soc-ok 2>&1 | grep -q '^battery-soc-ok: '"

# ======================================================================== flash boot
group "flash boot_a（raw）+ ESP 同步"
fb flash boot "$W/boot-new-a.img"
check "fastboot flash boot（主机补成 boot_a）OKAY" out_has "Finished"
check "主机看到 INFO：盘 / 分区号 / PARTUUID / LBA" out_has "writing boot_a on"
$FX part "$W/a.img" "$MA" boot_a "$W/p-boot_a"
check "boot_a 开头 = boot.img（cmp）" cmp -n "$(stat -c%s "$W/boot-new-a.img")" "$W/boot-new-a.img" "$W/p-boot_a"
$FX extract "$W/boot-new-a.img" "$W/ex-a"
MID=$(python3 -c "import json;print(json.load(open('$MA'))['mid'])")
for f in Image ramdisk.img gaokun3.dtb cmdline.txt; do
    esp_get "$W/a.img" "$MA" esp "$MID/android/slot_a/$f" "$W/esp-$f"
    check "ESP slot_a/$f = 从新 boot.img 解出的那段（cmp）" cmp "$W/ex-a/$f" "$W/esp-$f"
done
esp_get "$W/a.img" "$MA" esp "loader/entries/$MID-android-a.conf" "$W/ent-a"
want="options    $(tr -d '\n' < "$W/ex-a/cmdline.txt") androidboot.slot_suffix=_a"
check "直连条目 options = boot.img cmdline + slot_suffix（与 postinstall 同）" grep -qxF "$want" "$W/ent-a"
check "直连条目其余行不动（linux 行还在）" grep -q "^linux      /$MID/android/slot_a/Image" "$W/ent-a"
esp_get "$W/a.img" "$MA" esp "$MID/android/slot_b/Image" "$W/esp-b-Image"
$FX extract "$W/a/old-boot_b.img" "$W/ex-oldb"
check "ESP slot_b 没动" cmp "$W/ex-oldb/Image" "$W/esp-b-Image"
check "ESP 上没有留下 .new 临时文件" sh -c "! MTOOLS_SKIP_CHECK=1 mdir -/ -i '$W/a.img@@$(part_off "$MA" esp)' ::/ 2>/dev/null | grep -q '\.new'"
sums "$W/a.img" "$MA" "$W/s1.json"
check "只有 boot_a 与 ESP 变了" same_except "$W/s0.json" "$W/s1.json" '^p(5:boot_a|1:esp)$'
fb flash boot_b "$W/junk-boot.img"
check "boot_b 刷垃圾 → FAIL（不是 v2 boot.img / id 不对），一个字节没写" out_has "not a usable boot image"
img2simg "$W/boot-new-b.img" "$W/boot-new-b.simg" >/dev/null
fbc --download "$W/boot-new-b.simg" flash:boot_b
check "boot_b 刷 sparse → FAIL（boot 只收 raw）" out_has "must be flashed raw"
sums "$W/a.img" "$MA" "$W/s2.json"
check "两次拒绝之后整盘不变" same_except "$W/s1.json" "$W/s2.json" ''

# ======================================================================== flash super
group "flash super（sparse，主机按 16 MiB 切片）"
fb flash super "$W/super-a.simg"
check "主机把 sparse 切成多片发送" grep -qE "Sending sparse 'super' 1/[2-9]" "$W/out"
check "全部片 OKAY、Finished" out_has "Finished"
check "刷完解析出 LP 元数据：服务槽 a" out_has "serves slot(s): a"
$FX part "$W/a.img" "$MA" super "$W/p-super"
check "super 前 40 MiB = simg2img 前的原镜像（cmp）" cmp -n $((40 << 20)) "$W/super-a.raw" "$W/p-super"
tail -c $((8 << 20)) "$W/p-super" > "$W/p-super-tail"
python3 -c "
import sys;d=open('$W/p-super-tail','rb').read()
sys.exit(0 if d[:len(b'super-p7:')]==b'super-p7:' else 1)"
check "super 后 8 MiB（镜像没覆盖的部分）保持原图案" test $? = 0
sums "$W/a.img" "$MA" "$W/s3.json"
check "只有 super 变了" same_except "$W/s2.json" "$W/s3.json" '^p7:super$'

group "sparse 语义与越界拒绝（原始协议包，不经主机重排）"
$FX part "$W/a.img" "$MA" metadata "$W/meta-before"
$FX sparse-expect --base "$W/meta-before" --out "$W/meta-expect"
fbc --download "$W/sp-ok-meta.simg" flash:metadata
check "手造 sparse（raw / fill / dont-care / crc）OKAY" out_has "OKAY"
$FX part "$W/a.img" "$MA" metadata "$W/meta-after"
check "展开结果对：fill 是图案、DONT_CARE 区保持旧内容（不写零）" cmp "$W/meta-expect" "$W/meta-after"
sums "$W/a.img" "$MA" "$W/s4.json"
for k in oob chunkpast rawshort trailing sum; do
    fbc --download "$W/sp-$k.simg" flash:super
    check "sparse $k → FAIL" grep -q '^FAIL' "$W/out"
    check "sparse $k 的 FAIL 写明 nothing written" grep -q 'nothing written' "$W/out"
done
fb flash metadata "$W/raw-5m.img"
check "raw 5 MiB > metadata 4 MiB → FAIL" out_has "only 4194304"
sums "$W/a.img" "$MA" "$W/s5.json"
check "所有拒绝之后整盘一字节不变" same_except "$W/s4.json" "$W/s5.json" ''

# ======================================================================== 白名单
group "白名单：协议里不存在的分区"
for p in esp misc ubunturescue gk3rescue "$(basename "$LA")" loop0 nvme0n1 "../misc" "/dev/$(basename "$LA")" system system_a vendor_a cache; do
    fb flash "$p" "$W/raw-5m.img"
    check "flash '$p' → FAIL" grep -q 'FAILED' "$W/out"
done
fbc --download "$W/raw-5m.img" flash:system
check "flash system → 说明 1.0 只支持整块 super" out_has "only supports flashing the whole super"
for p in boot_a boot_b super esp misc; do
    fb erase "$p"
    check "erase '$p' → FAIL（只许 userdata / metadata）" grep -q 'FAILED' "$W/out"
done
sums "$W/a.img" "$MA" "$W/s6.json"
check "全部拒绝之后整盘一字节不变" same_except "$W/s5.json" "$W/s6.json" ''

# ======================================================================== erase / -w
group "erase 与 -w（§4.6.1）"
python3 - "$W/a.img" "$MA" <<'EOF'
import json, sys
disk, man = sys.argv[1], json.load(open(sys.argv[2]))
with open(disk, "r+b") as f:
    for p in man["parts"]:
        if p["name"] in ("userdata", "metadata"):
            n = (p["last"] - p["first"] + 1) * 512
            f.seek(p["first"] * 512); f.write(b"\x5a" * n)
EOF
fb -w
check "-w OKAY" out_has "Finished"
check "主机端打印 Erase successful, but not automatically formatting（报 raw）" out_has "not automatically formatting"
check "设备端 INFO：下次开机由 Android 格式化" out_has "Will be formatted by Android on next boot"
check "cache 不存在 ⇒ 主机跳过" out_has "wipe task partition not found: cache"
$FX part "$W/a.img" "$MA" userdata "$W/ud"
$FX part "$W/a.img" "$MA" metadata "$W/md"
python3 - "$W/ud" "$W/md" <<'EOF'
import sys
ud, md = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
M = 1 << 20
ok = ud[:4096] == bytes(4096) and ud[:M] == bytes(M) and ud[-M:] == bytes(M)
ok = ok and md == bytes(len(md))
sys.exit(0 if ok else 1)
EOF
check "userdata 开头 / 末尾 1 MiB 全零（开头 4 KiB 全零）、metadata 整块全零" test $? = 0
sums "$W/a.img" "$MA" "$W/s7.json"
check "-w 只动了 userdata / metadata" same_except "$W/s6.json" "$W/s7.json" '^p(2:userdata|8:metadata)$'

# ======================================================================== set_active
group "set_active（libgk3core BCAB 原语 + 守卫）"
$FX misc-dump "$W/a.img" "$MA" > "$W/md0"; BC0=$(sed -n 's/^bcab=//p' "$W/md0")
fb set_active b
check "super 的 LP 只服务 a ⇒ 拒绝" out_has "no _b partitions"
fb flash super "$W/super-ab.simg"
check "新 super 服务 a b" out_has "serves slot(s): a b"
check "本会话没刷过 boot_b ⇒ 提醒 boot 与 super 可能不同版本" out_has "boot_b was not flashed in this session"
fb set_active b
check "_b 不可启动、本会话没刷 boot_b ⇒ 拒绝" out_has "marked unbootable"
fb flash boot_b "$W/boot-new-b.img"
check "flash boot_b OKAY" out_has "Finished"
$FX misc-dump "$W/a.img" "$MA" > "$W/md1"; BC1=$(sed -n 's/^bcab=//p' "$W/md1")
check "flash super 不碰 BCAB（active 仍是 a，已被服务）" test "$BC0" = "$BC1"
fb set_active b
check "set_active b OKAY" out_has "Finished"
$FX misc-dump "$W/a.img" "$MA" > "$W/md2"; BC2=$(sed -n 's/^bcab=//p' "$W/md2")
EXP=$($FX bcab-set-active "$BC1" 1 0)
check "BCAB 字节 = libboot_control SetActiveBootSlot(1, current=0) 的独立 Python 实现（$EXP）" test "$BC2" = "$EXP"
esp_get "$W/a.img" "$MA" esp loader/loader.conf "$W/lc"
check "loader.conf default → *-android-b.conf，其余行不动" sh -c "grep -qx 'default \*-android-b.conf' '$W/lc' && grep -qx 'timeout 15' '$W/lc' && [ \$(grep -c '^default' '$W/lc') = 1 ]"
check "current-slot 跟着变成 b（同上游 fastbootd）" test "$(getv current-slot)" = b
fb set_active a
$FX misc-dump "$W/a.img" "$MA" > "$W/md3"; BC3=$(sed -n 's/^bcab=//p' "$W/md3")
EXP=$($FX bcab-set-active "$BC2" 0 1)
check "set_active a：BCAB = SetActiveBootSlot(0, current=1)（$EXP）" test "$BC3" = "$EXP"
fb set_active c; check "主机端自己先拒 set_active c（只认 slot-count 内的槽）" out_has "Slot c does not exist"
fbc set_active:c; check "原始命令 set_active:c → FAIL Bad slot suffix" out_has "Bad slot suffix"

group "VAB 守卫（misc 32 KiB 的 virtual_ab 消息）"
$FX misc "$W/a.img" "$MA" --vab merging
check "snapshot-update-status = merging" test "$(getv snapshot-update-status)" = merging
fb set_active b; check "merging ⇒ set_active 拒绝" out_has "snapshot update is in progress"
fb erase userdata; check "merging ⇒ erase userdata 拒绝" out_has "Cannot erase userdata while a snapshot update"
fb flash metadata "$W/raw-5m.img"; check "merging ⇒ flash metadata 拒绝" out_has "while a snapshot update is in progress"
fb flash super "$W/super-ab.simg"; check "merging ⇒ flash super 拒绝" out_has "merge is in progress"
fb snapshot-update cancel; check "merging ⇒ snapshot-update cancel FAIL 并说明" out_has "cannot be cancelled"
fb snapshot-update merge; check "snapshot-update merge FAIL（不支持）" out_has "not supported"
python3 - "$W/a.img" "$MA" <<'EOF'
import json, struct, sys
disk, man = sys.argv[1], json.load(open(sys.argv[2]))
p = [p for p in man["parts"] if p["name"] == "misc"][0]
with open(disk, "r+b") as f:     # SNAPSHOTTED、source_slot = 1（我们在目标槽 a 上 ⇒ 有效状态 snapshotted）
    f.seek(p["first"] * 512 + 32768); f.write(struct.pack("<BIBB", 2, 0x56740AB0, 2, 1))
EOF
check "snapshotted（source=_b，current=_a）⇒ status snapshotted" test "$(getv snapshot-update-status)" = snapshotted
fb erase metadata; check "snapshotted ⇒ erase metadata 拒绝" out_has "Cannot erase metadata"
fb snapshot-update cancel; check "snapshotted ⇒ cancel 记下（OKAY + 说明整块刷 super 时收尾）" sh -c "grep -q 'Finished' '$W/out' && grep -q 'completed when the whole super is flashed' '$W/out'"
fb flash super "$W/super-ab.simg"
check "整块刷 super ⇒ cancel 收尾：VAB → none、metadata 清零" out_has "snapshot-update cancel finished"
check "收尾之后 status = none" test "$(getv snapshot-update-status)" = none
$FX misc "$W/a.img" "$MA" --bcab invalid
fb set_active b; check "BCAB CRC 坏 ⇒ set_active 拒绝" out_has "bootloader_control in misc is invalid"
fb getvar slot-successful:a; check "BCAB 坏 ⇒ slot-successful FAIL" out_has "unreadable"
$FX misc "$W/a.img" "$MA" --bcab b-unbootable --vab none

# ======================================================================== 重启类
group "重启类：写出与 Android init 相同的 BCB"
$FX misc "$W/a.img" "$MA" --bcb none
fb reboot bootloader
check "fastboot reboot bootloader → 意图 bootloader" test "$(tail -1 "$W/reboot.txt")" = bootloader
check "BCB = bootonce-bootloader，其余全零（sha256 与独立期望一致）" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')" = "$($FX bcb-expect bootloader)"
$FX misc "$W/a.img" "$MA" --bcb none
fb reboot recovery
check "fastboot reboot recovery → 意图 recovery" test "$(tail -1 "$W/reboot.txt")" = recovery
check "BCB = boot-recovery（init 只补 command）" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')" = "$($FX bcb-expect recovery)"
$FX misc "$W/a.img" "$MA" --bcb none
fbc reboot-fastboot
check "reboot-fastboot（原始命令）→ 意图 fastboot" test "$(tail -1 "$W/reboot.txt")" = fastboot
check "BCB = boot-recovery + recovery\\n--fastboot\\n" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')" = "$($FX bcb-expect fastboot)"
$FX misc "$W/a.img" "$MA" --bcb wipe
W0=$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')
fb reboot bootloader
check "BCB 里有待执行的 wipe ⇒ reboot bootloader 不覆盖（init 同样不覆盖）" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')" = "$W0"
fbc reboot-fastboot
check "待执行的 wipe ⇒ reboot-fastboot 也不覆盖" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')" = "$W0"
fb reboot
check "fastboot reboot → 意图 reboot，BCB 不动" sh -c "[ \"\$(tail -1 '$W/reboot.txt')\" = reboot ] && [ \"\$($FX misc-dump '$W/a.img' '$MA' | sed -n 's/^bcb_sha256=//p')\" = '$W0' ]"
n=$(wc -l < "$W/reboot.txt")
fb reboot fastboot
check "fastboot reboot fastboot：is-userspace=yes ⇒ 主机什么都不发，不重启" test "$(wc -l < "$W/reboot.txt")" = "$n"
fbc shutdown
check "shutdown → 意图 poweroff" test "$(tail -1 "$W/reboot.txt")" = poweroff

group "进入时的 BCB（gk3.why）"
$FX misc "$W/a.img" "$MA" --bcb bootloader
start_daemon "$CL_A" --disks="$LA" || exit 1
check "进入时 bootonce-bootloader 被消费并清零" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_command=//p')" = ""
check "gk3-entry 说明清掉了" sh -c "$F getvar gk3-entry 2>&1 | grep -q 'consumed and cleared'"
$FX misc "$W/a.img" "$MA" --bcb fastboot
start_daemon "$CL_A" --disks="$LA" || exit 1
check "进入时 --fastboot 被消费" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_command=//p')" = ""
$FX misc "$W/a.img" "$MA" --bcb recovery
start_daemon "$CL_A" --disks="$LA" || exit 1
check "进入时 boot-recovery（adb reboot recovery）被消费" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_command=//p')" = ""
$FX misc "$W/a.img" "$MA" --bcb wipe
W1=$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')
start_daemon "$CL_A" --disks="$LA" || exit 1
check "进入时 --wipe_data 原样留给 S7b（不清、不擦）" test "$($FX misc-dump "$W/a.img" "$MA" | sed -n 's/^bcb_sha256=//p')" = "$W1"
$FX misc "$W/a.img" "$MA" --bcb none

# ======================================================================== 其他命令
group "flashing / oem / 不支持的命令"
fb flashing get_unlock_ability; check "get_unlock_ability: 1" out_has "get_unlock_ability: 1"
fb flashing unlock; check "flashing unlock OKAY（恒解锁）" out_has "always unlocked"
fb flashing lock; check "flashing lock FAIL" out_has "not supported"
fb oem log; check "oem log 回日志（含刚才的命令）" out_has "tcp> flashing lock"
fb oem device-info
check "oem device-info：盘 / 分区 / BCAB / VAB / ESP" sh -c "grep -q 'bootloader_control _a' '$W/out' && grep -q 'virtual A/B' '$W/out' && grep -q 'loader.conf default' '$W/out'"
fb oem frobnicate; check "未知 oem → FAIL" out_has "unknown oem command"
fb boot "$W/boot-new-a.img"; check "boot → FAIL（没有 kexec）" out_has "not supported"
fb continue; check "continue → FAIL" out_has "not supported"
for c in update-super:super create-logical-partition:foo_a:4096 delete-logical-partition:system_a resize-logical-partition:system_a:0 fetch:boot_a gsi:wipe nonsense; do
    fbc "$c"
    check "原始命令 $c → FAIL" grep -q '^FAIL' "$W/out"
done
fbc download:00000000; check "download 0 字节 → FAIL" out_has "Invalid size (0)"
fbc download:01000001; check "download 超过 max-download-size → FAIL" out_has "data too large"
fbc download:zz; check "download 长度不是 8 位十六进制 → FAIL" out_has "Invalid size"
fbc flash:metadata; check "（新连接）没有 download 就 flash → FAIL" out_has "no image downloaded"

group "写前重核 GPT"
python3 - "$W/a.img" <<'EOF'
import struct, sys, zlib
f = open(sys.argv[1], "r+b")
f.seek(1024); ents = bytearray(f.read(128 * 128))
i = 2   # p3 ubunturescue 改名（不影响白名单，但 GPT 变了）
ents[i * 128 + 56:i * 128 + 56 + 8] = "rescue2\0".encode("utf-16-le")[:8]
f.seek(1024); f.write(ents)
f.seek(512); h = bytearray(f.read(92))
struct.pack_into("<I", h, 88, zlib.crc32(ents) & 0xffffffff)
struct.pack_into("<I", h, 16, 0); struct.pack_into("<I", h, 16, zlib.crc32(bytes(h)) & 0xffffffff)
f.seek(512); f.write(h)
EOF
sums "$W/a.img" "$MA" "$W/s8.json"
fb erase metadata
check "GPT 在运行中被改 ⇒ 拒绝写" out_has "GPT changed since start-up"
sums "$W/a.img" "$MA" "$W/s9.json"
check "拒绝之后整盘不变" same_except "$W/s8.json" "$W/s9.json" ''
stop_daemon

# ======================================================================== 双系统
group "双系统布局（Windows ESP、MSR、两个 Basic data partition）"
MD=$W/d/manifest.json
start_daemon "console=tty0 gk3.slot=a gk3.disk=$(part_uuid "$MD" misc)" --disks="$LD" || exit 1
sums "$W/d.img" "$MD" "$W/d0.json"
check "gk3-disk-ok = yes" test "$(getv gk3-disk-ok)" = yes
fb flash boot_a "$W/boot-new-a.img"
check "flash boot_a OKAY" out_has "Finished"
esp_get "$W/d.img" "$MD" "EFI system partition" "$MID/android/slot_a/Image" "$W/d-esp-Image"
check "ESP（PARTLABEL 'EFI system partition'）slot_a/Image 已同步" cmp "$W/ex-a/Image" "$W/d-esp-Image"
esp_get "$W/d.img" "$MD" "EFI system partition" "EFI/Microsoft/Boot/bootmgfw.efi" "$W/d-bootmgfw"
check "Windows Boot Manager 文件还在" grep -q "fake windows boot manager" "$W/d-bootmgfw"
fb flash "Basic data partition" "$W/raw-5m.img"; check "flash 'Basic data partition' → FAIL" grep -q FAILED "$W/out"
fb flash "Microsoft reserved partition" "$W/raw-5m.img"; check "flash MSR → FAIL" grep -q FAILED "$W/out"
fb -w; check "-w OKAY" out_has "Finished"
sums "$W/d.img" "$MD" "$W/d1.json"
check "Windows 的三个分区、GPT 区一字节不变（只动了 boot_a / ESP / userdata / metadata）" \
    same_except "$W/d0.json" "$W/d1.json" '^p(1:EFI system partition|6:boot_a|9:metadata|10:userdata)$'
stop_daemon

# ======================================================================== 坏盘 / 多盘
for lay in dup missing; do
    group "坏盘：$lay"
    eval "L=\$L$( [ $lay = dup ] && echo X || echo M )"
    MM=$W/$( [ $lay = dup ] && echo x || echo m )/manifest.json
    IMG=$W/$( [ $lay = dup ] && echo x || echo m ).img
    start_daemon "console=tty0 gk3.slot=a" --disks="$L" || exit 1
    sums "$IMG" "$MM" "$W/$lay-0.json"
    check "gk3-disk-ok = no" test "$(getv gk3-disk-ok)" = no
    want=$([ $lay = dup ] && echo "'boot_a' is duplicated" || echo "'metadata' is missing")
    fb getvar gk3-disk-error; check "原因写明 $want" grep -qF "$want" "$W/out"
    fb flash boot_a "$W/boot-new-a.img"; check "flash boot_a → FAIL" grep -q FAILED "$W/out"
    fb erase userdata; check "erase userdata → FAIL" grep -q FAILED "$W/out"
    fb set_active a; check "set_active → FAIL" grep -q FAILED "$W/out"
    fb -w; check "-w → 不擦（主机报错或 FAIL）" sh -c "! grep -q 'Erasing succeeded' '$W/out'"
    fb reboot bootloader; check "reboot bootloader 仍然重启（没有可信 misc，意图丢掉）" test "$(tail -1 "$W/reboot.txt")" = bootloader
    sums "$IMG" "$MM" "$W/$lay-1.json"
    check "整盘一字节不变（含 misc）" same_except "$W/$lay-0.json" "$W/$lay-1.json" ''
    stop_daemon
done

group "两块好盘：不给 gk3.disk ⇒ 拒绝；给了 ⇒ 只写那一块"
start_daemon "console=tty0 gk3.slot=a" --disks="$LB1,$LB2" || exit 1
check "两块都符合 ⇒ gk3-disk-ok = no" test "$(getv gk3-disk-ok)" = no
fb getvar gk3-disk-error; check "原因：2 disks qualify" out_has "2 disks qualify"
M1=$W/b1/manifest.json; M2=$W/b2/manifest.json
sums "$W/b1.img" "$M1" "$W/b1-0.json"; sums "$W/b2.img" "$M2" "$W/b2-0.json"
start_daemon "console=tty0 gk3.slot=a gk3.disk=$(part_uuid "$M2" misc)" --disks="$LB1,$LB2" || exit 1
check "gk3.disk 指向第二块 ⇒ 选中 $LB2" test "$(basename "$(getv gk3-disk)")" = "$(basename "$LB2")"
fb erase metadata; check "erase metadata OKAY" out_has "Finished"
sums "$W/b1.img" "$M1" "$W/b1-1.json"; sums "$W/b2.img" "$M2" "$W/b2-1.json"
check "第一块一字节不变" same_except "$W/b1-0.json" "$W/b1-1.json" ''
check "第二块只有 metadata 变了" same_except "$W/b2-0.json" "$W/b2-1.json" '^p8:metadata$'
start_daemon "console=tty0 gk3.slot=a gk3.disk=00000000-0000-0000-0000-000000000000" --disks="$LB1,$LB2" || exit 1
check "gk3.disk 对不上任何盘 ⇒ gk3-disk-ok = no" test "$(getv gk3-disk-ok)" = no

group "克隆盘：两块盘 misc PARTUUID 相同"
start_daemon "console=tty0 gk3.slot=a gk3.disk=$(part_uuid "$W/c1/manifest.json" misc)" --disks="$LC1,$LC2" || exit 1
check "gk3-disk-ok = no" test "$(getv gk3-disk-ok)" = no
fb getvar gk3-disk-error; check "原因写明 cloned disk" out_has "cloned disk"
stop_daemon

group "sanitizer 报告（只在 FBD_ASAN=1 时有意义）"
check "守护进程 stderr 里没有 AddressSanitizer / UndefinedBehaviorSanitizer / runtime error" \
    sh -c "! grep -qE 'AddressSanitizer|UndefinedBehaviorSanitizer|runtime error' '$W/daemon.stderr'"

echo
echo "════════ gk3-fastbootd 离线测试（$BIN_TARGET）：通过 $PASS，失败 $FAILN"
for f in "${FAILED[@]}"; do echo "  ✗ $f"; done
[ "$FAILN" = 0 ]

#!/usr/bin/env bash
# 给 test-setup.ps1 造【真的】GPT 盘镜像（在 gk3-test-env 容器里跑：sgdisk / mkfs.ext4 / mkntfs / mkfs.vfat 都在）。
# 用途：-RemoveAndroid 的 GPT 解析、内容识别、相邻断言要拿真工具造的分区表与文件系统来核，不拿自己手拼的字节自证。
#
#   bash test-fixtures.sh <输出目录>
#
# 每个变体写 disk-<变体>.img（稀疏，约 50 MiB）+ disk-<变体>.json（sgdisk -i 读回来的每个分区：编号 / 分区 GUID /
# 类型 GUID / 首末扇区 / 名字，加上我们给它定的角色）。扇区 512。
#   normal   出厂 + 脚本路径的布局：ESP | MSR | C: | D: | GK3LIVE | misc metadata boot_a boot_b super userdata | WINPE
#   ntfsdata 同上，但 userdata 里是 NTFS（"名字碰巧叫 userdata 的 Windows 分区" —— 必须拒绝）
#   gap      D: 后面紧跟 WINPE、GK3LIVE 与 Android 在 WINPE 后面（不相邻 —— 删可以，不扩 D:）
set -euo pipefail
OUT=${1:?输出目录}
mkdir -p "$OUT"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkpart_img() {   # $1=文件 $2=MiB $3=内容
    local f=$1 mib=$2 kind=$3
    rm -f "$f"; truncate -s "${mib}M" "$f"   # ⚠️ 先删：同一个临时文件名上一个变体用过，truncate 不清内容
    case "$kind" in
        ntfs)  mkntfs -F -Q -q "$f" >/dev/null 2>&1 ;;
        ext4)  mkfs.ext4 -q -F "$f" >/dev/null 2>&1 ;;
        fat)   mkfs.vfat "$f" >/dev/null ;;
        boot)  printf 'ANDROID!' | dd of="$f" conv=notrunc status=none ;;
        lp)    printf '\x67\x44\x6c\x61' | dd of="$f" bs=1 seek=4096 conv=notrunc status=none ;;
        zero)  : ;;
    esac
}

build() {   # $1=变体名，其余：角色:名字:MiB:类型码:内容
    local v=$1; shift
    # 先在容器自己的 /tmp 里造（宿主机挂进来的目录上小块写很慢），最后拷出去
    local img="$T/disk-$v.img"
    rm -f "$img"; truncate -s 64M "$img"
    sgdisk --zap-all "$img" >/dev/null
    local n=0 start=2048 spec role name mib code kind guid
    for spec in "$@"; do
        IFS=: read -r role name mib code kind <<<"$spec"
        n=$((n + 1))
        guid=$(printf '6b3f%04x-0000-4000-8000-%012x' "$n" "$n")
        sgdisk -n "$n:$start:+${mib}M" -t "$n:$code" -c "$n:$name" -u "$n:$guid" "$img" >/dev/null
        mkpart_img "$T/p$n" "$mib" "$kind"
        dd if="$T/p$n" of="$img" bs=1M seek=$((start / 2048)) conv=notrunc,sparse status=none   # start 都是 1 MiB 对齐
        echo "$n $role" >> "$T/roles-$v"
        start=$((start + mib * 2048))
    done
    # 读回：sgdisk -i 的说法才是"真工具看到的分区表"
    python3 - "$img" "$T/roles-$v" > "$OUT/disk-$v.json" <<'PY'
import json, re, subprocess, sys
img, roles = sys.argv[1], sys.argv[2]
out = []
for line in open(roles):
    n, role = line.split()
    info = subprocess.run(['sgdisk', '-i', n, img], capture_output=True, text=True, check=True).stdout
    g = lambda pat: re.search(pat, info).group(1)
    out.append({'number': int(n), 'role': role,
                'typeGuid': g(r'Partition GUID code: ([0-9A-F-]+)').lower(),
                'guid': g(r'Partition unique GUID: ([0-9A-F-]+)').lower(),
                'firstLba': int(g(r'First sector: (\d+)')), 'lastLba': int(g(r'Last sector: (\d+)')),
                'name': g(r"Partition name: '([^']*)'")})
print(json.dumps({'sectorSize': 512, 'partitions': out}, indent=1))
PY
    cp --sparse=always "$img" "$OUT/disk-$v.img"
    echo "  ✓ disk-$v.img（$n 个分区）"
}

BASE_HEAD=(esp:EFI\ system\ partition:4:ef00:fat msr:Microsoft\ reserved\ partition:1:0c01:zero
           C:Basic\ data\ partition:8:0700:ntfs D:Basic\ data\ partition:8:0700:ntfs)
ANDROID=(misc:misc:1:8300:zero metadata:metadata:4:8300:ext4 boot_a:boot_a:1:8300:boot boot_b:boot_b:1:8300:boot
         super:super:2:8300:lp)
build normal   "${BASE_HEAD[@]}" live:Basic\ data\ partition:4:0700:fat "${ANDROID[@]}" userdata:userdata:8:8300:ext4 winpe:Basic\ data\ partition:4:0700:ntfs
build ntfsdata "${BASE_HEAD[@]}" live:Basic\ data\ partition:4:0700:fat "${ANDROID[@]}" userdata:userdata:8:8300:ntfs winpe:Basic\ data\ partition:4:0700:ntfs
build gap      "${BASE_HEAD[@]}" winpe:Basic\ data\ partition:4:0700:ntfs live:Basic\ data\ partition:4:0700:fat "${ANDROID[@]}" userdata:userdata:8:8300:ext4

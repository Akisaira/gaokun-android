#!/usr/bin/env bash
# 执行端 initramfs 的 QEMU 离线测试（容器内；宿主上用 scripts/gk3boot/test-initramfs.sh）。
#
#   bash tools/gk3boot/initramfs/test/run-tests.sh [场景…]
#
# 1. 取通用 arm64 内核 + 它的模块（Debian linux-image-*-arm64-unsigned；缓存在 build/cache-fbi/）。
#    本机内核把 configfs / f_fs / evdev 都编进去了，Debian 的是模块 —— 测试 overlay 里带上、由 test-hook insmod。
#    dummy_hcd 同时给出一个 UDC（dummy_udc.0）和一个主机：gadget 绑上之后会被"主机"真的枚举一遍。
# 2. 编假 gk3-fastbootd（test/fake-fastbootd.c）：只实现接口（README §13），不实现协议。
# 3. 造一块 GPT 盘（misc 照实机向量）给 gk3-fbi status 读。
# 4. qemu_fbi.py 逐个场景起 QEMU：-kernel vmlinuz -initrd "fastboot.img + 测试 overlay"，
#    串口收界面输出，HMP sendkey 往 virtio-keyboard 注入音量 / 电源 / 方向键。
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FBI=$(cd "$HERE/.." && pwd)
GK3=$(cd "$FBI/.." && pwd)
B=$GK3/build
IMG=$B/fastboot/fastboot.img
CACHE=$B/cache-fbi
W=$B/fbi-test
[ -s "$IMG" ] || { echo "✗ 先打 fastboot.img（scripts/gk3boot/build-fastboot-img.sh）" >&2; exit 2; }
mkdir -p "$CACHE" "$W"

# —— 1. 测试内核 + 模块 ——
if [ ! -s "$CACHE/vmlinuz" ] || [ ! -d "$CACHE/modules" ]; then
    echo "▶ 取测试内核（Debian linux-image-arm64 当前版本）"
    if [ -n "${GK3_DEBIAN_MIRROR:-}" ]; then
        sed -i "s|http://deb.debian.org/debian|$GK3_DEBIAN_MIRROR|g" /etc/apt/sources.list.d/debian.sources
    fi
    apt-get update -qq >/dev/null
    pkg=$(apt-cache depends linux-image-arm64 | sed -n 's/^ *Depends: \(linux-image-[0-9][^ ]*\)$/\1/p' | head -n 1)
    [ -n "$pkg" ] || { echo "✗ 解析不出内核包" >&2; exit 1; }
    t=$(mktemp -d)
    (cd "$t" && apt-get download -q "${pkg}-unsigned" >/dev/null)
    deb=$(ls "$t"/*.deb)
    dpkg-deb -x "$deb" "$t/x"
    rm -rf "$CACHE/modules"
    cp "$t"/x/boot/vmlinuz-* "$CACHE/vmlinuz"
    md=
    for c in "$t"/x/usr/lib/modules/* "$t"/x/lib/modules/*; do [ -d "$c/kernel" ] && { md=$c; break; }; done
    [ -n "$md" ] || { echo "✗ $deb 里没有模块目录" >&2; exit 1; }
    # .deb 里不带 modules.dep（postinst 才跑 depmod）—— 自己生成
    kver=$(basename "$md")
    mkdir -p "$t/base/lib/modules"
    ln -s "$md" "$t/base/lib/modules/$kver"
    depmod -b "$t/base" "$kver" || { echo "✗ depmod 失败" >&2; exit 1; }
    [ -f "$md/modules.dep" ] || { echo "✗ depmod 没生成 modules.dep" >&2; exit 1; }
    mkdir -p "$CACHE/modules"
    # 只留测试要的模块及其依赖（按 modules.dep 解析、拓扑序），解压成 .ko（busybox insmod 不认 .xz）
    python3 - "$md" "$CACHE/modules" <<'EOF'
import os, subprocess, sys
md, out = sys.argv[1], sys.argv[2]
dep = {}
for line in open(os.path.join(md, "modules.dep")):
    k, _, v = line.partition(":")
    dep[k.strip()] = v.split()
byname = {os.path.basename(k).split(".ko")[0].replace("-", "_"): k for k in dep}
want = ["configfs", "libcomposite", "usb_f_fs", "dummy_hcd", "evdev", "virtio_input", "virtio_blk", "virtio_gpu"]
order, seen = [], set()
def visit(path):
    if path in seen:
        return
    seen.add(path)
    for d in dep.get(path, []):
        visit(d)
    order.append(path)
builtin = open(os.path.join(md, "modules.builtin")).read()
for w in want:
    if w in byname:
        visit(byname[w])
    elif ("/%s.ko" % w) in builtin or ("/%s.ko" % w.replace("_", "-")) in builtin:
        print("  %s：内建" % w)
    else:
        sys.exit("✗ 模块 %s 既不在 modules.dep 也不内建" % w)
with open(os.path.join(out, "order"), "w") as f:
    for p in order:
        name = os.path.basename(p)
        src = os.path.join(md, p)
        dst = os.path.join(out, name.replace(".xz", "").replace(".zst", ""))
        if name.endswith(".xz"):
            subprocess.run("xz -dc '%s' > '%s'" % (src, dst), shell=True, check=True)
        elif name.endswith(".zst"):
            sys.exit("✗ 模块是 zstd 压缩的，容器里没解压器")
        else:
            subprocess.run(["cp", src, dst], check=True)
        f.write(os.path.basename(dst) + "\n")
print("  测试模块 %d 个：%s" % (len(order), " ".join(os.path.basename(p).split(".ko")[0] for p in order)))
EOF
    echo "$(dpkg-deb -f "$deb" Package) $(dpkg-deb -f "$deb" Version)" > "$CACHE/vmlinuz.version"
    rm -rf "$t"
fi
echo "▶ 测试内核：$(cat "$CACHE/vmlinuz.version")，模块 $(wc -l < "$CACHE/modules/order") 个"

# —— 2. 假 gk3-fastbootd ——
musl-gcc -std=c11 -Os -Wall -Wextra -Werror -static -isystem /opt/kh -s \
    -o "$W/fake-fastbootd" "$HERE/fake-fastbootd.c"
echo "▶ 假 gk3-fastbootd：$(stat -c %s "$W/fake-fastbootd") 字节"

# —— 2'. 不带守护进程的一份（missing 场景：发布镜像缺省带着真 gk3-fastbootd，overlay 删不掉文件）——
bash "$FBI/build.sh" --out "$W/nofbd" --no-fastbootd > "$W/nofbd.log" 2>&1 || { cat "$W/nofbd.log"; exit 1; }
echo "▶ 只有界面的 fastboot.img：$(stat -c %s "$W/nofbd/fastboot.img") 字节"

# —— 3/4. 盘 + 场景 ——
python3 "$HERE/qemu_fbi.py" --img "$IMG" --img-nofbd "$W/nofbd/fastboot.img" --kernel "$CACHE/vmlinuz" --modules "$CACHE/modules" \
    --fake "$W/fake-fastbootd" --work "$W" "$@"

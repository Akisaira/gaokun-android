#!/usr/bin/env bash
# 取一个通用 arm64 内核给 gk3boot 的 H2 交接测试用（容器内；qemu/run-boot-tests.sh 调用）。
#
#   bash qemu/fetch-test-kernel.sh <缓存目录>
#
# 取 Debian 13 当前的 linux-image-<ver>-arm64-unsigned（vmlinuz 是带 PE 头的 EFI stub Image，PL011 串口内建），
# 解出 vmlinuz 放进缓存目录，版本与 sha256 记在旁边。缓存在就不再联网。
# 不钉版本：Debian 仓库只留当前版本，钉死了过几周就下不到；测试不依赖内核版本，只要求"通用 arm64 + EFI stub"，
# 用的是哪一版每次都打印、写进结果。宿主上想固定用某一份：GK3_TEST_KERNEL=/path/vmlinuz（见 test-boot.sh）。
set -euo pipefail
C=$1
mkdir -p "$C"
if [ -s "$C/vmlinuz" ] && [ -s "$C/vmlinuz.version" ]; then
    echo "  测试内核（缓存）：$(cat "$C/vmlinuz.version")"
    exit 0
fi
if [ -n "${GK3_DEBIAN_MIRROR:-}" ]; then
    sed -i "s|http://deb.debian.org/debian|$GK3_DEBIAN_MIRROR|g" /etc/apt/sources.list.d/debian.sources
fi
apt-get update -qq >/dev/null
pkg=$(apt-cache depends linux-image-arm64 | sed -n 's/^ *Depends: \(linux-image-[0-9][^ ]*\)$/\1/p' | head -n 1)
[ -n "$pkg" ] || { echo "✗ 解析不出 linux-image-arm64 依赖的内核包" >&2; exit 1; }
tmp=$(mktemp -d)
(cd "$tmp" && apt-get download -q "${pkg}-unsigned" >/dev/null)
deb=$(ls "$tmp"/*.deb)
dpkg-deb -x "$deb" "$tmp/x"
cp "$tmp"/x/boot/vmlinuz-* "$C/vmlinuz.new"
head -c 2 "$C/vmlinuz.new" | grep -q MZ || { echo "✗ $deb 里的 vmlinuz 不是 PE（EFI stub）" >&2; exit 1; }
mv "$C/vmlinuz.new" "$C/vmlinuz"
echo "$(dpkg-deb -f "$deb" Package) $(dpkg-deb -f "$deb" Version) sha256=$(sha256sum "$C/vmlinuz" | cut -c1-16)…" \
    > "$C/vmlinuz.version"
rm -rf "$tmp"
echo "  测试内核（新取）：$(cat "$C/vmlinuz.version")"

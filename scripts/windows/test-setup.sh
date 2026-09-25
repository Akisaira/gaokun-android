#!/usr/bin/env bash
# 测 Windows 那一侧的免 U 盘安装脚本（开发机是 macOS，本机的 Windows 已抹掉 —— 只能测到这一步）：
#   1. PowerShell 7 容器里跑 test-setup.ps1：语法 / BOM / CRLF / 没有 5.1 不认的语法 / 全部纯逻辑
#   2. 拿 live 镜像里【真的】wpa_supplicant 解析它生成的 WiFi 配置，wpa_passphrase 交叉核对 PSK
#
#   bash scripts/windows/test-setup.sh
#
# PowerShell 从哪来（按顺序）：docker 镜像 mcr.microsoft.com/powershell；否则 out/tools/ps.tar.gz
# （github.com/PowerShell/PowerShell 的 linux-arm64 压缩包，解进构建机同款 Debian 容器里跑）。
# ⚠️ 2026-09-25 换网后两条都只有几十 KB/s，拉一次要二十多分钟 —— 拉到了就留着。
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
die() { echo "✗ $*" >&2; exit 1; }
mkdir -p "$REPO/out/tools"
OUT=$(mktemp -d "$REPO/out/tools/wintest.XXXX"); trap 'rm -rf "$OUT"' EXIT

echo "══ 1. PowerShell：test-setup.ps1"
# ⚠️ 只认 arm64 的镜像：2026-09-25 拉下来的 latest 是 32 位 arm（Architecture=arm），在 colima（aarch64）里 exec format error
if [ "$(docker image inspect mcr.microsoft.com/powershell:latest --format '{{.Architecture}}' 2>/dev/null)" = arm64 ]; then
    docker run --rm -v "$REPO/scripts/windows:/w:ro" -v "$OUT:/out" mcr.microsoft.com/powershell:latest \
        pwsh -NoProfile -File /w/test-setup.ps1 -Out /out/wpa.conf || die "test-setup.ps1 有失败项"
elif [ -f "$REPO/out/tools/ps.tar.gz" ]; then
    H=$(shasum -a 256 "$REPO/scripts/live/test-env.Dockerfile" | cut -c1-12)
    docker image inspect "gk3-test-env:$H" >/dev/null 2>&1 || die "没有 gk3-test-env:$H（先跑一次 scripts/live/test-in-container.sh）"
    # 没装 ICU：用不变区域（本脚本只用到 UTF-8 与 Get-UICulture，够了）
    docker run --rm -e DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 -v "$REPO/scripts/windows:/w:ro" -v "$OUT:/out" \
        -v "$REPO/out/tools/ps.tar.gz:/ps.tar.gz:ro" "gk3-test-env:$H" \
        sh -c 'mkdir -p /opt/pwsh && tar -xzf /ps.tar.gz -C /opt/pwsh && /opt/pwsh/pwsh -NoProfile -File /w/test-setup.ps1 -Out /out/wpa.conf' \
        || die "test-setup.ps1 有失败项"
else
    die "没有 PowerShell：docker pull mcr.microsoft.com/powershell，或把 linux-arm64 压缩包放到 out/tools/ps.tar.gz"
fi
[ -s "$OUT/wpa.conf" ] || die "test-setup.ps1 没写出 WiFi 配置"

echo "══ 2. 真 wpa_supplicant 解析生成的配置"
docker image inspect gk3-bootsmoke:latest >/dev/null 2>&1 || die "没有 gk3-bootsmoke 镜像（先跑 scripts/live/test-boot-container.sh）"
docker run --rm -v "$OUT:/out:ro" gk3-bootsmoke:latest sh -c '
    set -u; bad=0
    ok() { echo "  ✓ $*"; }; no() { echo "  ✗ $*"; bad=1; }
    # PSK：PowerShell 自己实现的 PBKDF2 与 wpa_passphrase（wpa_supplicant 的实现）逐字相同
    want=$(wpa_passphrase SkipM4 12345678 | sed -n "s/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p")
    grep -q "psk=$want" /out/wpa.conf && ok "WPA2 的 PSK 与 wpa_passphrase 算的一致（$want）" || no "PSK 与 wpa_passphrase 不一致"
    # 解析：wpa_supplicant 先读配置、再初始化网卡 —— 网卡不存在无所谓，配置有错会报 Line N / Failed to read
    parse() { { printf "ctrl_interface=/tmp/wpa\nupdate_config=0\n"; cat "$1"; } > /tmp/w.conf
              wpa_supplicant -c /tmp/w.conf -i gk3test0 -D nl80211 2>&1 | grep -E "Line [0-9]+:|Failed to read or parse" || true; }
    e=$(parse /out/wpa.conf)
    [ -z "$e" ] && ok "wpa_supplicant 解析通过（$(grep -c "^network={" /out/wpa.conf) 个网络块）" || { no "wpa_supplicant 报错："; echo "$e" | sed "s/^/      /"; }
    # 反例：确认上面那条判据真的会报错（不然"没报错"说明不了什么）
    printf "network={\n    ssid=zz\n    key_mgmt=NONE\n}\n" > /tmp/bad.conf
    [ -n "$(parse /tmp/bad.conf)" ] && ok "反例（ssid 不是合法的十六进制）确实被 wpa_supplicant 拒绝" || no "反例没被拒 —— 这个判据不可信"
    exit $bad' || die "wpa_supplicant 核对没过"
echo "══ 全部通过"

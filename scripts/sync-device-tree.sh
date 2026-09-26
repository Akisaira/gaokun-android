#!/usr/bin/env bash
# 把本仓的 device/huawei/gaokun3/ 同步到构建机的 crdroid 树，并断言构建机上
# 【不在版本库里、但构建必需】的输入仍然在。
#
#   bash scripts/sync-device-tree.sh <构建机 IP 或主机>
#
# ★ 这个脚本存在的理由（2026-09-16，B0 第 6 咬，#116 §15）：
#   `rsync -a --delete device/huawei/gaokun3/ vm:~/crdroid/device/huawei/gaokun3/`
#   看起来是"让构建机的树就是本仓 checkout"的正确做法 —— 而它把构建机上
#   **四样被 .gitignore 挡在公开仓之外、却是构建必需**的东西全删了：
#       adb_keys                 开发机 adb 公钥（个人密钥）          → soong panic，构建 42 秒就死
#       firmware/**              华为专有 .mbn + linux-firmware 那 18 个 → 显式 COPY_FILES，构建会报错
#       hexagonrpcd-root/**      SLPI 传感器 VFS 根（34 个）           → 一半是 wildcard，缺了【静默消失】
#       prebuilt-boot/**         内核与 DTB                             → 本机会产出，可同步
#   更糟的是事后那道"127 个文件逐字节一致"的 md5 核对**通过了** —— 因为两边一样地缺，
#   我拿了一个不完整的本机树当参照。**参照物必须是"构建需要什么"，不是"本机有什么"。**
#   恢复靠的是设备上 /vendor 里实际装进去的那一套（README 里写着的路）+ 上次构建的 out/。
#
# ★ 2026-09-26 第五样：effects/prebuilt/**（扬声器增强试验功能的 Histen 引擎，华为专有，PR #7）。
#   device.mk 对它用 wildcard —— 缺了构建【照样通过】，ROM 里只是悄悄没了 Histen，
#   正是上面那种"静默消失"。所以同样排除在 --delete 之外、单独同步、按 sha256 断言。
#   确实不想带它构建时（例如别人的构建机）：GK3_ALLOW_NO_HISTEN=1。
set -euo pipefail
HOST=${1:?用法: $0 <构建机 IP>}
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=$REPO/device/huawei/gaokun3
# ⚠️ 不能写 …:~/crdroid：bash 对赋值里 ":" 后面的 "~" 做波浪号展开（PATH 风格），
#   远端会拿到【本机】的 home 路径。用相对远端 home 的路径。
DST=vahiru@$HOST:crdroid/device/huawei/gaokun3
die() { echo "✗ $*" >&2; exit 1; }
ok()  { echo "✓ $*"; }

echo "═══ 0. 同步之前：设备树里每个 .xml 都必须能解析 ═══"
# ★ 2026-09-24：PR #6 的 features xml 少了一个注释结尾，整包构建到 systemfeatures-gen-tool
#   才报错（构建开始后约 2 分钟，而且只有整包构建会碰它 —— 单编 HAL 发现不了）。
#   在这里 1 秒内拦下；坏的 XML 同步过去只会浪费一次构建。
python3 - "$SRC" <<'PY' || die "设备树里有解析不了的 XML（见上），先修再同步"
import sys, pathlib, xml.etree.ElementTree as ET
bad = 0
for p in sorted(pathlib.Path(sys.argv[1]).rglob("*.xml")):
    if any(part in ("firmware", "hexagonrpcd-root", "prebuilt-boot") for part in p.parts):
        continue
    try:
        ET.parse(p)
    except ET.ParseError as e:
        print("  ✗ %s: %s" % (p.relative_to(sys.argv[1]), e))
        bad += 1
sys.exit(1 if bad else 0)
PY
ok "设备树 XML 全部可解析"

echo "═══ 1. 同步受版本控制的部分（--delete 但排除四样不入库的构建输入）═══"
# ★ 三个目录里的 README.md 受版本控制（第 4 步要逐字节对照），必须先 --include 放行 ——
#   rsync 取第一条匹配的规则。2026-09-26 踩到：firmware/README.md 09-24 改过，而
#   'firmware/**' 把它也挡住了，第 4 步于是永远报差异、同步本身又永远修不好它。
rsync -a --delete \
      --exclude '._*' --exclude '.DS_Store' \
      --include 'firmware/README.md' --include 'hexagonrpcd-root/README.md' --include 'prebuilt-boot/README.md' \
      --exclude 'adb_keys' --exclude 'firmware/**' --exclude 'hexagonrpcd-root/**' --exclude 'prebuilt-boot/**' \
      --exclude 'effects/prebuilt/**' \
      -e "$SSH" "$SRC/" "$DST/"
ok "device/ 已同步（不动 adb_keys / firmware / hexagonrpcd-root / prebuilt-boot / effects/prebuilt）"

echo "═══ 2. prebuilt-boot 单独同步，【不带 --delete】═══"
if [ -f "$SRC/prebuilt-boot/vmlinuz.efi" ]; then
    rsync -a --exclude '._*' --exclude '.DS_Store' -e "$SSH" "$SRC/prebuilt-boot/" "$DST/prebuilt-boot/"
    ok "prebuilt-boot 已同步（$(shasum -a 256 "$SRC/prebuilt-boot/vmlinuz.efi" | cut -c1-16)）"
else
    echo "· 本机没有 prebuilt-boot/vmlinuz.efi，保留构建机上的那份"
fi

echo "═══ 2b. effects/prebuilt（Histen 引擎）单独同步，【不带 --delete】═══"
# README.md 也在这个目录里、且受版本控制 —— 第 1 步把整个目录排除了，所以它也靠这一步过去。
rsync -a --exclude '._*' --exclude '.DS_Store' -e "$SSH" "$SRC/effects/prebuilt/" "$DST/effects/prebuilt/"
if [ -f "$SRC/effects/prebuilt/lib64/soundfx/libhw_histen_processing.so" ]; then
    ok "effects/prebuilt 已同步（含 Histen 引擎）"
else
    echo "· 本机没有 Histen 引擎，保留构建机上的那份（若有）"
fi

echo "═══ 3. 断言：构建机上四样不入库的输入都在 ═══"
$SSH "vahiru@$HOST" 'cd ~/crdroid/device/huawei/gaokun3
  fw=$(find firmware -type f ! -name README.md 2>/dev/null | wc -l)
  hx=$(find hexagonrpcd-root -type f ! -name README.md 2>/dev/null | wc -l)
  ak=$(wc -c < adb_keys 2>/dev/null || echo 0)
  dtb=$(ls prebuilt-boot/dtb/*.dtb 2>/dev/null | wc -l)
  echo "firmware=$fw hexagonrpcd=$hx adb_keys=${ak}B dtb=$dtb"
  [ "$fw" -eq 18 ] && [ "$hx" -eq 34 ] && [ "$ak" -gt 500 ] && [ "$dtb" -eq 1 ] && [ -f prebuilt-boot/vmlinuz.efi ]' \
  | tee /dev/stderr | tail -1 >/dev/null || die "构建机上缺构建必需的输入 —— 见上一行；恢复方法在 firmware/README.md 与 hexagonrpcd-root/README.md"
ok "18 个固件 · 34 个 hexagonrpcd 文件 · adb_keys · 1 个 dtb · vmlinuz.efi 都在"

echo "═══ 3b. 断言：Histen 引擎在、且是核对过的那一份 ═══"
# 期望值与来源见 effects/prebuilt/README.md。
HISTEN_SHA=338b774e70feeccd7718f9d2f25c5bfddf8254ddd2623fa25a778ffcaaf38a2e
got=$($SSH "vahiru@$HOST" 'sha256sum ~/crdroid/device/huawei/gaokun3/effects/prebuilt/lib64/soundfx/libhw_histen_processing.so 2>/dev/null | cut -d" " -f1' || true)
if [ "$got" = "$HISTEN_SHA" ]; then
    ok "Histen 引擎在（${HISTEN_SHA:0:16}）"
elif [ "${GK3_ALLOW_NO_HISTEN:-0}" = 1 ]; then
    echo "· Histen 引擎不在或不符（${got:-缺失}），GK3_ALLOW_NO_HISTEN=1 ⇒ 这一版的扬声器增强只有扬声器链"
else
    if [ -n "$got" ]; then why="sha256 不符（$got）"; else why="缺失"; fi
    die "构建机上的 Histen 引擎$why —— 见 effects/prebuilt/README.md；确实不要它就设 GK3_ALLOW_NO_HISTEN=1"
fi

echo "═══ 4. 受版本控制的文件逐一 md5 ═══"
L=$(mktemp); R=$(mktemp)
(cd "$SRC" && git ls-files -z . | xargs -0 md5 -r 2>/dev/null | awk '{print $1"  "$2}' | sort) > "$L"
(cd "$SRC" && git ls-files . ) | $SSH "vahiru@$HOST" 'cd ~/crdroid/device/huawei/gaokun3 && xargs md5sum 2>/dev/null | sort' > "$R"
if diff -q "$L" "$R" >/dev/null; then ok "$(wc -l < "$L" | tr -d ' ') 个受版本控制的文件逐字节一致"
else echo "✗ 有差异："; diff "$L" "$R" | head -10; rm -f "$L" "$R"; die "构建机的树 ≠ 本仓"; fi
rm -f "$L" "$R"

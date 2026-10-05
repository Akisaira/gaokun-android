#!/usr/bin/env bash
# gk3-wpa-scan.py 的自测。纯 Python，任何机器都能跑。
#
#   bash scripts/live/test-wpa-scan.sh
#
# 输入是按 wpa_supplicant 的 printf_encode（wpa-2.10 src/utils/common.c:477-523）
# 从【原始字节】编码出来的，所以判据就是：解析出的 ssid_hex == 原始字节。
set -u
cd "$(dirname "$0")/../.."
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

OUT=$(python3 - <<'PYEOF' | python3 scripts/live/gk3-wpa-scan.py
def printf_encode(b):                      # common.c:477-523 的逐条翻译
    m = {0x22: '\\"', 0x5C: '\\\\', 0x1B: '\\e', 0x0A: '\\n', 0x0D: '\\r', 0x09: '\\t'}
    return "".join(m[x] if x in m else chr(x) if 32 <= x <= 126 else "\\x%02x" % x for x in b)
rows = [  # bssid, freq, signal, flags, 原始 SSID 字节
    ("aa:00:00:00:00:01", 5180, -40, "[WPA2-PSK-CCMP][ESS]", "宿舍网".encode()),
    ("aa:00:00:00:00:02", 2412, -71, "[WPA2-PSK-CCMP][ESS]", "宿舍网".encode()),   # 同名 2.4G，弱
    ("aa:00:00:00:00:03", 2437, -55, "[WPA2-PSK-CCMP][ESS]", b"My  Net"),          # 连续两个空格
    ("aa:00:00:00:00:04", 2462, -60, "[ESS]", b'Cafe "Free"'),                    # 开放 + 引号
    ("aa:00:00:00:00:05", 5200, -65, "[WPA2-EAP-CCMP][ESS]", b"eduroam"),
    ("aa:00:00:00:00:06", 5220, -66, "[WPA2-SAE-CCMP][ESS]", b"back\\slash"),
    ("aa:00:00:00:00:07", 5240, -80, "[WPA2-PSK-CCMP][ESS]", b"\xd6\xd0\xce\xc4"),  # GBK 的"中文"
    ("aa:00:00:00:00:08", 5260, -50, "[WPA2-PSK-CCMP][ESS]", b""),                # 隐藏网络
    ("aa:00:00:00:00:09", 5280, -58, "[WPA2-PSK-CCMP][ESS]", b"100%\tsure"),      # % 与制表符
    ("aa:00:00:00:00:0a", 5300, -61, "[WPA2-PSK+SAE-CCMP][ESS]", b"mixed"),        # WPA2/WPA3 混合
    ("aa:00:00:00:00:0b", 2412, -62, "[WEP][ESS]", b"oldwep"),
    ("aa:00:00:00:00:0c", 2417, -63, "[WPA2-OWE-CCMP][ESS]", b"owe-only"),
]
print("bssid / frequency / signal level / flags / ssid")
for r in rows:
    print("%s\t%d\t%d\t%s\t%s" % (r[0], r[1], r[2], r[3], printf_encode(r[4])))
PYEOF
)
echo "$OUT" | sed 's/^/    /'
row() { printf '%s\n' "$OUT" | grep "ssid_hex=$1 "; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

echo "═══ 1. 中文 SSID：字节还原、显示为中文、双频只留强的那条 ═══"
H=$(hex "宿舍网")
R=$(row "$H")
[ "$(printf '%s\n' "$R" | wc -l | tr -d ' ')" = 1 ] && printf '%s' "$R" | grep -q 'signal=-40 ' \
    && printf '%s' "$R" | grep -q 'ssid=宿舍网$' && ok "宿舍网：一条、-40 dBm、显示正确" || bad "中文 SSID：$R"

echo "═══ 2. 连续空格原样保留（原 awk 会并成一个）═══"
row "$(hex 'My  Net')" | grep -q 'ssid=My%20%20Net$' && ok "My  Net → ssid=My%20%20Net" || bad "连续空格丢了"

echo "═══ 3. 引号 / 反斜杠 / 百分号 / 制表符 ═══"
row "$(hex 'Cafe "Free"')" | grep -q 'auth=open' && ok "Cafe \"Free\"：字节对、auth=open" || bad "引号 SSID"
row "$(hex 'back\slash')"  | grep -q 'auth=sae'  && ok "back\\slash：字节对、auth=sae" || bad "反斜杠 SSID"
row "$(printf '100%%\tsure' | od -An -tx1 | tr -d ' \n')" | grep -q 'ssid=100%25%09sure$' \
    && ok "100%<TAB>sure → ssid=100%25%09sure" || bad "百分号/制表符"

echo "═══ 4. 分类 ═══"
row "$(hex eduroam)" | grep -q 'auth=eap secure=\|secure=yes auth=eap' && ok "eduroam → auth=eap" || bad "企业网络没认出来"
printf '%s' "$OUT" | grep -q 'ssid_hex=d6d0cec4 .*ssid=中文$' && ok "GBK 编码的 SSID：字节保住、显示为「中文」" || bad "GBK SSID 不对"
printf '%s' "$OUT" | grep -q 'ssid_hex= ' && bad "隐藏网络不该列出来" || ok "隐藏网络没列出"
# v1.0 计划 GUI-9：混合模式按 PSK 连（只有纯 SAE 才要 key_mgmt SAE）；WEP / OWE 照实报，界面标灰
row "$(hex mixed)" | grep -q 'secure=yes auth=psk ' && ok "PSK+SAE 混合 → auth=psk" || bad "混合模式：$(row "$(hex mixed)")"
row "$(hex oldwep)" | grep -q 'secure=yes auth=wep ' && ok "WEP → auth=wep" || bad "WEP：$(row "$(hex oldwep)")"
row "$(hex owe-only)" | grep -q 'auth=owe ' && ok "OWE → auth=owe" || bad "OWE：$(row "$(hex owe-only)")"

echo "═══ 5. 顺序：信号从强到弱 ═══"
S=$(printf '%s\n' "$OUT" | sed -n 's/.*signal=\(-[0-9]*\).*/\1/p' | tr '\n' ' ')
[ "$(printf '%s\n' $S | sort -rn | tr '\n' ' ')" = "$S" ] && ok "$S" || bad "顺序不对：$S"

echo
echo "═══ 通过 $PASS · 失败 $FAIL ═══"
[ "$FAIL" -eq 0 ]

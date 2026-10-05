#!/usr/bin/env bash
# gk3_wifi_connect 的自测：wpa_cli / dhcpcd / ip 换成桩，看它对 wpa_supplicant 说了什么、
# 存下来给救援系统的那份配置长什么样。任何机器都能跑（不要网卡）。
#
#   bash scripts/live/test-wifi-connect.sh
#
# 真网卡上的连接只能在真机上验；这里验的是"参数有没有传对"—— 隐藏网络少一个
# scan_ssid=1 在真机上的表现只是"连不上"，看不出是哪一步错了。
set -u
cd "$(dirname "$0")/../.."
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/wpa_cli" <<'EOF'
#!/usr/bin/env bash
# 去掉 -i <网卡> -p <控制目录>，剩下的就是命令
while [ $# -gt 0 ]; do case "$1" in -i|-p) shift 2 ;; *) break ;; esac; done
echo "$*" >> "$WPA_LOG"
case "$1" in
    add_network) echo 0 ;;
    status)      printf 'wpa_state=COMPLETED\nssid=test\n' ;;
    *)           echo OK ;;
esac
EOF
cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"addr show"*) echo "    inet 10.0.0.5/24 brd 10.0.0.255 scope global wlan0" ;; esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/dhcpcd"
chmod +x "$T/bin/"*

# 跑一次：$1… = gk3_wifi_connect 的参数。结果：$T/rc、$T/wpa.log、$T/run/wpa_supplicant.conf
run() {
    rm -rf "$T/run" "$T/wpa.log"; : > "$T/wpa.log"
    ( export PATH="$T/bin:$PATH" WPA_LOG="$T/wpa.log" GK3_RUNDIR="$T/run" GK3_WIFI_IF=wlan0
      . scripts/live/installer-lib.sh
      gk3_wifi_up() { :; }       # 网卡与 wpa_supplicant 进程不在这里验
      gk3_wifi_connect "$@" ) > "$T/out" 2> "$T/err"
    echo $? > "$T/rc"
}
rc()   { cat "$T/rc"; }
sent() { grep -qxF -- "$1" "$T/wpa.log"; }
conf() { grep -qxF -- "$1" "$T/run/wpa_supplicant.conf" 2>/dev/null; }
hex()  { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

echo "═══ 1. 隐藏网络 + 密码 ═══"
H=$(hex "宿舍的隐藏网")
run "hex:$H" "abcdefgh" hidden
[ "$(rc)" = 0 ] && ok "连上（rc=0）" || bad "rc=$(rc)：$(cat "$T/err")"
sent "set_network 0 ssid $H" && ok "SSID 按十六进制、不带引号" || bad "SSID 没传对：$(cat "$T/wpa.log")"
sent "set_network 0 scan_ssid 1" && ok "set_network scan_ssid 1" || bad "没发 scan_ssid"
conf "	scan_ssid=1" && ok "存下的配置带 scan_ssid=1（救援系统开机才找得到它）" || bad "存下的配置缺 scan_ssid"
conf "	ssid=$H" && conf '	psk="abcdefgh"' && ok "存下的配置：ssid / psk" || bad "存下的配置不对：$(cat "$T/run/wpa_supplicant.conf" 2>&1)"
grep -q '^NET .*online=yes' "$T/out" && ok "最后报 NET online=yes" || bad "没有 NET 记录：$(cat "$T/out")"

echo "═══ 2. 普通网络不带 scan_ssid ═══"
run "hex:$(hex 'My  Net')" "abcdefgh"
[ "$(rc)" = 0 ] && ! grep -q scan_ssid "$T/wpa.log" && ! conf "	scan_ssid=1" \
    && ok "wpa_cli 与存下的配置里都没有 scan_ssid" || bad "普通网络多了 scan_ssid"

echo "═══ 3. 隐藏的开放网络 ═══"
run "hex:$(hex 'open-hidden')" "" hidden
[ "$(rc)" = 0 ] && sent "set_network 0 key_mgmt NONE" && sent "set_network 0 scan_ssid 1" && conf "	key_mgmt=NONE" \
    && ok "key_mgmt NONE + scan_ssid 1" || bad "开放隐藏网络：rc=$(rc) $(cat "$T/wpa.log")"

echo "═══ 4. 动 wpa_supplicant 之前就拒绝 ═══"
run "hex:$(hex '一二三四五六七八九十一')" "abcdefgh" hidden     # 11 个汉字 = 33 字节
[ "$(rc)" != 0 ] && [ ! -s "$T/wpa.log" ] && grep -q '32 字节' "$T/err" \
    && ok "33 字节的网络名：拒绝，报「最长 32 字节」" || bad "超长 SSID：rc=$(rc) $(cat "$T/err")"
run "hex:$(printf '%064d' 0)" "abcdefgh" hidden
[ "$(rc)" = 0 ] && ok "正好 32 字节：放行" || bad "32 字节被拒：$(cat "$T/err")"
run "hex:$(hex x)" "abcdefgh" yes
[ "$(rc)" != 0 ] && [ ! -s "$T/wpa.log" ] && ok "第三个参数不是 hidden：拒绝" || bad "乱写的第三个参数被放行"
run "hex:$(hex x)" "short" hidden
[ "$(rc)" != 0 ] && [ ! -s "$T/wpa.log" ] && ok "7 个字符的密码：拒绝（原有的检查还在）" || bad "短密码被放行"

echo "═══ 5. 纯 WPA3（SAE，v1.0 计划 GUI-9）═══"
run "hex:$(hex 'wpa3-only')" "abcdefgh" sae
[ "$(rc)" = 0 ] && sent "set_network 0 key_mgmt SAE" && sent "set_network 0 ieee80211w 2" && sent 'set_network 0 psk "abcdefgh"' \
    && ok "key_mgmt SAE + ieee80211w 2，密码照样放 psk" || bad "SAE：rc=$(rc) $(cat "$T/wpa.log")"
conf "	key_mgmt=SAE" && conf "	ieee80211w=2" && ok "存下的配置（给救援系统）也带 SAE" || bad "存下的配置缺 SAE：$(cat "$T/run/wpa_supplicant.conf" 2>&1)"
run "hex:$(hex 'wpa3-hidden')" "abcdefgh" hidden sae
[ "$(rc)" = 0 ] && sent "set_network 0 key_mgmt SAE" && sent "set_network 0 scan_ssid 1" && ok "隐藏 + SAE 一起" || bad "隐藏 + SAE：rc=$(rc)"
run "hex:$(hex 'wpa2')" "abcdefgh"
! grep -q 'key_mgmt\|ieee80211w' "$T/wpa.log" && ok "普通 WPA2 不动 key_mgmt / ieee80211w" || bad "WPA2 多发了 key_mgmt"
run "hex:$(hex 'wpa3-only')" "" sae
[ "$(rc)" != 0 ] && [ ! -s "$T/wpa.log" ] && grep -q '^ERR code=psk-length ' "$T/err" && ok "SAE 不给密码：动 wpa_supplicant 之前拒绝" || bad "SAE 空密码被放行"

echo "═══ 6. 给界面的行：进度只有代码、失败有 ERR ═══"
run "hex:$(hex x)" "abcdefgh"
! grep '^PROGRESS ' "$T/err" | grep -qv -E '^PROGRESS [0-9]+ [a-z][a-z0-9-]*( [a-z_]+=[^ ]*)*$' && grep -q '^PROGRESS 20 wifi-assoc$' "$T/err" \
    && ok "PROGRESS 行全是代码（hex 名字不带 ssid=）" || bad "进度行不对：$(grep PROGRESS "$T/err")"
run "plain name" "abcdefgh"
grep -q '^PROGRESS 20 wifi-assoc ssid=plain%20name$' "$T/err" && ok "明文名字：ssid= 百分号编码" || bad "明文名字的进度：$(grep PROGRESS "$T/err")"
run "hex:$(hex x)" "short"
grep -q '^ERR code=psk-length len=5$' "$T/err" && ok "密码太短：ERR code=psk-length len=5" || bad "没有 ERR：$(cat "$T/err")"

echo
echo "═══ 通过 $PASS · 失败 $FAIL ═══"
[ "$FAIL" -eq 0 ]

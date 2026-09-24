#!/usr/bin/env python3
# 把 `wpa_cli scan_results` 的输出变成安装器的 WIFI 行记录（installer-lib.sh 的协议）。
#
#   wpa_cli -i wlan0 -p /run/wpa_supplicant scan_results | python3 gk3-wpa-scan.py
#
# 输出，按信号从强到弱，同名只留最强的一条（2.4G / 5G 双频会各出一条）：
#   WIFI signal=-48 secure=yes auth=psk ssid_hex=e4b8ade69687 ssid=中文
#
#   ssid_hex  SSID 的原始字节。连接时传回它（gk3_wifi_connect hex:<…>）——
#             任意字节都不会被引号、空格、转义搞坏
#   ssid      给人看的：按 UTF-8 解码，解不开再试 GB18030（老路由器有 GBK 编码的
#             中文 SSID），都不行才显示 U+FFFD；再按协议做百分号编码
#   auth      open | owe | wep | psk | sae | eap —— 界面据此决定要不要密码、
#             以及"企业网络（eap）暂不支持"这种话要不要直说
#
# ★ 为什么不用 awk：wpa_supplicant 用 printf_encode 输出 SSID
#   （wpa-2.10 src/utils/common.c:477-523，wpa_ssid_txt 在 :622-633 调它），
#   32–126 之外的每个字节都变成 \xNN —— 中文 SSID 全是转义串。而 scan_results
#   一行是制表符分隔的（wpa_supplicant/ctrl_iface.c:3008 与 :3142），原先的 awk
#   按任意空白切、再用单个空格拼回，于是 "My  Net" 变成 "My Net"，连不上。
import sys


def unescape(s):
    """printf_encode 的逆：\\" \\\\ \\e \\n \\r \\t \\xNN → 原始字节"""
    out = bytearray()
    i = 0
    simple = {'"': 0x22, "\\": 0x5C, "e": 0x1B, "n": 0x0A, "r": 0x0D, "t": 0x09}
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in simple:
                out.append(simple[n]); i += 2; continue
            if n == "x" and i + 4 <= len(s):
                try:
                    out.append(int(s[i + 2:i + 4], 16)); i += 4; continue
                except ValueError:
                    pass
        out += c.encode("utf-8")
        i += 1
    return bytes(out)


def enc(text):
    """协议的百分号编码：% 与所有 ≤0x20 的字符 → %XX，其余（含中文）原样。
    ≤0x20 的字符在 UTF-8 里都是单字节，所以逐字符编码与逐字节等价。"""
    return "".join("%%%02X" % ord(ch) if (ord(ch) <= 0x20 or ch == "%") else ch
                   for ch in text)


def auth_of(flags):
    f = flags.upper()
    if "EAP" in f:  return "eap"
    if "SAE" in f:  return "sae"
    if "PSK" in f:  return "psk"
    if "WEP" in f:  return "wep"
    if "OWE" in f:  return "owe"
    return "open"


def main():
    best = {}
    for line in sys.stdin.read().splitlines():
        parts = line.split("\t", 4)
        if len(parts) != 5:
            continue                        # 表头 "bssid / frequency / …" 与杂行
        _bssid, _freq, sig, flags, ssid_txt = parts
        try:
            sig = int(sig)
        except ValueError:
            continue
        raw = unescape(ssid_txt)
        if not raw or raw.strip(b"\0") == b"":
            continue                        # 隐藏网络：没有名字可列
        a = auth_of(flags)
        if raw not in best or sig > best[raw][0]:
            best[raw] = (sig, a)
    for raw, (sig, a) in sorted(best.items(), key=lambda kv: (-kv[1][0], kv[0])):
        try:
            name = raw.decode("utf-8")
        except UnicodeDecodeError:
            try:                            # 老路由器常见 GBK 编码的中文 SSID
                name = raw.decode("gb18030")
            except UnicodeDecodeError:
                name = raw.decode("utf-8", "replace")
        print("WIFI signal=%d secure=%s auth=%s ssid_hex=%s ssid=%s"
              % (sig, "no" if a in ("open", "owe") else "yes", a, raw.hex(), enc(name)))


if __name__ == "__main__":
    main()

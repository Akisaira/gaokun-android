#!/usr/bin/env python3
# 取出图（test/shots_test.dart）要用的中文字体：Debian 的 fonts-wqy-microhei。
#
#   python3 tool/fetch-test-font.py      → test/fonts/wqy-microhei.ttc
#
# ★ 与设备上同一个字体：live 镜像装的就是这个包（docs/stage7-live-installer.md §3
#   选的也是它，约 5 MiB）。出图的字形与真机一致，改文案时看到的换行就是真机上的换行。
# ★ 钉死版本与 sha256；不入库（test/fonts/ 在 .gitignore 里）。
# ⚠️ 纯标准库：.deb 是 ar 包，里面是 data.tar.xz —— macOS 上不必有 dpkg。
import hashlib, io, os, sys, tarfile, urllib.request

URL = "http://deb.debian.org/debian/pool/main/f/fonts-wqy-microhei/fonts-wqy-microhei_0.2.0-beta-4_all.deb"
SHA256 = "3fb0ff79033124b863bf9d28af56c62646d5b74774d26be0ce8a5beefe2fed55"   # 2026-09-25 取
OUT = os.path.join(os.path.dirname(__file__), "..", "test", "fonts", "wqy-microhei.ttc")

data = urllib.request.urlopen(URL, timeout=60).read()
got = hashlib.sha256(data).hexdigest()
if got != SHA256:
    sys.exit("!! sha256 不符：%s != %s（Debian 换了包？换版本要改上面两行）" % (got, SHA256))
print("deb sha256 %s（%d 字节）" % (got, len(data)))
assert data[:8] == b"!<arch>\n", "不是 ar 包"
off = 8
while off < len(data):
    name = data[off:off + 16].decode().strip().rstrip("/")
    size = int(data[off + 48:off + 58].decode().strip())
    body = data[off + 60:off + 60 + size]
    off += 60 + size + (size & 1)
    if name.startswith("data.tar"):
        with tarfile.open(fileobj=io.BytesIO(body)) as t:
            for m in t.getmembers():
                if m.name.endswith("wqy-microhei.ttc"):
                    os.makedirs(os.path.dirname(OUT), exist_ok=True)
                    open(OUT, "wb").write(t.extractfile(m).read())
                    print("→", os.path.normpath(OUT), m.size, "字节")
                    sys.exit(0)
sys.exit("!! 包里没找到 wqy-microhei.ttc")

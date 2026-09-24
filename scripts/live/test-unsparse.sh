#!/usr/bin/env bash
# gk3-unsparse.py 的自测。
#
#   bash scripts/live/test-unsparse.sh
#
# 第 1 部分是纯 Python 合成用例，任何机器都能跑（Mac 也行）。
# 第 2 部分只在有 img2simg / simg2img 时跑（Debian：android-sdk-libsparse-utils），
# 拿【真工具】做交叉比对 —— 本仓的惯例是"两个实现、同一份输入、逐字节比"
# （boot.img 解包就是这么验的，见 install-gaokun3.sh 的注释）。
#
# ⚠️ 重点不是"能展开"，而是两条会让人装出一台半坏机器的性质：
#     1. 截断的输入（下载断在一半）必须【失败】，不能写一半报成功
#     2. 经过 zstd 管道之后结果逐字节不变 —— 那正是 simg2img 做不到的事
#
# ⚠️ 故意【不开 pipefail】：判据都显式取各段的退出码（见 scripts/verify-root.sh:8-11）。
set -u
cd "$(dirname "$0")/../.."
UNSPARSE="python3 scripts/live/gk3-unsparse.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }

# 造一份原始镜像 + 手写的 sparse 编码。块段覆盖四种类型，外加扩展头。
python3 - "$T" <<'PYEOF'
import os, random, struct, sys, zlib
out = sys.argv[1]
BS = 4096
rnd = random.Random(20260924)

def build(name, ext_file=0, ext_chunk=0, with_crc=True):
    raw = bytearray()
    chunks = []                                   # (type, blocks, payload)
    def add_raw(nblk):
        d = bytes(rnd.getrandbits(8) for _ in range(nblk * BS))
        raw.extend(d); chunks.append((0xCAC1, nblk, d))
    def add_fill(nblk, pat):
        raw.extend(pat * (nblk * BS // 4)); chunks.append((0xCAC2, nblk, pat))
    def add_skip(nblk):
        raw.extend(b"\0" * (nblk * BS)); chunks.append((0xCAC3, nblk, b""))
    add_raw(3); add_skip(40); add_fill(7, b"\xde\xad\xbe\xef")
    add_raw(1); add_skip(300); add_fill(2, b"\0\0\0\0"); add_raw(5); add_skip(9)
    if with_crc:
        chunks.append((0xCAC4, 0, struct.pack("<I", zlib.crc32(bytes(raw)) & 0xffffffff)))
    total_blks = len(raw) // BS
    fh = 28 + ext_file; ch = 12 + ext_chunk
    s = bytearray(struct.pack("<IHHHHIIII", 0xED26FF3A, 1, 0, fh, ch, BS,
                              total_blks, len(chunks), 0))
    s += b"\xaa" * ext_file
    for t, n, p in chunks:
        s += struct.pack("<HHII", t, 0, n, ch + len(p)) + b"\xbb" * ext_chunk + p
    open(os.path.join(out, name + ".raw"), "wb").write(raw)
    open(os.path.join(out, name + ".simg"), "wb").write(s)
    return s

s = build("basic")
build("exthdr", ext_file=8, ext_chunk=4)
build("nocrc", with_crc=False)
# 反例
open(os.path.join(out, "trunc.simg"), "wb").write(s[:len(s) - 5000])     # 断在 RAW 中间
open(os.path.join(out, "trunc-hdr.simg"), "wb").write(s[:20])            # 连头都不全
open(os.path.join(out, "trailing.simg"), "wb").write(s + b"garbage")
bad = bytearray(s); bad[0] ^= 0xff
open(os.path.join(out, "badmagic.simg"), "wb").write(bytes(bad))
# 头部把总块数多报 1 块：内容全对，但结尾核对必须抓到
lie = bytearray(s); struct.pack_into("<I", lie, 16, struct.unpack_from("<I", s, 16)[0] + 1)
open(os.path.join(out, "blkcount.simg"), "wb").write(bytes(lie))
PYEOF

echo "═══ 1. 合成用例：四种块段 + 扩展头，逐字节与原始镜像一致 ═══"
for n in basic exthdr nocrc; do
    $UNSPARSE "$T/$n.out" < "$T/$n.simg" 2>"$T/$n.err"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(sha "$T/$n.out")" = "$(sha "$T/$n.raw")" ]; then
        ok "${n}：sha256 一致（$(wc -c < "$T/$n.raw" | tr -d ' ') 字节）"
    else bad "${n}：rc=$rc 或内容不一致"; sed 's/^/      /' "$T/$n.err"; fi
done

echo "═══ 2. 经过管道（simg2img 恰恰在这里失败）═══"
cat "$T/basic.simg" | $UNSPARSE "$T/pipe.out" 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && [ "$(sha "$T/pipe.out")" = "$(sha "$T/basic.raw")" ] \
    && ok "cat | unsparse：一致" || bad "管道输入 rc=$rc 或内容不一致"
if command -v zstd >/dev/null; then
    zstd -q -19 --long -f "$T/basic.simg" -o "$T/basic.simg.zst"
    zstd -dc --long=31 "$T/basic.simg.zst" | $UNSPARSE "$T/zst.out" 2>/dev/null
    rc=( "${PIPESTATUS[@]}" )
    [ "${rc[0]}" -eq 0 ] && [ "${rc[1]}" -eq 0 ] && [ "$(sha "$T/zst.out")" = "$(sha "$T/basic.raw")" ] \
        && ok "zstd -dc --long=31 | unsparse：一致（与 release.sh 的 -19 --long 同参数压缩）" \
        || bad "zstd 管道 rc=${rc[*]} 或内容不一致"
else echo "  - 没有 zstd，跳过"; fi

echo "═══ 3. 反例：每一种都必须非零退出 ═══"
for n in trunc trunc-hdr trailing badmagic blkcount; do
    $UNSPARSE "$T/$n.out" < "$T/$n.simg" 2>"$T/$n.err"; rc=$?
    if [ "$rc" -ne 0 ]; then ok "$n 被拒：$(tail -1 "$T/$n.err" | sed 's/^!! gk3-unsparse: //')"
    else bad "$n 居然成功了（rc=0）"; fi
done

echo "═══ 4. 进度：单调、落在给定区间、最后一行到终点 ═══"
$UNSPARSE --progress 30 40 "$T/p.out" < "$T/basic.simg" 2>"$T/p.err"
PCTS=$(awk '$1=="PROGRESS"{print $2}' "$T/p.err")
LAST=$(printf '%s\n' "$PCTS" | tail -1)
MONO=$(printf '%s\n' "$PCTS" | awk 'NR>1 && $1<prev{bad=1} {prev=$1} END{print bad?"no":"yes"}')
RANGE=$(printf '%s\n' "$PCTS" | awk '$1<30||$1>70{bad=1} END{print bad?"no":"yes"}')
[ "$LAST" = 70 ] && [ "$MONO" = yes ] && [ "$RANGE" = yes ] \
    && ok "$(printf '%s\n' "$PCTS" | wc -l | tr -d ' ') 行 PROGRESS，单调，∈[30,70]，终点 70" \
    || bad "进度不对：last=$LAST 单调=$MONO 区间内=$RANGE"

echo "═══ 5. 与真 simg2img 交叉比对 ═══"
if command -v img2simg >/dev/null && command -v simg2img >/dev/null; then
    # 造一份带洞、带填充的原始镜像，让【真 img2simg】去编码
    python3 - "$T/ref.raw" <<'PYEOF'
import random, sys
r = random.Random(7); BS = 4096
with open(sys.argv[1], "wb") as f:
    for i in range(600):
        k = i % 7
        if k in (0, 3):  f.write(bytes(r.getrandbits(8) for _ in range(BS)))
        elif k == 5:     f.write(b"\x5a\xa5\x5a\xa5" * (BS // 4))
        else:            f.write(b"\0" * BS)
PYEOF
    img2simg "$T/ref.raw" "$T/ref.simg" >/dev/null 2>&1
    simg2img "$T/ref.simg" "$T/ref.simg2img" >/dev/null 2>&1
    zstd -q -19 --long -f "$T/ref.simg" -o "$T/ref.simg.zst"
    zstd -dc --long=31 "$T/ref.simg.zst" | $UNSPARSE "$T/ref.ours" 2>/dev/null
    A=$(sha "$T/ref.raw"); B=$(sha "$T/ref.simg2img"); C=$(sha "$T/ref.ours")
    [ "$A" = "$B" ] && [ "$B" = "$C" ] \
        && ok "img2simg → {simg2img, zstd|unsparse} 三者 sha256 相同" \
        || bad "不一致：原始 ${A:0:12} simg2img ${B:0:12} 我们 ${C:0:12}"
    # 顺带把"simg2img 吃不了管道"这件事本身钉成测试 —— 哪天上游修了，这里会提醒
    if cat "$T/ref.simg" | simg2img - "$T/ref.pipe" >/dev/null 2>&1; then
        echo "  ⓘ 这版 simg2img 居然吃得下管道了 —— 可以重新评估是否还需要 gk3-unsparse"
    else ok "确认 simg2img 读管道失败（sparse_read.cpp:103 的 lseek），gk3-unsparse 有存在理由"; fi
else echo "  - 没有 img2simg/simg2img，跳过（在 Debian 容器里跑：apt install android-sdk-libsparse-utils）"; fi

echo
echo "═══ 通过 $PASS · 失败 $FAIL ═══"
[ "$FAIL" -eq 0 ]

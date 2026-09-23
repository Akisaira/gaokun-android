#!/usr/bin/env python3
"""把 mesa 生成的 Android.bp 里烤死的【旧树绝对路径】重定位到当前树。

背景（2026-08-19 Stage 6 M3 实测）：
meson_to_hermetic 的生成器会把若干路径以**绝对路径**写进 genrule 的 cmd：

  cmd: "… --rnn /home/vahiru/aosp/external/mesa3d/src/freedreno/registers …"
  cmd: "… glslangValidator -V -I/home/vahiru/aosp/external/mesa3d/src/vulkan/runtime/bvh
                              -I/home/vahiru/aosp/external/mesa3d/src/compiler/spirv …"

把 Stage 5 的补丁树铺进 crDroid（路径从 ~/aosp 变成 ~/crdroid）之后，
这 53 处全部指向不存在的目录，构建在 17 个 genrule 上失败：

  FileNotFoundError: [Errno 2] No such file or directory:
    '/home/vahiru/aosp/external/mesa3d/src/freedreno/registers/freedreno_copyright.xml'

★ 为什么不改成相对路径（`$(location …)`）—— 试过这个念头，行不通：
  这些绝对路径的作用恰恰是**逃出 Soong 的 sbox 沙箱**。沙箱里只有被声明成
  `srcs` 的文件，而 glslang 那两个 `-I` 指向的目录（尤其 `src/compiler/spirv`
  下被 `#include` 的头）**根本没被声明**。改成相对路径 = 沙箱里找不到，
  失败得更晚更难查。`--rnn` 那条的 xml 虽然声明了，但为保持一致也一并重定位。

所以正解是"重定位"而不是"相对化"。副作用是构建不再 hermetic
（out/ 里留有本机路径），但这本来就是生成器的既有行为，不是本脚本引入的。

幂等：把任何形如 `<abs>/external/mesa3d` 的前缀统一改写成当前树的实际路径，
所以对已经正确的文件是空操作。

用法: mesa-relocate-abs-paths.py [<tree-root>]      默认 ~/crdroid
"""
import io
import os
import re
import sys

# 任意绝对路径 + /external/mesa3d。故意不写死 /home/vahiru/aosp，
# 这样换构建机、换目录名都不用改脚本。
PAT = re.compile(r'/(?:[A-Za-z0-9._+-]+/)+external/mesa3d')

FILES = ['Android.bp', 'Android_res.bp']


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/crdroid')
    root = os.path.abspath(root)
    want = os.path.join(root, 'external/mesa3d')
    if not os.path.isdir(want):
        sys.exit('找不到 %s' % want)

    total = 0
    for name in FILES:
        p = os.path.join(want, name)
        if not os.path.isfile(p):
            print('  跳过（不存在）: %s' % name)
            continue
        s = io.open(p, encoding='utf-8').read()
        hits = [m.group(0) for m in PAT.finditer(s)]
        wrong = [h for h in hits if h != want]
        if not wrong:
            print('  %s: %d 处绝对路径，已全部正确' % (name, len(hits)))
            continue
        s2 = PAT.sub(want, s)
        io.open(p, 'w', encoding='utf-8', newline='\n').write(s2)
        total += len(wrong)
        print('  %s: 重定位 %d 处 -> %s' % (name, len(wrong), want))
    print('共重定位 %d 处' % total)


if __name__ == '__main__':
    main()

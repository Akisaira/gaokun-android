#!/usr/bin/env python3
"""给 external/deqp-deps/glslang 补一个【自足的】host 端 glslangValidator。

为什么需要：mesa/turnip 构建期要用 glslangValidator 把 BVH/ASTC 的 GLSL
计算着色器编成 SPIR-V，而 Soong 的 genrule 沙箱禁止调用 PATH 上的系统
glslangValidator（"glslangValidator" is not allowed to be used），AOSP 树里
glslang 又只有静态库、没有可执行模块。turnip 的 subdir('bvh') 是无条件的，
所以"让 glslang 不可用"会让 vk_bvh_include_dir 未定义而生成失败 —— 只能补工具。

★ 为什么不复用树内的 deqp_glslang_* 静态库（2026-08-19 实测）：

    error: dependency "deqp_glslang_SPIRV" of "glslangValidator"
           missing variant: os:linux_glibc,link:static
    available variants: os:android,arch:arm64_armv8-2a,link:static …

  那些库继承 deqp_and_deps_defaults（external/deqp/Android.bp），里面有
  sdk_version:"27" 和 -DDE_OS=DE_OS_ANDROID，是彻底的 device-only 模块；
  给它们加 host_supported 会连锁污染整个 deqp。故本脚本生成的模块自带源码
  清单，只依赖 glslang 目录本身。

两个坑（都实测踩过）：
  1. -DENABLE_SPIRV 不给 → 运行时报 "does not have SPIR-V support"
     （StandAlone 的 SPIR-V 出口是编译期开关，不是命令行选项）。
  2. StandAlone.cpp 硬 include "glslang/glsl_intrinsic_header.h" —— 这是
     CMake 侧用 gen_extension_headers.py 生成的，Soong 侧没人生成，
     必须自己补 genrule，否则 fatal error: file not found。

幂等：重复运行只替换自己那一段（以 GAOKUN_MARK 起头到文件尾）。
用法: glslang-host-tool.py [<tree-root>]      默认 ~/crdroid
"""
import io
import os
import sys

GAOKUN_MARK = '// ─── gaokun3 (patches/0003)'

BLOCK = '''
// ─── gaokun3 (patches/0003): 自足的 host 端 glslangValidator ───
// 供 external/mesa3d/Android.bp 的 genrule 以 tools: ["glslangValidator"]
// + $(location glslangValidator) 使用（scripts/mesa-bp-merge.py 会改写）。
// ⚠️ 刻意【不】复用 deqp_glslang_* 静态库：它们继承
//    deqp_and_deps_defaults（external/deqp/Android.bp，带 sdk_version:"27"
//    与 -DDE_OS=DE_OS_ANDROID），是彻底的 device-only 模块，
//    没有 linux_glibc 变体。
genrule {
    name: "gaokun_glslang_glsl_intrinsic_header",
    // StandAlone.cpp 硬 include 它；CMake 侧由 gen_extension_headers.py
    // 生成，Soong 侧原本无人生成 → fatal error: file not found。
    srcs: ["glslang/ExtensionHeaders/*.glsl"],
    out: ["glslang/glsl_intrinsic_header.h"],
    tool_files: ["gen_extension_headers.py"],
    // 脚本只接受目录（内部 glob '*.glsl'），故从第一个
    // 输入文件反推目录；dirname 多参数会逐行输出，head -1 取一行。
    cmd: "$(location gen_extension_headers.py) -i $$(dirname $(in) | head -1) -o $(out)",
}

cc_binary_host {
    name: "glslangValidator",
    cpp_std: "c++17",
    rtti: true,
    cflags: [
        "-DENABLE_HLSL",
        "-DENABLE_SPIRV",
        "-DENABLE_SPVREMAPPER",
        "-DENABLE_OPT=0",
        "-DGLSLANG_OSINCLUDE_UNIX",
        // 构建期工具，不值得为 AOSP 比 glslang 上游严的告警集逐条压。
        "-Wno-error",
    ],
    cppflags: [
        "-fexceptions",
    ],
    local_include_dirs: [
        ".",
        "StandAlone",
        "SPIRV",
        "glslang/MachineIndependent",
        "glslang/HLSL",
        "glslang/ResourceLimits",
    ],
    generated_headers: [
        "deqp_glslang_gen_build_info_h",
        "gaokun_glslang_glsl_intrinsic_header",
    ],
    srcs: [
        "StandAlone/StandAlone.cpp",
        "glslang/ResourceLimits/ResourceLimits.cpp",
        "glslang/MachineIndependent/*.cpp",
        "glslang/MachineIndependent/preprocessor/*.cpp",
        "glslang/GenericCodeGen/*.cpp",
        // ENABLE_HLSL 开了就必须给源码：MachineIndependent 里
        // 对 HLSL 符号是硬引用，只开宏不给源码会缺符号。
        "glslang/HLSL/*.cpp",
        "glslang/OSDependent/Unix/ossource.cpp",
        // 不编 */CInterface/*.cpp：C API 两个文件互相引用，
        // 要么都进要么都不进，而 StandAlone 根本不用。
        "SPIRV/GlslangToSpv.cpp",
        "SPIRV/InReadableOrder.cpp",
        "SPIRV/Logger.cpp",
        "SPIRV/SpvBuilder.cpp",
        "SPIRV/SpvPostProcess.cpp",
        "SPIRV/SpvTools.cpp",
        "SPIRV/SPVRemapper.cpp",
        "SPIRV/disassemble.cpp",
        "SPIRV/doc.cpp",
    ],
}
'''


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/crdroid')
    bp = os.path.join(root, 'external/deqp-deps/glslang/Android.bp')
    if not os.path.isfile(bp):
        sys.exit('找不到 %s' % bp)
    s = io.open(bp, encoding='utf-8').read()
    i = s.find(GAOKUN_MARK)
    if i >= 0:
        s = s[:i].rstrip('\n') + '\n'
        note = '旧块已替换'
    else:
        note = '首次追加'
    s = s.rstrip('\n') + '\n' + BLOCK
    io.open(bp, 'w', encoding='utf-8', newline='\n').write(s)

    gen = os.path.join(root, 'external/deqp-deps/glslang/gen_extension_headers.py')
    mode = os.stat(gen).st_mode
    if not mode & 0o111:
        os.chmod(gen, mode | 0o755)
        note += '；已给 gen_extension_headers.py 加可执行位'
    print('%s -> %s' % (note, bp))


if __name__ == '__main__':
    main()

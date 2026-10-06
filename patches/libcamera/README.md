# libcamera 的本仓改动

上游：`https://gitlab.freedesktop.org/camera/libcamera.git`，
本仓验证过的 commit：**`87c7285663aaad7608fdc18d5216ec6811c685c7`**（2026-09-09）。

## 文件

| 文件 | 作用 |
|---|---|
| `0001-base-thread-use-sched_setaffinity-on-bionic.patch` | bionic 没有 `pthread_setaffinity_np`（[#89](../../docs/stage4-findings.md#89)） |
| `0002-ipa-libipa-add-hi846-camera-sensor-helper.patch` | hi846 的增益模型，**实测标定**（[#94](../../docs/stage4-findings.md#94)），可发上游 |
| `0003-ipa-manager-allow-trusting-unsigned-ipa.patch` | 让 IPA 跑进程内而不是独立进程（宏 `LIBCAMERA_IPA_TRUST_UNSIGNED`，默认行为不变） |
| `libcamera-Android.bp` | 把 libcamera 编成 Soong 模块，放到 `external/libcamera/Android.bp` |
| `config.h` | 替代 meson 自动生成的那份，路径改成 vendor 下的真实位置 |

## ⚠️★★ 为什么必须在 AOSP 里编

最初的规划是"NDK 预编译 libcamera + Soong 只编 HAL"。**那是错的**：
NDK 的 libc++ 用内联命名空间 `std::__ndk1`，AOSP 平台用 `std::__1`，
凡签名里带标准库类型的符号两边 mangled name 就对不上。实测链接报
`undefined symbol: ...generateConfigurationENSt3__14span...`。
⇒ **跨工具链混链 C++ 的前提是 ABI 相同，而 NDK 与平台恰恰不同。** 见 [#96](../../docs/stage4-findings.md#96)。

## 还需要的生成文件

Soong 不跑 meson 的生成步骤，所以这 5 个 `.cpp` 与那批生成头要另外产出：
`control_ids.cpp` / `property_ids.cpp` / `version.cpp` / `ipa_pub_key.cpp` /
`softisp_ipa_proxy.cpp`，以及 `generated/include/libcamera/**`（含
`control_ids.h` / `property_ids.h` / `formats.h` / `version.h` /
`ipa/*_ipa_interface.h` 等）。

⬜ **目前靠跑一次 meson 构建产出再拷贝**（`scripts/camera/build-libcamera-android.sh`），
这是一个**手动步骤**，正是 [#82](../../docs/stage4-findings.md#82)/[#85](../../docs/stage4-findings.md#85)
那种会被遗忘的形状。正解是用 Soong 的 `genrule` 跑 libcamera 自带的 Python
生成器（`utils/gen-controls.py`、`utils/ipc/generate.py`），它们只依赖树内的
YAML/mojom，没有别的前置。

## ★ 那组 include 路径是抄来的，不是试出来的

libcamera 的 IPA 源码大量使用**裸名** include（`<module.h>`、
`<core_ipa_interface.h>`、`<ipa_context.h>`、`<control_ids.h>` …）。
少一个的症状是一串**看不出关联**的 `unknown type name`。
`libcamera-Android.bp` 里那组 `local_include_dirs` 是从已跑通的 meson 构建的
`build.ninja` 里 grep 某个 `.o` 的编译行取 `-I` 抄来的 —— **别再一个个试**。

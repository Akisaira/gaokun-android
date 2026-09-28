# 上游 Venus 补丁集（sc8280xp 硬件视频编解码）

> ## ❌ 2026-09-28 起不再使用 —— 视频编解码换成了 qcom-iris（案卷 docs/stage4-findings.md #128）
>
> 这一套从 `scripts/kernel-apply-patches.sh` 里撤掉了，替代品是 `patches/0053`–`0060`。文件留在这里作案卷。
>
> ⚠️★ 本文下面有两句话**是错的**，保留原文、在这里更正：
> 1. "iris 的 of_match 里没有 sc8280xp，永远服务不了本机" —— **错**。v7.2-rc2 的 `iris_probe.c:372`
>    就认 `"qcom,sm8250-venus"`，而上游 v7.3 给 sc8280xp 的节点写的是
>    `"qcom,sc8280xp-iris", "qcom,sm8250-venus"`：靠回落串直接用 `sm8250_data`，驱动一行不用加
>    （Dmitry Baryshkov 的 "enable SM8350 and SC8280XP support" v7；binding 也已在 v7.2-rc2 里）。
>    当年只看了 of_match 的前几条。
> 2. "compatible 选 sc8280xp 而不是 sm8350" —— **本仓入库的 0019 从来都是 `qcom,sm8350-venus`**，
>    发出去的 DTB 里也是它（`strings prebuilt-boot/dtb/*.dtb`），所以设备一直跑的是 `sm8350_res`。
>    影响近乎为零（`freq_tbl` 只在 DT 没有 OPP 表时兜底），但文档说的不是事实。
> 3. 另查出一个 venus 时代的潜伏缺陷（不再修，随 venus 一起退役）：0017/0018 设了
>    `opp_pmdomain = {"mx", NULL}` 却没设 `opp_pmdomain_num`，于是 venus 从来没投过 MX 电压票；
>    MMCX 则根本不在节点里，全靠显示 / 相机把它顶在 TURBO_L1。0019 的 OPP 频点也没有按 videocc 的 ÷3 换算。

**来源**：上游 sc8280xp Venus 使能系列，编号沿用作者原始的 0013–0020。
本目录**不改写它们** —— 上游补丁保持原样，方便日后和上游对齐。

## ⚠️ 它们为什么必须入库（2026-08-22 的教训）

这一套此前**只活在构建机的工作区里**。M17 那次构建当场炸出来：

```
Error: sc8280xp-huawei-gaokun3.dts:1428.1-7 Label or path venus not found
FATAL ERROR: Syntax error parsing input tree
```

—— `sc8280xp.dtsi` 被回退过，`venus` 这个 label 没了，而
[`../0011-arm64-dts-gaokun3-enable-venus.patch`](../0011-arm64-dts-gaokun3-enable-venus.patch)
（`&venus { status = "okay"; }`）**依赖**它。也就是说：
**从干净的 v7.2-rc2 出发，照本仓的 `patches/` 根本重建不出发版内核。**
同一次还发现 `0009`（CPU cooling maps）也从那棵树上掉了 —— 要是没被拦住，
新内核会**悄悄失去 CPU 温控降频**，症状要等某次长时间游戏后突然关机才出现。

**结论：任何"只在构建机上打过一次"的补丁都必须入库。**
现在由 [`../../scripts/kernel-apply-patches.sh`](../../scripts/kernel-apply-patches.sh)
统一应用并做幂等检查。

## 应用状态：8 个打 7 个

| 补丁 | 动什么 | 状态 |
|---|---|---|
| `0013` dt-bindings | 文档 | ✅ |
| `0014` 去掉 of_match 尾逗号 | `core.c` | ❌ **故意跳过** —— 纯格式清理，主线已分叉 |
| `0015` hfi_venus presets 位更新 | `core.h` / `hfi_venus.c` | ✅ |
| `0016` 可选 LLCC 路径 | `core.c` / `core.h` / `pm_helpers.c` | ✅ |
| `0017` SM8350 resource struct | `core.c` | ✅ |
| `0018` **SC8280XP** resource struct | `core.c` | ✅ 本机用的就是它 |
| `0019` dtsi 加 Venus 节点 | `sc8280xp.dtsi` | ✅ ★ 提供 `venus` label |
| `0020` gaokun3 使能 Venus | `sc8280xp-huawei-gaokun3.dts` | ✅ 与本仓 `0011` **代码完全相同** |

★ compatible 选 `sc8280xp` 而不是 `sm8350`：两个资源结构只差 `freq_tbl`，
`sm8350_res` 借用的是 sm8250 的表，`sc8280xp_res` 才是本 SoC 自己的。
理由与取证见 `../0011` 的说明和 `docs/stage4-findings.md` #41。

## ⚠️ 0019 需要模糊匹配

`0019` 的第一个 hunk 上下文是 `#include` 列表，而 v7.2-rc2 里多一行
`#include <dt-bindings/firmware/qcom,scm.h>`，**`git apply` 会直接拒绝**：

```
error: patch failed: arch/arm64/boot/dts/qcom/sc8280xp.dtsi:11
```

`patch -p1 --fuzz=3` 三个 hunk 全成（fuzz 2 / offset 6 / offset 36）。
应用脚本会在 `git apply` 失败后自动回落到 `patch --fuzz=3` 并**明确打印**
用了模糊匹配 —— 别让它静默发生。

## ⚠️ 还有一个不在本目录、但同样必需的前提

`CONFIG_VIDEO_QCOM_IRIS` **必须关**，否则 Venus 编不过，而且报错完全看不出跟它
有关（`sm8350_reg_preset` / `VPU_VERSION_IRIS2` undeclared，报在 `core.c`，
像补丁打错）。主线 v7.2 用 `#if !IS_ENABLED(IRIS)` 把本机需要的资源全编掉了，
而 iris 的 of_match 里没有 sc8280xp，永远服务不了本机。
这一条由 `scripts/kernel-config-android.sh` 的 MUST_N 断言把守。

# 游戏特化总览

最后更新：**2026-10-11**。这台机器的目标是稳定跑 arm64 手游。为游戏做的改动分散在内核补丁、设备树、tree-fix 和开发脚本里，本文件把它们集中列出来：每一项解决什么问题、改在哪里、现在是什么状态。
细节和证据仍以各项链接的案卷、issue 和脚本头注释为准。Duck Detector 的逐项诊断、每次上机后的变化记录在 [`duck-detector-plan.md`](duck-detector-plan.md)，那份是过程记录，本文件只写结论。

状态记法：**镜像** = 已进 ROM 或发版内核；**实验** = 只在开发机上跑过，没进发版；**脚本** = 开发者在 Mac 侧手动运行，不进镜像。

---

## 1. 总表

| 方向 | 改动 | 解决什么 | 落点 | 状态（2026-10-11） |
|---|---|---|---|---|
| 兼容性 | **39 位用户地址窗口**（`patches/0078`） | 英雄联盟手游 / Unity il2cpp 一启动就崩（`il2cpp_init+28` 写 `0x10`，#17；#20 是同一个崩溃） | `kernel-apply-patches.sh:208-211`；`kernel-config-android.sh` 断言 `ARM64_USER_MMAP_WINDOW_39`、`ARCH_MMAP_RND_BITS_MAX=24` | 镜像（dev.11 起）。代价：mmap 随机化从 33 位降到 24 位，和手机一样。⬜ 进对局（需要登录）、抖音复测 |
| 兼容性 | `CONFIG_COMPAT=y` | 只有 armeabi-v7a 库的老游戏 | `.config` | 镜像（一直都有；10-11 配错的那版内核里缺了它，见 §4 第 4 条） |
| 兼容性 | **EGL blob cache 多文件**：`ro.egl.blobcache.multifile=true` | ANGLE 的程序和管线缓存超出默认的 2 MiB 单文件上限，游戏每次都重编着色器（#34 鸣潮） | `device.mk:265-268` | 镜像（dev.11 起）。⬜ 同一游戏第二次进场景时不再整套重编 |
| 兼容性 | UE 游戏选 GLES 还是 Vulkan（#33 无限暖暖） | 推断 UE 拿 `GL_RENDERER` 的 `ANGLE (` 前缀去匹配机型档案时没匹配上 | `debug.angle.gl_renderer` / `gl_vendor` 覆盖 | 等报告者做 A/B，有效再讨论进不进镜像（全局冒充 Adreno 可能把游戏带进针对高通驱动的规避分支） |
| 音频 | **低延迟播放块**（`patches/0083`，crDroid 侧 tree-fix [22]）+ `ro.vendor.audio.primary.out_latency_ms=10` | 音游延迟：应用输出延迟 317 → 114 ms，Arcaea 轨道 110 ms，8 核满载下 0 欠载 | `device.mk:203`；`crdroid-tree-fixes.py:842` | 镜像（`1791704075` 起）：10-11 实机 `dumpsys media.audio_flinger` 里 FastMixer 在跑，`mixPeriod=10.00 ms`。⬜ 没在发版构建上重测 Arcaea 的端到端延迟 |
| 触摸 | **game 预设**（默认）：关坐标平滑（省约 25 ms 稳态滞后）、debounce 1 帧、关手掌识别 | 跟手；贴着屏幕边缘平放的拇指不会被当成手掌丢掉 | `bin/gaokun3-touch-mode.sh`；默认值在 `device.mk:1054` 的 `persist.sys.gaokun3.touch_mode=game` | 镜像。`hand_enabled=0` 来自 PR #30（`29a61c9`），要求内核带 `patches/0082`，没有这个节点时跳过、不算失败。参数说明见 [`palm-rejection.md`](palm-rejection.md)、[`scripts/touch/README.md`](../scripts/touch/README.md) |
| 性能 | 后台 cpuset 限在 0-3 | 后台进程不跟游戏抢大核 | LIVE-5 / PERF-6 | 镜像（dev.9 起）。⬜ 用 `game-perf.sh` 对比前后帧率不降 |
| 性能 | `scripts/perf/game-perf.sh` | PERF-2 的帧率、温度、频率驻留、降频统计（只读） | 用法见脚本头注释与 [`release-checklist.md`](release-checklist.md) C1 | 脚本。⬜ 批 4 的游戏基线（三角洲 20 分钟、卡拉彼丘 10 分钟、明日方舟 30 分钟）和 UBWC A/B 都还没跑 |
| 环境 | **会话级"游戏模式"** `scripts/game-mode.sh` | 关 adb 和开发者选项、清理身份字段、隐藏 root 管理器、关掉证明伪造链 | §2 | 脚本 |
| 环境 | **netlink 隐私边界**（`patches/0084`） | 普通 App 能用 `RTM_GETLINK` / `RTM_GETNEIGH` 读到 wlan0 物理 MAC 和局域网邻居。AOSP 策略本来不允许，主线内核缺这套 remap | `kernel-apply-patches.sh:221-223` | 已在 KPATCHES ⇒ 下一个发版内核会带上。开发机 10-11 实测两条泄露都被拒（`EACCES`） |
| 环境 | **指纹变体段对齐**（tree-fix [23]） | `ro.build.type=user` 而 `Build.FINGERPRINT` 尾部写 `userdebug`，前后矛盾。`Build.FINGERPRINT` 常量由 zygote 预加载，运行时改不掉 | `crdroid-tree-fixes.py:748`、`:847` | 镜像（`1791704075` 起）：实机指纹 `…:user/release-keys` |
| 环境 | **去掉 swangle 的 sepolicy**；`PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER` 注释掉 | `system_server` 本不该有 `execmem`。早已改用 freedreno/turnip，SwiftShader 不再加载（10-11 全机 0 个进程映射它） | `BoardConfig.mk` sepolicy 一节（注释里有依据和回退办法） | `1791704075` 里已生效：Duck 报 `system_server execmem: Denied`。⚠️ 改动**还没提交**。回退到软渲染时，这个开关和 `ro.hardware.vulkan` 要一起改 |
| 环境 | **内核版本串覆写**（`patches/0085`） | Duck 的 KernelCheck 只认 4/5/6 开头的内核，7.x 直接判 DANGER | `kernel-apply-patches.sh` 的 KPATCHES 链尾 | 开发机上在跑；**10-11 用户定进发版内核**（版本串伪装，见 §4.1）。vermagic 不变 |
| 构建 | KernelSU `task_stack.h` include（原 `patches/0086`） | 7.2.9 ≥ 6.7 时这个 include 被版本门控跳过，10-11 构建机报 KSU 链接失败 | 改名 `patches/resukisu/0003-…`，由 `kernel-setup-resukisu.sh` 打、`release.sh` 核对（两版都要） | 本机对 pin `b2ac2fc` 的原文件 `--check` 过；⬜ 构建机 `kernel-setup-resukisu.sh --check`。为什么此前 7.2.9 不需要它没查清（README 0003 节） |

---

## 2. 游戏模式脚本（`scripts/game-mode.sh`）

Mac 侧的 `game-mode.sh` 把 `game-mode-device.sh` 推到设备上执行，需要 KSU root。所有改动可逆、不改镜像，状态和备份放在 `/data/local/tmp/gk3-game-mode/`。

| 子命令 | 做什么 | 怎么还原 |
|---|---|---|
| `identity` | 7 个指纹键（`ro.build` / `product` / `system` / `vendor` / `product.system` / `product.vendor` / `bootimage`）尾部的 `userdebug` 改成 `user`；删除 `ro.crdroid.version`。用 resetprop，不动 adb | 重启 |
| `install` / `uninstall` | 安装 / 卸载"开机自动跑 identity"（KSU `service.d`）。**`uninstall` 只卸这一项**，不会卸 App 或模块 | — |
| `on [分钟]` | identity，再关 adb（USB 和 TCP 5555）和开发者选项，同时启动自动还原定时器（默认 60 分钟） | 定时器到点、`off`、或开机兜底 |
| `off` | 立即还原全部（要求 adb 还连着） | — |
| `hide` / `unhide` | `pm uninstall --user 0` 卸载 `com.resukisu.resukisu`、`bin.mt.termex`（APK 先备份到 `apk/`）；把残留目录 `/sdcard/MT2` 改名收起 | `unhide` 从备份装回 |
| `noforge` / `forge` | 给 `tricky_store`、`playintegrityfix` 写 / 删 KSU 的 `disable` 标记，并当场杀掉 TrickyStore daemon。这样证明从"伪造的"变成"没有" | `forge`；zygisk 模块要重启才完全生效 |
| `status` | 列出各属性、设置、兜底和模块的当前状态 | — |

**使用要点**

* `on` 会断开 adb，之后就跑不了 `off`。分钟数要盖住整局游戏。万一回不来：按电源键重启，开机兜底 `/data/adb/service.d/gk3-game-mode-safety.sh` 会恢复 adb。
* **测游戏之前一定先 `on`**，否则开发者选项、USB 调试和 5555 会污染测试结果。
* ⚠️ **不要删 `ro.crdroid.device`**：`find-device.sh` 靠它认设备。
* ⚠️ **不要隐藏或卸载 `lineagesettings`**：10-11 卸过一次，system_server 循环崩溃，只能离线修 `system_a`（记在 memory 里的救砖记录）。

**实测踩过的坑**（都已在脚本里修掉，改脚本时别改回去）

1. macOS 自带的 bash 3.2 会把紧跟在 `$VAR` 后面的多字节字符吞进变量名（`$SERIAL：` 报 unbound variable）。Mac 侧脚本的变量一律写成 `${}`。
2. 定时器必须脱离 adb 会话（`trap '' HUP`，有 `setsid` 就再套一层）。否则 `stop adbd` 销毁 PTY 时会把定时器一起 SIGHUP 掉，adb 就再也回不来。
3. **resetprop 不会触发 init 的 `on property:` 钩子**：用它改 `persist.sys.usb.config` 不会让 USB gadget 重新枚举。USB 配置要用 `setprop`，并且要显式拉回 `sys.usb.config` 和 `service.adb.tcp.port`。
4. 开机兜底跑在 `service.d` 阶段时，SettingsProvider 可能还没起来：`settings put` 返回 0 却没写进去。兜底要先等 `sys.boot_completed`，写完读回校验，校验通过才删除标记（未提交的改动，2026-10-11）。

⬜ 还没上机验过：`noforge` / `forge`，以及新版开机兜底。`noforge` 按进程名 `daemon` 找 TrickyStore，再用 cwd 是否包含 `tricky_store` 确认，换了 TrickyStore 版本要重新核对。

---

## 3. 环境正常化的边界与 Duck Detector 结果

**边界**（用户 2026-10-10 定，细节见 [`duck-detector-plan.md`](duck-detector-plan.md) §0）：

| 类 | 做不做 | 内容 |
|---|---|---|
| A 如实修正 | 做 | 补上缺的字段，修正自相矛盾的字段，补主线内核漏掉的 AOSP 隐私边界 |
| B 证明伪造 | 不做 | 让 keybox / TrickyStore 伪造的 RootOfTrust、verifiedBootHash、TEE 指纹更逼真 |
| C 隐蔽工程 | 不做 | 抹 LSPosed / KSU 的残留、给 sepolicy 洗白、重新打包或改名 manager |
| D 会话级操作 | 做 | 由用户按游戏会话手动开关：关 adb、隐藏或卸载、`noforge` |

保留 KernelSU，不做不带 KSU 的游戏内核（用户 10-10 定）。设备上的 TrickyStore、keybox、PIF、HMA、LSPosed 是用户自己装的，不属于镜像。

**体检工具**：Duck Detector（Apache-2.0）。上游一遇到华为品牌就直接退出，所以体检用的是本地去掉这道门的版本。不改设备品牌，也不把改动提交回上游。

**结果变化**（报告都在设备 `/sdcard/duck_detector_report_*`，App Build 301）：

| 时间 | 环境 | DANGER / WARNING / READY | 变化 |
|---|---|---|---|
| 10-11 05:31 | dev.11，内核 7.2.9 | 5 / 5 / 18 | 基线：Bootloader、Kernel Check、LSPosed、Native Root、TEE |
| 10-11 14:47 | 换上 0084 + 0085 内核 | 2 / 7 / 18 | Kernel Check 变绿；Native Root 的两条 netlink 泄露消失，降为 WARNING；LSPosed 降为 WARNING，但原因是堆残留抖动，**不可复现，不算成果** |
| 10-11 16:09、16:26 | 新 ROM `1791704075`，但启动的是 **7.2.9 旧内核** | 4 / 5 / 18 | `system_server execmem` 变成 Denied（ROM 侧修复生效）；内核侧那两项退回 DANGER |
| 10-11 16:40 | `1791704075` + 0085 内核（直连槽条目） | **2 / 6 / 18** | 只剩 Bootloader、TEE 两项 DANGER |

**剩下的为什么不修**

* Bootloader / TEE：主因是 `verifiedBootHash` 全零（两张卡报的是同一条）和 TrickyStore generate 模式自身的指纹，属于 B 类。唯一如实的做法是 `noforge`：Play Integrity 会因此不通过，这是取舍，没法两全。
  `/proc/cmdline` 写的是 `orange` / `locked=0`，PIF 把运行时属性改成了 `green` / `locked=1`，两边矛盾也会被检出。改 cmdline 等于伪造 verified boot 状态，不做。
* KeyMint VINTF `NO_DECLARATION`：是检测器的盲区。声明在 APEX 里（`/apex/com.android.hardware.keymint/etc/vintf/`），Duck 只读 `/vendor/etc/vintf/`。在 vendor 里再声明一份会和 APEX 的声明冲突（`HalManifest.cpp:153`）。
* `ro.crypto.state=unsupported`：是实话（D3：`/data` 不加密）。
* Custom ROM、ADB、Root Manager、Dangerous Apps：会话前用 `on` / `hide` 处理（D 类）。其余是 crDroid 身份本身，不改包名。

**验收标准是游戏真能进，不是检测 App 全绿。** 目标游戏：Wild Rift / 英雄联盟手游（设备上装的是 `com.tencent.lolm`）。

---

## 4. 待定与风险（要用户看）

1. **0085 是伪装 → 用户 2026-10-11 定：进发版内核**（所有人的 `uname` 都会报 6.6.30-android15-8）。⬜ known-limitations 与发版说明要写明。
   * 7.2.9 是真的上游 stable 版本（[`build-machine.md`](build-machine.md) §6）。真实情况是 Duck 的 KernelCheck 只认得 4/5/6，不是"项目自定版本号"。
   * `6.6.30-android15-8-g0a4d3c12b3` 冒充的是 Android 通用内核（GKI）的版本串，末尾的 git 哈希是编出来的。构建署名 `android-build@abfarm-release` 同理。
   * **vermagic 不变**（v7.2.9 源码核过）：`VERMAGIC_STRING` 是编译期的 `UTS_RELEASE`（`include/linux/vermagic.h:41-42`）；模块校验比的是编进内核的静态串（`kernel/module/main.c:1105`、`:2658`）；0085 只改运行时的 `init_uts_ns`，`/proc/version` 读的也是它（`fs/proc/version.c:14`）。
     现在本机根本没有可加载模块（`/proc/modules` 0 行，没有 `/lib/modules`）。⚠️ 将来要发模块时注意：Android first-stage init 按 `uname` 的 major.minor 选 `/lib/modules/<目录>`（`first_stage_init.cpp:216-257`），内核报 6.6，找不到 `7.2.*` 目录。到时要用精确同名（`uname -r`）的目录。
   * 副作用**还没排查**：bpfloader、VINTF 内核兼容矩阵、KSU manager 显示的版本、bug report 读到 6.6 会不会走别的代码路径。
2. **原 0086 已收进 `patches/resukisu/0003`**，由 `kernel-setup-resukisu.sh` 打、`release.sh` 核对，不再只活在构建机工作区。
3. ⚠️ **新 ROM 和新内核还没合在一起**（推断，没在 ESP 上核对）：`1791704075` 打包的 `boot_b` 用的似乎还是 `prebuilt-boot/` 里的旧内核（16:09 的报告是 7.2.9）。0085 内核只能通过直连槽条目启动（本次开机 `vendor.gaokun3.bootentry.via=direct`）。走默认入口 `gk3boot.efi` 读的是 `boot_b`，会回到 7.2.9。要固化就得把 `prebuilt-boot/` 换成新内核再打包。
4. 10-11 的第一版 0085 内核 `03085d81…` 是用通用 defconfig 编的，已作废，**别用**。正确做法是以运行中的 `/proc/config.gz` 为底，`olddefconfig`，再跑 `kernel-config-android.sh` 断言（详见 `duck-detector-plan.md` 的"差点装了个起不来的内核"一节）。

---

## 5. 相关

* issue 案卷：#17 / #20（0078）、#33 / #34（GLES 与着色器缓存），见 [`TODO.md`](TODO.md) 的「GitHub issues」三节。
* 搁置项：原神 1080×1728 的渲染上限只能靠伪装机型突破，有账号风险，交给用户决定（TODO E 节）。
* 游戏音频基础延迟的剩余部分（AV-7 / B25）、PERF-2 基线：[`v1.0-plan.md`](v1.0-plan.md)。
* Play 保护认证（T2）与本文无关，那是 Android ID 登记。银行类 App 过不了 Play Integrity 是 UEFI 解锁带来的取舍。

---

## 6. 不分版（2026-10-11）

10-11 曾考虑把发版内核拆成"香草"（默认）和"巧克力"（游戏特化）两版。用户当天撤回：架构已经够复杂，而且自己一定用游戏那版。
⇒ **只发一个内核**，游戏向的内核改动（0078、0084、0085）都在 `KPATCHES` 主链里。当时调研过的做法（gk3boot 按条目选内核、misc 保留区计数回落、boot.img second 段 / ESP 存放）没有落地。以后要重提，先读这一节。

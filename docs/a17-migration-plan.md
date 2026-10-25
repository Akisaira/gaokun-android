# crDroid 13 / Android 17 迁移方案

起草 2026-10-25。

> **用户 10-25 已定**：① **1.0 正式版改在 A17 上发**（rc.1 / rc.2 的 A16 验收不再作为 1.0 的依据）；② **A16 不再维护**，构建机 `~/crdroid` 的 16.0 树就地改成 17.0，不加盘；③ **mesa 直接在 26.1 上用 `meson2hermetic` 重新生成**（路线 B）。下文第 4、5 节的选项分析保留作依据，以这三条为准。
本文所有上游事实都是当天抓原文得到的（raw 文件 / GitHub API / `git ls-remote`），抓下来的文件在会话 scratchpad，没入库。
**本地还没有任何 A17 源码树**，凡标「未核实」的，都要等构建机上 sync 出 17.0 树之后用 `grep` / `git apply --check` / `m` 确认。

## 1. 上游现状（已核实）

| 项 | A16（现在） | A17（目标） | 来源 |
|---|---|---|---|
| crDroid 分支 | `16.0`（crDroid 12.x） | `17.0`（`CR_VERSION := 13.0`，仓库默认分支已是 17.0） | `crdroidandroid/android@17.0`、`android_vendor_crdroid@17.0 config/version.mk:1-5` |
| Lineage 基线 | `lineage-23.2` | `lineage-24.0`（唯一 24.x 分支；10-11 Changelog 32 首发） | `default.xml:16` |
| AOSP tag | `android-16.0.0_r4`（BP4A.251205.006） | `android-17.0.0_r1`（CP2A.260605.016，06-16 发布） | `default.xml:14`、`build/make core/build_id.mk` |
| release config | `bp4a` | **`cp2a`**（`RELEASE_BOARD_API_LEVEL=202604`，SDK 37） | `vars/aosp_target_release` |
| lunch | `lineage_gaokun3-bp4a-userdebug` | `lineage_gaokun3-cp2a-userdebug`（按命名规律推断，未 lunch 过） | — |
| 包名 | `crDroidAndroid-16.0-…` | `crDroidAndroid-17.0-<日期>-<机型>-v13.0` | `version.mk` |
| 状态 | — | crDroid 13：09-28 beta 源码 → 10-11 正式推送；OTA 仓 49 台（Monthly 40 / Weekly 6 / BETA 2） | crdroid.net blog、`android_vendor_crDroidOTA@17.0` |

* AOSP 现在一年放两次源码（Q2 / Q4）。10-25 时 A17 只有 `_r1` 和 security `_r1/_r2`，**没有 QPR1**。等 Q4 源码放出来，Lineage / crDroid 很可能开 24.1 / 17.0-qpr 分支，到时基线还要再跟一次。
* `common_full_tablet_wifionly.mk` 仍在、内容不变；`BoardConfigLineage.mk` 只多了 `BUILD_BROKEN_SRC_DIR_RW_ALLOWLIST`。**A17 构建期源码树是只读的**，这个变化是真的在执行。

### 外部依赖

| 依赖 | A17 状态 |
|---|---|
| MindTheGapps | `cinnamonbun` 分支 = A17（`17_202606`），有 arm64 ⇒ local manifest 改分支即可 |
| `device/linaro/dragonboard` | `android-17.0.0_r1` 下 `shared/graphics` 的 tree id 与 16.0.0_r4 相同（`426f619a`），两个 sepolicy 目录原样在 |
| `external/mesa3d` | 25.3.0-devel → **26.1.0-devel**；`meson_to_hermetic` 删了，改为 `meson2hermetic`；freedreno / turnip 仍然没有接进 Android.bp |
| drm_hwcomposer | HWC3 composer3 V4 → V5 |
| minigbm | AIDL allocator V2 → V3 |
| 内核要求 | `kernel/configs` 的 202604 档（目录 `c/`）只有 android-6.18；`android-base.config` 是空文件，只有 `minlts="6.18.0"`。cgroups.json 与 A16 相同。没有强制 16K 页。7.2.9 高于下限，且我们本来就关了 VINTF 内核检查 |
| VINTF | 框架矩阵支持 FCM 7、8、202404、202504、202604 ⇒ 我们的 target-level 202504 仍合法。自建 HAL 的版本都在 202604 的范围内（light 2、thermal 3、usb 3、sensors 3、camera.provider 3、audio.core 4） |
| Root / 模块 | ReSukiSU 已改名 **Baka-SU/BakaSU**，HEAD 有 "support android17-6.18"，比我们钉的 `b2ac2fc8` 多 163 个提交。KernelSU 3.3、Next 3.4、SukiSU-Ultra 4.2、Vector 2.1、PIF 4.6 都写了支持 A17。**TrickyStore 没找到 A17 支持的证据** |

## 2. 本仓要改的东西（按风险排）

### 2.1 会挡住构建的

1. **mesa / turnip 是最大的一块。** 现在实际的做法是把构建机上那份**不入库的**归档包（`~/keep/mesa3d-patched.tar.zst`：mesa 26.0.3 + 0004 v3 + 已生成好的 Android.bp）整棵铺进 `external/mesa3d`，并没有在树上重跑生成管线。两条路：
   * **A：继续铺 26.0.3 归档。** 改动最小，但会冲掉 A17 自带的 `mesa_gfxstream_*` / `mesa_platform_virtgpu` 等模块；如果有别的模块按名字依赖它们，构建会断。归档里的 Android.bp 是按 A16 的 Soong 模块名生成的（glslangValidator、python mako / pyyaml 等），A17 一改名就编不过。（未核实）
   * **B：在 26.1 上用 `meson2hermetic` 重新生成。** 要重做 Stage 5 那 12 个管线坑，再 rebase 0004。
   * 推荐**先试 A**。A 能编过就先拿它把系统其他部分跑起来，B 作为后续的独立任务。另外，不管走哪条，都要先把归档备份进 R2：它现在只在构建机上有一份。
2. **`effects/Android.bp` 引用的 `:effectCommonFile` filegroup 在 A17 没了**，改成了 cc_library_static `libaudioeffectaidlcommon`。
3. **音频 HAL 补丁链**：A17 把 StreamAlsa 拆成了 `StreamAlsaBase` / `StreamAlsaMonoPipe` / `StreamAlsa` 三个文件。tree-fix 里 [14]（0052）、[15]（0063）、[17]（0069）、[21]（0077）、[22]（0083，音频延迟 317→110 ms 那条）打不上，要在新结构上重做。[22] 直接影响用户体验，重做完要复测延迟。
4. **tree-fix [23]（ROM 级指纹修正）**：A17 多了一个 `BUILD_SYSTEM_FINGERPRINT`，锚点从 2 处变成 3 处；注释里的错别字 "used used" 也被上游修掉了，锚点对不上。
5. **tree-fix [20]**：依赖的 Settings 锚点 `wifi_privacy_entries_ext` 没了，要重新评估这条还要不要。
6. **tree-fix [9]（patches/0003，glslang）应该删掉，不是 rebase。** A17 上游已经自带 cc_binary_host `glslangValidator`；继续打会和上游模块重名。删掉之后要确认 mesa 侧引用的名字能对上上游。
7. `AndroidProducts.mk`、脚本和文档里写死的 `bp4a` 都要改。

### 2.2 会悄悄失效的

* `crdroid-tree-fixes.py` 把「找不到文件」判成「跳过」、不算失败。迁移时要改成严格模式：所有条目要么生效，要么明确标为在 A17 上废弃。
* **[11] 路径写死了 `bp4a`。** 现在还生效，因为 cp2a → cp1a → bp4a 的继承链上那个文件仍在；但只要以后 cp* 覆盖了这个 flag，[11] 就会悄悄失效。改成沿 `TARGET_RELEASE` 的继承链去找。
* `PRODUCT_COPY_FILES` 里有 13 个源文件来自上游树（frameworks/av 的 audiopolicy 配置、frameworks/native 的 data/etc）。路径挪了会直接报错；内容变了会悄悄改变音频策略。
* `prebuilt-apps/fcitx5/Android.mk`、`AndroidBoard.mk`（从 `$(PRODUCT_OUT)/recovery.img` 取 ramdisk）是 Make 规则。A17 只要再收紧 Android.mk 的限制，输入法会静默消失，或者 OTA 里会缺 recovery ramdisk。
* `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES`：ramdisk 里的 `/lib/firmware/*.mbn`（GPU zap shader、DSP 固件）全靠这个开关。

### 2.3 运行时风险（只能上机发现）

| 区域 | 风险 |
|---|---|
| Wi-Fi | cp2a 打开了 `RELEASE_DISABLE_WIFICOND=true` 和 `RELEASE_WIFI_MAINLINE_SUPPLICANT_BINARY=true`；本机走的是 vendor wpa_supplicant + hostapd + libwifi-hal-emu |
| 图形 | 系统 GLES 是跑在 turnip 上的 ANGLE。A17 会带新 ANGLE，冻结在 26.0.3 的 turnip 能不能配合没核实；软渲染回退已经被关掉。drm_hwcomposer 的 `vendor.hwc.drm.device` 是从 A16 二进制里抠出来的，改名就会黑屏 |
| USB adb | A17 sepolicy 新增 policycap `functionfs_seclabel`，会影响 adb / MTP 的 functionfs 标签；7.2 内核支不支持没核实。**adb 是主要调试通道，上机前先确认** |
| 模拟 ACK 的内核补丁 | 0007（bpffs 惰性打标签）、0016（ashmem）、0017（xt_quota2）、0096（android_usb class）、0112（configfs UDC）都是对着 A16 用户态写的。A17 的 netd / BpfLoader / UsbDeviceManager / ashmem→memfd，以及新增的 Memory Limiter / mmd / PMGD 都要复核。0007 的先例是 system_server 循环崩溃 |
| 蓝牙 | 设备用的是 AOSP 默认 HAL，靠它先走 `NetBluetoothMgmt::openHci` 这个行为；profile 开关的 sysprop 名字是照 16.0.0_r4 写死的 |
| sepolicy | 类型名都还在。真正的风险是 A17 新增的 neverallow（vendor_init 读 system_prop、audioroute 的 execute_no_trans、gk3pend 写 kmsg 等），要 `m selinux_policy` 才知道 |
| 工具链 | 新 clang / libc++ 可能让冻结或钉死的第三方源码编不过（mesa 归档、libcamera 87c7285、hexagonrpc 435ed1c） |
| 32 位 | `TARGET_2ND_ARCH=arm` + 32 位 zygote 在 A17 和 cinnamonbun 上还支不支持，没有证据。老游戏依赖它 |

### 2.4 游戏环境（gaming.md / GAME-*）

* **0084（netlink remap）大概率可以去掉**：A17 sepolicy 打开了 policycap `netlink_xperm`，7.2 遇到它会直接走通用 nlmsg 扩展权限。但前提要先核实（A16 的 lineage-23.2 确实没开这个 policycap），而且隐私边界改由 AOSP 的 `unpriv_route_socket_nlmsgs` 决定，**必须用 Duck 复测**。
* 0085 的版本串（uname 报 6.6.30）是按 A16 / Pixel 8 Pro 的 PIF 选的。A17 的 libvintf / NetBpfLoad / mmd 里凡是按 uname 判门槛的地方，都要把 source-audit 任务 B 整体重跑一遍。
* TrickyStore：没找到 A17 支持的证据。KSU 换成 BakaSU HEAD 后，`patches/resukisu/0001-0003` 能不能打上要试。
* `game-mode-device.sh` 的 7 个指纹键，以及 PIF 指纹与 A17 补丁级别 / SDK 能不能自洽，都要复核。

### 2.5 `PRODUCT_SHIPPING_API_LEVEL` 保持 36

不要提到 37。提上去等于把设备当成 A17 新发布设备，会触发 memfd_class 强制、新的 VSR 和 VINTF 内核要求，而 7.2 不在任何 FCM 内核表里。只改 turnip 的 platform-sdk-version 和相关注释。

## 3. 发版与 OTA

* **crDroid Updater 会拦住跨大版本升级。** 清单里的 `os_sdk_level`（A17 = 37）大于本机 `SDK_INT`、又没设 `crdroid.updater.allow_major_upgrades` 时，Updater 判 `VERSION_UNSUPPORTED`，不让装（16.0 `InstallUtils.kt:25-31`，17.0 不变）。也就是说：把 A17 写进 `ota/gaokun3.json` 后，所有 A16 用户只会看到「无法更新」，而 A16 的修复版也推不出去了，因为清单一个设备只有一份。
* **`/data` 没有 checkpoint**（BATT-7 已定不做）。A17 首次开机如果起到一半失败，gk3boot 会回落到 A16 槽，但 `/data` 可能已经被 A17 改过；过了 zygote 才挂的话就回不去了。
* 所以 A17 应该**单独一个 OTA 清单 URL**（只在 A17 的 overlay 里改）。A16 → A17 的路径有两条：
  * 安装器「重新安装 + 保留数据」或清数据；
  * 以后某个 A16 版本预置 `allow_major_upgrades`，并先在开发机上演练一次「保留数据 OTA + 故意起不来 → 回落」。

## 4. 构建机

* 盘 504 GB。crDroid 源码 + `.repo` 约 190G，`out` 100–130G，估计现在剩 150–170G（**没 ssh 实测**）。**放不下第二棵完整树**（约 330G 以上）。
* 选项：① 挂一块独立数据盘（512G–1T），放 A17 树，迁完可删（推荐）；② 系统盘扩到 1T（只能扩不能缩）；③ 清掉 A16 的 `out/`，A17 用 partial clone。③ 仍然偏紧，而且 rc.2 之后的 A16 修复要重编时代价大。
* `sync-device-tree.sh:34`、`:98-198` 写死了 `~/crdroid`，要先参数化（比如 `CRDROID_TREE`）。不入库的 `~/iris-work/rom-build.sh` 也要查。

## 5. 时机

1.0 正式版还剩的几乎都是要用户在场或拍板的事（B4 真盘安装、B7 待机狗粮、B1、B2 密钥轮换、G10 发版说明定稿、仓库默认分支改 dev）。A17 和它们互不依赖。
**建议：1.0 正式版留在 A16 上发；A17 走并行树、单独的分支和 OTA 渠道，作为 1.1（或 2.0）。**
如果反过来让 1.0 等 A17，前面 rc.1 / rc.2 的验收全部作废，而且 Q4 的 A17 QPR1 源码一出来，基线又要跟一次。

## 6. 步骤

| 步 | 内容 | 在哪做 | 验收 |
|---|---|---|---|
| M0 | 本仓准备：`~/crdroid` 参数化；tree-fixes 严格模式 + 按分支选条目；local manifest 出 A17 版（cinnamonbun）；`bp4a` 改为按代际选 | 本机 | 脚本在 A16 树上行为不变 |
| M1 | 构建机加盘，`repo init -b 17.0` + sync；mesa 归档备份进 R2 | 构建机 | `lunch lineage_gaokun3-cp2a-userdebug` 能过 |
| M2 | 在 17.0 树上把 tree-fix 和补丁逐条 `--check`；重做 [14][15][17][20][21][22][23]，删 [9] | 构建机 / 本机 | tree-fixes 严格模式全绿 |
| M3 | 修设备树（effects、Make 规则、COPY_FILES）；先走 mesa 路线 A；`m selinux_policy` | 构建机 | `m` 产出 super / boot |
| M4 | 上机，先 oneshot 进另一个槽，A16 槽留作回落：adb → 图形 → 触摸 → Wi-Fi → 音频 → 蓝牙 → 传感器 → 相机 → 挂起 | 设备（**要用户在场**） | release-checklist A 档 |
| M5 | 游戏环境：BakaSU、0084 / 0085 复审、Duck、PIF / TrickyStore | 设备 | gaming.md 的检测项 |
| M6 | mesa 路线 B（26.1 重新生成）、内核 ACK 模拟补丁复核 | 构建机 | turnip CTS 子集 / game-perf |
| M7 | 发版：单独的 OTA 清单、安装器、发版说明 | — | 用户点头 |

## 7. 进度

| 步 | 状态（2026-10-25） |
|---|---|
| M0 | ✅ 分支 `a17-migration`：cp2a lunch 项、manifest（cinnamonbun）、tree-fixes 严格模式、`sync-device-tree.sh` 不再删 fcitx5 APK |
| M1 | ✅ 没加盘，`~/crdroid` 就地 `repo init -b 17.0 --git-lfs` + sync（A16 不入库的输入先备份到 `~/keep`）；`lunch lineage_gaokun3-cp2a-userdebug` 过 |
| M2 | ✅ tree-fix [1]–[25] 在真树上全打上；[9] 废弃；新增 [24]（adb_root 只随 WITH_SU）、[25]（KeyGestureController 包 LineageSettings 读取，补 10-11 救砖时没入库的那一处） |
| M3 | ⏳ 音频补丁按 A17 的 StreamAlsa 拆分重写、effects 改用 `libaudioeffectaidlcommon`；sepolicy 静态编译过；libcamera 树准备入库为 `scripts/camera/setup-libcamera-tree.sh`；第一次冷编卡在 `libcamera_gk3` 未定义，修后第二次冷编进行中 |
| M6 | ✅ 提前做了：mesa 26.1 用 meson2hermetic 重新生成（`scripts/mesa-a17/`，check-output 全过，490 个模块），0004 改成 v3、0005 不用 |
| M4 / M5 / M7 | ⬜ 要等 M3 出镜像；M4 首次上机要用户在场（0085 的 6.6.30 版本串会让 A17 netd 走 BPF 模拟的 L4S 路径，自检失败就会进 netd1shot 重启循环） |

`prebuilts/build-tools` 下 A16 树删过 `date` / `tar` 两个预编译件，A17 没有编码这一步，冷编要看会不会因此报错。

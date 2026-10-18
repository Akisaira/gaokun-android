# V5 出处核对 + GAME-1（0085 版本串伪装）副作用排查

2026-10-18。全部只读：构建机 `vahiru@74.225.248.96` 上只用 grep / sed / cat / git log / git show / git diff，没跑任何构建命令，没改任何文件。
本机只写了本文件（原在 `out/v5-game1-findings.md`，10-18 入库为 `docs/source-audit-20261018.md`）。设备没碰。
例外说明：任务 A-5 核 `PRODUCT_CHARACTERISTICS` 时对构建机 `out/target/product/gaokun3/system/build.prop` 做过一次只读 grep（`ro.build.characteristics=tablet`），没写任何东西。

行号一律是**构建机上的实际路径**。各树的版本：

| 树 | HEAD |
|---|---|
| `~/crdroid/system/libbase` | `bdf0f4db82` (2025-08-20) |
| `~/crdroid/system/vold` | `ebff65bce2` (2026-04-09) |
| `~/crdroid/build/make` | `f677d20362`（crdroid/16.0，2026-06-14）；工作区 `core/config.mk` 带 tree-fix [23]（`git diff` 只这一处） |
| `~/crdroid/packages/apps/Settings` | `57f8d3535b5`（crdroid/16.0，2026-07-02） |
| `~/crdroid/frameworks/native`（SF） | `da1214c0a2` (2026-06-29) |
| `~/crdroid/packages/modules/adb` | `262cc9ad` |
| `~/crdroid/packages/modules/Connectivity` | `6abc5cd5c3` |
| `~/crdroid/art` | `663e2bf7bf` |
| `~/gk3-kernel-72y` | v7.2.9（Makefile），工作区已打 0085（`init/version.c:59-65`） |
| `~/gk3-kernel-72y/KernelSU` | ReSukiSU `b2ac2fc8` |
| 本机 `refs/aosp-build` | `android-16.0.0_r4`（`b815dded1e`） |

---

## 任务 A：V5

### A-1 `system/libbase/file.cpp`：写失败后 errno 保留吗？——**保留，可信**

* 两参 / 三参版 `WriteStringToFile`（`file.cpp:310-319`）：
  * `open` 失败直接 `return false`（`:315-317`），errno 就是 `open` 的。`unique_fd` 析构里的 `close` 不动 errno：`include/android-base/unique_fd.h:108-121` 先存 `previous_errno`、close 后还原。
  * `write` 失败走 `WriteStringToFd(...) || CleanUpAfterFailedWrite(path)`（`:318`）；`CleanUpAfterFailedWrite`（`:272-278`）在 `unlink` 前后保存 / 还原 errno。之后 `unique_fd` 析构的 close 也还原 errno。
  * ⇒ 返回 false 时 errno 就是 `open()` 或 `write()` 失败的那个值。
* 带 mode/owner 的六参版（`:281-306`）同理，只是自己先打一条 `PLOG(ERROR)`。`PLOG` / `LOG` 本身也不改 errno（`include/android-base/logging.h:259` 的 `ErrnoRestorer`）。
* ⚠️ 顺带发现的副作用：写失败后 libbase 会对目标路径 **`unlink()`**（`file.cpp:275`）。写 sysfs 节点失败时这个 unlink 也会失败（errno 已还原，不影响判断），但在 enforcing 下可能多出一条 HAL 域对 sysfs 的 `unlink` / `remove_name` avc 拒绝。V9 做 avc 普查时，如果 lights / health 写失败那一刻冒出这类拒绝，就是这个原因，不用加 allow。
  另外 `O_CREAT`（`:312`）已核，与 `sepolicy/init.te:26` 的说法一致。

**本仓引用处：**

| 位置 | 现状 | 要改吗 / 怎么改 |
|---|---|---|
| `device/huawei/gaokun3/health/ChargingControl.cpp:89` | `// errno 可能被 WriteStringToFile 内部的 close 覆盖，只作参考。` | **要改（说法不对）**。改成：`// WriteStringToFile 失败时 errno 是 open/write 的原值（libbase file.cpp:272-278 与 unique_fd.h:108-121 都会还原），PLOG 可信。失败后它还会 unlink 目标路径，对 sysfs 无害。` |
| `device/huawei/gaokun3/lights/Lights.cpp:108` | `const int err = errno;  // 先存下来，后面的日志调用会改 errno` | 可不改，代码是对的。注释想精确的话改成：`// 先存下来（LOG 本身不改 errno，但 strerror 等之后的调用不保证）`。 |
| `docs/TODO.md:214` V5 行 | 待核 | 回填「✅ 10-18 构建机核实：errno 保留（file.cpp:272-278、unique_fd.h:108-121）」。 |

### A-2 vold：`DiskSource::matches` 的 fnmatch flags 与 `vold.has_reserved`

* **fnmatch flags = 0**：`system/vold/VolumeManager.h:70-72` 的 `return !fnmatch(mSysPattern.c_str(), sysPath.c_str(), 0);`。没有 `FNM_PATHNAME`，`*` 能跨 `/`。fstab 里的反汇编结论（7 处 `mov w2, wzr`）与源码一致。
* 匹配对象是 uevent 的 `DEVPATH`（`/devices/...`，不带 `/sys`），而且只处理 `DEVTYPE=disk`：`VolumeManager.cpp:210-222`。
* `DiskSource` 的来源是 fstab 里带 `voldmanaged` 的行，第一列原样作为 pattern：`main.cpp:274-302`（`sysPattern(entry.blk_device)` 在 `:275`，`addDiskSource` 在 `:300-301`）。
* **`vold.has_reserved`**：vold 自己设的。`main.cpp:155` 写 `SetProperty("vold.has_reserved", configs.has_reserved ? "1" : "0")`；`has_reserved` 在 `process_config`（`main.cpp:239` 起）里求值，规则是**fstab 里任意一行 `reserved_size > 0` 就为真**（`:250`、`:256-258`）。读这个属性的是 `frameworks/base/core/java/android/os/storage/StorageManager.java:149`（`PROP_HAS_RESERVED`）。
  ⇒ 它只说明 fstab 写了 `reservedsize=`，**不能**证明 tune2fs 真改了保留块。

**本仓引用处：**

| 位置 | 要改吗 / 怎么改 |
|---|---|
| `device/huawei/gaokun3/fstab.gaokun3:48-52` | 结论对。出处可补上源码：「依据：crDroid `system/vold/VolumeManager.h:70-72`（`fnmatch(..., 0)`），匹配对象是 DEVPATH 且只看 DEVTYPE=disk（`VolumeManager.cpp:210-222`）；本机 `/system/bin/vold` 反汇编也一致（7 处 `mov w2, wzr`）」。lineage recovery 那条 refs 出处可留可删。 |
| `device/huawei/gaokun3/fstab.gaokun3:31` | 「（vold.has_reserved 随之变 1）」改成「（vold 见到 fstab 里有 reservedsize 就设 vold.has_reserved=1，`system/vold/main.cpp:155/256-258`；它反映的是配置，不是 tune2fs 的结果）」。 |
| `docs/release-checklist.md:74`（A25） | 判据里的 `` `1` `` 留着，但要注明它只证明 fstab 行在：「`vold.has_reserved=1` 只说明 fstab 有 reservedsize（vold main.cpp:256-258），保留块以 tune2fs 那两行为准」。 |
| `docs/v1.0-plan.md:112`（STOR-1） | 「先在构建机 system/vold 里确认 fnmatch 的 flags」这一步已完成，可改为「✅ 10-18 已核：flags=0（VolumeManager.h:71），写一行通配即可」。 |
| `docs/TODO.md:214` | 回填。 |

### A-3 crDroid `build/make/core/sysprop.mk` / `config.mk` 与 `refs/aosp-build`：引用到的那几行**内容一致，行号整体后移**

先找了本仓是谁引用、引用了哪几行，再只比这些行（crDroid 文件副本在 `out/v5-tmp/crdroid-build-core/`）。

| 引用（本仓） | refs/aosp-build 行 | crDroid 行 | 内容 |
|---|---|---|---|
| `scripts/release.sh:333` `sysprop.mk:208`（vendor/build.prop 生成） | `:208` | **`:216`** | 一致（`INSTALLED_VENDOR_BUILD_PROP_TARGET := $(TARGET_OUT_VENDOR)/build.prop`） |
| `scripts/release.sh:334` 「同文件 :119」（规则只依赖属性文件） | `:119` | **`:127`** | 一致（`$(2): $(POST_PROCESS_PROPS) $(INTERNAL_BUILD_ID_MAKEFILE) $(3) $(6) $(BUILT_KERNEL_VERSION_FILE_FOR_UFFD_GC)`） |
| `scripts/release.sh:334` `config.mk:870 BUILD_DATETIME_FROM_FILE` | `:870` | **`:874`** | 一致（`$$(cat $(BUILD_DATETIME_FILE))`，运行时才 cat） |
| `device.mk:315` `sysprop.mk:198`、`device.mk:731` / `stage4-findings.md:9008` `sysprop.mk:194-205` | `:193-205`（`PRODUCT_VENDOR_PROPERTIES` 在 `:198`） | **`:201-213`**（`:206`） | 一致 |
| `device.mk:729` / `stage4-findings.md:9007` `product.mk:92-93` | `:92-93` | `:92-93` | 一致 |
| `BoardConfig.mk:300` `config.mk:1268-1270`（BOARD_VNDK_VERSION 清空） | `:1268-1270` | **`:1335-1337`** | 一致 |
| `BoardConfig.mk:302` `config.mk:773-782`（FULL_TREBLE 只读） | `:773`、`:778-781` | **`:777`、`:782-785`** | 一致 |
| `crdroid-tree-fixes.py:712` `config.mk:1308`（BUILD_FINGERPRINT） | `:1308` | **`:1371`**（未打 [23]）；打了 [23] 的现工作区是 `:1376`，THUMBPRINT `:1391` | 锚点 `:$(TARGET_BUILD_VARIANT)/$(BUILD_VERSION_TAGS)` 在原文件里正好 2 处，[23] 的断言成立 |

* ⇒ release.sh 的 OTA-11 推理（规则只依赖属性文件、日期运行时 cat ⇒ 增量构建不重生成）**在 crDroid 上同样成立**。
* crDroid 对 sysprop.mk 的改动（与 refs 的 diff 只有 `generate-common-build-props` 这一段，sysprop.mk 第 32-90 行附近）：
  ① 整段包进 `bash -c` 并先执行 `$(PRODUCT_BUILD_PROP_OVERRIDES)`，`ro.product.<分区>.device/model/name` 与 `ro.<分区>.build.fingerprint` 可被同名环境变量覆盖；
  ② `ro.<分区>.build.type` **非 eng 一律写 `user`**；
  ③ `BUILD_NUMBER` 以 `eng.` 开头时 incremental 改成日期秒数。
  这几行本仓没有引用，但 ② 解决了下面这条悬案。
* **顺带解决 `lineage_gaokun3.mk:109-110` 的"两说"**：`build/soong/scripts/gen_build_prop.py:28-32` 是 `Eng ? "eng" : "user"`，没有 userdebug 分支。这是 crDroid 自己的提交，不是 AOSP：soong `45aecb5b2`、build/make `74b87074f7`，都叫 "Turn off debug props on userdebug builds"，作者 Pranav Vashi，2025-10-24。AOSP 原版 `2da72af53` 有 `return "userdebug"`，被这个提交删了。⇒ "crDroid 改了一半"那一说对：type 改了，fingerprint 没改（我们的 [23] 补上了）。

**本仓引用处：**

| 位置 | 怎么改 |
|---|---|
| `scripts/release.sh:337` | 「（行号取自 refs/aosp-build，crDroid 16 的 build/make 待构建机核实…）」改成「（行号取自 refs/aosp-build；10-18 构建机核过 crDroid 16 `f677d20`：同一内容在 sysprop.mk:216 / :127、config.mk:874，逻辑一致）」。:333-334 的行号可以顺手换成 crDroid 的。 |
| `device.mk:315`、`device.mk:731`、`stage4-findings.md:9008` | 写的是 refs 行号且注明了 refs，可不改；想统一就加「（crDroid 16 为 :201-213 / :206）」。 |
| `BoardConfig.mk:300-302` | 「已对 AOSP 16 源码核实」没错；可补「crDroid 16 为 config.mk:1335-1337 / :777-785」。 |
| `crdroid-tree-fixes.py:712`、`:739-740` | `config.mk:1308` → 「refs :1308 / crDroid 16 :1371」；`:739-740` 那条 ⚠️ 可改成「10-18 核过：crDroid 16 原文两处锚点俱在，[23] 已在构建机工作区生效」。 |
| `lineage_gaokun3.mk:109-110` | 「两说哪个对待构建机核实」改成「10-18 核实：是 crDroid 自己的改动（soong `45aecb5b2` / build/make `74b87074f7`，"Turn off debug props on userdebug builds"），gen_build_prop.py:28-32 与 sysprop.mk 的分区 build.type 都被改成非 eng 即 user；指纹那头没改，由 tree-fix [23] 补齐」。同时 `docs/TODO.md` 里"另有一说"那条可以合并。 |
| `docs/TODO.md:214` | 回填。 |

### A-4 内核 configfs：写 UDC 失败后 gadget 留不留在 pending？——**不留，内核不会自动绑**；adb 能回来靠的是 adbd 每秒重试

代码路径（`~/gk3-kernel-72y`，v7.2.9）：

1. 写 `UDC`：`drivers/usb/gadget/configfs.c:271-313` `gadget_dev_desc_UDC_store`。先置 `udc_name = name`（`:299`），再调 `usb_gadget_register_driver`（`:300`）。失败就把 `udc_name` 清成 NULL、kfree、返回错误（`:301-303`、`:309-312`）。
2. configfs 的 gadget 驱动是 `.match_existing_only = 1`（`configfs.c:1985`）。
3. `usb_gadget_register_driver_owner`（`drivers/usb/gadget/udc/core.c:1740-1772`）：`driver_register` 同步 probe（`PROBE_FORCE_SYNCHRONOUS`，`:1751`）。没绑上（`!driver->is_bound`）时，因为 `match_existing_only`，打 `couldn't find an available UDC or it's busy` 并返回 `-EBUSY`（`:1760-1765`），接着 **`driver_unregister`**（`:1770-1771`）。
   UDC 在但 bind / start 失败（`gadget_bind_driver` 的错误路径，`:1641-1705`）也一样：`is_bound` 回到 false，最后同样被注销。
4. ⇒ 失败后 gadget 总线上**没有** configfs 的驱动，`udc_name` 也空了。之后 UDC 再出现（dwc3 切回 device，`usb_add_gadget` → `device_add` → 总线 match），没有驱动可以匹配，**内核不会自己绑**。没有"pending"状态。
   （非 `match_existing_only` 的驱动才会留在总线上等，`:1766-1768` 的 `couldn't find an available UDC` + `ret = 0` 那支；configfs 不走这支。）
5. 已经绑着时再写同一个 UDC：`configfs.c:295-297` 直接 `-EBUSY`，不碰现有绑定 ⇒ **不断连**。`init.gaokun3.usb.rc:67` 里"UDC 那半句待上机核实"，源码层面已经确认。

谁会重写 UDC（crDroid 用户态）：

* `system/core/rootdir/init.usb.configfs.rc:20-24`：`sys.usb.ffs.ready=1 && sys.usb.config=adb && sys.usb.configfs=1` 时写 `UDC ${sys.usb.controller}`。
* adbd 每秒自己重来：`packages/modules/adb/daemon/usb.cpp:274-282`，没绑上时等 `FUNCTIONFS_BIND` 只等 1 秒，超时就 break；`usb.cpp:742-766` 循环重开 functionfs；`usb_ffs.cpp:302` 每次 `SetProperty("sys.usb.ffs.ready","1")`。同值 setprop 也会触发：`system/core/init/property_service.cpp:433` 无条件 `NotifyPropertyChange`。
* 暂停开关：`usb.cpp:735-755`。**注意顺序**：先 `open_functionfs`（这时已经 ffs.ready=1，会触发一次写 UDC），再查 `sys.usb.adb.disabled`，为真才停在 `PropertyMonitor`。所以 host 期间每次 adbd 重进循环仍会有**一次**写 UDC 失败，之后不再每秒重试。
* ⇒ **结论**：只要 adbd 在跑、`sys.usb.config=adb`、`configfs=1`，并且切回 device 后 `sys.usb.adb.disabled` 能回到 0（`usbrole.sh` 的 `adb_gate`，`gaokun3-usbrole.sh:67-83/149/176`；USB 端口 HAL 的 `usb/Follow.cpp:22`、`:187`），USB adb 会在约 1–2 秒内自己回来：解除暂停 → 等 1 秒 BIND 超时 → 重开 ffs → ffs.ready=1 → init 写 UDC（此时 UDC 已在）→ 绑上。
  靠的是用户态重试，不是内核里留着 pending。如果 `adb.disabled` 停在 1（属性链断了），USB adb 就**不会**回来。V11 要盯的是这个，不是内核。

**本仓引用处：**

| 位置 | 怎么改 |
|---|---|
| `device/huawei/gaokun3/bin/gaokun3-usbrole.sh:52-53` | 结论对。行号按 v7.2.9 更新：`configfs.c:1985` ✓、`configfs.c:295-303` ✓；`udc/core.c:1733-1737` → **`udc/core.c:1760-1765`**（失败后注销驱动在 `:1770-1771`）。"linux v7.2-rc2" 改成 "linux v7.2.9（~/gk3-kernel-72y）"。本地 `refs/linux-v7.2-rc2` 没有 `drivers/usb/gadget`，rc2 的行号核不了。 |
| `device/huawei/gaokun3/init.gaokun3.usb.rc:38-39` | 「USB adb 能不能自己回来，取决于 gadget 有没有挂上 —— 未实测」改成：「内核不留 pending（configfs.c:300-303 + udc/core.c:1760-1771：失败即注销驱动），能回来靠 adbd 每秒重开 ffs → ffs.ready → init.usb.configfs.rc:23 重写 UDC；前提是切回 device 后 sys.usb.adb.disabled 回到 0。源码结论，V11 上机确认」。 |
| `device/huawei/gaokun3/init.gaokun3.usb.rc:66-67` | 「（UDC 那半句待上机核实）」改成「（UDC 已绑定时重写同名 UDC 在 configfs.c:295-297 直接 -EBUSY，不碰现有绑定 —— 源码已核）」。 |
| `docs/TODO.md:205`（V11）/ `:215` | V11 判据加一条：「切回 device 后 `getprop sys.usb.adb.disabled` 应为 0，并在 2 秒内出现 `UDC` 绑定（`cat /config/usb_gadget/g1/UDC` 非空）」。V5 那条回填。 |

### A-5 crDroid 16 Settings 实际菜单文案

出处：`packages/apps/Settings/res/xml/top_level_settings.xml`（`top_level_settings_expressive.xml` 标题用的是同一组字符串，`TopLevelSettings.java:359-362` 二选一）、`res/values{,-zh-rCN}/strings.xml`、`res-product/values{,-zh-rCN}/strings.xml`、SettingsLib 与 framework 的字符串。
vendor/lineage、vendor/crdroid、device 下都**没有** overlay 覆盖这些字符串（grep 过）。本机 `PRODUCT_CHARACTERISTICS := tablet`（`lineage_gaokun3.mk:293`；构建产物 `ro.build.characteristics=tablet`），所以 `product="tablet"` 的变体生效。

**对得上的**（不用改）：

| 文档里的路径 | 实际（英 / 中） | 出处 |
|---|---|---|
| Settings → About tablet | About tablet | `res-product/values/strings.xml`（`about_settings` product=tablet） |
| Settings → System → Developer options | System / 系统 → Developer options / 开发者选项 | `top_level_settings.xml:160-164`、`system_dashboard_fragment.xml:134-136`、`development_settings_title` |
| USB debugging / USB 调试 | 一致 | SettingsLib `enable_adb`；`development_settings.xml:180-181` |
| Wireless debugging / 无线调试；Pair device with pairing code / 使用配对码配对设备 | 一致 | SettingsLib `enable_adb_wireless`、`adb_pair_method_code_title`；`development_settings.xml:189-190` |
| Battery → Standby (sleep) → Allow standby；电池 → 待机（睡眠）→ 允许待机 | 一致 | 顶层 `power_usage_summary_title` "Battery"/"电池"（`top_level_settings.xml:150-154`）；Parts 注入 `ia.battery` → `PowerUsageSummary`（`DashboardFragmentRegistry.java:86-87`，`CategoryKey.java:35`）；Parts `res/values{,-zh-rCN}/strings.xml:37/39` |
| System → Startup options；系统 → 启动选项 | 一致（只在 HAL 报可用时启用，`parts/AndroidManifest.xml:183-205`） | Parts `strings_boot_options.xml:5` / zh `:3` |
| System → Keyboard → On-screen keyboard；系统 → 键盘 → 屏幕键盘 | 一致 | `keyboard_settings`="Keyboard"/"键盘"；`keyboard_settings.xml:24-27` → `virtual_keyboard_category`="On-screen keyboard"/"屏幕键盘" |
| System → Reset options；系统 → 重置选项 | 一致 | `reset_dashboard_title`；`system_dashboard_fragment.xml:146-147` |
| Speaker enhancement (experimental)；扬声器增强（实验性） | 标题一致（所在页面名不对，见下表） | Parts `strings.xml:12` |

**对不上的**（要改）：

| # | 文档位置 | 文档写法 | 实际文案 | 出处 | 建议改写 |
|---|---|---|---|---|---|
| 1 | `docs/FAQ.zh-CN.md:259`、`docs/INSTALL.zh-CN.md:305`、`docs/known-limitations.zh-CN.md:135` | 「关于平板电脑」 | **「关于本机」**（中文 tablet / default 都是这个） | `res-product/values-zh-rCN/strings.xml` `about_settings` product=tablet | FAQ：`**设置 → 关于本机**，连续点"Build 号"7 次…`；INSTALL：`中文界面是"设置 → 关于本机 → Build 号"`；known-limitations：`设置"关于本机 → Android 版本"里的内核版本` |
| 2 | `docs/FAQ.zh-CN.md:259`、`docs/INSTALL.zh-CN.md:305` | 「版本号」 | **「Build 号」** | `res/values-zh-rCN/strings.xml` `build_number`；条目在 `my_device_info.xml:250`（关于本机页底部，`firmware_version.xml:81-82` 也有一个） | 见上 |
| 3 | `docs/known-limitations.md:123`、`docs/known-limitations.zh-CN.md:135` | 内核版本在 *Settings → About tablet* | 在 **About tablet → Android version → Kernel version**（关于本机 → Android 版本 → 内核版本） | `my_device_info.xml:152-154`（firmware_version 入口）、`firmware_version.xml:73-74`；`firmware_version`="Android version"/"Android 版本"，`kernel_version`="Kernel version"/"内核版本" | 英：`…and *Kernel version* under *Settings → About tablet → Android version* all say…`；中：`设置"关于本机 → Android 版本"里的"内核版本"都显示…` |
| 4 | `README.md:53`、`README.zh-CN.md:43`、`docs/release-checklist.md:98`（B5）、`parts/AndroidManifest.xml:73` 注释 | *Settings › Sound* / 「设置 › 声音」 | **Sound & vibration** / **「提示音和振动」** | `top_level_settings.xml:87-91`；`sound_settings`；`ia.sound` → `SoundSettings`（`DashboardFragmentRegistry.java:92-93`） | 英：`in *Settings › Sound & vibration*`；中：`在"设置 › 提示音和振动"里`；B5：`设置 › 提示音和振动里的开关` |
| 5 | `docs/FAQ.md:150`、`docs/FAQ.zh-CN.md:148`（及 `:147` 注释） | *Take bug report* / "错误报告" | **Bug report** / **「Bug 报告」** | `development_settings.xml:33-35` 用 `@*android:string/bugreport_title`；`frameworks/base/core/res/res/values/strings.xml:805` / zh-rCN `:284` | 英：`Whether *Bug report* in Developer options works…`；中：`开发者选项里的"Bug 报告"在这台机器上…` |
| 6 | `docs/INSTALL.md:577`、`docs/INSTALL.zh-CN.md:419` | *Erase all data* / 清除所有数据 | **Erase all data (factory reset)** / **「清除所有数据（恢复出厂设置）」** | `main_clear_title` | 小问题，建议写全：`Settings → System → Reset options → *Erase all data (factory reset)*（设置 → 系统 → 重置选项 → 清除所有数据（恢复出厂设置））` |
| 7 | `.github/ISSUE_TEMPLATE/01-bug.yml:71-72`、`03-hardware.yml:79`、`04-game-app.yml:73` | *Settings → About* / 「设置 → 关于」的"版本那一行" | 页面是 **About tablet / 关于本机**，那一行标题是 **crDroid version / 「crDroid 版本」** | `my_device_info.xml:161-163`；`lineage-sdk/lineage/res/res/values{,-zh-rCN}/strings.xml` `lineage_version` | 英：`the *crDroid version* line in *Settings → About tablet*`；中：`「设置 → 关于本机」里"crDroid 版本"那一行`。值的格式（`v12.11-20261003`）源码里没核，需要真机确认 |

* 文档里"菜单名没核对"的注释可以撤掉或改写：`docs/FAQ.zh-CN.md:255`、`docs/known-limitations.zh-CN.md:371`（"菜单名还没在本机核对"；键盘那条路径已核对上，只差"Fcitx5 在不在列表里"要上机看）、`docs/known-limitations.md:374`、`docs/INSTALL.zh-CN.md:7`（Android 部分可以去掉"待核实"，Windows 部分仍待核）。
* 我不确定的：crDroid 的 expressive 主题开关（`SettingsThemeHelper.isExpressiveTheme`）实机上是哪套布局。两套 xml 的顶层标题字符串相同（`top_level_settings_expressive.xml:78/151/161/170`），只是排列可能不同，不影响路径名。

### A-6 `dumpsys SurfaceFlinger --latency` 的格式与窗口——**本机这一版不是 128 帧**，game-perf.sh 的窗口假设要改

* 入口：`SurfaceFlinger.cpp:6412` → `dumpStats`（`:6467-6477`）。第一行是 pacesetter 的 vsync 周期（ns，`:6468`）；只有给了图层名才继续，按名字**精确匹配** legacy layer。
* 每个图层的输出取决于 aconfig 标志 `deprecate_frame_tracker`（`Layer.cpp:615-632`）：
  * **标志开（本构建）**：`build/release/aconfig/bp4a/com.android.graphics.surfaceflinger.flags/deprecate_frame_tracker_flag_values.textproto` = `ENABLED`，`READ_ONLY`；flag 定义 `surfaceflinger_flags_new.aconfig:92-101`，`is_fixed_read_only: true`。
    走 `Layer::getFrameStats` → `FrameTimeline::generateFrameStats`（`Scheduler/FrameTimeline.cpp:1474-1496`）。每行 `desired\tactual\tready`（`Layer.cpp:626`，`std::format("{}\t{}\t{}\n")`），结尾一个空行。
    * 窗口 = FrameTimeline 保存的最近 **`kDefaultMaxDisplayFrames = 64`** 个 **display frame**（`FrameTimeline.h:559`；超出就 `pop_front`，`FrameTimeline.cpp:1558-1562`）。是 SF 合成帧数，不是该图层的帧数：
      120 Hz 下全帧率游戏约 **0.53 秒**；游戏 60 fps 而 SF 只在有新 buffer 时合成，则接近 1.07 秒。
    * 只输出 `presentTime > 0` 的 display frame（`:1483-1485`），**不会出现 0 / INT64_MAX**。按从旧到新的顺序。
    * 坑：再用一个计数 `count = mFrameStatsHistorySize` 截断，而且是从**最旧**的 display frame 开始数（`:1478-1481`）。这个计数是 `std::atomic<uint16_t>`（`Layer.h:444`），每帧 `++`（`Layer.cpp:1470`），只有 `--latency-clear` 才清零。
      ⇒ 图层每过 65536 帧（120 fps 约 9.1 分钟，60 fps 约 18 分钟）计数回绕，之后约 64 帧内输出只剩最旧的几帧，甚至为空。game-perf.sh 会把它记成一次 GAP，不会算错帧率，但 20 分钟的采样里会有 1–2 个 GAP 是 SF 自己造成的。
  * 标志关（旧路径，AOSP 早期 / 其他配置）：`FrameTracker::dumpStats`（`FrameTracker.cpp:165-178`）。`NUM_FRAME_RECORDS = 128`（`FrameTracker.h:42`），但只输出 **127 行**（`i = 1..127`，跳过当前槽）；未填的槽是 0、未上屏的是 `INT64_MAX`（`:72-74`）。本仓脚本里"128 帧、去掉 0 与 INT64_MAX"描述的是这一支。
* 对照 `scripts/perf/game-perf.sh`：
  * 解析本身没问题：`NF == 3` 跳过首行周期，取第 2 列；`$2>0 && $2<9e18` 两种路径下都安全；排序去重也不受顺序影响（`:141-147`）。
  * **窗口假设错了**：`:12-14`、`:175` 与 `README.md:25-26` 都按 128 帧 / 1.067 秒设计，一轮是 `sleep 0.5` + 一次 adb + 宿主机 awk/sort。实际窗口约 0.53 秒（120 fps），每轮耗时会超窗，GAP 会成常态。TCP adb 更明显。
  * 建议：把 `sleep 0.5` 降到 `0.2`；或者改成在设备上一个常驻 `adb shell` 里循环 `dumpsys SurfaceFlinger --latency …; sleep 0.25`，流式读回，省掉每轮 adb 的往返。
    不建议用 `service call SurfaceFlinger` 改 `MaxDisplayFrames`（`SurfaceFlinger.cpp:7483-7494` 那个调试码）：它改状态，违背脚本"只读"的约定。
  * 上机判据：`dumpsys SurfaceFlinger | grep deprecate_frame_tracker` 应为 true（FlagManager 的 dump，`common/FlagManager.cpp:157`）；跑一次 `--latency <图层>` 数数据行，应 ≤ 64。

**本仓引用处：**

| 位置 | 怎么改 |
|---|---|
| `scripts/perf/game-perf.sh:12-14` | 改成：「`--latency <图层名>`：首行是 vsync 周期；之后每行 desired / actual present / frame ready（ns）。crDroid 16（bp4a）开着 `deprecate_frame_tracker`，数据来自 FrameTimeline 最近 **64 个 SF 合成帧**（FrameTimeline.h:559），120 Hz 下约 0.53 秒，只含已上屏的帧；旧 FrameTracker 路径才是 127 行、含 0 / INT64_MAX。每 65536 帧计数回绕一次会短暂输出变空（Layer.h:444），记成 GAP」。 |
| `scripts/perf/game-perf.sh:139` 注释、`:175` 注释与 `sleep 0.5` | 注释改成"64 帧 / 0.53 秒"；`sleep` 降到 0.2（或改常驻 shell）。 |
| `scripts/perf/README.md:25-26` | 「只给最近 128 帧，120 Hz 下约 1.067 秒」→「只给 FrameTimeline 最近 64 个合成帧，120 Hz 下约 0.53 秒（crDroid 16 的 deprecate_frame_tracker 已开）」。 |
| `docs/TODO.md:101`（V14 "game-perf.sh 图层名与 128 帧窗口"）、`:215` | 改成"64 帧窗口（源码已核，待上机数行数）"；V5 回填。 |
| `docs/stage5-freedreno.md:386` | 历史记录，不改。 |

---

## 任务 B：GAME-1（0085 伪装 `6.6.30-android15-8-g0a4d3c12b3`）

### 伪装范围（已核）

* `init/version.c:59-65`：`pure_initcall` 里 `strscpy(init_uts_ns.name.release, …)`。只改 **release**，`version`（`uname -v`）、`machine` 不变。
* 跟着变的：`uname()` / `uname -r` / `/proc/sys/kernel/osrelease`（`kernel/utsname_sysctl.c:94`）/ `/proc/version`（`fs/proc/version.c:12-15` 读 `utsname()->release`）。
* 不变的：`linux_banner`（dmesg 第一行，`init/version-timestamp.c:24-25` 用编译期 `UTS_RELEASE`）、`LINUX_VERSION_CODE`、vermagic。
* 所有按 `uname` 判断的用户态代码都会看到 6.6.30，而且是 GKI 格式（`-android15-`）。
* ⚠️ 开发机现状（CLAUDE.md）：默认入口起的是 `boot_b` 里的 7.2.9，0085 内核只能走直连槽条目 + oneshot。下面所有上机验证都要先 `uname -r` 确认是 6.6.30。

### 逐处排查

| # | 位置（构建机） | 读的是什么 | 6.6.30 vs 7.2.9 | 影响 | 上机验证 |
|---|---|---|---|---|---|
| 1 | **NetBpfLoad**：`packages/modules/Connectivity/bpf/headers/include/bpf/KernelUtils.h:30-42`（`uname().release`，**可被 `ro.bpf.kver_override` 覆盖**）、`:88-108` | release 的 x.y.z | 门槛全部 ≤6.1（`isAtLeastKernelVersion` 4.9/4.14/4.19/5.4/5.10/5.11/5.13/6.0；`NetBpfLoad.cpp:1607-1636`）。≥6.7 / ≥6.13 / ≥6.2 那几条只对 32 位内核或 32 位用户态生效（`:1649`、`:1698`、`:1723`），本机两者都是 64 位。**唯一差别**：`isLtsKernel()`（`KernelUtils.h:98-108`），7.2 不在 LTS 表里 | 7.2.9 时 NetBpfLoad 打 W "Android V+ only supports LTS kernels." + E "Unsupported kernel version (7020009)"，但**不致命**（`NetBpfLoad.cpp:1661-1671` 只置 bad 打日志）；6.6.30 时这两行消失。功能无差别 | `logcat -b all -d \| grep -E "LTS kernels\|Unsupported kernel version"`：0085 下应无，7.2.9 下应有；`dumpsys netd` / 流量统计照常 |
| 2 | **bpf 程序的 min/max kver**：平台 bpfloader `system/bpf/loader/bpfloader.rs:428-447`（同样认 `ro.bpf.kver_override`）、`Loader.cpp:355-369/495-516`；Connectivity 程序 `bpf/progs/*.c` | 同上 | 所有程序的版本区间：上限只有 `INF` 或 ≤5.4（`netd.c:647-700`、`clatd.c:255/265`），下限 ≤6.1（`tcpAccECN.c`、`libmemevents/bpfprogs/bpfMemEvents.c:112-140` 的 `KVER_6_1`）。没有一条落在 (6.6, 7.2] | 两种版本加载的程序集**完全相同** | 可选：`ls /sys/fs/bpf/ \| wc -l` 两个内核下对比 |
| 3 | **libvintf**：`system/libvintf/RuntimeInfo-target.cpp:89-112`（`uname().release`）→ `RuntimeInfo::parseGkiKernelRelease`（`RuntimeInfo.cpp:144-184`） | release 按 GKI 格式解析 | 7.2.9-gaokun3 解析失败，回落到纯版本号，kernel level = UNSPECIFIED，再由 `VintfObject.cpp:674-689` 取 device manifest 的 level（`manifest.xml:34` target-level 202504，`HalManifest.cpp:813-825`）。**6.6.30-android15 解析成功**：kernel level = **V (202404)**（`RuntimeInfo.cpp:185-215`），与 manifest 的 202504 不同 ⇒ `VintfObject.cpp:685-687` 打 WARNING "uname() reports kernel level … but device manifest sets kernel level …"，并且以 V 为准 | kernel level 只影响合并框架矩阵时收哪些 `<kernel>` 段（`CompatibilityMatrix.cpp:365-371`：低于设备 level 的矩阵只加 kernel，且要 ≥ kernelLevel）。V 档是 6.1 / 6.6，B 档是 6.12（`kernel/configs/v`、`kernel/configs/b`），不重叠，合并不会冲突。<br>运行时唯一的全量检查 `Build.isBuildConsistent()`（`Build.java:1731-1742`）→ `verifyBuildAtBoot`（`android_os_VintfObject.cpp:146-157`）带 `disableKernel()`，**不比内核**；apexd 的 vendor apex 检查关了 RuntimeInfo（`apexd_vendor_apex.cpp:79-85`）；构建期内核检查本来就关着（`lineage_gaokun3.mk:312`）。⇒ 预期**无功能影响**，只多一条 WARNING | `logcat -b all -d \| grep -E "reports kernel level\|Vendor interface is incompatible\|verifyBuildAtBoot"`：前者预期 0085 下出现，后两者不应出现；开机不应弹"设备内部出现问题"（`ActivityTaskManagerService.java:6985-7010` 走 `isBuildConsistent`） |
| 4 | **KernelSU 内核侧**（`~/gk3-kernel-72y/KernelSU/kernel`） | 版本分支全是编译期 `LINUX_VERSION_CODE`（不受 0085 影响）。运行时改 uname 的两条路：`supercall/dispatch.c:1101-1170`（`CHANGE_SPOOF_UNAME`，要 `CONFIG_KSU_TOOLKIT_SUPPORT`）与 `:1023-1027`（`CMD_SUSFS_SET_UNAME`，要 `CONFIG_KSU_SUSFS_SPOOF_UNAME`） | `.config`：`# CONFIG_KSU_TOOLKIT_SUPPORT is not set`（:6945）、`# CONFIG_KSU_SUSFS is not set`（:6952） | 两条都没编进来，**不会与 0085 叠加或互相覆盖** | 无需 |
| 5 | **ksud（KMI 检测）**：`KernelSU/userspace/ksud/src/boot_patch.rs:82-117` | `rustix::system::uname().release()` 用正则抽 `androidNN` + x.y | 7.2.9-gaokun3 没有 `androidNN`，失败后回落 `/vendor/lib/modules`，本机没有 ⇒ 报错；6.6.30-android15 ⇒ **KMI = `android15-6.6`** | `ksud boot-info current-kmi` 会报 android15-6.6。管理器里"安装 / LKM 修补 / late-load"会去选 `android15-6.6_kernelsu.ko`（`late_load/mod.rs:57-69`），以及 init_boot/boot 分区（`boot_patch.rs:208-228`）。这个 .ko 的 vermagic 与本机 `7.2.9-gaokun3` 不符（`CONFIG_MODULES=y`，内核会拒载），而且本机 KSU 是内置的（`CONFIG_KSU=y`）。**用户不该点这些入口**。不点就无害 | `su -c "ksud boot-info current-kmi"`（预期 android15-6.6）；管理器首页应显示内置 / GKI 模式而不是 LKM |
| 6 | **ReSukiSU 管理器**：`manager/.../Kernels.kt:10-31`、`KernelRepository.kt:21-33` | `Os.uname().release` | `isGKI()` 对 major>5 一律 true，两种版本结果相同；只有显示的版本号变成 6.6.30 | 无（设备上装的管理器是用户自装的版本，逻辑大体相同但没逐行核） | 管理器首页看内核版本 |
| 7 | **first-stage init 模块目录**：`system/core/init/first_stage_init.cpp:215-257` | `uname().release` 的 major.minor，或与 release 同名的目录 | 6.6 找不到 `7.2.*` 目录 | 本机目前没有 `/lib/modules`，**现在无影响**（gaming.md §4.1 已写）。将来发模块要用 `uname -r` 精确同名目录（`:234-241` 那条优先、无回落） | — |
| 8 | **init 的 `ro.kernel.version`**：`system/core/init/init.cpp:702-712` | major.minor | 值从 `7.2` 变成 `6.6` | 平台里的消费者只有 `rootdir/init.rc:687-693`（只认 4.9 / 4.14 / 4.19 / 5.4），两种值都不命中；frameworks/base、Connectivity、Settings 里没 grep 到读它的代码。第三方 App 能读到（这正是伪装的一部分） | `getprop ro.kernel.version` |
| 9 | **ART**：`art/libartbase/base/utils.cc:162-180` `IsKernelVersionAtLeast`；`memfd.cc:40-50`；`gc/collector/garbage_collector.cc:463`；`mark_compact.cc:105/137/367` | major.minor | 门槛 3.12 / 3.17 / 4.14 / 4.17 / 5.7 / 5.13 / 5.16 / 6.0 / 6.1，两种版本同分支 | 无 | — |
| 9b | **ART CMC 的 UFFDIO_MOVE 安全探测**：`mark_compact.cc:1135-1193` | release 的 major.minor | 这是**唯一真正分叉的地方**：`(major,minor) <= (6,6)` 时（`:1149`），ART 认定这是 GKI 6.1/6.6，要用"附加模式位"（6.6 是 `1ull<<63`，`:1160-1166`）探测内核有没有带 MOVE 的修复补丁。主线 7.2 不认这个位：`mm/userfaultfd.c:4251-4253` 对未知 mode 返回 -EINVAL ⇒ 探测失败 ⇒ **不用 MOVE，退回 COPY**。真实 7.2.9 时直接返回 true、用 MOVE | 只影响 GC 性能（COPY 比 MOVE 多一次拷贝），不影响正确性：`CHECK_EQ(errno, EINVAL)` 正好满足，不会 abort。⚠️ 但构建机当前 `~/gk3-kernel-72y/.config:1048` 是 `# CONFIG_USERFAULTFD is not set`（这份 .config 10-18 08:28 被另一流程改过，**不确定是否就是发版配置**）。若发版内核也没开 USERFAULTFD，ART 根本不走 CMC/uffd，这一条完全不生效 | `zcat /proc/config.gz \| grep USERFAULTFD`；`getprop ro.dalvik.vm.enable_uffd_gc`；flag `use_uffd_move_ioctl_cmc_gc`（`art/build/flags/art-rw-flags.aconfig:31-40`，`is_fixed_read_only: false`，bp4a 没有覆盖值文件，默认值我**不确定**） |
| 10 | **fs_mgr / libdm / libsnapshot / vold** | major.minor | overlayfs userxattr ≥5.15（`fs_mgr.cpp:2492-2511`）、dm 空设备 uevent ≥5.15（`libdm/dm.cpp:768-777`）、ublk ≥6.1（`libsnapshot/capabilities.cpp:29-39`）、io_uring ≥5.6 / defer task ≥6.1（`snapuserd/utility.cpp:56-80`）、blk-crypto sysfs ≥5.18（`vold/FsCrypt.cpp:241-248`） | 全部同分支，无影响 | — |
| 11 | **Connectivity 其它**：`tcutils.cpp:500`（5.11）、`com_android_net_module_util_ServiceConnectivityJni.cpp:107`（6.0）、`BpfNetworkStats.cpp:138`（5.10）、`netd/BpfHandler.cpp`（≤5.10）、`BpfMap.h`（≤5.10） | 同 #1 | 同分支 | 无 | — |
| 12 | **lmkd / libprocessgroup** | — | `system/memory/lmkd`、`system/core/libprocessgroup` 里没有任何 uname / 内核版本判断（grep 零命中）。lmkd 用的 libmemevents bpf 程序门槛是 6.1（#2） | 无 | — |
| 13 | **调试产物**：Settings 内核版本（`KernelVersionPreferenceController.java:35`、`KernelVersionPreference.kt:64` 读 `/proc/version`；`DeviceInfoUtils.java:72` 用 `Os.uname()`）、bugreport（`dumpstate.cpp:871`）、tombstone（`tombstone_proto.cpp:883`）、dropbox 头（`BootReceiver.java:267`）、clatd 日志（`clatd/main.c:305-309`） | release / `/proc/version` | 全部显示 6.6.30 | 不是功能问题，但**用户发来的 bugreport / tombstone 里内核版本是假的**。好在 `uname -v`（构建时间戳）不变，`dmesg` 第一行是真的 | 见下面"文档建议" |
| 14 | **本仓脚本** | `uname` | `scripts/verify-kernel-ota.sh:31-33` 断言 `7\.x\.y-rcN-gaokun3`，rc 时代就已经过时，0085 下也必然 FAIL；`verify-root.sh:21`、`game-perf.sh:89`、`standby-sampler.sh:97` 只打印（后两者用 `uname -v`，不受影响） | 仅本仓工具 | — |

**一句话**：AOSP / crDroid 里按内核版本切换行为的地方，门槛几乎都 ≤6.1，6.6.30 和 7.2.9 走同一分支。真正分叉的只有三处：
(a) libvintf 的 kernel level 变成 V，多一条 WARNING，运行时不比内核，无功能影响；
(b) NetBpfLoad 的"非 LTS"告警消失；
(c) ART 的 UFFDIO_MOVE 探测会失败、退回 COPY，只影响性能，且前提是内核开了 USERFAULTFD，构建机现 .config 没开。
另有两个需要提醒用户的点：ksud 会把 KMI 认成 `android15-6.6`，别在管理器里点 LKM 安装 / 修补；bugreport / tombstone 里的内核版本是假的。

### 建议的上机核对清单（0085 内核下，先 `uname -r` 确认是 6.6.30）

1. `logcat -b all -d | grep -E "reports kernel level|Vendor interface is incompatible|LTS kernels|Unsupported kernel version"`：预期只有第一种。
2. 开机无"设备内部出现问题"弹窗。
3. `zcat /proc/config.gz | grep -E "USERFAULTFD"`、`getprop ro.dalvik.vm.enable_uffd_gc`：决定 #9b 是否有意义。
4. `su -c "ksud boot-info current-kmi"`：预期 `android15-6.6`。
5. `getprop ro.kernel.version`：预期 `6.6`。
6. 若想让平台的 bpf 加载器用真实版本（目前没必要），有现成的 `ro.bpf.kver_override`（`KernelUtils.h:36-39`、`bpfloader.rs:429-432`）。⚠️ 它是 `ro.` 属性，App 也读得到，等于在系统属性里留下真实版本，与伪装目的冲突，**不建议设**。

### 本仓要改的文档（GAME-1）

| 位置 | 建议 |
|---|---|
| `docs/gaming.md:117`（§4.1 "副作用还没排查"那条） | 改成：「副作用已按源码排查（10-18，out/v5-game1-findings.md → 建议摘进 stage4-findings 案卷）：bpf 加载与程序集不变（门槛 ≤6.1；NetBpfLoad 的非 LTS 告警反而消失）；libvintf 把 kernel level 认成 V(202404)，只多一条 WARNING，运行时检查不比内核；KSU 内核侧无按 uname 的分支，ksud 会把 KMI 认成 android15-6.6（别用管理器的 LKM 安装）；ART 的 UFFDIO_MOVE 探测会退回 COPY（仅当内核开了 USERFAULTFD）；bugreport / tombstone / 设置里的内核版本都是 6.6.30。⬜ 上机核对 5 项」。 |
| `docs/TODO.md:110`（GAME-1 行） | 「⬜ 排查 bpfloader / VINTF 内核矩阵 / KSU 读到 6.6 后的行为」改成「✅ 源码排查（10-18）：无功能影响，见 gaming.md §4.1；⬜ 0085 内核下上机核对 5 项（logcat 两条、USERFAULTFD、ksud KMI、ro.kernel.version）」。 |
| `docs/known-limitations.zh-CN.md:133`（注释里的 ⬜ 待核） | 换成上面的结论摘要。正文"替代办法"建议加一句：「KernelSU 管理器会把内核认成 android15-6.6，请不要使用其中的"安装 / LKM 修补"功能（本机的 KernelSU 是内置的）」。英文 `known-limitations.md:131` 同步。 |
| `known-limitations{,.zh-CN}.md` 的"现象"（:123 / :135） | 设置里的位置按 A-5 #1/#3 改成"关于本机 → Android 版本 → 内核版本"。 |
| `.github/ISSUE_TEMPLATE/01-bug.yml:69`、`03-hardware.yml:77`、`04-game-app.yml:69` | 命令里的 `uname -a` 可以保留（`-v` 那段构建时间戳是真的，能区分内核构建），但建议补 `getprop ro.vendor.gaokun3.version`，并在说明里加一句：「uname 显示的 6.6.30 是伪装，真实版本以 ROM 版本为准」。 |
| `scripts/verify-kernel-ota.sh:33` | 断言早已过时（rc 时代的正则）。改成按 `uname -v` 或 `ro.vendor.gaokun3.version` 判断，或者删掉这一条。 |
| 发版说明（rc.2 定稿时，TODO GAME-1 ⬜ 那项） | 除"版本号是伪装"外，建议点到 ksud / KSU 管理器 KMI 误判这一条。 |

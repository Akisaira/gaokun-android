# MateBook E Go（gaokun3）fastboot 设计

> **状态**：设计稿，尚未实现，也还没上机。日期 2026-10-04。
> **起因**：用户 2026-10-04 定 **D4：做一个 fastboot**（`docs/v1.0-plan.md:85`、`:316`），由它承接 B6 恢复出厂（OTA-4 / INST-13 / SEC-8 / BKUP-8）、`adb reboot bootloader|fastboot`，以及 `fastboot -w / flash / update / set_active`。
> **依据**：4 份摸底（启动链、recovery、USB/分区、live）、3 套方案（A recovery 内 fastbootd / B UEFI 层 fastboot / C′ ESP 常驻 initramfs）、3 份评审（风险 / 体验 / 成本）。正文引用沿用摸底和评审里核对过的 `文件:行号`；本文写作时补核了 `refs/lineage-bootable-recovery/fastboot/fastboot.cpp:75-115`、`recovery_ui/screen_ui.cpp:1585-1603`、`refs/lineage-system-core/init/init.cpp:1165-1190`、`init/reboot.cpp:975-995`、`fs_mgr/libsnapshot/snapshot.cpp:4195-4240`、`snapshot.proto:131-157`、`scripts/boot-oneshot.sh`。
> **其他相关决定**：D2 保留 test-key 并披露、D6 保留 root 管理器、D7 不发 vanilla。D1（发布版关 `ro.debuggable`）、D3（`/data` 不加密、如实写明）用户没有反驳，按计划建议执行。
> **冲突优先级**：实机实测 > 案卷 > 本文。凡标"待构建机核实""待 Xn"的，在核实前都不能当作事实。

---

## 1. 目标与范围

### 1.1 1.0 必须支持

| 类别 | 内容 | 说明 |
|---|---|---|
| 入口 | 设置 → 系统 → 重置 → **清除所有数据** | 必须真的擦掉；不能执行时必须让用户看到原因，不能像现在这样静默失败（B6） |
| 入口 | `adb reboot bootloader`、`adb reboot fastboot` | 两者都进同一个 fastboot 环境 |
| 入口 | `adb reboot recovery` | 本机没有 recovery，落到同一环境里的"恢复菜单" |
| 入口 | 开机菜单（systemd-boot）里的 `gaokun3 fastboot` 条目 | 接键盘盖时可选；不接键盘能否操作待测（INST-18） |
| 入口 | U 盘介质（`build-usb.sh`）上的同名条目 | 内置盘起不来时用 |
| 命令 | `getvar`（含 `all`）、`download`、`flash`（raw / sparse）、`erase`、`-w`、`set_active`、`reboot` / `reboot-bootloader` / `reboot-fastboot` / `reboot-recovery`、`flashing unlock\|get_unlock_ability`、`snapshot-update cancel`、`update <zip>`（协议层）、少量 `oem` | 详见 §4.5 |
| 安全 | 只暴露我们自己的分区；刷 boot 后同步 ESP；`set_active` 拒绝切到不可启动的槽；VAB 状态守卫；全程不挂起 | 详见 §4.10 |

### 1.2 1.0 明确不做

- **`flashing lock`**。设备恒为"解锁"：cmdline 写死 `androidboot.verifiedbootstate=orange`，上游判据见 `refs/lineage-system-core/fastboot/device/utility.cpp:197-199`。
- **`fastboot boot <img>`**。需要 kexec，评审在实机 `/proc/config.gz` 里没有看到 `CONFIG_KEXEC*=y`（体验评审，本文写作时设备离线，未复核）。
- **逐个刷逻辑分区**（`flash system_a` 等）、`update-super`、`create/resize/delete-logical-partition`。1.0 只支持整块刷 `super`。
- `fetch`、`upload`、`sideload`、gsi、发布版的 fastboot over TCP（只在测试构建里打开）。
- **安全擦除**（NVMe Deallocate / Sanitize）。1.0 的恢复出厂不是安全擦除，必须披露（见 §4.6）。
- AOSP recovery、recovery 内的 fastbootd（方案 A）。#39 未解，1.0 不走这条路。
- UEFI 层 USB fastboot（方案 B 完整版）。
- **开机按住音量下进 fastboot、连续启动失败自动进 fastboot**。1.0 之后由 B3 第一步的"轻量分派器"承担（§3.3）。
- Debian live 作为 fastboot 宿主。
- 中文界面。Linux VT 字体画不了 CJK，1.0 界面只用英文，INSTALL 里给中文对照（§4.8）。

### 1.3 术语

| 术语 | 含义 |
|---|---|
| BCB | misc 偏移 0–2 KiB 的 `bootloader_message`（`refs/lineage-bootable-recovery/bootloader_message/include/bootloader_message/bootloader_message.h:67-77`） |
| OneShot | systemd-boot 的 EFI 变量 `LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f`（`scripts/boot-oneshot.sh:19-20`）。只对下一次启动生效，用掉后回到 default |
| 意图记录 | 本设计新增，放在 misc vendor 区，由 Android 侧写入，记录"这次重启是 Android 发起的、要进什么"（§4.2.6） |
| 迁移标记 | 本设计新增，和意图记录放在同一结构里，标志"存量 BCB 已经清理过一次"（§4.6.4） |
| fastboot 环境 | ESP 上的 `gaokun3-fastboot.conf` 条目启动后的整个系统：内核 + 静态 initramfs + `gk3-fastbootd` |

---

## 2. 现状与约束

### 2.1 引导链

- 固件走回落路径 `EFI/BOOT/BOOTAA64.EFI`，也就是 systemd-boot。每个槽一个 BLS 条目 `<machine-id>-android-<a|b>.conf`，加载 `/<mid>/android/slot_<x>/{Image,gaokun3.dtb,ramdisk.img}`。loader.conf 内容是 `timeout 15 / console-mode keep / editor no / default *-android-a.conf`（`scripts/live/installer-lib.sh:899-920`、`:948-953`）。
- systemd-boot **只看 loader.conf 的 `default` 通配**。boot_control HAL 把 misc 当作真相源，同时把槽位镜像进 loader.conf：`setActiveBootSlot` 写 ESP 失败时整个调用失败；`markBootSuccessful` 每次开机都重写 default（`device/huawei/gaokun3/boot_control/EspSlot.cpp:45-47`、`:142-194`；`BootControl.cpp:114-161`）。⇒ **任何 fastboot 条目都不能做 default**。
- HAL 找 ESP 的办法：先试 by-name，再按"含 `loader/entries/*-android-*.conf`"识别（`EspSlot.cpp:37-40`、`:56-108`）。⇒ fastboot 条目的文件名**不能匹配** `*-android-*.conf`。
- systemd-boot 版本推断为 Debian `257.13-1~deb13u1`（`scripts/live/packages-live.lock:333`），没有从 ESP 上读到。本地没有 systemd 源码。
- 开发机 ESP（300 MiB）约剩 46 MB。固件自己占约 70 MB 的 `Persisted_Capsules.bin`；postinstall 要求空闲空间加上将被覆盖的旧文件 > 56 MiB（`device/huawei/gaokun3/bin/gaokun3-ota-postinstall.sh:114`；`installer-lib.sh:52` 的 `GK3_ESP_OTA_NEED_KIB=57344`）。

### 2.2 重启意图到不了下一次启动

- init 的处理（`refs/lineage-system-core/init/reboot.cpp:899-965`）：
  - `reboot,bootloader` 写 BCB `bootonce-bootloader`；如果 BCB 已有命令，报 "Bootloader command pending"，照样重启（`bootloader_message.cpp:234-246`）。
  - `reboot,fastboot`：本机 `ro.boot.dynamic_partitions=true`，写 `boot-recovery` + `recovery\n--fastboot`，目标改为 recovery。
  - `reboot,recovery`：BCB 为空时才补写 `boot-recovery`（`:923-937`）。
- 写完 BCB 之后，`HandlePowerctlMessage` 依次执行 `StopSendingMessages` → `ClearQueue` → 排 `shutdown` 触发器 → 排 `shutdown_done`（DoReboot）（`reboot.cpp:982-992`，本文已复核）。
- 内核层面：qcom-pon 的 reboot-mode 没有任何 mode，实机 `reboot_modes` 读出 ENODATA；cmdline 带 `efi=noruntime`；arm64 `machine_restart` 走 `efi_reboot(…, NULL)` 加 PSCI，不带 cmd（`refs/linux-v7.2-rc2-git` 的 `arch/arm64/kernel/process.c:130-151`、`drivers/firmware/psci/psci.c:309-319`）。⇒ **reboot 字符串会被丢弃**。
- systemd-boot 不读 misc。⇒ 今天 `adb reboot bootloader/fastboot/recovery` 和恢复出厂**最后都按 default 回到 Android**。
- **Android 能写 EFI 变量**：走高通 TZ 的 uefisecapp，不依赖 runtime services（`CONFIG_EFIVAR_FS=y`、`CONFIG_QCOM_QSEECOM_UEFISECAPP=y`；#42；`scripts/boot-oneshot.sh:8-15`）。写法：属性 0x07 + UTF-16LE 条目文件名（含 `.conf`）+ 双 NUL；覆盖前要 `chattr -i`；写完回读。OneShot 已经多次实测在下次开机被消费、之后回到 default（#42、#73）。
- Android 默认不挂 efivarfs。核心策略和设备策略里都没有 efivarfs 的类型和 genfscon，目前只在 ksu 域（permissive）里验证过。

### 2.3 BCB 无人消费，会一直残留

- normal boot 里没有任何代码清 BCB。`clear_bootloader_message` 只有 recovery、install、uncrypt、fastbootd 进入时才调用（`recovery.cpp:150,304`、`install/install.cpp:453`、`uncrypt/uncrypt.cpp:556-558`、`fastboot/fastboot.cpp:96`）。
- 开发机 BCB 现在全是零，因为 M4b 重装时安装器把整块 misc 清零了（`installer-lib.sh:838-843`）。**不能据此推断用户机器也一样**：用户机器上可能留着几个月前误点的 `boot-recovery --wipe_data`。
- `get_misc_blk_device` 只认 fstab 里 `mount_point == "/misc"` 的那一行（`bootloader_message.cpp:50-66`）。本机 fstab 有这一行，misc = `nvme0n1p4`（起始扇区 34，1007 KiB），标签 `misc_block_device`。
- misc 布局：0 是 BCB；2 KiB 是 vendor space（2–4 KiB 放 `bootloader_control`，开发机读到魔数 `BCAB`、后缀 `_a`、nb_slot 2）；16 KiB 是 wipe package；32 KiB 是 system space（virtual_ab、memtag 等）（`bootloader_message.h:24-36`）。`bootloader_control` 的结构体布局**本地没有源码**，待构建机核实。

### 2.4 recovery 与 #39

- 独立 recovery.img 能造出来，它的 ramdisk 随 vendor 下发（`/vendor/boot/recovery-ramdisk.img`，14,974,339 字节），postinstall 会铺到 ESP。默认不建启动项，实机 `persist.vendor.gaokun3.recovery_entry` 为空（`BoardConfig.mk:52-57`、`AndroidBoard.mk:20-24`、`gaokun3-ota-postinstall.sh:146-187`）。
- #39：用 oneshot 启动 recovery 后进入复位循环，pstore 和 last_log 都是空的，根因至今未解（`docs/stage4-findings.md:758-860`）。
- 现在这份 recovery ramdisk 里**没有 fastbootd、没有 `init.recovery.gaokun3.rc`、没有任何 vendor HAL、没有 `/lib/firmware`**（recovery 摸底解包核对）。recovery 的 init.rc 在 early-init 把 `sys.usb.configfs` 设为 0（`refs/lineage-bootable-recovery/etc/init.rc:13`），所以 recovery 里 USB adb 和 fastboot 都不可能出现。
- 本机 boot HAL 是 `vendor: true`，没有 recovery 变体（`boot_control/Android.bp:21-25`）。

### 2.5 分区与命名

- 实机 `/dev/block/by-name` 有：`boot_a→p5`、`boot_b→p6`、`esp→p1`、`metadata→p10`、`misc→p4`、`super→p8`、`userdata→p2`、`ubunturescue→p3`，另有整盘 `nvme0n1`。没有 by-partuuid，也没有 by-uuid。安装器建分区时 PARTLABEL 用的是标准名，并做了查重（`installer-lib.sh:388-400`、`:323`）。"PARTLABEL 不唯一"只针对 Windows 建的分区（`Basic data partition`）。
- 新装机和开发机的分区号不同（`sepolicy/file_contexts:134-137`），所以**不能按分区号写死**。
- 没有 recovery 分区，也没有 fastboot 分区；userdata 吃满了剩余空间，已装机器无法再切分区。
- 上游 fastbootd 对 by-name 下的**任何**节点都放行 flash/erase，判据只有 `access(W_OK)`（`utility.cpp:95-105`、`:150-165`），包括整盘和 ESP。本机是 permissive，SELinux 拦不住。

### 2.6 动态分区与 VAB

- super 是单块、不带后缀的 Virtual A/B（不压缩）。实机 lpdump：组 `gaokun3_dynamic_partitions_a`，上限 12,683,575,296 字节；slot0 只有 `*_a` 和 `*_a-cow`；`snapshotctl` 显示 `Update state: none`。
- **`_b` 实际起不来**：
  - misc 里 `slot_info[1]` 推断为 `0x0e`（不可启动、未标记成功；布局待核实）；`bootctl is-slot-bootable 1` 返回 70。
  - 风险评审在实机只读跑了 `lpdump --slot=1`：`system_b` / `system_ext_b` / `product_b` 的 extents 和 `_a` 完全重叠；`vendor_b` 最后一段只有 24 扇区，而 `_a` 是 2768 扇区。这是陈旧元数据。
  - ⇒ **"LP 元数据里有 `system_x`"不能作为槽可用的判据**。
- libsnapshot 的 `UpdateState` 定义：`None=0, Initiated=1, Unverified=2, Merging=3, MergeNeedsReboot=4, MergeCompleted=5, MergeFailed=6, Cancelled=7`（`fs_mgr/libsnapshot/android/snapshot/snapshot.proto:131-157`）。
- 上游清数据前的处理（`snapshot.cpp:4198-4235`）：
  - Unverified，且当前槽是目标槽、没有 forward-merge 标记：把当前槽设为不可启动，切回另一个槽。
  - Merging / MergeFailed：先把合并做完。
  - 这些只在 recovery 编译变体里可用（`snapshot.cpp:4167-4171`）。
- 状态文件是 `/metadata/ota/state`（`device_info.h:57` + `snapshot.cpp:3109-3111`，来自 C 方案引用）。

### 2.7 USB

- 只有一个 UDC `a600000.usb`（port0，dwc3 父设备 `a6f8800`，`dr_mode=otg`，`maximum-speed=high-speed`），最高 USB 2.0 HS。`a800000` 是 host。
- configfs、F_FS、libcomposite、AIO、io_uring 都是 `=y`；Android 已经在这个口上用 `ffs.adb` 跑 adb。
- UCSI 报的数据角色和实际相反：`typec/port0/data_role=[host]`，而 `usb_role` 被 rc 硬写成 `device`（#118 §6）。
- **#52**：a600000 在 device 角色下挂起会整板复位，不留 pstore（`docs/stage4-findings.md:2412-`、`:2744-2790`）。**patch 0012**：解绑半初始化的控制器同样会复位（`patches/0012-…:10-19`）。**A6**：待机唤醒后回插 USB 会坏。
- `ro.serialno` 为空；正常系统的 gadget 序列号写死为 `gaokun3`（`init.gaokun3.usb.rc`）。
- port0 对应机身上哪个物理口，文档里没有记录。

### 2.8 live 环境

- live 条目借用 `slot_b` 的 Image，cmdline 写死了 `gk3.dev=/dev/nvme0n1p3`（`scripts/live/m0-internal.sh:195`）。救援条目借用 `slot_a`（`installer-lib.sh:965`）。
- 只有带救援分区装机，或者像开发机这样手工放置的机器才有 live；Release 不附救援镜像（INST-6）。live.squashfs 约 202 MiB，ESP 放不下。
- live 里没有屏蔽挂起（B5，`scripts/live/build-rootfs.sh:136-137`），也没有任何设备端 fastboot 实现。
- 可复用的东西：`initramfs-init` 的 busybox 框架（4.0 MiB）、`gk3-unsparse.py` 的 sparse 语义、`gk3-bootimg.py`、安装器的 PARTLABEL 唯一性规则（`installer-lib.sh:1102-1158`）和 loop 盘测试夹具。

### 2.9 硬约束汇总

| # | 约束 | 依据 |
|---|---|---|
| K1 | "进 fastboot 或执行清除"的意图只能通过 misc（BCB）或 EFI 变量传到下一次启动；systemd-boot 只认 EFI 变量和 ESP 文件 | §2.2 |
| K2 | fastboot 条目只能通过 OneShot 进入，永远不做 default；文件名不能匹配 `*-android-*.conf` | §2.1 |
| K3 | 任何 BCB 消费者上线之前，必须先清理存量 BCB，并且能区分"存量"和"新写入" | §2.3 |
| K4 | 刷 `boot_x` 必须同步 ESP 派生物，否则只是空刷 | `gaokun3-ota-postinstall.sh:3-20` |
| K5 | flash/erase 必须有白名单，不能指望 SELinux | §2.5 |
| K6 | `set_active` 和清数据必须照顾 VAB 状态和 `_b` 不可用的事实 | §2.6 |
| K7 | device 角色下不能挂起，不能 unbind dwc3，进 fastboot 必须是冷启动 | §2.7 |
| K8 | ESP 空间紧张，载荷必须小，且只放一份 | §2.1 |
| K9 | 所有安装方式的用户都要有 fastboot（不能依赖 p3 / gk3rescue） | §2.8 |
| K10 | 上机实验要用户在场，并征得重启同意 | CLAUDE.md 操作禁忌 3 |

---

## 3. 方案比较与推荐

### 3.1 三套方案

- **A**：recovery ramdisk 内的 AOSP fastbootd。补 `init.recovery.gaokun3.rc`、boot HAL recovery 变体、自研 fastboot HAL，再加两处 tree-fix（白名单 + ESP 同步、stub UI 超时）。Android 在 `on shutdown` 钩子里写 OneShot。
- **B**：自研 UEFI 应用 `gk3boot.efi`，每次开机读 misc 执行 BCB，并在固件的 `EFI_USBFN_IO` 上实现 fastboot。
- **C′**：自研静态 `gk3-fastbootd`，放进与 live 同源的 initramfs（2–4 MiB），常驻 ESP，经 OneShot 进入；Android 侧的桥负责写意图记录和 OneShot。

### 3.2 比较表

| 维度 | A：recovery 内 fastbootd | B：UEFI 层 gk3boot | C′：ESP 常驻 initramfs |
|---|---|---|---|
| 可行性 | 卡在 #39（复位循环，根因不明，一个多月没重试）。另有一串只能上构建机确认的问题：fastbootd 怎么进 recovery、`BootControlClient::WaitForService` 会不会阻塞、recovery 里的 VINTF | 固件 DXE 里确有 `UsbfnDwc3Dxe` / `UsbDeviceDxe` / `UsbMsdDxe` / `UsbConfigDxe`，`EFI_USBFN_IO` GUID 已在二进制里交叉核对；但**运行时**能否在 port0 拿到 device handle 未验证，可能要逆向高通私有的 UsbConfig 协议 | 同一个内核，FunctionFS 已经在 port0 上跑过 adb；协议、sparse、GPT 都能离线开发，在容器里用主机端真 fastboot 走 TCP 对拍 |
| 风险 | 关机钩子的 exec 超时在 shutdown 期间不生效；改动面最大（system/core 和 bootable/recovery 两处 tree-fix、两个 HAL 变体） | **每次开机都跑**的代码挡在两个槽共用的路径上，变砖面最大；不接键盘能否从 U 盘救援未知 | 依赖 Android 侧的桥（未验证）；fastboot 内核的来源要设计；协议是自写的 |
| 体验 | 上限最高：正版 fastbootd，逻辑分区和 update-super 齐全，recovery 有触摸和中文；minui 能否点亮面板未知 | 有望做到真 bootloader 体验（ButtonsDxe 有按键记录）；但 `is-userspace=no` 会让 `fastboot reboot fastboot` 报"不可启动"（`fastboot.cpp:1588-1590`） | `is-userspace=yes` + 软重新枚举，标准 `fastboot update` 可用；fbcon 出字、按键、键盘盖都是内建驱动；只有英文界面 |
| 覆盖面 | 所有用户（ramdisk 随 vendor 走），但每槽占 ESP 约 15–18 MB | 所有用户，ESP 约 200 KB | 所有用户，ESP 2–4 MiB（另加内核，见 §4.2.3） |
| 成本 | XL：10–14 天，外加 #39 的不确定性；2–3 次 ROM 构建；上机 4–5 次 | XL：4–6 周；要从零搭 EDK2 和 QEMU 测试台；逆向私有协议 | 约 3–4 人周（成本评审认为代码量更接近 4–5 千行）；1 次 light 档核实，其余并进已排的构建；上机 3–4 次 |
| 风险评审 | 4 | 5 | 6.5 |
| 体验评审 | 6 | 4.5 | 7 |
| 成本评审 | 4 | 5 | 7 |
| **平均** | **4.7** | **4.8** | **6.8** |

### 3.3 推荐：1.0 做 C′（带评审修正），1.0 之后加 B 的轻量分派器，A 留作可选演进

**1.0 做 C′（含 §8 的全部修正）。** 三份评审独立给出了同一结论。C′ 是唯一同时满足下面五点的方案：

1. 所有安装方式的用户都有（K9）。
2. 不押注 #39，也不押注 UEFI 的 USB 栈。
3. 主要工作离线可测，构建和上机次数最少。
4. 失败后自动回到 Android：只经 OneShot 进入；`panic=10`；`/init` 失败时 `reboot -f`。
5. 停止往 ESP 铺 recovery ramdisk，ESP 的账反而变宽（OTA-8）。

**1.0 之后：B 的轻量分派器（B3 第一步）。** 做一个很小的 `gk3boot.efi`：**不碰 USB，不擦盘**。每次开机只做三件事：读 misc 的 BCB 和意图记录；读开机时的按键（固件 ButtonsDxe 有 `Keypress SDAM data payload`）；维护启动失败计数。然后把结果翻译成 OneShot，交给 systemd-boot，最终仍进入 C′ 的 fastboot 环境。它补上 C′ 的两个缺口：

- 不再依赖 Android 侧的桥（内核或 init 早期就死时，桥根本没机会运行）；
- 不接键盘、Android 起不来时，也能用"按住音量下 + 电源"进 fastboot。

它每次开机都运行，所以必须遵守 B 方案的 fail-open 和观察模式规矩，并先在 QEMU 上跑通。

**不做 B 的完整版（UEFI 里做 USB fastboot）。** USB 门槛只过了静态分析，工期 XL；它的体验和风险都不如 C′。

**A 保留为探索项。** 如果将来查清了 #39，可以把 C′ 的协议层换成正版 fastbootd（得到逻辑分区和 update-super）。入口、ESP 条目、意图记录、白名单思路都能沿用。A 的几个发现留档备用：缺 configfs rc；stub UI 的 120 秒超时；`on shutdown` 是唯一可用的关机钩子。

**为什么不是"live 宿主"（C 按字面做）**：一半以上的用户没有 live；squashfs 放不进 ESP；live 的 cmdline 写死了 `nvme0n1p3`。

---

## 4. 推荐方案（C′）详细设计

### 4.1 总览

```
 Android                                         ESP（共用）                         fastboot 环境
 ───────                                         ──────────                          ─────────────
 Settings/adb ─► init 写 BCB ─► on shutdown ──► LoaderEntryOneShot ─┐
                  (reboot.cpp)   gk3-bootintent   = gaokun3-fastboot.conf
                                 --shutdown        │                 │
                                 （写意图记录）     │                 ▼
                                                   │   systemd-boot ─► /gaokun3-fastboot/Image + dtb
                                                   │                   + initramfs.img（gk3.mode=fastboot）
 下次开机 post-fs-data ◄── 桥没成功时的兜底 ─────────┘                      │
   gk3-bootintent --boot（重新路由 / 迁移清理）                              ▼
                                                              /init ─► gk3-fastbootd
                                                               ├ 读 BCB + 意图记录 → 待命 / 恢复出厂 / 恢复菜单
                                                               ├ FunctionFS on a600000（18D1:4EE0, 0xff/0x42/0x03）
                                                               ├ GPT 白名单写 NVMe；gk3-esp-sync 写 ESP
                                                               └ tty1 文本界面 + evdev 按键
```

### 4.2 组件

#### 4.2.1 `gk3-fastbootd`（新增，C，静态 aarch64）

- **传输**：
  - FunctionFS。端点和描述符照抄 `refs/lineage-system-core/fastboot/device/usb_client.cpp:38-40`、`:81-239`；接口 class/subclass/protocol = `0xff/0x42/0x03`（主机端判据见 `fastboot/fastboot.cpp:244`）；VID/PID 用 `18D1:4EE0`（`refs/aosp-build/target/product/base_vendor.mk:33-35`）；序列号 `gaokun3`。
  - TCP 传输（`FB01` 握手，`fastboot/tcp.cpp:36-37`、`:95-120`）只在测试构建里编译，发布版关闭。
- **协议核心**：§4.5 列出的命令。
- **写盘相关**：
  - sparse 展开：语义对齐 `gk3-unsparse.py` 和 libsparse，任何 chunk 越界即拒。
  - GPT 解析，加白名单和唯一性检查（§4.4）。
  - LP 元数据只读解析：魔数见 `metadata_format.h:32,38`；偏移见 `liblp/utility.cpp:84-89`。
  - 解析 `/metadata/ota/state`：SnapshotUpdateStatus 的 protobuf，要手写 varint 解码。
  - misc 各区读写（§4.2.6）。
  - 写 efivarfs OneShot：照搬 `boot-oneshot.sh` 的三个坑。
- **`bootloader_control` 读写**：优先从构建机的 crDroid 树拷出 libboot_control 和 libbootloader_message 的源码静态编进来，**不手写结构体**；依赖能否静态化待 X2 核实。核实前，`set_active` 和"Unverified 时回滚"这两个功能不开（§4.5、§4.6）。
- **界面**：tty1 文本，按键走 evdev（§4.8）。

#### 4.2.2 fastboot initramfs（新增，基于 `scripts/live/initramfs-init` 和 `build-initramfs.sh`）

- 内容：静态 busybox + `/init` + `gk3-fastbootd` + 静态版 `gaokun3-bootimg-extract`（来自 `bootimg/bootimg_extract.cpp`，只依赖 `bootimg.h`）+ `gk3-esp-sync`。不带 WCN 固件，不带 GPU 固件，也不带 python。
- `/init` 遇到 `gk3.mode=fastboot` 时：不找 squashfs；挂 proc、sys、devtmpfs、configfs、functionfs；exec 守护进程。守护进程退出就 `reboot -f`。失败时沿用 `initramfs-init:27-45` 的"打印原因、60 秒后 `reboot -f`"，结果是回到 Android。
- 不跑 systemd 和 logind，也不加载 SELinux 策略。

#### 4.2.3 ESP 条目与内核来源（本文对 C′ 的改动，**未经评审，实施前要再审一次**）

- **条目固定命名为 `loader/entries/gaokun3-fastboot.conf`**，载荷目录固定为 `/gaokun3-fastboot/`，不放进 `<mid>/` 下。理由：
  - 关机桥写 OneShot 时就不需要挂 ESP 去查 machine-id，关机阶段少一个依赖；
  - 绕开 M4b 那次"machine-id 目录选错、ESP 写满"的同类风险；
  - 与 `gaokun3-live.conf` 的命名风格一致；
  - 文件名不匹配 `*-android-*.conf`，满足 K2。
- 条目内容：`title gaokun3 fastboot`、`sort-key` 排在 Android 之后。`options` 由 Android 条目的 options 派生：去掉 `androidboot.*`、`init=`、`firmware_class.path`（与 `installer-lib.sh:1092-1098` 的 `gk3__rescue_cmdline` 同一规则，抽成共用函数），**再去掉 `deferred_probe_timeout=10`**（来源 `BoardConfig.mk:130`，留着最坏会让 dwc3/PHY 晚 10 秒出现），最后加 `panic=10 gk3.mode=fastboot`。
- **内核来源：fastboot 用独立副本** `/gaokun3-fastboot/{Image,gaokun3.dtb}`，不借用任何槽：
  - OTA postinstall 写目标槽**之前**，把**当前正在运行的源槽**在 ESP 上的 Image 和 dtb 复制过来。这个内核刚刚启动成功，是已知可用的。
  - 图形安装器从载荷的 boot.img 解出来写入。
  - `gk3-fastbootd` 刷 `boot_x` 时**不碰**这份副本。
  - 效果：刷坏 `boot_a`、`boot_b` 甚至 `super`，fastboot 自己都还在。避免了风险评审指出的"刷坏所借槽的内核"问题，也不用在 HAL 里加第二个 ESP 写入者。
  - 代价：多占约 13–16 MB ESP，由停铺 recovery ramdisk 腾出的空间抵消（每槽约 15 MB，前提是那些文件确实在 ESP 上，见 T8）。
  - 退化：如果 ESP 空间核算不过，条目改为借用**当前运行的槽**（postinstall 此时只写目标槽，不会动它），并在日志和 `oem device-info` 里报告。
  - 已知差异：fastboot 内核会比 Android 落后一个版本，initramfs 却来自新的 vendor。configfs/ffs 的用户态接口稳定，按理没问题，验收时覆盖（E9）。

#### 4.2.4 `gk3-bootintent`（新增，vendor C++，Android 侧的桥）

两种模式：

- **`--shutdown`**：在 `on shutdown` 里 `exec`（`refs/lineage-system-core/rootdir/init.rc:1333-1335`）。时序已核对：`shutdown` 触发器排在 `shutdown_done`（DoReboot）之前（`reboot.cpp:986-992`）；exec 运行期间 init 不执行下一条命令（`init.cpp:1170`）。
  - 读 `sys.powerctl` 的目标（第二段）。属于 {bootloader, fastboot, recovery} 时，写意图记录，再写 OneShot = `gaokun3-fastboot.conf` 并回读。
  - **必须自带超时**：在进程内用 `alarm()`，约 5 秒。原因是 shutdown 期间 `HandleProcessActions` 被跳过（`init.cpp:1180-1187`），rc 里的 exec 超时不生效；`RebootMonitorThread` 要到 DoReboot 里才会启动。卡在 uefisecapp ioctl 的 D 状态，`alarm` 也杀不掉，这是残余风险（R2）。
  - 任何一步失败都只记日志，不拦重启。结果是回到 Android，由 `--boot` 兜底。
  - **不能**用 `on property:sys.powerctl=*`：属性变化会被 `ClearQueue` 清掉（`init.cpp:364-378` + `reboot.cpp:982-986`）。
- **`--boot`**：在 `on post-fs-data` 里 `exec`，这是有保证的兜底主路径（成本评审的建议）：
  1. 没有迁移标记：执行一次性迁移（§4.6.4）。
  2. 有迁移标记，且 BCB 非空或意图记录未完成：说明上次关机的路由没成功。BCB 只可能是上一次开机写的（每次开机这里都会处理），因此视为 Android 发起的有效请求：补写意图记录（来源 = `bootcheck`），计数 +1；如果计数 < 2，写 OneShot，然后 `setprop sys.powerctl reboot,recovery` 立即重新路由，代价是多一次重启。
  3. 计数到 2 仍失败：清 BCB 和意图记录，设 `persist.vendor.gaokun3.bootintent_failed=1`，由 Parts 弹通知"恢复出厂 / 进入 fastboot 未能执行"。**不允许静默丢弃 `--wipe_data`**（风险评审修正）。
  4. 意图记录状态为"已拒绝：系统更新合并中"（§4.6.2）时：清除记录，弹通知说明原因，请用户等合并完成后重试。

#### 4.2.5 `gk3-esp-sync`（新增，POSIX sh，toybox 和 busybox 都能跑）

- 从 `gaokun3-ota-postinstall.sh:41-187` 抽出公共规则：选 machine-id 目录（取第一个 32 位十六进制目录名）；按真实写入量核空间；从 `boot_x` 解出 Image、ramdisk、dtb、cmdline；同步 `<mid>-android-x.conf` 的 options；写临时文件、rename、sync，再从介质读回 cmp。
- postinstall 和 `gk3-fastbootd` 都调它。ESP 规则就从四份实现降到三份（HAL 的 C++、这份 sh、安装器的 bash）。

#### 4.2.6 misc 布局约定

| 偏移 | 内容 | 谁写 |
|---|---|---|
| 0–2 KiB | BCB（上游） | init、uncrypt；`gk3-fastbootd` 进入后清除 |
| 2–4 KiB | `bootloader_control`（libboot_control） | boot HAL；`gk3-fastbootd` 只按 libboot_control 原语读写，**绝不整段清零** |
| **8 KiB 起** | **`GK3I` 结构**：魔数、版本、迁移标记、意图记录（目标、来源 shutdown/bootcheck、BCB 摘要、当前槽、尝试计数、状态） | `gk3-bootintent`、`gk3-fastbootd` |
| 16 KiB、32 KiB | wipe package、system space（virtual_ab 等） | 上游；本设计只读 |

"8 KiB 处无人使用"待 X2 在 libboot_control、libsnapshot 和 Lineage recovery 里 grep 核实。

### 4.3 进入路径

| 场景 | 路径 | 结果 |
|---|---|---|
| 设置 → 清除所有数据 | uncrypt `--setup-bcb` 写 `boot-recovery` + `recovery\n--wipe_data\n--reason=…`（`uncrypt/uncrypt.cpp:567-605`）→ `reboot,recovery`（init 保留已有命令，`reboot.cpp:923-936`）→ 桥写意图记录（target=recovery、wipe）和 OneShot → 冷启动进 fastboot 环境 | 守护进程核对：意图记录存在，**且**记录里的 BCB 摘要与当前 BCB 一致 ⇒ 视为设置里已确认过，**免二次确认**，执行 §4.6，完成后重启进开机向导 |
| `adb reboot bootloader` / `fastboot` | init 写 BCB（bootloader：`bootonce-bootloader`；fastboot：`--fastboot`）→ 桥**以 `sys.powerctl` 的目标为准**（BCB 里即便残留 `--wipe_data` 也不清数据）→ OneShot | 进入 fastboot 待命；守护进程立即清 BCB 和意图记录，对齐 fastbootd 的行为（`refs/lineage-bootable-recovery/fastboot/fastboot.cpp:91-98`） |
| `adb reboot recovery` | 同上，目标 recovery，BCB 里没有 wipe | 显示恢复菜单（重启 / 关机 / 恢复出厂（需确认）/ 有 live 时显示"进入安装器"），同时 USB fastboot 可用 |
| RescueParty（`--prompt_and_wipe_data`） | 走 `sys.powerctl`，桥能路由 | 显示"系统无法启动：重试 / 恢复出厂"，**必须按键确认** |
| 开机菜单手选 | 没有意图记录 | fastboot 待命；BCB 里如有任何内容，**全文显示**；所有破坏性动作都要按键确认 |
| U 盘上的条目 | 同手选；目标盘按 §4.4 规则确定（U 盘自己没有我们的分区，会落到内置盘） | 同上 |
| Android 早期就死（InitFatalReboot、内核挂死） | `RebootSystem` 直接重启，不经过 shutdown 触发器（`init/reboot_utils.cpp:140-170`），桥不会运行 | 1.0 只能靠手选菜单或 U 盘。1.0 之后由轻量分派器的"失败计数 / 按键"补上（§3.3） |

**从 fastboot 出去**：

- `fastboot reboot` 或菜单"重启到系统"：普通冷重启，回到 default 的 Android。
- `reboot-bootloader` / `reboot-fastboot`：不真重启，回 OKAY 后在 configfs 层把 UDC 写空再写回（软重新枚举），满足主机端 `WaitForDisconnect` 和随后的 `is-userspace` 检查（`fastboot.cpp:1575-1596`）。不动 dwc3 的 bind 和 role。
- `reboot-recovery`：原地切到恢复菜单。
- "关机"：`reboot(POWER_OFF)`。

**耗时（估算，待 E5 实测）**：

- Android 关机 3–8 秒；固件 POST 未测；systemd-boot 有 OneShot 时**倾向于跳过 15 秒菜单**（#116 记录 OneShot 指向测试内核约 20 秒起来，`docs/stage4-findings.md:8432`，待 X0 用源码核实）；内核加 initramfs 到守护进程就绪约 2–4 秒（参照 live 的 dmesg，`out/m0/diag/boot-20260926-153138.log:360-398`）。
- 合计：从 `adb reboot bootloader` 到 `fastboot devices` 约 15–35 秒。走 `--boot` 兜底路径时，再加一次 Android 启动（约 50–56 秒）。

### 4.4 分区映射

不依赖 `/dev/block/by-name`（那是 Android ueventd 的产物），也不按分区号。规则是 **GPT PARTLABEL 精确匹配 + 唯一性**，与 `installer-lib.sh:1102-1158`（`gk3__need_part` / `gk3__bylabel`）同一套规则，在 C 里重新实现：

1. **确定目标盘**：
   - 优先取 EFI 变量 `LoaderDevicePartUUID`（systemd-boot 写的，#42 已实测能读）所在的盘，条件是该盘 GPT 里 `misc`、`boot_a`、`boot_b`、`super`、`userdata`、`metadata` **各恰好出现一次**。
   - 否则扫描全部盘，要求**恰好一块**满足条件。
   - 0 块或多块（比如插着一块出厂布局的外接盘）时拒绝一切写入。唯一的口子是 cmdline 里的 `gk3.fbdisk=<misc 的 PARTUUID>`，只能在 ESP 上手改条目给出（`editor no`），供测试用。
2. **对外暴露的名字**：`boot_a`、`boot_b`、`super`、`userdata`、`metadata`（`getvar partition-size/type`、`flash`、`erase` 只认这些）。`misc` 只供内部按偏移读写，不能 flash 也不能 erase。`esp`、`EFI system partition`、`ubunturescue`、`gk3rescue`、Windows 的 `Basic data partition`、整盘，在协议里**根本不存在**。
3. **槽**：`has-slot:boot=yes`，主机会把 `boot` 补成 `boot_<槽>`；其余分区都不分槽。
4. **ESP** 不按名字找，规则与 HAL 和 postinstall 一致：先看 `LoaderDevicePartUUID`，再按内容找带 `loader/entries/*-android-*.conf` 的 vfat 分区（双系统时它的 PARTLABEL 是 `EFI system partition`）。挂载点私有（**不要叫 `/mnt/esp`**，CLAUDE.md 运维禁忌 4），只写固定路径。
5. 每次写之前，在屏幕和 INFO 里打印"盘型号 + 分区名 + PARTUUID + 起止 LBA"。

### 4.5 命令支持

| 命令 | 1.0 行为 |
|---|---|
| `getvar version` | `0.4` |
| `getvar version-bootloader` | `gk3fb-<版本>` |
| `getvar product` | `gaokun3`（与 `BoardConfig.mk:27` 的 `TARGET_BOOTLOADER_BOARD_NAME` 一致；`android-info.txt` 的 `require board=` 被主机映射到 product，`fastboot.cpp:894-895`） |
| `getvar serialno` | `gaokun3`（与 adb gadget 一致；要不要改成 SMBIOS 序列号见 U5） |
| `getvar secure` / `unlocked` | `no` / `yes` |
| `getvar is-userspace` | **`yes`**。答 no 会让主机 `fastboot reboot fastboot` 报"不可启动"（`fastboot.cpp:1588-1591`） |
| `getvar max-download-size` | `0x20000000`（512 MiB，放内存；live 那套内核下内存约 15 GiB） |
| `getvar slot-count` / `current-slot` | `2` / 上次 Android 启动的槽（取自意图记录，没有就取 ESP default） |
| `getvar slot-successful:x` / `slot-unbootable:x` / `slot-retry-count:x` | 从 `bootloader_control` 读；X2 核实布局之前返回 FAIL "unknown" |
| `getvar has-slot:<p>` | `boot` 为 yes，其余为 no |
| `getvar partition-size:<p>` | 来自 GPT |
| `getvar partition-type:<p>` | **一律 `raw`**（理由见 §4.6.5） |
| `getvar is-logical:<p>` / `super-partition-name` | `no` / `super` |
| `getvar snapshot-update-status` | 由 `/metadata/ota/state`（只读私有挂载）映射为 none / snapshotted / merging |
| `getvar gk3-esp-default`（自定义） | ESP loader.conf 实际的 default，便于发现和 misc 不一致 |
| `getvar battery-*` | 可选，读 EC 的 power_supply；读不到就返回空，不影响刷机 |
| `download` | 放进内存缓冲 |
| `flash boot_a\|boot_b` | 写分区 → FlushBlocks → 读回比对哈希 → **同一条命令内**调 `gk3-esp-sync x`。ESP 同步失败就返回 FAIL："boot_x 已写入，但 ESP 未更新，下次仍启动旧内核"，ESP 上的旧副本保持不动，可以启动 |
| `flash super` | 只支持整块（sparse 或 raw，主机按 max-download-size 分片）。写完后只读解析新的 LP 元数据：校验魔数，列出它服务的槽 S。VAB 收尾：清 `/metadata/ota/` 下的快照状态（待 X2 核实收尾的完整集合）。如果当前 active 槽不在 S 里，自动按 `set_active` 规则切到 S，并 INFO 告知。本会话没刷过 `boot_S` 时，INFO 警告"boot 与 super 可能不是同一版本" |
| `flash <逻辑分区>` | FAIL："1.0 只支持整块 super；请用 flash-all 或安装器" |
| `erase userdata\|metadata` | 执行 §4.6 的单分区步骤；合并期间拒绝（对齐 `fastboot/device/commands.cpp:202-260`） |
| `erase <其他>` | FAIL（`cache` 返回 "no such partition"，主机的 `-w` 会因此跳过它，`fastboot/task.cpp:299-305`） |
| `-w` | 主机依次执行 `getvar partition-type` → `erase` → 格式化（`fastboot.cpp:2634-2645`、`task.cpp:299-311`）。我们报 raw，所以主机只擦不格式化，会打印 "Erase successful, but not automatically formatting…"（`fastboot.cpp:2077-2080`）。**设备端 erase 时补一行 INFO："Will be formatted by Android on next boot"**，免得老玩家以为失败了 |
| `set_active a\|b` | 依次检查：①不在 Merging / MergeFailed 状态（对齐 `commands.cpp:336-356`）；②`bootloader_control` 里目标槽**没有**被标为不可启动；③ESP 上 `slot_x/` 的三个文件存在且非空；④LP 元数据服务槽 x（这是必要条件，单独不充分，见 §2.6）。全部通过后：按 libboot_control 的 SetActive 原语写 misc，再写 loader.conf 的 default（临时文件 + rename + 读回）。**X2 之前此命令返回 FAIL** |
| `snapshot-update cancel` | Merging / MergeNeedsReboot 时 FAIL："合并进行中，请先正常开机一次"；其余状态返回 OKAY，在会话里记下，等整块刷 super 后统一收尾 |
| `snapshot-update merge` | FAIL（不支持） |
| `update <zip>` | 协议层支持。我们自己出的 zip 包含 `android-info.txt`、`fastboot-info.txt`（`version 1 / flash boot / flash --slot-other boot / flash super`）、`boot.img`、`super.img`（sparse）。不带 `super_empty.img`，所以不会触发 update-super（`task.cpp:42-55`、`fastboot.cpp:2122-2142`）。主机端会先 `set_active(当前槽)`，再 CancelSnapshotIfNeeded（`fastboot.cpp:1598-1604`、`:1807-1818`）。旧版 platform-tools 不认 `fastboot-info.txt`（`fastboot.cpp:1750-1758`），会退回按镜像清单刷，行为待 E1 实测。**是否随版发这个 zip 见 U3** |
| `flashing unlock\|unlock_critical` / `get_unlock_ability` / `lock` | OKAY 空操作 / `1` / FAIL "不支持上锁" |
| `reboot*` | 见 §4.3 |
| `oem log` / `oem device-info` | 上传守护进程日志 / 显示盘、ESP、意图记录、VAB 状态 |
| `boot`、`fetch`、`upload`、逻辑分区操作、`update-super`、gsi | FAIL，并附原因 |

**随版附带 `flash-all.sh` / `flash-all.bat`**：依次 `flash super`、`flash boot_a`、`flash boot_b`（同一个 boot.img）、`set_active a`、`-w`（可选）、`reboot`。这对应安装器 `installer-lib.sh:835-852` 那一段。整块刷 super 时 `set_active a` 一定成立，因为刷完后 `_a` 由 LP 服务，并且 `boot_a` 刚刷过。

**吞吐估算**：USB 2.0 HS，sparse super 约 3.2 GiB（C 方案从本地 `zstd -l` 读出），按 30–40 MB/s 估约 90–110 秒。待 E7 实测。

### 4.6 清除数据语义

#### 4.6.1 擦什么

所有入口共用同一个 `wipe_data()`：BCB 带 `--wipe_data`；`--prompt_and_wipe_data` 确认后；菜单"恢复出厂"；`fastboot erase userdata/metadata` 和 `-w` 走其中对应分区的步骤。

1. **前置检查**：目标盘唯一；VAB 状态判定（§4.6.2）；可选的电量检查（低于 20% 且没在充电时拒绝）。
2. **userdata**：
   - 先尽力 `BLKDISCARD` 整个分区；
   - 再**显式写零开头 1 MiB 和末尾 1 MiB**，fsync，读回确认开头 4 KiB 全零。
   - Android 下次开机时：fs_mgr 发现超级块魔数不对就直接返回、不跑 e2fsck（`fs_mgr.cpp:753-769`）；`partition_wiped` 为真（开头 4 KiB 全 0 或全 FF，`libcutils/partition_utils.cpp:42-67`），加上 fstab 里的 `formattable`（`fstab.gaokun3:26-27`），会按设备参数重新格式化（`fs_mgr.cpp:1634-1679`）。
3. **metadata**：整块 32 MiB 清零（代价很小）。first-stage mount 遇到 formattable 分区挂载失败会放行（`init/first_stage_mount.cpp:620-631`），由第二阶段格式化（`fs_mgr.cpp:1494-1503`）。这一步会一并清掉 `/metadata/ota`、gsi、vold 元数据。
4. **misc**：只清 0–2 KiB 的 BCB 和意图记录。**不动** `bootloader_control`（清数据不切槽，除非 §4.6.2 要求回滚）、virtual_ab 消息（状态为 None 类时本来就一致）、memtag（sc8280xp 没有 MTE）。
5. **不碰**：super、boot_x、ESP、p3、gk3rescue。恢复出厂不重装系统，这与 recovery 的 WipeData 一致（`install/wipe_data.cpp:133-170`）。
6. **收尾**：sync，屏幕显示完成，3 秒后重启。
7. **断电续做**：BCB 和意图记录要等全部步骤完成后才清，所以断电后下一次进入会重做。清零是幂等的，与 recovery 的 `get_args` 回写语义一致（`recovery_main.cpp:103-190`）。

**会被清掉的**：用户数据、KernelSU 的 `/data/adb`（D6 保留了 root 管理器，清除后需要重新授权）、adb 授权密钥、Wi-Fi 配置。

**不是安全擦除**：`/data` 没有加密（实机 `ro.crypto.state=unsupported`，D3），也没确认 NVMe discard 之后读出来是不是全 0（DLFEAT 未知），所以底层工具仍可能恢复旧数据。**发版说明和设置里的提示必须写明**（与 D2 test-key、D3 不加密一起披露）。

#### 4.6.2 与 VAB 和 OTA 的关系（守卫表）

判定依据是 `/metadata/ota/state`（只读私有挂载），映射关系照上游 `snapshot.cpp:4198-4235`：

| UpdateState | 上游 recovery 的做法 | 1.0 的做法 |
|---|---|---|
| None、Initiated、Cancelled、MergeCompleted | 允许清除 | 允许清除 |
| Unverified（OTA 已装，还没在新槽上验证） | 当前槽是目标槽且没有 forward-merge 标记：目标槽设为不可启动，切回源槽，再清除 | **X2 核实 `bootloader_control` 原语后**照做：目标槽设为不可启动，`set_active(源槽)`（misc + ESP default），然后清除；屏幕说明"待装的系统更新已放弃，清除后会重新下载"。源槽、目标槽和 forward-merge 标记的取法，实施时从本地 `refs/lineage-system-core/fs_mgr/libsnapshot/` 读出。**核实之前**：拒绝，意图记录写成"拒绝：更新待验证"后重启回 Android，由 `--boot` 弹通知 |
| Merging、MergeFailed、MergeNeedsReboot | 先把合并做完再清除 | **拒绝**：我们的环境里没有 libsnapshot，做不了合并。屏幕显示"系统更新正在合并，完成后请重新执行恢复出厂"，意图记录写成"拒绝：合并中"，重启回 Android，`--boot` 弹通知。**不保留延期执行的清除请求**，免得几天后哪次重启突然擦数据 |

这条路径**不允许静默失败**：每次拒绝都必须在屏幕上和 Android 通知里同时出现（体验评审修正）。

**可选的进一步改进（U4）**：在 Android 侧发现 OTA 待重启或合并中时，让设置里的"清除所有数据"直接禁用并说明原因。需要 frameworks 层 overlay 或补丁，资源名要在 Settings 源码里 grep 确认，1.0 不承诺。

#### 4.6.3 `fastboot -w` / `erase`

- 执行与 §4.6.1 第 2、3 步相同的单分区步骤，合并期间拒绝（同上表）。
- `-w` **不会**完成合并，也不会回滚。Unverified 时 erase metadata 一律拒绝，提示先 `fastboot snapshot-update cancel` 再整块刷 super，或者先正常开机。

#### 4.6.4 存量 BCB 的清理（迁移，K3）

- **时机**：装上新版后第一次开机，由 `gk3-bootintent --boot` 执行，**只执行一次**：
  1. 没有迁移标记 ⇒ 清零 misc 0–2 KiB（只清这一段），写入迁移标记（`GK3I`，含版本和时间），打日志并记下清掉的 BCB 内容。
  2. 有标记之后再出现的 BCB，都是标记之后写入的，按 §4.2.4 视为有效请求。
- **为什么不放在 postinstall 里做**：postinstall 跑在旧系统里，用户可能在 OTA 装完、重启之前点恢复出厂；放到新系统首次开机，可以用标记明确区分"标记之前"和"标记之后"。
- **代价**：如果用户恰好在 OTA 装完、重启之前点了恢复出厂，这次请求会被当成存量清掉。缓解办法：迁移时如果发现的是 `--wipe_data`，**不静默**，弹通知"检测到一次未执行的恢复出厂请求，已取消；如需清除请重新操作"。
- 安装器（含重装并保留数据）本来就会整块清零 misc（`installer-lib.sh:838-843`），清完要**写入迁移标记**，这样全新装机不会被当作"未迁移"。
- 开发机 misc 现在是全零，不能代表用户机器。

#### 4.6.5 为什么 `partition-type` 报 raw

如果报 ext4，主机会用**它自己的** mke2fs 为 376 GiB 的 userdata 生成镜像再刷下来（`fastboot.cpp:2033-2112`）。文件系统特性由主机上的 fastboot 版本决定，不一定和 fstab 一致；有些发行版的 fastboot 包还缺 mke2fs。报 raw 时，"擦"在设备端完成，"建"交给 Android 的 fs_mgr，和恢复出厂共用同一条路径，逻辑只有一份。

### 4.7 USB 与电源

- 只用 port0 / `a600000.usb`。在 configfs 层建 `g1`：`18D1:4EE0`，一个 `ffs.fastboot` 函数；挂 functionfs 到 `/dev/usb-ffs/fastboot`；描述符写好后写 `UDC=a600000.usb`。
- **role**：启动时如果已经是 `device`（patch 0012 之后开机默认就是 device）就不写；不是才写一次，与 `init.gaokun3.usb.rc` 的做法相同。**不 unbind 或 rebind dwc3**（patch 0012:13）。UCSI 插拔时会不会把 role 切到 host，见 T6。
- **不挂起**：initramfs 里没有 systemd、logind，也没有任何东西写 `/sys/power/state`。电源键、合盖只产生 evdev 事件，由守护进程自己解释：电源键 = 确认，合盖不处理。另外写 `/sys/power/wake_lock gk3fastboot` 作为保险。
- 进 fastboot 一定是冷启动（OneShot 重启），所以不受 A6（待机后回插就坏）影响。
- **空闲关机**（U6）：没有主机连接、也没有按键超过 30 分钟时关机，防止电池耗尽。默认值请用户定。

### 4.8 界面

- tty1 文本界面（fbcon；cmdline 里已有 `fbcon=rotate:1`；`FRAMEBUFFER_CONSOLE(_ROTATION)`、`DRM_MSM`、面板驱动都是 `=y`，见体验评审核对的实机 config）。状态页显示：目标盘、槽位、ESP default、USB state（`/sys/class/udc/a600000.usb/state`）、VAB 状态、最后一条命令和进度。
- **只用英文**：Linux VT 字体最多 512 个字形，画不了 CJK。INSTALL 和 FAQ 里给中文对照。1.0 之后如果需要中文，再在 DRM 上自己用嵌入的点阵字体画字。
- 按键：`pmic_pwrkey`、`pmic_resin`（音量下）、`gpio-keys`（音量上）、键盘盖 HID，设备名已只读核实。音量上下选择，电源键确认。
- 确认页：恢复出厂（无意图记录时）、`--prompt_and_wipe_data`、菜单发起的破坏性操作。确认页**没有超时自动执行**，也**没有超时自动重启**（不复制 recovery 的 120 秒行为）。

### 4.9 SELinux

- **fastboot 环境**：initramfs 用的是 busybox init，不加载 Android 策略，不存在 SELinux 约束。
- **Android 侧**（这部分要随整体 SELinux 轮次在 enforcing 下验证）：
  - efivarfs：新增类型和 `genfscon`（核心策略里没有，`refs/lineage-sepolicy` 里 grep 不到 efivar）。init 在 `on post-fs-data` 用私有挂载点挂 efivarfs，不挂到 `/sys/firmware/efi/efivars`，免得影响别处。
  - `gk3_bootintent` 域：读 `powerctl_prop`；读写 `misc_block_device`；对 efivarfs 文件 write、`ioctl FS_IOC_SETFLAGS`（`chattr -i`）；设置 `sys.powerctl`（`--boot` 重新路由时用）；设置 `persist.vendor.gaokun3.bootintent_failed`。
  - postinstall 域：复制 fastboot 内核和 initramfs 时需要的 ESP 写权限，复核第五轮已补的规则是否够用。
  - **本设计不需要** fastbootd 和 recovery 的策略。

### 4.10 安全与回落

**未授权写入**：fastboot 不做认证，与 orange 状态下的 fastbootd 一样（`utility.cpp:197-199`）。能进入 fastboot 的只有两种人：

- 能用已授权 adb 的人。D1 落实后，发布版 adb 要求授权；
- 能物理操作开机菜单或 U 盘的人。这些人本来就能用 live 安装器写盘（Secure Boot 关着）。

所以 fastboot **没有扩大物理接触以外的攻击面**。发布版编译期关闭 TCP 传输。安全说明里要写明"fastboot 不认证、恒为解锁"（与 D2、D3 一起披露）。

**写错盘**：§4.4 的白名单 + 名字唯一 + 目标盘唯一 + 越界即拒。

**ESP**：只写四处：fastboot 自己的 `/gaokun3-fastboot/`（只有 postinstall 和安装器写）、`slot_x/`、条目的 options、loader.conf 的 default。全部走临时文件 + rename + sync + 读回 cmp，写前核空间（吸取 M4b"写满却报成功"的教训）。不碰 `EFI/BOOT/BOOTAA64.EFI`。

**断电**：

| 时机 | 后果 | 恢复 |
|---|---|---|
| 写 boot_x 时 | 分区坏了，ESP 上仍是旧副本（只有校验通过后才同步） | 能启动旧内核；重刷即可 |
| ESP 同步时 | 临时文件还没 rename，旧文件仍有效 | 重刷即可 |
| 写 super 时 | Android 起不来；fastboot 不受影响（独立内核 + ESP 上的 initramfs） | 手选菜单或 U 盘进 fastboot 重刷 |
| 清数据时 | BCB 和意图记录仍在 | 下次进入时续做；如果是手选菜单进入，会显示 BCB 并确认 |
| 写 OneShot 时 | 变量下次开机就被消费 | 最坏是这一次没进 fastboot，由 `--boot` 兜底 |

**回落顺序**：

| 情况 | 回落 |
|---|---|
| fastboot 起不来或 panic | 自动回到 Android（OneShot 已被消费，`panic=10`） |
| fastboot 硬挂 | 长按电源键，回到 Android |
| 关机桥卡死（R2） | 长按电源键；下次开机由 `--boot` 兜底 |
| Android 坏、fastboot 好 | 菜单进 fastboot（或 Android 侧路由进去），用 flash-all 或 update |
| Android 和 fastboot 都坏，或 ESP 坏 | U 盘（live 安装器重装并保留数据，或 U 盘上的 fastboot 条目）。**发版说明要写"准备一个 U 盘"** |
| 桥连续失败 | 两次后放弃，弹通知 |

---

## 5. 实施步骤

| # | 内容 | 工作量 | 需要 | 产物 |
|---|---|---|---|---|
| 0a | 零风险核实（离线）：clone-refs.sh 加入 systemd v257，grep `src/boot`，回答：OneShot 是否跳过菜单；`LoaderEntryDefault` 和 loader.conf default 谁优先；OneShot 指向不存在的条目时怎么办；`LoaderDevicePartUUID` 的格式；`+N` 计数条目的 id 规则 | S | 联网 | 核实记录，追加进本文 §7 |
| 0b | 构建机 light 档只读核实（X2） | S | 开构建机（light），用完 stop | libboot_control 的布局和原语、依赖能否静态化；misc 8 KiB 是否没人用；`bootimg.h`；Settings 写入 BCB 的完整参数（是否一定带 `--reason`）；libsnapshot 源槽和 forward-merge 标记的取法；发版 super.img 的 sparse 大小 |
| 1 | `gk3-fastbootd` 协议核心 + FunctionFS 和 TCP 传输 + GPT 白名单 + sparse + LP 只读解析 + state 解析 | L（4–5 千行） | 本机 Mac + arm64 Docker（与 `live-build.Dockerfile` 同款） | 静态二进制 |
| 2 | 离线测试套件：容器里的 loop 盘，覆盖出厂布局、双系统布局、重名分区、两块候选盘；主机端真 fastboot 走 TCP，覆盖 §4.5 全部命令、白名单拒绝、歧义盘拒绝、sparse 越界、`-w` 后开头 4 KiB 全零、update zip（新旧两版 platform-tools）；与 `gk3-unsparse.py`、installer-lib 的 PARTLABEL 解析对拍 | M | 本机 Docker、platform-tools | `scripts/fastboot/test-*.sh`，全绿 |
| 3 | `gk3-esp-sync` 抽取 + postinstall 改为调用它 + 静态版 bootimg_extract | M | 0b 拷出的 `bootimg.h`；ROM 构建（并入已排的那次） | 共用件；postinstall 回归通过 |
| 4 | `wipe_data()` 和 VAB 守卫表；`set_active` 和 Unverified 回滚（依赖 0b） | M | 0b | 守护进程功能补齐，并有测试覆盖 |
| 5 | initramfs 的 fastboot 分支 + `build-initramfs.sh` 变体 | S | 本机 | `gk3-fastboot-initramfs.img` |
| 6 | 文本界面 + evdev 菜单 + 确认页 | M | E5 回显出来的键位 | — |
| 7 | `gk3-bootintent`（两种模式，带 alarm 自限）+ rc（`on shutdown`、`on post-fs-data`）+ efivarfs 挂载 + sepolicy + Parts 通知 | M | ROM 构建（并入批 1 或批 2） | vendor 二进制、rc、te |
| 8 | 落地到 ESP：postinstall 复制 fastboot 内核、铺 initramfs、写条目、停铺并删除 recovery-ramdisk；`gk3_apply` 写同样的东西 + 迁移标记；`build-usb.sh` 给 U 盘加条目；`test-apply` 补用例 | M | ROM 构建 + 安装器重建（并入计划里那一次） | — |
| 9 | 发布物：`flash-all.sh/.bat`；update zip（按 U3 的决定）；`release.sh` 断言 | S | — | Release 附件 |
| 10 | 文档：INSTALL（中英）加 fastboot 章节（进入方式、port0 是哪个物理口、Windows 要 Google USB 驱动、准备 U 盘、不支持 lock、不是安全擦除、英文界面的中文对照）、FAQ、安全说明 | S | 用户目视确认 port0 | — |
| 11 | 验收 E5–E9（§6） | L | 用户在场 3–4 次 | 验收记录写进案卷 |

**顺序约束**：

- 第 7 步的 `--boot` 迁移，和第 8 步的条目与载荷，**必须在同一个版本里发**：消费者（fastboot 环境）不能先于迁移上线。
- 第 4 步里的 `set_active` 和 Unverified 回滚，依赖 0b。0b 没核实之前，按 §4.5 和 §4.6.2 的"核实前"行为发布，不能因此卡住整个功能。

---

## 6. 验证实验（按安全顺序）

| 编号 | 内容 | 只读 | 需重启 | 用户在场 | 会擦数据 |
|---|---|---|---|---|---|
| X0 | 拉 systemd v257 源码，核实 §5-0a 的问题；可选：在 QEMU aarch64 + AAVMF + 同版 systemd-boot 上复现 | ✓（离线） | — | — | — |
| X1 | 容器端到端测试套件全绿（§5-2） | ✓（离线） | — | — | — |
| X2 | 构建机 light 档只读核实（§5-0b） | ✓ | — | — | — |
| X3 | 设备：root 下用私有目录 `-o ro` 挂 efivarfs，读 `LoaderInfo` / `LoaderFeatures` / `LoaderEntryDefault` / `LoaderEntrySelected` / `LoaderDevicePartUUID` 后卸载；只读 dump misc 0–16 KiB，确认 4–16 KiB 全零；只读 `lpdump --slot=0/1` 留档 | ✓ | — | 需用户同意 root 挂载 | — |
| E4 | 设备：在 Android 里跑 `gk3-bootintent --shutdown --dry-run`，打印解析结果；再让它把 OneShot 写成**当前 default 的 android 条目**（这样即使重启也只是正常开机），回读一致后清除。**这一步写 EFI 变量**。之后找一次本来就要做的重启，验证 `on shutdown` 里 exec 的时序、耗时，以及 shutdown 阶段 uefisecapp 是否可用（在 kmsg 里打标记） | 写 EFI 变量 | 第二段需要 | ✓ | — |
| E5 | 开发机 ESP 放测试条目 `gaokun3-fbtest.conf`（非 default），守护进程用**只读编译开关**（禁止一切写），经 `boot-oneshot.sh` 进入。观察并计时：从重启到 tty1 出字、Mac 上 `fastboot devices` 出现、`getvar all`；分区映射是否和 by-name 实况一致；键位；合盖和电源键没有副作用；拔插一次 USB 后的 role 和枚举；`reboot-bootloader` 软重新枚举；`fastboot reboot` 回到 Android；请用户确认 port0 是哪个物理口。出任何异常就长按电源键 | ✓（只读模式） | ✓ | ✓（USB 插 port0） | — |
| E6 | 装上带桥的测试 ROM（`install-ota-local.sh` 装到非当前槽，用 oneshot 验收的老流程）。依次 `adb reboot bootloader` / `fastboot` / `recovery` 各 3 次，确认都进入 fastboot（只读模式），BCB 和意图记录被清，`fastboot reboot` 回到 Android。再故意让桥失败（测试开关：不写 OneShot），验证 `--boot` 重新路由、两次后放弃并弹通知。验证首次开机的迁移（先手工在 misc 写一条假的存量 BCB，`--wipe_data` 那种要弹通知） | 写 misc | ✓ | ✓ | — |
| E7 | **外接盘沙盒**：一块出厂布局的外接盘，用 `gk3.fbdisk=` 指定为目标。执行 `flash boot_a`（检查 ESP 同步结果 cmp）、整块 `flash super`（sparse，测吞吐）、`-w`、`erase`、`set_active b`（应被拦下）、`update zip`、flash-all 脚本；中途拔线、长按电源键各一次。内置盘全程不可写（白名单 + 目标盘规则）。外接盘能否作为 Android 启动盘未验证，所以只检查写入结果 | 写外接盘 | ✓ | ✓ | 只擦外接盘 |
| E8 | **真恢复出厂**：在可丢弃的环境里，或者先把开发机关键状态（adb_keys、Wi-Fi、ksu、userdata）备份到外接盘，再从设置里端到端执行一次"清除所有数据"。观察：进 fastboot、免确认清除、回到 Android、fs_mgr 重新格式化、开机向导、槽位和 ESP default 都没变、BCB 已清、总耗时。另测一次 `--prompt_and_wipe_data`，应出现确认页。合并中拒绝的分支只在容器里测，不在真机上造合并状态 | — | ✓ | ✓，并且用户另行明确同意 | **✓** |
| E9 | 从 v0.7.1 OTA 升级到含 fastboot 的版本：检查 postinstall 复制了 fastboot 内核、铺了 initramfs 和条目、删了 recovery-ramdisk，以及 ESP 余量；首次开机迁移；内核落后一个版本时 fastboot 环境的 USB 和显示是否正常。双系统机器（共用 Windows ESP）的同类检查放到群友机器上只读做 | 写 ESP | ✓ | ✓ | — |
| E10 | （可选）Parallels 里的 Windows 克隆机，USB 直通，用 Google USB 驱动跑 `fastboot devices` / `getvar` | ✓ | — | — | — |

E5–E9 都在 CLAUDE.md 禁忌 3 约束下进行：每次重启前征得同意，确保有人能按电源键。E8 需要用户另行明确同意。

---

## 7. 未决问题与风险

### 7.1 需要用户决定

| # | 问题 | 建议 |
|---|---|---|
| U1 | 采纳本文的推荐组合吗：1.0 做 C′，1.0 之后做轻量分派器，A 留作探索项 | 采纳 |
| U2 | fastboot 不认证、恒为解锁，是否另加门槛（例如只有从设置或菜单亲手进入时才允许写，或者每次写之前按键确认） | 1.0 不加门槛，只披露。理由：物理接触本来就能用 U 盘写盘；加按键确认会让 `flash-all` 脚本没法无人值守 |
| U3 | 是否随版发 `fastboot update` 用的 zip：sparse super 约 3.2 GiB，压缩后能否低于 GitHub 单文件 2 GiB 上限要实测；也可以放在 R2 | 1.0 先发 flash-all 脚本；zip 等 E1 证明新旧 platform-tools 都正常、大小实测之后再定 |
| U4 | 是否在设置里，当 OTA 待重启或合并中时直接禁用"清除所有数据" | 1.0 不做（要改 frameworks），用 §4.6.2 的"拒绝 + 屏幕提示 + 通知"代替 |
| U5 | `serialno` 继续写死 `gaokun3`，还是改用 SMBIOS 序列号 | 1.0 保持 `gaokun3`（与 adb 一致）；多台设备同时连一台主机的场景以后再说 |
| U6 | fastboot 空闲多久关机 | 无主机连接且无按键 30 分钟后关机 |
| U7 | fastboot 内核用独立副本（多占 13–16 MB ESP），还是借用当前槽 | 独立副本（§4.2.3），空间不够时退化为借用 |

### 7.2 技术未知

| # | 未知 | 如何核实 |
|---|---|---|
| T1 | systemd-boot 257：有 OneShot 时是否跳过菜单；`LoaderEntryDefault` 的优先级（如果优先于 loader.conf，用户在菜单里按一次 `d` 就会让 HAL 的镜像失效） | X0、X3 |
| T2 | shutdown 阶段 `exec` 的可靠性和耗时，uefisecapp 在关机阶段是否可用 | E4 |
| T3 | `bootloader_control` 布局、SetActive 原语，以及能否静态编进守护进程；misc 8 KiB 是否无人使用 | X2 |
| T4 | Settings 写入 BCB 的完整参数（是否一定带 `--reason`、有没有 `--keep_memtag_mode` 之类） | X2（frameworks/base） |
| T5 | initramfs 模式下 fbcon 能否出字；`deferred_probe_timeout` 去掉后 dwc3 何时就绪 | E5 |
| T6 | UCSI 插拔时会不会把 a600000 的 role 改成 host 导致 fastboot 掉线；如果会，守护进程要不要盯住 role 并改回（#118 §7：不打 0048 时任何切换都会坏） | E5 拔插测试 |
| T7 | 实机 `ro.build.type=user` 却 `ro.debuggable=1`，来源不明（fastboot 环境不读 Android 属性，影响很小；D1 落实时一并查） | X2 |
| T8 | 用户机器 ESP 上实际有没有 recovery-ramdisk.img，能腾出多少空间 | E9；`boot-oneshot.sh --list` 类的只读挂载 |
| T9 | 不接键盘时开机菜单能否操作（INST-18）；键盘盖在 UEFI 阶段能否使用 | 批 1 的用户在场验收 |
| T10 | 双系统机器上，固件默认先启动 Windows Boot Manager 还是我们的 systemd-boot（如果是前者，OneShot 机制根本不会生效） | 群友机器只读 `bcdedit` / `efibootmgr` |
| T11 | NVMe discard 之后读出来是不是 0（DLFEAT）。设计上不依赖它，但影响隐私表述 | live 里只读执行 `nvme id-ns -H` |
| T12 | 主机端整块刷 3.2 GiB sparse super 的实际耗时 | E7 |
| T13 | 新旧 platform-tools 对 `fastboot-info.txt` 的处理差异 | X1 |

### 7.3 风险

| # | 风险 | 缓解 |
|---|---|---|
| R1 | Android 早期就死时没有自动入口（桥不会运行） | 1.0：手选菜单 / U 盘，写进文档；1.0 之后：轻量分派器 |
| R2 | 关机桥卡在 uefisecapp 的 D 状态，`alarm` 也杀不掉，整机停在关机阶段 | E4 先测；如果不可靠，关掉 `--shutdown`，只走 `--boot`（每次多一次 Android 启动） |
| R3 | 自写协议与各版本主机端 fastboot 的兼容性 | X1 用多版本 platform-tools 回归；只实现 §4.5 的范围 |
| R4 | 自写 4–5 千行代码只有一个人懂，单人维护的负担 | 测试套件 + 本文；结构上为将来换成正版 fastbootd（A）留出替换点 |
| R5 | ESP 空间（尤其是双系统共用 Windows ESP） | 停铺 recovery ramdisk；独立内核有退化模式；所有写入核空间并读回 |
| R6 | 迁移时误取消用户刚点的恢复出厂（OTA 装完、重启前那段窗口） | 发现 `--wipe_data` 时弹通知，不静默 |
| R7 | `set_active` 和 Unverified 回滚依赖 X2；X2 失败就只能拒绝 | §4.5、§4.6.2 写好了"核实前"的行为 |
| R8 | fastboot 内核落后一个版本 | E9 覆盖；必要时让 postinstall 在新槽验证成功后再刷新（需要 HAL 配合，1.0 不做） |

---

## 8. 采纳评审修正的记录

| # | 被纠正的论断 | 出处 | 纠正 | 依据 / 来源 |
|---|---|---|---|---|
| 1 | "本机没有 by-name" | 任务前提 | by-name 存在，安装器用标准名建了分区；只是本设计不依赖它 | 实机 `ls -l /dev/block/by-name`；`installer-lib.sh:388-400`（USB 摸底） |
| 2 | "#39 的第一步是在 recovery 里打通 USB adb" | #39 | 前提不成立：recovery 缺 `init.recovery.gaokun3.rc`，`sys.usb.configfs=0`，gadget 走不存在的 android_usb 分支 | `refs/lineage-bootable-recovery/etc/init.rc:1,13,135-162`（recovery 摸底） |
| 3 | "`init_fatal_panic` 对 #39 无效，因为失败走 reboot_on_failure" | #39 | recovery 的 init.rc 里没有 reboot_on_failure；critical 服务连崩会走 InitFatalReboot，认 `init_fatal_panic` | `etc/init.rc:92-117`；`init/service.cpp:375-387`；`init/reboot_utils.cpp:40-58,141-170` |
| 4 | 关机钩子可以用 `on property:sys.powerctl=*` | 摸底候选 | 属性变化会被 `ClearQueue` 清掉，只能用 `on shutdown` | `init.cpp:364-378`；`reboot.cpp:982-992`（本文已复核） |
| 5 | 关机钩子可以靠 rc 的 exec 超时兜底 | A、C | shutdown 期间 `HandleProcessActions` 被跳过，超时不生效；必须在进程内 `alarm` 自限，D 状态是残余风险 | `init.cpp:1180-1187`（本文已复核）、`:383-395`（风险、成本评审） |
| 6 | `set_active` 只要"LP 元数据里有 `system_x`/`vendor_x` 且有 extent"就放行 | A、C | 这个判据无效：`_b` 的 extents 与 `_a` 重叠，`vendor_b` 被截断。必须读 `bootloader_control` 的 unbootable 标志 | 实机 `lpdump --slot=1`（风险评审）；`bootctl is-slot-bootable 1`=70 |
| 7 | `set_active` 可以清零 misc 2–4 KiB，让 HAL 重建 | C | 会把"不可启动"标志一起抹掉，`_b` 看起来又可启动了；改为按 libboot_control 原语读写 | 风险评审；M4b 经验不能推广到 set_active |
| 8 | `--boot` 遇到"有 BCB、无意图记录"就当存量清掉 | C | 桥整个没跑成时，这会把刚写的 `--wipe_data` 静默清掉，B6 复发。改为：迁移只做一次（靠标记），之后发现的 BCB 一律重新路由，失败就弹通知 | 风险评审 |
| 9 | Unverified 或合并中拒绝清除后，结果没写清楚 | C | 必须在屏幕上和 Android 通知里同时可见；Unverified 在 X2 之后照上游回滚再擦 | 体验评审；`snapshot.cpp:4198-4235`（本文已复核） |
| 10 | 设备端必须报 `partition-type=ext4` | live 摸底、A | 报 raw，由 fs_mgr 格式化，只保留一份逻辑；`-w` 时补 INFO 说明 | `fastboot.cpp:2033-2112,2077-2080`；`fs_mgr.cpp:1634-1679`（C、体验评审） |
| 11 | stub UI 的 120 秒自动重启是无条件的 / screen UI 也会受影响 | A / 成本评审 | 只有 `WasTextEverVisible()` 为假时才返回 TIMED_OUT；StartFastboot 调了 `ShowText(true)`，所以 screen UI 正常时不受影响，只有 stub UI 或 quiescent 才会。成本评审"screen UI 同样会超时"的说法不成立。（只影响 A，本方案的界面没有超时） | `recovery_ui/screen_ui.cpp:1594-1602`、`fastboot/fastboot.cpp:88`（本文已复核） |
| 12 | `fastboot boot`"未核实" | C | 评审在实机 config 里没有看到 KEXEC，当前内核不可行，1.0 明确不做（本文写作时设备离线，未复核） | 体验评审 |
| 13 | 文本界面可以显示中文提示 | C | VT 字体画不了 CJK；1.0 只用英文 | 体验评审 |
| 14 | fastboot 条目原样继承 options | C | 要去掉 `deferred_probe_timeout=10`，否则 dwc3 最坏晚 10 秒出现 | `BoardConfig.mk:130`（本文已核对） |
| 15 | B："`fastboot update` 不支持" | B | 说得过头了：不带 `super_empty.img` 的 zip 加 `fastboot-info` 里的 `flash super` 不需要逻辑分区支持 | `fastboot.cpp:1807-1818`；`task.cpp:42-55`（风险评审） |
| 16 | B：`is-userspace=no` 可以接受 | B | 主机端 `fastboot reboot fastboot` 会报"不可启动"，所以本方案答 yes 并软重新枚举 | `fastboot.cpp:1588-1591`（体验评审） |
| 17 | B：`EFI_USBFN_IO` 的 GUID "凭记忆" | B | 已在 UsbfnDwc3Dxe、UsbDeviceDxe、UsbMsdDxe 三个 PE 里按 bytes_le 交叉核对，可以去掉"凭记忆"。BIOS 拆包产物在 B 方案调研时的 scratchpad（未入库），**建议留档到 `docs/hw/`** | 风险、体验评审 |
| 18 | B：MergeStatus 数值、systemd-boot drivers 目录的加载时机和镜像类型 | B | 凭记忆写的，未核实；本方案不依赖。libsnapshot 的 `UpdateState` 数值已从本地 proto 读出 | `snapshot.proto:131-157`（本文已复核） |
| 19 | C："2–3 千行 C" | C | 更接近 4–5 千行（FFS、sparse、GPT、LP、protobuf、界面） | 成本评审 |
| 20 | C：fastboot 条目借用"非目标槽"的内核 | C | 两个槽都刷坏时 fastboot 也跟着坏；改为独立副本（本文新增，**未经评审**） | 风险评审指出问题；§4.2.3 |
| 21 | C：条目和载荷放在 `<mid>/gk3fastboot/` | C | 改成固定名 `gaokun3-fastboot.conf` + `/gaokun3-fastboot/`，桥不用挂 ESP 查 mid（本文新增，**未经评审**） | OneShot 值就是条目文件名，`scripts/boot-oneshot.sh:61-64` |
| 22 | 入口完全依赖关机钩子 | A、C | 把 post-fs-data 的 `--boot` 重新路由作为有保证的兜底主路径，关机钩子只是提速优化 | 成本评审 |
| 23 | "有 OneShot 时会不会停 15 秒菜单"完全未知 | 摸底 | 有间接实测：OneShot 指向测试内核约 20 秒起来，倾向于跳过菜单，仍待源码核实 | `docs/stage4-findings.md:8432`（体验评审） |
| 24 | CLAUDE.md 把 `_b` 写成"回落槽" | CLAUDE.md | misc 标志和 LP 元数据都表明 `_b` 现在起不来（#118 §2 也记过）；fastboot 和文档里都不能把它当回落 | 启动链摸底；第 6 条 |
# MateBook E Go（gaokun3）统一启动入口设计

> **状态**：设计稿，还没有实现，也还没有上机（双系统 D1 已在开发机只读做过）。日期 2026-10-05；同日补全双系统（§4.9，两轮）。
> **2026-10-05 修订**：用户已采纳 U1–U11 的全部建议，并要求补全双系统（Windows + Android）。§4.9 整节重写；§1、§2.1、§4.2、§4.3.6、§4.6.1、§4.7、§4.8、§4.12、§4.14、§5、§6、§7 随之修改；新增决定点 U12–U21，U3 区分纯 Android 与双系统；自审纠正记在 §8.2 第 21 条起。**双系统没有真机样本**，§4.9 每条结论都标了证据等级。
> **2026-10-05 补全双系统（第二轮）**：按两份评审（风险 / 体验）合入修正——开发机实验只说明纯 Android 盘、不外推到双系统盘；"关掉安全启动后是否每次都要恢复密钥"改为【未知】；U 盘路径的 BitLocker 提醒提前到关安全启动之前；Modern Standby 会自动休眠；Windows 条目排第 2 位、标题一律 ASCII；`LoaderEntryDefault` 只允许两种值；Windows 侧能力集中到常驻的"Windows 伴随工具"；补卸载、反向迁移、文件交换、指纹、日常使用说明。新增 §4.9.15–§4.9.17、决定点 U22–U25，记录在 §8.2 第 45 条起（含不同意评审的几条及理由）。
> **起因**：用户 2026-10-05 澄清，说要"做一个 fastboot"，指的是**一个统一的、承载启动 Android 的入口**，作用和手机上的 ABL / bootloader 一样：选 A/B 槽，做启动失败计数和回落，读 misc 的 BCB，执行 bootonce-bootloader / recovery / wipe 这些意图；需要时进 fastboot 模式（刷机、`-w`、`set_active`）；恢复出厂和 `adb reboot bootloader` 也由它分派。
> **地位**：本文取代 [`fastboot-design.md`](fastboot-design.md) §3.3"推荐"一节。该文 §4 中 `gk3-fastbootd` 的协议、白名单、清除语义、USB 与界面设计，在本文里作为 **"fastboot 执行端"** 引用（记作 C′ §x.y）。
> **依据**：4 份摸底（固件、启动契约、开源基础、与现有链路共存），另有双系统 3 路摸底（现有双系统流程、固件与 Windows 启动机制、日常共存，§4.9）、3 套方案（X：ABL 骨架 + UEFI 内 USB；Y：入口做 efi 条目，fastboot 交给 Linux；Z：systemd-boot 驱动做决策层），3 份评审（风险、体验、成本）。正文引用的 `文件:行号` 沿用摸底和评审里核对过的那些。
> **源码位置**：上游源码浅克隆在会话 scratchpad 的 `src/` 下，**没有入库**：systemd v257.13（70b5d110）、hardware-interfaces boot/（1a56e38）、GBL（gbl-mainline e8577449）、CodeLinaro ABL（uefi.lnx.5.0.r53-rel / 6.0.r49-rel）、edk2 / mu-silicium（sparse）。BIOS 2.16 拆包产物在 scratchpad 的 `bios/`，分析工具在 `fwa/`。实施第 0 步要把它们纳入 `scripts/clone-refs.sh`，固件拆包留档到 `docs/hw/`（见 §5）。下文用 `boot.c`、`drivers.c`、`linux.c` 指 systemd v257.13 的 `src/boot/` 下的文件。
> **实机**：本轮所有摸底和评审进行时设备都离线（`adb devices -l` 为空），本文写作时复查也一样。实机事实一律引自已存日志（`out/v070-accept/census/logcat.txt`、`out/issues-1791053208/boot.img`）和上一轮的只读 misc dump。
> **冲突优先级**：实机实测 > 案卷 > 本文。标了"待 Ex / 待核"的内容，核实之前不能当作事实。

---

## 0. 一句话结论与推荐

**推荐方案是 Y（修正版）**：新增一个自研 UEFI 应用 `gk3boot.efi`，作为所有 Android 启动必经的唯一入口。它挂在 systemd-boot 下面，是一个带启动计数、并且是默认项的 `efi` 条目。它做这些事：
- 读 misc：BCB、`bootloader_control`、virtual_ab；
- 按 libboot_control 的语义选槽、扣 tries、自动回落；
- 分派 BCB 意图；
- 直接从 `boot_a/b` 分区读 boot.img，按 systemd-boot 已验证的契约交给内核的 EFI stub；
- 需要 fastboot、恢复出厂、恢复菜单时，用**同一个内核**加一个静态 initramfs，拉起 C′ 的 `gk3-fastbootd`（Linux 执行端）。

UEFI 内 USB fastboot（X 的核心）推到 1.x，届时只替换执行端的传输层。Z（systemd-boot 驱动）不作为终点，只在"入口自己交接内核"这道门槛（E4）完全不通时，作为退化形态。

**双系统**（§4.9）：
- 静态分析显示，华为固件每次开机都会删掉 Windows 自己写的启动项，两个系统都从回落路径上的 systemd-boot 进。所以入口方案不改变 Windows 的启动链，gk3boot 也不进 BitLocker 的度量。
- 新增的是：可选的"Windows 为默认"（gk3boot 预置 OneShot，Android 里的重启仍回 Android）、双向"重启到另一系统"、双系统固定显示菜单、ESP 给 Windows 留余量、`-RepairBoot` 和 `-RemoveAndroid`。
- 没有真机样本：固件**在纯 Android 盘上的**策略可以在开发机上先验（D1–D3，D1 已做，结果符合静态分析）；但实测里盘上有没有 Windows 分区改变过固件的启动选择（§4.9.2 末尾），所以**双系统盘上谁先运行只能由群友真机定**（D5 的 U 盘只读部分、D6）。Windows 侧靠 Parallels 和群友（D4–D7）。在那之前，双系统标"预览"。
- Windows 侧的修复、互相重启、默认系统、关快速启动 / 休眠集中到一个常驻的 **Windows 伴随工具**（U23，§4.9.15）。

分阶段：
1. 先离线做完决策核心和 QEMU 夹具；
2. 第一、二周内用户在场做 E3（只读探针）和 E4（缓冲区 LoadImage 真内核），这是硬门槛；
3. 入口先以观察模式上开发机，再转正；执行端与之并行开发；
4. 随 1.0 发布。

预计总工作量约 **8–10 人周**，需要用户在场 6–8 次。补全双系统（S12 扩大为 Windows 伴随工具、S15）再加约 2–3 人周（第一轮估 1–1.5，第二轮加了伴随工具的安装 / 开机自检 / 计划任务、U22 的 Windows 条目和 U25 的 Windows 侧预置）；开发机上的 D2 并进 E3 那一次，不增加在场次数；Windows 侧要靠 Parallels 和群友。

---

## 1. 目标与范围

### 1.1 目标

用户原话：**"一个统一的用来承载启动安卓的入口"**。落到行为上：

| # | 要求 | 对应 |
|---|---|---|
| G-E1 | 每一次 Android 启动都经过同一个入口，由它决定启动哪个槽、要不要进 fastboot | §4.2 |
| G-E2 | A/B：选槽、未确认的槽扣 tries、tries 用完自动回落到旧槽，也就是 OTA 坏了能自动回滚（今天没有，`v1.0-plan.md` G6） | §4.3.2 |
| G-E3 | BCB 意图都有消费者：`adb reboot bootloader / fastboot / recovery`、设置里的"清除所有数据"、RescueParty | §4.3.4 |
| G-E4 | fastboot 模式：`getvar`、`download`、`flash`、`erase`、`-w`、`set_active`、`reboot*` | §4.4 |
| G-E5 | 不接键盘也能走通：自动回落、BCB 驱动的进入方式都不依赖按键 | §4.3.6 |
| G-E6 | 入口自己坏了不会让两个槽一起起不来，能自动或手动回到今天的启动路径 | §4.12 |
| G-E7 | 双系统：不改变 Windows 的启动链和 BitLocker 度量；默认系统可选；两边能互相"重启到另一系统"；Android 里发起的重启（含 OTA 回滚、BCB 意图）不会落进 Windows；Windows 更新后能修复；能干净卸载 | §4.9 |

### 1.2 1.0 范围

- `gk3boot.efi`：决策层（GPT / misc / boot.img 解析，选槽与 tries，BCB 分派，存量 BCB 迁移，GK3 记录）、交接（从 `boot_x` 读，读不到时用 ESP 副本）、fail-open 阶梯、观察模式。
- 执行端：C′ 的子集，由入口直接引导，不再经过 OneShot 和 Android 关机桥。
- Android 侧：boot HAL 加一个"开机完成"线程（确认入口条目、清连续失败计数、导出事件属性）；Parts 弹通知。
- 部署：postinstall 部署入口、条目轮换、分阶段激活；安装器初始化 misc；`release.sh` 断言；开发脚本改造；Windows 脚本避开 `EFI\gaokun3`。
- 文档与发布物：INSTALL / FAQ，`flash-all.sh/.bat`。
- **双系统**（§4.9）：默认系统可选（`LoaderEntryDefault` + gk3boot 预置 OneShot + 关机标记）；Parts 的"重启到 Windows"和"默认启动系统"；Windows 脚本的"重启到 Android"、`-SetDefault`、`-RepairBoot`、`-RemoveAndroid`；双系统菜单策略；ESP 给 Windows 留余量；BitLocker 写入规则；快速启动一律关；安装器文案按事实改写。

### 1.3 1.0 明确不做

- **UEFI 内的 USB fastboot**（固件 UsbDevice 协议 + ABL FastbootLib 移植）：推到 1.x，前提是 E4u 实测 core0 能枚举。
- **gk3boot 直接坐 `BOOTAA64.EFI`**、取代 systemd-boot：不承诺。
- **退役 ESP 上的 `slot_x` 副本和直连条目**，HAL 回到上游 `boot-service.default`：推到 1.x，前提是 live 和救援改为自带内核。
- **在 gk3boot 里链式启动 Windows**：会改变 BitLocker 度量链，Windows 继续由 systemd-boot 启动。
- AVB、`flashing lock`、Secure Boot 签名、recovery（#39）、逻辑分区 / `update-super` / `fastboot boot` / `fetch`。
- `androidboot.bootreason`（要 EFI_RESETREASON，提供方未证实）、改 `serialno`。
- 中文 / 横屏的 UEFI 图形界面（1.0 的交互界面在 Linux 执行端，英文）。
- 开机"按住音量下"直接进 fastboot（理由见 §4.3.5）。
- 安全擦除（NVMe Sanitize / Deallocate）。
- 双系统方面：XBOOTLDR（解决 100 MiB ESP）；从 live 卸载 Android；Windows 侧"开机预置 OneShot"的计划任务**默认不做**（Windows 里的重启回 Windows，靠"Windows 为默认"解决；U25 建议 D4/D6 证实 Windows 能写变量后作为伴随工具的选项提前到 1.0.x）；在 NVRAM 建 bootmgfw 的备用启动项（F9 的计数语义不明，§4.9.2）；Android 自动修复 `BOOTAA64`（会让 BitLocker 要密钥，§4.9.6）。

### 1.4 术语

| 术语 | 含义 |
|---|---|
| 入口 / gk3boot | `\EFI\gk3boot\<ver>\gk3boot.efi`，本文的主角 |
| 外壳 | systemd-boot 257.13，仍在 `EFI/BOOT/BOOTAA64.EFI` |
| 直连条目 | 今天的 `<mid>-android-{a,b}.conf`，直接启动 ESP 上的 `slot_x` 副本。1.0 起降为回落路径 |
| 执行端 | 同一内核 + `fastboot.img`（静态 initramfs）+ `gk3-fastbootd`，负责 fastboot、恢复出厂、恢复 / 引导菜单 |
| BCB / BCAB / VAB 消息 | misc 偏移 0 的 `bootloader_message`；偏移 2048 的 `bootloader_control`（魔数 `BCAB`）；偏移 32 KiB 的 `misc_virtual_ab_message` |
| GK3 记录 | misc 偏移 8 KiB 的自有结构（延续 C′ §4.2.6 的位置，内容改了，见 §4.5） |
| H2 / H1 交接 | H2：从 `boot_x` 分区读到内存缓冲区后 LoadImage；H1：按文件设备路径 LoadImage ESP 上的 `slot_x/Image` |
| bless | 把条目文件名里的启动计数（`+N[-M]`）去掉，表示"已确认可用" |

---

## 2. 现状与约束（附出处）

C′ 的 §2（引导链、意图丢失、BCB 残留、#39、分区、VAB、USB、live）仍然有效，这里只补充和修正本轮新核实的部分。

### 2.1 固件（BIOS 2.16，"EFI v2.7 by Qualcomm Technologies"）

- **启动选择**：QcomBds 用的是 edk2 UefiBootManagerLib。启动选项执行前会设 5 分钟看门狗（`edk2 BmBoot.c:2148`）。~~本机没有 Boot####~~（2026-10-05 更正，§4.9.2）：华为策略每次开机都会删掉文件路径对不上的启动项，再给 ESP 建一个只指到分区的 `Windows Boot Manager (<设备名>)` 项，启动它时加载的就是回落路径 `\EFI\BOOT\BOOTAA64.EFI`。所以"`BOOTAA64` 决定一切"的结论成立，双系统机器上也是如此（待 D1/D2）。
- **华为启动失败计数**：`CheckResetCount`（QcomBds 0x8c24）读写 `OemConfig` 变量，有 `BootFail count = 3, System ShutDown!` 这条字符串。⇒ **入口绝不能把错误返回给固件**。
- **systemd-boot 的返回值语义**：chainload 的程序返回错误时，`run()` 直接 `return err` 给固件（`boot.c:2971-2973`）；返回 `EFI_SUCCESS` 时显示菜单，并把 timeout 置 0（`:2975-2976`）。
- **没有设备树服务**：固件不安装 DTB 配置表，也没有任何 DT_FIXUP 协议（对 `pe/*.efi` 逐字节扫描零命中）。DTB 一直是 systemd-boot 自己装的（`devicetree.c:78`、`:105-106`）。
- **存储**：NvmExpressDxe 提供 BlockIo / BlockIo2 / PassThru；PartitionDxe 是 edk2 原版，带 `EFI_PARTITION_INFO`（8cf2f62c-…，`PartitionInfo.h:23-55`）。主备 GPT 不一致时，PartitionDxe 会**自动写盘修复备份表**。**NVMe 分区上没有 EraseBlock**：这个 GUID 不在 NvmExpressDxe 里，PartitionDxe 只是把父设备的能力往下转发（风险评审字节扫描）。ABL 按 `gEfiNvme0Guid` 过滤根设备，本机不适用（`Board.c:383`）。
- **USB（只有静态证据）**：
  - UsbDeviceDxe 的依赖条件是 TRUE，会无条件安装 `EFI_USB_DEVICE_PROTOCOL` d9d9ce48-44b8-4f49-8e3e-2a3b927dc6c1，9 个函数的顺序与 ABL `EFIUsbDevice.h:359-370` 一致。
  - UsbConfigDxe 响应 `InitUsbControllerGuid` 1c0cffce-fc8d-4e44-8c78-9c9e5b530d36，但只在 core0 空闲时才把它起成 device，否则打印 "already enumerate…skip" 后返回成功（0x65f0-0x6734）。
  - 运行时 core0 处于什么状态**完全没验证**。
- **显示**：帧缓冲是竖装原生的 1600×2560。RotateScreen 会追加"宽高互换"的虚拟 GOP 模式，但只对 Blt 生效（0x155c-0x16b0）。
- **输入**：ButtonsDxe 提供 SimpleTextIn/Ex（音量上下、电源键），键位映射没能静态解出。CheckPostHotkey 在 POST 阶段自己读这三个键，用来进设置或 F12 菜单。I2cTouchPanel 会把 gpio174 配成 I2C，也就是已知坑 #26 那根脚。
- **度量**：FV 里有 MeasureBootDxe；607f766c 这个 GUID 同时对应 TrEE 和 TCG2 ⇒ 镜像度量**多半是开着的**（风险评审），待核。
- **其他**：RngDxe 提供 EFI_RNG；HwBcdOneKey 用 `HwStartImage` 钩住镜像启动；HwOpenWdtDxe 在 POST 时打开 EC 看门狗，谁、什么时候关掉它不明。

### 2.2 boot.img 与内核契约

- boot.img 是 **header v2**，单个分区里装 kernel + ramdisk + dtb，没有 vendor_boot / init_boot / AVB（`BoardConfig.mk:90-105`）。实际解析 `out/issues-1791053208/boot.img`（28,848,128 字节）：page 2048；kernel 15,589,888 字节，以 `MZ`+`zimg` 开头，是 EFI zboot PE；ramdisk 13,080,354 字节（gzip）；dtb 173,345 字节；cmdline 在 `@64[512]`，extra 在 `@608[1024]`（为空），**不含 slot_suffix**。
- **完整性校验可行**：头里偏移 576 的 `id` 等于 SHA1(kernel‖len, ramdisk‖len, second‖len, recovery_dtbo‖len, dtb‖len)。对上面那份文件复算得 `9274d5f8…e885e0`，与头里一致（Y 核实，风险评审复算）。
- **加载器的契约早有预留**：BoardConfig 写着"槽位后缀由加载器按 misc 里的槽位自己追加"（`BoardConfig.mk:107-110`）；postinstall 头注释写着自研 EFI 加载器就位后，拆包到 ESP 那一步就退役（`gaokun3-ota-postinstall.sh:19-20`）。
- **内核**：`CONFIG_EFI_STUB=y`、`EFI_ZBOOT=y`、`EFI_ARMSTUB_DTB_LOADER=y`、`CONFIG_CMDLINE=""`、`RANDOMIZE_BASE=y`；`# CONFIG_BOOT_CONFIG is not set` ⇒ androidboot.* **只能走 cmdline**（`init/property_service.cpp:1392-1408`）。
- **只能经 EFI stub 交接**：dtb 的 `/memory@80000000` reg 大小为 0（`sc8280xp.dtsi:389-393`），内存布局只能来自 EFI 内存图。所以要照 systemd-boot 的做法：LoadImage → LoadOptions（UCS-2 cmdline）→ `InstallConfigurationTable(DEVICE_TREE_GUID b1b621d5-f19c-41a5-830b-d9152c69aae0)` → initrd 走挂在 `LINUX_EFI_INITRD_MEDIA_GUID 5568e427-68fc-4f3d-ac74-ca555231cc68` 设备路径上的 LoadFile2 → StartImage（`include/linux/efi.h:382`、`:420`；`libstub/fdt.c:244-271`；`efi-stub-helper.c:511-624`；`initrd.c:9-120`）。**不能**像 GBL 那样 ExitBootServices 后直接跳（`gbl/efi/src/android_boot.rs:100-102`），那样会丢掉 EFI 内存图、ACPI、efivars 和 efi_pstore。
- **★ 缓冲区 LoadImage 在本机从没跑过**：systemd-boot 的 type1 条目走 `image_start → make_file_device_path → shim_load_image(path)`，是按文件设备路径加载的（`boot.c:2563-2576`）；`linux_exec`（`linux.c:80-144`）只有 UKI stub 一处调用（`stub.c:1275`）。X 和契约摸底说的"从内存 LoadImage 已在本机验证"**是错的**（三份评审一致纠正）。
- **slot_suffix 是硬依赖**：缺了它，libboot_control 的 `Init` 失败（`libboot_control.cpp:198-206`），本机 HAL 的 `CHECK(impl_.Init())` 崩溃（`BootControl.cpp:27-29`），fs_mgr 也选不了槽（`libfstab/slotselect.cpp:46-53`）。

### 2.3 misc 布局（已核实）

| 偏移 | 内容 | 出处 |
|---|---|---|
| 0–2 KiB | BCB：`command[32] status[32] recovery[768] stage[32] reserved[1184]` | `bootloader_message.h:67-84` |
| 2048 | `bootloader_control`，32 字节：`slot_suffix[4]`、magic `0x42414342`、version 1、9 位位域（nb_slot:3 / recovery_tries:3 / merge_status:3）、`slot_info[4]`，**每槽 u16**（priority:4、tries:3、successful:1、verity_corrupted:1）、`crc32_le`（前 28 字节） | `hardware-interfaces boot/1.1/default/boot_control/include/private/boot_control_definition.h:41-48`、`:59-107`；GBL `libgbl/src/slots/android.rs:72-121`、`:200-212` |
| 2K–16K | 按定义归"Vendor's bootloader"所有，我们就是这个 vendor bootloader | `bootloader_message.h:24-30` |
| 8 KiB | **GK3 记录**（本设计，"无人使用"待 E1 核实） | §4.5 |
| 16 KiB | wipe package | `bootloader_message.h:24-35` |
| 32 KiB | `misc_virtual_ab_message`：v2，magic `0x56740AB0`，merge_status，source_slot | `bootloader_message.h:155-160`；`libboot_control.cpp:403-440` |

- **实机 dump 解码**（上一轮只读读出）：`misc+0x800 = 5f61 0000 4243 4142 0102 0000 9f00 0e00 … 67dd c320`。按上表布局对前 28 字节算 zlib CRC32，得 `67ddc320`，与盘上一致 ⇒ 布局确认。解码为 `_a`=0x009f（priority 15、tries 1、已成功），`_b`=0x000e（priority 14、tries 0，不可启动）。上一轮"每槽 1 字节"的推断不对。32K 处是 v2、NONE、source 0。
- **libboot_control 语义**：
  - `setActive`：目标槽 priority 15、tries 6，其他槽中 ≥15 的降到 14，并清 verity_corrupted（`:282-314`）；
  - `markBootSuccessful`：successful=1、tries=1（`:316-330`）；
  - CRC 坏时重建：每槽 priority 7、tries 7，只有当前槽标 successful（`:140-180`）；
  - `kDefaultBootAttempts=7`（`:42`）。
- **GBL 的 set_active 写 7/7/6，与 HAL 不同 ⇒ 我们一律照 libboot_control 写。**
- **选槽算法**（GBL 语义）：在 `successful || tries>0` 的槽里取 priority 最高的，同分时 `_a` 优先；未成功的槽启动前 tries−1 并写回；已成功的槽不扣（`slots/android.rs:280-305`、`:328-377`）。
- **VAB**：libsnapshot 写状态时会经 HAL 同步 merge_status（`snapshot.cpp:3276-3316`）⇒ bootloader 不用挂 `/metadata`。MERGING 时禁止切槽；SNAPSHOTTED 或 MERGING 时禁止擦写 userdata / metadata / misc（`fastboot/device/commands.cpp:72-88`、`:351-368`）。回到源槽时，first-stage init 会写 rollback-indicator（`snapshot.cpp:2459-2497`）⇒ **只要入口扣 tries，VAB 就能自愈。今天没有任何组件扣 tries。**

### 2.4 Android 侧现状

- **init 写 BCB**（`init/reboot.cpp:899-965`）：
  - `bootloader` → `bootonce-bootloader`；
  - `fastboot`（本机有动态分区）→ `boot-recovery` + `recovery\n--fastboot\n`；
  - `recovery` → command 为空时才写 `boot-recovery`（`:923-937`）。
  - 恢复出厂由 uncrypt 写 `--wipe_data`。
  - 内核丢掉 reboot 参数（`efi=noruntime`，reboot-mode 没有 mode）。
- **★ `markBootSuccessful` 只在当前槽还没标成功时才被调用**（`update_verifier.cpp:331-381`，在 zygote-start 时 `exec_start`，`init.rc:1137-1140`；fstab 里 `/data` 没有 checkpoint）。
  - ⇒ C′ §2.1 写的"markBootSuccessful 每次开机都重写 default"**不对**：只有 OTA 后第一次成功开机时才会重写。
  - ⇒ 任何"靠它在每次开机清零或确认"的设计都不成立（Z 的决策看门狗、Y 的 ESP 写入频率论证，都栽在这里）。
- update_verifier 看到 `veritymode` 为空或 disabled 时会跳过块校验（`update_verifier.cpp:340-357`）。
- **HAL 的 EspSlot**：`setActiveBootSlot` 写完 misc 后，把 loader.conf 的 default 改成 `*-android-x.conf`，改不成就整个调用失败（`EspSlot.cpp:45-47`、`:142-194`；`BootControl.cpp:114-149`）。
- **postinstall**（来自新 vendor、在旧系统里执行，`POSTINSTALL_OPTIONAL=false`）：拆 `boot_<目标槽>` 到 ESP，同步 options，铺 recovery-ramdisk（`gaokun3-ota-postinstall.sh:57-187`；`BoardConfig.mk:213-218`）。它的域**没有 misc 权限**（`sepolicy/postinstall.te:49`）。
- **属性**：`sys.boot_completed` 是 `boot_status_prop`（`refs/lineage-sepolicy/private/property_contexts:952`），vendor_init 可以读（`private/vendor_init.te:316`）。`ro.boot.*` 落在 `bootloader_prop`（`:1046`），`ro.bootloader` 同样（`:1074`）。

### 2.5 systemd-boot 257.13 的相关行为（本轮源码核实）

- **默认项选择优先级**：`LoaderEntryOneShot` > `LoaderEntryDefault` 变量 > loader.conf 的 `default` > 第一个条目（`boot.c:1788-1824`）。OneShot 在 drivers 之后读取并删除（`:1637-1640`，删除时带 NON_VOLATILE 属性）。
- **排序**：先比计数是否用完（tries_left==0 的排最后，`:1710-1714`），再比 sort-key、machine-id、version（降序）、id；default 和 OneShot 都用 `efi_fnmatch`，取排序后的第一个匹配（`:1708-1783`）。
- **启动计数**：文件名 `名字+剩余[-已用].conf`，条目 id 会去掉计数部分（`:1340-1376`、`:1365-1371`）。启动前改名递减，并设易失变量 `LoaderBootCountPath`（`:1384-1421`）。
- type1 条目的 `linux` / `efi` 文件不存在时，**整个条目被跳过**（`:1531-1535`）。
- efi 条目会把 `options` 作为 LoadOptions 传过去，也会装 devicetree（`:2543` 起、`:2600-2624`）。
- 启动条目前会先 `process_random_seed`（`image_start` 之前，约 `:2967-2969`）⇒ 被它启动的入口天然继承随机种子表。
- `LoaderConfigTimeoutOneShot` 会强制下一次显示菜单（`:1617-1630`、`:2922-2934`）。
- **按键**：菜单里任何按键都会取消倒计时（约 `:881`），音量键移动高亮（约 `:908`）；`menu-hidden` 时先读 100 ms 按键，音量键查不到条目时直接开菜单（`:2925-2934`）；音量上下 = 移动，SCAN_SUSPEND = 确认（`:899-949`）。等待按键时每 5 分钟重新武装一次看门狗（`console.c:81-97`）。
- **drivers**：只加载 `\EFI\systemd\drivers\*aa64.efi`，且必须是 BS/RT driver 镜像。返回 EFI_ABORTED 不计入成功数，因而不触发 reconnect（`drivers.c:21-45`、`:100-112`）。这一条只与 Z 相关。
- **Windows**：ESP 上有 `bootmgfw.efi` 时自动加 `auto-windows`；BitLocker 场景用 BootNext 重启（`:2081-2150`）。

### 2.6 安装器 / Windows 脚本 / 开发脚本

- **安装器**：
  - 把 misc 整块清零（`installer-lib.sh:838-843`），同一份 boot.img 同时写进 `boot_a` 和 `boot_b`；
  - 直连条目的 sort-key 为 `zandroid<槽>`（`:921-929`），options 是 `$cmdline androidboot.slot_suffix=_$slot`（`:918`）；
  - **会把"别的 machine-id 目录下的 `*-android-[ab].conf`"改名停用**（`:879-887`），这条会误伤新条目；
  - 救援条目借用 `slot_a` 的内核（`:965`），cmdline 用 `gk3__rescue_cmdline`（`:1092-1098`）。
- **Windows 脚本**：`-Uninstall` 递归删除 `EFI\gaokun3`（`gaokun3-setup.ps1:267`）；`Format-LoaderConf` 只在 loader.conf 不存在时才写（`:184-187`、`:480-483`）。
- **`install-ota-local.sh` 第 4 步**只把 loader.conf 的 default 改回旧槽，不动 misc（`:140-152`）。入口改为以 misc 为准之后，这张安全网**会静默失效**。
- **`boot-oneshot.sh:51-53`** 用"文件是否存在"来检查条目，而 OneShot 匹配的是去掉计数之后的 id。

### 2.7 硬约束汇总

| # | 约束 | 依据 |
|---|---|---|
| E-K1 | 入口出错不能返回错误码，也不能停在不倒计时的菜单上 | §2.1、§2.5 |
| E-K2 | 只能经内核 EFI stub 交接：LoadImage + LoadOptions + DTB 表 + LoadFile2 initrd | §2.2 |
| E-K3 | 每次都追加 `androidboot.slot_suffix=_x` | §2.2 |
| E-K4 | `bootloader_control` 只按 libboot_control 原语读写，写前算 CRC、写后读回；CRC 无效时**不写** | §2.3 |
| E-K5 | MERGING 时不切槽、不清数据 | §2.3 |
| E-K6 | 入口不能是两个槽共用的单点：失败要能回到今天的直连路径 | G-E6 |
| E-K7 | 存量 BCB 要先迁移（只清不执行），再启用任何 BCB 消费（C′ 的 K3） | C′ §2.3 |
| E-K8 | 入口文件不能放进 `EFI\gaokun3\`；新条目不能被安装器的停用逻辑误伤；测试条目不能匹配 `*-android-[ab].conf` | §2.6 |
| E-K9 | 正常路径不碰 USB，不启用触摸，不切 GOP 模式 | §2.1 |
| E-K10 | "开机完成"信号要挂在 `sys.boot_completed` 上，不能挂在 `markBootSuccessful` 上 | §2.4 |
| E-K11 | 上机实验要征得用户同意，并有人在场能长按电源键 | CLAUDE.md 操作禁忌 3 |

---

## 3. 方案比较与推荐

### 3.1 三套方案

- **X**：以高通开源 ABL（LinuxLoader + FastbootLib）为骨架，用 EDK2 / C 写 gk3boot。fastboot 直接跑在固件的 UsbDevice 协议上（d9d9ce48 / 1c0cffce），USB 不通时退到 Linux 执行端。UEFI 内还要同步 ESP、清数据。
- **Y**：用 Rust 写 gk3boot，从 `boot_x` 读 boot.img，按 misc 选槽、扣 tries、分派 BCB，以带计数的默认 efi 条目挂在 systemd-boot 下。fastboot 由 gk3boot 引导"同一内核 + 静态 initramfs"，跑 C′ 的 `gk3-fastbootd`。
- **Z**：在 `\EFI\systemd\drivers\` 放一个策略驱动 `gk3policy`，只读 misc、写 `LoaderEntryOneShot`，内核仍由 systemd-boot 加载 ESP 副本；fastboot 是 C′ 原样（独立内核 + OneShot 条目）。

### 3.2 比较表

| 维度 | X：ABL 骨架 + UEFI USB | Y：efi 条目入口 + Linux 执行端 | Z：systemd-boot 驱动 + C′ |
|---|---|---|---|
| 可行性 | USB 只有静态证据，运行时 core0 状态未知（E4u）；缓冲区 LoadImage 未验证，却被当成"已验证"（事实错误） | 缓冲区 LoadImage 未验证，但被正确标成门槛（E4），退路明确；执行端可以在容器里离线测全 | 只用 systemd-boot 已验证的路径，可行性最高 |
| 风险 | UEFI 里写盘、刷 super、FAT 同步，变砖面最大；交棒前就 bless，交接故障不消耗计数 | 交棒前重新武装计数，同样兜不住交接故障（已修正，见 §4.12）；每次开机两次 FAT 改名 | 每次开机写 NV 变量；决策看门狗在正常使用中会自己跳闸；自禁用不粘滞；驱动在所有启动路径前运行，可能被度量进 PCR4 |
| 体验 | 最像手机，入口内就有 fastboot；但 ConOut 文字在竖屏上可能是侧着的，`is-userspace=no` 会让 `fastboot reboot fastboot` 报错 | 定位最清楚；执行端用 fbcon，文字是横的，按键名已核实；冷启动进 fastboot 避开 #52 / A6 | 不是"一个入口"：菜单按槽列，内核来自 ESP 副本，进 fastboot 要冷启一个独立内核；在菜单里改选 Windows 会白扣 tries |
| 用户需求覆盖 | 完整 | 完整（缺入口内 USB，1.x 补） | 约 85–90% 功能，观感达不到 |
| 成本 | 代码面最大；评审重估 10–12 周以上，E4u 不过再加 2–3 周；上机 7–9 次 | 方案自估 6–8 周，评审重估 **8–10 周**；上机 5–6 次；引入 Rust 是长期成本 | 8–11 周，其中执行端 4–5 周省不掉；1.x 还要另写入口，驱动多半作废 |
| 风险评审 | 4.5 | **6.5** | 6 |
| 体验评审 | 6.5 | **7** | 4.5 |
| 成本评审 | 5 | **7** | 6 |
| **平均** | **5.3** | **6.8** | **5.5** |

### 3.3 推荐：Y 为骨架（含 §8 的修正），Z 作门槛不过时的退化形态，X 的 UEFI USB 作为 1.x 演进

三份评审都选 Y 作 1.0 骨架，同时都要求下面这些修正，本文全部采纳：

1. **缓冲区 LoadImage 是第一道上机门槛（E4）**。不通时退化为 **H1**：仍由 gk3boot 做全部决策，只是改按文件设备路径加载 ESP 上的 `slot_x/Image`，也就是 systemd-boot 已在本机验证过的那类调用。决策层的成果全部保留，不必退回 C′ 的关机桥（成本评审）。如果连 H1 也不通，才退化成 Z 的形态：决策用 OneShot 表达，交接留给 systemd-boot。
2. **计数改由 Android 侧在 `sys.boot_completed` 时 bless**，入口自己不碰计数。这样交接故障也会消耗计数（风险、体验、成本三份评审一致）。
3. **入口更新做成分阶段激活**（一次只换一样）；0.7→1.0 那一跳是唯一例外（§4.10）。
4. **1.0 不在 UEFI 里放任何写盘代码**：恢复出厂、刷写都交给 Linux 执行端（NVMe 上本来也没有 EraseBlock）。
5. **"开机按住音量下"不作为 1.0 的进入方式**：会被 systemd-boot 吃掉（§4.3.5）。
6. **工作量按 8–10 周排期**。
7. **语言改由用户决定**（U2）。本文建议用 C，与执行端共用同一份核心库，三份 misc 解析降到两份（核心库 + HAL 的 libboot_control）。

Z 的几项可取之处吸收进 Y：
- 用户在菜单里选 Windows 不扣 tries（Y 天然如此：只有 Android 条目才会运行 gk3boot）；
- 执行端里的"引导菜单"用 evdev 读按键，可以直接选 Windows、安装器、救援（§4.4.4）；
- 未知命令要清掉，不然会堵住 BCB 通道。

X 的价值留到 1.x：UEFI 内的 USB 传输（ABL `FastbootMain.c:163-259` 加 `UsbDescriptors.c`，BSD 许可），以及基于它的 `fastboot boot <img>`。

---

## 4. 推荐方案详细设计

### 4.1 组件与代码基础

```
ESP（vfat，可能与 Windows 共用）
├─ EFI/BOOT/BOOTAA64.EFI              systemd-boot 257.13（不变：外壳 + 兜底菜单）
├─ EFI/systemd/systemd-bootaa64.efi    （不变）
├─ EFI/gk3boot/<ver>/gk3boot.efi       ★入口（约 0.3–0.6 MB，待实测）
├─ EFI/gk3boot/<ver>/fastboot.img      ★执行端 initramfs（2–4 MiB，C′ §4.2.2）
├─ EFI/gk3boot/<prev>/…                上一版（已确认可用的那版）
├─ loader/loader.conf                  default *-android-a.conf（HAL 照旧写，1.0 不改语义）
├─ loader/entries/
│   ├─ gk3boot-android-{a,b}[+3].conf  ★ efi 条目，sort-key 0gk3，title "Android"
│   ├─ gk3prev-android-{a,b}.conf      ★ 上一版入口（只在有过轮换时才有）
│   ├─ gk3boot-tools.conf              ★ efi 条目，options gk3.action=menu，title "Android 引导菜单 / Fastboot"
│   ├─ <mid>-android-{a,b}.conf        直连条目（今天的老路，降为回落，title 改为 "Android 直连 a/b（救急）"）
│   └─ gaokun3-live.conf / <mid>-int-ubuntu.conf / auto-windows（不变）
└─ <mid>/android/slot_{a,b}/{Image,gaokun3.dtb,ramdisk.img,cmdline.txt}   回落副本（1.0 继续铺；live / 救援借用）
```

| 组件 | 语言 / 位置 | 职责 |
|---|---|---|
| `libgk3core` | freestanding C（U2 选了 Rust 就是 no_std crate）；`tools/gk3boot/core/` | GPT（头 CRC + 表 CRC，只信主表）、boot.img v0–2 加 SHA1(id)、BCB、BCAB、virtual_ab、GK3 记录、选槽 / 扣 tries / set_active 原语、cmdline 变换。**同一份代码**编进 gk3boot.efi、执行端 `gk3-fastbootd`，以及主机测试和 `gk3-misc` CLI |
| `gk3boot.efi` | `tools/gk3boot/efi/`，arm64 Docker（与 live 同款）里构建 | 定位盘与分区、决策、交接（H2 / H1）、fail-open、观察模式、最简 ConOut 错误页 |
| 执行端 | C′ §4.2.1–4.2.2 子集 + 改动（§4.4） | fastboot、恢复出厂、恢复菜单、引导菜单 |
| `gk3-misc` | 主机版和 aarch64 静态版 CLI，链接 `libgk3core` | 安装器初始化 misc；开发时只读 dump / 解码（取代 C′ 的 `misc-decode.sh`） |
| `gk3-esp-sync` | C′ §4.2.5 | postinstall、执行端、安装器共用的 ESP 写入规则 |
| boot HAL 改动 | `device/huawei/gaokun3/boot_control/` | 开机完成线程（§4.6.1） |

**代码基础与取舍**（依据 oss 摸底和三份方案）：

- **交接**：照 systemd-boot `linux.c:93-144`、`initrd.c:9-120`、`devicetree.c:78-107` 的**写法重写**，不拷代码，避免 LGPL-2.1+ 牵连入口的许可证（U10）。
- **GBL**：不作基础。它不认 zboot（`load.rs:629-667`）；slot_suffix 只写进 bootconfig（`mod.rs:220`），而本机没开 BOOT_CONFIG，OsConfiguration 协议也没有改 cmdline 的接口；出错时走 `cold_reset`（`efi/src/ops.rs:395-396`）；构建只支持 Linux x86_64 + Bazel。只拿它的 BCAB 实现和单测（`libgbl/src/slots/android.rs`）、BCB 解析（`libmisc/src/lib.rs`）做**对照测试向量**。
- **ABL**：不能整体用。它的 A/B 存在 GPT 属性位里，会改写与 Windows 共用的 GPT（`PartitionTableUpdate.h:138-148`）；选 DTB 要 qcom,msm-id；交接是直跳；还依赖 4 个固件里没有的协议。1.x 只移植它的 USB 传输件。
- **EDK2 EmbeddedPkg / U-Boot**：不用（只认 v0 头；U-Boot 的 EFI app 只支持 x86）。

### 4.2 启动流程总览

```
上电 → 固件 POST（CheckPostHotkey：电源 / 音量键 → 设置或 F12 菜单，不归我们管）
 → QcomBds：华为策略删无效项、建 "Windows Boot Manager (…)" 分区项（§4.9.2）→ \EFI\BOOT\BOOTAA64.EFI = systemd-boot 257.13
 → systemd-boot：OneShot > LoaderEntryDefault > loader.conf default
      default "*-android-x.conf" 排序后先命中 gk3boot-android-x[+N]（sort-key 0gk3 < zandroid*）
      （带计数时：改名递减，设 LoaderBootCountPath）→ StartImage(gk3boot, LoadOptions=options)
 → gk3boot
      0 解析 LoadOptions（gk3.hint / gk3.mid / gk3.action / gk3.observe）；SetWatchdogTimer(120 s)（是否真会复位待 E6）
        读 LoaderEntryDefault：匹配 *-android-* 就删掉；记下"默认是不是 Windows"（§4.9.3）
      1 定位本盘：LoadedImage→DeviceHandle 的设备路径去掉 HD 节点 = 整盘 → BlockIo → 自己解析主 GPT
        → misc / boot_a / boot_b / super / userdata / metadata 各恰好出现一次
        （本盘找不到时扫所有整盘，要求全局唯一，否则 fail-open，§4.9.11）
      2 读 misc 0–64 KiB：BCB、BCAB、GK3、virtual_ab
      3 首跑迁移（没有迁移标记时）→ 清存量 BCB，本次不执行
      4 GK3 一次性意图（执行端留下的"下次去 systemd-boot 菜单"；双系统的 next=windows / set_default / clean_poweroff，
        Android 有待办时后两类作废，§4.9.3）
      5 gk3.action / BCB 分派 → 去执行端（fastboot / wipe / 菜单）或继续
      6 连续未完成启动计数 ≥ 阈值 → 执行端菜单（why=bootloop）
      7 选槽 + 扣 tries（BCAB）
      8 加载 boot_S（H2）并校验 SHA1(id)；失败 → 另一槽 / ESP 副本（H1）
      9 拼 cmdline →（默认是 Windows 时预置 LoaderEntryOneShot=*-android-<hint>.conf）
        → 交接：LoadImage → LoadOptions → DTB 表 → LoadFile2 → StartImage
      ✗ 任何内部错误 → fail-open 阶梯（§4.12），绝不 return 错误码
 → 内核 EFI stub（zboot）→ Android
 → Android：zygote-start 时 update_verifier → markBootSuccessful（只在未成功时）
           sys.boot_completed=1 → HAL 开机完成线程：bless 入口条目、清 GK3 连续计数、导出事件、激活分阶段的新入口
```

### 4.3 启动流程细节

#### 4.3.1 正常启动

- 正常路径**不等按键、不画界面、不碰 USB / GOP / 触摸**（E-K9）。只有观察模式会在 ConOut 打印一行 trace。
- **读取量**：misc 64 KiB，加上选中槽的 boot.img（约 29 MB）和一次 SHA1。目标额外耗时 < 0.5 s，E4 实测。
- **cmdline** = 头里的 `cmdline` + `extra_cmdline`（即 BOARD_KERNEL_CMDLINE，`BoardConfig.mk:123-134`），再追加：
  - ` androidboot.slot_suffix=_S`（必需）；
  - ` androidboot.bootloader=gk3boot-<ver>`（→ `ro.bootloader`，`property_service.cpp:1355`；属性上下文 `property_contexts:1074`）；
  - ` androidboot.gk3boot.event=<none|fallback|boot_corrupt|bcb_dropped|wipe_failed|…>`；
  - ` androidboot.gk3boot.entry=<自己条目的文件名>`（取自 `LoaderBootCountPath`，供 bless 用）。
  - 不再加 systemd-boot 为兼容老内核追加的 `initrd=\…`。
- 不开 CONFIG_BOOT_CONFIG，boot.img 格式和内核**都不用为入口改**。

#### 4.3.2 A/B 选槽与 tries

1. **BCAB 无效**（magic / version / CRC 任一不对，或 nb_slot≠2）：**不写**，按 `gk3.hint` 启动（hint 就是 HAL 镜像进 default 的那个字母），交给 HAL 初始化。
2. **可启动**：`tries>0 || successful`。在可启动的槽里取 priority 最高的，同分时取 `_a`。
3. **选中的槽未成功**：tries−1 → 重算 CRC → 写回 → FlushBlocks → 读回比对 → 启动。已成功的槽不扣。入口**只改 tries**：priority 和 successful 归 HAL 与执行端的 `set_active` 管。
4. **VAB**：
   - `merge_status==MERGING` 时**禁止换槽**：选中的槽不可启动就不回落，改进执行端（why=merging）并显示原因；
   - SNAPSHOTTED 时允许回落到源槽，由 first-stage init 自愈；
   - SNAPSHOTTED 且当前槽 == source_slot 时视为 NONE（`bootloader_message.cpp:307-315`）。
5. **两个槽都不可启动**：进执行端（why=noslot），不去猜一个槽硬启动。
6. **成功确认**：Android 侧不变（update_verifier → markBootSuccessful）。
7. **回滚时序**：setActive 给新槽 tries 6；每次没起来扣 1；内核 panic（`CONFIG_PANIC_TIMEOUT=10`，`docs/relnotes/v0.7.1-alpha-config.txt:7761`）或 init 的 `reboot()` 会自动消耗一次，硬挂要长按电源键（固件看门狗能否自动复位待 E6）；扣完后回到旧槽，event 记为 `fallback`，Parts 通知。

#### 4.3.3 启动失败的回落（由内向外）

| 失败 | 谁接住 | 结果 |
|---|---|---|
| `boot_S` 头或 SHA1 不对 | gk3boot：本次换另一个可启动的槽，**不写 misc**（可能只是瞬时读错）；两个都坏 → H1 用 ESP 副本；再坏 → 执行端（内核取 ESP 副本） | event=`boot_corrupt` |
| 新槽内核 / init 起不来（未确认） | BCAB tries | 回到旧槽 |
| 已确认的槽之后反复起不来 | GK3 "连续未完成启动"计数（入口每次 +1，开机完成时清零）≥5 → 执行端菜单（why=bootloop） | 用户可以选另一槽、fastboot、恢复出厂 |
| 交接本身有故障（新入口） | 入口条目计数（只有新部署 / 新激活的入口才带 `+3`，开机完成才 bless）→ gk3prev → 直连条目 | 回到今天的路径 |
| gk3boot 内部错误 | fail-open 阶梯（§4.12） | 直连条目 |
| ESP 或 systemd-boot 坏了 | U 盘 live（插着 U 盘时固件优先走 U 盘的 ESP，`docs/hw-inventory.md` 8quater） | 重新安装并保留数据，或删掉入口 |

#### 4.3.4 BCB 各命令

| BCB（command + recovery 字段） | 来源 | gk3boot 的处理 |
|---|---|---|
| 空 | — | 正常启动 |
| `bootonce-bootloader` | `adb reboot bootloader` | **先清 command 并写回**（GBL 语义：执行端坏了也不会循环），再进执行端，why=bootloader |
| `boot-recovery` + `--fastboot`、`boot-fastboot` | `adb reboot fastboot` | 同上，why=fastboot（fastbootd 也是进入时就清，`fastboot/fastboot.cpp:96`） |
| `boot-recovery` + `--wipe_data`（含 `--reason=…`） | 设置 → 清除所有数据 | 进执行端，why=wipe。**BCB 由执行端擦完后才清**（可重入）。GK3 给同一份 BCB 计次，连续 3 次进入都没被清 → gk3boot 自己清掉，正常启动，event=`wipe_failed`，Parts 通知 |
| `boot-recovery` + `--prompt_and_wipe_data` | RescueParty | why=prompt_wipe，执行端必须按键确认，**永不自动清** |
| 只有 `boot-recovery`，或带 `--update_package` / `--sideload` / `--wipe_cache` / `--rescue` 等 | `adb reboot recovery` 等 | why=recovery → 执行端的恢复菜单（说明哪些不支持），由执行端清除。**永不启动 recovery ramdisk ⇒ 绕开 #39** |
| `boot-quiescent`、`boot-rescue`、乱码 | — | 原文记进 GK3，**清掉**，正常启动。不清的话，init 以后只在 command 为空时才写，通道会被堵住（`reboot.cpp:923-937`） |

- **存量 BCB**：迁移标记写入之前的 BCB 一律只清不执行（§4.10）。
- **分派计数**放在 GK3，**不借** BCAB 的 `recovery_tries_remaining`，保持 BCAB 只按 libboot_control 的语义被写。
- 执行端存在之前（分阶段交付），BCB 分派开关保持关闭：只记录、不消费，与今天一样。

#### 4.3.5 进 fastboot / 菜单的方式

1. **BCB**（adb、设置、RescueParty）：无需按键，主路径。
2. **systemd-boot 菜单里的 `gk3boot-tools.conf`**：title "Android 引导菜单 / Fastboot"，sort-key 紧跟 gk3boot-android。接键盘盖时可以选；只用音量键 / 电源键能不能操作取决于 INST-18（E3）。
3. **自动进入**：两槽都不可启动、bootloop 阈值、MERGING 下选中的槽不可启动。
4. **执行端菜单**里的"Fastboot"。
5. **"开机按住音量下"不进 1.0**：systemd-boot 显示菜单时任何键都会取消倒计时，音量键还会移动高亮（`boot.c` 约 `:881`、`:908`）；`menu-hidden` 时 100 ms 读键会直接开菜单（`:2925-2934`）。所以按键永远到不了 gk3boot。1.x 若改成 `menu-disabled`，再由 gk3boot 自己读键，前提是 E3 证明按键在那一刻还留在 ConIn 里（U3）。

#### 4.3.6 无键盘

- 不需要按键也能走通的：tries 回落、入口计数回落、BCB 驱动（`adb reboot bootloader`、设置里恢复出厂）、两槽都坏 / bootloop 自动进执行端菜单。
- **执行端菜单**用 evdev 读 `pmic_pwrkey`、`pmic_resin`、`gpio-keys`（C′ §4.8 已核实设备名），音量上下选择、电源键确认。**这是 1.0 给平板姿态的主通道**，不依赖 UEFI 的键位映射。
- 双系统用户在平板姿态下切 Windows：主路径是 Parts 的"重启到 Windows"（GK3 意图，§4.9.4）；后备是 `adb reboot bootloader` 或 Parts 的"重启到引导菜单"（走标准 `reboot,bootloader`）→ 执行端菜单 → "Other systems"（§4.4.4）。双系统的 systemd-boot 菜单固定显示 5 秒（U13），所以接着键盘盖时也能直接选。

### 4.4 fastboot 模式（执行端）

#### 4.4.1 进入

gk3boot 用和 Android 同一套交接代码引导：
- **内核**按顺序取：最近一个已成功槽的 `boot_x`（SHA1 通过）→ 另一个槽 → ESP 上的 `slot_x/{Image,gaokun3.dtb}`。内核与 Android 永远是同一版，C′ 的 R8 不再存在，也**不需要** C′ §4.2.3 的独立内核副本（ESP 省 13–16 MB）。
- **initramfs**：`\EFI\gk3boot\<ver>\fastboot.img`，与 gk3boot 同版本、同目录，一起轮换。
- **cmdline**：从 boot.img 的 cmdline 变换而来。规则与 `installer-lib.sh:1092-1098` 相同（去掉 `androidboot.*`、`init=`、`firmware_class.path=`），再去掉 `deferred_probe_timeout=10`（`BoardConfig.mk:130`），加上 `panic=10 gk3.mode=fastboot gk3.why=<…> gk3.slot=<x> gk3.bootver=<ver> gk3.disk=<misc 的 PARTUUID>`。
  - 执行端据 `gk3.disk` 确定目标盘，不再需要 C′ §4.4 的 `LoaderDevicePartUUID` 推断；
  - 不过仍要校验六个名字在这块盘上各恰好出现一次。
- 进入一定是冷启动 ⇒ 不受 #52 / A6 影响；执行端照 C′ §4.7：不挂起，不 unbind dwc3。

#### 4.4.2 命令（沿用 C′ §4.5，以下是改动）

- `getvar`：
  - `version-bootloader` = gk3boot 的版本；
  - `current-slot` 取自 `gk3.slot`；
  - `slot-successful / slot-unbootable / slot-retry-count` 直接解 BCAB。布局已用实机 CRC 核实，C′ 那条"X2 之前 FAIL"的限制取消；E1 仍要核对 crDroid 树里的常量与 AOSP 1a56e38 一致。
- `is-userspace`：**yes**，沿用 C′ 的决定，`fastboot reboot fastboot` 走软重新枚举。代价是带 `super_empty.img` 的 `fastboot update` 会被主机端引向逻辑分区路径（`fastboot.cpp:1702-1711`、`:2122-2142`），1.0 对 `update-super` 和逻辑分区一律 FAIL，并在 INFO 里写明"请用 flash-all 或不带 super_empty 的 zip"。见 U4。
- `set_active`：照 libboot_control 原语写（目标槽 15/6，其他 ≥15 的降到 14，清 verity_corrupted），由 `libgk3core` 实现，并对拍 HAL 的逐字节结果。同步 loader.conf 的 default（直连回落要用）。MERGING 时拒绝；目标槽 unbootable、或 ESP 上缺 `slot_x` 时拒绝。
- `flash boot_a|boot_b`：写入 → 读回比对 → 同一条命令里调 `gk3-esp-sync`。ESP 同步失败时返回 FAIL，写明"boot 已写入，回落路径仍是旧内核"。入口以分区为准，所以不会出现 K4 那种"空刷"。
- `flash super`：只支持整块；刷完后若 active 槽不在新 LP 元数据服务的槽里，按 set_active 规则切过去。
- `reboot`：冷重启，BCB 为空就正常启动。`reboot-bootloader` / `reboot-fastboot`：软重新枚举。`reboot-recovery`：原地切到恢复菜单。
- `oem device-info`：增加 gk3boot 版本、GK3 记录、event、BCAB 和 VAB 解码。
- VID/PID 仍是 `18D1:4EE0`，接口 `0xff/0x42/0x03`（C′ §4.2.1）。

#### 4.4.3 恢复出厂

完全沿用 C′ §4.6：
- userdata：BLKDISCARD，再把开头和末尾各 1 MiB 写零，读回确认开头 4 KiB 全零；
- metadata：32 MiB 清零；
- 由 fs_mgr 识别 formattable 后重建（`partition_utils.cpp:42-66`、`fs_mgr.cpp:1634-1690`，**本机未实测，E10**）；
- misc 只清 BCB；
- VAB 守卫：MERGING 拒绝；Unverified 先回滚再擦（依赖 E1）。
- **免二次确认的条件**：迁移标记已存在，且 `gk3.why=wipe` 来自 BCB，且执行端读到的 BCB 原文与 gk3boot 记进 GK3 的摘要一致。这取代 C′ 的"意图记录"论证：标记之后出现的 BCB 只可能是 Android 写的。

#### 4.4.4 菜单（执行端，tty1 英文，fbcon 已横向）

- **恢复 / 引导菜单**：Boot Android（current slot）/ Boot other slot（高级）/ Fastboot / Factory reset（二次确认）/ Other systems / Reboot / Power off / Device info。
- **"Other systems"**：读 ESP 的 `loader/entries/`，列出 `auto-windows`（存在 `EFI/Microsoft/Boot/bootmgfw.efi` 时）、`gaokun3-live`、救援。
  - 选中后写 `LoaderEntryOneShot = <id>`：照 `scripts/boot-oneshot.sh` 的写法（属性 0x07、UTF-16LE + 双 NUL、先 `chattr -i`、写后回读），走内核的 uefisecapp。执行端不加载 SELinux 策略。然后重启。
  - 于是 Windows 仍由 systemd-boot 直接启动，度量链与今天手选 Windows 完全相同。
  - **efivarfs 写入在执行端里是否可用待 E6**。不可用时退化为：在 GK3 写一次性意图 `next=sdboot-menu`，gk3boot 下一次读到后直接返回 `EFI_SUCCESS`，systemd-boot 就停在不倒计时的菜单上（`boot.c:2975-2976`）。**不写** `LoaderConfigTimeoutOneShot`：它会留到下一次开机，再强制弹一次菜单（X 的错误）。
- **Boot other slot**：只做一次性启动，不改 active。通过 GK3 一次性意图 `next=slot:x` 实现，gk3boot 消费后清除，**不扣 tries**。
- 确认页没有超时自动执行。无主机连接、无按键 30 分钟后关机（C′ U6）。

### 4.5 GK3 记录（misc 8 KiB）

| 字段 | 写者 | 用途 |
|---|---|---|
| magic、version、CRC32 | 全部 | 有效性 |
| 迁移标记 + 被清掉的存量 BCB 摘要 | gk3boot（首跑）、安装器 | E-K7 |
| 分派记录：why、来源 BCB 摘要、当次的槽、同一份 BCB 的进入次数 | gk3boot | 免确认判据、3 次上限 |
| 连续未完成启动计数 | gk3boot +1；HAL 开机完成线程清零 | bootloop 检测 |
| 一次性意图：`next=sdboot-menu / slot:x / windows / none`，`set_default=windows\|android` | 执行端、HAL（Parts 请求）写；gk3boot 消费后清除 | 菜单出口；双系统的"重启到 Windows"和"默认启动系统"（§4.9.3、§4.9.4） |
| 默认系统的缓存（`android` / `windows`） | gk3boot 读 `LoaderEntryDefault` 后写入，只在值变化时写 | Android 侧不挂 efivarfs 也能知道默认系统：`gk3-misc mark-poweroff` 和 Parts 的显示都用它（§4.9.3） |
| `clean_poweroff` 标记 | vendor `on shutdown` 的 `gk3-misc mark-poweroff`（只在 Windows 为默认、目标是关机时写）；gk3boot 消费 | Windows 为默认时，从 Android 关机后冷开机进 Windows（§4.9.3） |
| 事件环（最近 N 条：fallback、boot_corrupt、bcb_dropped、wipe_failed、refused_merging…）+ 已通知位 | gk3boot、执行端写；HAL 读后置已通知位 | Android 通知 |

- 所有写入：先算 CRC，写完读回。CRC 无效时视为"无记录"，**不影响启动**。
- 首跑迁移会重建这个结构，并且只在 8 KiB 处写。
- "8 KiB 处无人使用"必须在 E1 用 grep 核实 libboot_control、libsnapshot、recovery。

### 4.6 Android 侧改动

#### 4.6.1 boot_control HAL

- **1.0 不改 setActive / markBootSuccessful 的语义**。EspSlot 照旧把槽镜像进 `default *-android-x.conf`；这个通配先命中 gk3boot 条目，default 里的槽字母只决定"入口计数用完时走哪条直连条目"。
- **新增"开机完成线程"**：
  - **触发**：vendor rc 写 `on property:sys.boot_completed=1` → `setprop vendor.gaokun3.boot.done 1`（vendor_init 可以读 `boot_status_prop`，`private/vendor_init.te:316`），HAL 等自己的 vendor 属性。这样 HAL 不用去读 `boot_status_prop`。该属性是 `system_restricted_prop`（`public/property.te:60`），vendor 直接读是否放行**待编译验证**，所以走 vendor 属性中转。
  - 动作 1：读 `ro.boot.gk3boot.entry`，那个条目文件名带计数就 rename 成不带计数的名字（**bless**），用的是已有的 ESP 挂载和写权限。
  - 动作 2：清 GK3 的连续未完成启动计数。HAL 已有 misc 读写权限。
  - 动作 3：有 `EFI/gk3boot/<new>/` 加 `gk3boot-android-*.conf.staged` 时，执行**分阶段激活**（§4.11）。
  - 动作 4：把 GK3 事件环和 `ro.boot.gk3boot.event` 导出成 `vendor.gaokun3.bootentry.*` 属性，供 Parts 通知；读完置已通知位。
  - 动作 5：`ro.boot.gk3boot` 为空 ⇒ 这次没经过入口（入口计数用完回落了，或者用户在菜单里对直连条目按 `d` 设了 `LoaderEntryDefault`，`boot.c:1788-1824`），设 `vendor.gaokun3.bootentry.bypassed=1` 并通知。通知里写明恢复办法：在菜单里高亮"Android"按 `d`，下次 gk3boot 会把这个精确 id 清掉（§4.9.3）。
  - 动作 6（只在 ESP 上有 `EFI/Microsoft/Boot/bootmgfw.efi` 时）：导出 `vendor.gaokun3.bootentry.windows=1`，Parts 据此决定显示"重启到 Windows"和"默认启动系统"；再比对 `EFI/BOOT/BOOTAA64.EFI` 和 `EFI/systemd/systemd-bootaa64.efi`，不同就通知"Windows 替换了启动器"。**只通知，不修**：改 `BOOTAA64` 会让 BitLocker 要密钥（§4.9.6）。
  - 动作 7（运行期，不限于开机完成）：Parts 设 `vendor.gaokun3.bootentry.request=next_windows|default_windows|default_android` 时，HAL 把它写成 GK3 一次性意图，回读后设 ack 属性，再由 Parts 发起重启（或提示"下次开机生效"）。
- **1.x**：EspSlot 退役，回到上游 `android.hardware.boot-service.default`（`hardware-interfaces boot/aidl/default/Android.bp:37-61`）。前提是直连回落条目不再依赖 default 字母，live / 救援自带内核。

#### 4.6.2 OTA postinstall

- 保留：拆 `boot_<目标槽>` 到 ESP、同步 options（回落副本）。
- **停铺** recovery-ramdisk，并删掉 ESP 上已有的那份和 `*-recovery-x.conf`（OTA-8，每槽约 15 MB）。
- **部署入口**：从 `/vendor/boot/gk3boot/<ver>/{gk3boot.efi,fastboot.img,SHA256SUMS}` 取文件，写到 `EFI/gk3boot/<ver>/`，每个文件都走 `.new` → cmp → rename。
  - **ESP 上还没有任何 gk3boot**（0.7→1.0）：直接写 `gk3boot-android-{a,b}+3.conf` 和 `gk3boot-tools.conf`，立即生效。
  - **已有 gk3boot**：只写 `gk3boot-android-{a,b}.conf.staged`（不以 `.conf` 结尾，systemd-boot 不读），由新槽开机完成后激活（§4.11）。
- 核空间时按真实写入量算（M4b 的教训）。postinstall **不碰 misc**（没有权限，还撞 neverallow）。

#### 4.6.3 BCB / 重启意图

**零改动**：init、uncrypt、RescueParty 按上游标准写 BCB。C′ 的 `gk3-bootintent`、efivarfs 类型、genfscon、`--boot` 重新路由**全部不需要**。

**双系统例外**（§4.9.3）：Windows 为默认时，vendor rc 的 `on shutdown` 要 `exec` 一次 `gk3-misc mark-poweroff`。它只读 `sys.powerctl` 和 GK3 里的默认系统缓存（§4.5），只写 misc 的 GK3 记录，**不碰 efivarfs**。Android 为默认时直接退出。它失败的后果只是"下次开机进 Android"。

#### 4.6.4 cmdline / bootconfig

- 静态部分照旧：BoardConfig → mkbootimg → boot.img 头。动态部分由 gk3boot 追加（§4.3.1）。
- 直连回落条目的 options 由 postinstall / `gk3-esp-sync` 从 `cmdline.txt` 同步，两条路径的 cmdline 同源。
- 不开 BOOT_CONFIG，不改内核格式。`serialno` 保持 `gaokun3`（C′ U5）；`bootreason` 推迟。

### 4.7 安装器与 Windows 脚本

**图形安装器**（`scripts/live/installer-lib.sh`）：
- **文件清单**：`gk3__esp_files`（`:654-662`）加入 `EFI/gk3boot/<ver>/{gk3boot.efi,fastboot.img}`（来源是 Release 附件，校验 sha256），去掉 recovery-ramdisk，保留 `slot_a/b` 三件套。
- **条目**：写 `gk3boot-android-{a,b}+3.conf`：
  ```
  title   Android
  efi     /EFI/gk3boot/<ver>/gk3boot.efi
  options gk3.hint=<x> gk3.mid=<mid>
  sort-key 0gk3
  version <ver>
  ```
  另写 `gk3boot-tools.conf`。直连条目的 title 改为"Android 直连 a/b（救急）"。`default *-android-a.conf` 不变。
- **必须修**：`:879-887` 的停用匹配收紧为 `^[0-9a-f]{32}-android-[ab]\.conf$`。反过来，旧版安装器 0.1.0-preview 在 1.0 的机器上会把 gk3boot 条目停用，结果退回直连路径，这是**安全的失败方向**。
- **misc**：清零后用 `gk3-misc init --slot a` 写一份合法的 BCAB：`_a` 为 priority 15、tries 6、未成功；**`_b` 为 priority 0、tries 0**（新装机器的 `_b` 没有 system，LP slot1 是陈旧元数据，C′ §2.6）。同时写 GK3 迁移标记。"重新安装 + 保留数据"同样处理。
- **loader.conf 的 timeout**：纯 Android 按 U3；双系统（ESP 上有 `EFI/Microsoft/Boot/bootmgfw.efi`）按 U13，写 `timeout 5`、不写 `menu-hidden`、不写 `reboot-for-bitlocker`、`auto-entries` 保持默认。
- **`gk3_esp_info`** 报告入口的版本、条目状态（计数、是否 staged）。
- **test-apply 新用例**：0.7.x 布局升 1.0；停用逻辑不碰 gk3 条目；ESP 上已有更新的入口（不降级）；空间不足；misc 字节核对。
- **双系统专项**（§4.9）：
  - 确认页：增加"默认启动哪个系统"（U12，预选 Android），选 Windows 时经 uefisecapp 写 `LoaderEntryDefault=auto-windows`；
  - Windows 卷是 BitLocker 且 `BOOTAA64` 要变时，强制确认"已拿到恢复密钥"（U16），文案按"走过脚本 / 从 U 盘来"分开（§4.9.7 规则 6）；Windows 卷处于休眠时拒绝写 ESP（U18，复用 `gk3__ntfs_hibernated`，`installer-lib.sh:1170`）；
  - 双系统时写 `gk3-windows.conf` 并在 loader.conf 写 `auto-entries no`（U22）；所有条目标题改成 ASCII；
  - live 开机时检查 `LoaderEntryDefault`：指向 live / 救援就提示一键清除；整盘清空式重新安装时删掉残留的 Loader 变量（§4.9.3）；
  - 完成页提示"回到 Windows 后安装伴随工具"并给下载地址（U23）；
  - **改文案**：`app_zh.arb:84`（modeAlongOk）、`:326`（confirmAlongHead）、`:365`（doneBody），以及 en 版和 `INSTALL.md:98`。原文"不会对你现有的分区进行任何更改""重新启动后，你将进入 Android"与事实不符，改成"只在空闲空间建分区；会在 EFI 分区里放入启动器（原文件已备份），开机会出现选择菜单"，完成页按所选的默认系统说明"开机默认进 X，切换方法……"；
  - 写 `BOOTAA64` 只在字节不同时写（U16）；
  - ESP 余量断言加上 Windows 和固件的 32 MiB（U17）；100 MiB 的 ESP 明确拒绝；
  - Android 分区设 GPT bit 0（U19，待 D4），绝不设 bit 1；
  - `gk3_esp_info` 增报：有没有 Windows、`BOOTAA64` 是否等于 systemd-boot、Boot#### 概况（live 自带 efibootmgr）、`LoaderEntryDefault`、ESP 余量；
  - machine-id 目录改按 `*-android-<槽>.conf` 的 `linux` 行取（§4.9.11），与 postinstall 共用；
  - `installer-lib.sh:893-894` 的注释"内核带 efi=noruntime，不指望 EFI 启动变量"已过时：uefisecapp 让变量可写（`fastboot-design.md:71`，#42），改成"能写，只是不依赖"。
- `build-usb.sh` 的 U 盘介质：只有 `esp` 分区，入口在 U 盘上找不到 misc，会走 fail-open。所以 U 盘介质**不放** gk3boot 条目，保持现状。

**Windows 脚本**（`scripts/windows/`）：
- 入口放在 `EFI\gk3boot\`，**绝不放进** `EFI\gaokun3\`（`-Uninstall` 会递归删除它，`:267`）。
- `Format-LoaderConf` 只在 loader.conf 不存在时写，保持不动。
- **默认路径改为 `-UseFallbackPath`**：按 F3/F6，`bcdedit /copy {bootmgr}` 建的短格式项会在 BootNext 生效之前就被固件删掉，"只下一次"多半会落空、回到 Windows。**D5 的 U 盘只读部分或 D6（群友双系统盘）确认之后再改**；D2 只说明纯 Android 盘，不作依据。改成默认意味着所有"只想试一下安装器"的用户回落路径都被永久换成 systemd-boot（影响 PCR4 和 HwBcdOneKey 的路径匹配），所以要等真机证据。在那之前，脚本的提示保持现状（`gaokun3-setup.ps1:527`）。
- 整个 Windows 侧升级为常驻的 **Windows 伴随工具**（U23，§4.9.15）：安装位置、开始菜单项、默认开的开机自检、"仅暂停 BitLocker"、U 盘介质上放一份。
- **快速启动在所有双系统路径上都关**（U18），不只在缩 D: 那条路上（`:407-411`）。
- **`-RepairBoot [-Check]`**（1.0 做，§4.9.6）：体检，然后在 `BOOTAA64` 被换回 bootmgfw 时，先暂停 BitLocker 1 次重启，再拷回 systemd-boot；U15 采纳时重建自有启动项。入口和条目不用碰。
- **"重启到 Android"**（§4.9.4）与 **`-SetDefault Windows|Android`**（§4.9.3）：都通过 `SetFirmwareEnvironmentVariableEx` 实现，需要管理员和 SeSystemEnvironmentPrivilege，D4/D6 待核。
- **`-RemoveAndroid`**（U20，§4.9.13）：先还原引导，再删 ESP 上的东西、删变量、删分区。
- **`-Uninstall`** 在 Android 装上之后不碰 `EFI\gk3boot`、`EFI\systemd`（现在也不碰，补回归测试）。GK3LIVE 在 Android 装好后去掉盘符（U19）。

### 4.8 0.7.x → 1.0 迁移

1. update_engine 把 1.0 写进 `_b`。
2. 新 postinstall（在 0.7.x 系统里执行）：ESP 上还没有 gk3boot ⇒ 直接部署 `gk3boot-android-{a,b}+3.conf`、`gk3boot-tools.conf` 和二进制；停铺 recovery-ramdisk。
3. 旧 HAL 执行 setActive(b)：misc 里 b 为 15/6，default 写成 `*-android-b.conf`。它与第 2 步的先后**不影响结果**（命名兼容）。
4. 重启：systemd-boot 选中 `gk3boot-android-b+3`，改名为 `+2-1`。gk3boot 首跑：
   - 没有迁移标记 ⇒ 存量 BCB 抄进 GK3、清零、写标记、本次不执行（含 `--wipe_data` 时标记"需通知"）；
   - b 未成功 ⇒ tries 6→5；校验 `boot_b` 的 SHA1 → 交接。
5. 1.0 的 Android 起来：update_verifier 调 markBootSuccessful（新 HAL）；开机完成线程把 `gk3boot-android-b+2-1.conf` bless 成 `gk3boot-android-b.conf`。

各种失败的去向：

| 失败 | 结果 |
|---|---|
| gk3boot 起不来或交接有故障 | 每次消耗一次入口计数（panic=10 自动复位，硬挂要长按电源键）；3 次后 default 通配落到直连的 `<mid>-android-b.conf`，即今天的行为；Android 发现没有 `ro.boot.gk3boot` 就通知 |
| 1.0 系统本身起不来 | 每次同时消耗入口计数和 b 的 tries。入口计数先用完 ⇒ 落到直连 b，**这一跳里就没有 tries 回滚了**（直连路径不扣 tries），与今天一样，要靠手选直连 a 或 U 盘。这是 0.7→1.0 这一跳**唯一的已知缺口**（U8） |
| 两者都坏 | U 盘 |
| 代价：用户恰好在 OTA 装完、重启之前点了恢复出厂 | 这次请求被当成存量清掉，GK3 留着原文，Android 侧通知"检测到一次未执行的恢复出厂请求，已取消，请重新操作"（C′ R6） |

**已装双系统的 0.7.x 用户**：
- 迁移步骤与上面相同。1.0 不改 `BOOTAA64`，也不改 systemd-boot，所以 Windows 的 BitLocker 不受这一跳影响（§4.9.7）。
- 默认系统仍是 Android；Windows 为默认要用户在 Parts 或 Windows 脚本里改。
- 1.0 的 postinstall 把 loader.conf 的 `timeout` 从安装器原来写的 `15` 改成 5（U13）；用户改过的不动。
- ESP 余量：0.7.x 的 recovery-ramdisk（每槽约 15 MB）被删掉之后再部署入口，净值为正。但第一次部署时，空间检查要按"先删后写"的顺序算，postinstall 也要照这个顺序执行。
- 0.7.x 的安装器从没设过 GPT bit 0，1.0 不回头补（U19 只管新装）。

### 4.9 双系统（Windows + Android）

> **2026-10-05 补全**（用户采纳 U1–U11 后要求）。开发机是纯 Android，**双系统没有任何真机样本**。本节每条结论都标了证据等级：
> - 【实测】本机或 Parallels 克隆机上跑过；
> - 【二进制】BIOS 2.16 拆包的静态反汇编（scratchpad `bios/pe/*.efi`，地址是 RVA，工具 `fwa/pe.py`），标"复核"的是本轮又亲自反汇编核对过的；
> - 【源码】systemd v257.13 或本仓代码，给出 `文件:行号`；
> - 【微软文档】给出 URL；
> - 【推断】由以上几类推出，没有实测；
> - 【待核】要做 §4.9.14 的实验（编号 D1–D8）。
>
> 摸底三路：现有双系统流程（安装器 / Windows 脚本 / HAL / postinstall）、固件与 Windows 启动机制、日常共存。三路之间的矛盾及其裁决记在 §8.2 第 21 条起。

#### 4.9.1 结论先行

1. **固件层面，两个系统走的是同一个门。** 华为的启动策略每次开机都会删掉"文件路径对不上完整设备路径"的启动项。Windows 写的短格式项 `HD(…)/File(…)` 属于这一类，所以活不过下一次开机。随后固件给 ESP 补建一个只指到分区、描述为 `Windows Boot Manager (<设备名>)` 的启动项；启动这一项时，实际加载的是回落路径 `\EFI\BOOT\BOOTAA64.EFI`【二进制，复核】。⇒ 装完双系统后，冷开机、F12 菜单里的 "Windows Boot Manager"、Windows 的"使用设备重启"，**进的都是 systemd-boot**；"Windows 更新把 WBM 挪到 BootOrder 第一位、从此直进 Windows"在本机**不会**发生【推断。与 2026-08-20 那次实机记录、以及 D1 的实机结果（开发机上只有固件自建的 `Boot0000`，§4.9.14）一致。但 **D1/D2 只能说明纯 Android 盘上的策略**：仓库里另有一条模型解释不了的实测——Windows 分区还在时 U 盘被优先启动、删掉 Windows 分区后翻转（§4.9.2 末尾），说明盘上的 Windows 分区会改变启动选择。所以双系统盘上谁先运行，要由群友出厂双系统盘的 D5（U 盘 live 只读部分）和 D6 定】。第一路摸底的 blocker"双系统用户很可能默认直进 Windows"据此**降为待核**，D5/D6 之前不当作已撤销（§8.2 #21、#45）。
2. **Windows 只有一条启动链**：固件 → systemd-boot → bootmgfw。BitLocker 在安全启动关闭时用 PCR 0/2/4/11【微软文档】，所以至少在第一次装上、以及 systemd-boot（`BOOTAA64`）的字节变化时会要恢复密钥；"F12 和菜单交替进 Windows 会反复要密钥"在本机不成立【推断】。**但关掉安全启动之后会不会每次开机都要密钥，是【未知】**：同款 SoC 的社区报告说每次都要、没说原因（§4.9.7），在 T11d 有结论之前，INSTALL 只能写"可能每次都要；建议装双系统前先在 Windows 里暂停或解密 BitLocker"。gk3boot 从不出现在 Windows 那次启动的镜像链里。
3. **真正的威胁是 `BOOTAA64` 被换掉，以及安全启动被重新打开。** 前者让 Android 消失，后者让**两个系统一起进不去**（固件里只有那一个门）。对策：Windows 脚本 `-RepairBoot`、FAQ、U 盘；D2 通过后再加自有启动项作为第二道门（U15）。
4. **默认系统可以选（U12）。** Windows 为默认时写 `LoaderEntryDefault=auto-windows`；gk3boot 每次启动 Android 时预置一次 `LoaderEntryOneShot`，保证"在 Android 里发生的任何重启都回到 Android"，包括 OTA、`adb reboot bootloader`、恢复出厂、崩溃后的 tries 回滚。冷开机才进 Windows。
5. **菜单策略按机器分（U13）**：双系统固定显示菜单 5 秒，不用 `menu-hidden`；纯 Android 仍按 U3。
6. **互相重启（U14）**：Android 侧"重启到 Windows"经 GK3 一次性意图实现，Android 不重新引入 efivarfs，代价是多一次 POST；Windows 侧由脚本装一个"重启到 Android"，它写 `LoaderEntryOneShot`（Windows 能否写这个变量待核）。
7. **ESP**：出厂 300 MiB 的 ESP 装完 1.0 后，约剩 97–120 MiB；安装器、postinstall、`gk3-esp-sync` 统一保证给 Windows 和固件至少留 32 MiB（U17）。用户自己重装 Windows 得到的 100 MiB ESP 在 1.0 里明确装不了。
8. **其余**：时钟不会差 8 小时（两边各存各的 RTC 偏移）【推断】，不要推荐 RealTimeIsUniversal；快速启动一律关（U18）；卸载必须先还原引导、后删分区（U20）；在 D5/D6 有一台真机通过之前，双系统在发版说明里标"预览"（U21）。
9. **Windows 侧集中到一个常驻的伴随工具**（U23，§4.9.15）：Windows 换掉 `BOOTAA64` 之后 Android 已不可达，只有它的开机自检能及时发现；它还负责互相重启、默认系统、关快速启动 / 休眠、卸载。Modern Standby 会在待机中**自动**转入休眠（§4.9.10），所以是否关掉整个休眠单列为 U24。

#### 4.9.2 固件怎么选启动项（BIOS 2.16 静态分析）

| # | 事实 | 证据 | 等级 |
|---|---|---|---|
| F1 | 每次开机，BDS 先跑华为策略 `HwBdsCustomActionAfterConsole`，顺序是 HwFactoryLoadDefault → RemoveByoUIAndBootManagerOptions → **RemoveInvalidOsBootOptions** → **EnumerateOptions** → DeleteUsbBootOption | HwUniformPolicyDxeDriver 0x1738–0x17f8；QcomBds 0x1bc4 经 BdsCustomAction 协议（d81a2ab2-…）调用 | 二进制 |
| F2 | RemoveInvalidOsBootOptions：对**带文件节点**的启动项，把每个文件系统句柄的"设备路径 + 该文件"拼成完整路径，再按启动项 FilePath 的长度做 CompareMem。一个都对不上，或文件不是 AA64 EFI 应用，就删掉这个 Boot####。只指到分区、不带文件节点的项不判（取不到文件名时直接算有效） | HwUniformPolicyDxeDriver 0xbde0（遍历）、0xbfdc–0xc11c（判定）、0xcd84 → 0x6d74（CompareMem）、0x2e24（拼路径） | 二进制，复核 |
| F3 | ⇒ Windows（bcdboot / bcdedit）常写的短格式 `HD(…)/File(\EFI\Microsoft\Boot\bootmgfw.efi)` 和完整路径对不上，**每次开机都会被删**。Windows 脚本 `bcdedit /copy {bootmgr}` 建的那一项也一样 | 由 F2 推出；Windows 在本机实际写哪种格式没实测 | 推断（D2 在开发机上用 efibootmgr 造短格式项即可核实） |
| F4 | EnumerateOptions：内置、非 USB、非可移动、不是华为隐藏恢复卷（WINPE）的 FAT 分区，如果还没有同一 HD 节点的启动项，就新建一个**只指到分区**的启动项，描述是 `Windows Boot Manager (<设备名>)` | 0xd05c–0xd25c；0xcf10 起拼描述（L"Windows Boot Manager" @0x1736c） | 二进制，复核 |
| F5 | 启动只指到分区的项时，QcomBds 先 LoadImage，失败后补上 `\EFI\BOOT\BOOTAA64.EFI` 再加载 ⇒ F4 那一项启动的就是回落路径 | QcomBds 0x23f3c–0x23f80（字串 @0x37b5c） | 二进制，复核 |
| F6 | BootNext 原生支持，但在 F1 **之后**才处理 ⇒ BootNext 指向一个刚被 F2 删掉的项时会落空，转走 BootOrder | QcomBds 0x1f3c（策略）早于 0x1f7c–0x2090（BootNext） | 二进制，复核 |
| F7 | BootOrder 每次按 `BootTypeOrder` 稳定重排，默认顺序是 HD、CD、其他/USB、PXE | QcomBds 0x17710、0x174a4；默认值 @0x32f28 | 二进制 |
| F8 | 启动项描述**以** "Windows Boot Manager" **开头**（StrnCmp 20 个字符）时，启动前调用 TouchDeviceInit。今天不管进 Android 还是经菜单进 Windows，走的都是 F4 那一项，所以都已经做过这一步 | QcomBds 0x8864–0x88f8 | 二进制，复核 |
| F9 | 任何启动项返回错误都会计一次 BootFailWarning，计数存在 `OemConfig` 变量里，满 3 次关机。**成功启动后是否清零没查清** | QcomBds 0x1b2c、0x1b70、0x9844、0x8c24 | 二进制；清零待核 |
| F10 | HwBcdOneKey 在 ReadyToBoot 时全局替换 `gBS->StartImage`。只有三个条件都满足才介入：SMBIOS Type 11 含 `$HUA`/`CN`；功能位打开；被启动的镜像是 ESP（卷标 `SYSTEM` 或 `EFI`）上的 `\EFI\Microsoft\Boot\bootmgfw.efi` 或 `\EFI\Boot\bootaa64.efi`。介入后读 BCD 和 `BOOTSTAT.DAT`，状态机满足条件时改去引导 WINPE 卷（华为一键恢复），日志写 `\EFI\OneKeyLog.txt`。gk3boot 和从缓冲区加载的内核都不匹配这两个路径 | HwBcdOneKey 0x28dc（挂钩）、0x26d4、0x1968（路径）、0x17b4（卷标）、0x2394（WinPE） | 二进制 |
| F11 | F12（CheckPostHotkey → BootManagerMenuApp）列出的是 Boot####。双系统机器上多半只有 F4 那一项和 USB 设备，Android 和 Windows **不会**作为两项分别出现 | QcomBds 0x22984、0x22b94 | 推断 |
| F12 | 2026-08-20，Windows 还在盘上：把内置 ESP 的回落文件换成 systemd-boot、拔掉 U 盘开机，直接进了 Android。原 `bootaa64.efi` 与 `bootmgfw.efi` 同为 3,120,168 字节（出厂的回落文件就是 WBM 的拷贝，这也解释了为什么 F10 认这两条路径） | `docs/hw-inventory.md` §8quater | 实测（当时没读 BootOrder） |

**修正**：§2.1 的"本机没有 Boot####"应改为"有一项固件自建的分区项，效果等同于走回落路径"。设计结论"`BOOTAA64` 决定一切"不变，只是理由换了。**模型解释不了的实测**（因此 F1–F7 **不完整**）：hw-inventory §8quater 记录过 Windows 分区还在时插着 U 盘开机，`LoaderDevicePartUUID` 是 U 盘；§8quinquies 记录过删掉 Windows 的 p2–p7 之后，优先的 ESP 从 U 盘翻到了内置盘。按 F1/F7，USB 项每次被删、EnumerateOptions 又排除 USB、默认 BootTypeOrder 是 HD 优先 ⇒ U 盘本不该被默认启动。⇒ **存在一条未建模的选择路径：U 盘优先，且随 Windows 分区（WINPE / Onekey / WinRE / MSR 之一或几个）的存在而变**。开发机早已没有这些分区，D1/D2 观察不到它；双系统用户的盘正处在"删之前"那个状态。挂到 T11k，由 D5 的 U 盘只读部分（插着 / 拔掉 U 盘各冷开一次，记 BootCurrent）回答。

**三种假设**（D5/D6 定论之前，按 H-A 设计、为 H-B/H-C 留退路）：

| 假设 | 开机先进 | 应对 |
|---|---|---|
| H-A：F1–F7 成立，Windows 写短格式 | 回落路径上的 systemd-boot | 1.0 基线：照旧占回落路径 |
| H-B：Windows 在本机写的是完整路径并排第一（能通过 F2，同 HD 节点又让 F4 不再建分区项） | Windows | U15 的自有项，或接受"Android 只能经菜单 / U 盘进"，写进 INSTALL |
| H-C：未建模的选择路径、用户改过 BootTypeOrder、BIOS 重置等 | 不定 | 同 H-B，加伴随工具的开机自检（§4.9.15） |

#### 4.9.3 开机先进谁、默认系统怎么选（U12）

**分层**：固件 → `BOOTAA64` = systemd-boot →（`LoaderEntryOneShot` > `LoaderEntryDefault` > loader.conf 的 `default`，`boot.c:1786-1812`）→ gk3boot（Android）或 bootmgfw（Windows）。

**两种默认**：
- **Android 为默认**（今天的行为；安装器预选这一项，因为依赖最少）：什么变量都不设。loader.conf 的 `default *-android-x.conf` 继续由 HAL 维护（EspSlot 只改 default 这一行，`EspSlot.cpp:157-192`）。
- **Windows 为默认**：写 NV 变量 `LoaderEntryDefault = auto-windows`。auto-windows 不带启动计数，写精确 id 没有副作用；变量优先于 loader.conf（`boot.c:1797`），HAL 和 OTA 改 loader.conf 不受影响。
- **入口**：
  - 安装器确认页（live 能经 uefisecapp 写变量）；
  - Parts 的"默认启动系统"（经 GK3 一次性意图 `set_default=windows|android`，由 gk3boot 下次运行时写或删，与 U14 同一条通路）；
  - Windows 脚本 `-SetDefault Windows|Android`；
  - 菜单里高亮 Windows 后按 `d`（systemd-boot 自带，`boot.c:1127`）。

**两条禁令**（双系统才有的坑）：
- **禁止把 Android 条目的精确 id 写进 `LoaderEntryDefault`**（包括在菜单里对着 Android 按 `d`），**也禁止 `@saved`**。原因：`config_find_entry` 只做 fnmatch、不看剩余次数（`boot.c:1771-1784`），精确 id 会让计数用完的入口条目照样被选中，§4.3.3 的"入口 → gk3prev → 直连"回落就失效了。
- **合法值只有两种**：不存在（= Android），或 Windows 条目的 id（`auto-windows`；采纳 U22 后新装机器是 `gk3-windows`，下文凡写 `auto-windows` 都指"本机实际存在的那个 Windows 条目 id"）。在 installer、救援、直连条目、上一版入口上按 `d` 同样会把开机钉住（`boot.c:967-981` 对任何高亮条目都写精确 id，菜单退出时写回 `:1127`）。systemd-boot 读入时转小写（`:1645`）；值匹配不到任何条目（Windows 被删了）时落回 loader.conf（`:1797-1810`），无害。
- 处理办法（"不是合法值就删"，四处都执行同一条规则）：
  - gk3boot 每次运行都检查 `LoaderEntryDefault`，不是合法值就删掉（语义等于"默认 Android"），并记 event `default_reset`；
  - 用户钉在**直连条目**、live 或救援上时，gk3boot 根本不运行：HAL 的 bypassed 通知（§4.6.1 动作 5）写明"在开机菜单里高亮当前默认项（标了默认的那一条）再按一次 `d` 即清除"（对已是默认的条目按 `d` = 清除，`boot.c:968-977`）。Android 不碰 efivarfs（U14 选 a），所以 HAL 只通知、不自己删；
  - live 安装器开机时检查：变量指向 live 或救援就在界面上提示，一键清除；整盘清空式重新安装时直接删掉残留的 `LoaderEntryDefault` / `LoaderEntryOneShot`；
  - Windows 伴随工具的开机任务（§4.9.15）同样规范化。
  - **兜不住的情况**：变量精确钉在计数已用完、且坏到检查之前就崩溃的 gk3boot 上。gk3boot 修不了自己，U7 的菜单也在它里面；兜底是菜单里手选别的条目并对默认项按一次 `d`，或插 U 盘。写进 FAQ。`d` 键在 boot.c 里无条件生效（`:967`），没找到关闭它的配置项。

**预置 OneShot（只在 Windows 为默认时）**：
- gk3boot 在交接前写 `LoaderEntryOneShot = *-android-<hint>.conf`（NV|BS|RT，写法同 `scripts/boot-oneshot.sh`）。
- 效果：只要进了 Android，之后的任何重启都回 Android，包括 OTA 后重启、BCB 意图、RescueParty、panic、看门狗复位、新槽起不来时的 tries 回滚。否则一次 panic 就会落进 Windows，回滚链断掉（第三路摸底指出）。
- 用通配而不用精确 id，是为了让计数用完的入口条目照常排到最后（`boot.c:1710-1714`）。
- fail-open 写 OneShot 的时间晚于预置，所以失败时会覆盖它（§4.12）。
- 走直连回落条目进 Android 时，gk3boot 不运行，也就没有预置。这是降级状态，可以接受：直连路径本来就不扣 tries、没有回滚链，这次重启落进 Windows 也不会让回滚"更断"；HAL 已发 bypassed 通知。评审建议此时由 HAL 补写预置，**不采纳**（要给 Android 加回 efivarfs，见 §8.2 #46）。
- 预置里的槽字母是开机那一刻的。OTA 之后 setActive 改了 loader.conf，预置的 OneShot 仍会先命中 `gk3boot-android-<旧字母>`，但 gk3boot 按 BCAB 选槽，照样启动新槽；字母只在入口计数全用完、落到直连条目时起作用，那时落到旧槽（已知可用）正是想要的（§8.2 #46）。

**冷开机进 Windows**：
- Android 里关机时，vendor rc 的 `on shutdown` 执行 `gk3-misc mark-poweroff`。它只在 `sys.powerctl` 以 `shutdown` 开头、且默认是 Windows 时（看 GK3 里 gk3boot 写下的默认系统缓存，§4.5；Android 不挂 efivarfs），在 GK3 记录里置 `clean_poweroff`。
- 下次上电，预置的 OneShot 让 gk3boot 运行，按下面"gk3boot 的判定顺序"第 d 步转去 Windows。
- 代价：从 Android 关机后的那一次冷开机要多走一次 POST。
- 标记没写上（钩子失败、长按电源键强制关机）⇒ 这次进 Android。这是安全的失败方向。
- 这个钩子只写 misc，不经 uefisecapp，所以 C′ R2 那种卡在 D 状态的风险不适用；时序沿用 C′ 已核对的 `on shutdown` exec（`reboot.cpp:986-992`）。要在 E7 一并实测。

| 场景 | Android 为默认 | Windows 为默认 |
|---|---|---|
| 关机后按电源键 | Android | Windows（从 Android 关的机：多一次 POST） |
| Android 里重启 / OTA / `adb reboot bootloader` / 恢复出厂 / 崩溃 | Android | Android（预置 OneShot） |
| Windows 里重启、Windows 更新的多次重启 | **菜单倒计时后进 Android**：Windows 更新推迟到下次进 Windows，不会损坏【推断】。U25 落地（伴随工具的 Windows 侧预置）后回 Windows | Windows |
| Android 里"重启到 Windows" | Windows（一次） | Windows |
| Windows 里"重启到 Android" | Android | Android（一次） |
| 菜单里手选 | 任选 | 任选 |

⇒ INSTALL 和确认页要写明：**以 Windows 为主的用户选"Windows 为默认"**。

**gk3boot 的判定顺序**（并入 §4.2 的第 0、4、9 步）：
- a. 读 `LoaderEntryDefault`：不是合法值（不存在，或 Windows 条目 id）就删掉；值是 `auto-windows`、**并且** ESP 上确实有 `\EFI\Microsoft\Boot\bootmgfw.efi`，才算"默认是 Windows"。结果只在变化时写进 GK3 的默认系统缓存。
- b. 处理 `set_default=windows|android`：写或删 `LoaderEntryDefault`，更新缓存，**不复位**，接着往下走。
- c. 判断 **Android 待办**：BCB 非空，或者选中的槽未成功（tries 计数中），或者连续未完成计数 > 0，或者 GK3 里有 `next=slot:x` / `next=sdboot-menu`。有待办时，把 `next=windows` 和 `clean_poweroff` 作废并记 event，按原流程启动 Android。HAL 据此通知，例如"已先完成系统更新，请再选一次重启到 Windows"。
- d. 没有待办，且满足 `next=windows`，或者（`clean_poweroff` 且默认是 Windows），且 bootmgfw 存在：**先清掉标记**，再写 `OneShot=auto-windows`，然后 `ResetSystem(Warm)`。这一路不加连续未完成计数、不扣 tries、不预置 OneShot。因为标记先清，最坏情况也只多一次复位，不会循环。
- e. 其余情况照常启动 Android；默认是 Windows 时，在交接前预置 OneShot。

正常路径（Android 为默认）的写入量**不变**。

**体验细节**：
- 转去 Windows 的那一次，会看到两次开机 Logo，INSTALL 要说明这是正常的。
- 只有平板、没接键盘时：在 E3 证明音量键能操作 systemd-boot 菜单之前，切系统只能靠两边的"重启到另一系统"和"默认系统"。Android 起不来、默认又是 Android 时，没有键盘就进不了 Windows（插 U 盘或接键盘）。所以平板用户如果以 Windows 为主，更应该选"Windows 为默认"。

#### 4.9.4 互相重启（U14）

**Android → Windows**：Parts 里加"重启到 Windows"，只在 ESP 上有 `EFI/Microsoft/Boot/bootmgfw.efi` 时显示。两种实现：
- **(a) 建议**：Parts 设属性请求 → HAL 在 GK3 写一次性意图 `next=windows` → `reboot`。gk3boot 读到后写 `OneShot=auto-windows` 并复位。不管哪种默认，下次开机 gk3boot 都会运行：Android 为默认时它本来就是默认项，Windows 为默认时有预置的 OneShot。
  - 好处：Android 不重新引入 efivarfs，§4.14 的"净减少"保持成立。
  - 代价：多一次 POST。
- **(b)** Android 直接写 efivarfs：#42 实测可写，少一次 POST，但要新 sepolicy 域，还要 genfscon 给 efivarfs 打标签。

执行端菜单的"Other systems"保留作后备：没装 Parts 或没开机完成时，用 `adb reboot bootloader` 也能到。

**入口位置**：1.0 保证的是 Parts 里的"重启到 Windows"（Parts 是自己的代码）。普通用户切系统时找的是**电源菜单**（长按电源键弹出的那个），目标是在那里也加一项；crDroid 的扩展点要在构建机的 crDroid 树里 grep 出文件和行号（E1），**不凭记忆写**，工作量计入 S9；找不到可用扩展点就只保留 Parts。

**Windows → Android**：Windows 脚本安装一个"重启到 Android"（管理员 PowerShell）：
1. `mountvol` 临时挂 ESP，读 loader.conf 的 `default` 值；
2. 先用 AdjustTokenPrivileges 打开 SeSystemEnvironmentPrivilege；
3. 用 `SetFirmwareEnvironmentVariableEx` 把这个值写进 `LoaderEntryOneShot`：GUID `{4a67b082-0a4c-41cf-b6c7-440b29bb8c4f}`，属性 7，UTF-16LE 加 NUL。权限要求见【微软文档 https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariableexw 】；
4. 读回核对，然后 `shutdown /r /t 0`。

为了不必每次都弹 UAC，脚本把上面这些注册成一个以 SYSTEM 运行的计划任务（SYSTEM 天然带这个特权），桌面和开始菜单的快捷方式只做 `schtasks /run`。`-SetDefault` 走同一个任务。这些都属于常驻的 Windows 伴随工具（U23，§4.9.15）：脚本本身只是下载包里的 .ps1，没有安装位置，从 U 盘装双系统的用户也从没运行过它。

说明：
- 用 loader.conf 的 default 值，而不用 `*-android-*` 这种宽通配：宽通配在入口条目全部计数用完时会排到另一个槽的直连条目。
- **本机 Windows 能否写 systemd 厂商 GUID 下的变量【待核，D4 先在 Parallels 做原型，D6 在真机确认】**：Windows 的变量服务在高通平台上同样经 TZ。写不进时退化为提示"重启后在菜单里选 Android"。

**不用的办法**：
- BootNext（`bcdedit /set {fwbootmgr} bootsequence`）：F3/F6 下它多半落空；即使不落空，指向的那一项启动的也是 systemd-boot 自己，区分不了两个系统【推断】。
- systemd-boot 的 `reboot-for-bitlocker` **必须保持关**。它只找描述**恰好等于** "Windows Boot Manager" 的项（`boot.c:2109`），本机只有带括号后缀的项，所以找不到；万一找到了，那一项启动的也是 systemd-boot 自己，会原地兜圈子。
- 第一路摸底提的 `gk3.action=boot-windows`（gk3boot 写 BootNext=WBM 再复位）**否决**，理由同上（§8.2 #25）。

#### 4.9.5 systemd-boot 菜单、Windows Boot Manager 与 F12 的关系

- **systemd-boot 菜单是双系统唯一的选择点。**
  - Windows 条目是自动生成的 `auto-windows`：ESP 上有 `bootmgfw.efi`、`auto-entries` 默认开，标题从 BCD 读（`boot.c:2130-2151`）。Parallels 里实测出现过"Windows 11（自动认出）"，但那是另一套固件（`scripts/windows/README.md`）。
  - ~~安装器不写 `auto-entries no`，也不另写 Windows 条目~~ **改为 U22**：systemd-boot 把 `auto-windows` 追加在所有 type1 条目**排序之后**（`boot.c:2814-2819`），排在它前面的有 Android、引导菜单、上一版入口、直连 a、直连 b、installer、救援 ⇒ 平板上每次要按 7 次左右音量下才到 Windows，而这是双系统用户每天最常用的操作。所以双系统时安装器写一个自有的 type1 条目 `gk3-windows.conf`（`title Windows`、`efi /EFI/Microsoft/Boot/bootmgfw.efi`，sort-key 介于入口条目 `0gk3` 与引导菜单条目之间，主机单测断言"Windows 排第 2"），并在 loader.conf 写 `auto-entries no` 避免出现两个 Windows。
    - `auto-entries no` 同时隐藏 auto-osx、EFI Shell、EFI Default Loader（`boot.c:1961`、`:2007`、`:2138`），不影响 `auto-firmware`（独立选项，`:1258`、`:2825`）。注意：文件名以 `auto-` 开头的 type1 条目会被跳过（`:1691`），所以不能把自有条目命名成 `auto-windows.conf`，id 必须换（`gk3-windows`）。
    - 代价：标题不再从 BCD 读（`:2140-2142`）；`w` 热键只属于 `auto-windows`（`:2147`），自有条目没有。`bootmgfw.efi` 不在时条目被跳过（`:1531-1535`），无害。
    - 两种条目都是 systemd-boot 对同一个文件做 LoadImage，PCR4 应当相同【推断】，D4 核对一次。旧布局（没有 `gk3-windows.conf`）继续用 `auto-windows`。
  - **条目标题一律 ASCII**：`Android`、`Windows`、`Android boot menu / Fastboot`、`Android (previous loader)`、`Android direct a/b (rescue)`。UEFI ConOut 能不能显示 CJK 字形从没验证过；现有直连条目的标题里已经有一个 `—`（`installer-lib.sh:920`），渲染情况同样未核。E3 顺带拍一张含 CJK 与 `—` 的测试标题，中文对照写进 INSTALL。
  - FAQ：菜单里按 `d` 会改默认系统，对同一条目再按一次撤销（`boot.c:967-981`）。
- **Windows 自己的启动菜单**（bootmgr displayorder）只管 Windows 内部（WinRE 等），不受影响；`bcdedit /enum firmware` 能看到 F4 那一项。
- **F12 里那个 "Windows Boot Manager (…)"，打开的是我们的菜单**，并不能"绕过 systemd-boot 直进 Windows"（F11 + F5）。INSTALL / FAQ 要这样写，不要教用户"进不去就 F12 选 Windows Boot Manager"。要绕过只能插 U 盘。
- **菜单策略（U13）**：
  - 安装器看 ESP 上有没有 `EFI/Microsoft/Boot/bootmgfw.efi`：有就写 `timeout 5`、不写 `menu-hidden`；没有就按 U3。
  - 理由：平板形态下切 Windows 主要靠菜单；`menu-hidden` 的 100 ms 读键窗口在只有音量键时不现实（INST-18 未证）。
  - 已装机器的 timeout 由 1.0 的 postinstall 处理：只有当前值等于安装器原来写的 `15` 时才改成 5，用户改过的不动。改 loader.conf 只影响 PCR5（§4.9.7），不会让 BitLocker 要密钥。
- **触摸**：固件只对描述以 "Windows Boot Manager" 开头的项做 TouchDeviceInit（F8）。今天的唯一一个门正好是这一项，所以经菜单进 Windows 和出厂一样做过这一步。第一路摸底担心的"经 systemd-boot 进的 Windows 触摸不灵"按静态分析不成立（§8.2 #24），D6 顺带确认。

#### 4.9.6 Windows 更新之后：会坏什么、怎么修

| 事件 | 会改什么 | 后果 | 依据 |
|---|---|---|---|
| Windows 升级 / 修复跑 bcdboot | 在 NVRAM 建 WBM 项并放到第一位 | 下次开机就被固件删掉（F3），**无影响**【推断】 | 【微软文档】https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di （"By default, during an upgrade BCDBoot moves the Windows Boot Manager to be the first entry in the UEFI boot order"）＋ F3 推断 |
| 同上 | **会不会改写 `\EFI\Boot\bootaa64.efi`** | 改写了 ⇒ Android 消失，开机直进 Windows | 微软文档只说 BCDBoot 把文件拷到 `\Efi\Microsoft\Boot`、用 `/s` 时"依赖固件默认打开 `\efi\boot\bootx64.efi`"，**没说会写回落路径**；社区有覆盖的报告。**待核（D4）** |
| 启动管理器吊销（CVE-2023-24932） | 换 ESP 上的启动管理器 | 原文 "The mitigations are blocked due to known UEFI firmware issues with Qualcomm-based devices"，接着是 "Qualcomm has provided the fix to device manufacturers" ⇒ **屏蔽是暂时的**，华为发带修复的 BIOS 后可能解除；解除后 Windows 可能改写 ESP 上的启动文件（D7 观察） | 【微软 KB】https://support.microsoft.com/en-us/topic/how-to-manage-the-windows-boot-manager-revocations-for-secure-boot-changes-associated-with-cve-2023-24932-41a975df-beb2-40c1-99a3-b3ff139f832d |
| 2026 年 Secure Boot 证书轮换 | 2011 年的 KEK / UEFI CA 于 2026-06、Windows Production PCA 2011 于 2026-10 到期，启动管理器会换成 Windows UEFI CA 2023 签名的版本；固件过旧时可能出现 "BitLocker recovery prompts (including repeated prompts/loops)" | 两页都没说**安全启动关闭**的机器会不会被换、会不会写回落路径 ⇒ 未知 | 【微软】https://techcommunity.microsoft.com/blog/windows-itpro-blog/act-now-secure-boot-certificates-expire-in-june-2026/4426856 ；https://learn.microsoft.com/en-us/troubleshoot/windows-client/windows-security/update-secure-boot-certificates 。D4、D7 观察 |
| 用官方 ISO 在双系统盘上全新重装 Windows | 安装程序的分区界面会列出 Android 分区（可能被删）；bcdboot 写 ESP | 可能同"改写回落路径"那一行，或 Android 分区被删【推断】 | FAQ：重装时别动不认识的分区；装完运行伴随工具的修复，或用 U 盘 |
| "从驱动器恢复"、华为 F10 一键恢复 | 重建整盘分区 | Android 被抹掉 | 【微软文档】https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/push-button-reset-overview （"Restores the default or preconfigured partition layout"）；F10 是推断，不实测 |
| Windows 某次启动失败（BOOTSTAT 记了失败） | HwBcdOneKey 的状态机（F10） | 用户选 Android 时，systemd-boot（回落路径）也可能被带进一键恢复；状态是持久化的，下一次经回落路径开机还会被同样改道，F12 里也只有同一个门 ⇒ 可能陷入"一键恢复 → 重启 → 一键恢复"的循环【推断】 | 二进制；触发条件待核（D3/D5）。确定能走的逃生路径是 **U 盘 live**（U 盘不在钩子的"硬盘上的 ESP"范围内【推断】），再从 live 进 Android 或修好 Windows；清掉 BOOTSTAT 失败状态的具体做法待核 |

**`-RepairBoot`（Windows 脚本，1.0 做）**：
1. 只读体检：`BOOTAA64` 与 `EFI\systemd\systemd-bootaa64.efi` 是否同字节；loader.conf、条目、`EFI\gk3boot` 在不在；可选 `-Check` 只出报告。
2. `BOOTAA64` 字节不同，且等于 `bootmgfw.efi` 时：BitLocker 开着就先 `Suspend-BitLocker -RebootCount 1`；备份成 `.before-gaokun3`（已有就不覆盖）；拷回 systemd-boot。是别的东西时（例如另一个 Linux 的 GRUB），只报告、不动。
3. U15 采纳时，重建自有启动项。
4. 幂等，每一步都打印。

**Android 侧不自动修 `BOOTAA64`**：
- 能进 Android，说明走的是别的门（U 盘或 U15 的自有项）；
- 改 `BOOTAA64` 会改变 Windows 的 PCR4，而 Android 暂停不了 BitLocker。
- ⇒ HAL 开机完成线程只做比对（动作 6，§4.6.1），不同就通知"Windows 替换了启动器，请在 Windows 里运行 `gaokun3-setup.ps1 -RepairBoot`"。
- 但在 H-A 下，`BOOTAA64` 被换回 bootmgfw 之后 F12 里也只有同一个门，**Android 通常根本进不来**，HAL 这条只在用户经 U 盘 / live 进 Android 时才有用。**主检测在 Windows 侧**：伴随工具的开机自检默认开、不可关（U23，§4.9.15），发现不同就通知并给一键修复。没有伴随工具的用户靠 FAQ 的手工三步或 U 盘 live 的"修复启动"。

U 盘 live 的"修复启动"做同样的第 2 步，但 Linux 侧暂停不了 BitLocker，写之前必须让用户确认手上有恢复密钥（U16）。

#### 4.9.7 BitLocker 与安全启动

**事实**：
- **安全启动必须关**：systemd-boot、入口、内核都没签名；systemd-boot 在安全启动打开时还会跳过 DTB（`boot.c:2577-2582`）。
- **安全启动关闭时，BitLocker 默认用 PCR 0/2/4/11**（PCR 4 = Boot Manager）。只有"Secure Boot State (PCR7) support is available"时才改用 7/11【微软文档 https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/configure ，"Configure TPM platform validation profile for native UEFI firmware configurations"一节】。
- **会触发恢复的事件**：Changes to the boot manager；修改验证配置里的 PCR；BIOS/UEFI 升级。暂停后再恢复，会按当时那次启动重新封存，不用输恢复密钥【微软文档 https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/recovery-overview 】。

**推论**：
- 出厂的设备加密多半绑在 PCR 7/11 上。关安全启动改变 PCR7，于是下一次开机要密钥；Windows 脚本已经先暂停 2 次重启（`gaokun3-setup.ps1:322-342`）。
- **【未知】之后会不会落到 0/2/4/11 并稳定下来。** 微软文档只说 PCR7 可用时默认用 7+11（上面的 configure 链接），**没说**已按 PCR7 封存的保护器在安全启动关掉后会不会自动改用 0/2/4/11 重新封存。同款 SoC 的社区说法是 "With the BitLocker still enabled, you would have to type in a 48 digit password each time you boot into Windows."（https://aarch64-laptops.github.io/laptops/thinkpad_x13s/debian_guide.html ）——原文没有说原因，本文不作解读。如果真实机制是"旧的 PCR7 保护器重封不了"，那"只留一条启动链"挡不住，用户每次开机都要输 48 位密钥。⇒ T11d 新增子项（D5 先读 `manage-bde -protectors -get C:`；D4 / D6 记录关安全启动后连续 3 次以上开机）。在有结论之前，INSTALL **只能写"可能每次进 Windows 都要恢复密钥；建议装双系统前先在 Windows 里暂停或解密 BitLocker"**；删除并重建 TPM 保护器之类的补救步骤，D4 验证后才写进 FAQ。
- 暂停次数是按 **Windows 自己的启动**递减的【推断】，所以中途进 live 安装不消耗次数；最后一次递减发生在"经 systemd-boot 进 Windows"的那次启动，并按那条链重新封存。如果次数其实按所有重启计，在进 Windows 之前就用完了，那么第一次经菜单进 Windows 仍会要密钥。D4（vTPM）核实；在那之前，文案一律写"可能要一次恢复密钥"。从 U 盘直接装、没跑过 Windows 脚本的用户没有暂停：BitLocker 开着时，第一次进 Windows 几乎一定要密钥。
- 封存后 PCR4 里是 systemd-boot 加 bootmgfw 的镜像度量，前提是固件真的开着镜像度量（§2.1 还待核）。

**不会让 Windows 要密钥的操作**（推断）：
- 改 loader.conf：systemd-boot 把它度量进 PCR 5【systemd 文档 https://systemd.io/TPM2_PCR_MEASUREMENTS/ 】；
- 条目 options：进 PCR 12；
- Loader* 变量、Boot#### 的增删：启动变量按 TCG PC Client 约定进 PCR 1；
- gk3boot 的部署与升级：它不在 Windows 那条链上；它写 OneShot 后会复位，平台复位时 PCR 清零（这一点也是推断，高通的 fTPM 在 TZ 里，随整机复位重新初始化）；
- Android OTA：不碰 `BOOTAA64`。

**会让 Windows 要密钥的操作**：
- 首次装双系统（没暂停时）；
- **任何改变 `BOOTAA64` 字节的动作**：安装器写入另一版 systemd-boot、`-RepairBoot`、卸载时还原；
- BIOS 升级（PCR 0）、开关安全启动。

Windows 自己更新 bootmgfw 时会自己处理暂停和重封【推断】。

**规则（U16）**：
1. systemd-boot 版本冻结，只由安装器写，而且只在字节不同时写；
2. Windows 脚本里所有会改 `BOOTAA64` 的动作，先 `Suspend-BitLocker -RebootCount 1`；
3. Linux 侧（live 安装器）检测到 Windows 卷是 BitLocker（安装器已能认 `TYPE=BitLocker`）时，改 `BOOTAA64` 前强制确认"已拿到恢复密钥"；Android 从不改它；
4. 双系统确认页和 INSTALL 写清：关闭安全启动后，Windows 的自动设备加密不会再自动开启，已加密的卷保持加密【微软文档 https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/ 】；
5. 已知限制里写：Windows 侧要求安全启动的反作弊（例如 Riot Vanguard，https://support.riotgames.com/en-us/riot/client/enable-tpm-20 ）与本方案硬冲突。
6. **时序：BitLocker 的提醒必须在"关安全启动"之前**。关安全启动这一步本身就会让绑定 PCR7 的 BitLocker 在下次进 Windows 时要密钥（Windows 脚本已为此调整过顺序，`gaokun3-setup.ps1:322-326`）；U 盘路径上用户先进固件关安全启动、可能先回一趟 Windows，**那时我们任何界面都还没出现过**，安装器确认页的勾选框已经晚了。所以：
   - INSTALL 与 U 盘下载 / 制作说明的**第 0 步**（在"关安全启动"之前）：在 Windows 里确认拿得到恢复密钥（https://aka.ms/myrecoverykey ；微软的找回说明 https://support.microsoft.com/en-us/windows/security/encryption/find-your-bitlocker-recovery-key ），并暂停或解密 BitLocker；也可以只运行伴随工具的"仅暂停 BitLocker"（§4.9.15）。Home 版"设备加密"的用户多半不知道密钥存在微软账户里，这一步要写给他们看。
   - 确认页按路径分文案：走过脚本路径（已暂停）写"接下来 2 次重启不会要密钥"；U 盘路径写"第一次进 Windows 可能要密钥，屏幕上会显示密钥 ID，到 aka.ms/myrecoverykey 按 ID 找"。blkid 能不能取到 BitLocker 的密钥 ID **待核**，取到就显示。规则 3 的强制确认保留为第二道。

#### 4.9.8 共用 ESP 的空间账

单位 MiB。boot.img 各段取自 `out/issues-1791053208/boot.img`（§2.2）。

| 项 | 大小 | 出处 / 等级 |
|---|---|---|
| 出厂 ESP 分区 / 可用 | 300 / ≈296 | hw-inventory §8、§8ter【实测】 |
| Windows 与固件已占：`EFI/Microsoft` 28、`EFI/Boot/bootaa64.efi` 2.9、`Persisted_Capsules.bin` 70 | ≈101–108 | §8ter【实测】 |
| **出厂空闲** | **188** | §8ter【实测】 |
| systemd-boot ×2 | 0.23 | 第三路摸底 |
| `BOOTAA64` 原件备份 | 2.9 | 安装器 `:695` |
| `slot_a` + `slot_b`（每槽 Image 14.9 + ramdisk 12.5 + dtb 0.17） | 55 | §2.2【实测文件】 |
| 救援 initramfs（选了才有） | 4 | 安装器 |
| 入口（gk3boot + fastboot.img）：新装 1 版 / 有过轮换后 2 版（当前 + gk3prev）/ 分阶段激活期间 3 版（再加 staged，§4.11 第 1–3 步） | ≤5 / ≤10 / ≤15 | §4.1 的估计，待 S5/S7 实测 |
| live（只有 Windows 脚本那条路有，`EFI\gaokun3`） | 19.2 | 第三路摸底，实测文件大小 |
| recovery-ramdisk：0.7.x 的 OTA 铺的；**自编版本**的发布目录里有它时，安装器也会往两槽各铺一份（`installer-lib.sh:661`、`:933-935`；发版不带，`:490`） | 每槽约 13–15 | 1.0 停铺并删除（§4.6.2） |

- **1.0 新装后的空闲**：最多 ≈188 − 68 = 120（不装救援、不走 Windows 脚本）；最少 ≈188 − 91 = 97。
- **OTA 期间**：postinstall 覆盖目标槽，需要暂时空间，现行门槛是"空闲 + 一个槽 > 56 MiB"（`installer-lib.sh:52`）。
- **Windows / 固件要的**：功能更新要求系统分区空闲 15 MB、质量更新 13 MB，并点名有的 OEM 把 BIOS 映像放在 ESP【微软 KB https://support.microsoft.com/en-gb/help/3086249/we-couldn-t-update-system-reserved-partition-error-installing-windows 】。固件胶囊暂存在 `EFI\UpdateCapsule`，空间不够时 CapsuleRuntimeDxe 会跳过并删除（字串 0xc974）。`Persisted_Capsules.bin` 由 **CapsuleRuntimeDxe** 引用（字串 0xe306；0xcb80 "GetMaxCapsuleSizeInCapsuleRawFile"、0xd872 "Capsule storage header update during capsule delete failed"）【二进制】，推断是**预分配**的胶囊原始文件存储：胶囊多半写进这份文件、不额外占空间；但它一旦被删，固件要重新腾出约 70 MB【推断】。（第一轮写成"RecoveryDxe 的恢复材料"，出处不对，§8.2 #50。）
- **原 §4.9 那句"停铺 recovery-ramdisk 腾出约 30 MB，净值为正"只对 OTA 过的机器成立**：新装机器上本来就没有 recovery-ramdisk，加入口是净 −5 到 −10（§8.2 #28）。
- **规则（U17）**：
  - 双系统时，安装器、postinstall、`gk3-esp-sync` 统一断言：**写完、并扣掉下一次 OTA 的暂时空间后，ESP 仍空闲 ≥ 32 MiB**，留给 Windows 和固件。常量写进 `installer-lib.sh` 和 postinstall，并写 test-apply 用例。
  - 出厂 ESP 最坏情况还剩 97 − 28.5 − 5（分阶段激活期间的第三版入口）≈ 63，满足。自编版本带 recovery-ramdisk 时再少 26–30。32 MiB **不包含**胶囊暂存（按上面的推断，胶囊写进预分配文件），D7 核实；D6 观察一次 Windows 功能更新前后的空闲变化。
  - 用户自己重装 Windows 得到的 100 MiB ESP，装完会是负数，**明确拒绝**，提示 1.x 的 XBOOTLDR 方案。
  - 所有提示文案写明：**绝不删** `Persisted_Capsules.bin`、`EFI/Microsoft`、`EFI/UpdateCapsule`。
  - 空间紧时，Windows 脚本或 Parts 可以提示删掉 `EFI\gaokun3`（live，19 MiB），但默认保留：它是"重新安装"的安全网。
- **1.x**：XBOOTLDR 分区（systemd-boot 257 会扫，`boot.c:2418-2434`）放槽副本、live、入口载荷。前提有二：①固件的 FAT 驱动能挂非 ESP 类型的分区（待核）；②按 F4，固件会给这个内置 FAT 分区也建一个分区项，它**不能排到 ESP 那一项前面**（否则每次开机先失败一次，按 F9 可能累加到 3 次关机），或者在它上面放一个无害的回落文件。两条在开发机上先看（新建分区后重复 D1），双系统盘上 D6 复核。H2 稳定后退役 ESP 上的槽副本（§1.3）。

#### 4.9.9 时钟

- **Android**：RTC 偏移存在 PMK8280 SDAM6 的 0xbc（`refs/linux-v7.2-rc2/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts:875-888`，`nvmem-cells = <&rtc_offset>`），不走 UEFI 变量。Android 按 UTC 写 RTC；自动对时默认开，开发机上 `ntp.aliyun.com` 对时成功（TODO B22）。
- **Windows / 固件**：偏移存在 UEFI 变量 `RTCInfo` 里（`pe/RealTimeClock.efi` 字串；同款 SoC 的 X13s 补丁说明"Windows stores the RTC time in local time"、固件和 Windows 用 UEFI 变量存偏移：https://lkml.iu.edu/hypermail/linux/kernel/2502.2/05188.html ）。
- ⇒ 两边各存各的偏移，互不覆盖，**不应出现经典的"差 8 小时"**【推断】。前提是 Windows 和固件的 SetTime 只改 `RTCInfo`、不改 PMIC 的原始计数——**没验证**。D6 做交叉实验：Windows 里手动改一次时间（时区不变），进 live 或 Android 且不联网，比对 `date -u` 与 SDAM；反方向同理。偏差整 8 小时 = Windows 在写原始计数。
- FAQ 先写："Android 离线时时间不对 → 联网后自动校正"（自动对时默认开）。
- **不推荐 RealTimeIsUniversal**：微软不正式支持，WoA 上有设了也退回的报告（https://learn.microsoft.com/en-us/answers/questions/2302708/windows-on-arm-time-incorrect-after-reboot-or-hibe ）。
- 相关但不属于本设计：从没跑过 Linux 的 Windows 机器上 SDAM 偏移没设过，live 又没有对时，网络安装走 HTTPS，证书时间校验可能失败。转交安装器批次：live 加对时，或给 `/usr/lib/clock-epoch` 设一个下限。

#### 4.9.10 快速启动与休眠（U18）

- 快速启动 = 关机时把内核会话连同已挂载的卷存进 hiberfil【微软文档 https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/distinguishing-fast-startup-from-wake-from-hibernation 】。Windows 运行时把 ESP 上的 BCD 存储当作注册表 hive 挂着【推断，本机未核】，所以休眠映像里可能带着 ESP 的 FAT 缓存。
- 而 Android 那边，OTA postinstall、HAL 改 loader.conf、systemd-boot 计数改名、bless 都会写 ESP。Windows 恢复后再写 ESP，就可能把 FAT 写坏【推断，D4 做破坏性实验定级】。
- **规则**：
  - 双系统时，Windows 脚本**在所有路径上**关快速启动，不再只在"要缩 D:"那条路上关（现状 `gaokun3-setup.ps1:407-411`）；`-Uninstall` / `-RemoveAndroid` 还原。
  - live 安装器在双系统 apply 之前检测 Windows 卷是否处于休眠，是就拒绝写 ESP。直接复用 `gk3__ntfs_hibernated`（`installer-lib.sh:1170`，只读看 hiberfil.sys 头；今天只用在缩分区那条路上，`:1203-1206`）；C: 是 BitLocker 时读不到，只警告。
  - INSTALL / FAQ：别在 Windows 休眠时切到 Android。Android 侧检测不到，只能靠文档。
- **Modern Standby 会自己转入休眠**：这是 ARM 平板，合盖待机后 Windows 会因为电量下降或空闲超时**自动**进入休眠，用户并不知道（Adaptive hibernate：https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/adaptive-hibernate ；Hibernate idle timeout：https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/sleep-settings-hibernate-idle-timeout ）【微软文档】。之后冷开机（默认 Android）就会在 Windows 休眠时改写共用 ESP；从 U 盘装双系统的用户连快速启动都没人替他关。⇒ **是否关掉整个休眠**（`powercfg /hibernate off`，代价是待机时电量耗尽就直接掉电、丢未保存的会话）单列为 **U24**，由伴随工具执行、征得同意、写进 INSTALL；U25 的 Windows 侧预置落地后，休眠后的下一次开机默认回 Windows 去恢复，能降低误进 Android 的概率。D4 的破坏性实验加一项"手动休眠后外部改 ESP"。
- **待机中想切到 Android**：Modern Standby 下按电源键是直接恢复 Windows，不经过固件和菜单【推断】，只能先"重启到 Android"。写进日常使用说明（§4.9.17）。

#### 4.9.11 防误操作与隔离白名单

**Windows 那边看到什么**：
- 安装器给 Android 建的分区，类型都是 Linux filesystem `0FC63DAF-…`（`GK3_TYPE_DATA=8300`，`installer-lib.sh:288`、`:390-400`），属性位全 0。
- 微软："Only partitions of this type [basic data] can be assigned drive letters"【https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-partition_information_gpt 】⇒ 资源管理器看不到这些分区，也不会弹"需要格式化"；但磁盘管理里看得到、删得掉。
- Windows 脚本建的 GK3LIVE 是 basic data 并且分配了盘符（`gaokun3-setup.ps1:250`），在资源管理器里一直看得见。

**U19**：
- 候选：Android 分区设 bit 0（`GPT_ATTRIBUTE_PLATFORM_REQUIRED`）。微软的说法是设了之后 diskpart 仍能删分区，但不能做卷操作；磁盘管理里实际怎么显示，D4 截图后再定设不设。
- **不设 bit 1**（UEFI 规范的"不建 BlockIo"）：固件和 Windows 对这一位的处理没验证过，也没有收益。（第一轮写的理由"gk3boot 读 misc、`boot_x` 全靠固件给分区建 BlockIo"与 §4.2 第 1 步矛盾：gk3boot 拿整盘 BlockIo、自己解析 GPT，§8.2 #51。）
- GK3LIVE 在 Android 装好后**只用 `Remove-PartitionAccessPath`** 去掉盘符；脚本以后需要时会自己重新分配（`gaokun3-setup.ps1:446`）。不设属性位：NO_DRIVE_LETTER（bit 63）只在"磁盘第一次被看到或移到另一台机器"时生效，去不掉已分配的盘符；HIDDEN 会让 Mount Manager 完全看不到这个卷，而脚本靠 `Get-Volume -FileSystemLabel` 找 GK3LIVE（`:252`、`:295`、`:397`）【微软文档，同上 URL】。

**隔离白名单**（在 C′ §4.4 的基础上补双系统的部分）：
- **gk3boot**：
  - 在**同一块盘**上找 misc、boot_a/b、super、userdata、metadata，每个名字恰好出现一次；
  - 先查自己所在的盘，找不到再扫所有整盘，要求全局唯一，否则 fail-open。这一条覆盖"手工把 Android 装在另一块盘、共用 Windows ESP"的用户（第一路摸底问题 9）；
  - GPT 只读。
- **执行端**：
  - 协议只暴露 `boot_a/b`、`super`、`userdata`、`metadata`；`-w` / 恢复出厂只碰 userdata、metadata 和 misc 的 BCB（C′ §4.4、§4.6）；
  - ESP、MSR、"Basic data partition"、WinRE、WINPE、Onekey、gk3rescue、整盘，在协议里都不存在；
  - **新增（内容检查）**：目标分区偏移 3 处是 `NTFS    ` 或 `-FVE-FS-`（BitLocker）的，不管叫什么名字一律拒绝。签名实施时对照 ntfs-3g 与 blkid 源码，不凭记忆抄。
  - **新增**：目标分区的类型如果是 Windows 系的（basic data `EBD0A0A2`、MSR `E3C9E316`、WinRE `DE94BBA4`、ESP `C12A7328`），一律拒绝，防止名字碰巧重复时写到 Windows 分区上。用黑名单而不是"必须是 `0FC63DAF`"：开发机这类手工分区的机器上，Android 分区的类型码没核对过（M6 是在删掉 Windows 分区的位置上重建的），E2 要用 `sgdisk -i` 核一遍；如果有 basic data 类型的 Android 分区，先改类型码，再启用这条检查。
- **写 ESP 的组件**（postinstall、`gk3-esp-sync`、HAL、执行端）只写我们自己的路径：`<mid>/android/`、`loader/entries/{gk3*,<mid>-android-*}`、loader.conf 的 `default` / `timeout` 行、`EFI/gk3boot/`。不碰 `EFI/Microsoft`、`EFI/Boot`、`EFI/UpdateCapsule`、`Persisted_Capsules.bin`、`OneKeyLog.txt`。
- **machine-id 目录**：postinstall 和安装器现在都取"第一个 32 位十六进制目录"（`gaokun3-ota-postinstall.sh:98`、`installer-lib.sh:513-516`）。共用 ESP 上还有别的 Linux 时可能选错，OTA 就会静默写到别人的目录里。改为读 `*-android-<槽>.conf` 的 `linux` 行取目录，安装器与 postinstall 共用同一个函数。
- **蓝牙**：问题不在"两边各存各的"，而在外设一侧通常只记得一份链路密钥：如果两个系统用同一个蓝牙地址，在一个系统里配对会让另一个系统的配对失效，来回切就得重新配对【推断，D5 比对两边的蓝牙地址】，写进 FAQ；1.x 再考虑从 Windows 导出链路密钥。
- **整盘清空式的"重新安装"**一并删掉残留的 `LoaderEntryDefault` / `LoaderEntryOneShot`（无害，但会留下孤儿变量）。

#### 4.9.12 BIOS 更新

- **途径**：Windows Update 推送的固件胶囊，或华为电脑管家。胶囊暂存在 ESP 的 `EFI\UpdateCapsule`（U17 的 32 MiB 余量包括它）。BIOS 版本不设限（CLAUDE.md 硬件表）。
- **风险**：
  1. PCR0 变化 ⇒ BitLocker 要密钥。Windows Update 推送固件时会不会先暂停 BitLocker，待核。
  2. **安全启动被恢复成开启**：未签名的 systemd-boot 被拒，而固件里只有那一个门，**两个系统都进不去**；按 F9，失败满 3 次会关机【推断】。
  3. NVRAM 被重置：Loader* 变量和 U15 的自有项丢失，固件会重建 F4 那一项，回到回落路径，仍然能用【推断】。
  4. ESP 太满时胶囊被跳过。
- **对策**：
  - FAQ"更新 BIOS 之后开不了机"：进固件设置关掉安全启动；准备好 BitLocker 恢复密钥。**但平板姿态下进固件设置 / F12 的物理按键组合至今没解出**（ButtonsDxe 的映射没解出，CheckPostHotkey 读电源 / 音量键，§2.1）⇒ 列为 **E3 的必答项**（用户在场拍照确认，T17），写进 INSTALL 双系统一章和 FAQ；伴随工具检测到 BIOS 版本变化时，提示里带上这个按键组合。用户看到的只是黑屏关机，所以 FAQ 的标题要写症状。
  - BIOS 更新也可能解除 CVE-2023-24932 的屏蔽（§4.9.6），之后 Windows 可能改写 ESP 上的启动文件——由伴随工具的开机自检兜住。
  - 升级前先在 Windows 里跑一次 `-RepairBoot -Check` 留底。
  - D7 请准备升级的群友在升级前后各采集一次状态。

#### 4.9.13 卸载 Android，回到纯 Windows（U20）

Windows 脚本新增 `-RemoveAndroid`。**顺序是硬约束**：

0. **预检**：
   - 要求管理员；BitLocker 开着时确认有恢复密钥，并 `Suspend-BitLocker -RebootCount 1`；
   - 列出将要删的分区：PARTLABEL ∈ {misc, metadata, boot_a, boot_b, super, gk3rescue, userdata}、类型为 `0FC63DAF`、并且和 Windows 在同一块盘上；有内容魔数的再核一遍（`ANDROID!`、LP 元数据、ext4 超级块）。misc 没有可用魔数（新装机器可能全零），按"名字唯一、大小 ≤ `GK3_MISC_MIB`（重新安装可能复用更小的 misc，`installer-lib.sh:844`）、与其他已认出的分区同盘"认，BCAB 落地后加 BCAB 魔数作辅助；
   - **GK3LIVE 也要删**（按卷标加内容 `gaokun3/live.squashfs` 认）：它建在缩出空间的**开头**、紧贴 D:（`gaokun3-setup.ps1:247-250`），不删就扩不回 D:；
   - 输入 `YES` 才继续。
1. **先还原引导**：`BOOTAA64` ← **当前的** `EFI\Microsoft\Boot\bootmgfw.efi`。`.before-gaokun3` 只作最后的退路，并先比对版本：它是装机那天的拷贝，之后 Windows 更新过的启动管理器只在 `EFI\Microsoft\Boot` 里；若用户随后重新打开安全启动、而 DBX 已吊销旧版（CVE-2023-24932 的屏蔽是暂时的，§4.9.6），用旧拷贝的 Windows 会起不来。也可以跑 `bcdboot C:\Windows`，但它对 NVRAM 和回落路径的副作用先在 D4 弄清。（"两者同字节"只在 2026-08-20 出厂状态下实测过，F12。）`-RepairBoot` 的反向操作同理。
   - **这一步必须在删分区之前做**。反过来的话，systemd-boot 默认仍会进 Android：入口找不到分区就 fail-open 到直连条目，内核找不到 super，init 重启，如此循环，直到撞上 F9 的"3 次关机"。
2. **删 ESP 上我们的东西**：`<mid>/`（只删含 `android/` 或 `rescue/` 的那一个）、`loader/`、`EFI/systemd/`、`EFI/gk3boot/`、`EFI/gaokun3/`，以及 `.before-gaokun3` 备份。如果 `loader/entries/` 里还有不是我们的条目（共用 ESP 的另一个 Linux），只删我们的条目，保留 `loader/` 和 `EFI/systemd/`，第 1 步也不做，改为提示用户自己决定回落路径放谁。
3. **删变量**：Loader GUID 下的 `LoaderEntryDefault`、`LoaderEntryOneShot`，用 `SetFirmwareEnvironmentVariableEx` 以零长度删除——这是文档写明的语义（"setting this value to zero will result in the deletion of this variable"，https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariableexw ）【微软文档】，本机固件是否照做待 D4 / D6；U15 采纳时，按描述加路径认出自有 Boot#### 并删除。
4. **删分区 → 把 D: 扩回去**（可选），还原快速启动 / 休眠的设置。扩 D: 之前断言空闲区与 D: 相邻；不相邻就说明原因并停下，**不去动** WINPE / Onekey（出厂布局 p4 Data 后面紧接 p5 WINPE，`hw-inventory.md:482-483`）。
5. **重启**，核对直接进了 Windows。

发布前要在 Parallels 克隆机上用**脚本路径装出来的布局**（GK3LIVE 在前、Android 在后）完整跑一次往返：装上 → 卸掉 → Windows 正常、BitLocker 不要密钥（D4）。从 live 里卸载放到 1.x。

**反向迁移（删 Windows、把空间并给 Android）**：先试双系统、后来全转 Android 的用户。1.0 不支持保留数据的扩容，只能用安装器的"清除整个磁盘"整盘重装（数据另行备份）。写进 FAQ。

#### 4.9.14 双系统专属验证实验

**固件对纯 Android 盘的策略（F2–F9）可以在开发机上验证**，不需要 Windows。但**结论不外推到双系统盘**：盘上有没有 Windows 分区在实测中改变过启动选择（§4.9.2 末尾），双系统盘上谁先运行（H-A / H-B / H-C）只由 D5 的 U 盘只读部分和 D6 定。Windows 那一侧的行为靠 Parallels 或群友真机。

| 编号 | 在哪 | 写什么 | 重启 / 在场 | 验证什么 | 预期 / 判据 |
|---|---|---|---|---|---|
| D1 | 开发机（并入 E2） | 只读：私有挂载点 ro 挂 efivarfs | — / — | 列出全部 Boot####、BootOrder、BootTypeOrder、BootCurrent，hexdump `OemConfig` | 有一项 `Windows Boot Manager (…)`，FilePath 只到 ESP 分区，BootCurrent 指向它；如果一项 Boot#### 都没有，F4 要重审。同时看其他内置 FAT 分区（双系统机器上就是 Windows 脚本建的 GK3LIVE）有没有也被建了项：按 F4/F5，这类项会去找一个不存在的 `BOOTAA64`，失败一次就计一次 F9。只有 ESP 那一项失败时才会轮到它们，但要知道它们在不在 |
| D1 结果（2026-10-05 02:5x，只读） | 开发机 | efivarfs ro 挂在私有目录，读完卸载 | — | 只有一项 `Boot0000` = `Windows Boot Manager (PCIe-8 SSD 512GB)`；`BootOrder` = `0000`、`BootCurrent` = `0000`（本次开机走的就是它）；另有 `OemConfig-42927b59-…`（未解码）。开发机的 Windows 早在 08-20 抹掉，这一项只能是固件自己建的 ⇒ **支持 F4**；只有一块 FAT 分区（ESP），所以 F4/F5 的"其他 FAT 分区也建项"在开发机上看不到。`FilePath` 只到分区这一点没解码完（只看了描述串），留待 E2 用 efibootmgr 式完整解码 | ✅ 符合预期 |
| D2 | 开发机 | 写 NV：建 (a) 短格式 `HD()/File(\EFI\gk3test\sd.efi)`（efibootmgr 默认就写这种），以及 (b) 完整路径的同一文件，描述 `Windows Boot Manager (gk3test)`。(b) 的完整路径用 D1 读到的 F4 那一项的 FilePath **原始字节**加文件节点和 End 节点拼出 EFI_LOAD_OPTION，用小脚本直接写 Boot#### 变量；**不用 efibootmgr / libefivar 生成**：即使它有完整路径模式，也是从 Linux sysfs 推出路径，本机内核走 DT，推出来的几乎不可能与固件 `DevicePathFromHandle(ESP)` 逐字节相同，F2 按长度 CompareMem，会得出"完整路径项活不下来"的假阴性（U15 也会被错误否掉）。Android 镜像里本来也没有 efibootmgr（只在 live 的包清单，`scripts/live/pkgs-common.txt:59`）。另一个等价做法是让 `gk3probe.efi` 在 UEFI 里用 `DevicePathFromHandle` + 文件节点生成，与固件比较用的构造方式相同。`sd.efi` 是 systemd-boot 的拷贝；BootNext=(a) | 重启 2–3 次 / 用户在场 | F3（a 被删）、F6（BootNext 落空）、(b) 能否保留、保留时固件是否不再建 F4 项；再删 `sd.efi` 重启，看 (b) 被删、F4 项在同一轮里重建；前后读 `OemConfig` 看 F9 的计数 | 所有路径最后都落到 systemd-boot，风险低；实验后删掉 (b) 和 `EFI\gk3test` |
| D3 | 开发机 | 只读 | — | ESP 上有没有 `OneKeyLog.txt`。SMBIOS Type 11（F10 的 `$HUA`/`CN` 门槛）**读不了**：本机内核没开 `CONFIG_DMI_SYSFS`（`docs/relnotes/v0.7.1-alpha-config.txt:1814`），`/sys/firmware/dmi/entries/` 不存在，live 同样；**不用 `/dev/mem`** 读 SMBIOS（CLAUDE.md 操作禁忌 2）。改在 Windows 侧读（D5），或给测试内核打开 DMI_SYSFS | 解释为什么开发机从没被带进 WinPE |
| D4 | Parallels 克隆机（Windows 11 ARM；固件不同，只验证 Windows 这一侧） | 克隆机随便写 | 多次 / — | ① `bcdboot C:\Windows`、累积更新、功能更新、"重置此电脑（保留文件）"前后，比对 `\EFI\Boot\bootaa64.efi` 的 sha256 和 `bcdedit /enum firmware`；② PowerShell P/Invoke 写 `LoaderEntryOneShot`，重启看是否进了对应条目；③ 开着快速启动关机，在外部改 ESP，再进 Windows 触发 ESP 写入，然后 `fsck.vfat -n`；④ `0FC63DAF` 加 bit 0 的分区在磁盘管理里怎么显示；⑤ `-RepairBoot`、`-RemoveAndroid` 往返；⑥ vTPM + 关安全启动 + BitLocker：`manage-bde -protectors -get C:` 的 PCR 列表，换掉 systemd-boot 前后要不要密钥 | 定 T11c / T11e / T11h 和 U18 / U19 / U20 |
| D5 | 群友双系统真机，**只读** | 不改任何东西 | 进一次 U 盘 live / 群友 | **Windows 里**：`bcdedit /enum firmware`、`/enum {fwbootmgr}`；`manage-bde -protectors -get C:`；msinfo32 的 PCR7 配置；`mountvol S: /S` 后 `dir /s S:\`（ESP 占用、`Persisted_Capsules.bin`、`OneKeyLog.txt`）；SMBIOS Type 11 用 `Win32_ComputerSystem.OEMStringArray` 读（https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-computersystem ）；电源设置（休眠是否开着）；两边的蓝牙地址；PowerShell P/Invoke **只读** `GetFirmwareEnvironmentVariableEx`。**U 盘 live 里**：`efibootmgr -v`（Windows 项的 FilePath 是短格式还是完整路径）、BootOrder、BootCurrent；**插着与拔掉 U 盘各冷开一次，记默认进了谁**（T11k）；只读读 SDAM 0xbc 与 `date -u`；BcdOneKey 变量 | 固件项的描述应是带括号的 `Windows Boot Manager (…)`；不应有 Windows 自己的短格式项。**这是 H-A / H-B / H-C 的第一份定论**（§4.9.2） |
| D6 | 群友真机，装双系统（**恢复密钥在手、数据已备份**） | 安装 | 多次 / 群友在场 | 冷开机进谁；F12 列表拍照；经菜单进 Windows 后触摸是否正常；BitLocker 在关安全启动后**连续 3 次以上**开机各要不要密钥（T11d）；时钟交叉实验（§4.9.9）；Windows 功能更新前后 ESP 空闲变化；Windows 写 OneShot（"重启到 Android"）；Android"重启到 Windows"；§4.9.3 表里两种默认的六个场景；两系统切换后时间是否一致；Windows 脚本默认路径（bootsequence）是否落空 | 通过后双系统去掉"预览"（U21） |
| D7 | 群友，有机会时 | 只读 | — | Windows 功能更新、BIOS 更新前后，各跑一遍 D5 那组命令，加上安全启动状态 | 定 R8 / R10 的发生率 |
| D8 | 主机侧单测（并入 E0） | — | — | GK3 状态机：`clean_poweroff` / `next=windows` / `set_default` 与 Android 待办的优先级、`LoaderEntryDefault` 清理、预置 OneShot 与 fail-open 的先后、U7 计数与"开机途中强关改进 Windows" | 全分支覆盖 |

补到 D4 的几项（Parallels，只代表 Windows 一侧）：⑦建一个描述为 `Windows Boot Manager (Android)` 的固件项，跑 bcdboot 和功能更新，看会不会被当成 Windows 自己的项改写、去重或删除（U15）；⑧手动休眠一次再外部改 ESP（U24）；⑨关机 / 重启的区分判据（候选是系统日志 Event 1074 记录的关机类型，https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-unexpected-reboots-system-event-logs ）以及更新自动重启时计划任务能否在复位前写完变量（U25、T15）；⑩`auto-windows` 与 `gk3-windows` 两种条目启动的 Windows，PCR4 是否相同（U22）；⑪`Suspend-BitLocker -RebootCount` 在中途进别的系统时怎么数。

纪律与 §6 相同：开发机上的 D2 要征得同意并有人在场，**结论只说明纯 Android 盘**；群友实验只请对方做只读命令，或者在对方明确接受风险、恢复密钥在手的前提下做 D6；不请任何人做 F10 一键恢复，不故意让 Windows 启动失败；外接盘和 Parallels 的结论不外推到华为固件。

#### 4.9.15 Windows 伴随工具（U23）

今天 Windows 侧的一切能力都默认"用户手里有那个 .ps1"：它只是下载包里双击运行的脚本（`scripts/windows/README.md`），只把文件拷到 GK3LIVE 和 ESP，没有安装位置，也没有开始菜单项；装完 Android、U19 又去掉了 GK3LIVE 的盘符；从 U 盘装双系统的用户从没运行过它。而 `BOOTAA64` 被 Windows 换掉之后，Android 已不可达，检测只能在 Windows 侧做（§4.9.6）。所以 1.0 把它升级为**常驻组件**：

- **安装**：setup 时把自己装到 `%ProgramFiles%\gaokun3`（与 ESP 上的 `EFI\gaokun3` 无关），建开始菜单项：重启到 Android、默认启动的系统、修复 Android 启动、仅暂停 BitLocker、卸载 Android。
- **执行方式**：以 SYSTEM 运行的计划任务（§4.9.4 已有），开始菜单项只触发固定动作，**不接受用户传入的参数**，避免成为提权通道。
- **开机任务，默认开、不可关**：①`BOOTAA64` 自检（与 `EFI\systemd\systemd-bootaa64.efi` 比 sha256，不同就通知并给一键修复）；②`LoaderEntryDefault` 规范化（§4.9.3）；③BIOS 版本变化时提醒，提示里带进固件设置的按键组合（E3 得出，§4.9.12）。
- **开机任务，可选**：Windows 侧预置 OneShot（U25）——Windows 每次开机写 `LoaderEntryOneShot = auto-windows`，Windows **关机**（不是重启）时比较后删除；于是 Windows 的任何重启（含更新的多次自动重启、驱动安装后的重启）都回 Windows，**不用另外判断"更新挂起"**，休眠后的开机也回 Windows 去恢复。前提：D4/D6 证实 Windows 能写这个变量，且 D4 的⑨找到可靠的关机 / 重启判据。删除失败的后果只是下一次冷开机进 Windows，菜单仍可手选。
- **一次性设置**：双系统一律关快速启动（U18）；按 U24 关休眠；`-Uninstall` / `-RemoveAndroid` 时恢复。装上 Android 之后删掉 setup 建的 bcdedit 对象（"gaokun3 installer"，`$state.bcd`；在 H-A 下对应的固件项早被删了，但 Windows 的 BCD 里还留着 `{bootmgr}` 的副本），保留 `EFI\gaokun3`（live，安全网）。
- **U 盘路径的用户怎么拿到它**：U 盘介质的 FAT 分区上放一份 `gaokun3-windows/`（Windows 能直接读）；安装完成页和 Android 首次开机后的 Parts 都提示"回到 Windows 后安装伴随工具"，并给出下载地址。
- **没有工具时的手工修复**（写进 FAQ）：①`Suspend-BitLocker -MountPoint C: -RebootCount 1`（与脚本同一个 cmdlet，`gaokun3-setup.ps1:338`）；②挂 ESP；③把 `\EFI\systemd\systemd-bootaa64.efi` 拷到 `\EFI\Boot\bootaa64.efi`。挂 ESP 的命令（`mountvol` 的 `/S`）实施时引用微软文档再写。另一条路是 U 盘 live 的"修复启动"。
- **仅暂停 BitLocker**（`-SuspendBitLocker`）：只执行 `Suspend-BitLocker -RebootCount 2`，不碰别的。给 U 盘路径的第 0 步用（§4.9.7 规则 6）。

#### 4.9.16 其他共存问题

- **两个系统之间交换文件**：内核开了 `CONFIG_EXFAT_FS=y` 与 `CONFIG_NTFS3_FS=y`（`docs/relnotes/v0.7.1-alpha-config.txt:6991`、`:6994`），但 Android 用户空间会不会挂载它们**未核**，而 BitLocker 加密的 D: 本来就读不了；Windows 也看不到 Android 分区。1.0 不承诺，FAQ 明说；1.x 可选一个 exFAT 共享分区。
- **指纹（T6 落地之后）**：两个系统用同一颗 FTE7001 和同一个华为签名的 TA。Android 侧录入、或安全存储 listener 写入，会不会覆盖或破坏 Windows Hello 的指纹模板，**完全没评估**（T16）。T6 的 enroll 设计要先回答这一条，再在双系统机器上开放指纹录入。
- **待机切换**：见 §4.9.10 末尾。
- **另一个 Linux 共用 ESP**、**gk3boot 找分区的范围**：见 §4.9.11。

#### 4.9.17 面向用户的双系统日常使用说明（INSTALL / FAQ 双系统一章的骨架）

S13 按这份清单写，每条落笔前按 §4.9.14 的结果把【推断】改成实测或"未验证"：

1. **开机看到什么**：systemd-boot 菜单 5 秒，第一项 Android、第二项 Windows（U22）；默认进安装时选的系统；从 Android 关机后再开 Windows，会看到两次 Logo。
2. **怎么切**：Android → Parts（目标：电源菜单）里"重启到 Windows"；Windows → 开始菜单"重启到 Android"（要装伴随工具）；或开机时在菜单里选（音量键 / 电源键能否操作以 E3 为准）。
3. **怎么改默认**：Parts 或伴随工具的"默认启动的系统"；菜单里按 `d`（再按一次撤销）。
4. **重启会回到哪**：Android 里的任何重启回 Android；Windows 里的重启回默认系统（U25 落地后回 Windows）；以 Windows 为主就把默认设成 Windows。
5. **BitLocker**：装之前（关安全启动之前）先拿到恢复密钥并暂停或解密；之后可能还会要（§4.9.7 的未知）。
6. **别做的事**：别在磁盘管理里删 Android 分区；别删 ESP 上的文件（尤其 `Persisted_Capsules.bin`）；别用"从驱动器恢复"和华为 F10 一键恢复；Windows 里用"关机"不用"休眠"；更新 BIOS 前先暂停 BitLocker、记好进固件设置的按键。
7. **Windows 更新后 Android 不见了**：伴随工具会提示，点"修复 Android 启动"；没有工具就按 FAQ 手工三步或用 U 盘。
8. **看到华为一键恢复界面**：别点恢复，插 U 盘从 live 进（§4.9.6）。
9. **待机**：Windows 待机中按电源键回到的是 Windows；要进 Android 先"重启到 Android"。
10. **卸载**：伴随工具"卸载 Android"；反过来"删 Windows 把空间给 Android"只能整盘重装。

### 4.10 存量 BCB 迁移

- 由 gk3boot **第一次运行**时做：没有迁移标记时，只清 0–2 KiB，原文摘要存进 GK3，写标记，本次不执行任何 BCB。
- 不放在 postinstall 里做：没有 misc 权限，还撞 neverallow（`postinstall.te:49`；`private/domain.te` 的 misc neverallow）。
- 新装机器由安装器直接写标记。
- 如果 BCB 分派开关在后续版本才打开（分阶段交付），迁移随**开关打开的那一版**的 gk3boot 一起做（迁移标记里带"分派版本"字段）。

### 4.11 入口自身的更新与回滚

- **版本化目录**：`EFI/gk3boot/<ver>/`。版本号同时写进目录名、条目的 `version` 和二进制里的字符串；sha256 清单随 vendor 下发，`release.sh` 断言附件与 vendor 里那份一致。
- **分阶段激活（1.0 起，"一次只换一样"）**：
  1. OTA：postinstall 只写新目录和 `.staged` 条目；
  2. 重启后，**旧入口**启动**新槽**（boot.img 契约不变），新槽 tries 照常；
  3. 新槽开机完成：HAL 线程把当前已确认的 `gk3boot-android-*.conf` 改名为 `gk3prev-android-*.conf`，把 `.staged` 改名为 `gk3boot-android-*+3.conf`，删除没有任何条目引用的旧目录；
  4. 下一次开机由新入口启动；连续 3 次没走到开机完成 ⇒ gk3prev（已知可用的入口 + 已知可用的槽）。
- **手动回滚**：删掉 `EFI/gk3boot/<ver>/`，条目会因 efi 文件不存在而被跳过（`boot.c:1531-1535`）。live、救援、Windows 里都能做。全删 `EFI/gk3boot/` 就回到 0.7 的直连路径。
- **systemd-boot 本身**不随 OTA 更新，只由安装器写。

### 4.12 安全与兜底

**fail-open 阶梯**（gk3boot 的任何内部错误、panic handler、StartImage 返回）：
1. 写 `LoaderEntryOneShot = <mid>-android-<已选槽或 hint>.conf`（直连条目），然后 `ResetSystem(Cold)`。下一次就是今天的老路。
2. 写变量失败 ⇒ 把自己的条目改名为 `+0`（计数用完，排到最后），再复位。
3. 两样都失败 ⇒ ConOut 显示原因和"长按电源键 / 插 U 盘"的指引，等待按键后复位，**不自动循环**。
4. GPT 或 misc 不可用、有歧义：不写任何东西，直接走第 1 步。
5. **绝不** `return` 错误码（华为 BootFail 计数），也不返回 `SUCCESS`（会停在不倒计时的菜单上）。唯一例外是 GK3 一次性意图 `next=sdboot-menu`，那时返回 SUCCESS 正是想要的效果。

**写盘范围最小**，gk3boot 只写这些：
- misc 里未成功槽的 tries；
- 已消费的 BCB command（bootonce / `--fastboot` / 未知命令 / wipe 3 次上限之后）；
- GK3 记录；
- 失败时自己条目的计数（`+0`），或一次 OneShot；
- 双系统（§4.9.3、§4.9.4）：Windows 为默认时每次启动 Android 预置一次 `LoaderEntryOneShot`；消费 `next=windows` / `clean_poweroff` 时写 `OneShot=auto-windows` 后复位；`set_default` 时写或删 `LoaderEntryDefault`；`LoaderEntryDefault` 是 Android 的精确 id 时删掉它。这些都是 NV 变量，不是 ESP 文件。

**从不写** `boot_x`、super、userdata、metadata、GPT、loader.conf、`BOOTAA64`，也从不建、删、排 Boot####。正常路径对 ESP **零写入**：计数由 systemd-boot 改名，bless 由 Android 做，而且只在入口新部署后那几次开机。

**交接防御**：
- 不切 GOP 模式；
- StartImage 返回时撤掉 LoadFile2 和 DTB 表再走阶梯；
- 交接前把看门狗设成 0 由 ExitBootServices 处理？**不**：EFI stub 退出启动服务时会关掉 UEFI 看门狗，gk3boot 不额外处理。进入菜单类交互只发生在 Linux 执行端。

**观察模式**（`gk3.observe=1`）：决策照算，屏幕打印一行 trace；**不写 misc、不扣 tries、不消费 BCB**；交接走同一段代码。上机顺序：非默认条目经 OneShot 进入 → 开发机默认条目开 N 次机 → 切到动作模式。

**QEMU 预验证**：
- 环境：QEMU aarch64 + AAVMF + systemd-boot 257.13 + 与真机同名的 GPT 夹具，另有双系统 128 项 GPT、重名、缺失的变体。
- "内核"用一个测试 PE 桩：打印 LoadOptions，校验 DTB 表与 LoadFile2 initrd 的 sha，然后复位。
- 覆盖：选槽、tries、VAB、全部 BCB 分支、迁移、SHA1 损坏、fail-open 阶梯、计数改名与 bless、在 misc 写入之间断电注入。
- BCAB 和 BCB 与 GBL 的单测向量、libboot_control 的行为逐字节对拍。真内核只能上机验证。

**攻击面**：fastboot 不认证、恒为解锁（C′ §4.10），要披露。能进入的只有拥有已授权 adb 的人或能物理接触的人，后者本来就能用 U 盘写盘。Secure Boot 必须保持关闭（入口和内核都没签名；systemd-boot 在 SB 开启时会跳过 DTB，`boot.c:2577-2582`）。

**华为固件特有**：
- HwBcdOneKey 的 `HwStartImage` 钩子对 gk3boot 自身的加载与今天的 efi 条目相同（#73 有三轮 chainload 实测），但对**缓冲区** LoadImage 的影响未知（E4）；
- EC 看门狗（HwOpenWdtDxe）只影响长时间停留在 UEFI 的场景，1.0 的入口不在 UEFI 里停留（交互都在 Linux 执行端）；
- 触摸：不碰 AbsolutePointer。

### 4.13 界面

| 场景 | 界面 |
|---|---|
| 正常开机 | 纯 Android：无（只有固件 logo，以及 loader.conf 的菜单策略，U3）；双系统：每次显示 5 秒 systemd-boot 菜单（U13），转去 Windows 的那一次会看到两次 Logo（§4.9.3） |
| 观察模式 | ConOut 一行 trace |
| gk3boot 出错 | ConOut 英文错误页（方向待 E3 拍照） |
| 执行端 | tty1 英文文本，fbcon=rotate:1，evdev 按键（C′ §4.8），INSTALL 给中文对照 |
| systemd-boot 菜单 | 条目 title 改清楚，**一律 ASCII**（UEFI ConOut 的 CJK 字形没验证过，E3 拍照核对）：`Android`、`Windows`（双系统时排第 2，U22）、`Android boot menu / Fastboot`、`Android (previous loader)`、`Android direct a/b (rescue)`、安装器、救援；中文对照写进 INSTALL |

UEFI 下的 Blt 横屏大字、中文点阵：1.x，与 UEFI 内 fastboot 一起做。

### 4.14 SELinux

- **gk3boot 和执行端**：不在 Android 策略的管辖范围内。
- **Android 侧净减少**：没有 efivarfs，没有 bootintent 域。双系统的"重启到 Windows"和"默认启动系统"都走 GK3 意图（U14 选 a），所以这一点保持成立。
- **新增**：
  - vendor rc 的 `vendor.gaokun3.boot.done` 属性上下文和 vendor_init 的 set；
  - hal_bootctl 读该属性、设 `vendor.gaokun3.bootentry.*`；
  - Parts 读 `vendor.gaokun3.bootentry.*` 和 `ro.boot.gk3boot.*`（`bootloader_prop`）。
  - HAL 原有的 misc 和 ESP 规则不变；
  - 双系统：Parts 设 `vendor.gaokun3.bootentry.request`、HAL 读它并设 ack；`gk3-misc mark-poweroff` 的 vendor 域（在 `on shutdown` 里 exec，读 `powerctl_prop`、写 `misc_block_device`）。U14 如果改选 b，就要加回 efivarfs 的类型、genfscon 和写权限。
  - 随下一轮 SELinux 在 enforcing 下验证。
- postinstall：复核第五轮已补的 ESP 写规则能否覆盖 `EFI/gk3boot/` 的写入和改名。

### 4.15 开发流程改动

- **`install-ota-local.sh` 第 4 步必须改**：
  1. 装完后 `bootctl set-active-boot-slot <当前槽>` 撤销激活（`libboot_control.cpp:306-310` 的注释说明了这种用法）；
  2. 用 OneShot 走新槽的**直连条目**验收（绕过入口）；
  3. 验收通过后显式 `set-active` 到新槽。
  - 或者信任入口的 tries 回落，但必须有人在场。
- **`boot-oneshot.sh`**：存在性检查改为同时匹配 `name+*.conf`，OneShot 写去掉计数后的 id；`--list` 显示计数和 `gk3-misc` 的解码。
- **测试内核**：继续用直连条目，文件名不能匹配 `*-android-[ab].conf`；也可以写一个 efi 测试条目，用 `gk3.kernel=<ESP 路径>`（只在 observe 构建里认）让入口加载测试内核。
- **`scripts/misc-dump`**：调 `gk3-misc dump`，只读。

---

## 5. 实施步骤

| # | 内容 | 工作量 | 需要 | 产物 |
|---|---|---|---|---|
| S0 | **零风险准备**：`clone-refs.sh` 加入 systemd v257.13、hardware-interfaces boot/、GBL（gbl-mainline 钉提交）、CLO ABL；BIOS 2.16 拆包与 `fwa/` 工具留档到 `docs/hw/`；本文的引用复核 | S | 联网 | 可复现的 refs |
| S1 | **构建机只读核实（E1）**，light 档，用完 stop | S | 构建机 | crDroid 树 libboot_control 常量与布局；misc 8 KiB 是否空闲；update_engine 里 SetActive 与 postinstall 的先后；Settings / uncrypt 写 BCB 的确切参数；libsnapshot 的源槽与 forward-merge 取法 |
| S2 | **`libgk3core`** + 主机测试：真实 misc dump（CRC 67ddc320）、boot.img（SHA1 9274d5f8…）、安装器 loop 夹具的 GPT、GBL / libboot_control 向量 | M | 本机；U2 先定语言 | 库 + golden 向量（执行端共用） |
| S3 | **工具链与 QEMU 夹具**：arm64 Docker（与 live 同款）+ AAVMF + systemd-boot 257.13 + 测试 PE 桩 + 夹具盘 | M | colima（本机当前没在运行），qemu-efi-aarch64 | `scripts/gk3boot/test-*.sh` |
| S4 | **`gk3probe.efi`**（只读探针，见 E3） | S | S3 | 探针 |
| S5 | **gk3boot 主体**：定位、决策、H2 / H1 交接、fail-open、观察模式、cmdline、事件 | L | S2、S3；E3 / E4 门槛 | `gk3boot.efi` |
| S6 | **BCB 分派与执行端引导**：迁移、分派计数、bootloop 计数、一次性意图、内核来源三级回落 | M | S5 | — |
| S7 | **执行端**：C′ §5 的第 1、2、4、5、6 步子集，改为读 `gk3.why/disk/slot`；`set_active` 与 slot getvar 用 `libgk3core`；"Other systems" 写 OneShot | L（3–5 周） | 本机 Docker + platform-tools；E6 | `fastboot.img` |
| S8 | `gk3-esp-sync` 抽取 + 静态 bootimg_extract（C′ 第 3 步） | M | 并入 ROM 构建 | 共用件 |
| S9 | **Android 侧**：HAL 开机完成线程、vendor rc、属性与 sepolicy、Parts 通知；postinstall 部署 / staged / 停铺 recovery-ramdisk；vendor 里加 `/vendor/boot/gk3boot/`；prebuilt 目录 + `sync-device-tree.sh` 断言 | M | 一次 ROM 构建（rom 档，并入已排的批次） | — |
| S10 | **安装器**：清单、条目、misc 初始化、收紧停用匹配、`gk3_esp_info`、test-apply 用例；release.sh 附件和断言 | M | 安装器重建 | — |
| S11 | **开发脚本**：install-ota-local 第 4 步、boot-oneshot 认识计数、misc-dump | S | 本机 | — |
| S12 | **Windows 伴随工具**（U23）：入口路径约束回归、安装到 `%ProgramFiles%\gaokun3` 与开始菜单、SYSTEM 计划任务、开机自检 / 规范化 / BIOS 提醒、`-RepairBoot [-Check]`、"重启到 Android"、`-SetDefault`、`-SuspendBitLocker`、`-RemoveAndroid`（含 GK3LIVE 与相邻断言）、快速启动一律关、U24 关休眠、GK3LIVE 去盘符、U 盘介质带一份；U25 的 Windows 侧预置（D4 之后）；D5/D6 之后决定默认路径是否改为 `-UseFallbackPath` | M（1–1.5 周） | Parallels 克隆机（D4） | — |
| S15 | **双系统其余部件**（§4.9）：gk3boot 的默认系统检测、预置 OneShot、`next=windows` / `set_default` / `clean_poweroff`（并入 S6）；HAL 动作 6/7、`gk3-misc mark-poweroff` 与 `on shutdown`、Parts 的两个入口（并入 S9）；安装器双系统专项与文案（并入 S10）；INSTALL / FAQ 的双系统一章（并入 S13） | M | 同上各步；D1–D3 在第 1–2 周随 E2/E3 做 | — |
| S13 | **文档与发布物**：INSTALL（中英）"启动入口与 fastboot"一章（进入方式、port0 是哪个物理口、计数回落、准备 U 盘、不认证、不是安全擦除、英文界面对照）、FAQ、flash-all.sh/.bat、发版说明 | S | E3、E6 结果；用户目视确认 port0 | — |
| S14 | **上机验收** E2–E11 | L | 用户在场 6–8 次 | 案卷 |

**顺序与里程碑**：
- **第 1–2 周**：S0–S4 离线完成；S1 开一次构建机；同时排 E2（只读，含 D1、D3）、E3（同一次上机加做 D2）、E4 两次上机；D4（Parallels）和 D5（群友只读）不占开发机，尽早发出去。**E4 是硬门槛**：通过就走 H2；不过试 H1；H1 也不过就退化为 Z 形态（决策用 OneShot 表达），请用户重新定。
- **第 3–5 周**：S5、S6，在 QEMU 全绿后上开发机做观察模式（E5）→ 计数互操作（E6 前半）。
- **第 3–8 周**（并行）：S7 执行端。
- **第 6–9 周**：S8–S12 集成，一次 ROM 构建 + 一次安装器重建；E7–E11。
- **第 9–10 周**：S13，发版。D5/D6 没有一台真机通过时，双系统在发版说明里标"预览"（U21），不挡发版。
- **可提前交付的部分**（执行端延期时）：入口 + A/B tries 自动回滚可以单独发，满足 G6；BCB 分派开关关闭，迁移随开关打开的那一版做。
- **约束**：BCB 分派开关的打开，必须与执行端、迁移在**同一版本**发布（E-K7）。

---

## 6. 验证实验（按安全顺序）

| 编号 | 内容 | 只读 | 需重启 | 用户在场 | 写 ESP | 写 misc | 擦数据 |
|---|---|---|---|---|---|---|---|
| E0 | 离线：`libgk3core` 主机测试 + QEMU 全分支与断电注入；执行端在容器里走 loop 盘 + TCP 与真 fastboot 对拍 | ✔（不碰设备） | — | — | — | — | — |
| E1 | 构建机 light 档只读 grep（S1 的清单） | ✔ | — | — | — | — | — |
| E2 | 设备只读：`cat /proc/cmdline`、`getprop \| grep ro.boot.`、`bootctl get-current-slot / is-slot-bootable / is-slot-marked-successful`、`ls -l /dev/block/by-name`、`dd` 只读读 misc 0–64 KiB 并用 `gk3-misc` 解码、对 `boot_a/b` 复算 SHA1(id)、`dmesg \| grep -i efi`。**征得同意后**：私有挂载点 ro 挂 efivarfs 读 Loader* / UsbConfig 变量；ro 挂 ESP 列出条目、slot、余量、有没有 recovery-ramdisk | ✔ | — | — | — | — | — |
| E3 | `gk3probe.efi`，非默认条目经 OneShot 进入，拍照记录：设备路径 → 整盘、GPT 名单、读 misc / boot 与 SHA1 的耗时；ConIn 对音量上下、电源键、键盘盖的扫描码；**进固件设置 / F12 的物理按键组合（必答，T17）**；含 CJK 与 `—` 的测试条目标题能否显示；GOP 模式与 ConOut 方向；内存图；`LoaderBootCountPath`；**缓冲区 LoadImage 一个测试 PE 并 StartImage**；可选：停留 6 分钟测 EC 看门狗 | 不写 misc | ✔ | ✔ | ✔（一个探针 + 一个条目） | — | — |
| E3 结果（2026-10-05 06:14，无人值守） | `gk3probe.efi`（`7f374d3`，sha256 `97632d46…`）经 OneShot 进入、跑完冷复位、70 秒回到 Android；日志 [`docs/hw/gk3probe-e3-20261005.txt`](hw/gk3probe-e3-20261005.txt) | ✔ 只读 | ✔ | 无人 | 放探针 + 条目，事后已撤 | — | — |
|  | **结论**：`errors=0`，4.3 秒。① **缓冲区 LoadImage + StartImage 在华为固件上通过**（带 / 不带设备路径两种，LoadImage 161 / 2.6 ms，子镜像拿到 LoadOptions）⇒ `HwStartImage` 钩子不拦，E4 的前置门槛已过；② **`EFI_USB_DEVICE_PROTOCOL`（d9d9ce48）有 1 个 handle**，`EFI_USBFN_IO` 没有 ⇒ 1.x 的 UEFI 内 USB fastboot 只能走高通私有协议；③ GPT 六个名字各唯一，boot_a/b 28.8 MB 读 23.5 ms、SHA1(id) 139 ms 均与头一致，misc 64 KiB 读 0.4 ms；④ GOP 当前模式 7 = 2560×1600（RotateScreen 的虚拟横屏模式），中文 `OutputString` 返回 SUCCESS（屏上是否可见待目视）；⑤ ConIn / ConInEx 在（含键盘盖 USB(0x2,0x2)），keyscan 无人按 ⇒ 键码待用户在场；⑥ systemd-boot 257.13-1~deb13u1，固件 `Qualcomm Technologies, Inc. 8483.513`、UEFI 2.70；`LoaderBootCountPath` 未设（条目无计数，符合预期）。 | | | | | | |
| E4 | **门槛**：gk3boot 观察模式，非默认条目经 OneShot 进入，第一次真正启动 Android（H2：缓冲区 LoadImage 真内核 + DTB + LoadFile2）。核对 `/proc/cmdline`、`ro.boot.slot_suffix`、`ro.bootloader`、HAL 无崩溃、avc、efi_pstore / efivars 是否可用、RNG / KASLR、开机耗时与直连对比。不过就换 H1 再测 | 不写 misc | ✔ | ✔ | ✔ | — | — |
| **E4 结果（2026-10-05 07:13，无人值守）：✅ 门槛通过** | `gk3boot.efi` `0.1.0-e4.g435f5b58cecb`（`93108c0`，sha256 `2ee681de…`）观察模式、`gk3.slot=b`，经 OneShot 进入，**H2 从 `boot_b` 分区直接把 1.0.0-dev.3 起到开机完成**（38 s adb、53 s boot_completed，与直连条目相当）；日志 [`docs/hw/gk3boot-e4-20261005.txt`](hw/gk3boot-e4-20261005.txt) | ✔ 只读（misc sha1 前后同为 `45f21236…`） | ✔ | 无人 | 放入口 + 条目，事后已撤 | — | — |
|  | 入口自身 189 ms：读 boot_b 29.2 MB 23 ms、SHA1(id) 141 ms、LoadImage(15.98 MB zboot) 9 ms；dtb 装成配置表（原表 0x0 = 固件不装 DTB，与 §2.1 一致）、initrd 走 LINUX_EFI_INITRD_MEDIA LoadFile2（cmdline 里没有 `initrd=`、内核报 `Freeing initrd memory: 12772K`）、LoadOptions 1370 字节；Android 侧 `/proc/cmdline` 多出 `androidboot.bootloader=gk3boot-…` 与 `androidboot.gk3boot.{event,entry,mode}`，`ro.bootloader=gk3boot-…`、`ro.boot.slot_suffix=_b`、`bootctl get-current-slot`=1；KASLR、RNG、efivars、`efi_pstore` 照常注册；avc 4（同基线）。决策 `boot slot=_b active=_b`、`would: no misc write (slot already successful)`。⇒ **H2 路线成立，不需要退到 H1 / Z**。下一步 E5（观察模式做默认、带计数）前要先补 fail-open 的'写 OneShot 再复位'（README §10 限制一条）。 | | | | | | |
| E4u | （仅为 1.x，可选）UEFI USB 门槛：fastboot 桩只做 getvar / download（进内存）/ reboot；SignalEvent(1c0cffce) → StartEx → 主机能否枚举、速率、吞吐 | 不写盘 | ✔ | ✔（port0 接 Mac） | ✔ | — | — |
| E5 | 观察模式设为开发机默认（带 `+3`），连续开机 ≥10 次：每次用 `gk3-misc` 对照"入口会怎么选"和实际槽；检查条目文件名递减，以及开机完成后被 bless | — | ✔ | 第一次在场 | ✔ | — | — |
| **E5 结果（2026-10-05 08:04，无人值守）：✅ 10/10** | gk3boot `0.2.0-e5.g09442bc9773e`（动作模式代码、本次以观察模式运行）作开发机**默认条目** `gk3boot-android-{a,b}+3.conf`（sort-key `0gk3`），连续 10 次开机全部经 gk3boot 进 `_a`（51–55 s），misc 64 KiB sha1 始终 = 基线 `7add26f8…`；**华为固件上 systemd-boot 的计数改名正常**（`+3 → +2-1`，`LoaderEntrySelected` 报去掉计数的 id `gk3boot-android-a.conf`）。记录 [`docs/hw/gk3boot-e5-e6-20261005.txt`](hw/gk3boot-e5-e6-20261005.txt) | ✔ | ✔×10 | 无人 | 放入口 + 2 条目，事后已撤 | — | — |
| E6 | 计数与 fail-open：故意 fail-open 的测试版（非默认，经 OneShot）→ 应自动落到直连条目，不需按电源键；故意挂死版 → 测看门狗（可能要长按电源键）；分阶段激活演练。执行端（非默认 `gk3boot-tools` 条目）：`fastboot getvar all`；目标用 `gk3.disk` 指向**外接盘**沙盒做 flash；"Other systems"写 OneShot 是否可用；请用户确认 port0 的物理位置 | — | ✔ | ✔ | ✔ | — | — |
| **E6 结果（2026-10-05 08:16–08:22）：✅ 计数兜底 + fail-open 均通过** | ① 不祝福连续 4 次：`+2-1 → +1-2 → +0-3` 三次经 gk3boot，**第 4 次 systemd-boot 自己改走直连 `<mid>-android-a.conf`**（`ro.bootloader=unknown`）；② `gk3.observe=2` 经 OneShot 强制 fail-open：`LoaderEntryOneShot=<mid>-android-a.conf written (attr 0x7, 96 bytes), read back OK` → 冷复位 → 直连条目起来（79 s，OneShot 已消费）⇒ gk3boot 在华为固件上能写 NV 变量、冷复位后固件照常走回落路径。看门狗 120 s 是否真复位、挂死场景**未测**（要人在场）。 | ✔ | ✔×5 | 无人 | 放条目，事后已撤 | — | — |
| E7 前置（2026-10-05 08:3x，构建机只读）✅ | misc 8 KiB（GK3 记录）**没有其他使用者**：crDroid 树里引用 `VENDOR_SPACE_OFFSET_IN_MISC` / `{Read,Write}MiscPartitionVendorSpace` 的只有 `hardware/google/pixel/misc_writer/`（Pixel 专用，设备上 `/vendor/bin`、`/system/bin` 都没有 misc_writer）；本仓 boot HAL 只经 libboot_control 写 BCAB（偏移 2048）；安装器只在重装时整块清零 misc（`installer-lib.sh:850`）。 | ✔ | — | — | — | — | — |
| E7 | 切到动作模式（开发机默认）：`adb reboot bootloader / fastboot / recovery` 各 2–3 次，确认 BCB 被正确清除或保留、fastboot reboot 能回 Android；手工写一条假的存量 BCB 验证首跑迁移只清不执行并通知；写 `boot-quiescent`，确认会被清掉；`bootctl set-active-boot-slot` 当前槽让 successful=0 → 入口扣 tries → 开机完成 | — | ✔ | ✔ | ✔ | ✔ | — |
| **E7 结果（2026-10-05 08:3x，无人值守）：✅ 正常路径与 BCB 不消费** | 动作模式作默认条目连续 5 次：BCB / BCAB / VAB 逐字节不变（`_a` 已成功，不扣 tries），8 KiB 处建出 GK3 记录（`GK3R`），streak 1→5 并经 `androidboot.gk3boot.streak` 报给 Android，**ESP 零日志**；`adb reboot bootloader` 后：`bcb: kind=bootloader … dispatch is off (E-K7): NOT consumed, NOT cleared, booting Android`，只在这种异常时写一份日志。事后 misc 前 64 KiB 写回基线（sha1 `7add26f8…` 读回一致）、条目撤回直连。记录 [`docs/hw/gk3boot-e7-20261005.txt`](hw/gk3boot-e7-20261005.txt)。⬜ tries 扣减 / 自动回滚在真机上要等 E8（需要一个真写过 super 的 OTA 新槽）。 | ✔ | ✔×6 | 无人 | 放条目；写回 misc 基线 | ✔（GK3 记录，已复原） | — |
| E8 | 自动回滚演练：用改过第 4 步的 `install-ota-local` 往 `_b` 装一个故意 panic 的版本（`init=/nonexistent`），set-active b，不再碰机器：观察 tries 6→0 后回到 `_a`、event 和通知；**必须用真正写过 super 的 OTA**，不能直接 set-active 到现在这个陈旧的 `_b` | — | ✔（多次自动） | ✔ | ✔ | ✔ | — |
| E9 | 执行端写内置盘：`flash boot_b`（用与现有内容逐字节相同的镜像），核对 ESP 同步；`set_active` 的守卫；整块 `flash super` **只在**开发机有完整备份、用户同意时做，同时测吞吐 | — | ✔ | ✔ | ✔ | ✔ | 可能 |
| E10 | **用户另行明确同意 + 先把 adb_keys、Wi-Fi、ksu 等备份到外接盘**：设置 → 清除所有数据 → 入口分派 → 执行端免确认清除 → fs_mgr 重建 → 开机向导；`--prompt_and_wipe_data` 应出现确认页；`fastboot -w`。"合并中拒绝"只在 QEMU 和容器里测 | — | ✔ | ✔ | — | ✔ | ✔ |
| E11 | 0.7.1 → 1.0 迁移：开发机走一遍 OTA，核对 postinstall 部署、首跑迁移、扣 tries、bless、ESP 余量；安装器 loop 夹具和 Parallels 克隆机回归安装器与 Windows 脚本；双系统机器上的同类检查见 D5–D7 | — | ✔ | ✔ | ✔ | ✔ | — |
| D1 | 开发机只读导出 Boot#### / BootOrder / BootTypeOrder / BootCurrent / `OemConfig`（并入 E2，§4.9.14） | ✔ | — | — | — | — | — |
| D2 | 开发机：造短格式与完整路径两个测试项（完整路径项用 D1 读到的原始 FilePath 加文件节点拼，**不用 efibootmgr 生成**），验证 F3 / F6 / F9 与自有启动项能否保留（与 E3 同一次上机）；结论只说明纯 Android 盘 | 写 NV | ✔ | ✔ | ✔（`EFI\gk3test`） | — | — |
| D3 | 开发机只读 `OneKeyLog.txt`（SMBIOS Type 11 读不了：没开 DMI_SYSFS，改到 D5 的 Windows 侧） | ✔ | — | — | — | — | — |
| D4 | Parallels 克隆机：Windows 更新是否改写回落文件、Windows 写 Loader 变量、快速启动 + ESP、磁盘管理与 bit 0、`-RepairBoot` / `-RemoveAndroid` 往返、BitLocker 的 PCR | 不碰设备 | — | — | — | — | — |
| D5–D7 | 群友真机：只读采集（D5，含一次 U 盘 live：`efibootmgr -v`、插拔 U 盘各冷开一次）、装双系统全流程（D6，恢复密钥在手）、更新前后对比（D7） | D5 / D7 只读 | D6 ✔ | 群友 | D6 ✔ | D6 ✔ | — |
| D8 | 主机侧 GK3 双系统状态机单测（并入 E0） | ✔ | — | — | — | — | — |

纪律：每一次需要重启的实验都要先征得用户同意，并确认有人能长按电源键；实验条目一律非默认、经 OneShot 进入；ESP 用私有挂载点（不叫 `/mnt/esp`）。

---

## 7. 需要用户决定的问题、技术未知与风险

### 7.1 需要用户决定

> **2026-10-05 用户已采纳 U1–U11 的全部建议，并要求补全双系统。** U3 因此按"纯 Android / 双系统"细化（见 U3 与 U13）；U12–U21 是补全双系统新增的决定点，U22–U25 是同日第二轮合入评审后新增的，都按惯例"用户只说有意见的，其余按建议执行"。

| # | 问题 | 建议 |
|---|---|---|
| U1 | 采纳本文路线吗：Y（修正版）作 1.0；E4 不过退到 H1，再不过退到 Z 形态；UEFI USB fastboot 放 1.x | 采纳 |
| U2 | 入口用什么语言：C（freestanding，与执行端共用 `libgk3core`，构建链与 live 相同）还是 Rust（no_std + uefi crate，边界检查更强，本机能直接出 .efi，但要多一门语言和一套工具链） | **C**：misc / BCAB 的实现从三份降到两份，单人维护成本更低；用主机侧 ASan / UBSan 和 fuzz 补足安全性 |
| U3 | loader.conf 的菜单策略（**已采纳；2026-10-05 起只适用于纯 Android**，双系统见 U13） | 纯 Android：观察期保持 15 秒；入口转正 + E3 证明不接键盘也能操作 systemd-boot 菜单之后，改为 `timeout menu-hidden`，文档写"开机按任意键 = 引导菜单"，菜单第一、二项是"Android"和"Android 引导菜单 / Fastboot"；E3 不通过就改 `timeout 3`。`menu-disabled` 加入口自己读键放到 1.x |
| U4 | `is-userspace` 报 yes 还是 no | **yes**（沿用 C′）：`fastboot reboot fastboot` 可用；带 super_empty 的 `fastboot update` 和逻辑分区操作明确 FAIL 并给提示，随版提供 flash-all 和不带 super_empty 的 zip（C′ U3） |
| U5 | 入口计数策略：Android 侧在开机完成时 bless + 分阶段激活，还是 Y 原案的"每次开机重新武装 `+3`" | **前者**：交接故障也会消耗计数；正常开机对 ESP 零写入；"每次重新武装"会让每次开机都在共用 ESP 上多一次 FAT 改名 |
| U6 | fastboot 不认证、恒为解锁 | 1.0 只披露，不加门槛（同 C′ U2） |
| U7 | bootloop 自动进菜单：阈值多少，是否 1.0 就开 | 开，阈值 5 次连续未走到开机完成（包括用户在开机过程中强制关机的情况，要写进 FAQ） |
| U8 | 0.7→1.0 这一跳的缺口：入口和新槽同时变，入口计数先用完时这一跳没有 tries 回滚 | 接受，写进发版说明，并建议用户准备 U 盘；之后的版本都由分阶段激活覆盖 |
| U9 | `androidboot.bootloader=gk3boot-<ver>` 会改变 `ro.bootloader` 的值 | 采用（Settings 的"关于"会显示入口版本），E4 时检查有没有应用依赖旧值 |
| U10 | 入口的许可证 | 与仓库其他自研代码一致；不拷贝 systemd（LGPL）代码，只照写法重写；1.x 移植 ABL 件时保留 BSD-3-Clause-Clear 声明 |
| U11 | C′ 遗留的 U3（update zip）、U5（serialno）、U6（空闲关机）照旧 | 按 C′ 的建议 |
| U12 | 双系统的默认系统：要不要让用户选"Windows 为默认"；实现是否用 `LoaderEntryDefault=auto-windows` + gk3boot 预置 OneShot + `clean_poweroff` 关机标记（§4.9.3） | **做**。安装器确认页**预选 Android**（今天的行为，依赖最少），并用大字写明"冷开机按这里选的进入、之后在哪里改；以 Windows 为主选 Windows"（第二轮，§8.2 #60）；Parts 和 Windows 脚本都能改。禁止 Android 精确 id 和 `@saved`。`on shutdown` 钩子在 E7 证明不可靠时退化为"从 Android 关机后，下次开机进一次 Android" |
| U13 | 双系统的菜单策略（U3 的双系统分支） | **固定显示菜单 `timeout 5`，不用 `menu-hidden`**；安装器看 ESP 上有没有 `bootmgfw.efi` 来决定；已装机器由 postinstall 把原值 15 改成 5，用户改过的不动 |
| U14 | 互相重启：Android 侧"重启到 Windows"走 (a) GK3 意图（多一次 POST，Android 不碰 efivarfs）还是 (b) 直接写 efivarfs；Windows 侧装"重启到 Android" | **(a)**；Windows 侧做，前提是 D4/D6 证明 Windows 能写 Loader 变量，写不进就只给"重启后在菜单里选"的提示 |
| U15 | 是否在 NVRAM 建自有的完整路径启动项（描述 `Windows Boot Manager (Android)`，指向 `\EFI\systemd\systemd-bootaa64.efi`），让 `BOOTAA64` 被换掉时 Android 仍可达，并避开 HwBcdOneKey 的路径匹配 | **1.0 不默认建**。先做 D2：通过（完整路径项能保留、固件不再重复建分区项、删文件后能自愈）就在 1.0.x 里随安装器和 `-RepairBoot` 加上；bootmgfw 的备用项不做（F9 的计数语义不明）。描述必须以 "Windows Boot Manager" 开头，保住 TouchDeviceInit（F8）。Windows 升级时会不会把这个同名前缀的项当成自己的去改写，D4/D6 一并看 |
| U16 | BitLocker 机器上改写 `BOOTAA64` 的规则 | **采纳 §4.9.7 的规则**：systemd-boot 版本冻结、只在字节不同时写；Windows 脚本写前先暂停 1 次重启；live 写前强制确认恢复密钥；Android 永不自动修。**第二轮补**：BitLocker 的提醒移到 INSTALL / U 盘制作说明的第 0 步（关安全启动**之前**），确认页文案按路径分开；"关安全启动后是否每次都要密钥"是未知，INSTALL 建议装前暂停或解密 |
| U17 | 共用 ESP 给 Windows / 固件留多少 | **扣掉下一次 OTA 的暂时空间后，仍空闲 ≥ 32 MiB**，安装器、postinstall、`gk3-esp-sync` 一致；100 MiB 的 ESP 明确拒绝；XBOOTLDR 放到 1.x |
| U18 | 快速启动 / 休眠 | **双系统一律关快速启动**（Windows 脚本所有路径）；live 检测到 Windows 卷处于休眠就拒绝写 ESP；D4 的破坏性实验决定严重程度 |
| U19 | 防误删：Android 分区设 GPT bit 0（PLATFORM_REQUIRED）、GK3LIVE 去盘符 | GK3LIVE 去盘符：**做**。bit 0：**等 D4 截图**，磁盘管理里确实不能随手删就设，否则不设。bit 1 永远不设 |
| U20 | 卸载：1.0 是否提供 Windows 脚本 `-RemoveAndroid` | **做**，按 §4.9.13 的顺序，在 Parallels 上往返测试之后才发；从 live 卸载放 1.x |
| U21 | 没有真机样本时双系统怎么发 | **标"预览"**：开发机先做 D1–D3（只说明纯 Android 盘上的固件策略），D4 走 Parallels；D5/D6 至少一台群友真机通过才去掉"预览"。"预览"期间安装器确认页**列出未验证的行为**：开机默认进谁、BitLocker 要几次密钥、Windows 更新后是否失联、Windows 能否写启动变量。不挡 1.0 发版 |
| U22 | 双系统菜单里 Windows 排在哪：保持 `auto-windows`（追加在所有条目之后，平板上要按约 7 次音量下），还是自写 `gk3-windows.conf` + `auto-entries no` 排第 2 | **自写，排第 2**（§4.9.5）。代价：标题不读 BCD、没有 `w` 热键；条目标题同时改成 ASCII。D4 核对两种条目的 PCR4 一致 |
| U23 | Windows 侧做成常驻的"伴随工具"吗：装到 `%ProgramFiles%\gaokun3`、开始菜单项、SYSTEM 计划任务、`BOOTAA64` 开机自检默认开且不可关、U 盘介质上带一份 | **做**（§4.9.15）。没有它，Windows 换掉 `BOOTAA64` 之后用户只看到"Android 没了"、手边既没工具也没提示 |
| U24 | 双系统时是否关掉 Windows 的**整个休眠**（Modern Standby 会在待机中自动转休眠，§4.9.10） | **关**，伴随工具执行前征得同意，INSTALL 写明代价（待机电量耗尽直接掉电、丢未保存的会话）；不同意就只关快速启动，并靠 U25 和文档降低风险 |
| U25 | Windows 侧预置 OneShot（Windows 里的任何重启回 Windows，包括更新的多次自动重启） | **做成伴随工具的选项，D4/D6 证实能写变量、D4 找到可靠的关机 / 重启判据之后默认开**，可提前到 1.0.x；在那之前按 §4.9.3 的表，INSTALL 建议以 Windows 为主的用户把默认设成 Windows |

### 7.2 技术未知

| # | 未知 | 如何核实 |
|---|---|---|
| T1 | **缓冲区 LoadImage 本机的 zboot PE**：SecurityDxe、HwBcdOneKey 的 `HwStartImage` 会不会拦截或干扰带厂商设备路径的缓冲区镜像 | E3（测试 PE）、E4（真内核） |
| T2 | 华为固件的 FAT 驱动对 systemd-boot 计数改名（SetInfo）是否可靠 | E5 |
| T3 | ButtonsDxe 的扫描码、在不在 ConIn 里、键盘盖在 UEFI 下能不能用、POST 热键窗口多长（INST-18） | E3 |
| T4 | UEFI 看门狗到期是否真的复位；EC 看门狗的行为 | E3（6 分钟）、E6 |
| T5 | crDroid 树的 libboot_control 是否与 AOSP 1a56e38 一致；misc 8 KiB 是否空闲；update_engine 里 SetActive 与 postinstall 的先后 | E1 |
| T6 | 执行端里经 uefisecapp 写 efivarfs 是否可用（"Other systems"） | E6 |
| T7 | 只清 userdata / metadata 开头能否让本机 fs_mgr 稳定重建 | E10 |
| T8 | 读约 29 MB 加 SHA1 在 UEFI NVMe BlockIo 上的耗时 | E3、E4 |
| T9 | 只用一份 `libgk3core` 能否同时编进 UEFI（无 libc）和静态 Linux 二进制（应当可以，需要 S2 证明） | S2 |
| T10 | `vendor.gaokun3.boot.done` 的中转方案在 enforcing 下是否只需本文列的规则 | 下一轮 SELinux |
| T11 | 双系统（2026-10-05 拆细，原问题"固件先走谁"已有静态答案：§4.9.2 F1–F5） | 见下面几行 |
| T11a | 华为策略是否真的删短格式项、建只指到分区的 `Windows Boot Manager (…)` 项（F2–F5）；自有完整路径项能否保留（U15） | D1、D2（开发机，不需要 Windows） |
| T11b | BootNext 是否在策略之后才处理、指向被删的项时是否落空（F6）；Windows 脚本默认路径是否因此失效 | D2；D6 |
| T11c | Windows 更新 / bcdboot / 重置此电脑会不会改写 `\EFI\Boot\bootaa64.efi` | D4；D7 |
| T11d | BitLocker 实际的 PCR 档案；**安全启动开→关之后，按 PCR7 封存的保护器会不会自动改按 0/2/4/11 重封，还是每次开机都要密钥**（社区报告是后者，原因不明）；固件是否真开着镜像度量；gk3boot 是否确实不影响 Windows 那次启动；`Suspend-BitLocker -RebootCount` 怎么数 | D4（vTPM）；D5 先读保护器；D6 记录连续 3 次以上开机 |
| T11e | 本机 Windows 能否经 `SetFirmwareEnvironmentVariableEx` 写 systemd 厂商 GUID 的变量 | D4 原型；D6 |
| T11f | HwBcdOneKey 的门槛（SMBIOS 11、功能位）与状态机触发条件（F10） | D3；D5（`OneKeyLog.txt`） |
| T11g | `OemConfig` 的 BootFail 计数在成功启动后是否清零（F9） | D1、D2 前后读 `OemConfig` |
| T11h | 快速启动下改共用 ESP 会不会把 FAT 写坏 | D4 |
| T11i | 两个系统切换后 RTC 是否一致；Windows 是否碰 SDAM | D6 |
| T11j | `on shutdown` 里 `gk3-misc mark-poweroff` 的时序与可靠性 | E7 |
| T11k | 未建模的选择路径：Windows 分区还在时 U 盘被优先启动、删掉后翻转（hw-inventory §8quater / §8quinquies）；双系统盘上到底是 H-A、H-B 还是 H-C | D5（U 盘 live 只读，插拔各冷开一次）；D6。开发机观察不到 |
| T15 | Windows 侧区分关机与重启的可靠判据（候选 Event 1074 的关机类型），以及更新自动重启时计划任务能否在复位前写完变量（U25） | D4 |
| T16 | 指纹：Android 侧录入 / 安全存储写入会不会破坏 Windows Hello 的模板（同一颗 FTE7001、同一个 TA） | T6 的 enroll 设计先回答；双系统机器上开放录入之前 |
| T17 | 平板姿态下进固件设置 / F12 的物理按键组合（安全启动被 BIOS 更新打开时唯一的自救路） | E3 必答 |
| T12 | 执行端的 C′ 未知照旧：initramfs 下 fbcon 能否出字、dwc3 何时就绪、UCSI 插拔会不会把 role 改成 host | E6 |
| T13 | （1.x）core0 在 UEFI 下的运行时状态、能否枚举、SuperSpeed、512 MiB 连续内存 | E4u、E3 |
| T14 | EFI_RESETREASON（A022155A-…）在本机由谁提供（决定 1.x 能否补 bootreason） | 离线反汇编 ResetRuntimeDxe |

### 7.3 风险

| # | 风险 | 缓解 |
|---|---|---|
| R1 | 入口挡在两个槽共用的路径上 | 拓扑本身就是安全网：入口计数 → gk3prev → 直连条目 → U 盘；fail-open 阶梯；观察模式先行；正常路径零 ESP 写入 |
| R2 | E4 不过（缓冲区 LoadImage 不行） | H1：文件路径加载 ESP 副本，决策层全部保留；再不行退化为 Z 形态 |
| R3 | 0.7→1.0 那一跳入口与新槽同时变（U8） | 计数回落到直连；发版说明；U 盘 |
| R4 | 自写代码量大，只有一个人懂 | `libgk3core` 单一实现 + golden 向量 + QEMU 夹具 + 本文；执行端保留以后换成正版 fastbootd 的替换点 |
| R5 | 用户在菜单里按 `d` 或手选直连条目，绕过了入口 | HAL 检测到没有 `ro.boot.gk3boot` 就通知；直连条目 title 写明"救急" |
| R6 | 迁移误取消用户刚点的恢复出厂 | GK3 留原文 + 通知，不静默 |
| R7 | 工作量超出 | 可提前交付"入口 + tries 回滚"；BCB 分派随执行端一起发 |
| R8 | 双系统下 Windows 更新或修复覆盖了回落路径，Android 完全不可达（T11c） | 伴随工具的开机自检 + 一键 `-RepairBoot`（U23）/ FAQ / U 盘；D2 **且** D5/D6 之后再定是否加 U15 的自有启动项作第二道门；HAL 动作 6 只在经 U 盘 / live 进 Android 时有用 |
| R10 | BIOS 更新把安全启动恢复成开启：固件里只有一个门，两个系统都进不去（§4.9.12） | FAQ"进固件关安全启动"；准备恢复密钥；D7 观察发生率 |
| R11 | BitLocker 恢复密钥：用户手上没有密钥时，首次安装或任何改动 `BOOTAA64` 的操作会把他锁在 Windows 外 | U16 的确认与暂停；systemd-boot 版本冻结；文案写清 |
| R12 | 共用 ESP 太满，Windows 更新（0x800f0922）或固件胶囊失败，用户会怪到 Android 头上 | U17 的 32 MiB 下限；停铺 recovery-ramdisk；绝不删 `Persisted_Capsules.bin` |
| R13 | HwBcdOneKey 在 Windows 启动失败后把开机带进华为一键恢复；F10 恢复或"从驱动器恢复"抹掉 Android | D3/D5 收集日志；INSTALL / FAQ 警告"开机看到华为一键恢复界面时，不要点恢复"；**状态是持久化的，长按电源键重启可能再次被改道**，所以 FAQ 给的逃生路径是 U 盘 live【推断】，清 BOOTSTAT 的做法待核；U15 的自有项能避开路径匹配 |
| R16 | 关掉安全启动后 BitLocker 每次开机都要密钥（T11d 未知） | INSTALL 第 0 步：装前暂停或解密；D4/D6 有结论前不承诺"只要一次" |
| R17 | Modern Standby 自动转休眠后用户进了 Android，Android 改写共用 ESP | U24 关休眠；U25 让休眠后默认回 Windows；live 检测休眠；文档 |
| R18 | Windows 换掉 `BOOTAA64` 后 Android "消失"，用户手边没有工具（从 U 盘装的、或没装伴随工具的） | U23 的开机自检默认开；U 盘介质带一份伴随工具；FAQ 手工三步；U 盘 live 的"修复启动" |
| R14 | Windows 休眠或快速启动时，Android 写了共用 ESP，导致 FAT 损坏 | U18；D4 定级 |
| R15 | 卸载顺序错误（先删分区、后还原引导）导致重启循环，撞上 BootFail 的"3 次关机" | U20 的固定顺序；FAQ 只给脚本，不给手工步骤 |
| R9 | bootloop 计数误触发（用户在开机中强制关机） | 阈值 5；菜单默认项是"Boot Android"；FAQ 说明 |

---

## 8. 与上一轮 C′ 设计的关系，以及采纳评审修正的记录

### 8.1 与 C′ 的关系

| C′ 的内容 | 本文中的地位 |
|---|---|
| §3.3"1.0 做 C′，1.0 之后加轻量分派器" | **作废**。入口（分派器的超集，还负责交接）提到 1.0，成为主角；C′ 降为执行端 |
| §4.2.1 `gk3-fastbootd`（FunctionFS、协议核心、GPT 白名单、sparse、LP 只读、state 解析） | **沿用**；misc / BCAB 部分改用 `libgk3core`；efivarfs 写 OneShot 只留给"Other systems" |
| §4.2.2 fastboot initramfs | **沿用**；改放在 `EFI/gk3boot/<ver>/fastboot.img`，由入口引导 |
| §4.2.3 独立内核副本、`gaokun3-fastboot.conf` + OneShot 进入 | **作废**：内核用 `boot_x` 里的同一个；条目改为 `gk3boot-tools.conf`（efi 条目） |
| §4.2.4 `gk3-bootintent`（关机桥 + `--boot` 重新路由）、§4.9 的 efivarfs sepolicy | **作废**，R1 / R2 随之消失 |
| §4.2.5 `gk3-esp-sync` | **沿用** |
| §4.2.6 misc 8 KiB 的 `GK3I` 意图记录 | **位置沿用、内容改了**：变成 GK3 记录（§4.5），写者改为入口、执行端和 HAL |
| §4.3 进入路径 | 由 §4.3.4 / §4.3.5 取代 |
| §4.4 分区映射 | **沿用**；目标盘由 `gk3.disk` 给出，仍要校验唯一性 |
| §4.5 命令、§4.6 清除语义与 VAB 守卫、§4.7 USB 与电源、§4.8 界面、§4.10 攻击面 | **沿用**（改动见 §4.4） |
| K1 / K2 | K1 由入口读 misc 解决；**K2 作废**：现在入口条目就是 default，靠命名兼容 HAL |
| K3、K4–K10 | 沿用；K4 弱化（入口以分区为准，ESP 副本只用于回落） |
| U7（独立内核） | 作废 |
| R8（fastboot 内核落后一个版本） | 消失 |

### 8.2 采纳评审修正的记录

| # | 被纠正的论断 | 出处 | 纠正 | 依据 |
|---|---|---|---|---|
| 1 | "从内存 LoadImage 加载 zboot 已在本机验证（linux.c:80-144）" | X、契约摸底 | 本机 type1 条目按文件设备路径加载；`linux_exec` 只服务 UKI stub ⇒ 缓冲区加载是第一道上机门槛（E4），退路 H1 | `boot.c:2563-2576`；`stub.c:1275`（三份评审） |
| 2 | 入口交棒前就 bless 自己（X）/ 每次开机重新武装 `+3`（Y） | X、Y | 两种做法都让交接故障不消耗计数，可能陷入 panic 循环 ⇒ 改为 Android 在 `sys.boot_completed` 时 bless，并做分阶段激活 | 风险、体验、成本评审 |
| 3 | "markBootSuccessful / HAL 每次开机都重写 loader.conf" | C′ §2.1、Y safety、Z 决策看门狗 | 只在当前槽未标成功时才调用 ⇒ "开机完成"信号挂在 `sys.boot_completed` 上 | `update_verifier.cpp:331-381`；`init.rc:1137-1140` |
| 4 | UEFI 里先"尽力 EraseBlock"再清数据 | X | NVMe 分区上没有 EraseBlock ⇒ 清数据只在 Linux 执行端做（BLKDISCARD + 写零） | 风险评审字节扫描 |
| 5 | 固件"只有 TrEE、没有 TCG2"，度量情况不明 | Z、fw 摸底 | 607f766c 同时是 TrEE 和 TCG2，FV 有 MeasureBootDxe ⇒ 度量多半开着；本设计让入口只在 Android 启动时加载，不进 Windows 的度量链（T11 待核） | 风险评审 |
| 6 | "Boot menu"先写 `LoaderConfigTimeoutOneShot` 再返回 SUCCESS | X | 返回 SUCCESS 本身就会停在菜单上；那个变量会留到下一次开机，再强制弹一次菜单 ⇒ 不写 | `boot.c:1617-1630`、`:2975-2976`（体验、成本评审） |
| 7 | "开机按住音量下进 fastboot" | X、Y | systemd-boot 的菜单 / 100 ms 读键会先吃掉按键 ⇒ 1.0 不做，改为菜单项 + BCB + 执行端菜单 | `boot.c` 约 `:881`、`:908`、`:2925-2934`（体验评审） |
| 8 | `is-userspace=no`（X）/ `yes` 可以不管 update（Y） | X、Y | no：`fastboot reboot fastboot` 报错；yes：带 super_empty 的 update 会走逻辑分区 ⇒ 选 yes，并明确 FAIL、给提示 | `fastboot.cpp:1575-1591`、`:1702-1711`、`:2122-2142` |
| 9 | Z 的决策看门狗、`Gk3PolicyArm` 自禁用 | Z | 看门狗只在 markBootSuccessful 时清零，正常使用中会跳闸；自禁用不粘滞；每次开机写 NV 变量 ⇒ Z 不作终点；本文的 bootloop 计数放在 misc，由开机完成时清零 | 风险评审 |
| 10 | 工作量 X 7–9 周、Y 6–8 周 | X、Y | 执行端按 C′ 原估 3–5 周算 ⇒ Y 约 8–10 周，X 10–12 周以上 | 成本评审 |
| 11 | set_active 写 7/7/6 | GBL | 照 libboot_control 写 15/6/14，与 HAL 一致 | `libboot_control.cpp:282-314`；`gbl slots/android.rs` |
| 12 | `bootloader_control` 每槽 1 字节；"本地没有布局源码" | 上一轮、C′ §2.3 | 每槽 u16；按实机 dump 复算 CRC 得 67ddc320，布局确认（crDroid 树一致性待 E1） | `boot_control_definition.h:59-107`；契约摸底 |
| 13 | GBL 作主干（oss 摸底） | oss | 不认 zboot、只写 bootconfig、直跳不填 /memory、出错 cold_reset、只能在 x86 上用 Bazel 构建 ⇒ 只作测试向量 | `load.rs:629-667`；`mod.rs:220`；`ops.rs:395-396`；`sc8280xp.dtsi:389-393` |
| 14 | ABL 整体作启动器 | — | A/B 存在 GPT 属性位里，会改写共用 GPT；要 msm-id；直跳；缺 4 个协议 ⇒ 只在 1.x 移植 USB 件 | `PartitionTableUpdate.h:138-148`；oss 摸底 |
| 15 | 执行端以 OneShot + 关机桥进入、用独立内核 | C′ | 改为入口读 BCB 后直接引导、用同一个内核 | 本文 §4.4.1 |
| 16 | 安装器停用逻辑"不受影响"（Z） / 未提及 | Z | `*-android-[ab].conf` 的匹配会误伤 gk3boot 条目 ⇒ 收紧为 `^[0-9a-f]{32}-android-[ab]\.conf$` | `installer-lib.sh:879-887`（成本评审） |
| 17 | 用 BCAB 的 `recovery_tries_remaining` 当分派计数 | Z | 改放 GK3，保证 BCAB 只按 libboot_control 语义被写 | 本文 §4.3.4 |
| 18 | boot.c 行号 2969-2971 / 2973-2974 | Y | 实际是 `:2971-2973`（return err）、`:2975-2976`（SUCCESS 停在菜单） | 风险、成本评审 |
| 19 | Z 用易失 OneShot | Z | systemd-boot 删除时带 NON_VOLATILE 属性，属性不匹配；本设计正常路径不写 OneShot，只在 fail-open 和"Other systems"时写 NV OneShot | `boot.c:1638-1640` |
| 20 | HAL 直接读 `sys.boot_completed` | 本文起草时 | `boot_status_prop` 是 `system_restricted_prop`，vendor 直接读未确认 ⇒ 用 vendor_init 中转成 vendor 属性 | `property_contexts:952`；`public/property.te:60`；`private/vendor_init.te:316` |
| 21 | "本机没有 Boot####"；"双系统机器先走 WBM 还是回落路径未知"，以及第一路摸底的 blocker"双系统用户很可能默认直进 Windows，至少在一次功能更新之后" | 本文 §2.1、§4.9 旧稿；双系统第一路摸底 | 华为策略每次开机删掉路径对不上的启动项（短格式的 WBM 项属于这一类），再建一个只指到分区的 `Windows Boot Manager (…)` 项，它启动的是回落路径 ⇒ 两个系统都从 systemd-boot 进；"Windows 更新把 WBM 挪到第一位"在本机没有持续效果（推断，D1/D2 核实） | HwUniformPolicyDxeDriver 0xbde0、0xbfdc、0xcd84、0xd05c；QcomBds 0x23f3c（本轮复核反汇编） |
| 22 | "QcomBds 里没有 Windows 字样，WBM 的 Boot#### 只能是 Windows 自己建的" | 双系统第三路摸底 | 字串和建项逻辑在 HwUniformPolicyDxeDriver 里，不在 QcomBds（L"Windows Boot Manager" @0x1736c，EnumerateOptions 0xd05c） | 同上 |
| 23 | 固件只在描述"正好是" "Windows Boot Manager" 时调 TouchDeviceInit | 双系统第一路摸底 | 是前缀比较（StrnCmp 20 个字符），`Windows Boot Manager (…)` 也算 | QcomBds 0x8864–0x88ac（本轮复核） |
| 24 | "经 systemd-boot 链式进的 Windows 少了 TouchDeviceInit，触摸可能不灵" | 双系统第一路摸底 | 唯一的门就是 `Windows Boot Manager (…)` 那一项，systemd-boot 启动之前就已经做过这一步 ⇒ 不成立（推断，D6 顺带确认） | F4、F5、F8 |
| 25 | 新增 `gk3.action=boot-windows`：gk3boot 写 BootNext=WBM 再复位，让 Windows 由固件直接启动、不进我们的链 | 双系统第一路摸底 | 本机唯一的 WBM 项启动的就是 systemd-boot 自己，BootNext 会绕回菜单；而且 F6 下 BootNext 可能落空 ⇒ 否决，改用 `OneShot=auto-windows`（§4.9.4） | F5、F6 |
| 26 | 退而求其次用 systemd-boot 的 `reboot-for-bitlocker` | 双系统第一路摸底 | 它只认描述**恰好等于** "Windows Boot Manager" 的项（`boot.c:2109`），本机没有；即使匹配上也会原地兜圈 ⇒ 必须保持关闭 | `boot.c:2081-2128` |
| 27 | "经 systemd-boot 菜单进 Windows 与 F12 直进 Windows 的 PCR4 不同，交替使用会反复要恢复密钥" | 双系统第一、三路摸底 | F12 列的 `Windows Boot Manager (…)` 启动的也是 systemd-boot ⇒ 只有一条链，只在第一次装上和 systemd-boot 字节变化时要密钥（推断） | F5、F11 |
| 28 | "停铺 recovery-ramdisk 腾出约 30 MB，ESP 净值为正" | 本文 §4.9 旧稿 | 只对 OTA 过的 0.7.x 机器成立；新装机器上本来就没有 recovery-ramdisk，加入口是净 −5 到 −10 MiB ⇒ 按两种情况分别算（§4.9.8），另给 Windows 留 32 MiB | 第三路摸底；`installer-lib.sh:655-664` |
| 29 | 双系统时安装器写 `auto-entries no` 并另写 `gk3boot-windows.conf`；或者建一个描述不是 "Windows Boot Manager" 的 Boot#### | 双系统第一路摸底 | 不需要另写 Windows 条目，auto-windows 保持即可；自有 Boot#### 的描述**必须**以 "Windows Boot Manager" 开头，否则会丢掉 TouchDeviceInit（今天 Android 也依赖它），并且要等 D2（U15） | F4、F8 |
| 30 | `installer-lib.sh:893-894`、`hw-inventory.md:545`："efi=noruntime ⇒ 不能用 EFI 变量" | 安装器注释 | 变量经 uefisecapp 可读写（#42 实测在 Android 里写 OneShot），只是过去选择不用 ⇒ 安装器改注释，并用 efibootmgr 做 `gk3_esp_info` | `fastboot-design.md:71`；`v0.7.1-alpha-config.txt` 的 `QCOM_QSEECOM_UEFISECAPP=y` |
| 31 | 用 `@saved`，或者在菜单里按 `d` 设 Android 为默认，就能实现"默认系统可选" | 双系统第三路摸底的候选 | `config_find_entry` 不看剩余次数，精确 id 会绕过入口的计数回落 ⇒ 禁止 Android 精确 id 和 `@saved`，gk3boot 遇到就删；Windows 为默认用 `auto-windows`（不带计数） | `boot.c:1771-1812` |

**双系统补全稿的自审纠正**（2026-10-05，写完后先按"风险 / 事实"、再按"用户体验"各审一轮，关键论断亲自核对。F2、F4、F5、F6、F8 重新反汇编；systemd-boot 的 `config_find_entry`、`reboot-for-bitlocker`、auto-windows 读源码；微软文档逐条打开核对原文）：

| # | 初稿的问题 | 视角 | 纠正 | 依据 |
|---|---|---|---|---|
| 32 | 冷开机转去 Windows 的条件写成"检查四件事"却只列了三件；转去 Windows 和"连续未完成计数 +1"、扣 tries、预置 OneShot 谁先谁后没定义，可能把计数推到阈值，或者形成"预置 → 转走 → 再预置"的循环 | 风险 | 改成 a–e 的判定顺序：转去 Windows 这一路不加计数、不扣 tries、不预置；**先清标记再复位**，最坏多一次复位，不会循环 | §4.9.3 |
| 33 | "Android 不挂 efivarfs"与"`gk3-misc mark-poweroff` 要判断默认是不是 Windows"自相矛盾（默认值在 EFI 变量里） | 事实 | gk3boot 把默认系统缓存进 GK3 记录（只在变化时写），Android 侧只读 misc | §4.5、§4.9.3 |
| 34 | Windows 已被删掉、`LoaderEntryDefault` 还留着 `auto-windows` 时，gk3boot 仍会转去 Windows，白白复位一次 | 风险 | "默认是 Windows"要求 ESP 上确实有 bootmgfw.efi | §4.9.3 第 a、d 步 |
| 35 | 执行端新增的类型检查写成"必须是 `0FC63DAF`"：开发机这类手工分区的机器，Android 分区的类型码没核对过，可能一上来就拒绝一切写入 | 风险 | 改成黑名单（basic data / MSR / WinRE / ESP 一律拒绝），E2 先用 `sgdisk -i` 核对开发机 | §4.9.11 |
| 36 | 默认"Windows 脚本暂停 BitLocker 2 次重启就覆盖了安装过程"，没交代次数怎么数；也没提从 U 盘直接装的用户根本没有暂停 | 事实 | 写明"按 Windows 自己的启动递减"是推断，D4 核实，文案一律写"可能要一次恢复密钥"；从 U 盘装、BitLocker 开着的，第一次进 Windows 几乎一定要密钥 | §4.9.7 |
| 37 | "平台复位后 PCR 清零"当作事实写 | 事实 | 标为推断（高通 fTPM 在 TZ 里） | §4.9.7 |
| 38 | D2 写"用 efibootmgr 建完整路径项"：efibootmgr 默认写的就是短格式，有没有完整路径的选项没核实 | 事实 | (b) 用 D1 读到的 F4 那一项的 FilePath 加文件节点拼出，用小脚本直接写变量 | §4.9.14 |
| 39 | §4.9.11 把"Android 分区设 bit 0"写成已定，而 U19 还要等 D4 | 事实 | 改为"候选" | §4.9.11、U19 |
| 40 | 漏了：F4 会给**所有**内置 FAT 分区建项，双系统机器上的 GK3LIVE 也会有一项，它找不到 `BOOTAA64`，被尝试时会计 F9 的失败次数 | 风险 | D1 同时观察；只在 ESP 那一项失败时才会轮到它们 | F4、F9；§4.9.14 D1 |
| 41 | `-RemoveAndroid` 默认整删 `loader/`、`EFI/systemd/` 并还原 `BOOTAA64`：共用 ESP 的另一个 Linux 会被一起删掉 | 风险 | 有非我们的条目时，只删我们的条目，回落路径交给用户决定 | §4.9.13 第 2 步 |
| 42 | "重启到 Android"每次都弹 UAC；转去 Windows 时出现两次 Logo 没有说明；纯平板（只有音量键）用户怎么切系统没交代；`next=windows` 被 OTA 待办作废后用户不知道发生了什么 | 体验 | 改为 SYSTEM 计划任务 + 快捷方式；INSTALL 说明两次 Logo；写明 E3 之前平板只能靠两边的"重启到另一系统"和"默认系统"，并建议以 Windows 为主的平板用户选"Windows 为默认"；作废时 HAL 通知"已先完成系统更新，请再选一次" | §4.9.3、§4.9.4 |
| 43 | 第一路摸底建议 FAQ 写"经菜单进 Windows 触摸不灵时改用 F12 进"，把 F12 当成后路 | 体验 | F12 里的 `Windows Boot Manager (…)` 打开的就是我们的菜单，不能当后路；文档改为"要绕过只能插 U 盘" | F5、F11；§4.9.5 |
| 44 | 一键恢复的风险只写了"可能被带进去"，没告诉用户看到之后怎么办 | 体验 | R13 加上"不要点恢复，直接长按电源键重启" | §7.3 R13 |

**双系统第二轮修正**（2026-10-05，合入两份评审：风险评审、用户体验评审。第一轮的结构、U12–U21、D1–D8 与 D1 实机结果保持不变，只做修正和补充）：

| # | 第一轮的问题 | 评审 | 纠正 | 依据 |
|---|---|---|---|---|
| 45 | "固件行为可以在纯 Android 的开发机上验证，不需要 Windows"；#21 据此撤销第一路摸底的 blocker | 风险（必改） | 实测里盘上有没有 Windows 分区改变过启动选择（§8quater 插着 U 盘时 U 盘优先、§8quinquies 删分区后翻转），F1–F7 解释不了 ⇒ 开发机结论只说明纯 Android 盘；H-A / H-B / H-C 由 D5 的 U 盘只读部分和 D6 定；#21 的"撤销"降为待核；U15、`-UseFallbackPath` 改默认都等 D5/D6 | `docs/hw-inventory.md` §8quater、§8quinquies；§4.9.2 末尾、T11k |
| 46 | — （**不同意**的两条）| 风险（应改） | 评审建议：入口被绕过时由 HAL 补写预置 OneShot；setActive 时同步改预置里的槽字母。**不采纳**：①第一轮已选 U14 (a)，Android 不碰 efivarfs，补写要加回 efivarfs 类型、genfscon 和写权限；直连路径本来就不扣 tries、没有回滚链，这次重启落进 Windows 不会让回滚更断，且 HAL 已发 bypassed 通知。②预置先命中的是 `gk3boot-android-<旧字母>`，gk3boot 按 BCAB 选槽，照样启动新槽；字母只在入口计数全用完时起作用，落到旧槽（已知可用）正是想要的。评审的第三条"关机时无条件删 OneShot 会误删别人的"在第一轮的设计里不适用（关机只写 misc 的 `clean_poweroff`，不删变量） | §4.9.3；`boot.c:1637-1640`、`:1710-1714` |
| 47 | "只在第一次装上、以及 systemd-boot 字节变化时要恢复密钥"；"之后重新封存时 PCR7 不可用，落到 0/2/4/11" | 风险（必改） | 没有出处；唯一的同 SoC 社区证据说"每次"都要，原因不明 ⇒ 改为【未知】，T11d 加子项；INSTALL 只写"可能每次都要，建议装前暂停或解密" | https://aarch64-laptops.github.io/laptops/thinkpad_x13s/debian_guide.html ；https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/configure |
| 48 | U 盘路径的 BitLocker 确认放在安装器确认页 | 风险、体验（必改） | 关安全启动本身就会触发，用户可能先回一趟 Windows ⇒ 提醒移到 INSTALL / U 盘制作说明的第 0 步（关安全启动之前），确认页文案按路径分开，保留强制确认作第二道 | `gaokun3-setup.ps1:322-326`；§4.9.7 规则 6 |
| 49 | D2 / U15 的完整路径项"用 efibootmgr 造"（§6 表）；D3 读 `/sys/firmware/dmi/entries/11-0/raw` | 风险（必改 / 应改） | efibootmgr 与 libefivar 从 sysfs 推路径，本机走 DT，推不出与固件 `DevicePathFromHandle` 逐字节相同的路径 ⇒ 用 D1 的原始 FilePath 拼，或由 UEFI 侧生成；本机没开 `CONFIG_DMI_SYSFS` ⇒ SMBIOS 11 改到 Windows 侧读 | HwUniformPolicy 0x2e24、0xcd84；`scripts/live/pkgs-common.txt:59`；`v0.7.1-alpha-config.txt:1814` |
| 50 | 入口按"1 版 / 2 版"算空间；`Persisted_Capsules.bin` 归给 RecoveryDxe；recovery-ramdisk"只有 0.7 的 OTA 才铺" | 风险（应改） | 分阶段激活期间是 3 版（≤15 MiB）；引用它的是 CapsuleRuntimeDxe（推断为预分配的胶囊存储，删了要重新腾出约 70 MB）；自编版本安装器也会铺 | §4.11；CapsuleRuntimeDxe 0xe306、0xcb80、0xd872；`installer-lib.sh:490`、`:661`、`:933-935` |
| 51 | 不设 GPT bit 1 的理由是"gk3boot 全靠固件给分区建 BlockIo"；GK3LIVE 去盘符用"bit 63 或 `Remove-PartitionAccessPath`" | 风险（小） | 与 §4.2 第 1 步矛盾（gk3boot 用整盘 BlockIo），理由改为"没验证、没收益"；NO_DRIVE_LETTER 去不掉已分配的盘符、HIDDEN 会让脚本找不到卷 ⇒ 只用 `Remove-PartitionAccessPath` | https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-partition_information_gpt ；`gaokun3-setup.ps1:252`、`:446` |
| 52 | `-RemoveAndroid` 先还原 `.before-gaokun3`；"扩回 D:" | 风险、体验（应改） | 装机那天的拷贝可能是旧版，安全启动重开且 DBX 吊销后起不来 ⇒ 从当前的 `bootmgfw.efi` 拷；GK3LIVE 紧贴 D:，不删就扩不回 ⇒ 一并删、扩之前断言相邻；零长度删除变量是文档写明的语义 | CVE-2023-24932 KB；`gaokun3-setup.ps1:247-250`；SetFirmwareEnvironmentVariableEx 文档 |
| 53 | `LoaderEntryDefault` 只在匹配 `*-android-*` 时删 | 风险、体验（应改） | 在 installer、救援、直连、上一版入口上按 `d` 一样会钉住开机，而那时 gk3boot 不运行 ⇒ 合法值只留"不存在"和 Windows 条目 id；HAL 通知里写清"再按一次 `d`"，live 和伴随工具也规范化；写明兜不住的情况 | `boot.c:967-981`、`:1127`、`:1771-1784` |
| 54 | 安装器不写 `auto-entries no`、不另写 Windows 条目（#29） | 体验（应改） | `auto-windows` 追加在所有条目之后，平板上要按约 7 次音量下 ⇒ U22：自写 `gk3-windows.conf` 排第 2，条目标题一律 ASCII。#29 关于"自有 Boot#### 的描述必须以 Windows Boot Manager 开头"那半条不变 | `boot.c:2814-2819`、`:1691`、`:2147` |
| 55 | Windows 侧能力全挂在一个没有安装位置的 .ps1 上；HAL 动作 6 被当成修复路径之一 | 体验（必改） | `BOOTAA64` 被换掉时 Android 多半进不来，HAL 运行不到 ⇒ U23 常驻伴随工具、开机自检默认开；HAL 那条只在经 U 盘 / live 进 Android 时有用 | `scripts/windows/README.md`；§4.9.6 |
| 56 | 只关快速启动，提醒"别用休眠" | 体验（必改） | Modern Standby 会在待机中自动转入休眠 ⇒ U24 是否关整个休眠；live 复用 `gk3__ntfs_hibernated` | Adaptive hibernate / Hibernate idle timeout 文档；`installer-lib.sh:1170`、`:1203-1206` |
| 57 | 第一轮建议"Windows 里的重启回 Windows"靠"Windows 为默认"，Windows 侧预置推到 1.x | 体验（必改，二选一） | 第一轮已选"收窄语义"那一支（G-E7 只承诺 Android 发起的重启回 Android），保留；另加 U25：Windows 侧预置做成伴随工具的选项，验证后默认开，可提前到 1.0.x。它同时覆盖更新的多次重启，不必另判"更新挂起" | §4.9.3 的表；§4.9.15 |
| 58 | 一键恢复时"直接长按电源键重启" | 体验（应改） | 状态持久化，重启可能再次被改道 ⇒ 逃生路径写 U 盘 live（推断），清 BOOTSTAT 的做法待核 | HwBcdOneKey 0x1968、0x2394 |
| 59 | 进固件设置的按键没交代；电源菜单入口没设计；时钟只比对一次；蓝牙"各存各的"；没有反向迁移、官方 ISO 重装、文件交换、指纹、待机切换、面向用户的整合说明；2026 证书轮换没提 | 体验（应改 / 遗漏） | E3 必答 T17；电源菜单的扩展点 E1 grep；D6 加时钟交叉实验；蓝牙按"外设只记一份密钥"重写；§4.9.13、§4.9.16、§4.9.17 补齐；§4.9.6 加证书轮换一行（文档没说安全启动关闭的机器会怎样 ⇒ 未知） | §4.9.6、§4.9.12、§4.9.13、§4.9.16、§4.9.17 |
| 60 | — （**不同意**的一条）| 体验（小） | 评审指出 U12"预选 Android"会让以 Windows 为主的用户顺手点下一步，建议改成不预选。**保留预选**，但确认页用大字写明"重启时按这里选的进入哪个系统、之后在哪里改"：预选 Android 是"依赖最少"的那一项（不写任何变量），而且第一次开机本来就要进 Android 走开机向导 | §4.9.3；U12 |

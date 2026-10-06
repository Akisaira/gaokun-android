# Stage 7 设计：LiveCD 图形安装器 + 轻量救援系统

> ⚠️ **C 版源码（`live/installer/`、`scripts/live/gen-strings.py`）2026-09-26 已删**（改 Flutter，M0 验收过后）。
> 文中 `gk3-installer.c:行号` 一类的引用指最后一版：`git show 445e978:live/installer/<文件>`。 **本文现状：部分有效** —— "rescue 与 live 一套镜像"、救援与 Android 共用内核与 dtb（§2.3）、ESP 现实约束与 M0 实测仍是现行 `scripts/live/` 的依据；C + cairo 界面、Alpine 底座、下面那段"状态"已被 [`stage7-flutter-debian.md`](stage7-flutter-debian.md) 取代，冲突时以那份为准（索引见 [`docs/README.md`](README.md)）。

> 状态：**M0 上机完成 —— 完整启动跑通，ssh 可达、WiFi 自动连上、分区工具齐全。**
> ⏸ 2026-08-23 起用户决定暂缓（TODO B4），⬜ 欠 `gk3_apply`（真写盘）与 DRM 后端。
> 产物实测大小：`gaokun3-rescue.squashfs` **55 MiB** ／ `initramfs.img` **2.7 MiB**
> ／ 可启动 U 盘镜像约 **152 MiB** —— 它要替掉的是 24.6 GiB 的 Ubuntu 分区。
>
> ⚠️★ **本段此前写着"完整启动还没做、initramfs 648 KiB"，已过时**
> （2026-09-10 对账更正）。initramfs 从 648 KiB 涨到 2.7 MiB 是**故意的**：
> 真凶是**内建 ath11k 在 initramfs 阶段就 probe（t=1.19s，远早于 switch_root）
> 却拿不到固件**，所以固件必须打进 initramfs。
> 构建脚本与踩到的六个坑见 [`scripts/live/README.md`](../scripts/live/README.md)。
> 下面凡是标"实测"的都有出处，其余是设计选择。
> 目标由用户在 2026-08-23 定下：①用更轻的系统替掉 24.6 GiB 的 Ubuntu 救援；
> ②给 LiveCD 做图形化安装流程；③支持"机器上已有别的系统"时装 Android；
> ④让用户选装不装救援系统。

## 0. 一句话结论：这是**一件事**，不是两件

救援系统和 LiveCD 安装器需要的东西 95% 重合（分区工具、文件系统工具、
网络、ssh、写镜像）。差别只有一个 GUI。所以做**一套镜像、两个 profile**：

| profile | 内容 | 落在哪 | 大小目标 |
|---|---|---|---|
| `rescue` | 无 GUI，ssh + 分区/文件系统工具 | 内置盘 | ≤ 120 MiB |
| `live` | `rescue` + 图形安装器 | U 盘 | ≤ 400 MiB |

## 1. 现实约束（实测，2026-08-23）

| 事实 | 值 | 出处 |
|---|---|---|
| ESP | 300 MiB，**已用 268 MiB，只剩 28 MiB** | `df /mnt/esp` |
| ESP 里最大的一坨 | `Persisted_Capsules.bin` **70 MiB** | `du /mnt/esp/*` |
| ESP 里第二坨 | `EFI/` 31 MiB（含**已抹除的 Windows** 整棵树） | 同上 |
| 每个 Android 槽在 ESP 上 | Image 14 + ramdisk 13 + recovery-ramdisk 15 + dtb 0.17 ≈ 42 MiB | `ls` |
| 其中 `recovery-ramdisk.img` | **没有任何启动项引用它**，×2 = 30 MiB 死重 | grep entries |
| 磁盘 | 476.9 GiB，**约 64 GiB 未分配** | `/proc/partitions` 求和 |
| 现役救援 Ubuntu | p3，24.6 GiB | 同上 |
| 内存 | 15.7 GiB | 前期 |
| 固件 | UEFI 2.70，Qualcomm 8483.513；**chainload 实测可用** | [#73](stage4-findings.md#73) |

★ **ESP 只剩 28 MiB 是这份设计里最硬的约束**，它直接否决了"把救援 rootfs 也塞进 ESP"。

## 2. 结构决定

### 2.1 救援系统不再是一个分区

现在：24.6 GiB 的 ext4 装了一整套 Ubuntu。
改成：**内核 + initramfs + 一个 squashfs**。

* ESP 上放 `gaokun3/rescue/{vmlinuz.efi, initramfs.img, gaokun3.dtb}` ≈ 25–30 MiB
* squashfs 放**自己那个 1 GiB 分区**（partlabel `gaokun3rescue`），不放 ESP
* initramfs 的活：按 partlabel 找 squashfs → mount → 上面盖一层 tmpfs
  （overlay）→ `switch_root`。找不到就落回一个能 ssh 的 initramfs shell。

为什么 squashfs 不放 ESP：ESP 是 FAT、没有权限位、而且**别人机器上的 ESP
经常是 Windows 建的 100 MiB**。独立分区让"双系统安装"这条路不受对方 ESP 大小摆布。

⚠️ **U 盘上例外**：LiveCD 只有一个 FAT 分区，squashfs 就放那儿，
initramfs 先按 partlabel 找、找不到再按**文件名**扫所有可读分区。
两种介质走同一份 initramfs。

### 2.2 底座选 Alpine（aarch64）

* musl + apk，base 8 MiB 量级；Debian minbase 光 rootfs 就 120 MiB
* 我们要的东西 apk 里都有：`sgdisk` `parted` `e2fsprogs` `dosfstools`
  `f2fs-tools` `ntfs-3g-progs` `nvme-cli` `zstd` `openssh` `chrony`
* ⚠️ 在 x86 构建机上做 aarch64 rootfs 需要 `qemu-user-static` + binfmt
  （apk 的 post-install 脚本要在目标架构上跑）。构建机上装得了。
  另一条路是**在设备的救援 Ubuntu 上原生构建**，不需要 qemu —— 但那要占着机器。

### 2.3 内核：复用我们自己的

不要另找内核。用**本仓这一棵**（v7.2-rc2 + `patches/`），因为：
面板、触摸（gpio174 补丁）、EC、ath11k、NVMe 全靠它。
差别只在 config：救援内核**不需要** Android 那一套（SELinux/DM/binder…），
但**必须**有 `SQUASHFS`、`OVERLAY_FS`、`NTFS3_FS`（缩 Windows 分区要读）、
`USB_STORAGE`、`BLK_DEV_INITRD`、`DRM` + 面板 + `HID`。
⚠️ 现在的 Android config 里 `USB_STORAGE` 是什么状态未查 —— 装机要从 U 盘读文件，
这条必须先确认。

### 2.4 固件：不需要任何华为专有 blob

救援/安装只需要 ath11k（`qca/*`）与 GPU（`a660_*`）—— **两者都在
linux-firmware 里，可再分发**。ADSP/CDSP/SLPI 那三个 `.mbn` 是音频与传感器用的，
救援用不上。所以 **LiveCD 可以公开发布**，不触碰本仓"专有固件不入库"的红线。

## 3. GUI：直接画 KMS，不上合成器

选型（决定 = **A**）：

| 方案 | 体积 | 工作量 | 风险 |
|---|---|---|---|
| **A. DRM/KMS dumb buffer + cairo/pango + libinput** | +30 MiB | 中（要自己写按钮/列表/进度条） | 低：没有合成器可坏，GPU 栈我们最熟 |
| B. weston + GTK4 应用 | +300 MiB | 小 | 多一层 Wayland/seat/udev 要调；体积翻 3 倍 |
| C. TUI（dialog/fbterm） | +2 MiB | 小 | ❌ **不合要求**：用户要的是图形化，而平板可能根本没接键盘 |

A 的理由不是"更酷"，是**这台机器上合成器能出的问题比我们要画的界面还多**，
而界面本身只有 6 屏、全是按钮。

* 文字用 pango + 一个中文字体（`wqy-microhei` 约 5 MiB；Noto CJK 全量 20 MiB 太大）
* **必须同时支持键盘操作**（Tab/方向键/回车）：万一 himax 触摸没起来，
  安装器不能变砖 —— 键盘和触控板走 EC，是另一条独立通路
* 双语（中/英），默认跟随第一屏的选择

### 界面流程

1. 语言
2. 目标磁盘（列出型号/容量/现有分区与识别出的系统）
3. 安装方式：**清空整盘** / **保留现有系统，装在空闲空间**
4. 选项：装不装救援系统（默认**装**）；救援系统的 ssh 公钥/密码
5. **确认页**：把将要执行的分区操作逐条列出来（"删除 p3"、"把 p2 从 300G 缩到 200G"…）
   —— 这一屏是唯一能防止误删的东西，必须显示**将被销毁的数据**
6. 进度 → 完成/重启

## 4. 双系统安装

需要三样现在没有的东西：

1. **识别现有系统**：ESP 里的 `EFI/Microsoft` → Windows；
   ext4 里的 `/etc/os-release` → Linux 发行版名。
2. **腾空间**：优先用未分配空间；不够就缩分区。
   * NTFS → `ntfsresize`。⚠️ **必须先查 dirty bit**（`ntfsfix -n` / 引导扇区标志）：
     Windows 快速启动/休眠会留下脏卷，缩了就是数据损坏。脏就**拒绝**并告诉用户
     去 Windows 里关快速启动 + 完整关机。
   * ext4 → 先 `e2fsck -f` 再 `resize2fs`。
3. **共用 ESP**：不新建第二个 ESP（UEFI 一盘一个）。需要在对方 ESP 里腾出
   **≥ 90 MiB**（两个槽的 Image+ramdisk+dtb，不含 recovery-ramdisk）。
   ⚠️ 本机就是活样本：300 MiB 的 ESP 已经 91% 满。空间不够时安装器要**明说差多少**，
   而不是写一半失败。

**最小可用空间**（安装器要硬校验）：
super 12 GiB + boot_a/b 128 MiB + metadata 32 MiB + misc 4 MiB
+ userdata 至少 16 GiB + ESP 90 MiB ≈ **29 GiB**；救援再加 1 GiB。建议 ≥ 64 GiB。

## 5. 迁移路径（本机怎么从 Ubuntu 换过去）

**不要先删 Ubuntu。** 顺序：

1. 造出 `rescue` profile，写进 ESP + 新建 1 GiB `gaokun3rescue` 分区（用未分配的 64 GiB）
2. 加一个**并列的**启动项，Ubuntu 那个一个字不动
3. 从新救援系统里 ssh 进去，跑一遍真实活儿（`sgdisk -p`、挂 super、改 ESP）
4. 只有第 3 步过了，才删 p3，把 24.6 GiB 还给未分配
5. `docs/INSTALL.md` 与 `scripts/install-gaokun3.sh` 同步改

## 6. 待查（动手前必须先有答案）

* [x] **内核 config**（2026-08-23 查完，从设备的 `/proc/config.gz` 读的实值）：
  `USB_STORAGE=y` ✅、`BLK_DEV_LOOP=y` ✅、`VFAT_FS=y` ✅、`NVME_CORE=y` ✅、
  面板与触摸都 `=y` ✅；缺的三个已加进 `kernel-config-android.sh`：
  **`SQUASHFS` 原本是 `=m`**（第 14 个「=m 坑」，救援 initramfs 里没有模块）、
  `NTFS3_FS` 原本没有、`NLS_UTF8` 原本没有。
  ⚠️★ `NTFS3_FS` 的 Kconfig 是 `depends on !NTFS_FS || m` —— 旧的 `NTFS_FS`
  兼容壳开着就把它**钉死在 `=m`**，`--enable` 也改不动，得先 `--disable NTFS_FS`。
* [x] **`Persisted_Capsules.bin`（70 MiB）：不动它。** 它是 UEFI 的
  capsule-on-disk 暂存文件（固件更新用）。Windows 虽然抹了，但这台机器的
  BIOS 无法用常规手段恢复，**用 70 MiB 去赌固件更新通路不出事，赔率不对**。
  ESP 的空间从别处找（见下），不从这里找。
* [x] **`recovery-ramdisk.img` ×2（30 MiB）**：grep 过全部启动项，**无人引用**，
  可删。加上 `EFI/Boot/bootaa64.efi.bak-windows`（3.1 MiB）与
  已抹除 Windows 的 `EFI/Microsoft`，一共约 45 MiB。
  ★ 而真正的大头是**统一内核之后**省下的那份救援 Ubuntu 内核 + initrd（59 MiB）。
  两笔加起来 ≈ 104 MiB —— 够放 live/rescue 的内核与 initramfs 了。
* [ ] 构建机上 `qemu-user-static` + binfmt 能不能装（apk 的目标架构脚本要用）
* [ ] 现有 `scripts/install-gaokun3.sh` 只有"清空整盘"一条路，且**从未端到端跑过**
  （TODO B4）。图形安装器要复用它的分区/写盘逻辑，那就必须先让它可被库调用，
  而不是一个从头跑到尾的脚本。


---

## M0 上机结果（2026-08-23 夜）

### ✅ 已在硬件上验过的

**squashfs 镜像本身**（从 Android 挂载复查）：`mount -o ro,loop` 成功，
`/sbin/init`、`sshd`、`sgdisk`、`wpa_supplicant`、ath11k 固件、
`/root/.ssh/authorized_keys`、`systemd-bootaa64.efi` 全在，
`gk3-sshd` / `gk3-wifi` / `avahi-daemon` / `dbus` / `haveged`
都挂在 default runlevel 上。

**initramfs + 自救路径**（阴性对照，零风险）：
故意给一个不存在的 `gk3.squash=` 路径启动。

| | 时间 |
|---|---|
| 正常 Android 重启（基线） | 约 45 秒 |
| 阴性对照这一轮 | **120 秒** |

多出的约 75 秒正是设计里的签名：**60 秒诊断等待 + 15 秒启动菜单超时**。
⇒ 证明 initramfs 能被内核解包、静态 busybox 能跑、`/init` 解析了 cmdline
并扫了所有分区、**失败之后自己重启并回到了 Android，全程无人干预**。

★ 这一步刻意设计成零风险：无论 initramfs 好坏，机器都会回到能远程接入的系统。

### ⬜ 还没验的（以及为什么今晚不做）

`switch_root` → OpenRC → `gk3-wifi` → sshd 这一段没验。

⚠️ **不做的理由**：这台机器只有 WiFi。如果救援系统起来了但网络没起来，
它会停在一个连不上的控制台，直到有人按电源键 —— 而本项目自己的规矩是
**"默认落点必须是能远程接入的系统"**。用户不在场时不该替他承担这个取舍。

**要试的时候**：启动项 `<machine-id>-rescue-alpine.conf` 已经就位，
squashfs 与 WiFi 配置都在 p3 上，一条 oneshot 就能进：

```sh
# 在 Android 里（需要 root）
printf '\x07\x00\x00\x00' > /data/local/tmp/os.bin
printf '%s' "<machine-id>-rescue-alpine.conf" | iconv -t UTF-16LE >> /data/local/tmp/os.bin
printf '\x00\x00' >> /data/local/tmp/os.bin
cat /data/local/tmp/os.bin > /mnt/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
reboot
```

失败会自动回落到 `default`（当前是 `*-android-a.conf`）；
**唯一需要人的情况是"起来了但连不上"**。

### ⓘ 当前部署方式是临时的

squashfs 现在放在**救援 Ubuntu 的 p3 分区上**（`/gaokun3/rescue.squashfs`），
而不是设计里说的独立 1 GiB 分区。
★ 这么做是**故意的**：验证阶段不动分区表，出问题只需删一个文件。
等完整启动验过之后，再按设计建独立分区、并把 p3 上那 24.6 GiB 的 Ubuntu 收回。

---

## ★★★ M0 完成：救援系统在硬件上跑起来了（2026-08-23）

```
Alpine Linux 3.24.1  ·  7.2.0-rc2-gaokun3+ aarch64  ·  gaokun3-rescue
根：overlay（只读 squashfs + tmpfs）    介质：/media/gk3 (ext4)
内存：15353 MiB 总 / 161 MiB 用          WiFi：SkipM4_5G，192.168.31.174
ssh：通
```

`sgdisk parted resize2fs mkfs.{ext4,vfat,f2fs} ntfsresize simg2img nvme rsync curl`
全部就位，`lsblk` 看得见内置盘的全部 8 个分区。

### ⚠️★ 真凶：内建驱动在 initramfs 阶段拿不到固件

前两次启动都是"系统起来了但网卡没有"。**`gk3-diag` 写回介质的日志一次定案**：

```
[1.191365] ath11k_pci 0006:01:00.0: wcn6855 hw2.1
[1.353331] mhi mhi0: Direct firmware load for ath11k/WCN6855/hw2.1/amss.bin failed with error -2
[1.353830] ath11k_pci: failed to power up mhi: -110
[1.354383] ath11k_pci: failed to init core: -110
```

**probe 发生在 t=1.19 秒** —— 远在 `switch_root` 之前，那时固件只可能在
initramfs 里；squashfs 还没挂上。找不到就 `-ENOENT`，然后驱动**放弃且不重试**。
同一时刻 remoteproc / 蓝牙 / venus / GPU 固件**全部同样 `-2`**。

把 WCN6855 固件打进 initramfs 之后，同一位置变成：

```
[1.325605] mhi mhi0: Requested to power ON
[1.325625] mhi mhi0: Power on setup success
[2.111038] ath11k_pci: chip_id 0x12 chip_family 0xb board_id 0xff soc_id 0x400c1211
```

⚠️ 只带 WCN6855 一颗芯片：整个 `ath11k` 目录 7 款芯片约 23 MiB，
而 initramfs 要放进只剩几十 MB 的 ESP。收窄后 **2.7 MiB**。

### ★ 教训：Android 那边为什么不用管这件事

Android 的 cmdline 上有 `firmware_class.path=/vendor/firmware/`，而 `/vendor`
在早期同样没挂上 —— 我一度因此**否掉了自己的正确假说**，以为"probe 本来就是
延后的，所以 squashfs 里的固件够得着"。
实测打脸：ath11k 在 **1.19 秒**就 probe 了。
★ **别用"另一个系统能行"去反推时序** —— 那两个系统的 initramfs 内容不同，
而这正是差别所在。

### ★ 没有网就没有信息 —— 所以救援系统必须自己留证据

前两次失败我**一点信息都拿不到**（没串口、没网、只能请人看屏幕）。
加上 `gk3-diag` 之后，它在 default runlevel 末尾把
`rc-status --all` / 挂载表 / 网络 / `sshd -T` 生效配置 / `dmesg` / 系统日志
**写回启动介质**（临时 remount rw）。下次进 Android 挂上 p3 就能读。
**这一条比这次修好的那个 bug 值钱。**

### 顺带修掉的三件

* `need localmount` → `after localmount`。`need` 是硬依赖，目标不在 runlevel
  里就**静默不启动**；`gk3-wifi` 与 `gk3-sshd` 共用这条，正好一起哑掉。
  而我们的根是只读 squashfs + tmpfs，**压根没有东西要挂**。
* `rc-status` 把一个**正常工作的** `gk3-wifi` 报成 `[crashed]`
  —— 没把 `pidfile` 声明给 OpenRC。救援系统里一个会说谎的 status 比没有更糟。
* `gk3_probe` 把 1007 KiB 的 misc 分区报成 `0 MiB`（整数除法）。
  合成数据里没有这种小分区，**只有真实磁盘能发现**。

### ✅ 安装器后端在真实磁盘上验过

站在救援系统里直接跑 `gk3_probe` / `gk3_plan`：

* 8 个分区、类型 GUID、文件系统、PARTLABEL 全对
* 认出那块 **63.9 GiB 的空闲区**（boot_b 与 metadata 之间）
* **双系统方案**用真实空闲区算出来严丝合缝：起于 814606336、止于 948561919，
  不重叠不越界，复用现有 ESP，`/data` 拿到 50.7 GiB

⇒ "在已有系统旁边装 Android"这条路，**在这台机器上是算得出来的**。

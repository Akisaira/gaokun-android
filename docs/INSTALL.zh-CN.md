<!--
  维护说明（不显示）：
  * 本文件是 docs/INSTALL.md 的中文版，逐节对应（REL-4）。译自 main 2eac147 时的 INSTALL.md。
    改一份就改另一份；事实以英文版与它注释里的出处为准，这里不另加内容。
  * 命令、文件名、属性名、开机菜单条目（systemd-boot 菜单只有英文）原样保留。图形安装器有中文界面：
    页面 / 选项写中文界面上的字（live/installer-flutter/lib/l10n/app_zh.arb），括号里附英文原文。
    Windows 与 Android 设置里的菜单路径保留英文原文，括号里的中文叫法没在中文版系统上逐字核对过（待核实）。
  * 用词与 FAQ.zh-CN.md / known-limitations.zh-CN.md 统一。
  * scripts/release.sh 在有这个文件时把它（而不是英文版）传到 R2 的 relnotes/INSTALL.md —— 系统更新里
    "无法更新（版本不受支持）"的说明链接指向那里。
-->
# 安装

[**English → INSTALL.md**](INSTALL.md) · [常见问题](FAQ.zh-CN.md) · [已知限制](known-limitations.zh-CN.md)

有两种装法，最后跑的都是同一个安装器后端：

* **图形安装器（预览）**（从 v0.7.0-alpha 起随发布提供）。可以用手指操作，可以**装在 Windows 旁边**，
  还可以**不用 U 盘**、直接从 Windows 里启动。推荐用它。
* **命令行安装器**（见[进阶](#进阶命令行安装器)）。会清空整块硬盘。后端相同，只是换成了文字界面 ——
  给喜欢敲命令的人。

**开始之前先读[在真机上测过什么](#在真机上测过什么)。** 测试机只有一台，就是开发者自己的那台，
所以新用户会走的大部分路径，到现在都只在测试盘上跑过。

> ### ⚠️ 清空硬盘会连 Windows 一起清掉。
> 无法撤销，而且哪里都没有出厂状态的镜像。想要回 Windows，只能自己用华为的恢复介质重装。
> 动手之前请把本页读完。

## 在真机上测过什么

| 路径 | 真机上测过吗？ |
|---|---|
| 图形安装器的 **重新安装 Android**（Reinstall Android）+ *保留用户数据*（Keep user data），从内置盘上的一份安装器启动 | ✅ 2026-09-26（载荷在介质上）和 2026-09-27（经 Wi-Fi 从本地镜像下载） |
| 图形安装器的 **重新安装 Android**，清除数据（这个模式的默认选项） | ⬜ 只在测试盘上 |
| 图形安装器的 **清除整个磁盘**（Erase the whole disk） | ⬜ 只在测试盘上 |
| 图形安装器的 **保留现有系统**（Keep the current system，双系统） | ⬜ 只在测试盘上 |
| 图形安装器的 **调整磁盘**（Adjust the disk） | ⬜ 只在测试盘上 |
| **从 U 盘启动安装器** | ⬜ 从没有过 —— 同一套系统从内置盘启动过很多次 |
| **Windows 脚本**（不用 U 盘启动安装器） | ⬜ 只在 Windows 11 ARM 虚拟机里 |
| **命令行安装器**（= *清除整个磁盘*） | ⬜ 2026-09-24 改用图形安装器的后端重写以后，只在测试盘上跑过。被它替换掉的那个旧脚本，就是开发机最初装系统时用的 |

"测试盘"指容器里的 loop 设备，每一步写入都会检查（`scripts/live/test-apply.sh`）。它能抓出很多问题 ——
双系统从来就装不上，就是它抓出来的 —— 但它毕竟不是真实固件后面的一块真 NVMe 盘。

## 开始之前

| 要求 | 为什么 |
|---|---|
| **华为 MateBook E Go，GK-W7X** | 只在这一款上构建和测试过 |
| 任意 BIOS 版本 | 本页以前要求 2.16、拒绝 2.17。这个限制已经取消（2026-09-25）：已经验证过与 BIOS 版本无关。安装器仍会报告它看到的版本号，因为报问题时需要它 |
| **关闭 Secure Boot** | 内核没有签名。两个安装器都会检查，没关就停下。在 Windows 11 里，固件设置的入口是 Settings → System → Recovery → *Advanced startup* → Troubleshoot → Advanced options → *UEFI Firmware Settings*（中文版 Windows 上大致是"设置 → 系统 → 恢复 → 高级启动 → 疑难解答 → 高级选项 → UEFI 固件设置"，待核实）。⬜ 这款机器开机时按哪个键进固件设置、哪个键进启动菜单，还没有按实测写下来 |
| **1 GB 或更大的 U 盘** —— 或者机器上**还有 Windows** | 安装器从 U 盘运行，或者从 Windows 脚本建的一个小分区运行 |
| **Wi-Fi** | 介质上没带系统镜像时，安装器要下载它（约 1.3 GB）。走 Windows 那条路可以自己带上：见[离线安装](#从-windows-启动不用-u-盘) |
| 键盘盖 | 只有命令行安装器和终端需要。图形安装器可以用手指操作，自带屏幕键盘 |

别的都不需要：不需要第二台电脑，不需要 `adb`，不需要本仓库的 checkout，也不需要自己准备固件
（发布镜像里已经带了 —— 见[固件](#固件)）。

你得有能力救回一台开不了机的机器。这里除了清空硬盘以外，没有什么是不可逆的 —— 但清空硬盘就是不可逆的。

### 你的数据没有加密

`/data` 是普通的 ext4 文件系统：没有基于文件的加密（`ro.crypto.state` 是 `unsupported`），1.0 也定了不加。
Secure Boot 是关着的，开机菜单里有安装器 / 救援系统，它们的控制台以 `root` 登录、不要密码。
任何拿到这台平板的人都能读出上面的一切；锁屏 PIN 只能挡住别人用屏幕。以后要开加密，就得清空 `/data`。

## 下载

| 什么 | 在哪 |
|---|---|
| **图形安装器** `gaokun3-installer-<版本>-…`（从它的下一个版本起，还有 `rescue.squashfs` 和命令行用的 `initramfs.img`） | GitHub：随它发布的那个 release 页面 —— 目前只有 **[v0.7.0-alpha](https://github.com/vahiru/gaokun-android/releases/tag/v0.7.0-alpha)**；之后的 release 没有再附带。镜像站：`https://ota.072172.xyz/installer/<版本>/<文件名>` —— ⬜ 那里还没传过任何东西；安装器的下一个版本两边都传 |
| **系统镜像** `boot.img`、`super.img.zst`、`install-artifacts.sha256`（只有命令行安装需要；图形安装器会自己下载） | GitHub：[最新 release](https://github.com/vahiru/gaokun-android/releases/latest)。镜像站，在 GitHub 的下载服务器连不上的地方（中国大陆）通常能用：`https://ota.072172.xyz/install/<build>/<文件名>` |

`<build>` 是那一版 OTA 包去掉 `.zip` 的文件名。以 v0.7.1-alpha 为例：

```
https://ota.072172.xyz/install/crDroidAndroid-16.0-20261003-gaokun3-v12.11/boot.img
https://ota.072172.xyz/install/crDroidAndroid-16.0-20261003-gaokun3-v12.11/super.img.zst
https://ota.072172.xyz/install/crDroidAndroid-16.0-20261003-gaokun3-v12.11/install-artifacts.sha256
```

当前的 build 名是 <https://ota.072172.xyz/ota/gaokun3.json> 里的 `filename` 字段（系统更新读的也是这个文件）。

## 图形安装器（预览）

文件（见[下载](#下载)）：`gaokun3-installer-<版本>-usb.img.xz`（可启动的 U 盘镜像）和
`gaokun3-installer-<版本>-windows.zip`（从 Windows 启动，不用 U 盘）。`gaokun3-installer-<版本>-SHA256SUMS`
列出这两个文件以及解压后的 U 盘镜像的校验值。安装器的版本号显示在侧栏底部，也写在介质上的
`gaokun3/release.txt` 里 —— 报问题时请带上。

它能做什么：

| 安装模式页上的选项 | 会发生什么 | 真机上测过 |
|---|---|---|
| **保留现有系统**（Keep the current system，双系统） | Android 装进空闲空间，已有的东西一概不动。开机菜单里仍然有 Windows | ⬜ 还没有（只在测试盘上） |
| **清除整个磁盘**（Erase the whole disk） | 盘上的一切换成[进阶](#装完之后的分区布局)一节里的分区布局 | ⬜ 还没有（只在测试盘上） |
| **重新安装 Android**（Reinstall Android；盘上已经有 Android） | 在现有分区里重写 Android；默认清除数据，也可以保留（*保留用户数据*） | ✅ 保留数据、同版本，从介质和经网络各一次。⬜ 清除数据 |
| **调整磁盘**（Adjust the disk） | 删除 / 缩小 / 扩大 / 新建 / 格式化分区，每一步单独确认 | ⬜ 还没有（只在测试盘上） |

系统镜像如果介质上带着就从介质上取，否则经 Wi-Fi 从上面的镜像站下载（最新版，约 1.3 GB）。
如果介质上带着镜像，还会把一个小救援系统（就是安装器本身）装进它自己的 1 GiB 分区，作为非默认的开机菜单项 ——
见[关于救援系统](#关于救援系统)。

**开始之前，在 Windows 里：** 关掉 *Fast Startup*（快速启动；Control Panel → Power Options →
*Choose what the power buttons do*，中文版大致是"控制面板 → 电源选项 → 选择电源按钮的功能"），
并且用 *Shut down*（关机）关机，不要用 *Hibernate*（休眠）。处于休眠状态的 Windows 分区不能调整大小 ——
安装器会检查并拒绝 —— 而且之后 Windows 自己也没法安全地挂载它。

**BitLocker / 设备加密，按这个顺序来**（下面的 Windows 脚本也按同样的顺序带你走）：先确认你拿得到恢复密钥
（<https://aka.ms/myrecoverykey>）；然后把系统盘上的 BitLocker 暂停两次重启 —— 脚本会问你，并替你运行
`Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 2`（通常是 C:）；**然后**才重启进固件设置、关掉 Secure Boot。
让 Windows 索要恢复密钥的，正是关 Secure Boot 这一步、或者之后改变了的启动路径，所以它不能放在最前面。
（脚本在暂停任何东西之前，还会先检查机器是不是以 UEFI 模式启动的。）⬜ 在这款平板上暂停两次重启够不够、
之后 BitLocker 怎么重新封存，还没在真机上核对过。

### 从 Windows 启动，不用 U 盘

1. 解压 `…-windows.zip`，双击 **`gaokun3-setup.cmd`**（它会请求管理员权限），读一下它打印的内容。
   它会检查型号、UEFI 和 Secure Boot，然后要你输入 `YES` 才会动硬盘。
2. 它让 Windows 把 **D:** 只缩小安装器自己需要的那一点（约 0.5–2 GB），建一个装着安装器的小 FAT32 分区
   `GK3LIVE`，加一个启动项，并且只把**下一次**开机设成进安装器。给 Android 的空间稍后在安装器里选。
   有两种例外它会问你：如果快速启动开着，它会提出替你关掉（安装器拒绝缩小被 Windows 留在休眠状态的分区）；
   如果 D: 用 BitLocker / 设备加密加密了 —— 安装器缩不了它 —— 它会提出现在就把给 Android 的空间腾出来。
   参数：`-AndroidGiB 64`（现在就给 Android 腾出这么多）、`-ShrinkDrive C`、`-Wifi none`。
3. 重启。在安装器里选 **缩小现有分区腾出空间**（Shrink an existing partition to make room；选 D:），
   再选 **保留现有系统**（Keep the current system）。（如果给 Android 的空间已经在 Windows 里腾好了，直接选后一项。）
   安装器缩小 D: 之后，Windows 下一次启动时会先做一次磁盘检查 —— 这是正常的：缩分区的工具故意要它这么做。

**离线安装：** 在第 1 步之前，把 `boot.img`、`super.img.zst` 和 `install-artifacts.sha256`（见[下载](#下载)）
放进 `gaokun3-setup.cmd` 旁边一个名为 `payload` 的文件夹。脚本会把它们拷到 `GK3LIVE` 上，
安装器就会用它们来装，不需要 Wi-Fi。

如果在安装之前改主意了，运行 `gaokun3-setup.cmd -Uninstall`：它会删掉那个分区和启动项、把 D: 扩回去，
如果它关过快速启动，也会恢复。如果机器直接又进了 Windows（固件忽略了一次性启动 ——
在华为的固件上还没验证过），加上 `-UseFallbackPath` 再运行一次。

⚠️ 这个脚本在 Windows 11 ARM 虚拟机里完整跑通过，还没在 MateBook E Go 上跑过
（"只划安装器自己的空间"这个默认行为、加密时的那个问题和快速启动那一步，目前只在单元测试里跑过）。

### 从 U 盘启动

把镜像写进 1 GB 或更大的 U 盘（balenaEtcher 和 Rufus 能直接读 `.xz`；在 Linux 上：
`xz -dc gaokun3-installer-<版本>-usb.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`），
插上，在固件的启动菜单里选它。Secure Boot 必须关掉。

⚠️ 这个安装器的 U 盘镜像还没在真机上启动过；同一套系统从内置盘启动过很多次。两个 USB-C 口里哪个能用来启动，
也还没核对过。（Android 下的 USB 调试要用靠近电源键的那个口；另一个口只能当主机。）

### 安装失败时：日志

安装器把日志写在它启动时所在的介质上，`gaokun3/diag/`（`installer.log`）。从 Windows 启动的
（不用 U 盘那条路）就是 `GK3LIVE` 那个盘。U 盘上麻烦一些：它唯一的分区是 EFI 系统分区，Windows 和 macOS
不会自己挂载它。最简单的办法是另拿一个格式化成 FAT32 或 exFAT 的 U 盘：插上，然后在安装器的终端里
（Ctrl+Alt+F2，`root`，不要密码）运行

```sh
bash -c '. /usr/share/gaokun3/installer-lib.sh && gk3_save_logs'
```

它会把日志、`dmesg`、本次开机的 journal、磁盘布局和分区表备份拷进那个 U 盘上的一个 `gaokun3-logs-<时间>`
文件夹（不含 Wi-Fi 密码）。失败页上的 *保存日志*（Save logs）按钮还在计划中。⬜ 还没在真机上跑过。

## 进阶：命令行安装器

它会清空整块硬盘 —— 和图形安装器的 **清除整个磁盘** 是同一件事，走同一个后端。在**安装器 U 盘的终端**里运行它：
它需要的东西那里都有。

### 1. 取得发布文件

从[下载](#下载)取三个文件，放进同一个目录：

| 文件 | 是什么 |
|---|---|
| `super.img.zst` | system / system_ext / product / vendor |
| `boot.img` | 内核、设备树和第一阶段 ramdisk，合在一个标准的 Android boot 镜像里（header v2）。会写进 `boot_a` 和 `boot_b`；安装器还会把它解开放到 ESP 上给 systemd-boot 用 |
| `install-artifacts.sha256` | 校验值。安装器在动硬盘**之前**先用它核对两个镜像，所以下载到一半断掉的文件会被拒绝，而不是留下一块写了一半的盘 |

什么都不要解压：`super.img.zst` 保持压缩状态 —— 安装器直接把它流式写进硬盘，不会产生 12 GiB 的中间文件。
发布页上的 `crDroidAndroid-*.zip` 是 OTA 包，安装用不到它。

### 2. 在安装器 U 盘的终端里运行

1. 用[安装器 U 盘](#从-u-盘启动)启动。如果下载需要 Wi-Fi，先在安装器的 *连接到 Wi-Fi*（Connect to Wi-Fi）页连上。
2. 切换到终端：在安装器第一页点 **退出到终端**（Quit to terminal），或者按 Ctrl+Alt+F2（Ctrl+Alt+F1 切回去）。
   以 `root` 登录 —— 没有密码。
3. 把发布文件下载到内存里（live 系统的可写层就是内存；1.3 GB 放得下），然后运行安装器：

   ```sh
   mkdir -p /tmp/rel && cd /tmp/rel
   B=crDroidAndroid-16.0-20261003-gaokun3-v12.11      # 你要装的 build，见"下载"
   for f in boot.img super.img.zst install-artifacts.sha256; do
       curl -fLO "https://ota.072172.xyz/install/$B/$f" || echo "FAILED: $f"
   done
   /usr/share/gaokun3/install-gaokun3.sh /tmp/rel
   ```

   （能连上 GitHub 的话，用 GitHub release 的链接也一样。）

⬜ 这一整套流程 —— U 盘的终端、下载到内存、整盘安装 —— 还没在真机上跑过（见[上面的表](#在真机上测过什么)）。

它会检查机器（型号、Secure Boot、工具；BIOS 版本只报告、不检查），打印它将要销毁的分区表和将要创建的布局，
然后等你输入 `ERASE`。在那之前什么都不写。目标盘默认是 `/dev/nvme0n1`；要装到别处，设 `DISK=`。

脚本不长，注释也全；与其相信本页，不如读脚本本身。特别是它解释了**为什么**要有每一个分区 ——
在一台没有 fastboot、没有 A/B boot 分区、没有 recovery 分区的机器上，这并不显然。

*从别的 Linux 安装：* 安装器也能在本仓库的完整 checkout 里运行（`sudo scripts/install-gaokun3.sh <发布目录>`；
它从 `scripts/live/` 读取后端，所以单拷这一个文件是跑不起来的；它需要 `gdisk dosfstools e2fsprogs zstd python3 systemd-boot-efi`）。
但还没有任何通用发行版镜像（Ubuntu、Debian……）被证实能在这台机器上启动 —— 这是一台只靠设备树的骁龙机器，
不是 ACPI PC —— 所以怎么走到那一步得靠你自己。这样装也不会有救援系统，除非你把 `rescue.squashfs` 和 `initramfs.img`
放进发布目录（去哪里取，见[关于救援系统](#关于救援系统)）。

### 装完之后的分区布局

| 分区 | 大小 | 用途 |
|---|---|---|
| `esp` | 300 MiB | systemd-boot，加上它实际加载的内核 / DTB / ramdisk，每个槽一个目录 |
| `misc` | 4 MiB | A/B 槽状态（`bootloader_control`） |
| `metadata` | 32 MiB | Android metadata |
| `super` | 12 GiB | 动态分区，A/B |
| `boot_a`、`boot_b` | 各 64 MiB | Android boot 镜像，A/B。OTA 更新的就是它们；ESP 上的那份是从它们解出来的 |
| `gk3rescue` | 1 GiB | *可选的*救援系统 —— 见下 |
| `userdata` | 剩余全部 | `/data` |

### 关于救援系统

这台机器没有能用的 Android recovery，也没有串口，所以能从菜单启动的一个小 Linux，就是修它的办法。

它就是安装器本身 —— 和 U 盘上是同一套系统，图形安装器也在里面，所以它也能重新安装 Android。
它以压缩镜像（squashfs）的形式放在自己的 1 GiB 分区里，从那里只读挂载，和 Android 共用内核；
运行期间你改动的东西都在内存里，下次开机就没了。只有安装器手上有这个镜像时才会装它：安装器 U 盘带着它，
Windows 安装包建的 `GK3LIVE` 分区也带着它（图形安装器里的选项是 *同时安装救援系统*（Also install the rescue system）；
⬜ Windows 那条路只在离线测试里核对过）。用命令行安装器的话，把 `rescue.squashfs` 和 `initramfs.img` 放进发布目录 ——
从图形安装器的下一个版本起，它们会和图形安装器一起附在 release 上（⬜ 还没发布），或者从 U 盘镜像里取
（它的 FAT 分区上的 `gaokun3/rescue.squashfs`、`gaokun3/initramfs.img`）。

**通过网络登录**需要你的 SSH 公钥 —— 发布的镜像里不带任何人的公钥。安装之前，把它放到安装器 U 盘上，
存成 `gaokun3/authorized_keys`（或者放进发布目录，存成 `authorized_keys`）；安装器会把它拷进救援分区，
连同你连过的那个 Wi-Fi 网络一起。没有公钥的话，救援系统只能在机器跟前用。

> ⚠️ 2026-09-24 起有变化。安装器以前会建一个 24 GiB 的 `rescue` 分区，把你当时启动的那个 live 系统整个拷进去。
> 那一套已经去掉了：安装器和图形安装器现在共用一份实现，救援系统就是上面那个小镜像。
> 如果你是用旧脚本装的，你机器上什么都不会变。

**怎么进去：15 秒的开机菜单。** 每次开机都会在 systemd-boot 的菜单停 15 秒；救援系统是其中一项。
如果 Android 卡死了，长按电源键，等菜单出来时选救援那一项。它永远不是默认项。

> ⚠️ **不要**指望机器自己回落到救援系统。Android 的 `boot_control` HAL 每次开机都会把 `default` 改写成当前运行的槽 ——
> 这是有意设计的，好让 A/B 换槽在重启后保持。从卡死中恢复，意味着得有人在菜单里选救援那一项。
> 本文档的早期版本承诺过自动回落；首次开机之后，那个承诺就从来没有成立过，所以我们把它撤回了，而不是粉饰过去。
> （旧脚本还会在安装时把救援设成默认项；那只能维持到第一次进 Android 为止，所以安装器现在干脆默认就是 Android。）

从救援系统回到 Android，直接 `reboot` 就行：救援那一项永远不是默认项，所以菜单 15 秒后会落到 Android。
想跳过菜单，或者想启动某个特定的槽，用救援系统自带的辅助命令：

```sh
gk3-boot-android b --reboot    # 只对下一次开机：用槽 b 的条目，然后马上重启
gk3-boot-android a             # 槽 a 同理，但不重启
gk3-boot-android --list        # ESP 上有什么、现在设了什么
gk3-boot-android --clear       # 撤销
```

它会自己找到 ESP，选出条目 `<machine-ID>-android-<槽>.conf`（名字里的 machine-ID 是已安装系统的，
不是救援系统自己的 —— 后者每次开机都重新生成），并把它设成 systemd-boot 的一次性条目（`LoaderEntryOneShot`）；
那一次开机之后，菜单的默认项重新生效。如果那个槽没有这样的条目、有不止一个，或者条目指向的内核在 ESP 上不存在，它会拒绝。
镜像里没有 `bootctl`，所以别处能找到的 `bootctl set-oneshot` 那套办法在这里不适用。

⬜ 还没在平板上的救援系统里试过（只在离线测试里）：特别是在那里写 EFI 变量行不行 —— 在 Android 里、用同一个内核是行的。

救援条目有**两条**，一条借用槽 a 的内核，一条借用槽 b 的：如果某次更新让一个槽的内核起不来，另一条仍然能启动救援系统。
两条用的是同一个救援镜像；第二条不额外占 ESP 空间。在这个改动之前装的机器，会在下一次更新到槽 b 时得到第二条。

## 固件

华为的专有固件（`.mbn`、`.jsn`、audioreach 拓扑）**不在**本仓库里。没有它们：没有 GPU（zap shader 就是其中之一）、
没有 Wi-Fi、没有蓝牙、没有声卡。

发布镜像里已经带了，所以全新安装不需要额外准备什么。如果你要从源码*构建*，见
[`device/huawei/gaokun3/firmware/README.md`](../device/huawei/gaokun3/firmware/README.md) ——
最快的办法是从你自己机器的 Windows 驱动库里取，或者从同一台硬件上的主线 Linux 安装里取。

## 第一次开机

两到三分钟，然后就好了 —— 没有需要运行的初始化脚本。息屏超时、国内能访问的联网检测端点、大屏上应用的信箱（letterbox）显示方式，都已经做进镜像里。

**还剩一步手动操作：亲手连一次 Wi-Fi。** 系统一旦认定某个网络没有互联网，就会把它永久标成停用，
而只有*用户亲手发起*、输入密码的连接才能清掉这个标记。镜像里预置的任何东西都替你做不了这一步。

### adb

安装和使用平板都用不到它。想用的话：打开 *开发者选项*（在 Settings → About tablet 里连点 *Build number* 七次；
中文界面大致是"设置 → 关于平板电脑 → 版本号"），再打开 *USB debugging*（USB 调试）或 *Wireless debugging*（无线调试）。
两者都按 Android 的标准方式工作：平板会让你给每台电脑授权。

在 v0.7.1-alpha 之后的发布构建里，*USB 调试*每次重启都会自己变回关闭，所以每次重启后要重新打开。
这是本移植的已知限制，不是设置没存上：Android 里平时负责记住它的那一部分（USB 设备管理器）在主线内核上不运行。
见[已知限制](known-limitations.zh-CN.md)。⬜ 还没在真机上确认过。

> 到 v0.7.1-alpha 为止的版本不一样：它们在所有网络上监听 TCP 5555 端口的 adb，**不要求授权**，
> 所以同一个网络里的任何人都能拿到 root shell。v0.7.1-alpha 之后的发布构建不再这样。如果你还在用那些版本，请更新。

### "此设备未经 Play 保护机制认证"

Google 维护着一份它认证过的设备构建身份清单，不在那个计划里构建的 ROM 不在清单上。Play 商店会这么提示，
有些应用在你解决之前会拒绝安装。解决办法免费，一分钟搞定，只要做一次。

1. 在平板上登录你的 Google 账号。
2. 读出设备的 Android ID：

   ```
   bash scripts/google/gsf-android-id.sh
   ```

   它需要电脑上有本仓库的 checkout、[adb](#adb)，以及 root —— 因为这个 ID 存在 Google Play 服务的私有存储里
   （流传很广的 `sqlite3 .../gsf/databases/gservices.db` 那个办法，在现在的 Play 服务上已经不行了，这个脚本就是为此而写的）。
   脚本怎么拿到 root：

   * **开发构建：** 通过 `adb root`；脚本自己会做。
   * **发布构建**（v0.7.1-alpha 之后）不再允许 `adb root`。先装 ReSukiSU 管理器 App，在里面给 **Shell** 授予 root；
     脚本会自己退回到 `adb shell su -c …`。⬜ 还没在发布构建上试过。

   计划在平板自己的设置里加一页显示这个 ID，这样就不需要电脑了（[`v1.0-plan.md`](v1.0-plan.md)，INST-14）。
3. **用同一个 Google 账号登录**，打开 <https://www.google.com/android/uncertified/>，粘贴这个 ID 并登记。
4. 等几分钟，然后清掉 Play 商店的数据：`adb shell pm clear com.android.vending`。

恢复出厂或清掉 Play 服务的数据之后要重新登记 —— ID 会变。

> **这解决不了什么。** Play Integrity —— 银行和一些支付 App 用的更强的认证 —— 仍然通不过，我们这边怎么配置都改变不了：
> 它要求上锁的 bootloader 跑 Google 签名的构建。这台机器按设计走的是未上锁的 UEFI 启动链，因为正是它让装别的系统成为可能。
> 如果某个 App 硬性要求 Play Integrity，它在这里就用不了。

## 更新

Android 16 的 A/B（虚拟 A/B）已经接好，所以更新会装进非活动槽，你可以照常用机器，下次重启后生效。

因为内核放在 ESP 上而不是 boot 分区里，本移植的 `boot_control` HAL 还会把活动槽同步进 systemd-boot 的 `loader.conf` ——
怎么做的、为什么原版 HAL 在这里不能用，见 [`device/huawei/gaokun3/boot_control/`](../device/huawei/gaokun3/boot_control/)。

**内核更新也走 OTA**，从 2026-08-20 起。`boot_a`/`boot_b` 是真正的 Android boot 分区，`boot` 在 `AB_OTA_PARTITIONS` 里，
所以内核改动就是一次普通的更新。

背后多了一步，因为 systemd-boot 读不了 Android boot 镜像：`update_engine` 写完非活动槽之后，一个 postinstall 钩子会解开那个槽的
boot 镜像，把内核、DTB 和 ramdisk 放进 ESP 上那个槽自己的目录。boot 分区才是权威来源，ESP 上的副本是从它派生的。
钩子只写它刚刷的那个槽，所以装更新不可能碰到你正在运行的内核。

> **更新之后回不到上一个版本。** 在虚拟 A/B 下，上一版的分区只保留到新版本成功启动一次为止；之后就被合并掉了。
> 开机菜单里仍然列着另一个槽（`… — slot _b` 或 `_a`），但从那以后那一项就起不来了：选它会白白失败一次开机，
> 然后机器重启回当前版本。（全新安装的机器上，`_b` 那一项背后压根就没有过系统。）也不会自己回落。
> 如果某次更新弄坏了你没法忍受的东西，回去的办法是图形安装器（开机菜单里的救援那一项，或者 U 盘）→
> **重新安装 Android**，选你要的版本；退回旧版本时保留数据，可能起不来。

> **自己手动分的区（双系统）？** 钩子和 boot-control HAL 通过 `/dev/block/by-name/esp` 找 ESP，而这个路径只有在 GPT 分区*名*
> （PARTLABEL，不是 vfat 卷标）恰好是 `esp` 时才存在。一位 v0.6.0 用户碰到过：每次 OTA 都失败，报 `/dev/block/by-name/esp 不存在`。
> 在任意 Linux 里修一次就好：`sgdisk -c <N>:esp /dev/nvme0n1`（N = 你的 ESP 的分区号）。从 v0.6.1 起，这两个组件都会退而
> 按内容找 ESP（装着 `loader/entries/*-android-*.conf` 的那个 vfat 分区）。

如果钩子失败了（通常是 ESP 满了），整个更新会明确地失败，而不是给你留下一个新系统配旧内核。

## 启动入口与 fastboot（1.0 起）

<!-- 与 INSTALL.md 同一节同源：S13（docs/boot-entry-design.md）。真机证据：E3–E8、执行端 E6 与分派 E7（docs/hw/gk3boot-*-20261005.txt）。
     镜像默认 persist.vendor.gaokun3.gk3boot=action（device.mk），条目文字见 boot_control/Gk3Boot.cpp 的 EntryText / ToolsText。
     ⚠️ E10（恢复出厂）与双系统（S15）没在真机上验过 —— 下面对应的句子都标了。 -->

从 1.0 起，Android 在 ESP 上有了自己的小启动器 **gk3boot**。它扮演的是手机上 bootloader 的角色：读 Android 存在 `misc`
分区里的 A/B 状态，选出槽，并直接从那个槽的 `boot_a` / `boot_b` 分区启动内核。菜单仍然由 systemd-boot 显示，
Windows 和救援系统也仍然归它管；gk3boot 只是它默认启动的那一项。

**什么时候接手。** 装上或更新到 1.0 后的第一次开机，仍然走旧的、每个槽各一条的条目。那次开机完成后，Android 会把 gk3boot
拷到 ESP 上，并加一个标题为 `Android` 的条目，排在最前面；之后每次开机都经过它。

**它带来什么：**

* **更新坏了会自动退回。** 刚更新的槽有六次机会。如果它始终没能完成开机（一直崩溃或重启），gk3boot 会自己退回到上一个槽，
  Android 会弹一条通知，说已经退回了。这是在这台机器上用一个故意弄坏的更新测过的。卡住不动、也不重启的情况，仍然要靠电源键。
* **启动器本身也有安全网。** 如果 `Android` 条目连续三次启动失败，systemd-boot 会回落到旧的、按槽的条目，
  所以坏掉的 gk3boot 不会把你锁在外面（在这台机器上测过）。
* **fastboot。** 见下。

**fastboot。** `adb reboot bootloader`（或 `adb reboot fastboot`），或者开机菜单里的 `Android fastboot / boot menu` 一项，
会启动一个用同一个内核做的小 fastboot 环境。屏幕上显示 `FASTBOOT MODE`、原因、槽和 USB 状态。然后：

* 数据线插在**靠近电源键**的那个 USB-C 口（port0）；另一个口不支持 fastboot。
* 在装了 Android platform tools 的电脑上：`fastboot devices`（设备名叫 `gaokun3`）、`fastboot getvar all`、
  `fastboot oem device-info`（磁盘、分区、A/B 和启动入口的状态）、`fastboot reboot`（回 Android）、
  `fastboot reboot bootloader`（重新进 fastboot）。
* 在机器本身上：音量键移动选项，电源键确认（音量键在这台机器上核对过；用电源键确认还没有）。

上面其余的内容都在这台机器上核对过。刷写（`fastboot flash`）已经实现、在模拟器测试里通过，但**还没在真机上试过** ——
目前请改用图形安装器重新安装。

**关掉它。** 以 root 身份（在这些构建上就是 `adb shell`；见 [adb](#adb)）：`setprop persist.vendor.gaokun3.gk3boot off`，
然后重启一次。那次开机完成时，Android 会从 ESP 上删掉 `Android` 和 fastboot 两个条目，机器就和 1.0 之前完全一样地启动。
用 `observe` 代替 `off`，则让 gk3boot 处在只记日志的模式，从不改动 `misc` 里的任何东西。

**双系统。** gk3boot 不碰 Windows。把 Windows 设成默认系统、从 Android 里"重启到 Windows"，这两样已经实现，
但**还没在真正的双系统机器上测过**。

## 清除数据（恢复出厂）

⚠️ **Settings → System → Reset options → *Erase all data*（设置 → 系统 → 重置选项 → 清除所有数据）目前什么都不做。**
那条路径会往 `misc` 里的 bootloader 控制块写 `boot-recovery` 然后重启，指望 bootloader 把控制权交给 recovery。
systemd-boot 不读这个块，这里也没有能用的 recovery（见下），所以这个请求无人接手 —— 之后你的数据还在。
从 1.0 起，这个请求打算交给启动入口的 fastboot 环境来执行（[见上](#启动入口与-fastboot10-起)）；那条路径在模拟器测试里通过了，
但**还没在这台机器上验证过**，所以在某个发版说明另有说法之前，请当作 *清除所有数据* 不起作用。

**现在要真正清掉 `/data`：** 启动图形安装器（开机菜单里的救援那一项，或者 U 盘）→ **重新安装 Android**，*保留用户数据* 不要勾 ——
清除是这个模式的默认选项。⬜ 清除数据这个变体目前只在测试盘上跑过，没在真机上跑过。分步说明，包括卖机或送修之前怎么做：
见[常见问题](FAQ.zh-CN.md#恢复出厂--卖机前清除数据)。

## Recovery：做出来了，但还起不来

这台设备上**没有能用的 recovery。** 镜像是编出来了，但启动它会让机器循环复位，所以没有哪个发布版带它，
开机菜单里的那一项也是**故意不建的**。测了什么、排除了什么，见 [#39](stage4-findings.md)。

这在今天让你失去的是：

* 没有 `adb sideload`。损失不大 —— 更新走设置，救援系统可以直接写任何分区。
* Android 里没有 `fastbootd`。从 1.0 起，改由启动入口拉起一个 fastboot 环境（[见上](#启动入口与-fastboot10-起)）。
* 不能从设置里恢复出厂（见上）。

如果你想调试它：命令行安装器接受你自己编的 recovery ramdisk（发布目录里的 `recovery-ramdisk.img`）。它和系统共用内核和 DTB，
所以只需要 ramdisk，它会落到 ESP 上两个槽各一份。`ENABLE_RECOVERY_ENTRY=1` 让安装器建开机菜单项，
`persist.vendor.gaokun3.recovery_entry=1` 让 OTA 钩子建它（2026-09-18 从 `persist.gaokun3.*` 改名 ——
SELinux 一转 enforcing，旧名字就写不进去了，见 `docs/stage4-findings.md` #117）。
⚠️ 这么做时人要在机器旁边：从循环里救回来要按电源键。

## 开不了机时

| 现象 | 原因 |
|---|---|
| 开机几秒就重启，哪个日志里都没东西 | 第一阶段挂载失败。`/sys/fs/pstore` 会是**空的** —— Android init 调用的是 `reboot()` 而不是 panic，所以 pstore 根本看不到它。在条目里加上 `androidboot.init_fatal_panic=true`，把它变成 efi_pstore 能抓到的真 panic |
| 选了另一个槽的条目，它重启了 | 更新之后这是预期的 —— 见[更新](#更新) |
| 黑屏，没有菜单 | Secure Boot 还开着，或者 ESP 没写好 |
| 能开机但没有 GPU / Wi-Fi / 声音 | `/vendor/firmware/` 里缺固件 |
| 拔掉 USB 后 adb 就没了 | 已知问题（[#27](stage4-findings.md)）。改用开发者选项里的 *无线调试*（见 [adb](#adb)） |

救援系统能重刷一切 —— 在机器跟前，或者如果你给了它公钥，也可以在局域网里经 SSH（见[关于救援系统](#关于救援系统)）。
它就是干这个用的。

## 报告问题

开 issue 时请写上你的 **BIOS 版本**、**SKU**、用过安装器的话写上安装器版本、你做了什么、发生了什么。
日志比描述更有用：如果 Android 能开机，首选

```sh
adb bugreport gaokun3-bugreport.zip
```

它一次就把系统日志、内核日志和崩溃记录都收齐了。它里面也有个人信息 —— Wi-Fi 网络名、账号名、装了哪些应用 ——
所以公开附上之前请自己读一遍。如果 Android 开不了机，从救援系统里取日志。怎么设置 adb、怎么单独取某种日志、
机器开不了机时该收集什么，都在[常见问题](FAQ.zh-CN.md#抓日志给开发者)里。告诉我们哪里坏了，和提交补丁一样有用。

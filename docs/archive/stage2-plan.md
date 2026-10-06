# Stage 2 方案：引导链 + AOSP 启动

目标（CLAUDE.md 第 98 行）：**adb shell 通了，黑屏也算成功。**

前置条件已全部就绪（Stage 0/1）：
内核有 binder / gadget / FunctionFS，崩溃日志走 efi_pstore 自动落盘。

> 标 ✅ 的是已实测；标 ⚠️ 的是设计判断，未验证。

---

## 0. AOSP 版本选择

**`android-16.0.0_r4`**

实测 manifest 上最新到 `android-17.0.0_r1`，但那是首发版本 —— 新硬件首次移植
不该同时赌两个未知数。16 已到 r4。

**不跟 aospm 的 Android 13。** 他们的设备树是 **sdm845** 的，我们是 **sc8280xp**，
设备树本来就要重写，它只是结构参考；而 2023 年的 AOSP 在 Debian 13
（glibc 新、Python 3.13）上大概率构建系统自己就跑不起来。

同步命令（构建机出口在加拿大，googlesource 直连 4.16 MB/s，不用镜像）：

```bash
repo init -u https://android.googlesource.com/platform/manifest \
    -b android-16.0.0_r4 --partial-clone --clone-filter=blob:limit=10M --no-tags
repo sync -c -j8 --no-clone-bundle --optimized-fetch --prune
```

---

## 1. 引导链：没有 boot.img，用 systemd-boot 直接加载

标准 Android：bootloader → `boot.img`（kernel + generic ramdisk）→ first stage init。
**本机没有 fastboot、没有 boot 分区**，但 systemd-boot 能直接加载
kernel + initrd + DTB —— 这正好替代 boot.img 的角色。

BLS entry 形态（放 ESP，与现有 Linux 条目并存）：

```
title      Android 16 (gaokun3)
linux      /<machine-id>/android/Image
initrd     /<machine-id>/android/ramdisk-combined.img
devicetree /<machine-id>/android/sc8280xp-huawei-gaokun3.dtb
options    <见第 3 节>
```

### ⚠️ ramdisk 要手工拼接（本阶段最大的未验证假设）

Android 16 把 ramdisk 拆成两部分：

- `ramdisk.img` —— generic ramdisk，含 first stage `/init`
- `vendor_ramdisk.img`（在 `vendor_boot.img` 里）—— 设备相关：内核模块、`fstab`

bootloader 本来负责把两者都喂给内核。systemd-boot 只接受一个 `initrd`，
所以要利用 **Linux 支持串接 cpio** 的特性合并：

```bash
cat ramdisk.img vendor_ramdisk.img > initrd-android.img
```

**能成立的依据**：Linux 的 initrd 解包器支持多个 cpio 归档首尾相接，
逐个解开、后者覆盖前者同名文件。这正是主线内核加载
"microcode + 主 initramfs" 的标准做法。

⚠️ **未验证的地方**：AOSP 产出的这两个 img 是 **lz4 压缩**的。
内核对"串接的压缩归档"支持不如未压缩 cpio 那么确定。

**判定方法**（部署后第一次启动就能分辨）：

| 现象 | 含义 | 处置 |
|---|---|---|
| 内核起来但 panic "No init found" | ramdisk 根本没解开 | 走下面的兜底方案 |
| 起来了但 fstab / 模块缺失 | 只解开了第一段 | 同上 |
| 正常进 first stage init | 串接成立 | 继续 |

**兜底方案**（不依赖串接特性）：各自解压后重新打成一个未压缩 cpio。

```bash
mkdir -p r && cd r
lz4 -dc ../ramdisk.img | cpio -idm
lz4 -dc ../vendor_ramdisk.img | cpio -idm     # 覆盖同名文件，顺序不能反
find . | cpio -o -H newc > ../initrd-android.img
```

未压缩 initrd 体积大一些，但 ESP 有 890 MB 空闲，放得下。

### 优点：回滚是免费的

改坏了不影响现有 Linux 条目，systemd-boot 菜单里选回去即可。
**这一路的每一步都不需要 fastboot、不需要刷机、不会变砖。**

---

## 2. 分区方案

### 2.1 现状（实测）

```
nvme0n1  476.9G
├─p1  300M  vfat  EFI system partition   SYSTEM     ← ESP，Android 的 kernel/ramdisk 放这
├─p2   16M        Microsoft reserved
├─p3  120G  ntfs  Basic data partition   Windows
├─p4  336.6G ntfs Basic data partition   Data       ← 从这里割
├─p5    1G  vfat  Basic data partition   WINPE
├─p6   18G  ntfs  Basic data partition   Onekey
└─p7    1G  ntfs  Basic data partition   WinRE
```

### 2.2 by-name 的正确理解（修正之前的说法）

`/dev/block/by-name/*` 由 GPT 的 **PARTLABEL** 生成。
Windows 建的分区 PARTLABEL 全是 `Basic data partition`，**不唯一**，所以
不能靠它引用现有分区 —— 这是之前判断"要用 PARTUUID"的由来。

但 **Android 自己的分区是我们新建的**，建的时候把 PARTLABEL 设成
`super` / `userdata` / `metadata` 就行，by-name 完全可用，
aospm 的 fstab 模板可以几乎照抄。

→ **结论：Android 分区用 PARTLABEL（自己设的），不碰 Windows 分区。**

### 2.3 计划布局

用**动态分区（super）**而不是分立分区。理由：Android 16 默认如此，
构建直接产出 `super.img`；关掉它反而要额外配置，逆着构建系统走。

| 新分区 | PARTLABEL | 大小 | 用途 |
|---|---|---|---|
| — | `super` | 12 G | system / system_ext / product / vendor（逻辑分区）|
| — | `userdata` | 64 G | /data，游戏装这儿 |
| — | `metadata` | 32 M | 加密元数据 |

合计约 **76 G**，从 p4（336.6 G）压缩得到，Windows 侧仍剩约 260 G。

**不需要** `boot` / `vendor_boot` / `dtbo` / `misc` 分区 —— 那些是 fastboot 流程的产物，
我们由 systemd-boot 从 ESP 直接加载。

⚠️ `misc` 分区（bootloader control block）在没有 A/B 和 fastboot 时用不上，
但某些 AOSP 组件会尝试读它。**[待确认]** 缺了会不会报错。

---

## 3. 内核 cmdline

以 aospm `shared/BoardConfig.mk:40-43` 为模板，逐项按本机改：

```
# —— 沿用 ——
firmware_class.path=/vendor/firmware/
init=/init
printk.devkmsg=on
deferred_probe_timeout=30
androidboot.selinux=permissive          # 首次启动必须，跑通再收紧

# —— 按本机改 ——
androidboot.hardware=gaokun3
androidboot.boot_devices=soc@0/1c20000.pcie      # ✅ 实测 NVMe 路径
console=tty0                                      # 本机无串口，去掉 ttyMSM0

# —— 从现有 Linux 条目继承（这些是本机跑通的必需项）——
clk_ignore_unused pd_ignore_unused arm64.nopauth
efi=noruntime
fbcon=rotate:1
usbhid.quirks=0x12d1:0x10b8:0x20000000
```

`androidboot.boot_devices` 的依据（实测）：

```
/sys/devices/platform/soc@0/1c20000.pcie/pci0002:00/0002:00:00.0/0002:01:00.0/nvme/nvme0/nvme0n1
```

⚠️ **不要加 `earlycon`** —— 强烈怀疑它会挂死本机启动
（见 `docs/archive/stage1-kernel-plan.md` 第 1.0 节）。

---

## 4. 设备树（AOSP 侧）

参考 `refs/aospm-device-sdm845` 的结构，但内容全部重写（不同 SoC）：

```
device/huawei/gaokun3/
├── AndroidProducts.mk
├── BoardConfig.mk          ← cmdline、分区尺寸、架构
├── device.mk               ← 打包哪些 HAL / 固件
├── aosp_gaokun3.mk         ← product 定义
├── fstab.gaokun3           ← by-name，见 2.2
├── init.gaokun3.rc
├── init.gaokun3.usb.rc     ← adb gadget（configfs + FunctionFS）
├── ueventd.gaokun3.rc
├── manifest.xml
├── firmware/               ← 第 5 节那 8 个固件
└── sepolicy/
```

架构相关（与 sdm845 的差异）：

```makefile
TARGET_ARCH      := arm64
TARGET_BOARD_PLATFORM := sc8280xp
TARGET_SCREEN_DENSITY := ?      # 屏幕 1600x2560 @ 266x166mm
```

⚠️ **DPI 待定。** 物理尺寸 266×166 mm、分辨率 1600×2560，算出约 **245 dpi**，
但那是横向摆放的算法。CLAUDE.md 第 124 行提示可参考 Galaxy Tab S7 FE
（同款面板）的 AOSP 设备树取值。

---

## 5. vendor 分区要带的固件（实测清单）

来自 Stage 0 的 `02-firmware-paths.txt`：

```
qcom/a660_sqe.fw                                  GPU 微码
qcom/a660_gmu.bin                                 GPU GMU
qca/wcnhpbtfw21.tlv                               蓝牙
qca/wcnhpnv21g.bin                                蓝牙 NVM
qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn       ADSP
qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn       CDSP
qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn       SLPI
```

配合 `firmware_class.path=/vendor/firmware/`，全部放 `/vendor/firmware/` 下
并保持相同的子路径结构。华为那三个 `.mbn` 不在 linux-firmware 里，
从当前 Linux 系统的 `/lib/firmware/` 直接取。

---

## 6. adb 通路（Stage 1 已验证硬件侧）

Stage 1 证明了 `a600000` 能作为 gadget 枚举，FunctionFS 可挂。
Android 侧要做的是让 init 建同样的 gadget：

```
# init.gaokun3.usb.rc 大意
on boot
    write /sys/kernel/config/usb_gadget/g1/idVendor 0x18d1
    write /sys/kernel/config/usb_gadget/g1/idProduct 0x4ee7
    ...
    write /sys/kernel/config/usb_gadget/g1/UDC a600000.usb
```

⚠️ **`androidboot.usbcontroller=a600000.usb`** 可能需要加到 cmdline ——
Android 的 usb HAL 用它定位 UDC。**[待确认]** 现代 AOSP 是否还读这个属性。

**后备方案**：内核已开 RNDIS/ECM，万一 USB adb 不通，
可以走 USB 网络做 `adb connect`。再不行还有 WiFi + `service.adb.tcp.port`。

---

## 7. 执行顺序

| # | 动作 | 风险 |
|---|---|---|
| 1 | AOSP 源码同步（进行中，数小时）| 无 |
| 2 | 写 `device/huawei/gaokun3/` 设备树 | 无 |
| 3 | `lunch` + 构建，先只求编译通过 | 无 |
| 4 | 在 Ego 上用 GParted 压缩 p4，建三个分区 | **中** —— 唯一动内置盘的一步 |
| 5 | dd `super.img` / 格式化 `userdata` `metadata` | 低 |
| 6 | 拼 ramdisk，放 ESP，建 BLS entry | 低 |
| 7 | 重启选 Android 条目 | 低（失败可选回 Linux）|
| 8 | 看 adb / efi_pstore | — |

**第 4 步之前务必先备份 Windows 分区表**（`sgdisk --backup`）。
在此之前所有操作都不碰内置盘。

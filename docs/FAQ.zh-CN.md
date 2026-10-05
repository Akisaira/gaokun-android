<!--
  维护说明（不显示）：
  * 按"出了什么事 → 怎么办"组织。每个回答都要有出处（脚本 / 案卷 / 实机），出处写在注释里，不写在正文里。
    找不到出处的写"待补"，不凭记忆写 —— 尤其是固件按键和 Windows 的菜单路径。
  * 中英两份（FAQ.md）内容必须一致，改一份就改另一份。
  * 写"1.0 起"的地方依赖 D1（发布版关掉免授权 adb、ro.debuggable=0）。那一版实际发出去之前，先核对它真的落地了。
-->
# 常见问题

[**English → FAQ.md**](FAQ.md) · [已知限制](known-limitations.zh-CN.md) · [安装](INSTALL.zh-CN.md)

* [开机与启动菜单](#开机与启动菜单)
* [更新与回退](#更新与回退)
* [抓日志给开发者](#抓日志给开发者)
* [救援系统与 SSH](#救援系统与-ssh)
* [恢复出厂 / 卖机前清除数据](#恢复出厂--卖机前清除数据)
* [卸载 Android、回到 Windows](#卸载-android回到-windows)
* [开发者选项、USB 调试与无线调试](#开发者选项usb-调试与无线调试)

---

## 开机与启动菜单

### 怎么进 UEFI 固件设置、关 Secure Boot、从 U 盘启动？
<!-- INST-4 / REL-9：仓库里没有任何按键的记录（docs/stage7-flutter-debian.md:290 "具体按键案卷里没记"）。
     ⚠️ 等用户在本机实测后补上：进固件设置的按键、启动菜单的按键、不接键盘盖时怎么按、Secure Boot 选项在哪个菜单。 -->
**按键待补（需要在本机上实测，我们不想凭印象写错）。** 知道这些的话，欢迎在群里或 issue 里告诉我们。

目前能确定的是：

* **Secure Boot 必须关掉**，因为内核没有签名。安装器开始前会检查，没关就拒绝继续；
  Windows 下的免 U 盘安装脚本也会先检查这一项。
* 从 U 盘启动：插上安装器 U 盘，在固件的启动菜单里选它。

### 开机时那个菜单里的每一项是什么？
<!-- 标题出处：scripts/live/installer-lib.sh:915（Android 两个槽）、:962（救援）；scripts/windows/gaokun3-setup.ps1:58（gaokun3 installer）；
     docs/hw-inventory.md §8quater（systemd-boot 自动列出 Windows Boot Manager）。timeout：installer-lib.sh:949。 -->
每次开机都会在 systemd-boot 菜单停 15 秒，然后启动默认项。

| 菜单项 | 是什么 |
|---|---|
| `Android` | 1.0 起：Android 自己的启动入口（gk3boot），自己选槽，更新后起不来会自动退回旧版本。装上 / 升级到 1.0 后的第一次开机完成时加上。见 [安装指南](INSTALL.zh-CN.md#启动入口与-fastboot10-起) |
| `Android fastboot / boot menu` | 1.0 起：fastboot 环境（数据线插靠近电源键的 USB-C 口） |
| `crDroid 16.0 (gaokun3) — slot _a`<br>`crDroid 16.0 (gaokun3) — slot _b` | Android 的两个槽，直接启动（1.0 起它们是后备，平时走上面的 `Android`）。**默认高亮的那一项就是现在在用的**。另一项能不能用，见下面的[回退](#更新后出了问题能回到上一版吗) |
| `gaokun3 rescue (slot a kernel)`<br>`gaokun3 rescue (slot b kernel)` | 救援系统（老机器上是一条 `gaokun3 rescue (runs from RAM)`）。只有用图形安装器安装、并且保留了"救援系统"选项时才有。它就是图形安装器本身，可以重新安装 Android，也可以 SSH 进去。两条只差借用哪个槽的内核 |
| `Windows Boot Manager` | 双系统时才有，菜单会自动找到它 |
| `gaokun3 installer` | 用 Windows 免 U 盘方式启动安装器时留下的条目 |

### 菜单怎么操作？不接键盘盖能操作吗？
<!-- INST-18 / OTA-12：无键盘时能否操作菜单从没验证过。 -->
接着键盘盖：用方向键选，回车启动。

**不接键盘盖时，音量键和电源键能不能操作这个菜单，还没有验证过（待补）。** 需要在菜单里选择时，请先接上键盘盖。

---

## 更新与回退

### 更新后出了问题，能回到上一版吗？
<!-- OTA-3（复核：VAB 合并后另一个槽已不可用；选它会失败一次、然后回到默认项，不会死循环）；
     OTA-2（新槽起不来时不会自动回落；手选旧槽之后默认项可能不会自己改回来 —— 推断，未验证）；
     docs/stage4-findings.md #118 §2。新装机：super 里只有 _a（OTA-3）。 -->
**大多数情况下不能。** 系统更新用的是 Android 的"虚拟 A/B"：新版本第一次成功开机后，后台会把它合并成唯一的一份系统，
上一版也就不存在了。之后菜单里虽然还列着另一个槽，选它只会白白重启一次，然后回到默认项。

只有一种情况能回去：**新版本根本起不来**（例如开机反复重启），还没来得及合并。这时：

1. 长按电源键关机，再开机。
2. 在菜单里选**另一个**槽（不是默认高亮的那个）。
3. 开机后，下次重启时默认项可能仍然指向坏掉的那个槽（这一点还没验证）。如果是这样，每次开机都在菜单里手选，直到下一次更新。

刚装好、还没做过任何更新的机器，只有当前那个槽里有系统，另一个槽是空的。

如果新版本能开机、只是某个功能坏了：回不到上一版。等修复版，或者用图形安装器重新安装旧版本（见下一条）。

### 能装回旧版本（降级）吗？
<!-- BATT-7：没有 userdata checkpoint，降级不保证数据兼容。重新安装：live/installer-flutter/lib/l10n/app_zh.arb:123、:132。 -->
可以用图形安装器的 **重新安装 Android** 装任意版本。但**降级时保留数据不保证能用**：新版本可能已经把你的数据改成了旧版本不认识的格式。
降级请选择清除数据（这是默认选项，不要勾"保留用户数据"），装之前先备份。

### 开机一直重启或卡住怎么办？
1. 先按上面的办法，在菜单里换另一个槽试试。
2. 不行就选 `gaokun3 rescue (runs from RAM)`，或者插安装器 U 盘启动，然后用 **重新安装 Android**。
   勾上"保留用户数据"可以保住数据（同版本重装在真机上验证过）。
3. 救援系统里能抓日志，见[机器起不来时](#机器进不了-android-时怎么抓日志)。

---

## 抓日志给开发者

报问题时请附上：机器型号（GK-W7X）、BIOS 版本、ROM 版本（见下面）、你做了什么、发生了什么，以及下面这些日志。
在 [GitHub issues](https://github.com/vahiru/gaokun-android/issues) 提，或者发到 [Telegram](https://t.me/gaokunAndroid) / QQ 群 **920133252**。

### 先准备 adb
<!-- USB adb 只在 port0 上 = 靠近电源键的口（2026-10-05 用户确认，STOR-3）；息屏时 USB adb 会断（README.zh-CN.md 待机一行，#52）。 -->
1. 在电脑上装 Google 的 **SDK Platform-Tools**（里面就有 `adb`）。
2. 在平板上打开**开发者选项**和 **USB 调试**，步骤见[下面](#开发者选项usb-调试与无线调试)。
3. 用 USB 线连上电脑，**屏幕保持亮着**（息屏时 USB 调试会断开）。电脑上运行 `adb devices`。
   **要插靠近电源键的那个 USB-C 口**：只有它能用于 USB 调试（另一个口只能当主机）。还是看不到设备的话，拔下来重插一次：
   和某些电脑相连时，两边偶尔会协商反，变成平板给电脑充电、两边都看不到对方（见[已知限制](known-limitations.zh-CN.md#插电脑时平板可能反过来给电脑充电)）。
4. 不想接线的话，用[无线调试](#无线调试)。

### 有电脑、机器能开机时
<!-- 内核日志：shell 用户在 enforcing 下没有 syslog_read（refs/lineage-sepolicy/private/ 下 shell.te 没有授权，dumpstate.te:211 有）⇒
     首选 bugreport（含 dmesg、logcat、墓碑；墓碑：refs/lineage-sepolicy/private/dumpstate.te:426-428 允许 dumpstate 读
     /data/tombstones）。隐私提醒与 .github/ISSUE_TEMPLATE/01-bug.yml 的日志一栏同口径。
     pstore 要 root（docs/stage4-findings.md #58："ls /sys/fs/pstore/ 需要 root"）。
     hangdump：device/huawei/gaokun3/etc/hangdump.rc:13（/data/vendor/gaokun3，0770 root system）。 -->
最省事、最全的一份：

```sh
adb bugreport gaokun3-bugreport.zip
```

它包含系统日志、内核日志、崩溃记录等，也包括 `/data/tombstones` 下的崩溃转储（墓碑）—— 那个目录不用 root 是读不到的。

⚠️ **错误报告里有个人信息**：Wi-Fi 名称、账号名、装了哪些应用。公开上传前请自己过一遍。

只想要一部分时：

```sh
adb logcat -b all -d > logcat.txt          # 全部系统日志（-d：导出后退出）
adb logcat -b crash -d > crash.txt         # 只要崩溃记录
adb shell dmesg > dmesg.txt                # 内核日志；报"权限不够"时用下面带 su 的那条
```

下面几条需要 root（先在 ReSukiSU 管理器里给 **Shell** 授权）：

```sh
adb shell su -c dmesg > dmesg.txt
# 上一次死机、重启时内核留下的记录（efi_pstore）；是空的也正常，很多故障不经过内核
adb exec-out "su -c 'tar -C /sys/fs -cf - pstore'" > pstore.tar
# 音频 / 蓝牙卡死时自动采的取证包
adb exec-out "su -c 'cd /data/vendor/gaokun3 && tar -cf - hangdump-*'" > hangdump.tar
```

**死机或自己重启之后，先别做别的，第一时间抓 `pstore`**。

ROM 版本：

```sh
adb shell getprop ro.build.version.incremental    # 例如 20261003184648
adb shell getprop ro.build.date.utc               # 构建戳，例如 1791053208
```

### 没有电脑时
<!-- REL-9：设置里的错误报告能否用于本机，未验证。 -->
开发者选项里的"错误报告"在这台机器上能不能用，还没有验证（待补）。
目前请尽量用电脑按上面的办法抓。

### 机器进不了 Android 时怎么抓日志
<!-- gk3-diag：scripts/live/overlay-common/etc/motd:9（/media/gk3/gaokun3/diag/，开机 45 秒后写）；
     .github/ISSUE_TEMPLATE/02-install-boot.yml:141-143（journalctl -k、/sys/fs/pstore、/var/lib/systemd/pstore/）。
     ⚠️ 未验证：Debian 的 systemd-pstore 是否会在救援系统里把 EFI 里的记录挪进内存里的 /var/lib/systemd/pstore（重启即失）。
     U 盘卷标：scripts/live/build-usb.sh:96-97（mformat -v GK3LIVE）；介质挂在 /media/gk3：scripts/live/initramfs-init:131；
     诊断写回介质、U 盘插别的机器能读：scripts/live/overlay-common/usr/lib/gaokun3/gk3-diag:2-9。 -->
在菜单里选 `gaokun3 rescue (runs from RAM)`（或者从安装器 U 盘启动）。

* 它开机 45 秒后会自动把诊断信息写到 `/media/gk3/gaokun3/diag/`。这个目录在盘上，重启后还在。
* 内核日志：`journalctl -k`。
* 崩溃记录：看 `/sys/fs/pstore/` 和 `/var/lib/systemd/pstore/`。**重启前先把它们拷到 `/media/gk3/gaokun3/diag/`**，
  后一个目录在内存里，重启就没了。
* 用 SSH 取回：`scp -r root@<IP>:/media/gk3/gaokun3/diag .`（SSH 要先授权，见下一节）。
* 是从安装器 U 盘启动的？那 `/media/gk3` 就是 U 盘本身：它的 FAT 分区，卷标 **`GK3LIVE`**。
  把 U 盘插到任何一台电脑上，文件就在 `gaokun3/diag/` 里。

---

## 救援系统与 SSH

### 救援系统怎么 SSH 进去？
<!-- 出处：scripts/live/build-rootfs.sh:145（root 无密码，仅限本地控制台）、:149-157（公开镜像不带公钥）；
     scripts/live/overlay-common/etc/ssh/sshd_config:4、:15（网络侧只认公钥）；
     scripts/live/installer-lib.sh:1012-1024（安装器把介质上的 gaokun3/authorized_keys 带进救援分区）、:1001-1008（Wi-Fi 同理）；
     scripts/live/overlay-common/usr/lib/gaokun3/gk3-ssh-keys（开机把 /media/gk3/gaokun3/authorized_keys 并进 /root/.ssh）；
     scripts/live/release-installer.sh:11（发布的安装器装进救援分区的就是 live 镜像本身 ⇒ 主机名 gaokun3-live，build-rootfs.sh:121）；
     app_zh.arb:17、:423（"退出到终端"、Ctrl+Alt+F2）。 -->
救援系统**只接受 SSH 公钥登录**。发布的镜像里不带任何人的公钥，所以要先把你自己的公钥放进去，否则只能在机器旁边操作。

**还没安装时**（推荐）：

1. 在电脑上生成一对密钥（已经有了就跳过）：`ssh-keygen -t ed25519`。
2. 把公钥（`~/.ssh/id_ed25519.pub` 的内容）存成安装器 U 盘上的 `gaokun3/authorized_keys`。U 盘的这个分区是 FAT，Windows 和 Mac 都能直接写。
3. 想让救援系统开机就连上 Wi-Fi：在安装器里连一次 Wi-Fi，安装器会把这份配置一起带过去；
   或者在 U 盘上放一份 `gaokun3/wpa_supplicant.conf`。
4. 安装时保留"救援系统"选项。安装器会把这两个文件复制进救援分区。

**已经装好了**：

1. 开机在菜单里选 `gaokun3 rescue (runs from RAM)`，会出现安装器界面。
2. 点"退出到终端"（或按 Ctrl+Alt+F2），用 `root` 登录。在机器前登录不需要密码。
3. 把公钥追加进去，然后重启 SSH：

   ```sh
   cat >> /media/gk3/gaokun3/authorized_keys     # 粘贴公钥，回车，再按 Ctrl+D
   systemctl restart ssh
   ```

   这个文件在救援分区上，以后每次进救援系统都有效。

**连接**：在救援系统的终端里用 `ip addr` 看 IP，然后在电脑上运行 `ssh root@<IP>`。
局域网支持 mDNS 的话，也可以试试 `ssh root@gaokun3-live.local`（还没在别人的网络里验证过）。

---

## 恢复出厂 / 卖机前清除数据

<!-- B6 / D4：设置里的"清除所有数据"无效，将来由 fastboot 承接（设计中）。⚠️ fastboot 落地后改写这一节。
     图形安装器：app_zh.arb:123"重新安装 Android"、:132"保留用户数据"；INSTALL.md 能力表（同版本保留数据重装已在真机验证）。
     REL-9 复核：INSTALL.md 里教的 mkfs.ext4 写法对普通用户风险太高，统一走图形安装器。 -->
**设置里的"清除所有数据"在这台机器上不起作用**：点了以后重启，数据全都还在。原因见[已知限制](known-limitations.zh-CN.md#设置里的清除所有数据恢复出厂不起作用)。
以后会改成用 fastboot 来恢复出厂，目前还在设计中。

现在请这样做：

1. 开机在菜单里选 `gaokun3 rescue (runs from RAM)`；没有这一项的话，插安装器 U 盘启动。
2. 选 **重新安装 Android**。**不要**勾"保留用户数据"（默认就是不勾，也就是清除数据）。
3. 系统镜像从 U 盘读取，U 盘里没有的话会通过 Wi-Fi 下载（约 1.3 GB）。

⚠️ 数据分区没有加密（见[已知限制](known-limitations.zh-CN.md)）。卖机或送修前，请务必先清除。

---

## 卸载 Android、回到 Windows

### 双系统：只想回 Windows 用一下
<!-- docs/hw-inventory.md §8quater：systemd-boot 自动列出 Windows Boot Manager。 -->
开机在菜单里选 `Windows Boot Manager` 就行。

### 双系统：彻底去掉 Android
<!-- 事实出处：scripts/live/installer-lib.sh:894-907（把 ESP 的回落路径 EFI/BOOT/BOOTAA64.EFI 换成 systemd-boot，
     原件备份为 .before-gaokun3）、:910-924（ESP 上的 <machine-id>/android/ 与 loader/entries/*-android-*.conf）；
     installer-lib.sh:323 / :397（Android 的分区名）；scripts/windows/gaokun3-setup.ps1:18（装上 Android 之后 -Uninstall
     只撤启动项与 ESP 上的安装器文件）。完整流程从没在真机上走过（GUI-17/18 扩展部分推迟到 1.0 之后）。 -->
**完整的卸载流程还没有在真机上走过，我们暂时不给分步命令（待补）。** 动手前请先在群里问一下。

供参考，安装器改动过的地方有这些：

* **启动**：ESP 上的 `EFI/BOOT/BOOTAA64.EFI` 换成了 systemd-boot，原来的文件备份为 `EFI/BOOT/BOOTAA64.EFI.before-gaokun3`。
  把它恢复回去，开机就会直接进 Windows。
* **ESP 上的文件**：一个以 machine-id 命名的目录（里面有 `android/`），以及 `loader/` 下的配置和启动项。
* **分区**：`misc`、`metadata`、`super`、`boot_a`、`boot_b`、`userdata`，可能还有 `gk3rescue`。
  删掉它们之后，再在 Windows 里把空间并回去。
* Windows 下的 `gaokun3-setup.cmd -Uninstall` 在 Android **装上之后**只会撤掉安装器自己的启动项和文件，**不会**卸载 Android。

### 用"清除整个磁盘"装的：想装回 Windows
<!-- docs/INSTALL.md:12-15；INST-21（从没在本机实操过）。 -->
那时 Windows 已经被清掉了，只能用华为的恢复介质重新安装。这个流程我们没有在这台机器上做过（待补）。
想保留 Windows 的话，安装时请选**保留现有系统**（双系统）。

---

## 开发者选项、USB 调试与无线调试

<!-- 菜单名称是 AOSP / crDroid 的标准叫法，没在本机界面上逐字核对（待构建机或真机核实）。 -->
菜单名称以设备上显示的为准。

### 打开开发者选项
1. **设置 → 关于平板电脑**，连续点"版本号"7 次，按提示输入锁屏密码。
2. 之后在 **设置 → 系统 → 开发者选项** 里能找到它。

### USB 调试
<!-- 每次重启复位成关：device/huawei/gaokun3/init.gaokun3.usb.rc:59-64（本机没有 UsbDeviceManager；重启后 AdbService 按
     persist.sys.usb.config 复位，发布构建里它为空）。AdbService 那半是按 frameworks/base 写的，本地 refs 没有那棵树，
     待构建机核实；上机核对列在 B1 的 needs_verification 里。依赖 D1 / B1。 -->
在开发者选项里打开 **USB 调试**，用线连上电脑。从 1.0 起，平板上会弹出"是否允许 USB 调试"：确认电脑的指纹，
勾上"一律允许"再点允许。没有授权的电脑连不上。

从 1.0 起，**"USB 调试"每次重启都会自己复位成关**：每次重启之后要重新打开。这是本机移植的已知限制
（见[已知限制](known-limitations.zh-CN.md)），不是设置没存上。还没在实机上确认过。

### 无线调试
1. 平板和电脑连同一个 Wi-Fi。
2. 开发者选项 → **无线调试** → 打开 → 点 **使用配对码配对设备**，记下 IP、端口和配对码。
3. 在电脑上运行 `adb pair <IP>:<配对端口>`，输入配对码。每台电脑只需配对一次。
4. 再运行 `adb connect <IP>:<端口>`。注意这里的端口要用"无线调试"主页面上显示的那个，不是配对端口。

不用的时候请关掉无线调试。

<!-- ⚠️ 依赖 D1：B1 落地的那一版起，镜像不再预设 persist.adb.tcp.port、ro.adb.secure=1、ro.debuggable=0。 -->
> **v0.7.1 及更早的版本**：镜像默认在 5555 端口开着**不需要授权**的网络 adb。同一个网络里的任何人都能直接连上并拿到 root。
> 1.0 已经关掉了它。还在用旧版本的话，请尽快更新，并且不要连接不信任的 Wi-Fi。

### `adb root` 用不了？
从 1.0 起，发布版不再支持 `adb root`。需要 root shell 时，先在 ReSukiSU 管理器里给 **Shell** 授权，然后用 `adb shell su`。

# scripts/live —— 救援系统 / LiveCD 构建

设计与取舍见 [`docs/stage7-live-installer.md`](../../docs/stage7-live-installer.md)。
这里只讲怎么用和有哪些坑。

## 一句话

**救援系统和 LiveCD 是同一套镜像的两个 profile。** 底座 **Debian 13 trixie arm64**
（2026-09-25 从 Alpine 换过来：图形安装器改用 Flutter，而 Flutter 引擎只有 glibc 版），
整个系统跑在内存里（只读 squashfs + tmpfs overlay），所以救援系统**不再需要一个 24.6 GiB 的分区**。

| profile | 内容 | 落在哪 |
|---|---|---|
| `rescue` | 无图形：ssh + 分区/文件系统工具 | 内置盘的一个小分区（`gk3rescue`，1 GiB） |
| `live`   | `rescue` + 图形安装器（Flutter + cage） | U 盘 |

## 用法（在 Mac 上，全部在 arm64 容器里原生跑，不需要构建机）

```sh
colima start                                              # 第一次
bash scripts/live/build-flutter.sh                        # 图形安装器 → out/installer-flutter-linux-arm64/
bash scripts/live/build-live.sh --boot-img <boot.img> [--m0]          # → out/live/gaokun3-live.img
bash scripts/live/build-live.sh --release <发布目录> --payload        # 带上安装载荷，装机不用联网
bash scripts/live/build-live.sh --profile rescue --boot-img <boot.img> --ssh-key ~/.ssh/id_ed25519.pub
```

`build-live.sh` 在一个特权容器里依次跑 `build-rootfs.sh`（mmdebstrap）→ `build-initramfs.sh` →
拆 boot.img（内核 / dtb / 内核参数）→ `build-usb.sh`。**内核直接用 Android 那一个**（见下）。
装了哪些包的哪个版本写进 `packages-<profile>.lock`（入库；两次构建之间 diff 它）。

`--with-rescue` 在 live U 盘上另带一份 rescue 镜像（约 104 MiB），装机时装进救援分区的是它。
★ **凭据一律放介质上，不进镜像**：U 盘的 `gaokun3/wpa_supplicant.conf`（WiFi）与 `gaokun3/authorized_keys`
（ssh 公钥）—— live 系统开机就用它们，装机时安装器把它们带进救援分区。

`--m0` 在 U 盘上多放几个启动项，给真机 M0 在开机菜单里选：Skia（关 Impeller）、两种后端的
浸泡测试（每 5 秒把 RSS 记到 U 盘的 `gaokun3/diag/soak-*.log`）、反方向旋转。
启动证据一律写回 U 盘的 `gaokun3/diag/`（`gk3-diag`，开机 45 秒后）。

**没有 U 盘时**：`m0-internal.sh check|prepare|logs|remove` 把同一套 squashfs 与 initramfs 放到内置盘
（squashfs 进救援 Ubuntu 的 p3，initramfs 进 ESP），写同样 5 个**非默认**启动项，再用 `boot-oneshot.sh`
一次性启动进去。`prepare` 不重启、不改 default。见 `docs/stage7-flutter-debian.md` §5.6b。
**发布**：`release-installer.sh --boot-img <那一版的 boot.img> --rom <ROM 版本> --firmware <目录> [--upload <tag>]`
（随 ROM 的 release 附带，见 `docs/stage7-flutter-debian.md` §5.11）。
`m0-internal.sh payload <发布目录>` 再把安装载荷（`boot.img` · `super.img.zst` · `install-artifacts.sha256`）放到
p3 的 `gaokun3/payload/` —— live 里"使用 U 盘里的镜像"读的就是那里（M4b 用）。

## 几条不显然的设计

### 与 Android 共用同一个内核

ESP 上原来有两个内核（Android 一个、救援 Ubuntu 一个），白占 14 MiB
且要各自维护。现在救援 = **同一个 `vmlinuz.efi` + 另一个 initramfs + 另一条 cmdline**。
为此在 `kernel-config-android.sh` 里补了三项，对 Android 是惰性的：

* `SQUASHFS=y` —— ⚠️ 它**默认是 `=m`**，而 initramfs 里没有模块。
  这是本仓第 14 个「=m 坑」。
* `NTFS3_FS=y` —— 双系统安装要缩 Windows 分区。
  ⚠️ 它的 Kconfig 是 `depends on !NTFS_FS || m`，旧的 `NTFS_FS` 兼容壳开着就
  把它**钉死在 =m**，得先 `--disable NTFS_FS`。
* `NLS_UTF8=y` —— FAT 上的非 ASCII 文件名。

### initramfs 不认标签，挨个找

`initramfs-init` 不靠分区标签/UUID，而是把每个分区挂上去找
`/gaokun3/rescue.squashfs`。一份 init 同时服务 U 盘和内置盘，
**配置越少越不会因为换台机器而失效**。
先扫可移动介质再扫内置盘 —— 插着 LiveCD 启动时，用户要的是 U 盘上那一份。

### ⚠️ 失败时重启，不停在 shell

这台机器没有串口。initramfs 停在 shell 就等于要人到机器旁按电源键。
所以出错默认打印诊断 → 60 秒 → `reboot -f`，回到 systemd-boot 菜单 →
15 秒 → `default`（Android），也就是回到一个能远程接入的系统。
要停下来调试就给 `gk3.debug`。

### ⚠️ 这台机器只有 WiFi

没有网口（USB-C 扩展坞卡在 UCSI 缺陷，TODO A6）。所以
`wpa_supplicant` + `dhcpcd` + `linux-firmware-ath11k` 是**必需项**，
不是可选项 —— 少了它救援系统就是一台连不上的机器。

**凭据不进镜像**：`/etc/init.d/gk3-wifi` 优先读**启动介质上**的
`/media/gk3/gaokun3/wpa_supplicant.conf`。这样公开发布的 LiveCD 不带任何人的
WiFi 密码，而救援镜像换了 WiFi 也不用重造。
构建时注入是备选（`--wifi-conf`），本仓不收这个文件。

### 断言在打包【之前】

`build-rootfs.sh` 在 `mksquashfs` 之前逐个检查关键文件
（`sgdisk` / `resize2fs` / `ntfsresize` / **`simg2img`** / `wpa_supplicant` /
ath11k 固件 / OpenRC 的 runlevel 链接）。
理由是本仓反复吃过的亏：**包名写错时 `apk add` 的失败很容易被吞掉**，
而错误要等到镜像装到机器上、开机连不上网才暴露。

## 现状（2026-09-25，Debian）

`build-live.sh` 端到端跑通，体检全过：squashfs **185 MiB**、initramfs 4.0 MiB、U 盘镜像 **317 MiB**。
开机冒烟（`test-boot-container.sh`）只有预期内的 `gk3-wifi` 失败。⬜ 还没在真机上启动过（M0）。
详细数字与坑见 `docs/stage7-flutter-debian.md` §5.5。下面"现状（2026-08-23）"是 Alpine 版的历史。

## 现状（2026-08-23，Alpine —— 历史）

三步链路在构建机上**端到端跑通**：

| 产物 | 大小 |
|---|---|
| `gaokun3-rescue.squashfs` | **55 MiB** |
| `initramfs.img` | **648 KiB** |
| `gaokun3-live.img`（可启动 U 盘镜像） | **152 MiB** |

对比它要替掉的东西：**24.6 GiB 的 Ubuntu 救援分区**。

* ✅ 构建脚本跑通，打包前的断言全过
* ✅ **已在硬件上启动过**（Stage 7 M0）：ssh 可达、WiFi 自动连上、分区工具齐全。
  ⚠️★ 本行此前写着"还没在硬件上启动过"，**已过时**（2026-09-10 对账更正）。
  ⚠️ 上面那张表里的 `initramfs.img` **648 KiB 也是旧数**：实际是 **2.7 MiB** ——
  内建 ath11k 在 initramfs 阶段就 probe（t=1.19s，远早于 switch_root）却拿不到
  固件，所以固件必须打进 initramfs。这不是膨胀，是修复。
* ⬜ 图形安装器（`live` profile）还没写
  ⚠️ 本行已过时：C 版图形安装器 2026-08 写过（`live/installer/`），
  2026-09-24 决定改为 Flutter + Debian（`docs/stage7-flutter-debian.md`）；C 版 2026-09-26 删掉
  （`git show 445e978:live/installer/…`），`gen-strings.py` 一起删。
* ✅ ~~`install-gaokun3.sh` 还是"清空整盘"一条路，未拆成可调用的库~~
  2026-09-24：命令行版改成 `installer-lib.sh` 外面的一层薄壳，见下一节。

## 安装器后端（`installer-lib.sh`）与它的测试

两个前端（`scripts/install-gaokun3.sh` 命令行、图形安装器）共用这一份实现。
协议、每个函数的输入输出写在 `installer-lib.sh` 文件头。它调用三个小工具，
与它放在同一目录（live 镜像里是 `/usr/share/gaokun3/`）：

| 文件 | 做什么 | 为什么不用现成的 |
|---|---|---|
| `gk3-unsparse.py` | 把 sparse 镜像从 stdin **顺序**展开写到分区，边写边报进度 | `simg2img` 接受 `-` 但**喂管道会失败**（`sparse_read.cpp:103` 导入时要 lseek）——而发版产物是 `.zst`，不走管道就得先落一份 12 GiB 的临时文件 |
| `gk3-bootimg.py` | 把 boot.img（v2）拆成 `Image` / `gaokun3.dtb` / `ramdisk.img` / `cmdline.txt` | systemd-boot 只认 ESP 上的普通文件；与设备侧 `bootimg_extract.cpp` 是同一件事的两个实现，必须逐字节相同 |
| `gk3-wpa-scan.py` | 解析 `wpa_cli scan_results` | 中文 SSID 在里面全是 `\xNN` 转义，而且那是制表符分隔的 —— 原来的 awk 两样都处理错 |
| `gk3-misc`（2026-10-05，S10） | `init`：清零后的 misc 写初始 A/B 状态（`_a` 15/6、`_b` 0/0）与 GK3 记录 | 布局只在 libgk3core 里有一份（入口、HAL、执行端共用）；源码 `tools/gk3boot/misc/gk3-misc.c`，`build-rootfs.sh` 静态编进镜像，仓库里跑时 `gk3__misc_tool` 用 cc 现编 |

测试（全部绿了才动 `installer-lib.sh`）：

```sh
bash scripts/live/test-plan.sh          # 方案计算：不重叠、不越界（任何机器）
bash scripts/live/test-unsparse.sh      # sparse 展开，含截断输入必须失败（任何机器）
bash scripts/live/test-wpa-scan.sh      # 中文 / GBK / 空格 / 引号 SSID（任何机器）
bash scripts/live/test-wifi-connect.sh  # 连接时对 wpa_cli 说了什么：隐藏网络的 scan_ssid、SSID 32 字节上限（桩，任何机器）
bash scripts/live/test-boot-android.sh  # 救援里的 gk3-boot-android：选直连条目、OneShot 变量逐字节（假 ESP + 假 efivarfs，任何机器）
# 下面要 root + loop 设备：在 Linux 容器里跑（macOS 上先 colima start）
bash scripts/live/test-in-container.sh scripts/live/test-unsparse.sh   # 多一轮与真 simg2img 交叉比对
bash scripts/live/test-in-container.sh scripts/live/test-apply.sh      # 端到端真装：整盘 / 双系统 / 反例
bash scripts/live/test-in-container.sh scripts/live/test-shrink.sh
# Rust 版后端（tools/gk3-installer，并行轨道，docs/installer-rust-design.md）与本库对拍：先 bash tools/gk3-installer/build.sh musl
GK3_TEST_DUEL=/repo/tools/gk3-installer/target/aarch64-unknown-linux-musl/release/gk3-installer \
    bash scripts/live/test-in-container.sh scripts/live/test-duel.sh     # 边角盘 + 纯计算
GK3_TEST_DUEL=/repo/tools/gk3-installer/target/aarch64-unknown-linux-musl/release/gk3-installer \
    bash scripts/live/test-in-container.sh scripts/live/test-apply.sh    # test-apply 的每个场景点上顺带对拍（不设就不对拍）
```

`test-apply.sh` 在 loop 设备上把命令行版和 `gk3_apply` 各真装一遍，逐项核对
（分区、super 逐字节、两个槽、启动项 options 与 boot.img 的 cmdline 一致、
双系统时 Windows 那几个分区逐字节未变、PARTUUID 未变、ESP 没被格式化……），
再验一组必须**在动盘之前**就拒绝的反例（截断的 .zst、sha256 不符、
Windows 默认的 100 MiB ESP、在已装过的盘上再装一次）。每次装完都核对 misc 的前 64 KiB 与独立算的初始状态逐字节相同。
K 组是双系统专项（S10 / S15，`tools/gk3boot/README.md` §17）：Windows 休眠拒绝写 ESP、BitLocker + 换 BOOTAA64 要
`--bitlocker-key yes`、32 MiB 余量、Windows 为默认写进 GK3 的 `set_default`、`timeout 5`、`LoaderEntryDefault` 被删
（假 efivarfs：`GK3_EFIVARS=<目录>`）、重新安装删掉统一启动入口的条目、字节相同的 BOOTAA64 不重写。
⚠️ 测试环境要 gcc（`test-env.Dockerfile`，给 `gk3__misc_tool` 现编 gk3-misc）。
`GK3_TEST_BOOTIMG=/repo/out/…/boot.img` 可以换成真发版的 boot.img。

★ 它第一次跑就抓到：**双系统模式从来装不上**——`gk3_apply` 在写完分区表之后
才按名字找 `esp`，而 Windows 的 ESP 叫 `EFI system partition`。真盘上验过的
只是方案计算，双系统的 apply 此前从没真跑过。

## 这一轮踩到的坑（都值得记）

### ★★ 在 chroot 外面检查符号链接 —— 一个原因造出 5 个假失败

第一版体检写的是 `[ -e "$ROOTFS/sbin/init" ]`。而 Alpine 的 `/sbin/init` 是一个
**指向 `/bin/busybox` 的绝对符号链接**，从宿主看它解析到**宿主的** `/bin/busybox`
—— Ubuntu 上没这个文件，于是好端端的东西被判成"缺失"。
`/etc/runlevels/default/*` 同理（指向 `/etc/init.d/*`）。
6 个失败里 5 个是这一个原因。

**修法**：所有检查都在 chroot 里跑，而且查**命令**（`command -v`）而不是**路径** ——
`sgdisk` 在 `/usr/bin`、`mkfs.vfat` 在 `/sbin`，这种事不该由我们来记。

### ★ `ls a b`：只要有一个 glob 不匹配就整体非零

固件检查写成 `ls /lib/firmware/... /usr/lib/firmware/...`，而本机只有前者，
于是**固件明明在**却被判缺失。候选路径要**逐个**试，不能塞进同一个 `ls`。

### ★ `static-pie linked` ≠ `statically linked`

initramfs 构建器断言 busybox 必须静态，模式写的是 `*statically*`。
Alpine 的 `busybox-static` 是 **static-pie**，`file` 报 `static-pie linked`，
于是一个完全正确的二进制被拒了。
**教训：把【失败条件】写清楚（"是不是动态链接"），比枚举成功条件可靠。**

### ★ `sgdisk` 是独立子包

`gptfdisk` 只给 `gdisk`。我核对过 `sgdisk` 这个包名存在，**却忘了加进列表** ——
而安装器全靠它分区。这正是"打包前逐项断言"的价值：不然要等镜像装到机器上、
分区那一步才炸。

### ★ `android-tools` 会拖进 protobuf + abseil-cpp

我们只要 `simg2img` 一个命令，用**子包 `android-tools-simg2img`**。
整包会把 226 个依赖里的一大半带进来，而这个镜像的体积目标是 ≤120 MiB。

### ⚠️ 又一次：管道吞掉退出码

`cmd | sed ...; echo $?` 拿到的是 `sed` 的退出码 —— 一次 9 个 `mkdir` 全失败
却报 `RC=0`。本仓在 `make ... | tail` 上记过同一个坑，这次是在临时的运行器里
复发的。**取退出码就别接管道。**

### ⚠️ 运维：构建机 ssh 反复掉线时走 `az vm run-command`

本轮 ssh/scp 连续失败十几分钟（Azure 报 running，实测 125 GiB 内存、
load 0.05、sshd active，机器本身完全空闲）。
`az vm run-command invoke --scripts @文件` 走的是 VM agent，**不依赖 ssh**，
可以送文件（base64）也可以同步跑构建并拿回输出。
⚠️ 它的输出在 Windows 上会被 gbk 转码吃掉非 ASCII 字符，日志里带中文的话
要 `sed 's/[^[:print:]]//g'` 或者只 grep ASCII。

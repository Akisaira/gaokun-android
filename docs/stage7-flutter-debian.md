# Stage 7（续）：图形安装器转 Flutter + Debian

> **状态（2026-09-24）**：用户决定重启 Stage 7（⏸ 自 2026-08-23，TODO B4/B7），
> 选型 **Flutter + Debian**。
> ✅ **M1 后端统一完成**：命令行版改成 `installer-lib.sh` 的薄壳；loop 设备端到端
> **46/46**（整盘 + 双系统 + 反例，合成与 v0.6.2 真 boot.img 各一遍），
> 另有 sparse 13/13、WiFi 扫描 9/9、方案计算 8/8、缩分区 8/8。
> ★ 端到端测试第一次跑就抓到**双系统模式从来装不上**（§3.1）。
> ⬜ M0（真机打一枪：Debian + mesa + cage + Flutter 能否出画面）要回家后做 ——
> 本机当时在 `10.187.160.x`，设备在家里的 `192.168.10.x`。
> ⬜ M2 Flutter 骨架（在 Mac 上，不依赖设备）。
>
> 前情：[`stage7-live-installer.md`](stage7-live-installer.md)（C + cairo 直画 DRM 的
> 设计与 M0）、[`stage7-installer-roadmap.md`](stage7-installer-roadmap.md)（用户 9 条需求
> 与搁置时的接手说明）。那两份里被这份推翻的，以这份为准。

---

## 0. 定下来的四条（用户 2026-09-24）

| # | 决定 | 代价 / 注意 |
|---|---|---|
| 1 | **退役 C 版安装器**（`live/installer/`，20 屏，真机跑通过） | 退役排在最后一步（M5）：在 M0 证明新栈能出画面之前删掉唯一能跑的前端没有好处 |
| 2 | 渲染 = **官方 `flutter_linux`（GTK）+ cage** | 正是原设计 §3 方案 B 否掉的那条（"合成器能出的问题比界面还多"）。要 mesa/freedreno 在 Debian 用户态可用 —— **Stage 5 只在 Android 侧验过**，M0 专打这一枪 |
| 3 | rescue 与 live **统一 Debian** | rescue 从 55 MiB 涨到 Debian 量级（预计 150–250 MiB），1 GiB 分区够 |
| 4 | live 镜像预算 **~800 MiB**（不含 payload） | 原目标 ≤400 MiB |

**为什么是 Debian 而不是留在 Alpine**：Flutter 官方引擎只有 glibc 版，Alpine 是 musl。
选了 Flutter 就必须离开 Alpine。原设计选 Alpine 的理由是体积（"Debian minbase
光 rootfs 就 120 MiB"），这条已由决定 4 放宽。

**为什么 Flutter 对这个项目特别合适**：开发机是 Apple Silicon Mac，Flutter 应用能在
macOS 上原生跑 —— 直接满足 C 版 README 那条铁律"没有离线渲染，改一行文案都要排队
等上机"（目标机是用户的日用平板）；arm64 Linux 产物也能在 Mac 上的 arm64 容器里
原生构建，用不到 x86 的构建机。

## 1. 结构

```
live/installer-flutter/          界面与流程（Dart）—— 不实现任何分区逻辑
  └─ Gk3Backend
       ├─ ShellBackend           bash -c '. installer-lib.sh && gk3_xxx …'
       └─ FixtureBackend         回放录好的输出（Mac 上开发、golden 测试）
scripts/live/installer-lib.sh    唯一的分区 / 写盘实现
  ├─ gk3-unsparse.py / gk3-bootimg.py / gk3-wpa-scan.py
  └─ 也被 scripts/install-gaokun3.sh（命令行）source
```

**协议**（`installer-lib.sh` 文件头）：stdout 是 `TYPE k=v k=v` 行记录；stderr 是人看的
日志与 `PROGRESS <百分比> <说明>`。**值里没有空格**：自由文本字段（分区名、卷标、
磁盘型号、SSID）一律百分号编码。解析 = 按空格切 + 每个值 %-解码，没有别的规则。

## 2. 里程碑

| | 内容 | 在哪做 | 状态 |
|---|---|---|---|
| M0 | Debian + mesa + cage + hello-world Flutter 在真机上出画面：方向、触摸、键盘、`chvt 2`、**10 分钟 RSS 曲线**、Impeller 与 Skia 各一遍 | 真机（U 盘，不碰内置盘） | ⬜ 要回家、要用户同意重启 |
| M0.5 | 内核补 systemd 要的 config 并断言 | 构建机 | ⬜ 名字已从 Debian 6.12 源码核对（§3.6），要对真树再核 |
| **M1** | **后端统一与补齐** | Mac + 容器 | **✅ 2026-09-24** |
| M2 | Flutter 骨架 + fixture 后端 + golden 测试 | Mac | ⬜ |
| M3 | Debian 构建链（mmdebstrap）+ 接真后端 | Mac 上的 arm64 容器 | ⬜ |
| M4a | 装到**外接 USB 盘**并从它启动进 Android | 真机，零风险 | ⬜ |
| M4b | 内置盘 | 真机，⚠️ **现在没有回落槽**（`_a` 不可启动，#122 §1） | ⬜ 需用户单独点头 |
| M4.5 | 救援系统迁移（先并列、验过、再删 p3） | 真机 | ⬜ |
| M5 | roadmap 欠的 5 条 + 退役 C 版 + 文档 | — | ⬜ |

## 3. M1：这一轮实测抓到的东西

### 3.1 ★★★ 双系统模式从来装不上

`gk3_apply` 在**写完分区表之后**按 PARTLABEL 找名叫 `esp` 的分区（原 `installer-lib.sh:410`），
而 Windows 建的 ESP 叫 `EFI system partition`。于是在任何一台 Windows 机器上都必然失败，
并留下 6 个建了一半的空分区（分区表备份在，能还原）。

为什么一直没发现：`stage7-installer-roadmap.md:96-98` 说"后端 probe/plan 真实磁盘验过、
apply loop 设备端到端验过"—— **两句都对，但拼不出"双系统能装"**：真盘上验的是
`gk3_plan`（纯计算），loop 上跑的 apply 只有整盘模式。

修：双系统时直接用 `--esp`；ESP 的块设备 / vfat / 分区类型 / 剩余空间检查全部挪到
第一次写盘**之前**。顺带：Windows 默认的 **100 MiB ESP 放不下**我们要的 150 MiB ——
这在真实世界里是最常见的"装不了"，现在在动盘之前拒绝，界面上要把它说成人话。

★ 教训：**"组件 A 验过、组件 B 验过"不等于"A∘B 验过"。** 端到端测试的价值就在这里。

### 3.2 `simg2img` 接受 `-`，但喂管道会失败

`refs/lineage-system-core/libsparse/sparse_read.cpp:103`：导入 RAW 块时只调
`sparse_file_add_fd(s, fd, GetOffset(), …)` 记偏移、写出时再回头读；`GetOffset()`
是 `lseek64(fd, 0, SEEK_CUR)`（`:96`），`:237` 还要 `Seek(len)`。管道上 lseek 是 ESPIPE。
容器里实测确认（`test-unsparse.sh` 把这件事本身钉成了一条测试，上游哪天修了会提醒）。

发版产物是 `super.img.zst`，全仓此前没有任何 `.zst` 处理 —— `docs/INSTALL.md` 那句
"the installer also accepts the .zst directly"是假的。现在 `gk3-unsparse.py` 顺序读 stdin，
`zstd -dc | gk3-unsparse.py <分区>`，不占临时空间；顺带在写 12 GiB 的几分钟里每 1%
报一次进度（simg2img 一声不吭）。与真 `img2simg`/`simg2img` 三方 sha256 一致。

### 3.3 两份实现的漂移清单（D1）

| | 命令行版（原） | lib（原） | 现在 |
|---|---|---|---|
| 救援分区 | `rescue` 24 GiB，克隆正在跑的 live 系统 | `gk3rescue` 1 GiB squashfs | 后者，有镜像才装 |
| `loader.conf` default | 救援 | `*-android-a.conf` | 后者（HAL 第一次开机就会改成 Android，前者只活到第一次开机） |
| cmdline | 从 boot.img 取（`914cd5b`） | **手抄且过时**（缺 `boot_devices`、`init=/init`、`disable_pressure=0`） | 从 boot.img 取 |
| 救援条目 cmdline | — | 手抄，缺 `usbhid.quirks`（键盘盖） | 从 boot.img 派生、去掉 `androidboot.*` |
| 内核文件来源 | 拆 boot.img | 要求发布目录里有散装文件（**发版不带**） | 拆 boot.img（`gk3-bootimg.py`） |
| super 写完验 LP 魔数 | 有 | 没有 | 有 |
| ESP 挂载点 | **`/mnt/esp`**（CLAUDE.md 操作禁忌 4） | mktemp | mktemp |

### 3.4 输入在动盘之前验完

原先 systemd-boot 与内核文件的检查排在写完 super 之后；截断的 `.zst` 能通过所有检查、
写到一半才暴露。现在：boot.img 当场解包（拆不开 = 盘没动）、有 `install-artifacts.sha256`
就先核 sha256、没有就 `zstd -t`。`test-apply.sh` 的 C 组把每一种都钉成了"拒绝且盘一个字节没变"。

### 3.5 WiFi：中文 SSID 与 8–63 字符

wpa_supplicant 用 `printf_encode` 输出 SSID（wpa-2.10 `src/utils/common.c:477-523`）：
32–126 之外每个字节都是 `\xNN` —— 中文 SSID 在 C 版里显示成转义串；`scan_results` 是
制表符分隔（`ctrl_iface.c:3008,3142`），原 awk 按空白切再用单空格拼回，"My  Net" 连不上。
连接改传十六进制 SSID（不带引号即十六进制，`common.c:679-686`）。UTF-8 解不开再试
GB18030（老路由器的 GBK SSID）。密码长度必须 8–63（`wpa_supplicant/config.c:571`），
原先 `set_network` 的返回值被扔掉，密码太短要白等 20 秒超时。

连上之后配置写到 `/run/gaokun3/wpa_supplicant.conf`，`gk3_apply` 把它装进救援分区 ——
否则装好的救援系统"起来了但网没起来 = 一台连不上的机器"（`stage7-live-installer.md:200-202`）。

### 3.6 其它

* **`lsblk -o PARTTYPE` 没有 udev 就是空串**（容器里实测），`blkid -p` 直接读分区表。
  lib 在 `gk3__bylabel` 的注释里早说过"没有 udev 时直接问底层"，新代码又踩了一次。
* **bash 3.2（macOS）把紧贴变量的全角字符读进变量名**：`"$n：…"` → `unbound variable`。
  中文紧贴变量时一律写 `${n}`。
* 预检：型号 / BIOS 读 `/sys/class/dmi/id/{product_name,bios_version}`
  （`drivers/firmware/dmi-id.c:42-47`，`CONFIG_DMIID` 在 `drivers/firmware/Kconfig:70`、
  默认 y），读不到退回 dmesg 的 `Hardware name:` 行（`hw-inventory.md:33` 原文）。
  Secure Boot 读 `SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c`
  （`EFI_GLOBAL_VARIABLE_GUID`，`include/linux/efi.h:368`）。以上名字取自 **Debian 6.12**
  的源码 —— 本地 `refs/` 里的内核树是稀疏 checkout，没有这些文件。
* 拒绝 BIOS 2.17 的理由改成"未验证"，**不再说"SPI/GPIO 不同"**（#120 §4：那份 DSDT_217
  是 SC8180X 的表）。`GK3_SKIP_BIOS_CHECK=1` 放行。

## 4. 风险（按"会不会让方案作废"排序）

1. 🔴 mesa/freedreno 在 Debian arm64 用户态不可用 → 回落 `FLUTTER_LINUX_RENDERER=software`
2. 🔴 GTK embedder 在 ARM GLES + Wayland 上有已知逐帧泄漏
   （[flutter/flutter#192603](https://github.com/flutter/flutter/issues/192603)，描述的组合正是我们这套）
   → M0 必须量 RSS 曲线，不是"看着能跑"
3. 🟡 Impeller 在弱 GPU 上闪烁（[#192915](https://github.com/flutter/flutter/issues/192915)）→ M0 两条后端都测
4. 🟡 体积、rescue 变大、Flutter 是本仓第一个要联网拉依赖才能构建的子项目
5. 🟢 `chvt 2` 逃生口在 Wayland 下失效 → M0 顺带验

外部 issue 是别人项目的现状，不是本仓实测；M0 的实测推翻它们时以实测为准。

## 5. 对外可见的变化（未推送）

* `docs/INSTALL.md`：命令行安装器现在需要一份仓库 checkout（它 source `scripts/live/`）；
  `.zst` 不用先解压；**从通用 Ubuntu/Debian live U 盘安装时没有救援系统了**
  （原先的 24 GiB 克隆救援已删，新的救援镜像要等我们的 live U 盘发布）。

# Stage 7（续）：图形安装器转 Flutter + Debian

> **状态（2026-09-24）**：用户决定重启 Stage 7（⏸ 自 2026-08-23，TODO B4/B7），
> 选型 **Flutter + Debian**。
> ✅ **M1 后端统一完成**：命令行版改成 `installer-lib.sh` 的薄壳；loop 设备端到端
> **46/46**（整盘 + 双系统 + 反例，合成与 v0.6.2 真 boot.img 各一遍），
> 另有 sparse 13/13、WiFi 扫描 9/9、方案计算 8/8、缩分区 8/8。
> ★ 端到端测试第一次跑就抓到**双系统模式从来装不上**（§3.1）。
> ✅ **M0 六项验收全过**（2026-09-25/26，没有 U 盘 ⇒ 放在内置盘上 oneshot 启动，六轮，§5.6b / §5.7）。
> ✅ **M2 Flutter 骨架完成**（2026-09-25）：13 屏对着真后端录的 fixture 在 Mac 上走通，
> 测试 42/42（协议 17 · 流程 8 · 文案约定 2 · 出图 15），离线出图 19 张 —— 看图抓到
> **占位符参数填反**（§4.1）。后端这轮又补了 `gk3_esp_info` / `gk3_release_info` / `gk3_net_release`
> （网络安装接进同一条写盘路径），loop 端到端到 **55/55**。
> ▶ M3 进行中。✅ **Linux arm64 构建成立**（Mac 上 arm64 容器原生构建，产物 22 MiB）；✅ **真程序在
> headless cage 里跑起来**：无标题栏全屏、`wlr-randr` 设 2560×1600 缩放 2 生效、Impeller / Skia 都能出帧
> （软件渲染下 61 fps、1 分钟 RSS 无单调增长）。抓到：**中文全是方块**（Flutter 不按字符回退系统字体，§5.1）。
> ✅ **Debian live 镜像造出来了**（2026-09-25）：mmdebstrap 355 个包，squashfs **185 MiB**、U 盘镜像
> **317 MiB**（含 25% 余量；预算 800），构建前的体检全过；开机冒烟（squashfs 当容器根、systemd 为 PID 1）
> 只有预期内的 `gk3-wifi` 失败，ssh 开机现生成主机密钥并在听。U 盘上带 M0 的 4 个变体启动项。
> ✅ **M4b 第一次真的装了一台**（2026-09-26，内置盘上的 live → 重新安装 + 保留数据，约 3 分钟，数据原样，§5.9）。
> ⬜ 还没验：清除数据 / 整盘 / 双系统（后两者本机没有合适的盘面，M4a 要外接 USB 盘）；M4.5 救援迁移。
>
> 前情：[`stage7-live-installer.md`](stage7-live-installer.md)（C + cairo 直画 DRM 的
> 设计与 M0）、[`stage7-installer-roadmap.md`](stage7-installer-roadmap.md)（用户 9 条需求
> 与搁置时的接手说明）。那两份里被这份推翻的，以这份为准。

---

## 0. 定下来的四条（用户 2026-09-24）

| # | 决定 | 代价 / 注意 |
|---|---|---|
| 1 | **退役 C 版安装器**（`live/installer/`，20 屏，真机跑通过） | 退役排在 M0 之后：在证明新栈能出画面之前删掉唯一能跑的前端没有好处。✅ **2026-09-26 M0 过了、已删**（连同 `scripts/live/gen-strings.py`；最后一版 `git show 445e978:live/installer/…`） |
| 2 | 渲染 = **官方 `flutter_linux`（GTK）+ cage** | 正是原设计 §3 方案 B 否掉的那条（"合成器能出的问题比界面还多"）。要 mesa/freedreno 在 Debian 用户态可用 —— **Stage 5 只在 Android 侧验过**，M0 专打这一枪 |
| 3 | rescue 与 live **统一 Debian** | rescue 从 55 MiB 涨到 Debian 量级（预计 150–250 MiB），1 GiB 分区够 |
| 4 | live 镜像预算 **~800 MiB**（不含 payload） | 原目标 ≤400 MiB |

**用户 2026-09-25 追加的两条**（M0 第二轮之后）：

| # | 要求 | 影响 |
|---|---|---|
| 5 | **LiveCD 的初衷之一是免 U 盘安装，并且要支持双系统** | "介质与目标同盘"成为正经流程：live 从内置盘的某个分区起来、装进同一块盘的空闲区。原先内置盘一旦是介质就整盘禁用 —— 改成**只禁整盘清空、介质分区不可缩，双系统放行**（§5.8）。新用户手上是 Windows，所以还缺"在 Windows 里把 live 放上内置盘"那一半（§5.8，✅ PowerShell 脚本，虚拟机里整条跑通） |
| 6 | **去掉 BIOS 版本限制**：有人验证过，不依赖 BIOS 版本 | 预检只报版本号、永远 ok（bug 报告要它）；`GK3_SKIP_BIOS_CHECK` 删掉；界面、命令行版、INSTALL.md 同步 |
| 7 | **界面改成 Material Design 3**（"一点也不 material design"） | 颜色只用 MD3 的角色（`ColorScheme.fromSeed`，成功 / 警告按 MD3 自定义颜色调和）；大屏布局 = 左侧步骤栏 + 内容；MD3 按钮 / 可选卡片 / 描边输入框 / 2024 版进度条。字体 Roboto + Noto Sans CJK SC **打包进应用**（不再靠 fontconfig 回退 —— 真机中文方块那次的根治），可变字重要显式给 `FontVariation`。触摸目标按 MD3 下限（48 dp ≈ 本机 37 逻辑像素）收到 56 / 72，不再是 C 版的 88。Linux 版 53 MiB（字体占 31 MiB） |
| 8 | **加"重新安装 Android"，默认清除数据**（M0 上机时两种方式都灰：这台机器整盘是 Android、又是安装器所在的盘） | `gk3_plan/gk3_apply --mode reinstall`：不改分区表，按 PARTLABEL 复用现有的 misc / metadata / boot_a / boot_b / super / userdata（/ gk3rescue），每个名字必须恰好一个、大小够；默认格式化 userdata 与 metadata，`--keep-data yes` 保留（换旧版本时可能起不来）；要写的分区挂着就拒绝（安装器所在的那个）；ESP 按"覆盖自己的文件"只要 16 MiB。loop 端到端 20 项（写坏后重写、分区表逐字节不变、保留 / 清除、挂着拒绝、缺分区报名字）→ test-apply 91/91；界面 50/50 |
| 9 | **加"手动调整磁盘"页，"能给的都给"**（重装被"misc 太小"拦住时用户提的；那一次其实是方案检查的 bug —— misc 按 MiB 取整成 0，已修） | 参考别的安装器：入口学 Ubuntu（安装方式页最后一项进手动分区），执行学 Windows 安装程序（每个操作单独按住确认、立即生效）。删除 / 新建 / 格式化 / 缩小 / 扩大（`gk3_part_*`）：ESP 与挂着的分区不动并写明原因、动手前备份分区表、删除不抹数据、新建必须落在空闲区里且对齐、扩大只并紧挨在后面的空闲并保住 PARTUUID。test-apply G 节 12 项 → 107/107；界面 56/56（新增 5 条） |

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
| **M0** | **Debian + mesa + cage + Flutter 在真机上出画面：方向、触摸、键盘、`chvt 2`、10 分钟 RSS 曲线、Impeller 与 Skia 各一遍** | 真机（没有 U 盘 ⇒ 内置盘 + oneshot，§5.6b） | **✅ 2026-09-26**（§5.7）|
| M0.5 | 内核能不能跑 systemd | 离线 | ✅ **能**（2026-09-25，§5.3）—— 不挡 M0；`AUTOFS_FS=y` 下次编内核时顺带 |
| **M1** | **后端统一与补齐** | Mac + 容器 | **✅ 2026-09-24** |
| **M2** | **Flutter 骨架 + fixture 后端 + 出图** | Mac | **✅ 2026-09-25** |
| **M3** | **Debian 构建链（mmdebstrap）+ 接真后端** | Mac 上的 arm64 容器 | **✅ 2026-09-25**（§5.5）—— 真后端的写盘路径由 M4a 在真机上验 |
| M4a | 装到**外接 USB 盘**并从它启动进 Android | 真机，零风险 | ⬜ |
| **M4b** | **内置盘** | 真机，⚠️ **现在没有回落槽**（`_a` 不可启动，#122 §1） | **✅ 2026-09-26 重新安装 + 保留数据，同版本 `1790206017`，数据逐项核对原样（§5.9）；09-27 网络来源再装一次同样原样（§5.10）**。★ 2026-09-26 核对：本机整盘是 Android ⇒ **双系统必被 PARTLABEL 查重拒绝**（fixture `android`），计划里"缩 /data 再装双系统"那条路在本机走不通 ⇒ M4b = **重新安装**模式。安全网：`gk3_apply` 只改写 `*-android-{a,b}.conf` 与 `loader.conf`，内置盘上的 live 启动项（`gaokun3-m0*.conf`）与 p3 不动 —— 装坏了从开机菜单进 live 再装一次。载荷：网络安装拿到的是已发布的 v0.6.2（`1789570683`）；设备上是未发布的 `1790206017`，要"同版本、保留数据"得先把它的 `boot.img` + `super.img.zst` 放到 p3 |
| M4.5 | 救援系统迁移（先并列、验过、再删 p3） | 真机 | ⬜ |
| M5 | roadmap 欠的 5 条 + 退役 C 版 + 文档 | — | ▶ roadmap 第 1–4 条 Flutter 版都做了（两步式 WiFi 与信号格数、网络安装接进 apply、分区大小回灌 `--userdata-mib`、"已分配 / 共"读 `PLANSUM`）；第 1 条最后一项**隐藏网络** 2026-09-26 补上（后端 `gk3_wifi_connect … hidden` → `scan_ssid=1`，`test-wifi-connect.sh` 12/12，界面 58/58）。第 5 条就是 M4。✅ 退役 C 版（2026-09-26）。⬜ 文档（INSTALL.md / README 的救援描述要等 M4.5） |

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

## 4. M2：这一轮实测抓到的东西

### 4.1 ★★ 占位符参数填反，测试全绿，看图才发现

gen-l10n 生成的方法参数顺序 = 模板 ARB 里 `@元数据` 的顺序。我生成 ARB 时按字母序写元数据，
于是 `modeWhyNoRoom(need, have)` 实际签名是 `(have, need)` —— 8 条多占位符文案里 **6 条填反**，
界面上是"可用空间不足 **0 MiB**（现有最大的一块是 **21.2 GiB**）"、"创建 **/dev/nvme0n1p1** 的分区……
EFI 分区 **80 GiB**"。流程测试全绿，因为断言写的是 `find.text(l.netConnected(a, b))` —— **测试与代码
用同样错的顺序调同一个函数**，永远相等。

修：元数据按出现顺序生成；`test/l10n_test.dart` 钉住这条约定；流程测试改为断言**渲染出来的文字**
（`'EFI 分区 /dev/nvme0n1p1'`）。★ 教训：断言要落在用户看到的东西上，而不是落在"用同一个函数再算一遍"上。
这也是离线出图不可省的理由 —— C 版 README 说它是"这个安装器能被开发出来的前提"，这一轮应验了。

### 4.2 其它

* **fixture 由真后端在容器里录**（`scripts/live/gen-fixtures.sh`），不手写。录的过程本身又抓到两个后端 bug：
  `GK3_SDBOOT` 只在文件恰好叫 `systemd-bootaa64.efi` 时才生效；`gk3_apply`/`gk3_shrink` 把人看的话 echo 到 stdout。
* **测试里 `rootBundle` 会跨测试卡死**：它缓存 `loadString` 的 Future，上一个测试没飞完的读取挂在那个
  测试的 FakeAsync 区里永远完成不了。单独跑全过、一起跑 7 条挂 6 条。改为同步读盘的 `DiskBundle`。
* **C 版文案里的 `\n` 是给固定宽度的 cairo 排版准备的**，Flutter 自动折行后叠上硬换行就成了"将为你启动\n系统，\n内核"。
* 测试脚本自己的坑：`new_disk` 在 `$(…)` 里调、往数组里加的 loop 设备留在子 shell 里 ⇒ 一个都没解绑，
  攒了 58 个把 colima 的 98G 盘写满（`gen-fixtures` 才因"No space left"失败）。改为按镜像文件 `losetup -j` 找。
* zsh 里未加引号的 `$FILES` 不分词 —— 我的"扫一遍脚本"命令整串被当成一个文件名，却打印了"已无残留"。
  又一次"判据看产物，不看输出"。

## 5. M3：Linux 版第一次真跑

`scripts/live/build-flutter.sh`（arm64 容器里 `flutter build linux --release`）→
`scripts/live/test-render.sh`（运行时镜像里起 headless cage、截图、记 RSS）。

### 5.1 ★★ 中文全是方块，离线出图发现不了

运行时镜像装着 `fonts-wqy-microhei`，fontconfig 也按字符查得到它（`fc-match "sans-serif:charset=4e2d"`
→ WenQuanYi Micro Hei），但 Flutter 没回退过去 —— 拉丁字母走 DejaVu 正常，**中文全是方块**。
离线出图看不出来：出图时字体是测试里手动注册成 Roboto 的，走的根本不是这条回退路径。

修：主题里**按名字**列回退字体（`fontFamilyFallback: [WenQuanYi Micro Hei, Noto Sans CJK SC, …]`，
`lib/ui/theme.dart`）。重编后截图中文正常，与离线出图几乎逐像素一致。
为什么按字符的系统回退不起作用 —— **没有查清**（可能与 `.ttc` 字体集合有关，没验证）。
⚠️ C 版 README 警告过"写死字体名会在换字体包时静默变成方框"：所以只作回退，且 live 镜像构建时
必须断言这个字体在。★ 教训：**离线出图验的是布局与文案，验不了真实 embedder 的字体路径**；
`test-render.sh` 的截图是第二道门。

### 5.2 渲染后端的开关

* 3.47.2 在 Linux 上**默认 Impeller**（日志 `Using the Impeller rendering backend (OpenGLESSDF)`）。
* ⚠️ **release 版不读 `FLUTTER_ENGINE_SWITCHES`**：`engine/src/flutter/shell/platform/common/engine_switches.cc:16-18`
  是 `#ifndef FLUTTER_RELEASE`。容器里设了照样是 Impeller。
* 改走 embedder 的公开 API `fl_dart_project_set_enable_impeller()`（`flutter_linux/fl_dart_project.h:164-170`），
  runner 认 `GK3_RENDERER=skia`。

| 后端（llvmpipe 软件渲染，2560×1600，60 秒浸泡） | 帧率 | 光栅化 p50 / p95 | RSS |
|---|---|---|---|
| Impeller（默认） | 61 fps | 2.2 / 2.4 ms | 418–451 MB，无单调增长 |
| Skia（`GK3_RENDERER=skia`） | 61 fps | 1.5 / 1.6 ms | 377–411 MB，无单调增长 |

⚠️ 这是**软件渲染下的基线**，不是结论：flutter/flutter#192603 的逐帧泄漏说的是 ARM GLES 驱动。
真机 M0 用同一个浸泡页（`GK3_SOAK=1`）量至少 10 分钟。★ 浸泡页存在的理由：第一次量时界面停在欢迎页，
Flutter 空闲不出帧，60 秒 RSS 一动不动 —— **那条曲线什么也没测**。

### 5.3 M0.5：现有内核能跑 systemd，不必先重编

原计划要读设备上的 `/proc/config.gz`，设备不在身边。但内核开着 `CONFIG_IKCONFIG`，配置就嵌在镜像里 ——
新工具 `scripts/extract-kconfig.py` 直接从发版的 `boot.img` / `prebuilt-boot/vmlinuz.efi` 抽出来（两处抽出的
逐字节相同）。对照的是 **systemd v257 自己 README 的 REQUIREMENTS 一节**（Debian 13 带的就是 257），不凭记忆列。

* **硬性要求全部满足**：`DEVTMPFS CGROUPS INOTIFY_USER SIGNALFD TIMERFD EPOLL UNIX SYSFS PROC_FS FHANDLE`，
  以及实质必需的 `NET_NS USER_NS`；`DMIID=y`（预检读 `/sys/class/dmi/id` 在真机上成立）；UEFI 两项、
  squashfs/overlay/ntfs3/loop 都在。
* 不满足的 5 项逐条核过：`UEVENT_HELPER_PATH` —— `UEVENT_HELPER` 本身没开，等价于满足；
  `FW_LOADER_USER_HELPER=y` 但 `…_FALLBACK` 没开，只在驱动显式要求时才走用户态（不动：Android 的 ueventd 可能依赖）；
  `NET_SCH_FQ_CODEL=n` —— Debian 257 的 sysctl.d 根本没设 qdisc；`DMI_SYSFS=n` 只关 SMBIOS 凭据；
  **`AUTOFS_FS=m`**（镜像不带模块 = 没有）→ Debian 的 `proc-sys-fs-binfmt_misc.automount` 会失败一次，
  只是告警。下次编内核时在 `scripts/kernel-config-android.sh` 里改 `=y`（对 Android 惰性）。
* ⚠️ 这是 **v0.6.2 发版内核**（`7.2.0-rc2-gaokun3`，#24）的配置。设备现在跑的候选版内核若改过 config 要再抽一次。

### 5.4 cage 0.2.0

* 默认**禁止切换 VT**，`-s` 才允许 —— 不加它命令行逃生口必然失效。
* 没有旋转参数（计划里写的 `-r` 不存在）；但支持输出管理协议，`wlr-randr --custom-mode/--scale` 实测生效，
  旋转走 `--transform`（真机上验）。

### 5.5 Debian 根文件系统与 U 盘镜像

`bash scripts/live/build-live.sh --boot-img <boot.img> [--m0]`：arm64 特权容器里 mmdebstrap（Debian 13 trixie，
`main,non-free-firmware`，不装推荐包，手册/文档/翻译不进镜像）→ initramfs → 拆 boot.img → U 盘镜像。

| | 大小 |
|---|---|
| 根文件系统（展开） | 661 MB，355 个包（`scripts/live/packages-live.lock`，入库；两次构建 diff 它） |
| squashfs（zstd 19） | **185 MiB** |
| initramfs（busybox + WCN6855 固件） | 4.0 MiB |
| U 盘镜像（含 25% 余量，不含载荷） | **317 MiB** —— 预算 800，也低于 C 版当初的 ≤400 |
| 大头 | `libllvm19` 120 MB（Mesa 的软件渲染）· `firmware-atheros` 97 MB（本机只用其中 WCN6855 的 12 MB）—— 要瘦身就从这两项下手 |
| **rescue profile**（无图形） | 216 个包，squashfs **104 MiB**（计划估 150–250；1 GiB 的 `gk3rescue` 分区绰绰有余） |

体检（不过不出镜像）沿用 Alpine 版的全部断言、换成 Debian 查法，另加：**安装器的每个动态库都能解析**
（`ldd` 无 `not found`）、**主题按名字回退的 `WenQuanYi Micro Hei` 真的在**、freedreno 驱动在（`dri/msm_dri.so`
→ `libgallium` 里编进了 freedreno）、会话服务是 enabled 的（Alpine 版第一次停在 login 提示符）。

**开机冒烟**（`scripts/live/test-boot-container.sh`）：squashfs 解开当容器根，systemd 为 PID 1 跑 70 秒。
验得了单元文件与服务（这台机器没有串口，这类错误在真机上就是黑屏），验不了内核与硬件。第一次跑出
`nvmf-autoconnect.service` 失败（nvme-cli 带的 NVMe-oF 自动连接），已屏蔽；现在只剩预期内的 `gk3-wifi`（容器里没有 wlan0）。

救援系统的两处补齐（M4.5 的前置）：
* **公钥放介质上**：公开的 live 镜像不带任何人的公钥，于是从它装出来的救援系统本来【远程进不去】——而远程
  接入正是救援系统存在的意义。沿用 WiFi 凭据的同一模式：ssh 起来之前把 `/media/gk3/gaokun3/authorized_keys` 并进 `/root/.ssh`（见 §5.6b 为什么不让 sshd 直接认）；
  用户把公钥放到 U 盘的 `gaokun3/authorized_keys`，`gk3_apply` 装机时把它（或发布目录里的、或正在跑的系统自己的）
  拷进救援分区。loop 端到端验过（56/56）。
* **装进去的是 rescue profile，不是 live 本身**：`build-live.sh --with-rescue` 在 U 盘的 `gaokun3/install-rescue/`
  另放一份 rescue 镜像，`gk3_apply` 优先用它；不带的话兜底是 live 镜像本身（带图形安装器、开机 tty1 就起它）。

这一轮的坑：
* Debian trixie 的 `/etc/default/locale` 是指向 `../locale.conf` 的**悬空符号链接**，`cp` 拒绝穿过它写 —— 改为直接提供 `/etc/locale.conf`。
* M0 启动项的标题用 `printf %q` + `eval` 传进容器，Mac 的 bash 3.2 与容器的 bash 5 转义 UTF-8 不一致 ⇒ 乱码。改为逐行写文件。
* ⚠️ **开机菜单的标题改成了 ASCII**：菜单由 UEFI 固件用它自己的字体画，一般不含中文 —— 原先的中文标题
  （包括 Alpine 版的"救援系统（Alpine，全内存）"）**从没在本机菜单上看过**。没有证据时取稳妥的一侧；M0 顺便看一眼。
* U 盘启动项的内核参数原先是手抄的（B15 那一类漂移，缺 `disable_pressure`），改为从 boot.img 的 `cmdline.txt`
  派生，与装机时的救援条目用同一个函数 `gk3__rescue_cmdline`。

### 5.6 M0 在真机上要做的事（U 盘就绪，要你同意重启）

```sh
bash scripts/live/build-live.sh --boot-img out/test-bootimg/boot.img --m0   # 已构建：out/live/gaokun3-live.img
sudo dd if=out/live/gaokun3-live.img of=/dev/rdiskN bs=4m && sync            # ⚠️ 先 diskutil list 确认 N 是 U 盘
```

插 U 盘，用以前从 U 盘启动 Ubuntu 采集硬件信息时的同一种方法从 U 盘启动（固件的启动选择；⚠️ 具体按键案卷里没记，`hw-inventory.md:4` 只写了"从 U 盘启动"）→ U 盘上的 systemd-boot 菜单（10 秒）：

| 启动项 | 看什么 |
|---|---|
| `gaokun3 installer / rescue`（默认） | 出不出画面、**方向对不对**、中文正不正常、触摸点到的是不是手指下面那个按钮、键盘能不能打字、"退出到终端"能不能切到 tty2 |
| `M0: Skia (Impeller off)` | 同上，比较两种后端（#192915：Impeller 在弱 GPU 上闪烁） |
| `M0: soak test, Impeller` / `…Skia` | 放着 **至少 10 分钟**：U 盘上 `gaokun3/diag/soak-*.log` 每 5 秒一行 RSS 与帧率（#192603：逐帧泄漏） |
| `M0: rotate the other way (transform 90)` | 如果默认那个方向是反的，这个应该是对的 |

**不碰内置盘**：安装器会列出磁盘，但 M0 里不要点到"开始安装"。每次启动 45 秒后 `gk3-diag` 把状态、
dmesg（含 msm/adreno 的行）、失败的单元、还有**一张屏幕截图**写到 U 盘的 `gaokun3/diag/`。
U 盘拔下来插回 Mac 就能读。⚠️ 槽 `_a` 现在不可启动（#122 §1），U 盘起不来时拔掉即回到 `_b`。

#### 5.6b 没有 U 盘：放在内置盘上，一次性启动进去（2026-09-25）

用户手边没 U 盘。Alpine 版 M0 走的就是这条路（`docs/stage7-live-installer.md:204-224`）：squashfs 放在
**救援 Ubuntu 的 p3** 上、ESP 上一个非默认启动项、一条 `LoaderEntryOneShot` 进去。脚本
`scripts/live/m0-internal.sh` 把它做成了四步，**前两步不重启**：

```sh
bash scripts/live/m0-internal.sh check      # 只读：按内容找 p3、量 ESP 与 p3 空间、抽 slot_b 内核的 .config 核 systemd 要求、看 WiFi 配置在不在
bash scripts/live/m0-internal.sh prepare    # squashfs → p3:/gaokun3/live.squashfs，initramfs → ESP:<mid>/live/，写 5 个启动项，sha256 逐个核
bash scripts/boot-oneshot.sh gaokun3-live.conf && adb -s gaokun3 reboot   # ⚠️ 要你在场并同意（M0 时叫 gaokun3-m0.conf，2026-09-27 改名）
bash scripts/live/m0-internal.sh logs       # 回到 Android 后取 p3:/gaokun3/diag/ → out/m0/diag/
bash scripts/live/m0-internal.sh payload <发布目录>   # （M4b 加的）载荷 → p3:/gaokun3/payload/，推之前推之后各核一遍 sha256
bash scripts/live/m0-internal.sh remove     # 撤掉启动项、initramfs、live.squashfs、payload/
```

和 U 盘那条路的区别：
* **启动项复用 slot_b 的内核与 dtb**（`<mid>/android/slot_b/`），只多一个 initramfs。内核参数从 slot_b
  的启动项派生（它由 OTA postinstall 从 boot.img 同步），过滤规则与装机时的救援条目是同一个函数。
* **`gk3.dev=/dev/nvme0n1pN` 指定分区**，不让 initramfs 去扫内置盘上的每个分区（ext4 即使只读挂载也可能
  回放日志）。initramfs 为此改成**等设备节点出现**（最多 15 秒）—— NVMe 的分区节点是异步冒出来的，
  拿不到就判"不存在"会让 live 在一块好好的盘上起不来；不指定时的扫描也改成最多重扫 5 遍。
* **比 U 盘好的一点：能远程。** p3 上有 WiFi 配置的话 live 起来就连网；`prepare` 把一对开发机专用的钥匙
  （`out/m0/ssh_ed25519`，不动 `~/.ssh`）的公钥**追加**进 `p3:/gaokun3/authorized_keys`，于是浸泡数据可以
  `ssh -i out/m0/ssh_ed25519 root@<ip>` 实时看。人只需要看屏幕、摸触摸。
* **装不坏内置盘**：live 是从 nvme0n1 上的分区起来的，`gk3_probe` 把整块内置盘标成 `medium=yes`，界面禁用它，
  `gk3_apply` 的安全闸也拒绝整盘清空介质所在的盘。
* 启动项文件名是 `gaokun3-m0*.conf`，**不能**匹配 boot_control HAL 的 `*-android-*.conf`
  （`device/huawei/gaokun3/boot_control/EspSlot.cpp:42` 写 default、`:60` 认 ESP）；default 不动。
* ⚠️ 没有回落槽（`_a` 不可启动）不影响这条路：它**不碰任何 Android 分区**。live 起不来时 initramfs 60 秒后
  自己重启（或长按电源键），一次性启动已经被消费掉，回到 default 的 `_b`。

★ **`check` 在真机上查出的（2026-09-25）**：p3 的根目录（live 里就是 `/media/gk3`）属 **uid 1001**、`gaokun3/` 是 **777**
（解包 Ubuntu 根文件系统留下的）。原设计让 sshd 直接认介质上的 `gaokun3/authorized_keys`，而 StrictModes 会从公钥文件
一路查到 `/` —— 于是这把钥匙被**静默拒绝**，M0 会是一台 ssh 不进去的机器。开机冒烟里照这个实况造了一个假介质，
复现出 `Authentication refused: bad ownership or modes for directory /media/gk3/gaokun3`。
修法不是去改 p3 的权限（介质是外来的文件系统，下一块 U 盘、下一个用户的分区照样管不了），而是 **ssh 起来之前由
`gk3-ssh-keys` 把它并进 tmpfs 上的 `/root/.ssh/authorized_keys`**，sshd 只认那一份。冒烟测试现在常驻这一项。
⚠️ 换了网络后 deb.debian.org 不通、重建做不了，这一条是用 `GK3_TEST_OVERLAY=1`（已构建的根 + 工作区的 overlay）验的，
**还没进产物**。这次上机本来也 ssh 不进去（Mac 与设备不在一个网里），所以 M0 用的是之前那版镜像。

顺带修的一处：`gk3-diag` 写完诊断会把介质改回只读，而安装器会话把它改成读写、并一直开着 installer.log 与
浸泡日志。在它之后改回只读，好的情况是 EBUSY 失败，差一点就是**浸泡日志从第 45 秒起全部 EROFS** ——
M0 要的恰恰是那条 10 分钟曲线。现在只在它本来是只读时才改回去。

### 5.7 M0 上机（2026-09-25，内置盘 + oneshot，两轮）

**第一轮（14:56）**：live 起来了 —— initramfs 按 `gk3.dev` 在 `nvme0n1p3` 上找到 squashfs，systemd 起来、
失败的单元只有 gk3-wifi；触摸（Himax）与键盘（HID 12d1:10b8）都认到，DSI-1 connected（1600×2560）；
gk3-diag 按时把日志写回 p3。**但 cage 起不来**：
* `Direct firmware load for qcom/a660_sqe.fw failed with error -2` → Mesa `fd_pipe_new2: allocation failed` →
  EGL 建不了 DRI2 screen。**镜像里没有 GPU 固件**。C 版画 dumb buffer、从不碰 GPU，所以 live 以前从没缺过它；
  体检也没查（现在查了：`build-rootfs.sh` 的 `GPU_FW`）。计划里排第一的风险"freedreno 在 Debian 用户态不可用"
  **不是**这次的原因。
* systemd-udevd 把 `wlan0` 改名成 `wlP6p1s0`，gk3-wifi 只认 `wlan0` ⇒ 判"没网卡"去重绑（重绑本身无害，
  但它按厂商号把 NVMe 的根端口 `0002:00:00.0` 也列了进去 —— 写进 `ath11k_pci/unbind` 对它是空操作，改成只认网络控制器）。

**第二轮（15:45，不重建镜像）**：启动项加 `firmware_class.path=/media/gk3/gaokun3/firmware`（把本机 Android
`/vendor/firmware` 的三个 GPU 固件拷到 p3）与 `net.ifnames=0`：
* `loaded qcom/a660_sqe.fw from new location`（t=3.1 s）、`a660_gmu.bin` 同 —— GPU 起来了
* **cage + Flutter（Impeller，OpenGLES）在真机 GPU 上出画面**：欢迎页、中文字形正常（截图由 gk3-diag 用 grim 抓，
  `out/m0/diag/boot-20260925-074703.png`）；wlr-randr `transform 270 scale 2` 生效，DSI-1 跑 1600×2560@120
* 网卡名回到 `wlan0`，wpa_supplicant 起来了（周围没有配置里的网络，一直等载波 —— 预期内）
* ✅ **用户目视：方向对、触摸准**（`transform 270` 当初是推理出来的，现在是实测）。⬜ 键盘、tty2 逃生口没专门试；浸泡与 Skia 两项没跑

**第三到第六轮（22:09–00:06，用 `patch-live-installer.sh` 不联网换进新界面与新后端）—— M0 六项验收全过**：

| 验收项 | 结果 |
|---|---|
| ① 出画面、方向对 · ② 触摸准 | ✅ 第二轮起（MD3 版也在真机上截过图，与离线出图一致） |
| ③ 键盘 | ✅ WiFi 页用实体键盘输热点密码、连上 |
| ④ tty2 逃生口 | ✅ 第三轮查出镜像里**没有 chvt**（kbd 包没装，按钮点了没反应、日志里一串没人接的 ProcessException）→ 链到 busybox、界面失败时说原因；之后那一轮会话零报错 |
| ⑤ 浸泡（RSS 曲线） | ✅ 见下表：#192603 担心的逐帧泄漏**没有出现** |
| ⑥ Impeller 与 Skia | ✅ 两条都稳；**默认保持 Impeller**（Flutter 在 Linux 上的方向），Skia 留作启动项参数 `gk3.renderer=skia` |

| | Impeller | Skia |
|---|---|---|
| 时长 | 11.3 分钟 | 10.2 分钟 |
| RSS（启动 1 分钟后 → 末） | 193 → 196 MiB | 155 → 158 MiB |
| 增长 | +0.17 MiB/分钟 | +0.19 MiB/分钟（≈ 一小时 10 MiB：一次安装十几分钟，无碍） |
| 帧率中位 | 61 fps | 61 fps |
| 光栅化 p95 | 0.9 ms | 0.8 ms |

同几轮在真机上顺带查出并修掉的：重新安装被"misc 太小"拦住（本机 misc 1007 KiB，方案按 MiB 取整成 0）；
网络安装的版本页"无法获取版本列表"（`variants.txt` 从没发布过，404 → 退回 `ota/gaokun3.json` 推出最新发布）。
⚠️ 热点里从 Mac 扫不到 live 的 22 端口（设备是连上了的）—— 疑似手机热点隔离了客户端，没查实。

正式修法已进构建脚本（**未重建**，换网后 deb.debian.org 不通）：`build-live.sh --firmware`（华为 zap shader 的
再分发问题见 TODO B23）、overlay 屏蔽可预测命名（`99-default.link → /dev/null`）、网卡名不再写死。

### 5.8 免 U 盘装双系统（用户 2026-09-25 的要求 5）

**已做（离线验过）**：
* `gk3_probe` 的 PART 记录多一个 `medium=yes|no`，标出安装器所在的分区
* `gk3_shrink_info` 对挂着的分区一律 `can=no why=mounted`（首先是介质分区）；`gk3_shrink` 自己也拒绝
* `gk3_apply` 的安全闸只拦整盘清空；双系统只往空闲区建分区，**介质与目标同盘时照常放行**
* 界面：U 盘介质照旧禁用；内置盘介质**可选**，带一句"只能装在空闲空间里"；选方式页整盘清空禁用并写明原因；
  缩分区页介质分区列出但不可缩
* 测试：`test-apply.sh` 新增 D 节（介质与目标同盘：探测标记、不可缩、整盘拒绝、双系统装完且介质分区内容与
  PARTUUID 未变，15 项）→ 71/71；fixture 新场景 `windows-live`（出厂盘缩出 80 GiB + 4 GiB 的 GK3LIVE），
  Flutter 46/46，新截图 `03b` / `04b`

**Windows 那一侧**（新用户手上是 Windows，不是 Android —— Android 侧已有 `m0-internal.sh` 那条路）。
✅ 用户 2026-09-25 选定 PowerShell 脚本，**已写**：`scripts/windows/`（`gaokun3-setup.cmd/.ps1`、打包 `build-bundle.sh`
由 `build-live.sh` 调用 → `out/live/gaokun3-windows{,.zip}`，312 MiB）。纯逻辑有单元测试（`test-setup.sh`）；
✅ **2026-09-25 在 Parallels 的 Windows 11 ARM 虚拟机（用户那台的克隆）里整条跑通**：压缩、建 GK3LIVE、ESP、
bcdedit 一次性启动 → 重启真的进了 systemd-boot 菜单（安装器默认、Windows 自动列出）→ 重置回 Windows、一次性项已清 →
`-Uninstall` 后分区 / ESP / 固件启动项与安装前完全一致；`-UseFallbackPath` 的原件逐字节还原。剩华为固件认不认 BootNext、
BitLocker 恢复密钥两项要真机（`scripts/windows/README.md`）。做法：
1. 预检：型号 GK-W7X、Secure Boot 已关（`Confirm-SecureBootUEFI`）
2. **让 Windows 自己缩 D:（出厂有独立的 Data 分区，336.6 GiB）**（`Resize-Partition`，即"压缩卷"）。理由：它能处理 BitLocker/设备加密、脏卷、
   不可移动文件 —— `ntfsresize` 对 BitLocker 卷**完全无能为力**，而 Windows 11 在这类机器上可能默认开着设备加密
   （⚠️ 本机出厂是否开着，我不确定，需要验证）。live 里的 `gk3_shrink` 留给从 U 盘启动的人
3. 在缩出来的空间开头建一个 FAT32 小分区（GK3LIVE，2–4 GiB）放 `live.squashfs`（可选再放载荷）。
   不放 ESP：出厂 ESP 300 MiB、只剩约 188 MiB（`hw-inventory.md` 第 8ter 节）；不放 C:：可能被 BitLocker 加密
4. ESP 上放 systemd-boot + 内核 + dtb + initramfs + 一个启动项（`\EFI\gaokun3\`）。⚠️ 空间紧：出厂 ESP 空闲
   188 MiB，双系统时 Android 要 `GK3_ESP_NEED_MIB`=150，live 的内核 + initramfs 约 20 MiB，合计约 170 MiB
5. 一次性启动：`bcdedit /copy {bootmgr}` 建固件启动项指向 systemd-boot，`bcdedit /set {fwbootmgr} bootsequence`
   只下一次走它 —— 装失败 / 不想装，重启就回 Windows
6. 安装器起来后走双系统（本节上半部分已经支持）；GK3LIVE 装完可以留作救援分区

⚠️ **验证难题**：唯一一台机器的 Windows 已在 2026-08-20 抹掉，没有 Windows 可测。可选：Mac 上用 UTM 跑
Windows 11 ARM 虚拟机验 PowerShell 与 bcdedit 的流程（验不了华为固件对 `bootsequence` 的处理），或找有 Windows
的用户试。

**2026-10-05（统一启动入口 S12 / U23）**：同一个脚本升级成常驻的 **Windows 伴随工具**（【预览】，只在容器里测过）——
免 U 盘安装的最后一步把它装到 `%ProgramFiles%\gaokun3`、建开始菜单与 SYSTEM 计划任务（开机自检 BOOTAA64 / `LoaderEntryDefault` /
BIOS 版本），并提供 `-RepairBoot`、"重启到 Android"、`-SetDefault`、`-SuspendBitLocker`、`-RemoveAndroid`；快速启动改为**一律关**
（U18，不再只在"要到安装器里缩 D:"那条路上）。U 盘介质上另带一份（`gaokun3-windows\`）。细节与只能等真 Windows 的点：
`scripts/windows/README.md`「Windows 伴随工具」一节、`docs/boot-entry-design.md` §4.9.15 与 S12 行。

### 5.9 ★ M4b：第一次真的装了一台（2026-09-26，内置盘，重新安装 + 保留数据）

`docs/stage7-installer-roadmap.md` 那条"从来没有真的装过一台机器"的欠账，今天还上了。
本机整盘是 Android，双系统必被 PARTLABEL 查重拒绝 ⇒ 走**重新安装**；用户选"同版本、保留数据"（对日用数据改动最小）。

* 载荷：构建机 `out/` 里的 `1790206017`（设备正在跑的那一版，未发布）照 `release.sh` 的办法打包
  （`boot.img` · `zstd -19 --long` 的 `super.img.zst` 1.28 GB · `install-artifacts.sha256`）→ 直连拉回本机
  （热点下约 4 MB/s，按偏移续传、sha256 一致；R2 凭据不在构建机上，没去找）→ `m0-internal.sh payload` 推到
  p3 的 `gaokun3/payload/`（WiFi adb 8.8 MB/s，推前推后各核一遍）。live 换成**正式构建**的镜像（`prepare`）。
* 装机前在 /data 与 /data/media/0 各放一个随机标记，记下第三方应用清单、`/data` 用量、几个设置项。
* oneshot 进 live → 用户在屏幕上：重新安装 → U 盘里的镜像 → 保留数据 → 按住确认 → 重启。
  **会话开始 23:30:53，Android 23:34:07 已 `boot_completed`** —— 点界面 + 写盘 + 重启 + 开机一共约 3 分钟。

| | 装机前 | 装机后 |
|---|---|---|
| 槽 | `_b`（mapper 里只有 `*_b`） | **`_a`**，已标记成功；mapper 里只有 `*_a`（super 是新写的）|
| 版本 | `1790206017` | `1790206017` |
| ESP default | `*-android-b.conf` | `*-android-a.conf`；live 的 5 个启动项、Ubuntu / Alpine 救援项都还在 |
| 两个随机标记 | 写入 | **原样**（/data/local/tmp 与 /data/media/0）|
| 第三方应用 | 21 个 | **逐行相同** |
| `/data` 已用 | 62 796 872 KiB | 62 797 620 KiB |
| `ntp_server` / `allow_suspend` | `ntp.aliyun.com` / 0 | 同左 |

⇒ **保留数据的重新安装在真机上成立**（同版本）。开机后用户处于 `RUNNING_LOCKED`、`/sdcard` 还没挂 ——
那是任何一次重启后"等第一次解锁"的正常状态，不是这次装机造成的。
⚠️ 回落槽的处境照旧、方向反了：新写的 super 里 `*_b` 是空的（`lpdump`：`system_b` 没有 extent）⇒ `_b` 起不来。
安全网是开机菜单里内置盘上的 live（再装一次）与救援 Ubuntu。

**★ 抓到的缺口：介质上找不到 `gk3_apply` 的任何一行输出。** `diag/installer.log` 只有 Flutter 进程自己的
stderr；后端的进度、sha256 核对、每一步写盘只在屏幕上的日志区里出现过。这一次装成了所以无所谓，
装坏的那一次就只剩"屏幕上好像报了个错"。修法：`ShellBackend` 把每次调用的参数（WiFi 密码遮住）、
stdout 记录、stderr、退出码与耗时照抄到自己的 stderr —— session 脚本早已把它接到 `diag/installer.log`。
测试 `shell_backend_test.dart`（含"参数里的 `$(…)` 不被 shell 解释"），界面测试 60/60。

**★★ 事后查出的第二个、也是更要紧的问题：ESP 被写满了，而安装报告成功。**（装完推新 live 镜像时 `m0-internal.sh` 报"ESP 只剩 0 KiB"才发现）
* `gk3_apply` 的 `<machine-id>/` 目录名取的是**正在跑的系统**的 `/etc/machine-id` —— live 的是 systemd 每次开机现生成的
  （`c1d9da8e…`），于是重新安装没有覆盖设备上现有的 `8a29534f…/android/`，而是另开一个目录又写了一整套（46 MB）。
  300 MiB 的 ESP 上还住着固件的 `Persisted_Capsules.bin`（70 MB）与救援 Ubuntu 的内核（60 MB）⇒ 写满：
  `c1d9…/slot_b/ramdisk.img` 截断在 2.8 MB、`c1d9…-android-b.conf` 是**空文件**；`cp` 的失败没人查，安装照样走到 100%。
* 这次能开机是运气：default 的通配 `*-android-a.conf` 同时匹配新旧两个条目，systemd-boot 挑中了新的（完整的）那个。
  而 **OTA postinstall 找目录的规则是"第一个 32 位十六进制目录"**（`gaokun3-ota-postinstall.sh:79`）⇒ 下一次 OTA 会写进旧目录、
  default 改成 `*-android-b.conf` ⇒ 同时匹配旧目录的好条目与新目录的**空条目 + 截断的 ramdisk** —— 抛硬币。
* 🔧 **设备上当场修了**（不重启）：删截断的 `c1d9…/slot_b` 与空条目 → 这次启动用的 ramdisk 拷进 `8a29…/slot_a`（先写临时名、核 sha256 再换）→
  三个文件与 `boot.img` 拆出来的逐一相同、`8a29…-android-a.conf` 的 options 与刚启动的那条**逐字相同** ⇒ 下一次启动与这一次字节相同 →
  再删 `c1d9…`。结果：只剩一个目录、每个槽一个启动项、ESP 空闲 46 MiB。
* 🔧 **安装器**：① 目录名与 postinstall 用**同一条规则**（`gk3__esp_pick_mid`：ESP 上第一个 32 位十六进制目录，没有才用 machine-id）；
  ② 动盘前按**真要写的量**核空间（`gk3__esp_delta_kib`：新文件减去同一路径上会被覆盖的旧文件），并且要求装完之后还过得了
  OTA postinstall 的门槛（空闲 + 槽里旧文件 > 56 MiB）；③ 每个写 ESP 的动作都查结果，写完按同一份清单逐字节 `cmp`；
  ④ 别的目录下我们的 `*-android-{a,b}.conf` 改名 `.disabled`（default 的通配会同时匹配它们）。
* 测试为什么没抓到：`test-apply.sh` 一直导出**同一个** `GK3_MACHINE_ID`，而真机上每次开机都换。F 节补 4 条
  （换 machine-id 重装、停用别的目录的条目、放不下、放得下但 OTA 过不了）→ **114/114**。
* ⓘ 顺带核对到的：OTA 解出来的 ramdisk（`7a006810…`）与 `boot.img` 里的（`8f258bbb…`）内容确实不同（解压后差 768 字节）——
  OTA 的 boot 镜像是从 target-files 重新打包的，两个都能起同一版，不是问题。

⬜ 没验的：清除数据的重新安装（默认那条）、整盘清空、双系统 —— 后两者在本机都没有合适的盘面；换旧版本 + 保留数据（界面上写了"可能起不来"）。

### 5.10 安装器成熟：一轮独立审查修的 9 处（2026-09-27）

M4b 那次"ESP 写满、却报告成功"之后，让一个独立的审查专找同一类问题：**写失败没人查而照样报成功**、**测试的前提与真机不一致**。
高危的两条都按源码 / 实测坐实了才改（`ff93fd5`）：

| # | 问题 | 怎么修的 |
|---|---|---|
| 1 ★ | **Windows 快速启动 / 休眠时缩 NTFS 会损坏 Windows 的数据** —— ntfsresize 按 `NTFS_MNT_FORENSIC` 打开卷（ntfs-3g 2022.10.3 `ntfsresize.c:2888`），而这个标志正好跳过休眠与 `$LogFile` 检查（`volume.c:1286`）；我们还给 `--info` / `--no-action` 加了 `--force`，一个就放过脏卷（`ntfsresize.c:2946-2948`）。代码自己的注释写着"不要绕过它"。快速启动默认开着 ⇒ 这是双系统用户的常态 | 探测：`hiberfil.sys` 开头是不是 `hibr`/`HIBR`（与 ntfs-3g 同一判据，`volume.c:832-833`）→ `why=ntfs-hibernated`；`--info` 不带 `--force`。动手前：`ntfs-3g -o no_detach,norecover` 读写挂一次，**挂成只读 = 不安全**（读写挂载默认允许退回只读并返回 0，`ntfs-3g.c:4031-4033`；不加 `norecover` 它会把没关干净的日志清掉，`volume.c:1296-1302`）。界面加原因文案 |
| 2 ★ | 救援分区的写入全不查、不读回 —— 重新安装时它刚被格式化，写坏等于把好的救援系统换成坏的，要等到真要用它那天才知道 | 每步查；卸下 + `blockdev --flushbufs` + 只读挂回逐个 `cmp`（`gk3__verify_on`；ESP 也改成这样从介质读回，挂着直接 `cmp` 读的是页缓存） |
| 3 | 下载 sha256 不符时留着文件 ⇒ 同一次会话里换版本再装，续传接在错的前缀后面，永远对不上 | 不符就删 |
| 4 | 分区节点被 udev 重建的瞬间，`dd` 会在 /dev 里写出一个普通文件、"成功"，盘上什么都没有 | `conv=nocreat`；写完确认仍是块设备 |
| 5 | `partprobe` 没生效（分区被占着）时，同号节点指着**旧**起点，`-b` 看不出来 | 拿 sysfs 的起点 / 大小对盘上的分区表，对不上就停 |
| 6 | 扩大 / 缩小：分区名写回、内核看到的新大小、GPT 属性位都没核 | 都核；属性位原样带过去（恢复分区靠它们） |
| 7 | 格式化后改类型码失败被 `\|\| true` 吞掉 | 报错 |
| 8 | 分区表备份落到 /tmp（内存）时仍告诉用户"可以还原" | 三份实现合成 `gk3__gpt_backup`，落到内存时警告 |

测试：`test-shrink` +5（脏卷、休眠、终审、属性位）→ 17/17，`test-apply` +3 → 119/119。⚠️ 测试第一次写错了两处，都是**测试的前提**错：
伪造的"新版本"是在旧版本后面追加得到的（续传正好接对），休眠卷的清理用普通 `mount` 删文件（退回只读、静默失败）。

**★ 真机：网络安装第一次跑通（2026-09-27 01:09–01:18，内置盘上的 live → 重新安装 + 保留数据 + 从网络下载）。**
下载源是开发机（`variants.txt` 放在 p3 上，指向 Mac 上 `python3 -m http.server` 发的 `1790206017`）。这一次后端的每次调用都记进了
介质上的 `diag/installer.log`（§5.9 补的日志回写，第一次在真机上用上）：

| 步骤 | 实测 |
|---|---|
| 连 WiFi（热点，软键盘输密码） | `gk3_wifi_connect` 7.1 秒；日志里密码是 `<密码 8 个字符>` |
| 版本列表 | 介质上的"开发机 · 1790206017"排第一，线上的最新发布跟在后面（6.7 秒） |
| 下载 1.25 GB | **190 秒**（约 6.6 MB/s），两个文件 sha256 都过 |
| `gk3_apply` | **8.8 秒**：ESP 用现有的 `8a29…` 目录，"要写 0 MiB"；super 12 GiB 流式写完、LP 魔数对；ESP 8 个文件**从介质读回**核对一致 |
| 回到 Android | 槽 `_a`、版本不变，两个随机标记原样，21 个第三方应用逐行相同；ESP 仍是一个目录、空闲 46 MiB |

* ★ 顺带查清：**ssh 进 live 一直连不上，不是热点隔离客户端** —— 以前是 live 根本没连上这个热点（p3 上的 WiFi 配置是家里的 SSID），
  连上之后 `ssh -i out/m0/ssh_ed25519 root@<IP>` 一次就进，IP 从下载服务的访问日志里拿。整个安装过程我都是从 ssh 看的。
* ★ 抓到：**下载的两分半里进度一行也没出来**，结束时一起吐 —— 屏幕上的进度条停在 5%、最后跳到 95%。`tr '\r' '\n'` 往管道写是块缓冲；
  换成 awk 自己按 `\r` 切也不行，mawk 读管道同样攒块（实测三行全在最后一刻出）。改成 bash `read -d $'\r'`（逐字节读），
  test-apply 加一条按 curl 的样子喂、量第一行多久出来 → 120/120。

同一轮还加了：**介质上的变体清单**（`/media/gk3/gaokun3/variants.txt`，局域网镜像 / 自建源 / 离线；线上两份都取不到时有它就够）——
网络安装在真机上的第一次实测就靠它把开发机当下载源（设备 → 热点 → Mac 实测 9 MB/s）。

### 5.11 发布：随 v0.6.3 发预览（用户 2026-09-27）

> ⏸ 2026-09-28 用户：v0.6.3 暂不发（候选版不含 PR #10 的麦克风修复，还要等 iris 修复），下一版可能直接 0.7.0 ——
> 安装器预览跟着那一版发，做法不变（`release-installer.sh --rom <那一版>`）。

* **B23 定①**：GPU zap shader 随 live 镜像与 Windows 安装包公开发，与 ROM 同待遇（仓库照旧不收固件）。
* **随下一个小版本发，不单开发布线**（我的建议，用户同意）：live 用的就是 ROM 的内核 —— 拿那一版验过的 `boot.img` 造 live，
  发的就是验过的那一份（与 `release.sh --no-build` 同一个道理）；一个 release 页面里 ROM、U 盘镜像、Windows 安装包全有；
  单人维护，两条发布线要多一套版本号、说明与兼容矩阵。**标"预览"**：新用户的两个入口（U 盘启动、Windows 脚本）与双系统都还没上过真机。
* **安装器自己的版本号** `0.1.0-preview`（与 ROM 版本无关：网络安装默认装最新版）。只从 `pubspec.yaml` 读：
  界面侧栏底部显示（`lib/version.dart`，`test/version_test.dart` 核对一致）、启动时打进 `installer.log`、
  镜像里 `/etc/gaokun3-release`、U 盘与 Windows 安装包里 `release.txt`（另记 git 提交与内核来源 `boot.img` 的 sha256）。
* **`scripts/live/release-installer.sh`**（Mac 上跑）：工作区必须干净 → 用给的 `boot.img` 造（不带 `--m0`、**不带 `--with-rescue`**：
  装进救援分区的就是 live 本身 —— 它在真机上起过十几次，单独的 rescue profile 一次没起过）→ 核版本 / 提交 / 内核来源 →
  `gaokun3-installer-<版本>-{usb.img.xz,windows.zip,release.txt,SHA256SUMS}` → `--upload <tag>` 才传，传完按服务器上的字节数核对。
* 用户文档：`docs/INSTALL.md` 开头改成"两个安装器"，加"Graphical installer (preview)"一节（哪些在真机上验过、哪些没有，逐项写明）；
  `docs/relnotes/v0.6.3-alpha.md` 加一节，顺带删掉早已作废的"BIOS 必须 2.16"。

### 5.12 Windows 脚本只划自己的空间，给 Android 的空间在安装器里分（用户 2026-09-27）

用户："更改磁盘这个操作应该在安装操作的时候进行，安装安装器应该仅划分自己需要的空间"。原先脚本一次从 D: 缩出 64 GiB 给 Android + 4 GiB 给安装器。
* 脚本默认只缩出 GK3LIVE 要的（`Get-LiveMiB`：安装包内容 ×1.25 + 128 MiB，按 256 MiB 取整，至少 512 MiB），紧挨在 D: 后面；
  用户在安装器里"缩小现有分区腾出空间"缩 D:，Android 装进 D: 与 GK3LIVE 之间。`-AndroidGiB <N>` 照旧可以一次缩好。
* **代价是 BitLocker**：加密的卷安装器缩不了（当初把缩交给 Windows 就是为这个）。用户选"脚本认出来再问"：
  D: 的 `VolumeStatus` 不是 `FullyDecrypted`（设备加密"等待激活"也算）且没给 `-AndroidGiB` ⇒ 问"现在就缩多少"（回车 64，0 = 不缩）。
  安装器那边认出 BitLocker 卷（blkid `TYPE=BitLocker` → `why=bitlocker`），界面写明回 Windows 怎么做 —— 原先报"文件系统不支持无损缩小"，是误导。
* **快速启动**：这条路上它成了头号拦路虎（D: 停在休眠状态 → 安装器拒绝缩）⇒ 脚本说明、确认后关掉，`-Uninstall` 恢复。
* ★ 录 fixture 时抓到：**ntfsresize 缩完会故意置 dirty 位**（让 Windows 下次开机跑 chkdsk，`ntfsresize.c:2987`）—— 以前的 `--force` 把这一点盖住了。
  于是安装器缩过一次 D: 之后，再缩要等 Windows 开机检查一遍（这是对的）；fixture 里"代替 Windows 压缩"那一步要 `ntfsfix -d`。INSTALL.md 写明"Windows 下次开机会先检查磁盘"。
* 测试：`test-setup.ps1` +14（39/39）；`test-shrink.sh` +2（造出 libblkid 认得的 BitLocker 卷头 → 19/19）；fixture 新场景 `windows-setup` / `windows-setup-shrunk`
  （真后端录；BitLocker 那份也是录的）+ 流程测试 2 条 → 界面 63/63。生成 fixture 时 docker 的盘写满过一次（每个场景真装一遍实写约 12 GiB）⇒ 场景录完即 `drop_disk`。
* ⚠️ 新路径（自动算大小、加密卷提问、关快速启动）只有单元测试，没在虚拟机里重跑；真机上的双系统依旧没装过。

### 5.13 1.0 批 3：写盘不许被打断、失败了看得见（2026-10-05，v1.0 计划 B5 / GUI-3/5/11/12、INST-6/12/16/17）

都只在本机（容器、loop 设备、假 ESP）测过，**没重建 live 镜像、没上机**。
* **B5：写盘期间关不了机、睡不了**，三层，任何一层单独失效另两层还在（`3608a52`）：
  ① `overlay-common/etc/systemd/logind.conf.d/gaokun3.conf` 让 logind 不管电源键 / 睡眠键 / 休眠键 / 合盖（三种合盖都 ignore）；
  ② `build-rootfs.sh` 把 sleep / suspend / hibernate / hybrid-sleep / suspend-then-hibernate 五个 target 全 mask，体检逐个断言；
  ③ 写盘的那次调用套 `systemd-inhibit --mode=block`（拿不到——logind 没在跑——就照样执行、记一笔，前两层不靠 logind）。
  rescue 也铺 overlay-common ⇒ 在救援系统里短按电源键也不再关机。
  ⓘ 原因：live 里 a600000.usb 停在 role=device、没有 usbrole 守卫，挂起会整板复位（stage4-findings #52）——赶上缩 NTFS 或写 super 就是一块坏盘。
* **GUI-3/5：失败页分两种**：下载失败（盘没动过）⇒ "重试 / 返回修改"，重试接着半截文件续传；写盘失败 ⇒ 另一页（盘可能已改）。
  侧栏常驻"重新启动 / 关机"，只在 `gk3_apply` 期间禁用、先确认（下载期间可用：没有取消按钮时它们就是出口）。
  `gk3_net_fetch`：`--speed-limit 10240 --speed-time 60`（60 秒平均不到 10 KiB/s 判这次失败）+ `--connect-timeout 20`，
  外层最多 `GK3_NET_TRIES`=5 次按已有长度续传；408 / 429 / 5xx 与网络类失败（6/7/16/18/28/35/52/55/56/92）重试，404 不重试；
  用完了仍是网络类失败 ⇒ 半截文件留着（不交给 sha256 删掉）。换了版本时先比新旧校验清单，变了的文件先丢。
  ⬜ 阈值在国内走 R2 慢速下载时会不会误判，要真机看。
* **GUI-11：界面崩了不连带杀写盘进程**（本轮，后端已就位，**前端还没接**）：Flutter 一崩 cage 退出、`gk3-installer.service` 停，
  systemd 按默认 KillMode=control-group 杀整个 cgroup。`installer-lib.sh` 末尾加了 `gk3_job_run / _start / _follow / _status`：
  写盘调用进 `systemd-run --unit=gk3-job-<id> --collect --service-type=exec` 的临时单元，GK3_* 环境用 `--setenv` 带过去，
  `systemd-inhibit` 套在单元**里面**（锁跟写盘进程活，不跟界面活）；输出写 `/run/gaokun3/jobs/<id>/{out,err}`、结束写 `rc`，
  并存一份到介质 `gaokun3/diag/job-<id>.log`。`gk3_job_follow` 只转发完整的行（python3，按字节偏移），退出码 = job 的退出码；
  job 没写状态就没了 ⇒ 125。不是 systemd 系统时退回 `setsid -f`（会说一句：cgroup 被整个杀时仍会被连带）。
  **前端要做的**：`ShellBackend.call` 里 `writesDisk(fn)` 时把 argv 的 `fn` 换成 `gk3_job_run fn`（其余不变：stdout / stderr / 退出码逐行相同，
  JOB 记录在 stderr 上）；启动时 `gk3_job_status` 看有没有 `state=running` 的 job，有就进运行页并 `gk3_job_follow <id>` 接上。
  ⬜ systemd-run 那条路在容器里只用假的 systemd-run 测过参数；真 systemd 下单元能不能拿到 logind 的 inhibitor、`--setenv` 继承值，要在 live 里看。
* **GUI-12（后端）：日志另存到拿得到的地方**：U 盘只有一个 ESP 类型的分区，Windows / macOS 不自动挂。`gk3_log_targets` 列出可写的
  FAT / exFAT（另插的 U 盘在前，启动介质最后、标 `esp=yes`；不往 NTFS 写），`gk3_save_logs [分区|目录]` 写 `gaokun3-logs-<时间>/`
  （会话日志、各 job、dmesg、journal、探测、sgdisk -p、分区表备份；不含 WiFi 配置），stdout `LOGSAVED …`。
  ⬜ 前端的"保存日志"按钮没做；U 盘分区改 0700 类型要先实测华为固件能否回落启动。
* **INST-6**：Windows 安装包的 GK3LIVE 上只有 `live.squashfs`，原先按 `rescue.squashfs` 找 ⇒ 从 Windows 开始的安装永远没有救援系统。
  `gk3__find_rescue_squashfs` 兜底用它；`release-installer.sh` 另把 `rescue.squashfs` + `initramfs.img` 作为附件（命令行安装用），`--r2` 同时传 R2 的 `installer/<版本>/`。
* **INST-17 / OTA-10**：救援条目两条（借 slot_a / slot_b 的内核，`<mid>-rescue.conf` / `<mid>-rescue-b.conf`），postinstall 给借刚换内核那个槽的那条同步 options（规则同 `gk3__rescue_cmdline`），老机器 OTA 到 b 时派生第二条。
* **INST-12**：救援里 `gk3-boot-android [a|b] [--reboot]`（镜像里没有 bootctl）。**INST-16**：`CHECK id=tools` 加 `pkgs=`。

### 5.14 1.0 批 3 前端组：界面不再显示后端的中文、下载可取消、接上 §5.13 留的三个接口（2026-10-05）

都只在本机（Mac 上 flutter test、容器里 test-apply / gen-fixtures）测过，**没重建 live 镜像、没上机**。
* **协议（INST-10）**：`installer-lib.sh` 给界面的只有代码 —— `PROGRESS <百分比> <代码> [k=v…]`（`gk3_prog` 带编码好的字段）与
  `ERR code=<代码> [k=v…]`（新的 `gk3_fail <代码> [k=v…] -- <中文说明>`：先出 ERR，再出原来的 `!! 中文`，日志与命令行版不变）。
  ERR 也走 stderr（`x=$(gk3__…)` 吞 stdout，报错会跟着丢）。在 `gk3_apply` / `gk3_shrink` 的调用栈里自动带 `touched=yes|no`（盘动过没有；
  看栈不看变量 —— 同一个 shell 里先后调过它们，变量会留着）。前端 `lib/ui/messages.dart` 按代码查 l10n；`test/messages_test.dart`
  从 installer-lib.sh / gk3-unsparse.py 里把所有代码抓出来，要求两种语言都有、英文的不含 CJK。没改的四处 `gk3_die`
  （救援分区那几行：rescue.squashfs / initramfs.img 缺失、救援分区写失败 / 卸不下）界面上显示通用的"没有完成（退出码）"。
* **英文界面无 CJK（GUI-14）**：flow_test 逐页扫屏幕上的文字（日志区除外）。⚠️ 日志是后端原样输出、部分是中文 ——
  失败页在英文界面里默认收起，点"Show the technical log"才展开（bug 报告要它）。"中文"两个字是语言按钮自己的名字，不算。
  变体清单可带 `name_en` / `desc_en`（没有就用 `name` / `desc`）。
* **语言（GUI-4 / GUI-19）**：侧栏底部"安装器 <版本>"走 l10n；记住的 > 内核参数 `gk3.lang=`（`gk3-installer-session` 转成 `GK3_LANG`，
  Dart 也直接读 `/proc/cmdline`）> 中文。记在 `/media/gk3/gaokun3/installer-lang`（会话脚本已把介质挂成可写），只读时 `/run/gk3-installer/lang`。
* **下载（GUI-5）**：curl 进度表的最后两列（Current Speed、Time Left）进 `PROGRESS … dl … speed= left=`，界面显示"1.8 MB/s · 还要约 8 分钟"；
  ⬜ 两列的含义按 curl 的进度表格式，只在桩上验过。"取消下载"只在下载阶段有、先确认；`ShellBackend` 用 `setsid` 让下载自成进程组、取消时整组 TERM
  （只杀 bash 的话 curl 成了孤儿，重试时两个 curl 写同一个文件）。取消后是"下载已取消"页（盘没动，可重试 / 返回）。
  另外：`gk3_apply` 在第一次写盘之前的检查里失败（ERR `touched=no`）现在也走"盘没动过"那种失败页，不再说"写了一半"。
* **GUI-8 电量**：`CHECK id=power ok=… value=<%> ac=yes|no min=15`。名字取自 EC 驱动（`gaokun-ec-battery` / `gaokun-ec-adapter`，
  `refs/gaokun-buildbot/drivers/gaokun-ec/huawei-gaokun-battery.c:174-175`、`:435`），找不到按 `type` 找，找不到电池 ⇒ unknown 不拦。
  ⬜ live 内核里这个驱动在不在没在 live 里看过。
* **GUI-9 WiFi**：`gk3-wpa-scan.py` 改成"有 PSK 就是 psk"（WPA2/WPA3 混合模式按 PSK 连），只有纯 SAE 报 sae；`gk3_wifi_connect … sae` 设
  `key_mgmt SAE` + `ieee80211w 2`（Debian wpasupplicant 2:2.10-24 的 `examples/wpa_supplicant.conf:991`；密码照放 psk，同文件 `:1047-1051`），
  存给救援系统的配置也带上。WEP / OWE / EAP 在列表里标灰并写原因。⬜ 纯 SAE 的 AP 没真连过。
* **GUI-17 / GUI-18**：安装器所在的盘就是目标盘时，选项页默认不另装救援（写明原因、可打开），完成页不说"移除安装介质"；
  整盘清空的确认页把卷标 Onekey 的分区标成"华为一键恢复分区"并写后果（WINPE 是否属于同一套没核实，没标）。
* **§5.13 的三个接口**：GUI-11 —— `ShellBackend` 在库里有 `gk3_job_run` 时，写盘调用改成 `gk3_job_run <fn> …`（stderr 上的 JOB 记录解析成记录）；
  欢迎页先问 `gk3_job_status`，有 `state=running` 的就直接进运行页 `gk3_job_follow <id>`（标题"正在接着刚才的写盘"，侧栏禁用；跟完 apply 进完成页，
  跟完别的回欢迎页重来）。job 没写状态就没了 ⇒ `ERR code=job-lost touched=yes`。GUI-12 —— 两种失败页都有"保存日志"：`gk3_log_targets` 列目标
  （启动介质标"电脑上默认看不到"）、`gk3_save_logs <分区>`，存完说存到哪。INST-16 —— 预检失败那行显示 `apt install <pkgs>`。
* fixture 用 `gen-fixtures.sh` 重录（进度 / ERR 只有代码；预检带 power；WiFi 列表加纯 WPA3 / WEP / OWE；`log_targets` / `save_logs` 在假 U 盘上录；
  `job_status-*` 手写，跟读内容是 blank 场景录的那次 apply）。⚠️ 改了 `.arb` 之后先 `flutter gen-l10n`，`flutter test` 不会重新生成。

## 6. 风险（按"会不会让方案作废"排序）

1. 🔴 mesa/freedreno 在 Debian arm64 用户态不可用 → 回落 `FLUTTER_LINUX_RENDERER=software`
2. 🔴 GTK embedder 在 ARM GLES + Wayland 上有已知逐帧泄漏
   （[flutter/flutter#192603](https://github.com/flutter/flutter/issues/192603)，描述的组合正是我们这套）
   → M0 必须量 RSS 曲线，不是"看着能跑"
3. 🟡 Impeller 在弱 GPU 上闪烁（[#192915](https://github.com/flutter/flutter/issues/192915)）→ M0 两条后端都测
4. 🟡 体积、rescue 变大、Flutter 是本仓第一个要联网拉依赖才能构建的子项目
5. 🟢 `chvt 2` 逃生口在 Wayland 下失效 → ✅ **已有答案（2026-09-25，读 cage 0.2.0 的 `-h`）**：cage
   **默认禁止切换 VT**，要加 `-s` 才允许 —— 不加它，`chvt 2` 与 Ctrl+Alt+F2 必然失效。
   会话服务里写死 `cage -s`。另：⚠️ 计划里写的"旋转交给 cage `-r`"**在 0.2.0 不存在**（没有旋转参数），
   旋转和缩放都要在 cage 起来之后用 `wlr-randr --transform/--scale` 设。

外部 issue 是别人项目的现状，不是本仓实测；M0 的实测推翻它们时以实测为准。

## 7. 对外可见的变化（未推送）

* `docs/INSTALL.md`：命令行安装器现在需要一份仓库 checkout（它 source `scripts/live/`）；
  `.zst` 不用先解压；**从通用 Ubuntu/Debian live U 盘安装时没有救援系统了**
  （原先的 24 GiB 克隆救援已删，新的救援镜像要等我们的 live U 盘发布）。

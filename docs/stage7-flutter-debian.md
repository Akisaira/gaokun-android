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
> ▶ **下一步是 M4（真装一台）**：M4a 要一块外接 USB 盘；M4b（内置盘）要用户单独点头。
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
| M4b | 内置盘 | 真机，⚠️ **现在没有回落槽**（`_a` 不可启动，#122 §1） | ⬜ 需用户单独点头。★ 2026-09-26 核对：本机整盘是 Android ⇒ **双系统必被 PARTLABEL 查重拒绝**（fixture `android`），计划里"缩 /data 再装双系统"那条路在本机走不通 ⇒ M4b = **重新安装**模式。安全网：`gk3_apply` 只改写 `*-android-{a,b}.conf` 与 `loader.conf`，内置盘上的 live 启动项（`gaokun3-m0*.conf`）与 p3 不动 —— 装坏了从开机菜单进 live 再装一次。载荷：网络安装拿到的是已发布的 v0.6.2（`1789570683`）；设备上是未发布的 `1790206017`，要"同版本、保留数据"得先把它的 `boot.img` + `super.img.zst` 放到 p3 |
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
bash scripts/boot-oneshot.sh gaokun3-m0.conf && adb -s gaokun3 reboot     # ⚠️ 要你在场并同意
bash scripts/live/m0-internal.sh logs       # 回到 Android 后取 p3:/gaokun3/diag/ → out/m0/diag/
bash scripts/live/m0-internal.sh remove     # 撤掉启动项、initramfs、live.squashfs
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

# 免 U 盘安装与 Windows 伴随工具：Windows 那一侧

用户 2026-09-25 的要求：LiveCD 的初衷之一是**免 U 盘安装**，并且要能**装双系统**。
新用户手上是 Windows，所以得有个办法在 Windows 里把安装器放上内置盘 —— 就是这里的脚本。
安装器那一侧（介质与目标同盘时放行双系统、只拦整盘清空）见 `docs/stage7-flutter-debian.md` §5.8。

| 文件 | 是什么 |
|---|---|
| `gaokun3-setup.cmd` | 给用户双击的入口：以管理员身份运行同目录的 `.ps1`，参数原样传过去 |
| `gaokun3-setup.ps1` | 预检 → 让 Windows 自己压缩 D:，**只缩出安装器自己要的**（按安装包内容算，约 0.5–2 GiB）→ 建 FAT32 分区 GK3LIVE 放 live → ESP 放 systemd-boot 与启动项 → bcdedit 设"只下一次"。给 Android 的空间在安装器里缩。`-Uninstall` 撤销。**同一个脚本也是常驻的 Windows 伴随工具**（【预览】，见下面"Windows 伴随工具"一节） |
| `build-bundle.sh` | 造安装包目录 + zip（`build-live.sh` 在构建容器里调它）→ `out/live/gaokun3-windows{,.zip}` |
| `test-setup.ps1` / `test-setup.sh` | 测试：PowerShell 容器里测语法、编码、5.1 兼容与全部纯逻辑；再拿 live 镜像里的真 wpa_supplicant 解析生成的 WiFi 配置 |
| `test-companion.ps1` | 伴随工具的测试（被 `test-setup.ps1` dot-source）：模拟 ESP（临时目录）、固件变量（内存表）、BitLocker / manage-bde、分区 cmdlet、schtasks / powercfg / bcdedit |
| `test-fixtures.sh` | 在 `gk3-test-env` 容器里用真 `sgdisk` / `mkfs.ext4` / `mkntfs` / `mkfs.vfat` 造 3 种 GPT 盘镜像（正常 / userdata 里是 NTFS / D: 后面隔着 WINPE），给 `-RemoveAndroid` 的 GPT 解析与断言用 |

```sh
bash scripts/live/build-live.sh --boot-img … --firmware out/vendor-firmware   # 顺带产出安装包
bash scripts/windows/test-setup.sh
```

## 几个不显然的决定

* **脚本只划安装器自己要的空间，给 Android 的空间到安装器里分**（用户 2026-09-27："更改磁盘应该在安装的时候进行，
  安装安装器应该仅划分自己需要的空间"）。原先是脚本一次缩出 64 GiB 给 Android + 4 GiB 给安装器。现在：
  * GK3LIVE 按安装包内容算（`Get-LiveMiB`：内容 ×1.25 + 128 MiB，按 256 MiB 取整，至少 512 MiB）；`-LiveMiB` 可覆盖
  * 给 Android 的空间在安装器里"缩小现有分区腾出空间"—— 那边的 `gk3_shrink` 拒绝休眠 / 快速启动 / 脏卷（§5.10 的 #1）
  * **例外：要缩的卷加了密**（BitLocker / 设备加密，`VolumeStatus` 不是 `FullyDecrypted`，"等待激活"也算）：安装器缩不了
    （blkid 认作 BitLocker，`why=bitlocker`），只有 Windows 能 ⇒ 没给 `-AndroidGiB` 时问一次"现在就缩多少"（回车 64，0 = 不缩）
  * **快速启动**：~~只在"要到安装器里缩 D:"这条路上关~~ **2026-10-05 起一律关**（设计稿 U18：装成双系统之后 Android 会写共用的 ESP，
    Windows 从快速启动恢复时可能把它写坏，§4.9.10）⇒ 开着就说明、确认后把 `HiberbootEnabled` 设 0，旧值记进状态文件；
    装上 Android 之前 `-Uninstall` 恢复，装上之后一直关着（伴随工具每次开机还会再看一眼，Windows 更新又打开了就再关）
  * `-AndroidGiB <N>`（≥24）照旧可以让 Windows 一次缩好
* **live 放在新建的 FAT32 分区上**，不放 ESP（出厂 ESP 只剩约 188 MiB，Android 自己要 150）、不放 C:（可能是加密的）。
  分区建在缩出来那段的**开头**，Android 装在它后面 —— 与 fixture 场景 `windows-live` 的布局一致。
* **进安装器用 `bcdedit /set {fwbootmgr} bootsequence`**（只下一次），不改默认启动项；不想装了重启就回 Windows。
  备选 `-UseFallbackPath`：接管 ESP 的回落路径 `\EFI\Boot\bootaa64.efi`（原件留 `.before-gaokun3`）——
  这是本机 2026-08-20 在 Windows 还在盘上时**实测过**的机制（`docs/hw-inventory.md` 第 8quater 节），也是
  装完之后 `gk3_apply` 让 systemd-boot 接管开机用的同一个办法。
* **WiFi**：默认只带当前连着的那个。WPA2 写的是按 802.11i 推导出的 64 位十六进制 PSK，**不是明文密码**；
  WPA3（SAE）用不了预推导，只能写明文；企业网 / WEP 跳过。`netsh` 导出的明文临时文件在 `finally` 里删。
* **文件格式**：`.ps1` 必须 UTF-8 带 BOM（Windows 自带的 PowerShell 5.1 没 BOM 就按系统代码页读，中文全乱）、
  CRLF；`.cmd` 只用 ASCII。`build-bundle.sh` 与 `test-setup.ps1` 都会核对。
* **不用 PowerShell 7 的语法**（`?:`、`??`、`&&`、`?.`）—— Windows 自带的是 5.1。`test-setup.ps1` 按语法树查。

## Windows 伴随工具（S12 / U23，2026-10-05，【预览】）

设计稿 `docs/boot-entry-design.md` §4.9.15（及 §4.9.3 / §4.9.4 / §4.9.6 / §4.9.10 / §4.9.13）。Windows 换掉 `\EFI\Boot\bootaa64.efi`
之后 Android 就不可达了，只有 Windows 侧能及时发现 —— 所以 Windows 侧做成常驻的。⚠️ **还没在真 Windows 上跑过**（D18 ⇒ 标"预览"）：
只有容器里的测试（下面）；Parallels 的 D4、群友真机的 D5 / D6 都还没做。

**装在哪**：免 U 盘安装的最后一步自动装；从 U 盘装双系统的用户，U 盘的 FAT 分区上有 `gaokun3-windows\`（`build-usb.sh --windows-tools`，
`build-live.sh` 默认带上），回到 Windows 双击里面的 `gaokun3-setup.cmd`（不带参数 = 安装伴随工具）。装完：

* `%ProgramFiles%\gaokun3\`：`gaokun3-setup.ps1` / `.cmd` 的拷贝（只有管理员能改 —— SYSTEM 任务跑的就是这一份，所以不是提权通道）
* 计划任务 `\gaokun3\`：`BootCheck`（开机、SYSTEM）、`Notify`（登录、Users 组、最低权限）、`RebootToAndroid` / `DefaultAndroid` / `DefaultWindows`
  （没有触发器、SYSTEM、命令行固定）；`WindowsShutdown` 只在打开 U25 时才建
* 开始菜单 `gaokun3`：重启到 Android、开机默认进 Android、开机默认进 Windows（这三项**不提权**，只是 `schtasks /Run` 触发上面的固定任务，
  **传不进任何参数**）；修复 Android 启动、检查启动状态、仅暂停 BitLocker、卸载 Android（这四项经 `.cmd` 请求管理员）
* `%ProgramData%\gaokun3\`：`companion.json`（BIOS 基线、U25 开关、快速启动 / 休眠的原值）、`boot-check.json`（开机自检结果）、
  `companion.log`、`result-<动作>.json`（SYSTEM 任务的回执，开始菜单那边等着读）

| 子命令 | 做什么 |
|---|---|
| （开机任务，默认开、**不可关**） | ① `bootaa64.efi` 与 `EFI\systemd\systemd-bootaa64.efi` 比 sha256：等于 `bootmgfw.efi` = 被 Windows 换掉了 → 登录时弹窗、点"是"一键修复；是别的东西只提示。② `LoaderEntryDefault` 规范化：只允许"不存在"或 Windows 条目 id（`auto-windows` / `gk3-windows.conf`，只按 ASCII 不分大小写），别的删掉 —— 与 `tools/gk3boot/core/src/dual.c` 的 `gk3_defvar_classify` 同一组测试向量；读不出（不是"不存在"）就不动。③ BIOS 版本变了 → 提示（安全启动可能被重新打开、BitLocker 可能要密钥）。另外每次看一眼：删掉免 U 盘安装留下的 bcdedit 对象、GK3LIVE 去盘符（U19，只用 `Remove-PartitionAccessPath`）、快速启动又开了就关。**只通知、不自动修**（修要先暂停 BitLocker，得人同意） |
| `-RepairBoot [-Check]` | 只读体检（`-Check` 到此为止，有问题退出码 2）；`bootaa64.efi` = Windows 启动管理器（或不在）时：BitLocker 开着（或读不出）先 `Suspend-BitLocker -RebootCount 1`（没有 BitLocker 模块退回 `manage-bde -protectors -disable C: -RebootCount 1`），备份 `.before-gaokun3`（已有不覆盖），拷回 systemd-boot、核 sha256。是别的东西（另一个 Linux）只报告。幂等。U15（自有启动项）1.0 不做 |
| `-RebootToAndroid` | 读 loader.conf 的 `default`（只接受 `…-android-<槽>.conf`），写 `LoaderEntryOneShot`（UTF-16LE + NUL，属性 7，`SetFirmwareEnvironmentVariableExW`，先 `AdjustTokenPrivileges` 打开 `SeSystemEnvironmentPrivilege`），读回逐字节核对，`shutdown /r /t 0`。写不进就提示"重启后在菜单里手选"、不重启。**Windows 能不能写这个变量【未验证】** |
| `-SetDefault android\|windows` | `windows` = 写 `LoaderEntryDefault` = Windows 条目 id（有 `loader\entries\gk3-windows.conf` 用它，否则 `auto-windows` —— 与 `gk3boot.c` 的 `win_entry_id` 同一条规则）；`android` = 删掉它 |
| `-SuspendBitLocker` | 只暂停 2 次重启，别的都不碰（U 盘路径"关安全启动之前"那一步，§4.9.7 规则 6） |
| `-RemoveAndroid [-NoExtend]` | 卸载 Android、回到纯 Windows，顺序是硬约束：0 预检（只读：裸读系统盘 GPT 拿分区名 —— `Get-Partition` 给不出；名字在 Android 名单里、类型是 Linux filesystem、偏移与 Windows 看到的一致、每个名字只出现一次、内容不是 NTFS / BitLocker / FAT、boot / super 至少一个认得出 `ANDROID!` / LP 元数据、misc ≤ 4 MiB；GK3LIVE 按卷标 + `gaokun3\live.squashfs` 认、只认系统盘上的；ESP 上要有 bootmgfw 或备份）→ 暂停 BitLocker 1 次 → 1 `bootaa64.efi` ← **当前的** `bootmgfw.efi` → 2 删 ESP 上我们的东西（绝不碰 `EFI\Microsoft`、`EFI\UpdateCapsule`、`Persisted_Capsules.bin`、`OneKeyLog.txt`）→ 3 删两个 Loader 变量 → 4 删分区、D: 紧挨着才扩回去（出厂布局 D: 后面是 WINPE 就不扩、说明原因）、恢复快速启动 / 休眠 → 5 卸掉伴随工具。ESP 上还有别的 Linux 的条目时：只删我们的条目与我们写的变量，保留 `loader\`、`EFI\systemd\`，不动回落路径 |
| `-WindowsPreset on\|off` | U25：Windows 每次开机写 `LoaderEntryOneShot` = Windows 条目，Windows **关机**（不是重启）时比较后删掉 ⇒ Windows 里的任何重启（含更新的自动重启）都回 Windows。**默认关**（设计稿：D4/D6 证实能写变量、D4 ⑨ 找到可靠的关机 / 重启判据之后再默认开）。关机 / 重启的判据用系统日志 Event 1074（User32）的第 5 个参数，只认得中英文，认不出按关机处理 |
| `-Hibernate ask\|off\|keep` | 安装伴随工具时，U24：要不要关掉整个休眠（`powercfg /hibernate off`）。`ask` 问你（`-Yes` 时按"不关"） |

**与设计稿不同 / 补充的取舍**：
* `-Uninstall` 在 Android 装上之后**不**恢复快速启动（§4.9.10 写的是"`-Uninstall` / `-RemoveAndroid` 还原"）：那时机器仍是双系统，U18 要它关着；只有没装 Android 时、以及 `-RemoveAndroid` 才恢复。
* `-Uninstall` 原先按卷标删 GK3LIVE，没区分盘 —— U 盘介质的卷标也是 GK3LIVE（`build-usb.sh` 的 `mformat -v`），插着 U 盘跑就可能删错。现在只认系统盘上的。
* 开机自检在 SYSTEM 下跑、开机时没有桌面可弹 ⇒ 结果写文件、`Notify` 任务在用户登录时弹（确认过的记在 `%LOCALAPPDATA%\gaokun3\ack.json`；`bootaa64.efi` 被换掉那一条每次登录都弹，直到修好）。"默认项被重置""BIOS 变了"这类事件在状态文件里留 7 天，免得两次开机之间没人登录就丢了。
* `-RemoveAndroid` 在 D: 不相邻时**照删、不扩**（不是整个停下），确认页上先写明。

**测试**（`bash scripts/windows/test-setup.sh`，2026-10-05：通过 237 · 失败 0，wpa_supplicant 核对 3/3）：伴随工具部分 198 条 ——
静态（变量名后面紧跟中文、P/Invoke 的 C# 按 `-langversion:5` 编得过且反例编不过）、分类向量、字节格式、任务 XML（SYSTEM / Users 主体、
触发器、参数白名单）、真盘镜像上的 GPT 解析（与 `sgdisk -i` 逐项相同）与内容识别、开机自检的各分支、`-RepairBoot` 的顺序（暂停
BitLocker 那一刻 `bootaa64.efi` 还是 Windows 的）与幂等、"重启到 Android"的开始菜单 → SYSTEM 任务 → 回执、写不进变量时不重启、
`-Uninstall` 的回归（**Android 装着时 `EFI\gk3boot`、`EFI\systemd` 逐字节不变**）、`-RemoveAndroid` 删的正好是那 7 个分区 / 绝不碰的文件 /
顺序 / 三种拒绝 / 别的 Linux 共用 ESP。**测的是我们的判定与顺序，不是 Windows 本身** —— 下面这些只有真 Windows 能回答。

**只能等 Parallels（D4）/ 群友真机（D5 / D6）的**：
1. `SetFirmwareEnvironmentVariableExW` / `GetFirmwareEnvironmentVariableExW` 在本机（高通，变量服务经 TZ）上能不能读写 systemd-boot 厂商 GUID 下的变量；零长度写是不是真的删除（D4 原型、D6 真机）
2. 计划任务：`RegistrationInfo/SecurityDescriptor`（给 Authenticated Users `GRGX`）能不能让普通用户 `schtasks /Run`；Users 组 + 登录触发的任务能不能把 MessageBox 弹到用户桌面；Event 1074 触发的任务在关机途中来不来得及跑完（D4 ⑨）
3. Event 1074 的"关机类型"字串在中 / 英文 Windows 上到底是什么（U25 的判据）
4. 用 `CreateFileW` 打开 `\\.\PhysicalDriveN` 按 4 KiB 对齐读 GPT；`Remove-Partition` 删 Linux 类型的分区；删完 `Get-PartitionSupportedSize` 是否马上看到空出来的空间（中间调了 `Update-Disk`）
5. `Suspend-BitLocker -RebootCount 1` 在中途进 Android 时怎么数（D4 ⑪）；拷回 systemd-boot / 还原 bootmgfw 后 BitLocker 到底要不要密钥（D4 ⑥、D6）
6. Windows 更新会不会写回 `\EFI\Boot\bootaa64.efi`（D4 ①、D7）—— 那正是开机自检要抓的事
7. `-RemoveAndroid` 的完整往返（脚本路径装出来的布局：装上 → 卸掉 → Windows 正常、BitLocker 不要密钥，D4 ⑤）

## ✅ Parallels 虚拟机实测（2026-09-25）

用户那台 Windows 11 ARM 虚拟机（25H2，10.0.26200，中文）的**克隆**上跑的，原机没动，测完克隆已删。
克隆里关掉安全启动、从 C: 切出一个 60 GiB 的 NTFS "Data" 卷（虚拟机里 D: 是光驱，所以是 E:）当出厂的 D:。
辅助脚本在 `vmtest/`（`prlctl exec <vm> powershell -File \\Mac\<共享>\….ps1`；以 SYSTEM 身份跑，日志写成 UTF-8）。

| 验了什么 | 结果 |
|---|---|
| 中文输出（BOM）、预检、安装包 sha256 校验 | ✅ |
| Data 太小时**动盘之前**就拒绝（40 GiB 缩不出 24 + 4 GiB 再留 10 GiB） | ✅ |
| 压缩 E:（60 → 32 GiB）、GK3LIVE 紧接其后（偏移 = E: 末尾）、再往后正好 24 GiB 空闲 | ✅ |
| ESP 写入、`bcdedit /copy {bootmgr}` + `displayorder` + `bootsequence` | ✅ |
| **重启 → 固件认了"只下一次"**，systemd-boot 菜单：gaokun3 installer（默认）/ **Windows 11（自动认出）** / … | ✅（Parallels 的固件，不是华为的） |
| 重置 → 直接回 Windows，`bootsequence` 已被固件清掉，默认项没动 | ✅ |
| `-Uninstall`：分区（偏移 / 大小 / GUID）、ESP 文件、固件启动项与安装前**完全一致**，E: 扩回 60 GiB，数据文件完好 | ✅（第一轮留下空的 `loader\entries`，已修，第二轮干净） |
| `-UseFallbackPath`：原件留 `.before-gaokun3`、撤销后 `bootaa64.efi` 逐字节还原 | ✅ |

两处只属于虚拟机的现象：systemd-boot 的倒计时在 Parallels 的 ARM 固件里**不走、也收不到按键**（真机上 15 秒倒计时每天在用，不受影响）；
我们的内核在虚拟机里起不来（它是给 sc8280xp 编的，一个核空转）—— 所以"从安装器到装完"那一段只能在真机上验。
Windows 的分区序号（`PartitionNumber`）在撤销后变了（中间重启过），但它的引导按 GUID / 偏移找分区，不看序号。

## ⚠️ 还没验证的（按风险排）

这些脚本是在**没有 Windows 的机器上**写的（唯一一台的 Windows 已在 2026-08-20 抹掉）。纯逻辑有单元测试，
下面这些只能在 Windows 上验：

1. **BitLocker / 设备加密**：关安全启动、改了启动方式之后，Windows 下次开机可能要恢复密钥。脚本在 BitLocker 开着时
   要用户先确认拿得到恢复密钥，然后 `Suspend-BitLocker -RebootCount 2`；这一步排在安全启动检查**之前**
   （2026-10-04，v1.0 计划 GUI-7 / INST-11：原先排在后面，用户照提示关掉安全启动回来时才第一次看到提醒）。
   会不会触发、暂停 2 次重启够不够（关安全启动回来一次 + 装完第一次经 systemd-boot 进 Windows 一次）、
   恢复保护时按哪条启动路径重新封存 —— 都没实测过。
2. **华为固件认不认 `bootsequence`**（UEFI 的 BootNext）。Parallels 的固件认；华为的没验。不认的话会直接进 Windows，脚本提示改用 `-UseFallbackPath`。
3. ~~`Resize-Partition` / `New-Partition -Offset` / `Format-Volume -FileSystem FAT32` / `mountvol /S`~~ ✅ 虚拟机里验过（上表）。
   ⚠️ 但 2026-09-27 改成"只划自己的空间"之后的新路径（自动算 GK3LIVE 大小、加密卷的提问、关快速启动）只有 `test-setup.ps1`
   的单元测试（39/39），没在虚拟机里重跑过 —— 虚拟机测试脚本 `vmtest/run-setup.ps1` 仍给 `-AndroidGiB 24`，走的是老路径
4. `Get-NetConnectionProfile` 的网络名与 `netsh` 导出的配置名是否一致（虚拟机没有 WiFi，验不了；不一致时带不上 WiFi，安装器里再连即可）。

ⓘ 安装包里的 squashfs 带着华为专有的 GPU zap shader —— 随包公开发布（用户 2026-09-27 定 B23 ①：随镜像发，与 ROM 同待遇 —— 已发布的 ROM 的 vendor 里本来就带着它）（`docs/TODO.md` 的 B23）。

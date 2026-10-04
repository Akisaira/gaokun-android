# 免 U 盘安装：Windows 那一侧

用户 2026-09-25 的要求：LiveCD 的初衷之一是**免 U 盘安装**，并且要能**装双系统**。
新用户手上是 Windows，所以得有个办法在 Windows 里把安装器放上内置盘 —— 就是这里的脚本。
安装器那一侧（介质与目标同盘时放行双系统、只拦整盘清空）见 `docs/stage7-flutter-debian.md` §5.8。

| 文件 | 是什么 |
|---|---|
| `gaokun3-setup.cmd` | 给用户双击的入口：以管理员身份运行同目录的 `.ps1`，参数原样传过去 |
| `gaokun3-setup.ps1` | 预检 → 让 Windows 自己压缩 D:，**只缩出安装器自己要的**（按安装包内容算，约 0.5–2 GiB）→ 建 FAT32 分区 GK3LIVE 放 live → ESP 放 systemd-boot 与启动项 → bcdedit 设"只下一次"。给 Android 的空间在安装器里缩。`-Uninstall` 撤销 |
| `build-bundle.sh` | 造安装包目录 + zip（`build-live.sh` 在构建容器里调它）→ `out/live/gaokun3-windows{,.zip}` |
| `test-setup.ps1` / `test-setup.sh` | 测试：PowerShell 容器里测语法、编码、5.1 兼容与全部纯逻辑；再拿 live 镜像里的真 wpa_supplicant 解析生成的 WiFi 配置 |

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
  * **快速启动**：要到安装器里缩 D: 的话必须关（它让分区停在休眠状态，安装器会拒绝缩）⇒ 开着就说明、确认后把
    `HiberbootEnabled` 设 0，旧值记进状态文件，`-Uninstall` 恢复。只在这条路上动它，替 Android 缩过了就不碰
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

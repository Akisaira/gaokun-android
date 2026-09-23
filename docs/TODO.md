# 待办清单

最后更新：**2026-09-23**（全表对账：把 v0.6.2 发布与 SELinux 第五轮之后已经做完、但正文还写着 ⬜ 的条目逐条核对并收口；
新增两条 —— 待机默认值对老用户的影响（S1）、全新安装丢触摸参数（B15 实锤）。
同日第二轮：按用户反馈关 A0；修掉 B15 / B17；issue #5 声明平板（T5）；12 个过时脚本归档到 `scripts/archive/`）

这份清单的排序原则是**用户能不能感觉到**，而不是有趣程度。每条都尽量写出
**具体的第一步** —— 没有第一步的条目只是愿望，不是待办。

状态表与公开招募项在 [`../README.md`](../README.md)；每条的证据在
[`stage4-findings.md`](stage4-findings.md) 等案卷里；历史在
[`project-log.md`](project-log.md)。

> ⚠️ **本次对账的边界**：2026-09-23 设备不在线（USB 无、`192.168.10.0/24` 全段 5555 无应答），
> 所以凡是写着"应已随 v0.6.2 进镜像"的，依据是**提交时间早于构建戳**（`a7ce25f` 09-14 14:50 <
> `1789570683` = 09-16 22:58）加 09-16 `sync-device-tree.sh` 的一致性断言，**不是设备上的核对**。
> 下次设备在线时先 `adb shell` 看一眼 `/vendor/bin/gaokun3-usbrole.sh` 与相机 HAL 是否是新版。

---

## 总表：现在还剩什么

**统计（2026-09-23）**：用户能感觉到的缺口 **9** 条未完 · 工程债 **12** 条未完 ·
等用户点头的对外动作 **5** 条 · 明确搁置 **4** 条。下面按"下一步是什么"分组，
详情见各自的条目。

### ▶ 眼前的下一步：v0.6.3 候选版（2026-09-24 重新构建）装机验收

⚠️ **测试版 `1790184271` 作废**：它的 dtb（`6b8c7dea…`）带着 0049 的前身（后摄 270），而用户目视确认的是 **180**（[#119 §7](stage4-findings.md)）。
**候选版**（未发布；`lineage_gaokun3-bp4a-userdebug`）：构建戳 / incremental / payload sha 见下面「产物」一行（构建完填）。
内核 #24 不变；dtb = **0048 版 `8b390878…`**（与设备 ESP 上 `slot_a` 的同一份）；**待机默认已改回 1（S1）**。
比 `_a` 上的 `1789737346` 多出：PR #6 相机（AF / JPEG 旋转 / 旋转崩溃，维护者修过 14 处 + 键清单）、
T5 平板声明、B16 Wi-Fi TCP 缓冲 RRO、B18 remoteproc、usbrole follow + 0048（USB 角色）、
#117 §19 那 4 处 SELinux 规则 + usbrole/rproc-kick 规则、S1。
★ 开发机已显式 `setprop persist.vendor.gaokun3.allow_suspend 0` 并核对落盘 ⇒ 装上候选版后开发机仍不睡。
产物：（构建中）

**装**（⚠️ 要人在场：新系统第一次启动；`_b` 当前不可启动，装完 OTA 就是写进 `_b`）：
payload 先上设备（R2 staging 要凭据：`release.sh --stage-only`；没有凭据就直传，白天约 1.3 MB/s ≈ 17 分钟，
续传别用本机 rsync，见 CLAUDE.md 运维坑 1）→ `bash scripts/install-ota-local.sh --check` → `--go` → 重启。
脚本会把 `default` 掰回 `_a`、只 oneshot 到新槽，起不来下一次重启就回 `_a`。
⚠️ 设备上 09-18 的旧 payload 已改名为 `payload-1789737346.*`，免得误装旧版。

**验收清单**（装好后逐条）：
1. ☐ `getprop ro.build.date.utc` = 候选版的戳；`getprop ro.build.characteristics` = `tablet`（issue #5 请报告者测 QQ）
2. ☐ 解锁后开 Aperture：后摄取景仍是正的（dtb 与现在同一份，应当不变）、点按对焦能锁；**前摄看一次**（设备树 0，未目视）
3. ☐ `adb shell /data/local/tmp/gaokun3-ncam-smoke`（已在设备上）后摄 / `front` 全过
4. ☐ 拔插一次 USB 线：USB adb 能回来（0048 + follow）
5. ☐ `dumpsys connectivity | grep TcpBufferSizes` 含 `8388608`；系统更新下载速度
6. ☐ 开机 ≥8 分钟后 denial 普查（#117 §20 的办法，dmesg 要从 ~0 秒开始）
7. ☐ `ps -AZ | grep -E "rprockick|usbrole"` 各自在自己的域；三颗 DSP running
8. ☐ **S1**：`getprop persist.vendor.gaokun3.allow_suspend` = 0（开发机的持久值）且 `cat /sys/power/wake_lock` 含 `gaokun3_usbrole`；
   息屏 2 分钟后 Wi-Fi adb 仍在（= 没睡）。镜像默认值 `grep allow_suspend /vendor/build.prop` = 1
都过 ⇒ 这一版就是 v0.6.3：`release.sh --no-build`（脚本现在会断言 allow_suspend 默认为 1）。发版要用户点头。
⚠️ **变体必须 `lineage_gaokun3-bp4a-userdebug`**（#117 §15）。

### 🔴 第一梯队：用户明确点名 / 用户能直接感觉到

| # | 事情 | 现在卡在哪 | 下一步（具体） |
|---|---|---|---|
| **S1** ✅ | **待机默认值 1→0 会波及老用户**（2026-09-24 已改回 1，见下） | 用户 2026-09-23：这是 SELinux 那轮（属性改名）带出来的，不是为待机本身做的决定。09-18 为改名把 `persist.vendor.gaokun3.allow_suspend` 默认设成 0（`device.mk:526`），`device.mk` 注释只说"新装机默认不睡"。但 v0.6.2 的用户**绝大多数从没设过这个属性**（旧默认 1）⇒ OTA 一过、新名字取默认 0 ⇒ **所有老用户也会失去 s2idle**，README 的"待机 ✅"随之失真 | ✅ **用户 2026-09-23 定**：开发期保持 0，**正式版发布前改回 1**。✅ 2026-09-24 候选版起已改回 1（`device.mk` 的 `PRODUCT_VENDOR_PROPERTIES`），开发机已 `setprop … 0` 并核对落盘；✅ `release.sh` 断言发版的 `vendor/build.prop` 里是 1（`--stage-only` 不拦）。⬜ 装机验收清单第 8 条 |
| **T1** | **触摸** | ✅ v0.6.2 已发（跳点限速线、fuzz=0、按下 17 ms、面积轴、6 个驱动缺陷、可观测性，[#114](stage4-findings.md)–[#116](stage4-findings.md)）。剩：手掌碎成多触点（不影响点击，三种阈值法实测全否） | 下一版驱动做跨帧形态判据；轴已经有了，可以顺手写触摸 IDC（`touch.size.calibration`，本机现在 `ConfigurationFile: <none>`） |
| **B15** ✅ | **全新安装丢触摸参数**（2026-09-23 已修） | ★ 实锤：`scripts/install-gaokun3.sh:251-257` 写死的 cmdline **没有** `himax_hx83121a_spi.disable_pressure=0`（`BoardConfig.mk:134` 有）⇒ 按 INSTALL.md 全新装 v0.6.2 的机器**没有触点面积轴**，直到第一次 OTA 的 postinstall 把 cmdline 同步过去 | ✅ `install-gaokun3.sh` 改为从 boot.img 头读 cmdline（`cmdline[512]@64 + extra_cmdline[1024]@608`，与 `bootimg_extract.cpp` 同一写法），读不到就拒装。拿 v0.6.2 发布的 `boot.img`（sha `975d7987…`）实测：解出的 cmdline 与 `BoardConfig.mk` **逐字相同**。`deploy-android.sh` 已归档。⬜ 剩 `scripts/live/installer-lib.sh:506` 那份（更旧，还缺 `boot_devices` / `init=/init`），随 B4 一起改 —— 它还假设发布目录有散装 `Image`/`dtb`/`ramdisk`，而发布只带 `boot.img` |
| **T2** | **Google 未认证** | Play 商店报"设备未经 Play 保护机制认证" | 工具与文档已就位（`scripts/google/gsf-android-id.sh` + INSTALL.md）。**剩下的是用户动作**：拿 Android ID 去 google.com/android/uncertified 登记 |
| **T3** | **相机画质** | 暗光噪点、闪光白墙过曝 34%、偏绿（[#112](stage4-findings.md) §5）。降噪 + 预闪按亮度收敛 + 曝光回填**应已随 v0.6.2 进镜像**（见顶上"对账边界"），1:1 样片颗粒明显变细（#112） | 还没写的两条：闪光帧下发 `ExposureValue` 负补偿；libcamera AWB 剔饱和像素（值得投上游）。CCM 要色卡（用户提供）。手电筒亮度档位（`turnOnTorchWithStrengthLevel`） |
| **T4** | **息屏 USB adb 断** | `usbrole.sh` v2（插着主机不睡）**应已在 v0.6.2 里**；但在 S1 定下来之前默认根本不睡，这条暂时无感 | 原生化要先修 UCSI 的数据角色（A6，现在是反的） |
| **A1** | 音频/蓝牙长期运行后死锁 | 用户报过，我们从未复现 | 设备在线时先 `ls /data/vendor/gaokun3/` 看开发机自己有没有抓到过 `hangdump-*`；否则等下次死锁把目录要过来 |
| **T5** 🆕 | **声明本机是平板**（[issue #5](https://github.com/vahiru/gaokun-android/issues/5)） | `ro.build.characteristics` 是 `default` ⇒ QQ 不给平板模式登录。原因：从没设过 `PRODUCT_CHARACTERISTICS`，而 `common_full_tablet_wifionly.mk` 也不设它 | ✅ 已写 `lineage_gaokun3.mk`：`PRODUCT_CHARACTERISTICS := tablet`（依据 `build/make/core/product_config.mk:425-428`）。⬜ 下次构建后 `grep ro.build.characteristics …/system/build.prop` 验；请报告者实机测 QQ。⚠️ issue 里「网页把设备认成 Linux」**不一定**跟着好 —— Android 的 UA 本来就含 `Linux; Android`，网页是否给平板版由浏览器决定，不看这个属性（未验证） |
| **A6** 🔺 | **USB 角色 / #27 拔插后 adb 不回来** | ★ 2026-09-23 真凶查到（[#118](stage4-findings.md) §7）：port0 控制器**任何一次**角色切换后都坏 —— host 时 xhci `Host halt failed, -110`，切回 device 后 gadget `-524`、只能重启。与 0012 记过的 pipe 时钟 -110 同签名，缺 `qcom,select-utmi-as-pipe-clk` ⇒ `patches/0048` —— ✅ **2026-09-23 上机验证**：来回切三次 xhci 200 ms 绑上、UDC 400 ms `configured`，`-110`/`-524` 各 0 次（[#118](stage4-findings.md) §8）。角色策略：用户态 `follow`（电气探测，不信 EC）A/B 两场景实测通过、C 只测了状态机。本机 `slot_a` 的 dtb 已手工换成 0048 版（备份 `.pre0048`）；⬜ 随下次构建进镜像（prebuilt-boot 的 dtb 已换）；⬜ hub/U 盘/充电器真机场景仍未测（用户手边没有）。另：2026-09-23 直接问 EC（[#118](stage4-findings.md) §6）：插着主机时 `partner_type=2`（UFP，应为 1），**没插也是 2** ⇒ 可能是常数；EC 端口数据里没有角色位 | **要用户插拔**：U 盘 / 纯充电器 / 扩展坞各跑一次 `scripts/usb/ucsi-snapshot.sh`，看 partner_type 与 pwr_dir 怎么变，再定 quirk（扩展坞会 DR_Swap，不能盲用"受电⇒对方是主机"） |
| **A3** 🔄 | **自动亮度** | ★ 2026-09-23：`tcs3701`（ams AG）**注册出来了、芯片应答**（[#118](stage4-findings.md) §5，#72 时是"没有提供者"）。但使能后只回一条 `msg_id=130`、载荷 `08 04`，0 条读数；513/514 三种请求同一回应 ⇒ 传感器侧拒绝激活 | 查 130/4 的语义与 libssc 怎么使能光感；最像的差别是 registry（我们是空文件、只读，psacal 拷的是本机 Windows 生成的）。为什么现在应答：候选 L2C，未做对照 |
| **A5** | 恢复出厂设置不起作用 | 走 misc+recovery，而本机 recovery 起不来 | 依赖 B3（自研 EFI 加载器）或让 recovery 能启动 |

### 🟡 第二梯队：工程债（不修不会坏，但会反复咬人）

| # | 事情 | 为什么值得做 / 现状 |
|---|---|---|
| **B1** | SELinux 转 enforcing | 第五轮（[#117](stage4-findings.md)）7 处规则：3 条实机验证、2 个标签实机确认、属性改名生效；**另 4 处已写未验**（见"眼前的下一步"）。两个结构性阻塞原封不动：`gaokun3_smmustall`（正解 = B6）、`gaokun3_hangdump`（36 条，60 秒才采一次样）。09-18 误编 user 版 = 一次真 enforcing 试跑：**起不来** |
| **B0** | 让构建机的树**就是**本仓 checkout | **已经咬了六次**。`kernel-apply-patches.sh --verify` 与 `sync-device-tree.sh`（带断言）是探测器，不是根治 |
| **B5b** | UBWC：仓库写着关 | `device.mk:174` 仍是 `nocompression`，**一次测量都没有**。下版构建前删那行并带一次实测 |
| **B6** | GPU SMMU 中断根治 | 做掉它 `smmu-nostall.sh` 整个消失，B1 的一半阻塞跟着消失 |
| **B9** ✅ | SLPI handover 噪声 | **2026-09-24 结案**（[#119](stage4-findings.md) §4）：它是 SSC 向 AP 投递一批数据的门铃（封顶 5 Hz，采样率 25→50 Hz 不变，没人读时为 0），不是故障。`patches/0014` 的 ratelimit 就是正解 |
| **B12** | 释放 R2 桶前要有国内可达的镜像 | GitHub 附件国内不可达。要用户定方案（Worker 反代 / 保留桶） |
| **B16** 🔄 | 设备外网单连接慢 | **2026-09-24 定位并修**（[#119](stage4-findings.md) §3）：到海外 CDN 的 RTT ~294 ms，Android 默认 Wi-Fi TCP 接收上限 2 MB ⇒ 单连接 ~3.5 MB/s；临时改 8 MB 实测 9.1–9.8 MB/s（4 连接合计 12.6 MB/s，局域网 32 MB/s）。`rro/Gaokun3WifiOverlay` 进下一版镜像。⬜ 装机后核对 `TcpBufferSizes` |
| **B3** | 自研 EFI 加载器 | A5 与"默认启动项永远留救援"都依赖它 |
| **B7** | 用轻量系统替掉救援 Ubuntu（= B4） | 24.6 GiB 换成 55 MiB squashfs，⏸ 用户暂缓 |
| — | 相机零碎 | `patches/0022` 仍未在**健康**状态下验证 unbind/rebind；libcamera 生成源码仍靠手工，未改成 Soong `genrule`（`patches/libcamera/README.md:34`）；`kDarkLuma=50` 是启发式 |
| **B18** 🔄 | init 泄漏 remoteproc 引用 | 已修（[#119](stage4-findings.md) §5）：`gaokun3-rproc-kick.sh` 只对不在运行的 DSP 写 start；新域 + usbrole 补 sysfs 规则，`selinux_policy` 通过。⬜ 随下一版镜像验证 |
| **B19** 🆕 | 没有回落槽 | `_b` 不可启动（[#118](stage4-findings.md) §2）。出事只能靠救援系统；Virtual A/B 合并后 `-cow` 还在的原因未查 |
| **B20** 🆕 | wlan0 MAC 每次开机都变 | 框架不做 MAC 随机化，驱动每次给新地址 ⇒ 每台机器在路由器上都是"新设备"，IP 漂。本机已用静态 IP 绕开。★ 2026-09-24 查清两条路：① ath11k 先读 DT 的 `local-mac-address`（`mac.c:10712 device_get_mac_address`），读不到才用固件给的 —— 但写死在 DT 会让所有用户同一个 MAC，不可取；② **Android 原生解**：`config_wifi_connected_mac_randomization_supported` 默认 false（`ServiceWifiResources/res/values/config.xml:373`），在 `rro/Gaokun3WifiOverlay` 里打开 ⇒ 每个 SSID 一个固定的随机 MAC。⬜ 故意没进这一版：它要 HAL 在连接前改 MAC，改不动可能连不上网，而夜里只有 Wi-Fi 上的 adb、没法远程救 —— 等有人在旁边时单独试 |
| — | tinymix 的 vendor 变体 | 有了它 `audioroute` 就不用挂 `vendor_executes_system_violators`（#117 §8） |
| — | 设备上的垃圾 | `/data/local/tmp` 2.8 GB 历次测试内核；ESP 上 `slot_cam5` 与 `cam5/6/7` 测试条目（现状未核对）。**删东西等用户点头** |

### 🟢 等用户点头的对外动作

| # | 事情 |
|---|---|
| **R** | 下一版发不发、发哪一版（见"眼前的下一步"与 S1） |
| **D5** | [PR #3](https://github.com/vahiru/gaokun-android/pulls) 的回复（已审完，等措辞） |
| **D6** | 把 `drm_crtc` 那个 `BUG_ON` 报到 dri-devel（**上游 master 现存缺陷，普通应用能 panic 整机**） |
| **D7** | v0.2.0-alpha 的 R2 产物删不删（2.1 GiB，删了老发布页的链接会 404） |
| — | `docs/upstream/` 里 **5 份内核补丁稿**一份都没发；另有可投 libcamera 的 `patches/libcamera/0002`（hi846）/ `0004`（ov13b10） |

### ⏸ 明确搁置（记录理由，不是忘了）
A2 硬件视频**编码**（查明后故意关闭）· ~~A3 自动亮度~~（**2026-09-23 解除搁置**，见第一梯队 A3）·
A6b WPA3 issue #2（本地不复现，要报告者配合）· B4 LiveCD 图形安装器（用户暂缓）。

### ✅ 本次对账收口的（正文原写着 ⬜，其实早做完了）
触摸脚本进镜像（T1a，v0.6.2）· 完整 ROM 构建（T1c，v0.6.2）· 指纹 incremental 不一致（T2，v0.6.2 为 `20260916145759`）·
`wpa_cli` 进镜像（A6b，`f068947` 09-12，v0.6.1 起）· `#14` 进默认槽 / 撤掉 camss 钉住（A7，`a87d79b`）·
扬声器"用户还听不到"（A′，#86 实测 PA=21）· 侧滑返回的导航栏（A0，#86）·
SELinux 第五轮"一行都没编译"（B1，#117 §11–§18 已编译并装机）。
`plan-2026-09-14.md` 与 `touch-morning-runbook.md` 已归档到 [`archive/`](archive/)。

第二轮（同日）：A0 侧滑返回（**用户确认已好**）· B15 全新安装的 cmdline（见上）·
B17 `find-device.sh` 改成 macOS / Linux / Git Bash 通用、扫全段不看 ARP（实测：无设备时 2.7 秒给出结论，`--ssh` 模式扫到并正确排除了一台陌生主机）·
12 个过时脚本归档到 [`../scripts/archive/`](../scripts/archive/README.md)（每个都写了取代者）。

---

## A. 用户能感觉到的缺口

### A9. ✅ 内核可重建性已修好并上机验证通过

**起因**：音量补丁内核起不来，查明是照本仓配方重建的内核缺两份**从未入库的
树外源码**（[#79](stage4-findings.md)）。**2026-09-11 全部做完**
（[#80](stage4-findings.md)）：

* `patches/0016`（ashmem，底本 ACK `android15-6.6` —— ★ 最后一个还带它的分支）
  与 `patches/0017`（xt_quota2，底本 `android16-6.12`）已入库并进 KPATCHES。
  内容取自构建机旧树 `~/gaokun/mainline-linux`，**是当年实测过的那一份**。
  6 处 API 漂移逐条写在补丁头里。
* ⚠️★★ 顺带查出 **`kernel-apply-patches.sh` 的指纹判据有假阳性**，
  已让 `patches/0009`（CPU 温控降频）静默漏打 —— **正是 M17 写这个脚本要防的
  那一个补丁**。判据已加固（挑最长的 3 条新增行、要求全部命中）。
* ✅ **上机一次成功**：新内核 `#3` 重启 37 秒回来、`boot_completed` 在 uptime 34 s；
  `/dev/ashmem` 在、`/proc/net/xt_quota/globalAlert` 在（netd 已在用）、
  8 个 CPU 温区全部 `trips=2 / cdev=1`、pstore 零记录；
  WiFi / 蓝牙 / 传感器 / GPU / Venus / root / 声卡全部正常。
* ✅ 新内核已**提升为常驻**（覆盖 `slot_b/Image`），测试脚手架已清，
  ESP 仍是 4 个条目、84% / 50 MB 可用。

★ **下次测内核照抄这套安全阀**（这次代价为零、没用上，但值得常备）：
条目里加 `androidboot.init_fatal_panic=true loglevel=7 panic=10` ——
`panic=10` 让 init 炸掉后**自动重启回 `default` 自愈**，不用按电源键；
`init_fatal_panic` 把 init 的 LOG(FATAL) 转成真 panic 落 pstore。

★ **重建验收判据（进发版收尾清单，两条都要）**：
① 设备 `/proc/config.gz` 与重建树 `.config` 做 diff —— 差出的每个符号都是一份
没入库的源码；② 两个内核镜像做**全字符串差集**，**外加 dtb 比 sha256**。
⚠️ 字符串差集**看不见 DTS**，0009 漏打就完全逃过了它。

### A0. ✅ 侧滑返回手势失效 —— 根因查明：这台机器从来没有过导航栏

⚠️★★ **答案 2026-08-24 就查出来了，但那一轮的工作整个没入库**，
直到 2026-09-12 才从构建机上抢救回来（[#82](stage4-findings.md)）。
在那之前本条一直写着"假说未证实、怀疑是桌面模式"—— **那个假说是错的。**

**根因**：手势返回的处理器（SystemUI 的 `EdgeBackGestureHandler`）是**随
NavigationBar 组件创建的**。本机没有声明导航栏 ⇒ 没有该组件 ⇒ 没有处理器，
也没有左右边缘的手势 inset，边缘往里滑什么都不会发生。

**实测证据**（桌面模式已关、`navigation_mode=2` 的干净状态下取的）：

```
dumpsys window windows   → 窗口列表里【只有 StatusBar，没有 NavigationBar】
SysUiState               → hasNavigationBar=false
InsetsSource mandatorySystemGestures → frame=[0,0][1600,42] sideHint=TOP
                            —— 只有顶部一条，左右两侧没有任何手势区
mSystemGestureExclusion  → SkRegion()（空，不是被应用屏蔽掉的）
```

AOSP 默认 `config_showNavigationBar=false`
（`frameworks/base/core/res/res/values/config.xml:2771`，注释说
"in the future this may be autodetected"）—— 那是给有实体按键的机器准备的。
本机没有实体导航键，**必须自己声明**，而我们此前从未声明过。

**修法已入库**：设备 overlay 里 `config_showNavigationBar=true`。
★ Lineage 不覆盖这一项（逐名核对过 `vendor/lineage` 的 common overlay），
所以设备 overlay 在这里有效 —— 不像 `config_isDesktopModeSupported`
那样要绕到 `crdroid-tree-fixes.py` 去改。

✅ **已随 ROM 生效**（#86 装机验收：`mNavigationBar=Window{… Taskbar}` 出现了）。
✅ **用户 2026-09-23 确认边缘侧滑返回已经好了。** 本条结案。

### T1. ✅ 触摸手感 —— 已随 v0.6.2 发布，只剩手掌碎块（[#114](stage4-findings.md)–[#116](stage4-findings.md)）

#### T1a. ✅ 幽灵触摸 + 不灵敏 = 同一个根因，已修（不需要新内核）
用户报「经常出现幽灵触摸、触摸不灵敏」。根因是**我们自己出厂的 game 预设**里的
`track_jump_dist2=6400`：驱动的跳点检测拿**原始位移**比阈值 ⇒ 它等于一条 **1.0 m/s 的限速线**，
越线后轨迹反复自毁、`debounce` 永远回不到 0 ⇒ **手指持续快过它时驱动一个点都不上报**。

实测（同一人同样甩动、录 event7 原始流）：**jump=6400 → 87 条轨迹（37% 是 ≤5 帧碎片）；
jump=0 → 6 条、0 碎片**。一次滑动被切成十几次触摸 ⇒ 滑动惯性反复清零（甩不动列表）、
手势被判取消（不灵敏），沿途多出来的"按下"**就是用户看到的幽灵触摸**。

* ✅ 两版预设的 `JUMP` 都清 0（`bin/gaokun3-touch-mode.sh`），`device.mk` 里那句错误的
  「不动任何信号处理门限」已更正。
* ✅ `patches/0038` 把判据改成**与预测位置的偏差**（复用匹配阶段已算好的 `cand[].dist2`），
  仿真验证：修正后到 5 m/s 不丢帧，且**仍能一致抓到 ≥10 mm 的真实换手指**（原版中速误触发、高速全漏）。
* ✅ 本机已现场改到最优（jump=0 / smoothing=0 / start_debounce=2）；开机属性设成 `daily`，
  **重启后会落到安全值而不是坏配置**（代价是 25 ms 平滑滞后，等下次构建带上修好的脚本就能切回 game）。
* ✅ 修好的 `gaokun3-touch-mode.sh` 已随 v0.6.2 进镜像（#117 §18 实机：`game` 预设 smooth=0 / jump=0 / pressure=1）。

#### T1d. ✅ 驱动全面审查，六个缺陷已修（`patches/0040`–`0045`，[#115](stage4-findings.md)）
读完 `himax-spi-core.c`(1478) + `hx-algo.c`(1133) 之后：

1. **`hx_detect_macro_zones()` 表满时是 `return` 不是 `break`** ⇒ 放弃扫描网格**剩下的全部**。
   噪声多（充电器耦合）时**屏幕下半部分的真实手指整个消失**，且无任何记录。→ `0041`
2. **掌压剔除把整个连通域删掉** ⇒ BFS 是 8 连通，指尖挨着手掌进同一 zone，删掉就把手指一起删了。
   → `0042` 改成标记（**默认行为逐位不变**），并给两个运行时旋钮救回手指。
3. **SPI 读重试发的是垃圾**（tx/rx 同一块缓冲，头已被覆盖）⇒ 三次机会实际只有一次。→ `0040`
4. **事件栈每帧切成两次 `spi_sync`**，第二次那 3 字节没人读。→ `0040`
5. ★★★ **驱动看不见自己** —— 见下 T1e。→ `0043`
6. **`resolution` 一直是 0**（从未调 `input_abs_set_res()`）。→ `0044`
7. 顺手：`W=1` 的六条 kerneldoc 告警。→ `0045`，改完**`W=1` 完全干净**

#### T1e. ✅ 给驱动装上眼睛（`patches/0043`）—— 这次最值钱的一条
27 个旋钮全可调，但**从"像素过阈"到"上报触点"之间每一级都能悄悄放行或丢弃候选，
而没有任何东西能说出是哪一级干的**。#114 那一晚只能靠读代码 + 写仿真 + 录 evdev 反推。

现在：`algo/stats`（22 个逐级计数器，写任意值清零）、`algo/contacts_log`（最近 16 个触点
出生时的 x/y/面积/信号/是否在边缘）、`debugfs .../frame_raw` 与 `.../frame`
（面板**产出**的 vs 流水线**判定**的 40×60 网格）。
工具：`scripts/touch/dump-state.sh`（一键取证）+ `grid.py`（画成看得懂的图）。

#### T1b. ⬜ 三道形同虚设的噪声闸门（`patches/0039`，默认值全不变）
Z8 孤立尖峰过滤实际从没生效（只毙掉八邻域和 <25 的尖峰）；边缘**单像素豁免** + `edge_boost` 把
边缘格乘 1.5（四角 ×2.25）⇒ 一个边缘噪点就能变触点，而拿平板的手正好扶在四边；
掌压规则 3 是死代码（`palm_density_low=400 < macro_threshold=800`，恒为假）。
已做成可调旋钮 `iso_nbr_ratio_q8` / `edge_min_area`。⚠️ 目前**没有证据**说用户的幽灵走这两条路 ——
留作幽灵真在边缘复现时的工具。

#### T1c. ✅ fuzz 与触点面积 —— 实机定案（2026-09-16，[#116](stage4-findings.md)）
* **fuzz = 0**，写进 DT（`patches/0046`）。依据是实测噪声而非手感：空载噪声 RMS 29.6 ⇒ 质心抖动
  σ 0.16/0.10 单位（不到半个坐标单位），而 fuzz=8 的死区 ±4 单位大 8 倍。慢拖 A/B：位移为 0 的帧 13.7% → 1.8%。
* **触点面积轴进镜像**：cmdline `disable_pressure=0` + 驱动默认 `pressure_enabled` 跟着轴走（`0047`）。
* **按下延迟 25 → 17 ms**：`debounce_base`/`track_start_debounce` 2 → 1，36 条轨迹 0 碎片、guard_kill=0。
* 固件**确实**做逐像素基线跟踪（空载原始帧 −143…+69，离阈值 11.6 倍）—— #115 第 5 条的担心不成立。
* ⛔ **`peak_threshold` 不能抬**：1500 把快速甩动切碎（移动手指峰值更低），且没挡住手掌。回 800。
* ⬜ 手掌碎块（`max_contacts` 打满 10）：三个阈值假设全被实测否决；用户确认不影响点击，降级为"多余触点"。
  真要解得看跨帧形态，下一版驱动的活。
* ✅ 完整 ROM 已构建并作为 v0.6.2 发布（第二版，戳 `1789570683`，#116 §18–19）。

<details><summary>（历史）2026-09-16 那一晚的准备工作，已全部完成</summary>

★ **明早照着 [`touch-morning-runbook.md`](archive/touch-morning-runbook.md) 走**，每一步都写了「看什么算通过」。
已在 ESP 上就位（**default 没动、原内核原封不动**）：

* `slot_b/Image-test`（内核 **`#23`**，sha `b05bcc6e…`）与条目 `…-android-b-test.conf`，
  复用 slot_b 的 ramdisk/dtb，只多占 15.6 MB。slot_b 原内核 `89a1d14f…`（`#19`）**没动**，留作回落。
* 那个条目的 cmdline 里加了 `himax_hx83121a_spi.disable_pressure=0`，
  好让**同一次重启**把 fuzz 与触点面积一起验掉。

要启动它：`bash scripts/boot-oneshot.sh <MID>-android-b-k21.conf` 然后重启（⚠️ 征得同意）。
起来之后（都不再需要重启）：

```sh
echo 0 > /sys/module/himax_hx83121a_spi/parameters/fuzz    # 对着手指实时 A/B
echo 1 > /sys/bus/spi/devices/spi0.0/algo/pressure_enabled  # ★ 先开这个再看手感
```

⚠️ `pressure_enabled=0` 时驱动报的是**常数**（TOUCH_MAJOR=1、PRESSURE=4095），
每个触点都成了"针尖"，可能比现在更糟 —— 开了 `disable_pressure=0` 就**必须**一起把
`pressure_enabled` 打开。
⚠️ **验完把 `Image-k21` 与那个条目删掉**：ESP 现在只剩 **35 MB**，而 OTA 的 postinstall
要 56 MB（B13）。`install-ota-local.sh` 的预检会拦住，但别等它拦。

原 T1 正文如下。
驱动给 `ABS_MT_POSITION_X/Y` 写死 `fuzz = 8`，注释原文是
"preventing libinput from treating 10px drifts as swipes" —— **桌面 Linux 的理由**。
内核 `input_defuzz_abs_event()` 对 fuzz=8 的处理：`|Δ| < 4` **整个丢掉**、`< 8` 只取 1/4、
`< 16` 只取 1/2。本机 1600×2560、像素间距约 0.1 mm ⇒ **慢速拖动时 0.4 mm 以内的位移消失**。
而 Android 侧 InputReader + `ViewConfiguration` 的 touch slop（本机约 24 px）本来就在做同一件事，
驱动自己还带 IIR 平滑（`hx-algo.c`，默认开）——三层重复过滤。

**第一步**：✅ `patches/0037` 已写好（把 fuzz 做成 0644 模块参数，**默认仍是 8，单独打上不改行为**）。
✅ 内核 **`#21`** 已编出（sha `6b87401d…`，15593984 字节，退出码 0、**零告警**，
`--verify` **32/32 逐字节一致**，DTB `fedd3fb6…` 与设备上 v0.6.1 的两个槽**逐字节相同** = 只动了驱动）。
`#21` = 0037 + 0038 + 0039，产物在本机 scratchpad 的 `k21/vmlinuz.efi`。
已静态确认新旋钮进了二进制：`iso_nbr_ratio_q8` / `edge_min_area` / `track_jump_dist2` / `fuzz`
以及两个 cmdline 参数 `himax_hx83121a_spi.fuzz` / `.disable_pressure`。
**只差一次重启**（要用户在场）。起来之后就能用手指实时 A/B：
`echo 0 > /sys/module/himax_hx83121a_spi/parameters/fuzz`。调定了再把值写进 DT 的
`touchscreen-fuzz-x/y`（标准属性，`drivers/input/touchscreen.c:89` 会覆盖驱动默认值）。

⬜ 第二件（同一次重启里一起验）：**驱动默认不报 `ABS_MT_TOUCH_MAJOR` / `ABS_MT_PRESSURE`**
（`disable_pressure=true`），于是 Android 拿不到触点面积 ⇒ **框架的手掌误触抑制没有输入可用**，
压力恒为 1.0。硬件是有数据的（`hx-algo.c` 的 `area` = 参与该触点的像素数、`signal_sum` = 积分信号）。
用 `himax_hx83121a_spi.disable_pressure=0` 上 cmdline 试；轴注册之后 `algo/pressure_enabled`
是**运行时可写**的，可以现场对比真值与常数。
⚠️ 别盲目打开就发版：`pressure_enabled=0` 时驱动报的是**常数**（TOUCH_MAJOR=1、PRESSURE=4095），
那可能比现在更糟（每个触点都成了"针尖"）。要么一起开，要么都别动。

</details>

⬜ 第三件：本机**没有触摸的 IDC 文件**（`dumpsys input` 里 `ConfigurationFile: <none>`）。
有了面积/压力轴之后才值得写，那时可以调 `touch.size.calibration` / `touch.pressure.calibration`。

### T2. ⬜ Google 未认证（"设备未经 Play 保护机制认证"）
自编 ROM 的 GMS 不在 Google 的认证设备库里。**修法是把本机的 Android ID 登记一次**，免费、一分钟。
* 工具已就位：`bash scripts/google/gsf-android-id.sh`（⚠️ 新版 GMS **不再往
  `com.google.android.gsf` 的 `gservices.db` 写**，网上那条 `sqlite3` 老办法在这里查不到东西；
  真实位置是 GMS 的 `shared_prefs/Checkin.xml`）。
* 用户文档已就位：`docs/INSTALL.md` 的 "This device isn't Play Protect certified" 一节。
* ⬜ **剩下的是用户动作**：去 <https://www.google.com/android/uncertified/> 登记，然后
  `pm clear com.android.vending`。⚠️ 恢复出厂后 ID 会变，要重登记。
* ⚠️ **边界要说清楚**：这只解决"未认证"那条提示。**Play Integrity（银行类应用）仍然过不了** ——
  它要 bootloader 上锁 + Google 签名的系统，而本机 UEFI 解锁正是"能装别的系统"的前提。
  这是取舍，不是缺陷。
* ✅（v0.6.2 起 incremental = `20260916145759`）顺带修掉的一处不一致：v0.6.1 的指纹里 incremental 是 **`eng.androi`**
  （AOSP 在 `BUILD_NUMBER` 未设时回落成 `eng.$(用户名前6字符)`，而 Lineage 把用户名匿名成
  `android-build`），与 `ro.build.version.incremental`（构建戳）**对不上** —— 一个构建里两个
  互相矛盾的 incremental。`release.sh` 已设 `BUILD_NUMBER`，**下次构建生效**。
  ⚠️ 指纹里的 `:userdebug` 与 `ro.build.type=user` 也对不上，那是 crDroid 自己的 spoof 只改了一半；
  **没动它**——改成 user 变体会连带关掉 adb root 和整套开发流程。

### A6b. ⬜ WPA3(SAE) 连上即断 —— [issue #2](https://github.com/vahiru/gaokun-android/issues/2)

> ✅ **2026-09-14 结案（[#107](stage4-findings.md)）**：#100 的"AP 不认密码"被证实 —— 用户在手机上核对出密码记错了。
> 改对后 **WPA3-SAE 一次连上**（group 19 / H2E / PMF），3 分钟带流量浸泡 0 次掉线。本机 SAE 栈端到端可用。
> issue #2（关联后被踢）在这台华为 AP 上不复现；要推进它仍需报告者在那台 ZTE 上跑 `scripts/wifi/wpa3-probe.sh`。

> **★★★ 2026-09-13 更新：用户提供的那台 AP 已经查完，但它【不是】issue #2。**
> 用户给了自家的 AP 让我复现（⚠️ SSID/密码不写进本仓），结果是**密码 AP 不认**：
> SAE 被拒在 Confirm（`status 15` = hostapd 校验失败）、WPA2-PSK 关联后
> `4WAY_HANDSHAKE_TIMEOUT`，**两条独立算法都在校验那一步失败**，
> 且与故意写错的密码**失败签名逐行同形**。换全新 MAC、确认不是同名邻居、
> `sae_pwe` 0/1/2 全试 —— 都排掉了。完整案卷 [#100](stage4-findings.md)。
> ⇒ **issue #2 仍未复现**：我们连认证都没过，报告者是关联之后才被踢。
> ★ 但拿到了一条正面结论：**本机 SAE 栈机制上是活的**
> （群协商 / Commit / RSNXE / H2E 全通，AP 接受 Commit 并处理了我们的 Confirm）。
> ⇒ 下面"还没排除的候选"里，**第 1 条（`sae_pwe`）可以划掉了**。

**报告者 robbin15**（GK-W76 / BIOS 2.16 / **v0.2.0-alpha** / 安装脚本全新安装）：
5 GHz 用 **WPA3-SAE** 或 **WPA2-PSK/WPA3-SAE 混合**时"连接秒断"，**每次都出**；
把路由器 5G 改回 **WPA2-PSK 就正常**。路由器是 ZTE，5G 在**信道 36（5180 MHz，非 DFS）**，
扫描里该网络带 `SAE` + `MFPC` 标志。

★ **判据很干净**：同一个 5 GHz 频段、同一台路由器，只改安全模式就一正一反
⇒ **变量是 SAE，不是频段、不是信道、不是 regulatory**。
⚠️ 而且现象是**关联之后被踢**，不是认证失败连不上 —— 两者要分开查。

**已经排除的三层（2026-09-12，都有证据，别再重查）**：

| 层 | 结论 | 证据 |
|---|---|---|
| wpa_supplicant 编译 | ✅ 没问题 | `android.config` 里 `CONFIG_SAE=y` / `SAE_PK=y` / `OWE=y` / `DPP=y`；构建出的二进制里 `SAE-EXT-KEY` / `FT-SAE` / `sae_pwe` 字符串都在 |
| Android 框架 | ✅ 没问题 | 本机 `dumpsys wifi` 的 SupportedFeatures 含 `WIFI_FEATURE_WPA3_SAE` / `WPA3_SUITE_B` / `OWE` / `DPP` / `SAE_PK`，且有 `KeyMgmt: SAE` |
| ath11k 拒绝 PMF 的组密钥 | ✅ **不是它** | `ath11k_install_key()` 对不支持的 cipher 返回 **`-EOPNOTSUPP`**，而那正是让 mac80211 **回落软件加密**的返回值 ⇒ BIP/IGTK 走软件是正常安排 |

⚠️★ **记一次我自己的误判**：先靠 `grep -A20` 看到一串 `return -EINVAL` 就断定
"ath11k 硬拒 `WLAN_CIPHER_SUITE_AES_CMAC` 导致 PMF 失败"，差点写成结论 ——
**那几行 `-EINVAL` 是 `-A20` 溢出到别的函数里的**。读完整函数才看到真正的
`default:` 分支返回 `-EOPNOTSUPP`。
★ **看一个函数的返回值，要把函数读完，不能靠 grep 的上下文窗口。**

**还没排除的候选**：
1. ~~★ **`sae_pwe` 没设**~~ ❌ **2026-09-13 排除**：`wpa_cli get sae_pwe` 实测
   本机默认就是 **`1`（H2E only）**，与 AP 广告的 `[SAE-H2E]` 一致；
   而且 0/1/2 三种全试过，AP 每次都**接受 Commit**（若 PWE 方法不匹配，
   分歧会在 Commit 阶段暴露）。⇒ 这一条不成立。见 [#100](stage4-findings.md)。
2. ★★ **SAE 之后的 4 次握手 / 密钥安装**。这与"关联后被踢"的形状最吻合。
   `ath11k_install_key()` 等 `install_key_done` 最多 1 秒，超时返回 `-ETIMEDOUT`。
3. WCN6855 固件对 SAE 的行为（我们发的是 linux-firmware ≥ 20241210 那份）。
4. ⚠️ 报告者用的是 **v0.2.0-alpha**（2026-08-21），此后内核与 ROM 都换过多轮 ——
   **有没有可能已经变了，没人验证过。**

**本地测不了** ⚠️ **这条已过时**：2026-09-13 用户提供了 WPA3 transition-mode
的 AP（用户自家那台，2412 与 5180 双频，`[WPA2-PSK+SAE+PSK-SHA256-CCMP][SAE-H2E]`），
**环境有了**；缺的变成了**一个我们知道密码正确的 WPA3 AP**。

✅ **顺带一条（2026-09-12 已办）**：镜像里**没装 `wpa_cli`**（实测 `which wpa_cli`
为空），于是"不刷机改一下 supplicant 参数做 A/B"这条最快的验证路子走不通 ——
`wpa_supplicant.rc` 里明明已经开了控制接口（`-O/data/vendor/wifi/wpa/sockets`），
只差那个客户端。已加进 `device.mk` 的 WiFi 段。
模块名核实过没凭记忆写：`external/wpa_supplicant_8/wpa_supplicant/Android.bp:1272`
的 `cc_binary { name: "wpa_cli", proprietary: true }` ⇒ 落到 `/vendor/bin/wpa_cli`。
⚠️ 该文件核的是 **LineageOS `lineage-23.2` 分支的上游副本**，不是构建机上那棵
checkout —— 构建时若报 "non-existent modules in PRODUCT_PACKAGES" 就去树里再 grep。
⚠️ `/data/vendor/wifi/wpa/sockets` 是 0770 wifi:wifi，**shell 不在 wifi 组** ⇒ 要 root。
✅ 已进镜像（`f068947` 09-12 入库，v0.6.1 起的镜像都带）。
✅ **2026-09-13 已用上**：`m wpa_cli` 单编（170 KB）→ push 到 `/data/local/tmp`
→ `-p /data/vendor/wifi/wpa/sockets -i wlan0` 挂上**运行中的** supplicant，
`status` / `list_networks` / `add_network` / `set_network` / `select_network` 全可用。
★★ 它真正的价值不是看日志，而是**绕开框架的 `config_wifiSaeUpgradeEnabled`**
—— 该 AP 会被 Android 自动 WPA2→WPA3 升级，所以 **`cmd wifi` 根本做不出 WPA2 对照组**，
而这个对照组正是 [#100](stage4-findings.md) 定案的那一击。

**第一步（二选一）**：
* 有 WPA3 热点时，跑 `scripts/wifi/wpa3-probe.sh "<SSID>" "<密码>"` ——
  一次取齐四层证据并抓连接失败点；
* 或者请报告者跑同一个脚本并贴输出（**比让他描述现象有效得多**）。
  ⚠️ 顺带请他在**当前版本**上复测一次 —— v0.2.0-alpha 已经很旧了。

### A1. 音频与蓝牙长期运行后死锁 ⚠️ 次高优先
用户实机报告，我未复现、未定位（[#38](stage4-findings.md)）。
两者共用同一条到 DSP 的 QRTR/FastRPC 通路，而这条通路上**已经实测到过**
会话级卡死（使能光感会污染整个 SSC 会话）。

★ **取证看门狗已随 v0.2.0 起的镜像发布**（`bin/gaokun3-hangdump.sh`）：
现实是死锁时用户只会重启、证据就没了，所以证据必须自动留下。它 60 秒采一次
`/proc` 线程状态（刻意不跑 dumpsys，很便宜），判据是**同一个 tid 连续三次都在 D**
（≥2 分钟），命中后把 stack/wchan/QRTR 服务表/PCM 状态/binder 日志/logcat
写到 `/data/vendor/gaokun3/hangdump-<uptime>/`。

**第一步**：下次死锁后把那个目录整个要过来 —— 不必再追问"多久、什么负载"。
若目录是空的，说明它没判定成死锁（比如卡的不是 D 状态），那本身就是线索。
手工对照仍可用 `gaokun3-qrtr-lookup` 比服务表：少了哪个服务就指向哪个 DSP。
⚠️ 别把 `Handover signaled` 当崩溃证据，那是良性噪声（#37 已用对照实验证明）。

### A2. 硬件视频【编码】（Venus）— ⚠️ **已查明并【故意关闭】，不是待验证项**
解码 ✅ 已随 v0.4.0-alpha 发布（`c2.v4l2.avc.decoder` 实测解出 30 帧，
案卷 [#41](stage4-findings.md)）。

★ **编码这一侧 2026-08-22 已经实测并定性**，结论写在
[device.mk](../device/huawei/gaokun3/device.mk) 那段属性旁边（原文可查）：

```
E EncodeComponent: Unable to parse RGBX_8888 from IMPLEMENTATION_DEFINED
E EncodeComponent: Failed to get input block layout
E ...: Attempted to lock() a buffer that was not allocated with a
       BufferUsage::CPU_* usage.
```

SurfaceFlinger 交出来的是 **RGBX_8888 / IMPLEMENTATION_DEFINED**，
而 Venus 编码器要 **NV12**，`v4l2_codec2` 的 `EncodeComponent` **不做这个转换**
—— 属于组件本身的功能缺失，不是配置能解决的。

⚠️★ **而且开着比关着更糟**：编码组件 rank `0x80` 会压过软编的 `0x200`，
于是应用**直接失败，而不是回退到软编**。所以两条
`ro.vendor.v4l2_codec2.encoder.supported.*` 属性是**有意注释掉**的，
`scripts/verify-venus-codec2.sh:57` 也据此断言"**必须没有**编码组件"。
录屏/录像走软编，能用。

**真要做的话**，工作量在 `external/v4l2_codec2` 的 `EncodeComponent`：
让它认 `IMPLEMENTATION_DEFINED`，向 gralloc 问出真实布局并协商 NV12
（和已经修掉的两条解码 bug 同型：v4l2_codec2 照搬 ChromeOS 行为、venus 守规范）。

⚠️ 记一条方法论：2026-08-23 我又跑了一次 `screenrecord`，失败信息是
`ERROR: UNASSIGNED_LAYER_STACK` —— **那跟编码器毫无关系**，
是当时**屏幕是灭的**（`mWakefulness=Asleep`），SurfaceFlinger 拒绝抓屏。
**灭屏状态下的 screenrecord 结果不能用来判断编解码器。**

### A3. 自动亮度（环境光）— 芯片在总线上不应答，四个软件维度已扫空
详见 [#72](stage4-findings.md)（并已作废 #43/#68/#70 的历次归因）。

**当前定性**：光感驱动**在 SLPI 固件里**（`strings` 见 tcs3701 120 次），
`default_sensors.json` **声明了** `.ambient_light`，SEE 也确实在 probe ——
**但芯片不应答**。阴性对照给出了判据：把能用的加速度计地址改错，
得到的失败签名与光感**一模一样**（都是「SSC 说没有传感器提供 data_type=...」）。

**已扫空的维度**（每格实测，不是推理）：
`bus_instance` **0–7 全扫** ／ `bus_type` 0–3 ／ `rail_on_state` 1 与 2 ／
Linux 没占那条总线（只有 4 条 i2c 适配器、无 0x39/0x46）／
Linux 没占中断脚（TLMM 32 与 127 都 `UNCLAIMED`）。
另：`is_dri = 0` ⇒ 光感**本来就走轮询**，「DRI 中断没到」这条假说**不成立**。

**新掌握的结构**：配置是**二供料**方案 —— IMU（sh3001 ✅／t1000）在 bus 1，
光感（tcs3701／sy3133cs）都在 bus 5。t1000 与 sh3001 同参数而只有后者注册出来，
⇒ SEE 的「探测择优」机制本身是正常的。

★ **一条一直没人注意的事实**：喂给 DSP 的 `hw_platform = QRD` 是**我们自己编的**
（主线不导出它）。所以这整套是**高通参考设计的配置**，板级差异原本在
Windows DriverData 注册表里，**已随抹除 Windows 丢失**。

**剩下的可能性**（按可行性）：
① 芯片没上电／被复位钉住（与触摸屏 gpio174 同一类；那些脚在 SSC 域，AP 看不到）；
② 真实总线/地址只存在于已丢失的注册表里；
③ 抄一台光感在主线上能用的 sc8280xp（ThinkPad X13s）。

★ **可复用工具已入库**：`scripts/ssc/`（60–90 秒一次的实验循环 +
带回读验证的改字段工具 + 必跑的阳性/阴性对照）。**下次动这块先读它的 README。**

⇒ **自动亮度暂时做不了。自动旋转与游戏体感不受影响。**

### A5. 恢复出厂设置不起作用
设置里那条路走 misc 的 BCB + recovery，而本机没有可用 recovery
（[#39](stage4-findings.md)）。实机证据：misc 里躺着一条没人消费的 `boot-recovery`。

**现在的替代**：从救援 Linux `mkfs.ext4 -F /dev/disk/by-partlabel/userdata`。
**真正的修法**：见 B3（EFI 加载器）或让 recovery 能启动（已搁置）。

### A6. USB-C 外接显示（UCSI）★ 现在还欠着待机那笔账
⚠️ 2026-09-14 更新（[#112](stage4-findings.md)）：**UCSI 在当前内核上是活的**（typec port0/port1、partner、
EC 的 ucsi 驱动绑上），但它给的数据角色**是反的**（PC 插着时 `data_role=[host]`），靠 `init.gaokun3.usb.rc`
硬写 `device` 盖回来。下一步：查 EC 的 partner type 语义 → 修 `ucsi_huawei_gaokun.c` → DT
`role-switch-default-mode = "host"` → 删 rc 里的硬写。下面这段是旧状态：
`PPM init failed -ETIMEDOUT`，本机主线已知缺陷，`/sys/class/typec/` 是空的。
代价还包括 USB 只有 high-speed（SuperSpeed 需要 UCSI 切 orientation）。

★ **它现在是三个问题的共同根因**：没有 role 源正是 `a600000.usb` 停在
半初始化 `device` 态的原因（[#52](stage4-findings.md)），而我们为此付的代价
就是**息屏时 USB adb 断开**。UCSI 修好 → role 被正确指派 → 那个取舍自动消失。
⚠️ 顺带说明这条为什么值得排在摄像头前面：**USB adb 掉线是本项目迄今最大的
效率税**（#27），每次都要靠扫网段 + TCP adb 找回来。

### A8. ✅ 设备的 WAN 吞吐"只有 PC 的 1/20" —— 2026-09-14 结案：不成立
同一时刻同一 URL：平板 8.14 MB/s，本机 8.53 MB/s，LAN 直连 37 MB/s（[#108](stage4-findings.md)）。
#44 那次对照多半是本机走了代理隧道。★ 对照组要先确认两边走的是同一条链路。

### A7. 摄像头 —— ★★ 前摄可用，★★★★★ 电源域缺陷已根治（#105）

> **★★★★★ 2026-09-14 更新：[#87](stage4-findings.md) 的电源域缺陷【根因找到并修好】**
> （[#105](stage4-findings.md)）。根因是 `camcc-sc8280xp` 里 `camnoc_axi`/`slow_ahb`/`fast_ahb`
> 三个 RCG 没标 `clk_rcg2_shared_ops`，用完相机后 CAMNOC AXI 的时钟源停在一个熄灭的 PLL 上。
> 修法 `patches/0031`（3 行）。内核 `#13`（含诊断）与 `#14`（发版形态）实测：解钉、自然塌缩、
> 空闲后再用，全部成功。**下面那段"量一次钉住 camss 的功耗"已经不需要了** —— 钉住本身可以撤。
> ✅ ① 默认槽早已换成带 0031 的内核（现为 v0.6.2 的 `#24`）；② rc 里的 `power/control on` 已撤（`a87d79b`）。
> ⬜ 待办：③ 上游投稿 `camcc-sc8280xp: Mark RCGs shared where applicable`
> （照 x1e80100 口径）+ 等待值 `0027`；④ `patches/0022` 在健康状态下补一次 unbind/rebind 验证
> （pstore 证明 #83 的"拖死整机"就是它修的 panic）。

> **★★ 2026-09-12 libcamera 可行性摸底完成（[#88](stage4-findings.md)）——
> 结论比预期好得多，上游已经认识我们这台机器**：
> `simple` 流水线 **显式支持 `qcom-camss`** 且 `swIspEnabled=true`
> （`simple.cpp:266`）；软件 ISP 吃 10 位 CSI2 打包 + GBRG 序
> （`debayer_cpu.cpp:443-465`，我们是 `0x300e` = `SGBRG10_1X10`）；
> **hi846 在传感器数据库里**（`camera_sensor_properties.cpp:135`，
> 它记的测试图案 2=彩条 / 9=分辨率图案**正是 #81 用过的那两个**）；
> 依赖面很小（`udev`/`gnutls` 都可选，只需补 `libyaml`）；
> ✅ 并排掉了一个本可能致命的风险：**libcamera 源码里 `LINK_FREQ` 一次都没出现**
> ⇒ 不要求 hi846 缺的那个控件。
> ⚠️ 真正的未知在 Android 侧：libcamera 产出的是传统 `camera_module_t` HAL3，
> 而框架要 `ICameraProvider`。实机 `strings /system/bin/cameraserver` 显示
> **HIDL @2.4/2.5/2.6（含 passthrough）与 AIDL 两条都在**，上游
> `provider@2.4-legacy`（加载传统模块的那个）也还在 ⇒ **可能一行 HAL 代码都不用写**，
> 但 hwservicemanager 本机装着没跑，passthrough 还灵不灵**未验证**。
>
> **里程碑**（照搬传感器 M11 被验证过的路径：先做独立客户端 = HAL 逻辑的 90%）：
> ✅ **M1 已达成**（2026-09-12，[#89](stage4-findings.md)/[#90](stage4-findings.md)）：
>    交叉编只需一处移植修复；上机后 `SoftwareIsp` 把 `3264x2448-GBRG-10-CSI2P`
>    变成 **ABGR8888 3256×2448**，连收 40 帧，AGC 曝光在爬。
>    ⚠️ 画面全黑（传感器没光，RAW 标准差仅 0.36 = 黑电平基座）——
>    **"能出图"已证明，"出的是对的图"还没视觉确认**，下次开工先给前摄补光。
>    ✅ **增益缺口已补**（[#94](stage4-findings.md)）：实测标定出
>    **`gain(code) = 1 + code/16`**（满量程 16×），留出验证四档误差 <2.3%；
>    黑电平实测 64@10bit 且不随增益放大。补丁
>    `patches/libcamera/0002-ipa-libipa-add-hi846-camera-sensor-helper.patch`
>    已入库（`git diff` 生成、`git apply --check` 验过），**可发上游**。
>    ✅ **已重编并上机验证**（[#95](stage4-findings.md)）：`analogue-gain: 16`
>    （满量程），Warning 消失，**拍出第一张能认出来的真实照片**
>    （`docs/img/gaokun3-first-photo.jpg`）。M1 至此完成。
>    ⬜ 画质偏暗偏灰是**调优**问题（用的是通用 `uncalibrated.yaml`：无 CCM、
>    灰度世界 AWB、缺 colourGains）——需要一份 `hi846.yaml` 调优文件，
>    **但那不挡 HAL**，M2 可以直接开工。
> ⬜ **M2 HAL3→框架的接法**：★ 2026-09-12 已查清（[#91](stage4-findings.md)）——
>    **HIDL 在本机是死的**（`hwservicemanager` 是悬空符号链接、init 报
>    "service not found"，而 `CameraProviderManager` 发现 HIDL provider 只能靠它），
>    所以 `provider@2.4-legacy` 那条"零代码"路**作废**。
>    ⚠️ 另有一条便宜路也死了：libcamera 软件 ISP **只出 RGB 族**
>    （`debayer_cpu.cpp:436-441`，无 YUYV/NV12），喂不了 AOSP 的 ExternalCameraProvider
>    —— **和 #84 撞的是同一堵墙**。
>    ★ **已定方案 A：camera3 → AIDL 桥。**
>    C（复活 HIDL）的前提其实成立（`hwservicemanager` 在 AOSP android16-release 里还在，
>    本机那个悬空符号链接正是它的 `install_symlink` 模块装的），但**战略上是陷阱**：
>    FCM 202504 的兼容性矩阵里 camera.provider **只剩 `format="aidl"`**，
>    HIDL 版在矩阵 7 之后就没了 —— 本仓在 Codec2 上已经吃过同一个亏。
>    A 比 B 便宜得多的硬理由：**AIDL 的 `CameraMetadata` 就是 `camera_metadata_t` 的
>    序列化 blob**（aidl 文件原文："Access by casting to a `camera_metadata*`"），
>    与 camera3 HAL 同一个东西、转换成本为零；而 libcamera 的 `src/android/`
>    已经把能力表/流配置/请求结果/JPEG/**RGB→YUV(libyuv)** 全做完了。
>    ⇒ A 写的是一层**转发**，B 是一层**重写**。
>    ⬜ 下一步：按 `-Dandroid=enabled` 编出 `libcamera-hal.so`，再写 AIDL 三件套薄壳。
> ⬜ **M3 meson → Android.bp**（mesa 那套工具链可复用）。
> ⚠️ 全程压着 [#87](stage4-findings.md) 的电源域缺陷，开发期用"开机即钉住 camss"当桥。

> **★ 2026-09-12 更新（上机实测）**：上游候选修复 `patches/0020`
> （`unregister CAMCC_GDSC_CLK`）**被否** —— 补丁确实生效（`clk_summary` 里
> `camcc_gdsc_clk` 0 次）但故障一字不差复现，见 [#87](stage4-findings.md)。
> camss 电源域缺陷至此排除六条，根因未破。
> ⚠️ 另查出 `camcc-sc8280xp` 的 **unbind 路径是坏的**（probe 注册的 genpd
> 没注销 → rebind 撞名 `-22` → 相机子系统"解绑后绑不回去"，只能重启）
> ⇒ "出错后重绑 camcc 恢复"这条廉价规避不存在。
>
> ★★ **优先级已改**：不再继续猜根因。已有**实测有效的规避**（塌缩前钉住
> camss 的 runtime PM），挡着它进 ROM 的唯一理由是"功耗未测"——
> 那是**可以测量的问题，不是未知**。
> ⬜ **下一个动作：量一次钉住 camss 的功耗代价**（息屏静置，对比 pin / 不 pin
> 的电池电流）。可忽略 ⇒ 规避进 ROM、libcamera HAL 立刻开工；
> 明显 ⇒ 再回来啃根因（那时才值得动 `/dev/mem`，且必须先钉住 camcc）。

**2026-09-11 前摄 hi846 端到端出帧**（[#81](stage4-findings.md)）：传感器彩条从
SGBRG10P 原始拜耳解出 **黄 青 绿 品 红 蓝**，R/G/B 满量程 1023/0，上下行逐像素差 0。
据我们所知是 sc8280xp 上第一次在 Android 侧让 camss 出帧。
已入库：5 个 config（`kernel-config-android.sh` + MUST_Y）、`patches/0018`
（去掉后摄节点，A/B 实测非它不可）、`scripts/camera/`（两个静态诊断工具）。

**⬜ 第一步：相机 HAL。** `cameraserver` 在跑但 0 个相机设备，`/vendor/lib64/hw` 无 camera HAL。

★★ **已验过：camss 的 PIX（ISP）通路【不出 YUV】，ExternalCamera HAL 这条捷径是死的。**
（2026-09-12 实测，见 [#84](stage4-findings.md)。这一条是**阴性结果**，
写下来是为了省掉下一个人半天 —— 拓扑里有 `msm_vfeN_pix` 实体、video 节点又报
`UYVY`/`YUYV` 这些格式，看起来非常像"接上就有 YUV"。）

实测：
* 把 `msm_vfe0_pix` 的**源 pad** 设成 `MEDIA_BUS_FMT_UYVY8_1X16`(0x200f)
  → **驱动改回 0x300e**（拜耳），随后 STREAMON 报 `EPIPE`；
* `VIDIOC_SUBDEV_ENUM_MBUS_CODE` 枚举该源 pad → **只有 `0x300e` 一个码**，
  与 RDI 源 pad 完全相同。

⇒ **硬件/驱动这条路上拿不到 YUV，去拜耳必须在上层做。**
所以相机 HAL 只能走 **libcamera**：它的 `simple` pipeline handler + **软件 ISP**
正是为"简单流水线出裸拜耳"这种情形设计的。mesa 那套 meson→bp 工具链可复用。

hi846 的完整控件表在 [#81](stage4-findings.md) 第六节。

**⬜ 两个必须先修的前提**：
1. ⚠️★★ **camss 电源域缺陷**（[#83](stage4-findings.md) 已把根因缩到一点）：
   **只要 `titan_top_gdsc` 真的塌缩过，再上电就必失败** ——
   `titan_top_gdsc status stuck at 'off'`（`gdsc.c:185` 的 WARN），STREAMON 报 −110。
   连着跑不会失败（GDSC 来不及塌缩，6/6 全过），隔一会儿再跑必炸。
   ⚠️ 原先记的"开机后只有第一次成功"是**错的模型**，已更正。
   已排除：camcc 处于 runtime-suspend（钉成 active 照样 3/3 失败）、
   `RETAIN_FF_ENABLE` 位（两种状态下都是 1）。
   ★★ **已有验证过的规避手段**（[#83](stage4-findings.md) 第五节）：
   **在第一次塌缩之前**把 camss 的 runtime PM 钉住 ——
   `echo on > /sys/devices/platform/soc@0/ac5a000.camss/power/control`。
   同一次开机内的 A/B：钉住时连跑 5 次 + 空闲 60 秒后再跑**全部成功**，
   解钉 8 秒后立刻复现失败。⚠️ **必须在塌缩之前钉**（已塌缩后再钉会当场触发失败）。
   ⚠️ 代价是相机电源域常开，功耗未测 —— **在相机 HAL 落地之前不要写进 ROM**。
   ❌ **第一个候选修复（`patches/0020`，上游 `499b4cb6710f`）已上机实测被否**
   （内核 `#5`，[#87](stage4-findings.md)）：补丁确实生效（`camcc_gdsc_clk` 出现 0 次），
   故障一字不差复现。⇒ 至此排除**六条**：camcc 处于 suspend、时钟被关
   （`clk_summary` 141 行逐行相同）、`RETAIN_FF`、**MMCX 父域档位/息屏**
   （屏强制常亮时 mmcx 全程 `on/416`，照样失败）、息屏、以及 0020。
   ⚠️ `slot_cam2/Image` 与现役 `slot_a/Image` sha256 逐字节相同（同一个 `#5`），
   2026-09-13 已把副本与 `…-cam2.conf` 删掉回收 15 MB（ESP 只有 296 MB）。
   ❌ **第二个候选修复（`patches/0021`）也已上机实测被否**（内核 `#6`，
   [#102](stage4-findings.md)）—— 这是**第七条**。补丁确实生效
   （`ad00000.clock-controller` 作为 interconnect 消费者出现、投票随 GDSC 起落），
   而且**失败之后那条 icc 投票还留在 1/1** ⇒ NoC 全程抬着也没用。
   ★★★★★ **但同一轮的单变量实验把触发条件挪到了【下电】那一侧**：
   同一次开机、同一个域 —— **无流量塌缩 → 上电 ✅ 12 帧；跑过 camtest 再塌缩 → ❌ −110。**
   ⇒ "只要塌缩过就必败"这个模型**也不对**，塌缩本身无害；
   触发条件是**"跑过流量之后再塌缩"**。
   ★ 而 A/B 两格在**上电那一刻的状态完全相同**，差别只在历史里
   —— 这解释了前面七条假说（全在查上电缺什么）**为什么必然全部落空**。
   ⚠️ A/B 分不开两种读法（真有 DMA 流量 vs. 那段 ON 期间开了一整套 camcc 时钟与
   CSIPHY 稳压器），**下一步必须拆开**，阶梯实验见 [#102](stage4-findings.md)。
   ⚠️★ 新禁忌：**camss 已 `runtime_error` 时不要 unbind 它，会拖死整机**
   （2026-09-13 用一次强制关机换来的）。
   ⬜ `patches/0022`（unbind/rebind 的 genpd 注销）**至今未验证** ——
   要在干净开机、camss **健康**时测，不能拿一个已经 wedged 的子系统去试。

   <details><summary>（已否）第二个候选修复当时的依据</summary>

   上游 `bd09d87c55d6`（Luca Weiss，**已在 v7.2-rc2 里**）的提交说明原文 ——
   "On newer SoCs like Milos the **CAMSS_TOP_GDSC** power domains requires the
   enablement of the **multimedia NoC**, otherwise the **GDSC will be stuck on 'off'**"。
   它把 `needs_icc` / `icc_path_index` / `gdsc_toggle_logic()` 里的 `icc_set_bw()`
   都加进了 `gdsc.c`（本机 `gdsc.c:152`/`:188`、`gdsc.h:79-81` 都在），
   **但只给 `camcc-milos` 接了线**。`patches/0021` 给 sc8280xp 接上同样的线
   （驱动 `.needs_icc = true` + DT 的 `&camcc { interconnects = <&mmss_noc
   MASTER_CAMNOC_HF 0 &mmss_noc SLAVE_MNOC_HF_MEM_NOC 0>; }`，**两半必须一起上**）。
   ★★ 它比 0020 有分量的地方是**机制自洽**，能解释六条排除为什么全落空
   （NoC 不是时钟、不是 MMCX、不在 camcc 的寄存器路径上；而 GDSCR 的**写确实生效**，
   只有 PWR_ON 起不来 ⇒ 卡的是握手不是总线），
   还解释了一条以前没人问过的事实：**`ife_0..3` 每次拍照都完整下电上电却从不出错** ——
   它们翻转时 camss 已 resume、icc 投票是活的（`camss.c:5781-5795`），
   而 `titan_top` 的翻转由 PM core 在驱动回调**之外**完成，那一刻
   `camss_runtime_suspend()`（`camss.c:5766-5779`）已经把四条路清零了。
   ⚠️ **仍是待验证假说**，有一条对不上：**开机后第一次上电是成功的**，
   而按本模型那次投票同样应该是 0（可能是 icc `sync_state` 还没放掉引导器的初始带宽，
   **未验证**）。
   内核 `#6` 已编好：`android/slot_cam3/{Image,gaokun3.dtb}`（sha `6facbde1…`/`1273a6a9…`，
   与构建机逐字节交叉校验过）+ `…-cam3.conf`，**故意没设 oneshot**。
   同内核还带 `patches/0022`（上游 `86b23609d5e1`，修 [#87](stage4-findings.md) 那个
   unbind 撞名；只在解绑时生效，**与相机判据零交叉**）。
   **测法**（与 #87 逐字相同才可比）：oneshot 过去 → 跑一次 camtest（应 12 帧）
   → 等 `titan_top_gdsc` 变 `off-0` → **再跑一次**。
   成功 = 假说成立；仍 −110 = 假说被否。
   ⚠️ 新内核第一次上机要有人能按电源键。
   ⚠️★ **实验成本**：一旦触发失败，camss 就锁死 `runtime_error`，**只有重启能恢复**
   ⇒ 用户不在场时"先复现再观察"这条路是关着的，这不是懒。
   </details>
   ⚠️⚠️ **读那些寄存器之前先把 camcc 钉住**（`power/control=on`）并确认
   `runtime_status=active` —— 否则 `devmem` 的【读】就能让内核静默死亡，
   2026-09-12 已经这么弄挂过一次。★ 并且**用户不在场时不做这类探针**。
2. ⚠️★★ **camss 抢走 video0–31，Venus 被挤到 video32/33**，而 `v4l2_codec2` 只扫 0–9
   ⇒ 硬解静默回落软解。`crdroid-tree-fixes.py` 第 7 条已修（上界 10→64），
   **必须随相机一起进 ROM**。相机内核因此**没有提升为常驻**，设备仍跑 `#3`。

**后摄** ★★★★ **2026-09-14 通了，而且不是 S5K3L6 —— 是 OV13B10**（[#106](stage4-findings.md)）。
板级电源序列来自华为 Windows 驱动包的 `CAMS_RES_QRD.bin`；L2B 与面板 VDDI 共用、RPMh 取最大（Windows 同款行为）；
轨亮着时扫总线 0x36/0x50 应答。`patches/0032`（DT）+ `0034`（ov13b10 OF 匹配 + 板级上电）+ `VIDEO_DW9714=y`
之后：47 个 subdev、`camtest --rear` 出 2104×1560 帧、HAL 枚举 2 个相机。内核 `#19`（+0035 回落 +0036 闪光）在 `slot_cam5`，两路验收全过（[#110](stage4-findings.md)）。
⬜ 应用层实测；⬜ libcamera：`camera_sensor_properties` 加 ov13b10、增益模型 helper、`ov13b10.yaml`；
⬜ 上游 `ov13b10.c` 补 `get_selection`；⬜ 读 EEPROM@0x50（模组标定）；
⬜ **`rotation` FIXME —— 2026-09-19：这条已成"照片方向"的最后一环。**
HAL 侧的 JPEG 旋转与朝向换算都已修好（见 [camera-photo-rotation-2026-09-19.md](camera-photo-rotation-2026-09-19.md)），
照片方向现在**完全由设备树这两个 `rotation` 值决定**，而它们恰恰是猜的。
标定用 `setprop debug.gaokun3.camera.orientation.{front,rear}`（该文档第六节）；~~实机已量出前摄 270 / 后摄 0~~。
⚠️ 2026-09-24 合并 PR #6 时对账：几处记录互相矛盾（这里 270/0、文档第 7 章 0/0、PR 描述 90/270）。~~取 PR 描述里最后那组（前 90 / 后 270）写成 `patches/0049`~~ —— **错了**：
✅ **后摄 180 经用户目视确认**（2026-09-24 早上；核对过当时设备树就是 180、没有属性覆盖，[#119 §7](stage4-findings.md)）。`0049` 已改写为只去掉 FIXME，dtb 与 0048 版逐字节同。
⬜ **前摄**：设备树 0，未目视（PR 文档 7.2 的照片证据支持 0）。
✅ 稳健性：`patches/0035` —— 某颗传感器 20 s 没绑上就只带绑上的完成 notifier；`ov13b10.fail_probe=1` 实测前摄照常（45 个 subdev，[#110](stage4-findings.md)）。
✅ 2026-09-14 收尾：用户手电筒照镜头看到景物/亮度变化 ⇒ **`#18` + 后摄 dtb 已设为默认槽**；prebuilt-boot 已是 `#19` + dtb v2。
`slot_cam` / `slot_cam4`（#14 时代）已从 ESP 删除（它们把 ESP 吃到只剩 4.5 MB，会让 postinstall 失败，#110）。
✅ **闪光灯**（[#110](stage4-findings.md)）：Windows 的 `\_SB.FLSH` 资源块为空 ⇒ PMIC 闪光模块（`pmc8280c` = PM8350C，
主线 `leds-qcom-flash`）；GPIO93 实测不亮。内核 `#19` 四路逐个 torch、用户看背面 ⇒ LED 在 **1 + 4 路**，
`patches/0036` 收成单节点 `led-sources = <1>, <4>`（torch 200 mA / flash 600 mA / 400 ms，保守假设）。
dtb v2 上机：`/sys/class/leds/white:flash` 一个、47 个 subdev。故意不在 ov13b10 节点写 `flash-leds`（v4l2-async 会多等一个 subdev）。
✅ 相机 HAL 接 `/sys/class/leds/white:flash`（[#111](stage4-findings.md)）：手电筒（`setTorchMode`）+ 拍照闪光
（预闪触发点灯 → 报 PRECAPTURE 几帧 → 静态照片完成才灭；AUTO 用交付帧采样亮度判"太暗"）。
features xml 补 `android.hardware.camera` + `android.hardware.camera.flash`（SystemUI 手电筒砖的前提）。
✅ 装机验收（v0.6.1 戳 1789362233）：快捷设置手电筒砖点开 `brightness=255`、再点归 0（#111 §6）。
⬜ Aperture 后摄闪光 ON 拍一张，看 LED 亮/灭各一次（要解锁，等用户在）。
⬜ **噪点 / 闪光过曝 / 偏绿**（用户 2026-09-14 反馈，[#112](stage4-findings.md) §3-4）：HAL 已加增益自适应降噪、
预闪按亮度收敛、回填曝光/增益；已编译、手动起 provider，**待用户拍样片对比**（地砖平坦区标准差 ≈ 10 → ?）。
⬜ 手电筒亮度档位：HAL 声明 `FLASH_INFO_STRENGTH_MAXIMUM_LEVEL`/`DEFAULT_LEVEL` 并实现 `turnOnTorchWithStrengthLevel`
（brightness 0..255 线性映射即可），SystemUI 的 `flashlight_strength` 已开、砖会给滑杆。
✅ 相机 ID 稳定化（后摄 = 0）：`release-061d`（戳 1789364282）装机实测 `internal/0` = BACK。
⬜ `kDarkLuma=50` 是启发式；真要准得让 softisp IPA 把曝光/增益写进结果元数据（上游没写，可提 patch）。
⬜ ESP 上还剩 `slot_cam5`（#19）与 `cam5`/`cam6`/`cam7` 三个测试条目，v0.6.1 装机验收通过后删。

---

## A′. 已关闭（只留索引，细节在案卷里）

* **s2idle 待机** ✅ v0.3.0-alpha。真凶是我们自己加的 `dr_mode="otg"`。
  [#52](stage4-findings.md)–[#57](stage4-findings.md)
* **耳机口 + 内置麦克风** ✅ 用户确认出声。[#40](stage4-findings.md)
* **普通应用能 panic 内核** ✅ v0.4.0-alpha，`patches/0013` 删掉 `drm_crtc`
  里那行竞态 `BUG_ON`。[#58](stage4-findings.md) / [#62](stage4-findings.md)
* **硬件视频解码** ✅ v0.4.0-alpha。[#41](stage4-findings.md)
* **亮度调节** ✅ 真 lights HAL 取代了只接受数值不干活的 stub。
* **扬声器音量偏小** ✅ **已随 ROM 生效**：#86 装机验收 `audio-route.sh` 与仓库逐字节相同、`tinymix` 实测 `SpkrLeft PA Volume = 21`。下面是返工过程，留作记录。 原修法（WSA 数字上限 81→90，
  +5.7 dB）**抬错了那一级** —— 数字级在 DAC 之前，+6 dB 把 −6 dBFS 的内容顶到
  0 dBFS，实测 THD **−20 dB（约 10% 失真）**。现改为数字压在单位增益 84、
  响度由 PA 出（上限 17→23，运行时 17→试 21）。
  ✅ **内核这一半已上机验实**（2026-09-11，[#80](stage4-findings.md) 第七节）：
  `tinymix` 查到 `SpkrLeft PA Volume` 范围变成 **`0->23`**、
  `WSA_RX0 Digital Volume` 变成 **`0->84`**，写 24/90 都被钳住。
  ⬜ **但用户还听不到** —— 设备上的 ROM 是 08-24 那版，`/vendor/bin/audio-route.sh`
  仍是旧脚本，开机照老结论设 `Digital Volume 90`（**被新内核拒了**，
  这反倒是新上限生效的证据）和 `PA=12`。
  ⚠️★ **内核与 ROM 在本项目是分开发布的，所以"补丁已入库"≠"用户听得到"。**
  **第一步：构建一版带新 `audio-route.sh` 的 ROM**（本仓那份早就改好了，
  两步写法让同一份 ROM 在新旧内核上都对）。
  在那之前运行值已手工设成 PA 21 / dig 84，**重启会被旧脚本改回 12**。
  [#78](stage4-findings.md) / [#79](stage4-findings.md)
* **插着键盘时屏幕键盘不弹** ✅ `show_ime_with_hard_keyboard` 默认置 1。
  ⚠️ 键盘开关**不是**这条的解药（Android 看键盘设备存不存在，不看 inhibited）。

---

## B. 工程债与正确性

### B12. ⬜ 释放 R2 桶的前提：国内可达的下载镜像
2026-09-14 v0.6.0 把清单 `download` 指到 GitHub Release 附件，用户当天反馈更新失败：附件 302 到
`release-assets.githubusercontent.com`，国内不可达；`raw.githubusercontent.com` 同样。已全部换回 R2。
出路：同一 Cloudflare 域名（`ota.072172.xyz`）下建 Worker 反代 GitHub Release 附件与仓库里的清单，
桶只留存储为零的转发层；或干脆保留桶（成本很低：出站免费）。**要用户定**，且改完要在国内网络实测下载。

### B14. ⬜ 息屏 USB adb：脚本折中已做，原生化两步 + 复位根因（[#112](stage4-findings.md)）
`bin/gaokun3-usbrole.sh` v2：插着主机（UDC configured）息屏不切 host、不放行挂起，拔线再切。应已随 v0.6.2 进镜像（提交 `a7ce25f` 早于构建戳，未在设备上核对）；
装后把本机 `persist.vendor.gaokun3.allow_suspend` 设回 1（现在是 0，根本不睡；
⚠️ 属性 2026-09-18 已改名且**默认值改成 0**，见 [#117](stage4-findings.md)）。
源码定性：device 模式系统挂起无条件 `dwc3_core_exit()`（PHY 下电）且 gadget 总 soft disconnect ⇒
上游 dwc3 没有"adb 穿越睡眠"。⬜ 复位根因（combo PHY exit → TZ 复位？）开放。⬜ UCSI 角色修好后可去掉脚本的 host 切换。

### B13. ✅ `install-ota-local.sh` 装前先算 ESP 空间（2026-09-14 已加，并已用它拦过一次）
[#110](stage4-findings.md)：postinstall 要求"可用 + 将被覆盖的旧文件 > 56 MB"，本机被三周的实验槽位吃到
4.5 MB 可用（47 MB 合计）⇒ v0.6.1 装到自己机器上会在 postinstall 失败，而那会被误读成"新版本有问题"。
脚本里加一步 `df` + 列出 `<ESP>/<mid>/android/` 下非 `slot_a`/`slot_b` 的目录并提示删除。

### B0. ⚠️★★★ 让构建机的设备树【就是本仓的 checkout】—— 这个坑已经咬了五次

**现状**：`~/crdroid/device/huawei/gaokun3` 是一个**普通目录**，不是 git
checkout，与本仓之间靠人手拷来拷去。于是它必然漂，而且是**双向**漂。

**第 6 咬（2026-09-16，#116 §15）**：`rsync --delete` 把构建机上 `.gitignore` 挡着的四样构建输入
（adb_keys / firmware/** / hexagonrpcd-root/** / prebuilt-boot/**）全删了。构建 42 秒 panic 在 `adb_keys`；
但 `hexagonrpcd-root/sensors/config/*.json` 与 `socinfo/*` 走 **wildcard**，缺了会**静默**产出没传感器的镜像。
更糟的是事后 127 文件 md5 核对**通过了** —— 两边一样地缺。★ **参照物必须是"构建需要什么"，不是"本机有什么"。**
从设备 `/vendor` 与上次 `out/` 恢复，52 个文件与设备逐字节相同。→ `scripts/sync-device-tree.sh`（带断言）。

**已经付过的四次账**（全是同一个形状）：
1. M17：上游 Venus 补丁集只活在构建机 ⇒ 从干净树重建不出发版内核
2. [#79](stage4-findings.md)/[#80](stage4-findings.md)：`ashmem` + `xt_quota2`
   只活在构建机 ⇒ **上机黑屏，用户按了电源键**
3. `patches/camera-wip/`：相机驱动只活在构建机
4. [#82](stage4-findings.md)：**08-24 一整轮工作**（温控 HAL / 触摸模式 /
   HEVC CSD / 导航栏 / Vulkan 1.3）只活在构建机 ——
   而且**差点被我自己覆盖掉**，靠 M5 那条"先比清单"才拦住
5. [#110](stage4-findings.md)：#109 的修法（libcamera `Android.bp` 加 `relative_install_path`）
   改在本仓 `patches/libcamera/`，**构建机的 `external/libcamera/Android.bp` 没跟着变**，
   早上那版 v0.6.1 候选会把"相机打不开"原样再发一次。⇒ B0 的范围不止设备树：
   **本仓 `patches/` 里凡是给构建机某棵树用的文件**（libcamera 的 bp、mesa、内核）都算。
   ⚠️ 同一天还差点用 macOS `tar` 把 33 个 `._*` 文件同步进构建树（bsdtar 的 AppleDouble），
   同步一律 `rsync --exclude '._*' --exclude '.DS_Store'`。

⇒ 缓解措施已有（`kernel-apply-patches.sh`、`crdroid-tree-fixes.py` 12 条、
`/proc/config.gz` 对账、全树 `git status` 普查），但**它们都是事后补救**。
★ 2026-09-14 补了一个**精确的探测器**：`kernel-apply-patches.sh <tree> --verify` ——
从 HEAD 起临时 worktree 把整条链重放，再把每个被补丁碰过的文件与真实树逐字节比
（[#110](stage4-findings.md) 末尾）。第一次跑就抓到 `0011` 与 `upstream-venus/0020` 是
同一个 `&venus` 块、重放出两份（0011 已从表里拿掉）。**每次编内核前先跑它**，
绿了再 `make`。设备树那一半仍靠 `rsync --exclude '._*'` + 逐文件 md5 清单（#110）。
**第一步**：把构建机上那个目录换成本仓的 git checkout（或 symlink 到一个
checkout），让 `git status` 直接说话。⚠️ 换之前先做一次清单比对 —— 那里面有
`.gitignore` 掉的固件/传感器配置/预编译内核，不能被覆盖。

⚠️ 另记一处**未编码的分歧**：构建机的 `prebuilts/build-tools` 里
`date` / `tar`（×3 平台，共 6 个文件）**被删掉了**，全仓零记录、理由不明。
决定只记录不编码（理由见 [#82](stage4-findings.md) 第五节）。
下次干净树构建若出现 `tar`/`date` 相关报错，就是它。

### B1. SELinux 转 enforcing —— 四步 + 第五轮补漏，剩两个结构性阻塞与一个待定
[#75](stage4-findings.md) / [#76](stage4-findings.md) / [#77](stage4-findings.md)。
2026-08-23 夜随构建戳 `1787436126` 装机验收：

* ✅ 第 1 步 定义域 —— **`init` 域里只剩 PID 1**（此前 5 个服务挤在里面）
* ✅ 第 2 步 设备节点类型（c2 服务、6 个 nvme 分区、`/dev/fastrpc-*`、`/dev/mem`）
* ✅ 第 3 步 sysfs genfs 标签 —— ★ **`network_stack` 236→0、
  `hal_health_default` 235→0，零 allow 规则**
* ✅ 第 4 步 按真实主体写 allow（hexagonrpcd / 传感器 HAL 的 QRTR /
  boot_control 的挂载 / 键盘），`sepolicy_neverallows` 通过
* ✅ 功能零回归：传感器、声卡、WiFi、root 8/8

**还剩两个加规则解决不了的**（这才是 enforcing 的真正门槛）：

1. **`gaokun3_hangdump`** —— 读 debugfs 那条 neverallow
   （lineage-23.0 的 `domain.te:1462`，名单只有 init/vendor_init/dumpstate）
   **没有 userdebug 豁免**；而它还要读所有域的 `/proc`。
   它本质上是 `dumpstate` 那一类工具。
   **出路**：binder-debugfs 换成 `dumpsys`，或做成只在 userdebug 启用的诊断件。
2. **`gaokun3_smmustall`** —— 要 `sys_rawio` + `/dev/mem`。写得进去
   （那条 neverallow 有 userdebug 豁免），但会让 enforcing 与否取决于构建变体。
   ⚠️★ 2026-09-18 我一度"更正"成"我们发 user 变体所以写不进去"，**那是错的**：
   `ro.build.type=user` 只是 build.prop 被硬写的样子，本仓一直编 userdebug
   （[#117](stage4-findings.md) 第 15 条，当晚用一次失败的装机换来的）。
   ★ **正解是先做 B6**，脚本整个消失，这道坎一起没了。

⬜ 另有一处**语义不对、但当前无后果**：genfscon 是前缀匹配，给 UCSI 的
`power_supply` 打标签时连带盖住了它下面的 `wakeup21`/`wakeup23`（本该是 `sysfs_wakeup`）。
`wakeupN` 编号动态，逐条 genfscon 不现实。
**2026-09-18 实测（[#117](stage4-findings.md) 第 10 条）**：本机绝大多数 wakeup 节点
（thermal-sensor、mhi0）**谁也没标**，而 `system_suspend` 整次启动 + 14 分钟使用
**一条 denial 都没有** ⇒ 它在本机根本不读这些节点。
⇒ 修它的收益是语义正确，不是修 bug；而"放行 system_suspend 读 sysfs_batteryinfo"
那条路被 `domain.te:1555-1572` 的 neverallow 堵死。**别当成有功能在等着修。**

**2026-09-18 第五轮（[#117](stage4-findings.md)）—— 不看 denial、只对源码查出来的四个洞**，
规则已写进 `device/huawei/gaokun3/sepolicy/`：

* ✅ `gaokun3_touchmode` 域 —— v0.6.2 加的触摸手感服务**一直跑在 init 域里**
  （没 seclabel、没标签）。★ 第 1 步不是一次性工序，是**每加一个 init 服务**的清单项。
* ✅ `/dev/dri` **目录本身** → `gpu_device` —— 当初判断"换类型解决不了"是错的，
  核心策略里 `gpu_device:dir r_dir_perms` 对那批主体全都现成，**零 allow**。
* ⚠️★ `gaokun3_esp_block_device` —— ESP（p1）此前挂通用 `block_device`，而
  `domain.te:705` 那条 neverallow 让**任何域都打不开它**：boot_control HAL 挂 ESP
  在 enforcing 下不是"缺一条 allow"，是**写了 allow 就构建失败**。
  permissive 下它一直好好的，所以活了近一个月。
* ✅ `postinstall.te` —— OTA 钩子的权限（挂 ESP、读 boot_x、写 BLS 条目）。
  ⚠️ 代价：`find_esp()` 的兜底探测（扫全盘找 vfat）撞同一条 neverallow，
  **enforcing 后只有按 `install-gaokun3.sh` 布局装的机器能走完 OTA**，手工分区的会失败。

✅ **属性改名已落地**（用户 2026-09-18 定的）：`persist.gaokun3.allow_suspend` /
`.recovery_entry` → **`persist.vendor.gaokun3.*`**，新类型 `vendor_gaokun3_prop`
（`vendor_public_prop`，见 `sepolicy/property_contexts` + `sepolicy/vendor_gaokun3_props.te`；
⚠️ 上下文名**必须** `vendor_` 开头，构建器硬检查，见 [#117](stage4-findings.md) 第 9 条），
`shell` 可写、`postinstall` 可读。
⚠️★ **`allow_suspend` 的默认值同时从 1 改成 0** —— 改名会让已装机器上现有的值失效，
默认改成 0 才能让本机（一直是 0）行为不变。**代价：新装机的用户默认也不进 s2idle，
与 v0.3.0–v0.6.2 的镜像默认相反 —— 发版说明必须写。**
⚠️ `persist.sys.gaokun3.*`（键盘、触摸模式）**故意没跟着改**：它们靠 `system_prop`
才让 Parts 应用（`system_app` 域）写得了，改成 vendor 前缀反而写不了。

**2026-09-18 晚补：设备回来了，又查出三条（都写了规则）**

* ✅ **温控 HAL 读不到温区**（35 条）—— `sysfs_thermal` 是 AOSP 公共类型，
  但核心策略**没给它写任何 genfscon**，本机温区因此是通用 `sysfs`。
  已标 `/class/thermal` 与 `/devices/virtual/thermal` 两处（照 AOSP 对 wakeup 的写法），
  ⚠️ 这次**标对了还不够**：核心策略里有 `sysfs_thermal` 规则的只有 system_server
  与 recovery，HAL 自己那条要我们写。
* ⚠️★ **`audio-route.sh` 执行 `/system/bin/tinymix` 撞 Treble 的 neverallow**
  （`domain.te:1238-1275` 的 `}:file *;` —— vendor 域对 system_file_type 的**任何**
  权限都禁，只豁免 shell_exec/toolbox_exec 等）。而 AOSP **没有 tinymix 的 vendor 变体**
  （`external/tinyalsa/Android.bp:66-71`，只有 `libtinyalsa` 是 `vendor_available`）。
  只能挂 `vendor_executes_system_violators` 属性（AOSP 正是为这种情况准备的）。
  ⬜ 干净解：给 tinyalsa 投一个 tinymix 的 vendor 变体，那三行就能删。
* ✅ drm_hwcomposer 的 uevent 监听（`netlink_kobject_uevent_socket read`，10 条）。

⬜ 上面 `wakeupN` 那条的最自然修法（放行 `system_suspend` 读 `sysfs_batteryinfo`）
**已排除**：`domain.te:1555-1572` 的 neverallow 不豁免 coredomain 里的 system_suspend。

✅ **2026-09-23 更正**：下面这段写于编译之前。之后 `m selinux_policy` 通过（#117 §11–§13）、
`-userdebug` 重编装机成功并逐条实机验证（§18），又查出 4 处新的、已写未验（§19–§20）。
原文：~~这一轮一行都没编译、一条都没上机~~。下一步有两件、互相独立：
1. 构建机上 `m selinux_policy` —— 只验"规则写不写得进去"（neverallow / 类型可见性）；
2. 装机后重跑一次 denial 普查 —— 才能验"够不够用"。#117 第 3 条说明这**是两个问题**。

### B2. ✅ 真温控 HAL —— 已随 v0.6.0 进镜像（2026-09-12 装机验收）
`device/huawei/gaokun3/thermal/`（自研，读 `/sys/class/thermal`），`device.mk:97` 装它，
装机验收实测"skin 44 °C 不关机"。
⚠️★ 拆掉的那颗地雷值得留着：AOSP mock 报的 skin/battery **SHUTDOWN 阈值只有 36 °C**，
而 `ThermalManagerService.shutdownIfNeeded()` 到 SHUTDOWN 会直接 `powerManager.shutdown()`；
mock 值恒定才没打到。**只换 HAL 不改阈值 = 开机几分钟自动关机。**
⚠️ 本条 2026-09-14 之前一直写着"现在是 AOSP mock"——**发版说明写了不等于 TODO 更新了**，
这是本仓第二次栽在同一处（M16 那次是 README 首屏）。收尾清单里要有一条"grep 旧结论的关键词"。

### B3. 自研 EFI 加载器（规范化的最后一段）
读 `misc` 的 `bootloader_control` 选槽 + 解析 Android boot 镜像 +
装 initrd/DTB 协议。做完之后：
* postinstall 钩子与 ESP 上的派生文件**全部可以退役**
* BCB 能被消费 → `adb reboot recovery` 与恢复出厂设置才有可能工作
* 是 AVB/verified boot 的前提

**安全阀已实测可用**（[#73](stage4-findings.md)，2026-08-23）：systemd-boot 的
`efi` 指令在这台机器上确实能 LoadImage + StartImage 另一个 EFI 应用，
三轮实验全部自动回到 Android，**没有人碰过机器**。所以"固件不支持 chainload"
这个顾虑不成立，开发这个部件不需要有人守在机器旁。
⚠️ 但 `efi` 条目**拿不到 initrd**（`boot.c:2428` 直接按类型返回），
`devicetree` 倒是照装 —— 拿它引内核必须自带 `panic=10`。

⚠️ **真正的物理约束是 ESP 只剩 28 MB**（296M 用了 268M）。
里面有 70 MB 的 `Persisted_Capsules.bin` 和 31 MB 的 `EFI/`
（含已抹除的 Windows 整棵树）。要往 ESP 加东西，先腾地方。

### B4. LiveCD 图形安装器 —— ⏸ **用户决定暂时搁置**（2026-08-23）
接手说明见 [stage7-installer-roadmap.md](stage7-installer-roadmap.md) 末尾。

**已验过**：后端 probe/plan/apply/shrink 全部端到端测过（apply 在 loop 设备上、
shrink 在真 NTFS+ext 上验了文件 md5 与 PARTUUID）；20 屏离线渲染；
DRM 输出 + 触摸 + 键盘 + 软键盘在真机上跑通。

**还欠**：WiFi 页重做成两步式、apply 接网络安装、专业分区页的值回灌 plan、
**端到端真装一次**（从来没有真的装过一台机器）。

★ 回来时记住：**设备自己能编译**（Alpine aarch64 + 网），
改一行到真机看见效果约 30 秒，不用重建镜像。

### B5b. ⬜ UBWC 压缩：设备上已经开了 13 天，但仓库里还写着关（[#85](stage4-findings.md)）
`device/huawei/gaokun3/device.mk:174` 仍然设 `vendor.minigbm.debug=nocompression`
—— 那是 **Stage 2 为 SwiftShader 软渲染加的**（`stage2-findings.md` 第 15 条），
Stage 5 换成硬件 turnip 之后就没有存在理由了。
2026-08-30 我在设备 overlay 上把它注释掉做 A/B，**然后没记结论也没改 device.mk**，
于是仓库与实机分叉了 13 天（09-12 装 ROM 前清点 overlay 才发现）。

**已知**：UBWC 开着跑 13 天，SMMU fault / `a6xx_recover` / GMU error **全 0**，
用户日常 + 原神无异常 ⇒ **它不坏**，`patches/0004` v3 按真实 modifier 重算布局
那步确实覆盖了这条路。
**未知**：**一次测量都没有** —— "关掉能省显存带宽"至今是推论不是数据。

⬜ 做法：下一版构建前删掉 `device.mk:174` 那一行，**并带一次实测**
（帧率 / 合成耗时 / 显存带宽三选一即可），别凭"理应更好"直接改。
★ 这是 #14 同一形状的坑：**"用了正确的做法"不等于"达成了目标"，差一次测量。**
⚠️ 2026-09-12 装的那版 ROM 把它 **revert 回 `nocompression` 了**，这是故意的：
装机当口不引入未测量的变更，而 `nocompression` 是历版发布的 known-good。

### B6. GPU SMMU 中断根治
实际 DT 是全局 672/673、context bank 从 678 起；而硬件拉的是 675/680，
其中 680 被分给 CB2、675 整张表里根本没有。很像 CB 起始偏移就错了。
⚠️ 但只凭"675/680 挂起"推不出正确映射，而且**改错了没有任何征兆**
（只是继续收不到 fault）。做成之后可以丢掉常驻的 `smmu-nostall.sh` 轮询。

### B7. 用轻量系统替掉救援 Ubuntu（★ 与 B4 是同一件事）
**★ M0 完成（2026-08-23）**：Alpine 救援系统已在硬件上跑起来 ——
ssh 可达、WiFi 自动连上、全套分区工具就位、`lsblk` 看得见内置盘 8 个分区。
案卷 [stage7-live-installer.md](stage7-live-installer.md)。

产物：squashfs **55 MiB** + initramfs **2.7 MiB**（含 WCN6855 固件）。
它要替掉的是 **24.6 GiB** 的 Ubuntu 分区。

⬜ **还没删 p3**，因为现在 squashfs 就放在 p3 上（验证期故意不动分区表）。
下一步：按设计建 1 GiB 的 `gk3rescue` 分区、把 squashfs 挪过去、
确认能启动之后再回收那 24.6 GiB。

### B8. ✅（查明、不修）`invalid volume index range in the curve` ×12 —— AOSP legacy 音量配方的启动顺序噪声
每次 audioserver 启动都吐 12 条 `E APM_AudioPolicyManager: invalid volume index
range in the curve:`（后面是空的，连哪条曲线都没说）。
**确认与耳机改动无关**：干净 A/B，旧策略 12 条、新策略 12 条。
来源应在 `audio_policy_volumes.xml` / `default_volume_tables.xml`（两份都是从
`frameworks/av/services/audiopolicy/config/` 原样拷的）与本机 `devicePorts`
的交集上。目前没有可观测的功能损害，故只记不修。

**2026-09-14 查明（读源码，未改）**：打印点是 `AudioPolicyManager::checkAndSetVolume()`
（`managerdefault/AudioPolicyManager.cpp:8835-8843`），条件是该 volume curves 的
`getVolumeIndexMin()/Max() < 0`，每组只报一次（`invalidCurvesReported` 集合）。
而 legacy 配方（我们用的 `audio_policy_volumes.xml` + `default_volume_tables.xml`）里
**没有索引范围**——范围是 AudioService 开机后逐个 `initStreamVolume()` 灌进来的
（`:3731`）；可是 APM 自己在 `initialize()` → `onNewAudioModulesAvailableInt()` 打开输出时
就先 `applyStreamVolumes(..., force)`（`:7155`）走到了这里，那一刻 12 组范围全是 -1。
⇒ **AOSP 通用的启动顺序噪声**，任何用 legacy 音量 XML 的设备都有，与我们的 devicePorts 无关；
之后 AudioService 灌了范围就一切正常。根治 = 换成 engine 配置 XML
（`audio_policy_engine_configuration.xml` 系列，`<volumeGroup>` 自带 `indexMin/indexMax`），
是一次不小的音频策略搬家，只为消 12 行日志不值。**结案：只记不修。**

---

### B9. SLPI 每 200 ms 一条 handover 噪声 —— 2026-09-14 定位到 sensors HAL 的采样节拍
详见 [#59](stage4-findings.md)。**它无害但有代价** —— 正是它把 [#58](stage4-findings.md)
那两次 panic 的调用栈从 pstore 里挤掉了（45 条记录里有用的不到 10 条）。
`patches/0014` 已把打印改成 ratelimited（治症状，正确且值得上游），
但**远端为什么每 200 ms 翻一次 smp2p 位仍然不知道**。

硬证据：SLPI 的 `q6v5 ready` 与 `q6v5 handover` 两条中断计数**完全相同、
同步增长**（5 秒 5475→5502），ADSP/CDSP 各只有 2。

**2026-09-14 第一步做了（用户在场）**，结果干净：

| 状态 | `q6v5 handover`（SLPI，5 秒计数） |
|---|---|
| 基线（sensors HAL + hexagonrpcd 都在跑） | **25**（= 5 Hz） |
| 只停 `vendor.sensors-gaokun3` | **0** |
| 再停 `vendor.hexagonrpcd-sdsp` | 0 |
| 两个都拉起、等 20 秒 | **25** |

⇒ 5 Hz **就是 sensors HAL 的采样/请求节拍**，不是 DSP 自己的心跳：HAL 一停，
`ready`/`handover` 两个 smp2p 位就不再翻。所以它不是"SLPI 在反复 handover"，
而是 **SLPI 固件把这两个 smp2p 位当成了别的信号在用**（每批传感器数据翻一次），
主线 `qcom_q6v5` 把每次翻转都当 handover 处理并打印。
⬜ 下一步在 HAL 里：把 accel 采样率从现在的值改成 2× / ½×，看计数是否跟着变 ——
若跟着变就是"每批样本翻一次"，`patches/0014` 的 ratelimit 就是正解，
再往上游提"SLPI 的 handover 位复用"这条观察。

### B11. root（ReSukiSU）—— ✅ **已随 ROM 常驻**
2026-08-23 夜装机验收（构建戳 `1787436126`，slot_a）：
`scripts/verify-root.sh` **8/8**，`/data/adb/ksud` 就位，管理器已装。
★ postinstall 写进 slot_a 的内核与手工验过的那个 **sha256 逐字节相同**。

⬜ 还剩两个**产品决定**（都不是技术问题）：
* 要不要预装管理器 APK。★ ROM 侧其实什么都不用加 —— `ksud` 就在 APK 的
  `lib/arm64-v8a/libksud.so` 里，装 App 即到位。
* 要不要在 cmdline 给 `kernelsu.allow_shell=1`（adb shell 直接拿 `su`）。
  **建议不给**：那等于任何能连 adb 的人无确认拿 root。

⚠️ 发版说明里应当写明：**root 会影响 Play Integrity 和部分带反作弊的手游**。

### D5. PR #3 待回复（已审完，等你定措辞）
线上那个 PR 动的正是内核预编译这一块。我把要问的整理好了，**没有发到 GitHub**
—— 对外发言等你。三个问题：`dr_mode=host` 是不是有意为之（那正是我们 #52 的
取舍另一半）；他们刷完之后 USB adb 还通不通；能不能公开那份内核 `.config`
（我们这边的断言是 52 条 MUST_Y + `VIDEO_QCOM_IRIS` MUST_N，可以对一遍）。

### D6. 把 `drm_crtc` 那个 `BUG_ON` 报到 dri-devel（对外动作，等你定）
`patches/0013` 修的是**上游 mainline master 现存**的缺陷：普通应用查一次
present fence 的名字就能把整机 panic 掉。稿子照那个补丁的 commit message
改一改就能发。我不代发对外邮件。

### D8. ✅ v0.6.1-alpha 已发布（2026-09-14）—— 下一版（v0.6.2）待装的东西
> ✅ 2026-09-23：v0.6.2 已于 09-16 发布。降噪/预闪收敛与 usbrole v2 **应已在里面**（提交早于构建戳，未在设备上核对）；
> 闪光 EV 负补偿与 AWB 剔饱和仍未写（见总表 T3）。
降噪 + 预闪收敛 + 曝光/增益回填（#112 §4-5，bind mount 实测有效）、usbrole v2（插着主机不睡）、
闪光 EV 负补偿与 AWB 剔饱和（未写）。发前照旧：构建 → 装机验收（含 HAL 真实出流）→ `--no-build` 发。

### D7. v0.2.0-alpha 的 R2 产物要不要删（2.1 GiB，等你定）
`install/v0.2.0-alpha/` + `builds/…20260820….zip`。**它们正被 v0.2.0-alpha 的
GitHub 发布页链接着**，删了那个页面的下载链接会 404。桶现在 6.6 GiB，
免费额度 10 GB，不删也还撑得住。

---

## E. 明确搁置（记录理由，不是忘了）

* **recovery** —— 启动即复位循环（[#39](stage4-findings.md)）。
  现阶段意义不大：sideload 被系统内 OTA 覆盖，而调试它需要人反复到机器旁
  （本机没有串口、recovery 没有网络栈、pstore 对这类失败无效）。
  真要做，**第一步是把 USB adb 在 recovery 里弄通**，那是唯一能看见内部的通道。
* **fastboot** —— bootloader 级**不可能**（固件是 UEFI，不是 fastboot 设备）。
  用户态的 `fastbootd` 住在 recovery 的 ramdisk 里，所以随 recovery 一起搁置。
* **GMS / Play 商店** —— 用户未提出需求。
* **突破原神 1080×1728 的渲染上限** —— 那是游戏按**设备白名单**给的档位，
  不是本机的技术限制。要突破只能伪装机型，**有账号风险**，留给用户决定。

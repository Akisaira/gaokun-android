# 项目：MateBook E Go (sc8280xp / gaokun) 移植 Android

## 目标

在华为 MateBook E Go（Snapdragon 8cx Gen 3 / sc8280xp，代号 gaokun）上跑原生 AOSP，
最终目标是能稳定运行 arm64 手游。

**当前阶段：Stage 6 收尾 —— 产品化。v0.6.2-alpha 已发布（2026-09-16，构建戳 `1789570683`）：触摸手感按实测定案（跳点判据、fuzz=0、按下 17 ms、触点面积轴）、驱动 6 个缺陷 + 可观测性、OTA postinstall 同步 cmdline。手上还剩画质（降噪/闪光过曝）、息屏 USB adb、Google 认证、手掌碎块 —— 都在 `docs/TODO.md` 的总表里。
2026-09-24 凌晨（用户睡觉、授权自主推进）：**PR #6 相机（AF / 朝向 / 崩溃）已接手修完并合并推送**（`9c79b78`）。
2026-09-24 早上：**后摄朝向 180 经用户目视确认**（0049 前身写的 270 是错的，已改写，#119 §7）⇒ 测试版 `1790184271` 作废；
重新构建的 **v0.6.3 候选版 `1790206017` 已装到 `_b` 并远程验收**（#122；待机默认改回 1＝S1，开发机持久 0 实测不睡）。
新查出：NTP 在国内从没成功过（B22，已写未编）、SLPI 自愈后传感器全丢（B21）、指纹驱动不了（#120）、光感激活会让 SLPI 崩溃（#121）。
路由器（OpenWrt，`192.168.10.1`）加了静态租约：`00:03:7f:12:*:*` → `.239`（本机 MAC 只有后两字节每次开机变），设备侧的静态 IP 仍保留。
新工具 `gaokun3-ncam-smoke`（应用视角的相机冒烟测试，设备上 `/data/local/tmp/`）。案卷 #119。
2026-09-18：SELinux 第五轮（案卷 #117）—— 补了 7 处规则（触摸服务的域 / `/dev/dri` 目录 / ESP 块设备类型 / OTA postinstall / 温控 HAL 的 sysfs_thermal / audioroute 的 tinymix / hwc 的 uevent socket），自研属性改名 `persist.vendor.gaokun3.*` 且 **allow_suspend 默认值改成 0**（⚠️ 不只新装机：v0.6.2 老用户多半没设过这个属性，OTA 后也会落到 0、失去待机 —— 发版前要用户定，见 `docs/TODO.md` S1）。构建机编译验证通过；`-userdebug` 重编后**装机成功**（戳 `1789737346`，槽 `_a`，60 秒起来）：温控 HAL 的 35 条 denial 归零且 `dumpsys thermalservice` 报真温度、audioroute 的 7 条归零、`/dev/dri` 与 ESP 的标签实机确认、功能零回归。⚠️ 中途误用 `-user` 变体导致一次装机失败（#117 §15）。⬜ 新查出的 4 处规则（hwc 的 create/bind、同进程 HAL 库、mediaswcodec、wakeup genfscon）**已写未验**，下次构建一起。（每次开工时更新这一行）**

> ## ★★★ 开工前先读（这一段是"现在"，历史在 `docs/project-log.md`）
>
> ### 设备与连线
> **两条连线路径**（2026-09-14 实测都通；现在在不在线见下面 ⚠️）：USB adb（`adb devices -l` 显示 `usb:...`）与
> TCP adb（`persist.adb.tcp.port=5555`，2026-09-14 实测 `192.168.10.239:5555`）。
> ⚠️ **IP 会漂**，本机自己的网段也会漂（一天内换过三次）。找设备前先 `ifconfig` 看自己在哪个网段，
> 再扫**全网段**的 5555 —— ★ 别按"上几次都落在哪"收窄，2026-09-12 就是这么把一台**好好跑着的**机器
> 误判成"内核挂死"并让用户去按电源键的。判据用 `getprop ro.crdroid.device`，
> 局域网里那台小米手机（`pudding`）也开着 5555。
> ★ 现在直接跑 **`bash scripts/find-device.sh`**（绕沙箱）：2026-09-23 起它在 macOS 上能用，扫本机所在的每个 /24 全段、按协议认身份。
> ★ **2026-09-23 起 IP 固定为 `192.168.10.239`**（家里那个 SSID 改成了静态 IP，#118 §1；
>   2026-09-24 路由器侧也做了保留，`00:03:7f:12:*:*` → `.239`，#119 §8 —— 池子 `.100–.249` 本来包含 `.239`）。
>   IP 以前会漂是因为 wlan0 的 MAC 每次开机都变。换了网络（别的 SSID）仍走 DHCP，那时再用 find-device。
>
> ### 四条会让你损失一小时以上的运维坑
> 1. **`| tail` 之后取 `$?` 拿到的是 `tail` 的退出码。** 在 `az`（打印"已下发停机"而机器没停）、
>    `make`（报 `KBUILD_RC=0` 而构建失败）、`gh release upload`（报"uploaded"而什么都没传）上
>    各栽过一次。判据要看**产物**（时间戳 / 大小 / 服务端列表），不看管道尾巴。
>    ★ 大文件传输同理：2026-09-16 `scp` 1.35 GB 的 payload **退出码 0、文件只有 77%**（连接中途断了）。
>    传完必看字节数 + sha256；续传用 `rsync --partial --append-verify`，别重来。
>    ⚠️ 2026-09-24：**本机（macOS）的 `/usr/bin/rsync` 是 openrsync（"2.6.9 compatible"），没有 `--append-verify`**，
>    只打印用法就退出 —— 包在"失败就重试"的循环里会变成死循环。本机上续传用
>    `ssh 构建机 "tail -c +$((已有字节+1)) 文件" >> 文件` 按偏移追加，最后比 sha256；循环要设重试上限。
> 2. **沙箱代理会掐断到构建机的 ssh，并 MITM 掉 `az` 的证书。**
>    长任务与大流量的 ssh 一律绕沙箱；`az` 加 `AZURE_CLI_DISABLE_CONNECTION_VERIFICATION=1`。
>    主机名 `cicd` 会被解析成 fake-IP `198.18.0.92`，**用真实 IP 直连**。
>    ⚠️★ 两者的要求是**相反**的（2026-09-14 实测）：**ssh 要绕沙箱，`az` 要留在沙箱内**。
>    绕沙箱跑 `az` 会直接 `Certificate verification failed` —— 而那次是 `vm deallocate`，
>    失败了机器就一直在计费。★ 停机之后**必须回头查一次真实电源状态**，别信命令输出。
> 3. **一行命令里永远不要 `pkill -f <名字>` / `pgrep -f <名字>`** —— 命令行自己就含那个名字，
>    于是把自己的 shell 杀了，后面什么都没跑。2026-09-14 一天栽了三次。
>    用 `pkill -x`、`kill $(pidof ...)`，或让长跑脚本自己写 pid 文件。
> 4. **内核树上的补丁只活在【工作区】里（从未提交）** —— 所以 `git checkout -- <路径>` /
>    `git restore` / `git stash` 在那棵树上是**破坏性**的，且毫无警告。
>    2026-09-16 我用它撤一个补丁，一次清空了 `0037`–`0045` 九个。
>    撤补丁用 `git apply -R`；撤不掉说明正文变了，那时重放整条链
>    （`scripts/kernel-apply-patches.sh <树>`，幂等）—— 那正是这个脚本存在的理由。
>
> ### 四条操作禁忌（每一条都是用一次事故换的）
> 1. ⚠️★★★ **camss 已经 `runtime_error` 时不要 unbind 它** —— 会拖死整机，只能长按电源键。
>    ★ 更值钱的半条：我当时是"顺便"测 `patches/0022` 才这么干的，而 0022 修的是 unbind 路径，
>    **本来就该在健康状态下测**。**一个实验该在什么状态下做，是实验设计的一部分。**
> 2. ⚠️★★★ **对可能被门控的寄存器块，`/dev/mem` 的【读】和写一样危险。**
>    2026-09-12 读 camcc（当时 runtime-suspend）触发总线 external abort、内核静默死亡，
>    机器停到用户醒来。非读不可时先钉住控制器并确认 `runtime_status=active`；
>    ★ **并且要看"此刻有没有人能按电源键"——没人能按时，这类探针一概不做。**
> 3. ⚠️ **重启 / 装内核前要征得用户同意**：失败要有人按电源键，oneshot 兜底≠不用动手。
> 4. ⚠️ **装机脚本用的挂载点不要叫 `/mnt/esp`** —— 2026-09-14 我在另一个 shell 里"顺手看一眼"
>    就把它 umount 了，于是安全网那一步静默失败。共享的可变状态要么私有、要么加锁。
>
> ### 发布与构建
> * 构建机用完 **`az vm deallocate`**（按分钟计费）。构建机的树**不等于**本仓 checkout ——
>   这个坑咬过五次，编内核前先 `bash scripts/kernel-apply-patches.sh <树> --verify`（绿了再 make），
>   同步设备树**只用 `bash scripts/sync-device-tree.sh <IP>`**，别手写 rsync：2026-09-16 一条
>   `rsync --delete` 把构建机上四样**不入库但构建必需**的输入（adb_keys / firmware / hexagonrpcd-root /
>   prebuilt-boot）全删了，而事后的 md5 核对还通过了 —— 两边一样地缺。脚本会断言它们在。
> * 发版一律 **`release.sh --no-build`** —— build stamp 每次构建都变，重跑构建发出去的
>   **不是**你在硬件上验过的那一版。
> * **不推仓库、不发版**是需要用户点头的两件事；其余（本地提交、构建、staging、设备实验）直接做。
>
> ### 现在设备上跑的是什么
> ⚠️★ **槽 `_b` = v0.6.3 候选版，未发布**（戳 `1790206017`，incremental `20260923232657`，2026-09-24 装，
> `lineage_gaokun3-bp4a-userdebug`）。40 秒起来、已标记成功，远程验收过了大半（#122 §2），剩前摄目视与 USB 拔插要人。
> 发版 = 用户点头后 `release.sh --no-build`（构建机 `out/` 里就是这一版；payload 另存在 `~/ota-0924/`）。
> ⚠️★★ 槽 `_a` **已不可启动**（`bootctl is-slot-bootable 0` = 0，快照已合并、mapper 里只有 `*_b`，#122 §1）——
> **现在没有回落槽**，和 #118 §2 同样的处境、方向反过来。重启 / 装内核前把这一点算进风险：万一 `_b` 起不来，只能靠救援系统。
> `default` 由 boot_control 在成功启动后自动指向当前槽（现在是 `*-android-b.conf`，实测）。
> ★ `slot_b/gaokun3.dtb` 来自镜像本身（`8b390878…` = 0048 版；0049 只改注释），**不再是手放的**。
> `slot_a` 目录里那份手放的 0048 dtb 与 `.pre0048` 备份还在，但 `_a` 已起不来，只剩历史意义。
> 此前 bind-mount 的相机 HAL 随重启消失，现在跑的是镜像里的那份（同一份代码）。
> ⚠️ 开发机上手动设着 `settings global ntp_server=ntp.aliyun.com`（B22 的临时解；镜像里的修复已写未编）。
> ⚠️ 本机待机仍然关着：属性已改名为 **`persist.vendor.gaokun3.allow_suspend`**（现值 0，
> 2026-09-24 起**显式持久化**；候选版起镜像默认 1 —— 开发机靠持久值保持 0，装上候选版后实测仍不睡，#122 §2）。旧名 `persist.gaokun3.allow_suspend` 在设备上还留着一个孤儿值，无害。
> ⚠️★★ **不要用 `-user` 变体构建本机的 ROM** —— user 构建的 init 强制 enforcing
> （忽略 `androidboot.selinux=permissive`，`selinux.cpp:112-116`），而我们的策略还不完整，
> 结果是**装上去起不来**。本机一直用 `lineage_gaokun3-bp4a-userdebug`。案卷 #117 §15。
> **v0.6.2-alpha 已全部发布**（2026-09-16）：R2 清单已更新（设备侧抓取 200）、
> GitHub release 5 个附件服务端字节数逐一核对并标 Latest、仓库已推送。说明见 `docs/relnotes/v0.6.2-alpha.md`。

---

## 文档地图（找东西从这里开始）

| 想知道什么 | 去哪 |
|---|---|
| **现在什么状态、有什么禁忌** | 本文件上面那个框 |
| **还剩什么没做、优先级** | `docs/TODO.md` —— 顶上有一张「现在在做 / 待办」总表 |
| **触摸调参的实机记录与工具** | `docs/stage4-findings.md` #114–#116 + `scripts/touch/README.md`（手册 `docs/archive/touch-morning-runbook.md` 已完成使命，留作 2026-09-16 那一晚的操作记录）|
| **某个结论是怎么来的**（最权威） | `docs/stage4-findings.md`，按 `#NN` 编号的案卷；Stage 5/6/7 另有专档 |
| 那一周发生了什么 | `docs/project-log.md`（本文件的历史，原样搬过去的） |
| 怎么装、用户会踩什么 | `docs/INSTALL.md` |
| 硬件原始数据 | `docs/hw-inventory.md`、`docs/hw/`（转储） |
| 发版说明 | `docs/relnotes/` |
| 要投上游的补丁 | `docs/upstream/`（未发，等用户点头） |

⚠️ **冲突时的优先级**：实机实测 > `stage4-findings.md` 的案卷 > 本文件 > `project-log.md`。
本仓的历史里有**大量被后来实测推翻的结论**，推翻过程是故意留着的 —— 但别把它们当现状。

## ⚠️ 给 AI 助手的强制规则

**这个平台没有任何 Android 移植的前人成果。** 训练数据里不存在这台机器上的
Android 相关知识。因此：

1. **任何具体的 kernel config 名、AOSP property 名、HAL 接口名、文件路径，
   必须从本地 checkout 的源码树里 grep 出来，并给出文件路径和行号。**
   不允许凭记忆给出。记忆里的名字在这个平台上大概率是错的或过时的。

2. **不确定就明说"我不确定，需要验证"**，不要给出听起来笃定的猜测。
   在这个项目里，一个自信的错误答案比"我不知道"贵得多——用户要花几小时
   才能发现你编的那个 config 项根本不存在。

3. **实机行为以 dmesg / logcat / 用户的实际观察为准，与你的判断冲突时以实机为准。**

4. 涉及 sc8280xp 硬件细节时，优先查 `refs/linux-gaokun` 和 `refs/jhovold-linux`；
   涉及 AOSP-on-mainline 的组织方式时，优先查 `refs/aospm-*`。

---

## 硬件事实

| 项目 | 值 |
|---|---|
| SoC | Qualcomm Snapdragon 8cx Gen 3 / **SC8280XP** |
| 设备代号 | gaokun3（8cx Gen 3 机型）；gaokun2 是另一套 EC 协议 |
| 型号 | **HUAWEI GK-W7X，SKU C233，2022 款，CSOT 面板，触摸固件 `41 07`** |
| BIOS | **2.16**（2023-01-31）⚠️ **不要升级到 2.17** —— 上游触摸驱动是按 2.16 开发的（reset=99 / IRQ=175 / 12 MHz）。⚠️ 2026-09-24 查出：此前的理由"两版触摸 SPI 总线和 GPIO 编号完全不同"比的那份 `DSDT_217` 表头是 `QCOMM SDM8180` —— **是 8cx Gen 2 的表，不是本机的下一版**（#120 §4）。"别升"作为谨慎做法保留，理由待重写 |
| GPU | **Adreno 690** —— mesa freedreno + turnip，主线支持成熟 |
| 屏幕 | **Himax HX83121A / ppc357db11 WQXGA**，MIPI-DSI。**与三星 Galaxy Tab S7 FE 同款面板** |
| WiFi/BT | WCN6855 —— ath11k + hci_qca，主线驱动 |
| EC | 华为自研，主线驱动 6.15 进；UCSI 6.16；**DSI 面板 7.1 进** |
| 存储 | NVMe（**不是 UFS**，不是手机那套分区布局） |
| 引导 | **UEFI，不是 fastboot**。可关 Secure Boot。GRUB/systemd-boot 加载 |
| 虚拟化 | KVM/EL2 可用 |
| 部分可做 | 指纹（FocalTech FTE7001，中断 GPIO181 / 复位 GPIO185）：比对在 TrustZone 的签名 TA `fingerprint` 里，**路线已明确**——本机 QSEECOM 通路已在跑（uefisecapp probe 成功），缺的 LOAD 有 samcday 真机验证过的参考实现，见 #120/#123。TPM 不支持；深度休眠 (S4) 未测 |
| 待机 (s2idle) | ✅ **已修复**（M16，v0.3.0-alpha）。⚠️ 本表此前写着"挂得下去、醒不回来、内核/EC 缺陷"，**两句都错**：M15 证明复位发生在**挂起进入**而非唤醒，M16 查出真凶是我们 Stage 2 自己加的 `dr_mode="otg"`，与内核和 EC 都无关 |

## 关键约束（每次都要记住）

- **没有高通 Android BSP。** 8cx 系列从来只发 Windows/Linux 驱动。
  不存在可扒的 vendor blob，所有 HAL 必须基于主线内核自建。
  → 路线只能是 **AOSP on mainline**，参考 aospm 项目。

- **不是 fastboot 设备。** 所有假设 `fastboot flash` / `by-name` 软链接 /
  A/B 槽位的 AOSP 常规流程都要改写。
  ⚠️ **fstab 用 PARTUUID，不能用 PARTLABEL** —— 实测内置盘上 Windows 建的分区
  PARTLABEL 全都是 `Basic data partition`，不唯一。见 `docs/hw-inventory.md` 第 8 节。

- **没有暴露的串口。** 早期启动失败 = 纯黑屏零信息，adb 要等 init 起来才有。
  → ✅ **已解决，走 `efi_pstore`（EFI 变量），不是 ramoops。**
  **ramoops 在这台机器上不可能工作** —— 固件每次复位都重新初始化 DRAM，
  低位 `0xae900000` 和高位 `0x865d38000` 都实测过，内容一律不存活。
  崩溃日志现在会自动落到 `/var/lib/systemd/pstore/`。
  详见 `docs/hw-inventory.md` 第 7bis 节，工具 `scripts/pstore-ctl.sh`。

- **无 modem。** aospm 的 libqril/qrild/qrtr 那一套全部跳过。

- **arm64 原生。** 手游 arm64-v8a 包直接跑，不需要任何转译层。

## 环境

- **编译机：Azure VM `CICD`**（资源组 `AIROUTER_GROUP`，Standard_D32as_v5，
  32 vCPU / 125 GB RAM / 504 GB 盘，静态公网 IP）。**按分钟计费，用完
  `az vm deallocate`**（盘保留，下次 `az vm start` 约 1 分钟起来）。
  crDroid 源码树在 `~/crdroid`，内核树在 `~/gk3-kernel`。
  ⚠️ **沙箱代理会掐断到它的 ssh** —— 长任务与大流量一律绕沙箱。
  ⚠️ 直连回家只有约 1.3 MB/s，大文件走 **R2 中转**（41 MB/s，出站免费）。
  ⚠️ NSG 的 22 端口目前对 `*` 开放 —— M6 说过要锁到自己出口 IP，**没落地**。
- **目标机：只有一台**（`gaokun3`）。⚠️ 本节此前写着"目标机 A 保留 Windows
  作参照 / 目标机 B 随便刷"，**那个设定 2026-08-20 就不成立了**：Windows
  已抹除、整机归 Android（M6）。**没有对照机** —— "正常应该是什么样"只能
  靠救援 Linux、案卷和实测，不能靠比对另一台。
- ⚠️ 本机自己**编不了 AOSP**（要 16 GB+ 内存、250–400 GB 盘）。

---

## 本地参考树（clone 到 `refs/` 下，供 AI 直接读源码）

> ⚠️★ **`refs/` 不在版本库里，新 checkout 上它并不存在** —— 而上面第 1、4 条
> 强制规则要求"从本地源码树 grep 出来、给出文件路径和行号"。
> 开工前先跑 **`bash scripts/clone-refs.sh`**，否则那两条规则无法执行，
> 只能退回"凭记忆给名字"，而那正是规则要禁的事。

```
refs/linux-gaokun/           github.com/right-0903/linux-gaokun          本机内核核心
refs/matebook-e-go-linux/    github.com/whitelewi1-ctrl/matebook-e-go-linux   GK-W7X patch + GRUB 配置
refs/boot-works/             github.com/matalama80td3l/matebook-e-go-boot-works  面板驱动
refs/jhovold-linux/          github.com/jhovold/linux (wip/sc8280xp-6.16)  ⚠️ 已停更，仅作历史对照
refs/gaokun-buildbot/        github.com/KawaiiHachimi/linux-gaokun-buildbot  ⭐ 现役内核基线
refs/egotouchrev-linux/      github.com/chiyuki0325/EGoTouchRev-Linux    触摸 SPI 驱动
refs/aospm-device-sdm845/    github.com/aospm/android_device_generic_sdm845    ⭐ 设备树模板
refs/aospm-manifests/        github.com/aospm/android_local_manifests
refs/aospm-system-core/      github.com/aospm/platform_system_core       看 diff 知道要改什么
refs/aospm-tinyhal/          github.com/aospm/tinyhal                    音频 HAL
refs/lineage-sepolicy/       LineageOS/android_system_sepolicy (lineage-23.0)  ⭐ SELinux 唯一权威
```

> ⚠️ **jhovold 树已不是基线。** 它停在 6.16（2025-09 最后推送），
> 缺 HX83121A 面板驱动（7.1 才进主线）。现役基线是
> **mainline v7.2-rc2 + `refs/gaokun-buildbot/patches/` 20 个补丁**。

固件来源：`matebook-e-go/uup-drivers-sc8280xp`（Windows 驱动扒 blob）+
linux-firmware ≥ **20241210**

**Stage 2 打 vendor 分区要抓的固件（实测 dmesg 加载路径）：**

```
qcom/a660_sqe.fw          qcom/a660_gmu.bin              GPU (Adreno 690)
qca/wcnhpbtfw21.tlv       qca/wcnhpnv21g.bin             蓝牙 WCN6855
qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn              ADSP
qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn              CDSP
qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn              SLPI
```

华为专有路径下那三个 `.mbn` 不在 linux-firmware 里，必须自己带。

---

## 阶段计划与验收

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **0** ✅ | 主线 Linux 跑通 + 配好崩溃日志 + 采集素材 | 全部通过（pstore 走 efi_pstore） |
| **1** ✅ | 内核转 Android 配置 | 全部通过（UDC 出现，主机端 `configured` 枚举）|
| **2** ✅ | 引导链 + AOSP 启动 | **全部通过**（2026-08-17）：adb shell 通，keystore2/zygote/adbd 稳定运行。12 个问题的完整记录见 `docs/stage2-findings.md` |
| **3** ✅ | 图形栈（minigbm + drm_hwcomposer + swangle） | **全部通过**（2026-08-17）：桌面完整渲染。freedreno 留待 Phase B |
| **4** ✅ | 输入 / 音频 / WiFi / 电源 | **全部通过**：触摸（gpio174）、WiFi 免干预自动连、扬声器+耳机+双麦、蓝牙、待机。案卷 `docs/stage4-findings.md` |
| **5** ✅ | GPU：freedreno + turnip 硬件 Vulkan | **全部通过**（2026-08-19）：SMMU fault 0，22 分钟浸泡零错误。案卷 `docs/stage5-freedreno.md` |
| **6** | 转 crDroid 16.0 + 产品化 | 主体完成：OTA / root / SELinux 四步 / 传感器 / 硬解。案卷 `docs/stage6-crdroid.md` |
| **7** | LiveCD 图形安装器 + 轻量救援系统 | M0 完成，⏸ 用户暂缓。`docs/stage7-live-installer.md` |

> ⚠️★ **本表编号一度与实际里程碑脱节**：原表写"5 = 游戏适配"，而实际
> Stage 5 做的是 GPU、Stage 6/7 表里压根没有。**游戏适配已经达成**
> （原神极高画质流畅，见 README 状态表），它不是一个独立阶段，
> 而是 Stage 5 GPU 打通后的结果。

**Stage 0 必须采集并记录在 `docs/hw-inventory.md` 的东西：**
- `.config` 中所有 QCOM / ath11k / hid 相关项
- `dmesg | grep -i firmware` 的完整固件加载路径
- **ALSA UCM2 配置文件**（Stage 4 要翻译成 mixer_paths.xml）
- `modetest` 完整输出：connector 名、plane 数量、**支持的 format 和 modifier**
  （Stage 3 配 minigbm 的关键依据）
- 触摸屏 / 键盘 / 触控板的 evdev 名和 evtest 输出
- 触摸屏走 SPI 还是 I2C

---

## 已知坑

- 触摸屏 I2C 模式有间歇性失灵，SPI 模式更稳
- **触摸 IC 的工作模式由 gpio174 在固件重载瞬间的电平决定**（低=SPI 高=I2C HID），
  上游两棵 DTS 都没配这个脚，全靠 UEFI 遗留电平碰运气；显示复位还会静默触发
  固件重载。症状是"触摸随机死亡/幽灵触点风暴/驱动探测成功但全聋"。
  修复=pinctrl 恒拉低，见 `patches/0002-*.patch` + `docs/stage4-findings.md` #26。
  空闲 IRQ 速率是状态指纹：≈显示扫描率=正常；0=IC 停摆；乱=模式错乱。
- **`timeout N getevent > 文件` 会因块缓冲丢光全部输出**——采集 evdev 要用
  `cat /dev/input/eventX` 录二进制再离线解码。见 `docs/stage4-findings.md` #26 方法论。
- ~~EC 挂起/恢复：Android 的 suspend 模型比 Linux 激进，预期这里会先炸~~
  ⚠️★ **这条预言错了，M4 实测推翻**：把 EC 驱动整个解绑，挂起照样失败 ⇒
  与 EC 无关；真凶是我们自己加的 `dr_mode="otg"`（M16）。留着它是因为
  它从 Stage 3 起误导了好几轮排查 —— **写进"已知坑"的预测，要和实测结论
  一样接受复查。**
- ~~DSI panel 的 KMS plane 数量少时 drm_hwcomposer 会 fallback 到 GPU 合成~~
  ✅ **担心不成立。** 实测 **25 个 plane / 6 个 CRTC**，硬件合成资源充裕。
  modifier 只有 `LINEAR` 和 `QCOM_COMPRESSED`(UBWC, `0x500000000000001`)，
  支持 UBWC 的 format 见 `docs/hw-inventory.md` 第 3 节 —— 那就是 minigbm 的配置依据。

- **UCSI 有缺陷**（`refs/linux-gaokun/README.MD:86-87`），常见
  `error -ETIMEDOUT: PPM init failed`，此时 `/sys/class/typec/` 为空。
  ✅ 但**不影响 adb**：`dr_mode = "otg"` 无 role 源时落到 device 侧，
  USB 数据通路不经 UCSI。代价是只有 high-speed，SuperSpeed 需要 UCSI 切 orientation。

- **DT label 编号与物理地址不对应**：`usb_0` 是 `a6f8800`，`usb_1` 才是 `a8f8800`。
  改 dwc3 前务必 `readlink -f /sys/block/sda` 确认启动介质在哪个控制器上。

- **`super.img` 是 Android sparse 格式，不能 `dd`** —— 必须 `simg2img` 展开。
  头部魔数 `0xED26FF3A` 是 sparse 标志，**不是** LP metadata。误 dd 会让 init
  读不到元数据、挂载失败后主动复位，且不留任何日志。见 `docs/stage2-findings.md` 第 1 节。

- **`CONFIG_SECURITY_SELINUX=y` 不等于 SELinux 已启用** —— 还必须出现在
  `CONFIG_LSM` 字符串里。buildbot 默认值只有 apparmor，导致 selinuxfs 从不注册、
  Android init 静默死亡。**只看 config 会误判，必须查 `/sys/kernel/security/lsm`。**

- **Android init 失败时是主动 `reboot()`，不是 panic** —— 所以 pstore 抓不到。
  抓日志要靠改造 ramdisk 写内置盘 ESP，方法见 `docs/stage2-findings.md` 第 5 节。
  `androidboot.init_fatal_panic=true` 可以把 LOG(FATAL) 类失败转成真 panic 走 pstore，
  但服务级失败（`reboot_on_failure`）仍是正常 shutdown，两条通路都要布。
- **cgroup v1 在 6.12+ 拆到 `*_V1` 选项后面且默认关** —— `CONFIG_CPUSETS=y` 只给 v2。
  Android 的 cgroups.json 要求 cpuset 走 v1，缺 `CONFIG_CPUSETS_V1` 时
  `SetupCgroups` 失败 → 所有服务起不来 → `bootstrap-apexd-failed` 复位。
  一并要 `MEMCG_V1` / `UCLAMP_TASK(_GROUP)`（task_profiles.json 引用）。
  见 `docs/stage2-findings.md` 第 8 节。
- 游戏多走 GLES，freedreno GL 路径和 zink-over-turnip 都试，先通再选

## 捷径备忘

- **面板与 Galaxy Tab S7 FE（gts7fe / SM-T733）同款** → DPI、时序、背光曲线
  可直接参考 Tab S7 FE 的 AOSP 设备树
- Stage 3 卡死时的止损方案：Cuttlefish（`cvd start --gpu_mode=gfxstream`），
  KVM 可用，是真 Android VM 不是容器

## 协作

- gaokun 社区（Linux 侧）：面板、EC、休眠、触摸的问题问他们
- aospm 社区（Android-on-mainline 侧）：HAL、设备树组织方式问他们
- ~~这两个圈子此前没有交集，本项目是第一个连接点~~
  **已有平行项目**：LineageOS 系 mainline-generic 正在做 gaokun3 live-ISO
  （同款 buildbot 内核），双方结论交叉验证一致。他们的 config fragment
  和模块清单是我们 Stage 3/4 的路线图，见 `docs/parallel-mainline-generic.md`。

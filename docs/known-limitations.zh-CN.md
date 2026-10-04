<!--
  维护说明（不显示）：
  * 这份清单写的是"装上这个 ROM 之前应当知道的事"：长期存在的限制、不支持的功能、安全与许可上的取舍。
    某一版特有的缺陷写在那一版发版说明的 Known issues 里，不写在这里。
  * 每条后面的注释里写着它在 docs/v1.0-plan.md 里的条目 id。发版前逐条核对；修好了就删掉那一条，
    取舍变了（例如 SELinux 切 enforcing、预装了中文输入法）就改写那一条。
  * 中英两份（known-limitations.md）内容必须一致，改一份就改另一份。
  * 依据（文件:行号 / 实机）写在注释里，不写在正文里。
-->
# 已知限制与不支持的功能

[**English → known-limitations.md**](known-limitations.md) · [常见问题](FAQ.zh-CN.md) · [安装](INSTALL.md)

这个 ROM 是在一台**没有任何厂商 Android 支持**的机器上从零搭起来的。下面这些是装之前应当知道的事：
有些是我们有意做的取舍，有些是还没做出来，有些在这台机器上做不到。

每一条都按同一个格式写：**现象**（你会看到什么）、**原因**（一句话）、**替代办法**（现在能怎么办）。

某一版特有的问题见那一版的[发版说明](relnotes/)。

---

## 一、安全与隐私（请先读这一节）

### 系统用 AOSP 公开的测试密钥签名
<!-- B2 / SEC-2（用户 2026-10-04 定 D2：保留 test-key、披露）。证据：实机 otacerts.zip 只有 testkey.x509.pem，
     与 refs/aosp-build/target/product/security/testkey.x509.pem 逐字相同；framework-res 的证书 = platform.x509.pem；
     scripts/release.sh 没有签名步骤；ro.build.tags=release-keys 只是标签。 -->
* **现象**：看不出来。系统版本信息里写的是 `release-keys`，但那只是一个标签。
* **原因**：系统、系统应用和 OTA 更新包都用 AOSP 源码里**公开**的测试密钥签名，对应的私钥人人都能下载。
  所以**任何人**都能做出一个本机会当成正版接受的 OTA 更新包，或者一个以系统身份运行的 App。
  这台机器的安全因此取决于两件事：下载渠道没被人控制，以及你不装来路不明的"系统组件"。
* **替代办法**：
  * 只通过 设置 里自带的系统更新，或本项目的 GitHub Releases 页面更新。
  * 不要安装别人发给你的、自称"系统补丁 / 系统组件"的 APK 或 zip。
  * 全新安装时，安装器会先核对 `install-artifacts.sha256` 再写盘，别跳过这一步。

### `/data`（你的全部个人数据）没有加密
<!-- B3 / SEC-3（用户定 D3：1.0 不加密、如实披露）。证据：实机 ro.crypto.state=unsupported；
     device/huawei/gaokun3/fstab.gaokun3:27 的 userdata 行没有 fileencryption=；
     scripts/live/build-rootfs.sh:145 救援/安装系统 root 无密码（网络侧只认公钥）。 -->
* **现象**：锁屏密码只能挡住"开机后直接用"，挡不住"拿到机器的人"。
* **原因**：数据分区是明文的 ext4。Secure Boot 必须关着；开机菜单里有安装器和救援系统，本地控制台登录 root 不需要密码；
  插一个 Linux U 盘也一样。拿到机器的人可以直接读出照片、聊天记录、浏览器登录状态、Wi-Fi 密码等全部数据。
* **替代办法**：
  * 把这台机器当成"谁拿到谁就能看全部数据"的设备来用，不要在上面存放敏感资料。
  * 卖机、送修、借给别人之前，用图形安装器的 **重新安装 Android**（默认清除数据），见[常见问题](FAQ.zh-CN.md#恢复出厂--卖机前清除数据)。
  * 以后要上文件级加密，只能清空数据重装，老用户无法通过 OTA 直接获得加密。

### 默认带 root（KernelSU / ReSukiSU）
<!-- SEC-12 / REL-10（用户定 D6：保留 root、充分披露；1.0 前不出无 root 变体）。证据：实机 /proc/config.gz CONFIG_KSU=y、
     CONFIG_KSU_MULTI_MANAGER_SUPPORT=y；scripts/kernel-config-android.sh:363-420；TODO B11。
     ⚠️ 维护：v0.7.1 及以前【不预装】管理器 APK（TODO B11："ksud 就在 APK 里，装 App 即到位"）。1.0 若预装，
     下面"没有管理器时"那句仍然成立，但要在第一句写明"系统里带着 ReSukiSU 管理器"。 -->
* **现象**：内核里内置了 root 实现 KernelSU（ReSukiSU 分支）。某些银行、支付 App 和带反作弊的游戏可能检测到它，
  提示"设备存在风险"或拒绝运行。
* **原因**：开发和排错离不开 root，我们决定发布版也保留它。哪些 App 能拿到 root，由 **ReSukiSU 管理器** App 决定：
  只有你在管理器里批准过的 App 才能拿到；没有安装管理器时，没有任何 App 能拿到 root。
* **替代办法**：
  * 不需要 root 就不要在管理器里给任何 App 授权。
  * 目前没有不带 root 的版本，内核里的 root 能力关不掉。
  * 冒烟测试里，带 ACE 反作弊的《三角洲行动》和《卡拉彼丘》能正常运行；银行和支付类 App 还没有系统地测过，欢迎反馈。
<!-- 冒烟测试出处：docs/TODO.md:136（v0.7.1 候选版 1791053208，App 冒烟 8/8）。APP-4 的金融 App 测试做完后在这里补结果。 -->

### SELinux 处于 permissive（宽容）模式
<!-- SEC-4 / D5（建议：批 2 的三项 enforcing 验收都过就切，否则披露）。证据：device/huawei/gaokun3/BoardConfig.mk:128
     androidboot.selinux=permissive；实机 /sys/fs/selinux/enforce=0；perf_event_paranoid=-1。
     ⚠️ 维护：哪一版默认切到 enforcing，就删掉这一条（或改成"从 vX 起 enforcing"）。 -->
* **现象**：看不出来。
* **原因**：Android 的应用沙箱有两层，一层是普通的用户权限，另一层是 SELinux。这台机器的 SELinux 规则还没写完，
  所以它只记录违规、不拦截。后果是：一个 App 一旦找到漏洞，能做的事比在普通手机上多得多。例如任何 App 都能使用内核的性能计数器。
* **替代办法**：只安装来源可信的 App。

### 启动链未上锁，系统分区不做完整性校验
<!-- BoardConfig.mk:128 androidboot.veritymode=disabled；实机 ro.boot.verifiedbootstate=orange、ro.boot.flash.locked=0；
     docs/INSTALL.md 第 4 节"What this does not fix"。 -->
* **现象**：开机时不会检查系统有没有被改动过。Play Integrity 永远过不了（见下面的"Google 认证"一条）。
* **原因**：这台机器用 UEFI + systemd-boot 启动，Secure Boot 必须关着，内核没有签名，也没有开 dm-verity。
  能在这台机器上装别的系统，靠的就是这条开着的启动链。
* **替代办法**：没有。这是在这台机器上运行 Android 的前提。

---

## 二、随镜像一起分发的专有组件

<!-- SEC-10 / REL-15（D20：披露 + 准备不带 Histen 的构建开关）。证据：device/huawei/gaokun3/firmware/README.md 清单表与
     "不可公开再分发"一句（:36）；docs/TODO.md:86-96（Histen，用户 2026-09-28 定"带着发"）；TODO B23（zap shader 随
     live 镜像发，用户 2026-09-27 定）；device/huawei/gaokun3/lineage_gaokun3.mk:188-201（MindTheGapps）。
     ⚠️ NOTICE 还只写着"本仓库不含"，没覆盖二进制发布 —— 那一节由别的条目改（见 handoff）。 -->
本项目的源码按 GPL 等开源许可发布（见 [NOTICE](../NOTICE)）。但**发布的系统镜像、OTA 包和安装器镜像**里还带着下面这些
**不属于本项目、也不是开源软件**的组件。没有它们，GPU、Wi-Fi、蓝牙、声音、传感器都无法工作：

| 组件 | 在系统里的位置 | 来源 | 说明 |
|---|---|---|---|
| 华为专有固件：GPU 安全着色器（zap shader）、ADSP / CDSP / SLPI 固件、音频拓扑、pd_mapper 服务表 | `/vendor/firmware/qcom/sc8280xp/HUAWEI/gaokun3/` | 华为的 Windows 驱动包 | 未获华为的再分发授权。安装器镜像里也带着 GPU 那一份 |
| 传感器 DSP 配置（SLPI 的 JSON 与注册表） | `/vendor/etc/hexagonrpcd-root/` | 同上（高通参考配置） | 同上 |
| Histen 音效引擎 `libhw_histen_processing.so` | `/vendor/lib64/soundfx/` | 华为 Windows 驱动 | 华为专有，未获再分发授权，而且做过二进制修改。只有打开"扬声器增强（实验性）"时才处理声音 |
| Google 应用与服务（MindTheGapps：Play 商店、Play 服务等） | `/system_ext`、`/product` | Google | 闭源，按 Google 的条款使用 |
| GPU 微码、Wi-Fi、蓝牙固件 | `/vendor/firmware/` | linux-firmware | 高通的可再分发许可，不在上面的问题之内 |

这意味着：如果权利方提出要求，下载页面有可能被下架。你自己转发或二次分发镜像时，也要知道里面带着这些东西。

---

## 三、不支持或不完整的功能

### 设置里的"清除所有数据"（恢复出厂）不起作用
<!-- B6 / A5（用户定 D4：将来由 fastboot 承接，设计进行中）。证据：docs/INSTALL.md 的 Recovery 一节；#39。
     ⚠️ 维护：fastboot 落地并验收后改写这一条（替代办法换成新路径）。 -->
* **现象**：点了之后机器会重启，但**数据全部还在**，系统也没有任何提示。
* **原因**：这个功能要靠 recovery 来执行，而 recovery 在这台机器上启动不了，重启后的清除请求没人执行。
  将来会改成用 fastboot 来做恢复出厂，目前还在设计中。
* **替代办法**：用图形安装器的 **重新安装 Android**，它默认清除数据。步骤见[常见问题](FAQ.zh-CN.md#恢复出厂--卖机前清除数据)。

### 用 USB 线连电脑不能传文件（没有 MTP / PTP）
<!-- PWR-6 / BKUP-7 / STOR-7（1.0 只做文档；完整实现推迟到 1.0 之后）。证据：device/huawei/gaokun3/device.mk:57-64 注释
     （UsbDeviceManager 只在 /sys/class/android_usb 存在时才建，本机是 configfs）；init.gaokun3.usb.rc 只建了 ffs.adb；
     实机 sys.usb.config=adb、dumpsys usb 没有 device_manager。 -->
* **现象**：插上电脑后，电脑上不会出现这台平板的盘符或"便携设备"。平板上也没有"USB 用途 / 文件传输"的通知和设置项。
* **原因**：USB 的设备端目前只实现了 adb 调试这一种功能。要支持文件传输，还得补一整套 USB 功能切换，
  而且要和已知的 USB-C 口问题一起测试，排在 1.0 之后。
* **替代办法**：
  * 用局域网传文件的 App（例如 LocalSend），或者网盘。
  * 会用 adb 的话：打开 USB 调试，然后 `adb pull /sdcard/DCIM/ .`、`adb push 文件 /sdcard/Download/`。
  * 插着电脑 USB 口时这台机器不会进入待机（这是有意的设计，避免待机时整机复位），传完记得拔线。

### 插 U 盘没有反应
<!-- STOR-1 / BKUP-6（批 1 计划修：fstab 加 voldmanaged）。⚠️ 维护：修好并实测后删掉这一条。 -->
* **现象**：U 盘、移动硬盘插上后，文件管理器里看不到。
* **原因**：内核其实认到了设备，但系统的分区表配置里没有登记"可移动存储"，Android 不会去挂载它。
* **替代办法**：暂时没有。需要拷文件请用网络。

### 指纹不可用（开发中）
<!-- HW-5 / T6（D12：不是 1.0 门槛）。证据：docs/fingerprint-driver-design.md:3-5、104-112（M1 完成，M2 暂停）；
     实机 pm list features 没有 android.hardware.fingerprint。 -->
* **现象**：电源键上的指纹在 Android 里完全不存在，设置里没有指纹选项。
* **原因**：指纹比对在华为签名的安全固件里运行，命令协议需要从 Windows 驱动逆向。目前已经能把华为的指纹程序加载进安全环境，
  还差内核驱动和 Android 的指纹服务。
* **替代办法**：用 PIN 或密码解锁。指纹就算做出来，支付类 App 的指纹支付大概率仍然用不了。

### 手写笔（华为 M-Pencil）不支持
<!-- DISP-13。证据：refs/gaokun-buildbot/drivers/touchscreen-hx83121a/himax-spi-core.c:1074 只上报 MT_TOOL_FINGER；
     实机 getevent -pl 没有 BTN_TOOL_PEN。推迟到 1.0 之后（要逆向原始帧，XL）。 -->
* **现象**：手写笔完全没有反应，没有压感，也没有悬停。
* **原因**：触摸屏的触点是内核驱动从原始电容数据里自己算出来的，这套算法只认手指。笔的信号格式还没有人逆向过。
* **替代办法**：没有。

### 没有自动亮度
<!-- DISP-8 / HW-4 / A3（#121）。证据：实机 dumpsys display mAutoBrightnessAvailable=false。 -->
* **现象**：设置里没有"自适应亮度"，只能手动调。
* **原因**：光线传感器在总线上能应答，但一打开它，负责传感器的 DSP 就会崩溃，所以只能先关着。
* **替代办法**：手动调节亮度。

### 定位基本不可用（没有 GPS）
<!-- APP-13 / NET-5。证据：实机 pm list features 只有 android.hardware.location 与 .network，没有 .gps；dumpsys location 的
     network provider 来自 com.google.android.gms 且 enabled=false。本机是否有 GNSS 硬件未核实（无 modem）。
     国内 App 自带 Wi-Fi 定位 SDK 能否工作：未实测（批 4）。 -->
* **现象**：地图、天气、外卖、打车等 App 拿不到位置，或者一直显示"定位中"。
* **原因**：系统里没有 GPS。"网络定位"由 Google Play 服务提供，而它在国内连不上 Google。
* **替代办法**：
  * 在天气等 App 里手动选择城市。
  * 自带定位 SDK 的国内 App（例如用 Wi-Fi 定位的地图 App）也许能用，我们还没有测过。
  * 导航请用手机。

### 无法播放受 DRM 保护的视频（没有 Widevine）
<!-- AV-9 / APP-6（D11：不带，并披露）。证据：实机 service list 没有 android.hardware.drm.IDrmFactory；
     /vendor/etc/vintf/manifest/ 没有 drm；media_codecs_c2.xml:25。国内视频 App 的 VIP 内容受不受影响：未实测。 -->
* **现象**：Netflix、Disney+、Prime Video 等无法播放正片，会报 DRM 或"设备不支持"之类的错误。
  国内视频 App 的部分会员或版权内容可能也受影响（还没测过）。
* **原因**：系统里没有任何 DRM 模块。Widevine 是 Google 的闭源组件，需要授权和认证，我们没法带。
* **替代办法**：用别的设备观看这类内容。

### 蓝牙耳机在通话、语音时麦克风不可用
<!-- AV-2（1.0 只披露；HFP 软件数据通路推迟到 1.0 之后）。证据：device/huawei/gaokun3/audio/audio_policy_configuration.xml:25-31
     只 include 了 primary / r_submix / bluetooth_with_le_audio；实机 dumpsys media.audio_policy 没有任何 *BLUETOOTH_SCO* 设备；
     device.mk 的 bluetooth.profile.hfp.ag.enabled=true。"通话声音从扬声器出来"是推断，未实测。
     AV-3：A2DP 放音从没在真机上完整验过。AV-10：有线耳机麦克风也不可用（批 2 计划修，修好后删掉那半句）。 -->
* **现象**：用蓝牙耳机打微信语音、开腾讯会议、开游戏语音时，耳机上的麦克风不工作，通话声音也可能不走耳机。
  另外，有线耳机上的麦克风目前也不能用。
* **原因**：蓝牙通话需要一条专门的音频通路，这台机器没有高通给手机准备的那一套，系统里还没有搭出替代方案。
* **替代办法**：通话时用平板自带的麦克风和扬声器。用蓝牙耳机听音乐（A2DP）走的是另一条路，不受这条影响，
  不过它还没有在真机上完整测过。

### 待机时收不到消息推送
<!-- APP-5 / NET-9 / PWR-12（1.0 先测量后披露；WoW 推迟到 1.0 之后）。证据：docs/stage4-findings.md #131 §1（ath11k 在本机只走断电挂起）；
     device/huawei/gaokun3/device.mk:607 默认 persist.vendor.gaokun3.allow_suspend=1；device.mk:586-591 关待机的写法。
     实际延迟没量过（批 4 测完把数字补进来）。v0.7.1 发版说明：每次唤醒 Wi-Fi 约 2 秒回来。 -->
* **现象**：屏幕关掉、机器进入待机后，微信、QQ 等的新消息不会实时提醒，要等你点亮屏幕（或系统定时唤醒）才一起到。
  每次唤醒后，Wi-Fi 要过几秒才连上。
* **原因**：待机时 Wi-Fi 芯片整个断电，网络上的数据没法唤醒机器。国内 App 在这个系统上也没有厂商推送通道可用。
* **替代办法**：
  * 需要及时收消息时，让屏幕保持常亮，或者用手机收消息。
  * 也可以彻底关掉待机，代价是息屏时耗电明显增加。这需要 root（在 ReSukiSU 管理器里给 Shell 授权）：
    `adb shell su -c "setprop persist.vendor.gaokun3.allow_suspend 0"`。这个设置重启后仍然有效；改回 `1` 就恢复待机。

### 未通过 Google 认证
<!-- T2 / INST-14 / APP-4。证据：docs/INSTALL.md 第 4 节（登记流程与 Play Integrity 说明）；实机 verifiedbootstate=orange。 -->
* **现象**：Play 商店提示"设备未经 Play 保护机制认证"，有些 App 装不上。依赖 Play Integrity 的 App（例如 Google 钱包、
  部分海外银行）用不了。
* **原因**：这个 ROM 不在 Google 的认证设备名单上。Play Integrity 还要求上锁的启动链和 Google 签名的系统，这一条在本机永远满足不了。
* **替代办法**：按 [INSTALL.md 的"This device isn't Play Protect certified"](INSTALL.md#this-device-isnt-play-protect-certified)
  把设备登记一次，Play 商店就能正常用。Play Integrity 没有办法解决。

### 系统里带的是 Google 应用，国内用不上，也没有国内应用商店
<!-- APP-12（用户定 D7：只发 GApps 版、不发 vanilla）。证据：lineage_gaokun3.mk:188-201；LIVE-6（GMS 开机后常崩 4 次，用户是否看得到未确认）。
     GMS 在国内不断重试联网的耗电：未测。 -->
* **现象**：不翻墙时，Play 商店和 Google 服务都连不上，Google 服务还会在后台反复尝试联网（耗电没测过）。系统里没有国内的应用商店。
* **原因**：我们只发带 Google 应用的版本。
* **替代办法**：用浏览器从各 App 的官网，或者国内应用商店的网页版，下载 APK 安装。

### 其它不支持的硬件
<!-- 无 modem：CLAUDE.md 关键约束；无磁力计：README.zh-CN.md 传感器一行。 -->
* **没有蜂窝网络和 SIM 卡**：这台机器没有基带。
* **没有指南针**：没有磁力计。自动旋转正常，它用的是加速度计和陀螺仪。

---

## 四、其它常见问题（计划在后续版本改进）

这几条属于缺陷，不属于取舍，修好就会从这里删掉。

<!-- NET-2（批 2）。v0.7.1 发版说明里"芯片只能二选一"的说法不准确：iw 显示驱动支持 STA+AP，是软件配置没开。 -->
* **打开 Wi-Fi 热点时，平板自己会断开 Wi-Fi**：机器没有基带，所以热点没有网络可分享。原因是目前的软件配置不支持同时开 Wi-Fi 和热点，
  不是芯片的限制。
<!-- DISP-3（D10：找得到许可证合适、物理键盘可用的就预置，否则写文档）。⚠️ 维护：预置了就删掉这一条。 -->
* **系统没有自带中文输入法**：自带的键盘不支持中文。请自己装一个中文输入法（从输入法官网下载 APK）。

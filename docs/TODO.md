# 待办清单

最后更新：**2026-10-06**（重整：本文件只回答"还剩什么、下一步是什么"。已完成项的过程记录、1.0 dev.1–dev.9 的逐版装机记录、已结案的调查、
v0.6.x / v0.7.x 时期已收口的条目和旧的分梯队总表，原样搬到 [`archive/TODO-history-2026-10.md`](archive/TODO-history-2026-10.md)（按原顺序、标题层级不变）。
被搬走的节在原位置留了**同名标题 + 结论 + 指引**，所以别的文档里"TODO 的 v0.7.0 一节""TODO B1""TODO「▶ 1.0 批 0/1」dev.5 段"这类引用照旧能找到入口；
旧文件的 `TODO.md:NNN` 行号引用已对不上，按节名去 archive 里找。原来的文件头（历次对账说明）与 09-23 那行没重算过的统计已删，原文见 archive 的 [`#file-header`](archive/TODO-history-2026-10.md#file-header) / [`#summary-stats`](archive/TODO-history-2026-10.md#summary-stats)；条目数以下面总表为准。）

排序按 **1.0 发版路径**：发版阻断 → 1.0 应做 → 等用户 / 等硬件 → 1.0 之后。每条都写出下一步 —— 没有下一步的只是愿望。
1.0 各条目的定义、证据与批次以 [`v1.0-plan.md`](v1.0-plan.md) 为准；每版都要回归的项在 [`release-checklist.md`](release-checklist.md)；
结论的出处在案卷（[`stage4-findings.md`](stage4-findings.md) 等）；历史在 [`project-log.md`](project-log.md)。

状态：⬜ 没做 · ◐ 做了一部分（多半是"代码已进镜像、没上机验"）· ✅ 完成。编号沿用原来的：V0–V18 是「▶ 1.0 批 0/1」一节的验收号，
D1–D23 是 v1.0-plan §6 的决定，其余是 v1.0-plan 与本文件的条目号（旧编号去向见总表末尾的索引）。

---

## 总表：现在在做 / 待办（2026-10-06）

**设备现状**：槽 `_b` = **`1.0.0-rc.1`**（戳 `1791285623`，内核 `912f22c3`），**SELinux enforcing**，active = `_b`。**rc.1 验收（10-06）**：在 dev.10（enforcing）上经 OTA 装（第二次 enforcing 下 OTA ✅），A 档 **PASS 47 · FAIL 0**（发布闸门要的零 FAIL：验收期间临时关了开发机的 5555，跑完恢复）、iris 15/15、前后摄、s2idle 11/11、稳定 MAC、fcitx5 是系统应用（`UPDATED_SYSTEM_APP`，签名吻合）。载荷 `out/rc1-1791285623/`；安装器 `0.2.0-rc.1`（U 盘镜像带 rc.1 系统，Windows 包不带）在 `out/rc1-wt/out/release-installer/0.2.0-rc.1/`。踩到：enforcing 下 Android 侧写 EFI 变量被拒（efivarfs 没标签，`a1d303a` 修，进下一版；只影响开发脚本）。⬜ 发布：等用户给 R2 凭据并确认方式（建议 ROM `--stage-only` + 安装器 R2 + GitHub pre-release，不进 OTA 清单）。⚠️ 分派开着：设置里的恢复出厂会真擦。

**用户已定**：D1 发布版关 debuggable · D2 留 test-key 并披露 · D3 `/data` 不加密并披露 · D4 恢复出厂交给统一启动入口 · D6 保留 root ·
D7 只发 GApps 版 · D10 fcitx5-android 从 GitHub 取（2026-10-06，已入构建）· D13 备份默认 Seedvault · D15 默认时区上海 ·
D17 充电上限保持现状、**不做写 EC 的上机实测**（2026-10-06）· **D5 SELinux 切 enforcing**（2026-10-06，dev.10 起默认）· **E10 真机恢复出厂不测**（2026-10-06）· D21 0050 移出发布内核（dev.9 起）·
其余按 v1.0-plan §6 的"建议"列执行（2026-10-04）。仓库已推送到 origin。

**下一个构建（dev.11）要带上的**：`5c48d08` fcitx5 原样安装、`309f735` HAL 的 ESP 认法（EBUSY / enforcing），安装器 S1 / S2 修复与风险确认页（安装器侧，重建 live 镜像时带上）。

### ① 发版阻断（v1.0-plan §2 的 B1–B7 与发版标准 G1–G11）

| 编号 | 一句话 | 状态 | 下一步 | 证据 |
|---|---|---|---|---|
| B1 · G1 | 发布构建关掉免授权 adb、5555、debuggable、维护者公钥 | ◐ | dev.1 起每版 `release.sh` 断言过、只读判据过（`ro.adb.secure=1`、`ro.debuggable=0`）。剩 **V10 交互项**（用户在场）：全新装机没有 5555 监听、adbd 不在跑；「USB 调试」授权框、关了再开不断连、重启复位成关；「无线调试」配对码 | 下文 V1 / V10；archive [`#v1-batch01`](archive/TODO-history-2026-10.md#v1-batch01) dev.1 段 |
| B2 · G2 | 系统与 OTA 用 AOSP test-key 签名 | ◐ | 按 D2 不换 key，披露已进发版说明草稿。**⬜ R2 写密钥轮换 + 域名自动续费**（9-29 发版时密钥在会话输出里显示过一次；Cloudflare 后台做，不用构建） | v1.0-plan B2；archive [`#v070`](archive/TODO-history-2026-10.md#v070) 末行 |
| B3 · G3 | `/data` 不加密 | ✅ 决定 | D3：不加密、披露（known-limitations 已写；roadmap 的"FBE 在管 /data"已改正，`7a10ae2`）。发版说明定稿时再核一遍措辞 | v1.0-plan B3 |
| B4 · G4 | 新用户的安装路径都没在真机上跑过 | ⬜ | **M4a**：外接盘写出厂布局 → U 盘启动（两个口各一次）→ 整盘清空 → 开机并 OTA 一次 → 双系统 → 默认的"清除数据重装" → 首次开机向导走一遍；Windows 脚本找一台真 Windows（否则按 D18 标预览）。安装器代码侧（批 3 前后端、S10 / S15、Windows 伴随工具）都已写、本机测过；live 镜像 10-06 本机重建、rootfs 体检过 | 下文「等安装器」；[`stage7-flutter-debian.md`](stage7-flutter-debian.md) §5.13–§5.15 |
| B5 · G5 | live 写盘期间电源键 / 合盖会关机或挂起 | ◐ | 代码 `3608a52`；10-06 重建镜像体检过（5 个 target masked、logind 6 个键、systemd-inhibit）。⬜ 真机：只读查 `systemd-logind` / `power-switch` / `systemd-inhibit --list`，按电源键不关机、合盖不挂起、`systemctl suspend` 被拒 | 下文「等安装器」 |
| B6 · G3 | 设置里"清除所有数据"静默失效 | ◐ | 统一启动入口接管：1.0 镜像默认动作模式 + 分派开（`ca55b5c`），QEMU exec-wipe 过；**用户定 E10 不测** ⇒ 已知限制里"别指望设置里的清除数据"那段保持原样，推荐"图形安装器 → 重新安装 + 清除数据" | [`boot-entry-design.md`](boot-entry-design.md) E10；下文 A5 |
| B7 · G7 / G8 | 用户默认配置下的待机与长稳没测过 | ⬜ | 批 4（用户在场、拔线）：`allow_suspend=1` 放 8 小时（前后读 `qcom_stats`、`charge_now`、`suspend_stats`）、亮屏硬解 1 小时、72 小时狗粮；先用 V14 验 `scripts/perf/standby.sh` 的输出格式 | v1.0-plan B7 |
| G6 · OTA-2 | OTA 新槽起不来时自动回落 | ◐ | 入口的启动计数与自动回滚已真机过（E5 / E6 / E8）。⬜ **E11：0.7.x → 1.0 那一跳的迁移演练**（那次 OTA 由旧 HAL 执行） | archive [`#v1-batch01`](archive/TODO-history-2026-10.md#v1-batch01) dev.5 段 |
| G9 · SEC-4 | SELinux：1.0 切 enforcing | ◐ **用户 10-06 定：切** | ✅ dev.9 经 OneShot 真 enforcing 开机：普查只剩两类已知上游缺口；显示 / 触摸 / Wi-Fi / 传感器 / 音频 / iris 15/15 / 前后摄 / A 档 44 / s2idle 11/11（含 USB 角色切换与回插）全过（`out/sel-d5-*`）。BoardConfig 默认改 enforcing，dev.10 起。⬜ enforcing → enforcing OTA（dev.10 装机即是）；OTA-5 手工分区 ESP 名字不标准的机器 enforcing 下 OTA 失败（INSTALL 已写改名办法） | BoardConfig.mk 注释 |
| G10 | 用户文档 | ◐ | README 中英、INSTALL 中英（`33faa9b`）、FAQ、known-limitations、1.0 发版说明草稿（`8ccdd35`）都有了。⬜ 定稿（V17）：草稿里十余处"⬜ 还没在真机上测过"逐条回填或删掉 | `docs/relnotes/v1.0.0-draft*.md` |
| G11 | 回归清单与安装器一致性 | ◐ | `release-checklist.md` + `scripts/accept.sh` 已用于 dev.1–dev.9。⬜ GUI-15：RC 时用 1.0 的 boot.img 重建安装器、`release.sh` 断言两边 sha 一致 | release-checklist |

### ② 1.0 应做（v1.0-plan §3 / §4）

**已进 dev.9 镜像、等上机验**（判据写在下面各节）：

| 编号 | 一句话 | 状态 | 下一步 | 证据 |
|---|---|---|---|---|
| NET-4 · B20 | 稳定的 Wi-Fi MAC | ◐ | dev.9 上查出原修法没生效（随机化总开关关着时框架不碰 MAC）⇒ `b2c8c44`：开机在 Wi-Fi 打开前把 `wlan0` 写成序列号派生值；手动验证过、挂起 11 轮固件重载后地址不变。⬜ dev.10：两次重启 `wlan0` 相同且首字节含 0x02 | 下文「批 2 · 网络」 |
| NET-2 | 热点与 Wi-Fi 同时开 | ◐ | dev.9 `wlan1` 预建就位。⬜ 用户在场：连着 Wi-Fi 开热点，Wi-Fi 不断、另一台手机连热点能上网（顺带收掉 #11 的尾巴） | 同上 |
| NET-7 / NET-10 | 热点 5 GHz / WPA3 / 国家码；联网探测备用地址 | ◐ | ⬜ `cmd wifi get-country-code` 非 null、手机连 5 GHz / WPA3 热点；`dumpsys network_stack` 两项 URL（NET-10 可静默做） | 同上 |
| NET-1 | 息屏时 AP 断开后自动重连（软件 PNO） | ◐ | DeviceConfig 那道门已去（`e3c5ba3`，tree-fix [18]，dev.2 起）。⬜ V13 实测 | 下文 V3 / V13 |
| AV-4 / AV-10 / AV-16 | USB 声卡、有线耳机麦、裁掉示例设备 | ◐ | dev.9 静态项在（`IModule/usb`、cmdline 的 `snd_usb_audio.index`）。⬜ 插 USB 声卡（port1）+ 开机前插着冷启动一次；带麦耳机录 5 秒；`dumpsys media.audio_policy` 静默核对 —— 全部不放音 | 下文「批 2 · 音频」 |
| PWR-16 | Parts 待机开关 | ◐ | ⬜ 开关在「电池」页、拨关拨开属性随动、重启保留、开发机以前 setprop 的 0 显示成"关"；enforcing 下 avc 为 0 | archive `#v1-batch01`「批 2 ROM 侧」 |
| LIVE-5 · PERF-6 | power_profile；后台 cpuset 限到 0-3 | ◐ | dev.9 两个后台 cpuset = 0-3 ✅。⬜ `dumpsys batterystats` 看到 2 个 policy、21 / 18 步、容量 4483，「电池用量」页有排行；`game-perf.sh` 前后帧率不降；timeInState BPF 没加载那半条（下次自然重启抓 bpfloader 日志） | 同上 |
| PWR-14 · D17 | EC 充电上限 | ✅（按决定） | 代码随版本走、默认关；dev.9 上 IChargingControl 与四个 EC 节点属主就位。不做写 EC 的实测；两点没证据（停充时是否旁路供电、EC 对 start=0 / end=100 的行为）发版说明草稿写的是"EC 到达上限时具体怎么表现还没核对" | 同上 |
| B21 · DISP-14 | SLPI 崩溃自愈后传感器全丢 | ◐ | 恢复服务 `gaokun3_sscrecover` 已进 dev.9。⬜ V18：征得同意后让 SLPI 崩一次（唯一允许碰光感的地方），看恢复日志、约 60 秒内 accel 回来、自动旋转跟手 | 下文 V18 |
| DISP-15 · HW-6 | 键盘关着时拔插仍关；去掉 vibrator example | ◐ | dev.9 已无 vibrator HAL ✅。⬜ 用户拔插键盘盖；设置里"振动和触感"一项消失 | 下文 V18 |
| BKUP-5 · D15 | 备份默认 Seedvault；默认时区上海 | ◐ | 只在全新 `/data` 上看得到 ⇒ 并进 B4 的新装机验收；"从没设过时区的老机器 OTA 后变上海时间"写进发版说明 | 下文 V18 |
| DISP-3 · D10 | 中文输入法 fcitx5-android | ◐ | APK 已入构建（`f2fd400`），dev.10 起进镜像。⬜ 上机：设置里能启用、拼音出字、实体键盘中英切换（与 Android 自己的 Ctrl+Space 冲不冲突）、候选窗 | 下文 B12a |
| PWR-4 · USB-1 · USB-2 | USB-C 口异常 / 插电脑落成我方供电时弹通知；host 时不再每秒重绑 UDC | ◐ | 代码 dev.2 起在（`5dfe7dd` / `ccd54f9` / `d511d18`）。⬜ V11 里复现时看通知（插 Mac 落成我方供电、待机后回插坏口）；小改进：接收器改 directBootAware，解锁前也能报 | 下文 A6 |
| PWR-5 · STOR-1 · STOR-2 · STOR-5 | port0 有下游时保持 host；U 盘挂载；`/data` 保留块 | ◐ | STOR-5 dev.1 实测 ✅（保留块 32768 / gid 1065）。⬜ V11：U 盘 FAT32 / exFAT 插 port1 出现在「文件」；port0 插外设息屏亮屏 5 次仍是 host；开机插着 U 盘再换插 PC 时 adb 能否回来 | 下文 V11 |
| BATT-1/2/3 · DISP-1 | 电池按位解码（0072）；EC 初始 LID（0073） | ◐ | dev.3 起在。⬜ 用户在场：插电脑 USB 口带负载放电采 `ec_raw` / `current_now` 正负 / `capacity_level`；合盖开机一次看 `initial lid state: closed`；三种合盖姿态 getevent ⇒ 再决定 lid overlay | archive `#v1-batch01` dev.3 段 |
| PWR-13 · LIVE-13 · APP-17 | 内核配置项 | ◐ | dev.9 看到 THERMAL_STATISTICS、ARMV8_DEPRECATED ✅。⬜ PWR-13 另一半：SKIN 温度其实是芯片温度，要标定 EC 温度通道 | 同上「批 2 ROM 侧」 |

**还没做、要用户在场的**（v1.0-plan 批 1 / 批 2 的验收项）：

| 编号 | 一句话 | 状态 | 下一步 |
|---|---|---|---|
| DISP-2 · D9 | 接键盘横放时竖屏 App 把整屏转竖 | ⬜ | `wm set-ignore-orientation-request` 运行时 A/B，倾向回 Android 默认 |
| AV-1 | 录屏 / 录像从没产出过文件 | ⬜ | Recorder 录 10 秒屏 → Aperture 前摄 720p → 后摄；按结果补 media_profiles |
| AV-12 | 前摄方向没目视（DT 是 0） | ⬜ | 先拉 DCIM 看 EXIF，再请用户看一眼 |
| APP-4 | 银行 / 支付 App 与 Play Integrity 从没测 | ⬜ | 支付宝、微信支付、招行、工行、云闪付、12306 + 一个 Integrity 检测 App |
| INST-18 · D19 | 开机菜单不接键盘能否操作 | ⬜ | V15 实测音量键 / 电源键；再定 timeout |
| V12 | 亮屏后方向、陀螺仪、亮度 | ⬜ | 见下文 V12 |

**还没做、可以无人值守的**：

| 编号 | 一句话 | 状态 | 下一步 |
|---|---|---|---|
| V0 余项 | 批 0 只读核查的子项 | ⬜ | lpdumpd 的 tombstone；修 `gaokun3-loopback` 的 SIGSEGV（release-checklist 的 B6 / A13 要用它）；Histen 关着时音频 HAL 的 maps 里有没有 `libhw_histen_processing.so`（裁决 effects/README 与旧"发版暂停"一节的矛盾）；`mEnablePalmRejection`（DISP-6）、`LID_BEHAVIOR_NONE`（DISP-1）复核 |
| V2 · REL-7 | v0.7.1 的 GPL 源码补录 | ⬜ | 构建机（light 档）补 `v0.7.1-alpha-sources.md` 文末 "Not yet recorded"；查 `repo manifest -r` 为什么没跑成 |
| V5 | "待构建机核实"的源码出处 | ⬜ | 见下文 V5（libbase errno、vold 行号、sysprop.mk、configfs 的 UDC pending、Settings 菜单文案、SurfaceFlinger `--latency` 格式） |
| V14 | 采样脚本 | ⬜ | `standby.sh` 拔 USB 后存活 / `ev=wake` 行；`game-perf.sh` 图层名与 128 帧窗口 |
| HAL 误报 Windows | 手工删过 Windows 的机器 ESP 上留着 `bootmgfw.efi` ⇒ Parts 显示"重启到 Windows" | ◐ | 开发机的残留 10-06 已删（备份 `out/esp-backup-20261006/`），⬜ 下次开机确认 `bootentry.windows=0`；检测加"盘上有 NTFS / BitLocker 卷"，或在文档里写清 |
| 执行端余项 | fastboot 执行端 | ⬜ | 主菜单的电源键确认路径（Reboot to Android）、`flash` 都没真机验过 |
| 批 4 测量 | 只在 1.0 前做一次（v1.0-plan 批 4） | ⬜ | PERF-2 游戏基线 + UBWC A/B（B5b）、APP-5 熄屏推送延迟、AV-3 蓝牙耳机、AV-8/15 播放回归与 Histen 插耳机、AV-13/14、LIVE-7 60/120 Hz 电流、PERF-5、DISP-4 DP 输出、DISP-5/11/12、HW-10 人脸解锁、BATT-5/6/10、OTA-15、APP-19 QQ 平板模式、BKUP-10 —— 多数要用户在场或要外设 |

### ③ 等用户 / 等硬件

| 编号 | 事情 | 状态 | 要什么 |
|---|---|---|---|
| D5 · SEC-4 | 1.0 切不切 enforcing | ✅ 用户定切（10-06） | 见 ① 表 G9 |
| V7b | 1.0 预不预装 ReSukiSU 管理器 APK | ⬜ | 用户定；预装就改 known-limitations / FAQ / INSTALL 里"先装管理器"那句与 `gsf-android-id.sh` 的提示 |
| V7c | issue 表单渲染核对；v0.7.1 GPL 附件补传 | ⬜ | 仓库已推送 ⇒ 去 `issues/new/choose` 把 7 个表单打开看一遍；补传 release 附件要用户点头 |
| B2 R2 轮换 | 见阻断表 B2 | ⬜ | 用户在 Cloudflare 后台做 |
| B12 · D8 | OTA 与下载的长期基础设施（R2 / Worker 反代） | ⬜ | 用户定方案，改完在国内网络实测下载 |
| 原 D7 | v0.2.0-alpha 的 R2 产物删不删 | ⬜ | 用户定（删了老发布页链接 404） |
| 原 D5 | PR #3 的回复 | ⬜ | 用户定措辞 |
| 原 D6 · 上游 | `drm_crtc` BUG_ON 报 dri-devel；`docs/upstream/` 5 份内核补丁稿；libcamera `0002`（hi846）/ `0004`（ov13b10）；camcc RCG shared | ⬜ | 对外发言，用户点头 |
| T2 | Google 未认证 | ⬜ | 用户自己拿 Android ID 去登记（工具与文档就位） |
| A6b · NET-11 | issue #2 WPA3 连上即断 | ⬜ | 等报告者在当前版本上跑 `scripts/wifi/wpa3-probe.sh` |
| #12 / #15 | 抖音（已不复现）/ 英雄联盟秒退 | ⬜ | 要 tombstone / logcat |
| A6 硬件 | U 盘、纯充电器、扩展坞各跑一次 `scripts/usb/ucsi-snapshot.sh` | ⬜ | 用户手边的外设 |
| 外设清单 | USB 声卡、带麦耳机、DP 显示器、U 盘、蓝牙耳机、外接 NVMe、带 Windows 的 MateBook E Go | — | 分别对应 AV-4 / AV-10 / DISP-4 / STOR-1 / AV-3 / B4 / GUI-7 |
| 开发机清理 | `/data/local/tmp` 约 2.8 GB 历次测试内核（现状未核）；Ubuntu 救援分区（24.6 GiB）回收 | ⬜ | 删东西等用户点头 |

### ④ 1.0 之后（v1.0-plan §7 + 本文件的长期项）

指纹 T6（③ client driver、④ Android HAL；APP-18 支付指纹）· 自动亮度 A3 · 硬件视频编码 A2 · MTP / USB 用途 · BT SCO 通话 · WoW 待机联网 ·
A6 根因（dwc3 / QMP 的 resume 路径）与 B14 息屏 USB adb 原生化 · GPU SMMU 中断根治 B6 · 手掌碎块 T1 · 手写笔 · 相机 30 fps / 变焦 / EV / 画质（T3、A7 余项）·
游戏音频基础延迟（B25 尾巴 / AV-7）· NET-4 按网络的随机 MAC（连同一次性迁移）· Power HAL 真实现与 RT uclamp · 120 Hz 无缝降频 ·
quota / projid / casefold · FUSE passthrough · zram · Wi-Fi Direct · 海外 regdomain · B0 构建机的树换成本仓 checkout ·
B3 余项（退役 ESP 派生文件、AVB）· tinymix 的 vendor 变体 · #12 的 39 位地址空间测试内核起不来（搁置）· iris 零碎（`venus_compat_gfmt=N` 复测、HAL 的 POLLPRI 空转、SYS_ERROR 后 `invalid uc_region`）·
#16 尾巴（`ath11k_mhi_start` 失败不 unprepare，每次漏约 4 MB DMA，`mhi.c:446-450`）· recovery、原神渲染上限（见 E 节）。

### 旧编号索引（原第一 / 第二梯队表与对账表里的号，原表见 archive [`#tier1`](archive/TODO-history-2026-10.md#tier1) / [`#tier2`](archive/TODO-history-2026-10.md#tier2) / [`#user-actions`](archive/TODO-history-2026-10.md#user-actions) / [`#paused`](archive/TODO-history-2026-10.md#paused) / [`#reconcile`](archive/TODO-history-2026-10.md#reconcile)）

| 号 | 现状 | 去处 |
|---|---|---|
| S1 待机默认值 | ✅ 镜像默认 1（`release.sh` 断言），开发机持久 0；1.0 起 Parts 有开关（PWR-16） | — |
| B15 全新安装丢触摸参数 · B17 find-device | ✅ 2026-09-23 | — |
| B16 TCP 缓冲 · B18 remoteproc · B22 NTP · B23 zap shader 随 live 发 | ✅（v0.6.3 / v0.7.0 / v0.7.1 验收） | — |
| B19 没有回落槽 | VAB 的设计；回落由统一启动入口的自动回滚承担（E8 过） | G6 |
| B20 MAC 每次开机都变 | ◐ | NET-4 |
| B21 SLPI 自愈后传感器全丢 | ◐ 已进 dev.9 | ② 表 B21 |
| B24 内置麦克风 App 录音 | ✅ v0.7.0 验收 A1–A5（#127 §7） | — |
| B25 音游播放丢块 | ✅ 0069 随 v0.7.1 发、出声音游过（#130 §7）；播放回归 = AV-8（批 4），基础延迟 = 1.0 之后 | — |
| T3 相机画质 · T4 息屏 USB adb | ⬜ | ④（T3）；B14 |
| T5 平板声明 | ✅ `tablet`；QQ 平板模式 = APP-19 | 批 4 |
| T6 指纹 | ◐ TA 已加载（#125）；0050 已移出发布内核 | ④ |
| T7 扬声器增强 Histen | ✅ 随 v0.7.0 发（0068） | — |
| R 下一版发不发 | 1.0 发版要用户点头 | — |

---

### ▶ 1.0 批 0/1 已合并、待构建与验证（2026-10-05）

> 过程记录见 [archive/TODO-history-2026-10.md#v1-batch01](archive/TODO-history-2026-10.md#v1-batch01)（本节原文，含 dev.1–dev.9 逐版装机记录、「批 2 ROM 侧」五项、已合并改动表、V0–V18 全文、「等安装器」全文）。

**结论**：v1.0-plan 批 0 / 批 1 的 12 组改动 + 安装器组 10-05 合进 main；批 1 剩余 14 项（`27b50f8`…`bb8abf2`）、批 2 内核 / ROM / 网络 / 音频、统一启动入口 S7 / S9 / S11 / S15 随后合入。
九个 1.0 发布构建，每版一行：

* **dev.1** `1791138567`（10-05 03:10，`_b`）：第一个发布构建，V1 / V7a / V9 过；KSU 的 adb root 在 `ro.debuggable=0` 下照样生效（已写进 known-limitations 的 root 一条）；`release.sh` 的 pipefail 静默退出已修（`bed602c`）；`repo manifest -r` 没跑成（V2）。
* **dev.2** `1791144960`（04:43，`_a`）：批 1 剩余 14 项；postinstall 删无引用的 recovery ramdisk；smmustall 心跳缺失 → `c1d11dc`（dev.3 验过）。
* **dev.3** `1791151679`（06:32，`_b`）：批 2 内核 0072 / 0073 / 0074 实测；查出 AOSP `init.rc` 把 hung_task 写 0 → `0030c79`（dev.4 起 120）。
* **统一启动入口两道门槛**（06:14–08:3x）：E3 / E4 / E5 / E6 / E7（观察与动作模式，BCB 不消费）真机过，日志 `docs/hw/gk3probe-e3-…`、`gk3boot-e4-…`、`gk3boot-e5-e6-…`、`gk3boot-e7-…`。
* **dev.4** `1791156793`（08:1x，`_a`）：SEC-9 内核 v7.2-rc2 → v7.2.9；iris 15/15、相机、10 次真挂起过。
* **dev.5** `1791163499`（09:5x，`_b`）：S9 Android 侧入口三档闭环；**E8 真 OTA 回滚演练通过**（`docs/hw/gk3boot-e8-20261005.txt`）。
* **❌→✅ 更正 / 7.2.9 黑屏根因（结案）**：不是屏幕硬件故障，是 v7.2.y stable 的 `5de981b7db`（Revert "drm/msm: dsi: fix PLL init in bonded mode"，v7.2.6 进）撤掉了双 DSI 绑定 PLL 的修复 ⇒ `patches/0076` 撤回它（`ee81f67`），SEC-9 重新应用（`2333e2d`）。判据：亮屏时 `himax-spi-ts` 中断 ≈120/s = 面板在扫描。"判为面板 / 排线故障"作废。
* dev.6（`1791173750`，#16 内核）在本文件里没有单独的记录段（见 CLAUDE.md 的历史状态）。
* **dev.7** `1791185227`（16:0x，`_a`）：7.2.9 + 0076 + S7 执行端，显示恢复、相机过。**Wi-Fi 节拍（结案）**：s2idle 第 7 轮起 Wi-Fi 不重连 = 测试每 12 秒一轮撞上框架自动重连限速（约 50 秒内 5 次后停发约 6 分钟），s2loop 加 PACE=75（`5c8f6f8`）后 11/11。**iris 13/15（结案）**：测试中途关了屏，dev.9 亮屏 15/15、错误行 0。
* **fastboot 执行端与 BCB 分派真机通过**（17:0x–17:2x）：E6 执行端 + E7 分派六步，`docs/hw/gk3boot-e6exec-e7dispatch-20261005.txt`；执行端版本串的 `-dirty` 已修（`29f4614`）。
* **批 2 ROM 侧**五项：PWR-16 `4568f99`、PWR-14 `f242063`、LIVE-5 `ceb1167`、PERF-6 `2f12e43`、PWR-13 / LIVE-13 / APP-17 `f6d1001`（上机判据见 archive 本节开头）。
* **dev.8** `1791199356`（19:5x）：编过、`release.sh --dry-run` 过，未装机（用户：别测了、继续推进）；1.0 起默认动作模式 + 分派开（`ca55b5c`）。
* **dev.9** `1791215652`（10-06 00:0x 编，15:0x–16:0x 装 `_b`）：dev.8 + 批 2 音频 / 传感器与默认值 + 内核去掉 0050（D21，`912f22c3`）；**`install-ota-local.sh` 的 S11 新第 4 步首跑**；回归全过（见总表）；NET-4 更正（`b2c8c44`）；HAL 误报 Windows（见 ② 表）。

**V0–V18 现状**（全文与判据见 archive 本节）：

| V | 内容 | 状态 | 剩什么 |
|---|---|---|---|
| V0 | 批 0 只读验收 | ◐ | `accept.sh` 已在 dev.1–dev.9 跑；子项见 ② 表"V0 余项" |
| V1 | B1 关键源码 grep（不过就不编） | ✅ | dev.1：`ProductNotDebuggableInUserdebug` 只影响属性，init 仍允许 permissive；`GAOKUN3_DEV_BUILD` / `GK3_VERSION` 能进 Kati |
| V2 | GPL 补录与构建脚本 | ⬜ | 见 ② 表 |
| V3 | NET-1 第二道门 | ✅ 代码 | `e3c5ba3`；实测归 V13 |
| V4 | PWR-4 止损通知 | ◐ | `5dfe7dd`；坏口复现时看弹窗（V11） |
| V5 | 其余"待构建机核实"的出处 | ⬜ | 见下 |
| V6 | 编译 + 发布产物断言 | ✅ | dev.1 起每版；REL-5 版本属性 `ro.vendor.gaokun3.version`、`ssc_test` 的 toggle 模式都已写 |
| V7a | 开发机迁移（adb_keys、持久化 adb 属性） | ✅ | dev.1 之前 |
| V7b | 预装管理器 APK | ⬜ | 等用户（③） |
| V7c | 对外动作：表单、附件 | ⬜ | 等用户（③） |
| V8 | 新 HAL 前的同会话开关实验 | ✅（被 V9 覆盖） | toggle 模式已写；PWR-3 新 HAL 已随 dev.1 上机，亮灭屏 20 次"使能 / 停用"各 21 次、读数正常、无看门狗误报 |
| V9 | 新构建装后检查 | ◐ | dev.1 过（传感器功耗、STOR-5、NTP、usbrole、avc）。剩：亮灭屏 ≥50 次 + lights 的 errno 记录、二次开机不再 `Setting reserved block count`、B21 被动检查、"连上网到第一次对时"的耗时 |
| V10 | B1 上机验收（交互） | ◐ | 见阻断表 B1；另：开发构建 `adb root` 时桥接只报 EEXIST / EBUSY；发布构建上 `dmesg` / `logcat -b kernel` / `bugreport` 能不能用 |
| V11 | USB / 存储 / usbrole（用户在场，全程 TCP adb） | ⬜ | STOR-1 两种格式插 port1；PWR-5 port0 插外设息屏亮屏 5 次；开机插 U 盘再换插 PC 看 UDC；PWR-4 坏口时 `vendor.gaokun3.usbrole.broken=1`。STOR-3（port0 = 靠近电源键的口）✅ |
| V12 | 亮屏后方向、陀螺仪、亮度 | ⬜ | 旋转及时、三种陀螺仪情形、融合传感器；亮度只有出现可见后果才做内核侧根治（`himax_bl_update_status`） |
| V13 | NET 实测 | ⬜ | 息屏醒着时 AP 断开再恢复 2 分钟内重连；`allow_suspend=1` 定时唤醒后重连；软件 PNO 的耗电；`ntp.aliyun.com` 海外可达（要海外用户） |
| V14 | 采样脚本与 A22 | ⬜ | 见 ② 表；A22 = 在 USB adb 下真跑一次 `cmd wifi start-softap` |
| V15 | 文档里"待补 / 未验证"的事实 | ⬜ | 进 UEFI / 启动菜单的按键与无键盘操作；前摄方向；WPA2/WPA3 混合模式；QQ / 微信平板登录；R2 国内直连速度；BATT-1 低功率电源显示"充电" |
| V16 | 救援系统里 FAQ 写到的行为（要重启进救援） | ⬜ | systemd-pstore 会不会把 EFI 里的记录挪进内存并删变量；`ssh root@gaokun3-live.local`（avahi）；`gk3-boot-android` 写 EFI 变量 |
| V17 | 1.0 发版说明与"从 1.0 起"的说法 | ◐ | 草稿 `8ccdd35`（中英）；定稿前在已验收的发布构建上确认 `ro.adb.secure=1` / `ro.debuggable=0` / 没有 5555 |
| V18 | 传感器恢复、键盘拔插、振动器、备份、时区 | ◐ | HW-6 dev.9 静态过；B21、DISP-15、BKUP-5、D15、D10 见 ② 表 |

**V5 要核的出处**（结论回填到 FAQ / INSTALL / issue 模板 / 注释）：`system/libbase/file.cpp` 写失败后 errno 是否保留；`system/vold` 的 `DiskSource::matches` fnmatch flags 与 `vold.has_reserved` 出处；crDroid `build/make/core/sysprop.mk` / `config.mk` 与 `refs/aosp-build` 是否一致；
内核 `drivers/usb/gadget/configfs.c` 写 UDC 失败后 gadget 是否留在 pending（决定 V11 里 adb 能否自己回来）；crDroid 16 Settings 的实际菜单文案；`dumpsys SurfaceFlinger --latency` 的列格式与 128 帧窗口。

**等安装器**（`scripts/live/`、`live/installer-flutter/`、`scripts/windows/`；代码都已写、本机测过，下面全是真机项，并进 B4 一次做）：

* B5：见阻断表；另外停滞判死阈值（10 KiB/s 持续 60 秒）在国内走 R2 慢速时不误判；systemd 257 认不认 `--what` 的 handle-suspend-key；侧栏关机点一次。
* 批 3 前端：live 内核里 `gaokun-ec-battery` / `gaokun-ec-adapter` 在不在（电量预检）；纯 SAE 的 AP 真连一次；取消下载时 curl 跟着死；真 systemd 下界面被杀后重新起来能接上 job（GUI-11）；"保存日志"存到另插的 U 盘、Windows 上能打开（GUI-12；U 盘分区改 0700 前先实测固件回落启动）；英文界面（`gk3.lang=en`）走一遍。
* STOR-5：真盘装一次后 `tune2fs -l` 确认保留块。INST-6：从 Windows 安装包开始装一次、救援条目能起。INST-17 / OTA-10：OTA 后两条救援条目都能起。INST-12：救援里写 EFI 变量（V16）。
* GUI-7 / INST-11：`Suspend-BitLocker -RebootCount 2` 够不够、恢复保护时按哪条启动路径重新封存 —— 要一台带 Windows 的 MateBook E Go。S10 / S15 双系统安装侧与 Windows 伴随工具（预览）：`tools/gk3boot/README.md` §17、stage7 §5.15、`scripts/windows/README.md`。
* `release-installer.sh --r2` 没跑过（发布要用户点头）；"指向 latest"要等用户定是否每版都附安装器。
* `m0-internal.sh` 的发布构建提示：授权后 `adb shell` 是否直接 uid 0（V10）。

### ▶ 1.0 批 2 · 网络（NET-2 / NET-4 / NET-7 / NET-10）已写、未编译、未上机（2026-10-05）

> 过程记录见 [archive/TODO-history-2026-10.md#v1-batch2-net](archive/TODO-history-2026-10.md#v1-batch2-net)（提交表、源码出处、NET-4 两次更正的原文）。

**现状**（2026-10-06）：四项已随 dev.8 编过、dev.9 装机；tree-fix [19][20] 在真树上跑过（dev.8 起编译通过）。上机判据（用户在场的并进"热点加 Wi-Fi 同时开"那次）：

* **NET-2**：`ls /sys/class/net` 有 wlan1（dev.9 ✅）；连着 Wi-Fi 开热点，Wi-Fi **不断**、另一台手机连热点能上网；`dumpsys wifi` 里 HalDeviceManager 的 chip mode 有 STA+AP 组合。⚠️ 双信道组合（STA 5 GHz + AP 2.4 GHz）驱动报了支持，固件实际表现未验证。
* **NET-4**：1.0 **不开**随机化总开关（老网络存的 ALWAYS 会突然生效、无法安全迁移）；稳定设备 MAC 靠 `gaokun3-wlan-ap.sh` 开机写 `wlan0`（`b2c8c44`，dev.10 进镜像）。判据：两次重启 `wlan0` 地址相同且首字节含 0x02；`cat /sys/devices/soc0/serial_number` 非空。以后要开随机化：连同一次性迁移（WifiConfigManager 加标记）一起做，[20] 已备好。
* **NET-7**：`cmd wifi get-country-code` 非 null；热点设置里能选 5 GHz、WPA3；手机连上能上网。
* **NET-10**：`dumpsys network_stack` 里 https / http URL 是两项；临时用 iptables 拒掉 `connect.rom.miui.com` 后网络仍判"已连接"。
* ⓘ 热点 MAC 随机化、ACS、11ac/ax 热点这一轮都没动。

### ▶ 1.0 批 2 · 音频（AV-4 / AV-10 / AV-16，外加 AV-5 的记录）已写、未编译、未上机（2026-10-05）

> 过程记录见 [archive/TODO-history-2026-10.md#v1-batch2-audio](archive/TODO-history-2026-10.md#v1-batch2-audio)（提交表与关键核实的原文）。

**现状**（2026-10-06）：三项已随 dev.9 编过并装机（dev.9 = dev.8 + 批 2 音频）；dev.9 上 `IModule/usb` 与 cmdline 的 `snd_usb_audio.index=-2,-2,-2,-2` 在。
提交：AV-16 `2ab0372`、AV-4 `7240cd1`、AV-10 `3218dde`（`patches/0077`）。

**AV-10 条目本身**（策略 XML 里原来写着"见 docs/TODO.md"、而 TODO 里一直没有这一条 —— 现在就是这里）：有线耳机的麦克风不能用。硬件通路在：hw:0,2（`TX_CODEC_DMA_TX_3 → MultiMedia3`），混音器 TX 通路 `bin/audio-route.sh` 开机就摆好了（"耳机麦路由已应用（PCM2 / TX）"那段；控件名全部出自那里，这一轮没加新控件）。缺的只是"HAL 打开哪个 PCM"，上面那一行已补。⚠️ hw:0,2 以前只在**没插耳机**时录过（RMS −62 dBFS、51% 精确零，开路的样子，`docs/stage4-findings.md` #40），真信号与麦偏压（MIC BIAS 是否由 DAPM 自动打开）**待上机核实**；上游 UCM 原文本仓没有存档（`docs/hw-inventory.md` 提到的 `06-ucm2/` 不在仓库里），对不上就要回 Linux 救援里 `alsaucm` 对照。

**AV-5（ADSP SSR 后混音路由丢失，推测、从没观测到过）**：批 1 那一半（hangdump 记 remoteproc 状态变化）AV-6 已经做了（`bin/gaokun3-hangdump.sh` 的 `rproc_sig()` / `rproc_event()`，ADSP 的 q6v5 ready 计数一涨就记一条到 `/data/vendor/gaokun3/rproc-events.log`），不用再补。⬜ 剩下的：真碰到一次 ADSP 重启后，**静默**核对路由还在不在 —— `tinymix -D 0 'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2'`、`'MultiMedia4 Mixer VA_CODEC_DMA_TX_0'`、`'MultiMedia3 Mixer TX_CODEC_DMA_TX_3'` 都应是 On（`audio-route.sh` 设的值）；是 Off 就坐实 AV-5，修法是让 audioroute 在声卡重新注册后重跑（现在只在 `sys.boot_completed=1` 跑一次，`etc/audioroute.rc`）。hangdump 自己不跑 tinymix：它的域没有 `audio_device` 权限（`sepolicy/gaokun3_scripts.te` 只给了 audioroute），为一个推测去开权限不值。**不要为了验它去手动触发 SSR。**

**上机判据（全部静默，不放音）**：
* AV-16：`dumpsys media.audio_policy` 里没有 Telephony / FM Tuner 设备、Outputs 里没有 `compressed_offload`；有 App 放音（音量 0）时 `pcm1p` 仍 RUNNING。
* AV-4：`dumpsys media.audio_policy` 的 HW Modules 有 `usb`。**插 USB 声卡（先用 port1 —— port0 会触发 A6）**：内置声卡仍是 card0、USB 卡 ≥1，出现 `USB Device Out` / `USB Headset Out`，App 放音时 `card1/pcm0p` RUNNING。**开机前就插着 USB 声卡冷启动一次**：内置声卡仍是 card0、`logcat -s audioroute` 正常。
* AV-10：`getprop ro.vendor.audio.primary.alsa.in_headset` = `CARD_0_DEV_2`；插**带麦**耳机后 `Wired Headset Mic` 连上；录 5 秒（`gaokun3-mic-smoke`），logcat 有 `… gives card id 0, device id 2`、`card0/pcm2c` RUNNING、对着麦说话那段 RMS 明显高于 −62 dBFS；拔掉回到 `pcm3c`；三段耳机（无麦）不应连上 `Wired Headset Mic`。
* 回归：`scripts/audio/mic-verify.sh` 四个用例 + `dumpsys media.audio_flinger` 的 latency 与上一版相同。

### ▶ v0.7.0-alpha（已发布 2026-09-29，戳 `1790605865`）

> 过程记录见 [archive/TODO-history-2026-10.md#v070](archive/TODO-history-2026-10.md#v070)（两个候选版的验收全文、装机清单、Histen 0068 的诊断）。

结论：第一个候选版 `1790597477` 因 Histen 被 APEX 链接器命名空间拒载而不发 → `patches/0068` → 重编 `1790605865` 验收除第 8 项"待机后回插 USB-C 口坏"外全过（用户定写成已知问题照发，跟进见 A6）。
遗留：⬜ R2 密钥轮换（见阻断表 B2）；验收里新见的两条 SELinux denial 都已在第七轮处理（`hal_audio_default` 自调用 → `572a060`；`vendor_init` 写 printk → 09-29 删掉那行写入）。

### ⏸ 发版暂停（用户 2026-09-28）—— 已结束

> 过程记录见 [archive/TODO-history-2026-10.md#release-pause-0928](archive/TODO-history-2026-10.md#release-pause-0928)。

结论：v0.6.3 候选版 `1790206017` 不发，直接出 v0.7.0（带 B24 麦克风、iris、安装器预览、Histen 引擎 —— 用户定"带着发"）。"候选版一待机就复位"是测试方法错（插着 USB 直接 `echo mem`，#128 §17）。
遗留的 iris 零碎（`venus_compat_gfmt=N`、POLLPRI 空转、`invalid uc_region`）列在总表 ④。

### （暂停前）v0.6.3 候选版 `1790206017` —— 未发布，已被 v0.7.0 取代

> 过程记录见 [archive/TODO-history-2026-10.md#v063-candidate](archive/TODO-history-2026-10.md#v063-candidate)。

### 🐞 GitHub issues #11–#16（2026-10-04 逐条核查；处理随 v0.7.1-alpha 发布）

> 过程记录见 [archive/TODO-history-2026-10.md#issues-11-16](archive/TODO-history-2026-10.md#issues-11-16)（逐条根因、出处与 v0.7.1 装机验收原文）。

| issue | 结论 | 还剩 |
|---|---|---|
| #11 热点开不了 | ✅ hostapd 进镜像，v0.7.1 上 `start-softap` 成功 | 真设备连上并上网 → 并入 NET-2 |
| #13 天翼云电脑必崩 | ✅ 声明 `usb.host`，UsbService 起来 | — |
| #16 待机睡死 | ✅ 看门狗配置 + `patches/0070`（MHI 保留固件表）+ `0071`（CMA 限 2–4 GiB），GFP_DMA 高阶分配 69 → 0、挂起 12/12（#131） | ⬜ `ath11k_mhi_start` 失败不 unprepare 漏约 4 MB DMA（1.0 之后）；⬜ 请报告者给 `dmesg \| grep cma` 与 `alloc_pages_fail` |
| #12 抖音播放必崩 | 报告者：抖音 40.6.0 在同一 48 位内核上已不崩；39 位测试内核起不来、搁置 | 要 tombstone 才能继续 |
| #14 实测报告 | 与本表一致；MAC 部分并入 NET-4 | — |
| #15 实测报告 | 无代码改动 | 英雄联盟秒退要 logcat |

---

## A. 用户能感觉到的缺口

### A9. ✅ 内核可重建性已修好并上机验证通过
结论：`patches/0016`（ashmem）/ `0017`（xt_quota2）入库、`kernel-apply-patches.sh` 的指纹判据加固；重建验收判据已落地为 [`release-checklist.md`](release-checklist.md) D1。
过程记录见 [archive/TODO-history-2026-10.md#a9](archive/TODO-history-2026-10.md#a9)。

### A0. ✅ 侧滑返回手势失效 —— 根因：这台机器从来没有过导航栏
结论：overlay 设 `config_showNavigationBar=true`，#86 装机验收生效，用户 2026-09-23 确认。过程记录见 [archive/TODO-history-2026-10.md#a0](archive/TODO-history-2026-10.md#a0)。

### T1. ✅ 触摸手感 —— 已随 v0.6.2 发布，只剩手掌碎块（[#114](stage4-findings.md)–[#116](stage4-findings.md)）
结论：T1a 幽灵触摸（跳点限速线）、T1c fuzz=0 与触点面积轴、T1d 驱动六个缺陷、T1e 可观测性（`patches/0037`–`0047`）都已发。过程记录见 [archive/TODO-history-2026-10.md#t1](archive/TODO-history-2026-10.md#t1)。
还剩（都不阻断 1.0）：
* ⬜ 手掌碎成多触点（`max_contacts` 打满 10）：三个阈值假设全被实测否决、不影响点击 ⇒ 下一版驱动做跨帧形态判据（DISP-7，1.0 之后）。
* ⬜ T1b 三道形同虚设的噪声闸门：`patches/0039` 已做成旋钮 `iso_nbr_ratio_q8` / `edge_min_area`、默认值不变 —— 没有证据说幽灵走这两条路，留作边缘幽灵复现时的工具。
* ⬜ 触摸 IDC（`dumpsys input` 里 `ConfigurationFile: <none>`）：面积轴已有，可以写 `touch.size.calibration`（DISP-6，polish）。
* ⬜ Parts 里没有触摸手感开关（`persist.sys.gaokun3.*`，enforcing 下普通 adb shell 设不了；原记在 B1 的"非阻塞"）。

### T2. ⬜ Google 未认证（"设备未经 Play 保护机制认证"）
修法是把本机的 Android ID 登记一次：工具 `bash scripts/google/gsf-android-id.sh`（新版 GMS 的 ID 在 `shared_prefs/Checkin.xml`，不在 `gservices.db`）、
用户文档在 `docs/INSTALL.md` 的 "This device isn't Play Protect certified" 一节。⬜ **剩用户动作**：去 <https://www.google.com/android/uncertified/> 登记，然后 `pm clear com.android.vending`（恢复出厂后 ID 会变，要重登）。
⬜ INST-14：Parts 加"Google 认证"页（root oneshot 服务读 ID），不用电脑。⚠️ Play Integrity（银行类）仍然过不了，那是 UEFI 解锁的取舍。
过程记录（含 v0.6.2 起修掉的 incremental 不一致）见 [archive/TODO-history-2026-10.md#t2](archive/TODO-history-2026-10.md#t2)。

### A6b. ⬜ WPA3(SAE) 连上即断 —— [issue #2](https://github.com/vahiru/gaokun-android/issues/2)
结论：本机 SAE 栈端到端可用（#107：WPA3-SAE 一次连上、3 分钟带流量 0 掉线；#100 是密码记错）；issue #2 在本地不复现。
⬜ 下一步（NET-11）：请报告者在**当前版本**上跑 `scripts/wifi/wpa3-probe.sh "<SSID>" "<密码>"` 并贴输出。过程记录（已排除的三层、候选、`wpa_cli` 的用法）见 [archive/TODO-history-2026-10.md#a6b](archive/TODO-history-2026-10.md#a6b)。

### A1. 音频与蓝牙长期运行后死锁 ⚠️ 次高优先
> 现状（2026-10-06）：从未复现。hangdump 自 AV-6（dev.2 起）另记 remoteproc 状态变化（`/data/vendor/gaokun3/rproc-events.log`）；靠 B7 的 72 小时狗粮去碰。下面是原条目。

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

### A2. 硬件视频【编码】—— 已查明并【故意关闭】（1.0 之后）
结论：`v4l2_codec2` 的 `EncodeComponent` 不做 RGBX → NV12 转换，开着比关着更糟（rank 压过软编、应用直接失败），所以编码属性故意注释掉、`verify-hw-codec2.sh` 断言"必须没有编码组件"；录屏 / 录像走软编。
1.0 只在 AV-1 出片后做一次测量（AV-13）。过程记录见 [archive/TODO-history-2026-10.md#a2](archive/TODO-history-2026-10.md#a2)。

### A3. 自动亮度（环境光）—— 1.0 之后
现状：`tcs3701` 注册出来、芯片应答（#118 §5），但一使能光感 SLPI 的 sensor_process 就整个崩溃（[#121](stage4-findings.md)，`sns_stream_service.c:436`）；Windows 在本机用的也是 QRD 那套 JSON ⇒ 差别只剩 DSP 自己写的 registry。
⬜ 下一步：让 hexagonrpcd 可写（FadyAckad `sp11-sensors` 分支；psacal 称加写入桩后 ~408 lux，未复现）。⚠️ 激活光感会让 SLPI 崩（B21 的恢复服务能收拾）。
2026-09-23 之前"芯片不应答"的定性与 `scripts/ssc/` 实验记录见 [archive/TODO-history-2026-10.md#a3](archive/TODO-history-2026-10.md#a3)。

### A5. 恢复出厂设置不起作用 —— ◐ 已交给统一启动入口
用户 2026-10-04 定（D4）：恢复出厂（BCB `--wipe_data`）与 `fastboot -w` 都落到统一启动入口的执行端上。1.0 镜像默认动作模式 + 分派开（`ca55b5c`），QEMU exec-wipe 过；**用户 2026-10-06 定 E10 不测** ⇒ 真机未验，已知限制照旧。
现成的替代：图形安装器"重新安装 + 清除数据"；或救援里 `mkfs.ext4 -F /dev/disk/by-partlabel/userdata`。过程记录见 [archive/TODO-history-2026-10.md#a5](archive/TODO-history-2026-10.md#a5)。

### A6. USB-C 口（port0）角色 / UCSI ★ 待机后回插仍会坏
* 0048（`qcom,select-utmi-as-pipe-clk`）修好了常规角色切换（#118 §8：来回切三次 `-110` / `-524` 各 0 次）；角色策略用用户态 `follow`（电气探测，不信 EC）。
* ❌ **待机 / 唤醒之后回插 port0 仍会坏**（v0.7.0 第 8 项：`-524` / `-110`，间歇，第一个候选版同样步骤过过一次）⇒ 1.0 只止损：PWR-4 通知（`5dfe7dd`）+ 已知限制；根因（dwc3 / QMP PHY 的 resume 路径）放 1.0 之后。
* UCSI 在当前内核上是活的，但给的数据角色是反的（PC 插着时 `data_role=[host]`），靠 `init.gaokun3.usb.rc` 硬写 device 盖回来（#112）；EC 的 `partner_type` 插不插都是 2，可能是常数（#118 §6）。
* 2026-10-05 新发现：插 Mac 有时落成**我方供电**（USB-1，`ccd54f9` 弹通知请重插）；host 时每秒重绑 UDC（USB-2，`d511d18`）；port0 = 靠近电源键的口（STOR-3 ✅）。
* ⬜ 下一步：① 复现 —— 待机前后各切一次角色看哪一步坏，开 dwc3 / QMP 的 dyndbg；② **要用户插拔**：U 盘 / 纯充电器 / 扩展坞各跑一次 `scripts/usb/ucsi-snapshot.sh`，看 `partner_type` 与 `pwr_dir`，再定 quirk（扩展坞会 DR_Swap，不能盲用"受电 ⇒ 对方是主机"）；③ hub / U 盘 / 充电器的真机场景（V11）。

过程记录（UCSI 旧状态、#52 的取舍、总表旧行）见 [archive/TODO-history-2026-10.md#a6](archive/TODO-history-2026-10.md#a6) 与 [`#tier1`](archive/TODO-history-2026-10.md#tier1)。

### A8. ✅ 设备的 WAN 吞吐"只有 PC 的 1/20" —— 2026-09-14 结案：不成立
见 [archive/TODO-history-2026-10.md#a8](archive/TODO-history-2026-10.md#a8)（★ 对照组要先确认两边走的是同一条链路）。

### A7. 摄像头 —— 前后摄可用，电源域缺陷已根治（#105）
已收口：电源域（`patches/0031`）、基于 libcamera（simple 流水线 + 软件 ISP）的相机 HAL、后摄 OV13B10（0032 / 0034 / 0035）、闪光灯与手电筒、相机 ID 稳定、后摄方向 180（用户目视）、PR #6（AF / JPEG 旋转 / 崩溃）、后摄隐私灯（0074）。
过程记录（#81–#112 的全过程、已否的候选修复）见 [archive/TODO-history-2026-10.md#a7](archive/TODO-history-2026-10.md#a7)。还剩：
* ⬜ **AV-12 前摄方向**：设备树 0，未目视（PR 文档 7.2 的照片证据支持 0）—— 1.0 应做。
* ⬜ **AV-1 录像 / 录屏出片**、⬜ Aperture 后摄闪光 ON 拍一张看 LED 亮灭各一次 —— 都要用户在场。
* ⬜ **T3 画质**（1.0 之后）：闪光帧下发 `ExposureValue` 负补偿；libcamera AWB 剔饱和像素（值得投上游）；CCM 要色卡；手电筒亮度档位（HAL 声明 `FLASH_INFO_STRENGTH_*`、实现 `turnOnTorchWithStrengthLevel`）；`kDarkLuma=50` 是启发式（要 softisp IPA 把曝光 / 增益写进结果元数据）；AV-11 15 fps / 变焦 / EV。
* ⬜ libcamera：`camera_sensor_properties` 加 ov13b10、增益模型 helper、`ov13b10.yaml`；生成源码改成 Soong `genrule`（`patches/libcamera/README.md:34`）。上游：`ov13b10.c` 补 `get_selection`；读 EEPROM@0x50；camcc `Mark RCGs shared` 投稿 + 等待值 `0027`。
* ⬜ `patches/0022`（unbind / rebind 的 genpd 注销）在 camss **健康**时补一次验证。⚠️ camss 已 `runtime_error` 时不要 unbind（会拖死整机）。

### A′. 已关闭（只留索引，细节在案卷里）
s2idle 待机（`dr_mode="otg"`，#52–#57）· 耳机口与内置麦（#40）· 普通应用能 panic 内核（`patches/0013`，#58 / #62）· 硬件视频解码（#41）· 亮度调节（真 lights HAL）·
扬声器音量偏小（PA 21 / dig 84，#78 / #79 / #86）· 插着键盘时屏幕键盘不弹（`show_ime_with_hard_keyboard`）。原文见 [archive/TODO-history-2026-10.md#a-closed](archive/TODO-history-2026-10.md#a-closed)。

---

## B. 工程债与正确性

### B12a. ◐ 中文输入法（DISP-3 / D10）：fcitx5-android 0.1.3 已放进构建，⬜ 下一版构建 + 上机
2026-10-06 用户定从 GitHub release 取：APK sha256 `8e5de1036aea…` 与 GitHub 资产 digest 一致；`device.mk` 改成 APK 在就带（`GAOKUN3_WITH_FCITX5=false` 显式不带）；`sync-device-tree.sh` 3b2 断言；NOTICE 记 LGPL 源码 tag；已知限制中英改成"已预装、要自己打开一次"（没设成默认输入法）。
⬜ 上机：设置里能启用、拼音能出字、GK-W7X 键盘盖上怎么中英切换（与 Android 自己的 Ctrl+Space 冲不冲突）、候选窗正常。
10-05 的选型调研（fcitx5-android vs Trime）见 [archive/TODO-history-2026-10.md#b12a](archive/TODO-history-2026-10.md#b12a)。

### B12. ⬜ 释放 R2 桶的前提：国内可达的下载镜像
2026-09-14 v0.6.0 把清单 `download` 指到 GitHub Release 附件，用户当天反馈更新失败：附件 302 到
`release-assets.githubusercontent.com`，国内不可达；`raw.githubusercontent.com` 同样。已全部换回 R2。
出路：同一 Cloudflare 域名（`ota.072172.xyz`）下建 Worker 反代 GitHub Release 附件与仓库里的清单（⚠️ 2026-10-04 起仓库里**没有**清单了：`ota/gaokun3.json` 停在 v0.6.1、没有任何东西读它，已删（1.0 计划 REL-14）；权威清单只在 R2，由 `release.sh` 上传 —— 走这条路要先让 `release.sh` 把清单回写进仓库），
桶只留存储为零的转发层；或干脆保留桶（成本很低：出站免费）。**要用户定**，且改完要在国内网络实测下载。

### B14. ⬜ 息屏 USB adb（1.0 之后；[#112](stage4-findings.md)）
脚本折中（`bin/gaokun3-usbrole.sh` v2：插着主机息屏不切 host、不放行挂起，拔线再切）已在镜像里（2026-10-04 在 v0.7.1 上 md5 与仓库一致）；开发机 `allow_suspend` 持久为 0，1.0 起可用 Parts 开关（PWR-16）。
源码定性：device 模式挂起无条件 `dwc3_core_exit()`、gadget 总 soft disconnect ⇒ 上游 dwc3 没有"adb 穿越睡眠"。⬜ 复位根因（device 角色下挂起会整板复位，#52）开放；⬜ UCSI 角色修好（A6）后去掉脚本的 host 切换。
原文见 [archive/TODO-history-2026-10.md#b14](archive/TODO-history-2026-10.md#b14)。

### B13. ✅ `install-ota-local.sh` 装前先算 ESP 空间（2026-09-14）
见 [archive/TODO-history-2026-10.md#b13](archive/TODO-history-2026-10.md#b13)。

### B0. ⚠️★★★ 让构建机的设备树【就是本仓的 checkout】—— 已经咬了六次（1.0 之后）
现状：`~/crdroid/device/huawei/gaokun3` 是普通目录、靠同步脚本与本仓对齐，必然双向漂。探测器已有：编内核前 `kernel-apply-patches.sh <树> --verify`（绿了再 make）、
同步只用 `sync-device-tree.sh`（断言 adb_keys / firmware / hexagonrpcd-root / prebuilt-boot 这些不入库但构建必需的输入在）、同步一律排除 `._*` / `.DS_Store`。★ 参照物必须是"构建需要什么"，不是"本机有什么"。
⬜ 第一步：把构建机上那个目录换成本仓的 git checkout（或 symlink 到 checkout），换之前先做一次清单比对（`.gitignore` 掉的固件 / 传感器配置 / 预编译内核不能被覆盖）。
⚠️ 构建机 `prebuilts/build-tools` 里 `date` / `tar` 共 6 个文件被删、理由不明，只记录不编码；干净树构建出 `tar` / `date` 报错就是它。
六次事故的经过见 [archive/TODO-history-2026-10.md#b0](archive/TODO-history-2026-10.md#b0)。

### B1. SELinux 转 enforcing（= SEC-4 / G9）
现状以 [#129](stage4-findings.md)（第七轮）为准：块设备标签改按 by-name、相机 allocator 等 20 余处已修（`572a060` / `d885275` / `4d93d4c`）；**2026-09-30 第一次真 enforcing 开机成功**
（vendor 域零 denial，解锁 / GPU / 相机 / 音频 / 硬解 / 传感器 / Wi-Fi / 蓝牙 / usbrole 全过）。工具在 [`scripts/selinux/`](../scripts/selinux/README.md)。
* ⬜ enforcing 下真实待机与回插、enforcing → enforcing OTA；然后**用户定（D5）**默认改 enforcing 跟哪一版发（先发策略、再去掉 cmdline 的 permissive）。恢复出厂那一项随 E10 不测。
* ⬜ 新服务（PWR-16 开关、sscrecover、wlanap、Histen 开着放音 + 录音）在 enforcing 下各跑一次看 avc（`hal_audio_default` 自调用的规则已在 `hal_audio_default.te:34`，`572a060`）。
* ⬜ 非阻塞：rproc-kick / hexagonrpcd / bootctl 规则收窄；tinymix 的 vendor 变体（有了它 audioroute 就不用挂 `vendor_executes_system_violators`）；genfscon 前缀匹配盖住 UCSI `power_supply` 下的 `wakeupN`（语义不对、当前无后果，别当成有功能在等着修）。
* ⚠️ 切 enforcing 后 ESP 名字不标准的机器 OTA 会失败（OTA-5）；**不要用 `-user` 变体构建**（#117 §15）。
* ✅ 已收口：`/dev/dri/card*` 0666 → 0660（SEC-14，dev.2）；`vendor_init` 写 printk 的 denial（09-29 删掉那行写入）；allow_suspend 的 UI（PWR-16）。

第一至第七轮的过程（含两个"结构性阻塞"的旧处理、属性改名）见 [archive/TODO-history-2026-10.md#b1](archive/TODO-history-2026-10.md#b1)。

### B2. ✅ 真温控 HAL —— 已随 v0.6.0 进镜像
⚠️ 留着的教训：AOSP mock 的 skin / battery SHUTDOWN 阈值只有 36 °C，只换 HAL 不改阈值 = 开机几分钟自动关机。原文见 [archive/TODO-history-2026-10.md#b2](archive/TODO-history-2026-10.md#b2)。

### B3. 自研 EFI 加载器 —— ◐ 已被统一启动入口覆盖
`gk3boot.efi` 读 misc 选槽、扣 tries 自动回落、分派 BCB、从 `boot_x` 分区直接启动（E3–E8 真机过，[`boot-entry-design.md`](boot-entry-design.md)、`tools/gk3boot/`）——原条目"读 `bootloader_control` 选槽 + 解析 boot 镜像、让 BCB 能被消费"已做到。
⬜ 余项（1.0 之后）：退役 postinstall 与 ESP 上的派生文件；AVB / verified boot。原文见 [archive/TODO-history-2026-10.md#b3](archive/TODO-history-2026-10.md#b3)。

### B4. LiveCD 图形安装器（Flutter + Debian）
现状与里程碑见 [`stage7-flutter-debian.md`](stage7-flutter-debian.md)；1.0 的真机验收是总表阻断项 **B4 / B5**。原文（含 2026-08-23 搁置时的记录）见 [archive/TODO-history-2026-10.md#b4](archive/TODO-history-2026-10.md#b4)。

### B5b. ⬜ UBWC 压缩：仓库仍写着关（[#85](stage4-findings.md)）
`device/huawei/gaokun3/device.mk:263`（行号又漂了）仍是 `vendor.minigbm.debug=nocompression` —— Stage 2 为 SwiftShader 加的，turnip 之后没有存在理由。已知：设备上开着跑过 13 天，SMMU fault / `a6xx_recover` / GMU error 全 0；未知：**一次测量都没有**。
⬜ 做法：并进批 4 的 PERF-2（DISP-18）—— 删掉那一行并带一次实测（帧率 / 合成耗时 / 显存带宽三选一），别凭"理应更好"直接改。原文见 [archive/TODO-history-2026-10.md#b5b](archive/TODO-history-2026-10.md#b5b)。

### B6. GPU SMMU 中断根治
实际 DT 是全局 672/673、context bank 从 678 起；而硬件拉的是 675/680，
其中 680 被分给 CB2、675 整张表里根本没有。很像 CB 起始偏移就错了。
⚠️ 但只凭"675/680 挂起"推不出正确映射，而且**改错了没有任何征兆**
（只是继续收不到 fault）。做成之后可以丢掉常驻的 `smmu-nostall.sh` 轮询。

### B7. 用轻量系统替掉救援 Ubuntu —— 新装机已由安装器覆盖
新装机：安装器写 `gk3rescue` 救援条目（INST-6 / INST-17，见 stage7）。⬜ 开发机：Ubuntu 救援分区（24.6 GiB）仍在，回收要用户点头。2026-08-23 Alpine M0 的记录见 [archive/TODO-history-2026-10.md#b7](archive/TODO-history-2026-10.md#b7)。

### B8. ✅（查明、不修）`invalid volume index range in the curve` ×12
AOSP legacy 音量配方的启动顺序噪声，与本机无关。见 [archive/TODO-history-2026-10.md#b8](archive/TODO-history-2026-10.md#b8)。

### B9. ✅ SLPI handover 噪声 —— 结案
它是 SSC 向 AP 投递一批数据的门铃（#119 §4），`patches/0014` 的 ratelimit 是正解；"没订阅者时仍 50 Hz 常开"的空转由 PWR-3 修掉（dev.1 V9 实测），#119 §4 的更正已补（`b0133ab`）。见 [archive/TODO-history-2026-10.md#b9](archive/TODO-history-2026-10.md#b9)。

### B11. root（ReSukiSU）—— ✅ 随 ROM 常驻，D6 保留并披露
披露已写（known-limitations：授权过的 adb 直接是 root）。⬜ V7b 预不预装管理器 APK（`ksud` 就在 APK 的 `libksud.so` 里，ROM 侧不用加东西）；建议**不给** `kernelsu.allow_shell=1`。
原文见 [archive/TODO-history-2026-10.md#b11](archive/TODO-history-2026-10.md#b11)。

### D5. PR #3 待回复（已审完，等你定措辞）
线上那个 PR 动的正是内核预编译这一块。我把要问的整理好了，**没有发到 GitHub**
—— 对外发言等你。三个问题：`dr_mode=host` 是不是有意为之（那正是我们 #52 的
取舍另一半）；他们刷完之后 USB adb 还通不通；能不能公开那份内核 `.config`
（我们这边的断言是 52 条 MUST_Y + `VIDEO_QCOM_IRIS` MUST_N，可以对一遍）。

### D6. 把 `drm_crtc` 那个 `BUG_ON` 报到 dri-devel（对外动作，等你定）
`patches/0013` 修的是**上游 mainline master 现存**的缺陷：普通应用查一次
present fence 的名字就能把整机 panic 掉。稿子照那个补丁的 commit message
改一改就能发。我不代发对外邮件。

### D8. ✅ v0.6.1-alpha 已发布（2026-09-14）
见 [archive/TODO-history-2026-10.md#d8](archive/TODO-history-2026-10.md#d8)；那里列的"闪光 EV 负补偿与 AWB 剔饱和"归 T3（A7）。

### D7. v0.2.0-alpha 的 R2 产物要不要删（2.1 GiB，等你定）
`install/v0.2.0-alpha/` + `builds/…20260820….zip`。**它们正被 v0.2.0-alpha 的
GitHub 发布页链接着**，删了那个页面的下载链接会 404。桶现在 6.6 GiB，
免费额度 10 GB，不删也还撑得住。

---

## E. 明确搁置（记录理由，不是忘了）

* **recovery** —— 启动即复位循环（[#39](stage4-findings.md)），仍搁置；它原本要承担的恢复出厂与 fastboot 已改由统一启动入口的执行端承担（D4）。
* **原神 1080×1728 的渲染上限** —— 游戏按设备白名单给的档位，要突破只能伪装机型、有账号风险，留给用户决定。
* 原 E 节的另两条已不成立：**fastboot**（统一启动入口 + `gk3-fastbootd` 执行端，E6 真机过）、**GMS / Play 商店**（D7：只发 GApps 版）。

原文见 [archive/TODO-history-2026-10.md#e](archive/TODO-history-2026-10.md#e)。

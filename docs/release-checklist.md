# 发版回归清单

> REL-6 / PERF-12（`docs/v1.0-plan.md`）。这份就是此前在 `docs/TODO.md:244`、`:1017`、`docs/project-log.md:494`、
> `docs/stage4-findings.md:4691`、`:8053` 里被引用、却一直不存在的「发版收尾清单」。
> 内容取 `docs/TODO.md` 里三份装机验收清单的并集 —— v0.6.3 候选版（`:118-127`）、v0.7.0（`:57-68`）、
> v0.7.1（`:133` 那段与 `docs/relnotes/v0.7.1-alpha.md` 末段"没测的项"）—— 再加上 1.0 计划的 G1–G11 与 PERF-12 的三档。
> 以前每版临时按本版改动挑项目，上一版测过的项下一版不一定再测；以后**每个候选版都从这里抄**，本版的结果记进 TODO 的本版一节。

## 怎么用

| 档 | 什么时候跑 | 谁 | 工具 |
|---|---|---|---|
| **A 无人值守** | **每个候选版**，装机 oneshot 起来、开机 ≥10 分钟后 | 无人值守（USB 或 TCP adb） | `scripts/accept.sh` 一键 |
| **B 要人在场** | 每个候选版跑和本版改动相关的项；**1.0 RC 全跑** | 用户（解锁、插拔、目视、听） | 下表的命令 |
| **C 长稳与测量** | 只在 1.0 前跑一次；内核 / mesa / HWC / 刷新率 / minigbm 有改动时跑游戏那几项 | 用户在场或拔线放置 | `scripts/perf/` |
| **D 发版收尾** | `release.sh --no-build` 之前 / 之后 | 维护者（宿主机） | 下表的命令 |

```bash
# 候选版装进 _b、oneshot 起来、开机 ≥10 分钟后：
SER=gaokun3 bash scripts/accept.sh --stamp <候选版的 ro.build.date.utc> --soak 600 --video <某个.mp4>
echo $?        # 0 = 没有 FAIL；1 = 有 FAIL；2 = adb 不通或中途掉线（汇总行照出、带一个 A0 FAIL）。别接 | tail 再取 $?（CLAUDE.md 运维坑 1）
```

* 报告在 `out/accept/<戳>-<时间>/report.txt`，同目录存着 logcat / dmesg / dropbox 列表 / 频率与温度快照，下一版拿来对比。
* `--profile dev`：开发构建（adb 免授权与 TCP 5555 是故意的）时 A3 只记录、不判。发布构建一律 `release`（默认）。
* `--readonly`：只做只读检查（跳过开相机、录音、真解视频），任何时候都能跑。
* **WARN 不挡发版，但要人看一眼**（denial 有没有新的大面积、测试工具自己崩了等）。
* 本清单里每个属性名 / 路径 / 字符串都是 2026-10-04 在 `1791053208` 上实测核对过的；新增一项也要先在实机上核对再写。

---

## A 档：无人值守（`scripts/accept.sh`）

编号与 `accept.sh` 的输出一一对应。"来源"一列：v063#n / v070#n = TODO 里那一版清单的第 n 项，v071 = v0.7.1 那段，G = 1.0 计划 §1。

| # | 检查 | 命令 / 读什么 | 通过判据 | 来源 |
|---|---|---|---|---|
| A1 | 构建与内核 | `getprop ro.build.date.utc`、`ro.build.characteristics`、`/proc/version` | 戳 = 候选版的戳（`--stamp`）；`tablet` | v063#1、v070#1 |
| A2 | 开机状态 | `sys.boot_completed`、`/proc/uptime`、`persist.sys.boot.reason.history` | 1；开机 ≥10 分钟（不到判 WARN） | PERF-12 |
| A3 | 安全默认值 | `ro.adb.secure`、`ro.debuggable`、`persist.adb.tcp.port`、`/proc/net/tcp{,6}` 里 `:15B3` 的 LISTEN、`/product/etc/security/adb_keys` | 1 / 0 / 空 / 0 个 / 不存在（D1：debuggable 一起关） | G1 |
| A4 | 待机默认值（S1） | `grep allow_suspend /vendor/build.prop` | 镜像默认 = 1（设备当前值只记录：开发机持久 0） | v063#8 |
| A5 | 自研服务与域 | `getprop init.svc.<名>`；`ps -AZ` | `smmustall` `hangdump` `gaokun3_usbfollow` `vendor.{boot,camera-provider,sensors,light,thermal}-gaokun3` 都 running；`smmu-nostall.sh` 在 `gaokun3_smmustall`、`gaokun3-usbrole.sh follow` 在 `gaokun3_usbrole` 域 | v063#7 |
| A6 | 三颗 DSP | `/sys/class/remoteproc/*/{name,state}` | adsp / cdsp / slpi 都 running | v063#7 |
| A7 | 传感器 | `dumpsys sensorservice` 的 Sensor List | 有 `SH3001 Accelerometer`、`SH3001 Gyroscope` | REL-6 |
| A8 | Wi-Fi / 热点 | `cmd overlay lookup com.android.wifi.resources com.android.wifi.resources:string/config_wifi_tcp_buffers`；`dumpsys connectivity` 的 `TcpBufferSizes`；`dumpsys wifi` 的 `config_wifiSaeUpgradeEnabled`；`/vendor/bin/hw/hostapd` | 资源值与活动网络都含 `8388608`（没有活动网络时后者 SKIP）；SAE 升级 `false`；hostapd 在 | v063#5、v070#9、v071（#11） |
| A9 | USB 服务（#13） | `service check usb`；`pm list features` | `found`；有 `android.hardware.usb.host` | v071 |
| A10 | NTP | `settings get global ntp_server`；设备与宿主机 `date +%s` 之差 | `null`（没手动设）；≤5 秒（5–60 WARN，>60 FAIL） | v070#7 |
| A11 | 硬件解码 | `scripts/verify-hw-codec2.sh [片子]` | 小结失败 0；给了 `--video` 时第 5 步真解出帧 | v070#2 |
| A12 | 相机 | `/data/local/tmp/gaokun3-ncam-smoke` 与 `… front` | 两次最后一行都是 `RESULT: PASS` | v063#3、v070#3 |
| A13 | 麦克风 | `/data/local/tmp/micverify/gaokun3-mic-smoke -r 48000 -c 2 -t 5 -T`（不出声、不落文件） | 最后一行以 `RESULT: PASS` 开头（工具打的是 `RESULT: PASS (开头静音 N ms)`，`mic-smoke.c:511`）；logcat 有 `first capture block ready`、没有 `incomplete data received`。TIMING 行（开头静音、D ≈ 1 ms、E ≈ 21 ms）打进报告，人对照 v070#4 看 | v070#4 |
| A14 | 扬声器增强注册 | effect HAL（`android.hardware.audio.effect.service-aidl.example`）的 `/proc/<pid>/maps`；logcat | maps 里有 `libgaokunhisteneffect.so`；没有 effect 相关（`soundfx` / `histen` / `audio.effect`）的 `not accessible for the namespace`（App 自己的命名空间报错只记一笔） | v070#5（B2-0） |
| A15 | GPU | `scripts/verify-turnip.sh 600`（`--soak 600`） | 小结失败 0：GLES 行是 turnip、GMU 错误 / a6xx_recover 0、smmustall 心跳 `抓 fault=0`、帧读回有字节；浸泡前后三项不增、桌面进程 PID 不变 | PERF-12 |
| A16 | 崩溃 | `/data/system/dropbox` 里本次开机以来的条目 | `system_server_crash` 0；系统进程的 `SYSTEM_TOMBSTONE` 0。按 tombstone 头分类：`/data/local/tmp` 下的测试工具、`uid` ≥ 10000 或 `/data/app` 下的 App 只 WARN（跑过 B9 / C1 之后游戏自己的崩溃不算系统回归）；`system_server_anr` 0（否则 WARN） | PERF-12 |
| A17 | SELinux | `logcat -b all` + `dmesg` 里的 avc，`scripts/selinux/avc-summary.py`（permissive=1 / =0 各一遍）按（主体, 类型, 类, 权限）元组去重计数 —— 不依赖 `audit()` 戳，servicemanager 打的用户态 `service_manager` 拒绝也算进来 | 0 为 PASS；非 0 为 WARN，看有没有新的大面积 denial；`audit_lost` 0 | v063#6、v070#6、v071 |
| A18 | 待机计数与性能快照 | suspend_stats、qcom_stats、两簇 `time_in_state`、GPU `trans_stat`、thermal、cooling_device；频率与温度在 A15 前后各存一份（`freq-before.txt` / `freq-after.txt`），报告里出一行 A15 期间的平均频率增量 | 空闲时 cooling_device 全为 0；快照存进报告目录供下一版对比 —— **跨版本比 A15 期间的增量**，开机以来的累计值受开机时长影响 | PERF-12、REL-6 |
| A19 | GApps | `pm list packages com.google.android.gms` | 已装（D7：只发 GApps 版） | D7 |
| A20 | root | 经 adb root 或 `su -c` 的 `id -u` | 0（D6：保留 KSU；ro.debuggable=0 之后要验它还在） | D6、B1 |

A 档里不在 `accept.sh` 的两项（要手动，但不用人在场）：

| # | 检查 | 命令 | 通过判据 | 来源 |
|---|---|---|---|---|
| A21 | iris 回归 15 项 | `out/iris-rc/rc-accept.sh`（⚠️ 不在仓库里，只在维护者本机的 `out/`） | 播完后 seek、seek、分辨率变化、stop、drain 全过 | v070#2 |
| A22 | 热点起得来（#11） | USB adb 下 `cmd wifi start-softap gk3test wpa2 <口令>` → `dumpsys wifi` 看 AP 起来 → `cmd wifi stop-softap` | AP 起来；停掉后 STA 自己重连。⚠️ 会断 STA，TCP adb 下别做 | v071 |

---

## B 档：要用户在场

| # | 检查 | 怎么做 | 通过判据 | 来源 |
|---|---|---|---|---|
| B1 | 前后摄目视 | 解锁后开 Aperture，后摄、前摄各看一次，点按对焦 | 取景是正的（后摄朝向 180，#119 §7）；点按能锁焦 | v063#2 |
| B2 | USB 拔插 | 拔插一次 USB 线；port0 / port1 各插一次 U 盘，亮屏、息屏各一次 | USB adb 能回来（0048 + follow）；U 盘能挂上。⚠️ 待机后回插 port0 失败是已知问题 A6 | v063#4、批 1 |
| B3 | USB 授权弹窗 | 发布构建插 USB | 弹 RSA 授权框；不授权时 `adb devices` 是 unauthorized | G1 |
| B4 | 真实待机 | 临时 `setprop persist.vendor.gaokun3.allow_suspend 1` → 拔 USB → 息屏等它睡 → 电源键唤醒 → 插回 USB → 改回原值 | `suspend_stats/success` 涨了；TCP adb 回来；插回后 USB adb 回来。⚠️ 别插着线直接 `echo mem`（device 角色挂起会整板复位，#128 §17） | v070#8 |
| B5 | 扬声器增强开关 | 设置 › 声音里的开关：开 / 关两向，各放一段音乐；有耳机时插耳机再来一遍 | 默认关；关着时音频正常（bypass）；开着时 logcat 有 `Histen chain up`；耳机不走扬声器链 | v070#5（B2-1…B2-5） |
| B6 | 出声音频 | 扬声器、耳机、双麦录音、蓝牙耳机各放 / 录一段；音游跑一遍出声回归（#130 §7） | 都有声、无爆音；音游卡顿后下一声即恢复。⚠️ 回环工具 `gaokun3-loopback` 10-04 自己崩过一次，回归前先修稳 | Stage 4、v071、PERF-12 |
| B7 | 热点让真设备连上 | 开热点，手机连上并打开网页 | 连得上、能上网（STA 同时开着时） | v071 未测 |
| B8 | 混合 WPA2/WPA3 路由器 | 连一台 WPA2/WPA3 混合模式的路由器 | 连得上、不反复断 | v071 未测 |
| B9 | App 冒烟 | 解锁后各开一次：明日方舟、三角洲、卡拉彼丘、Phigros、Arcaea、QQ、网易云、Brave | 0 崩溃（之后 `accept.sh` 的 A16 里 `data_app_crash` 不新增） | v071 |
| B10 | 1.0 RC 追加 | 合盖三种姿态的 getevent（DISP-1）；屏幕方向 A/B（DISP-2）；录屏与录像（AV-1）；开机菜单不接键盘能否操作（INST-18）；金融类 App（APP-4）；首次开机向导完整走一遍并截图（OTA-13） | 按各条目的判据；结果记进 1.0 计划对应条目 | 1.0 计划批 1 / 批 3 |
| B11 | 安装路径（G4） | 外接盘 / 真 NVMe 上：整盘清空、双系统、清除数据重装、从 U 盘启动 | 各通过一次，记进 `docs/stage7-flutter-debian.md` §M4a | G4 |
| B12 | OTA 与回落（G6） | 在 `_b` 上从上一版保留数据 OTA 一次；让新槽故意起不来 | 数据原样；能回到旧槽 | G6 |
| B13 | live 安装器写盘安全（G5） | 启动进 live（开机菜单的 `gaokun3 installer`，要重启 ⇒ 要用户同意、在场），ssh 进去跑 `systemctl is-active sleep.target`；写盘期间按电源键、合盖各一次（用测试盘）；本机 `cd live/installer-flutter && flutter test test/flow_test.dart` | `sleep.target` 是 `masked`、写盘不被打断；flow_test 里有"下载失败 → 重试"用例且通过。⚠️ 2026-10-04 两样都还没有：mask 由 1.0 计划 B5（GUI-2）加，重试用例由 GUI-3/5、GUI-14 加 —— 落地之前本项判不过 | G5 |

---

## C 档：长稳与测量

| # | 检查 | 怎么做 | 判据 / 记录 | 来源 |
|---|---|---|---|---|
| C1 | 游戏性能基线 | 用户解锁、进固定场景后：`SER=gaokun3 bash scripts/perf/game-perf.sh -p com.tencent.tmgp.dfm -t 1200`（三角洲 20 分钟）；`-p com.idreamsky.klbqm -t 600`（卡拉彼丘 10 分钟）；`-p com.hypergryph.arknights -t 1800`（明日方舟挂机 30 分钟）。之后马上 `accept.sh --readonly` 看 A15 / A16 | 每个记平均 fps、1% low、CPU / GPU / 内存最高温、温控压频秒数、GPU 频率分布；GMU / fault 0。**和上一版比，平均 fps 降超过 10% 或最高温升超过 5 °C 判失败**。先看 `header.txt` 确认帧率上限是 60 还是 120（PERF-2 复核）。**UBWC 的 A/B 同时做**（DISP-18 并入 PERF-2，`docs/v1.0-plan.md:141`、`:229`；TODO B5b）：同一场景在 `vendor.minigbm.debug=nocompression`（`device.mk:224`，历版发布值）与 UBWC 开着各跑一次，两份 `summary.txt` 并排记 —— 切换要改镜像或 overlay，按 TODO B5b 的做法来，别凭"理应更好"直接改 | PERF-2、PERF-12、DISP-18 |
| C2 | 拔线待机 8 小时 | 插着线 `SER=gaokun3 bash scripts/perf/standby.sh start` → 用户临时把 allow_suspend 设 1 → 拔 USB、息屏放 8 小时 → 插回 `pull` → `stop` → 改回原值 | 不设合格线，但必须量过（G8）：掉电点数 / 每小时、charge_now 的 mAh、挂起次数、`cxsd` / `aosd` / `ddr` 增量写进案卷与发版说明。`cxsd` 仍为 0 时按 1.0 计划 B7 的顺序排查 | B7、PERF-3、G8 |
| C3 | 亮屏硬解 1 小时 | 固定亮度，`HB=300 … standby.sh start`，拔线连续硬解播放 1 小时，`pull` | 掉电点数写进案卷（G8） | B7、G8 |
| C4 | 72 小时狗粮 | allow_suspend=1、拔线日常使用，`standby.sh start` 全程开着；结束 `pull` | 真实挂起 ≥30 次；`system_server_crash` 0、tombstone 0；心跳行里关键进程 PID 不变、RSS / fd 无单调增长；每次唤醒后 `wlan=up` 能回来；结束后 `accept.sh` 全过（G7） | B7、PERF-4、G7 |
| C5 | 挂起 / 恢复循环（#16） | 内核改动时：`scripts/s2idle/android-ath11k-s2loop.sh`（用法见脚本头；先切 host） | 全部恢复、Wi-Fi 每次回来；恢复期间 GFP_DMA 高阶分配 0（#131） | v071（#16） |
| C6 | 60 / 120 Hz 电流对比 | 同一场景各测一次 `current_now` | 数据交给 D16（刷新率选项）决定 | LIVE-7 |

---

## D 档：发版收尾（宿主机侧）

| # | 检查 | 怎么做 | 通过判据 | 来源 |
|---|---|---|---|---|
| D1 | 内核能从仓库重建 | 设备 `/proc/config.gz` 与照本仓配方重建出的 `.config` 做 diff；两个内核镜像做全字符串差集，dtb 比 sha256 | config 无差；字符串差集无未解释项；dtb sha256 一致（字符串差集看不见 DTS） | `TODO.md:244`、`stage4-findings.md:4691` |
| D2 | 文档不过时 | `grep -rnE "cannot suspend\|不能待机\|=m\|❌" README.md README.zh-CN.md docs/INSTALL.md docs/TODO.md`，再对 README 状态表与本版实测；设备树里的成段注释也会变质（`init.gaokun3.rc`、`etc/usbrole.rc`、`device.mk` 都出过事），另跑 `grep -rnE "^[[:space:]]*#.*(cannot suspend\|不能待机\|❌)" device/huawei/gaokun3/` 只看注释命中 | 每一处命中都确认仍然成立 | `project-log.md:494`、`TODO.md:1017`、`stage4-findings.md:8053` |
| D3 | 发的就是验过的那一版 | `release.sh --no-build`；变体是 `lineage_gaokun3-bp4a-userdebug`；各分区 build.prop 的 `date.utc` 对一遍（system / system_ext / product / vendor / odm，vendor 的曾停在 09-28 —— OTA-11 / SEC-13） | 构建戳 = A1 验过的戳；各分区 `date.utc` 一致（G6 要 `release.sh` 断言这一条，⬜ 截至 2026-10-04 `release.sh` 只比了清单 timestamp 与 `ro.build.date.utc`，`:82-85`，落地前手动比） | CLAUDE.md、#117 §15、G6 |
| D4 | 产物齐、字节对 | GitHub release 附件逐个核对服务端字节数；R2 清单最后传、设备侧抓取 200；`install-artifacts.sha256` | 字节数与本地一致（别信上传命令的输出，CLAUDE.md 运维坑 1） | v0.7.0 / v0.7.1 发版记录 |
| D5 | 安装器与 ROM 一致 | 安装器里的内核 / dtb 与 ROM 的 `boot.img` 拆出来的比 sha256 | 一致 | G11 |
| D6 | 发版说明与披露 | 已知问题 / 不支持一节：root（D6）、AOSP test-key 签名（D2）、`/data` 不加密（D3）、专有组件、Widevine、U 盘 / MTP / 指纹 / 手写笔等；GPL 对应源码清单 | 每项都写了 | G2、G3、G10、REL-7 |
| D7 | 验收记录存档 | A 档报告目录、B / C 档结果 | `report.txt` 汇总行 FAIL 0；B / C 档结果写进 TODO 的本版一节 | G11 |
| D8 | SELinux 的去留（G9） | 二选一：做完 #129 §6 剩下的 3 项、默认切 enforcing（`getenforce` = `Enforcing`，A17 在 enforcing 下跑一遍 `avc-summary.py --enforcing`）；或者书面接受 permissive | 有用户的决定（1.0 计划决定 D5）**加一份验收记录**：切了就附 enforcing 下的 A 档报告；没切就在发版说明里披露、并把决定记进 TODO 的本版一节 | G9、SEC-4 |

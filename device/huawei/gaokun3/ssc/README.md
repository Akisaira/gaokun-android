# SSC 客户端 —— 从 Android 侧读 SLPI 上的传感器

这台机器**没有任何 AP 侧传感器芯片驱动**：加速度计、陀螺仪、光感、铰链角
全部跑在 SLPI DSP 上，AP 够不着那些总线。可行的通路是反过来 ——
AP 用 FastRPC 给 DSP 当只读文件服务器（`hexagonrpcd`），DSP 起 SSC，
再由 QRTR 上的 QMI 服务 400 把读数送回来。

背景与全部踩坑见 `docs/stage4-findings.md` #37；
**协议规格（含每条事实的来源文件与行号）见 `docs/sensors-ssc-protocol.md`。**

## 为什么不用 libssc

`libssc` 依赖 glib / gio / gobject / **qmi-glib(libqmi)** / libprotobuf-c，
整套 GLib 栈搬不进 Android。但它的协议逻辑很薄，`.proto` 只有几百行，
而 AOSP 自带 `protoc` 与 `libprotobuf-cpp-lite` —— 照规格重写比移植依赖便宜。

## 内容

| 文件 | 作用 |
|---|---|
| `ssc_client.{h,cpp}` | 可复用客户端：QRTR lookup → QMI 组包/解包 → protobuf。**将来的 AIDL HAL 直接链 `libgaokun3ssc`** |
| `ssc_test.cpp` | 命令行验证工具 `gaokun3-ssc-test`，对标 Linux 上的 `ssccli`；另有 `toggle` 模式（同会话循环开关，见下）|
| `ssc-*.proto` | 取自 libssc 原文（GPL-3.0，保留其版权头）|

## 实测结果（2026-08-20，Android，slot _a）

```
$ gaokun3-ssc-test accel 10 8
SSC 服务 400 在 node 9 port 13
传感器 accel 的 UID = 61ab5376b4a5c9aa58442ede47acd316
  X=-0.086191 Y= 0.052672 Z= 9.883265  accuracy=3
```

| data_type | 结果 |
|---|---|
| `accel` | ✅ Z≈9.88 m/s²（重力），accuracy=3 |
| `gyro` | ✅ 静止时各轴 ≈0 rad/s，accuracy=3。★Linux 侧从未验证过（那边的 `ssccli` 不支持）|
| `mag` | ❌ SSC 明确回答"没有传感器提供" —— **本机没有磁力计**，所以没有指南针 |
| `rotv` | ❌ 未注册（配置里有 `sns_rotv.json`，但融合旋转矢量多半需要磁力计）|
| `ambient_light` | ❌ **别碰**：使能后从不返回读数，且会污染整个 SSC 会话 —— 之后连加速度计也读不到，必须重启 hexagonrpcd |

⚠️ `mag`/`rotv` 那两次"找不到"**不会**污染会话（回读 accel 正常），
与 `ambient_light` 的行为不同。

## 用法

```sh
# 前提：hexagonrpcd 在跑
gaokun3-qrtr-lookup 400        # 先确认服务在
gaokun3-ssc-test               # 默认 accel 10 Hz 10 秒
gaokun3-ssc-test gyro 20 5
```

⚠️ **需要沉降时间**：hexagonrpcd 刚起来时 SSC 约需 20 秒才出数，
所以本工具的等待窗口给到 40 秒。**"读不到"不等于"坏了"。**

## toggle 模式：同一会话循环开关（上新 sensors HAL 之前的前置实验）

> ⬜ **未编译、未上机**（2026-10-05 写）。本机编不了（要 Android 的 protobuf 与 Soong），
> 只用桩头文件在 macOS 上做过 `clang++ -fsyntax-only -Wall -Werror`。

```sh
gaokun3-ssc-test accel 50 20 toggle   # 50 Hz，循环 20 轮 —— ★ 第 3 个参数是【轮数】，不是秒数
gaokun3-ssc-test gyro  50 20 toggle
```

**它做什么**：在**同一个 `SscClient`、同一个 UID** 上，每轮
`EnableContinuous` → 收 2 秒（数测量条数、打印首条 X/Y/Z）→ `Disable` → 静默 2 秒
（照样收，停用后仍到达的测量单独计数，并单列 500 ms 之后才到的那部分）。
每轮一行 `第 n 轮：测量 m 条，停用后残留 k 条`，最后一行汇总；全部轮次结束后
再在同一会话上查一次 `FindSensor`，确认枚举没坏。
调用序列照 [`../sensors-hal/SscHub.cpp`](../sensors-hal/SscHub.cpp) 的 PWR-3 启停路径做
（会话开始时查一次 UID、重开时**不**重查、停用发 msg_id=10、停用后只读 500 ms），
逐条出处行号写在 `ssc_test.cpp` 的 `RunToggle` 上方。只接受 `accel` / `gyro`；
**`ambient_light` 绝对不要用**（会污染整个 SSC 会话，见上面的表），程序也会拒绝。

| 退出码 | 含义 |
|---|---|
| 0 | 每轮都有读数，结束后枚举正常 |
| 1 | 参数错 / 打开 / 就绪 / 60 秒内找不到传感器 / 使能请求发不出去 |
| 3 | 某一轮 2 秒内一条测量都没有 —— 立刻停止 |
| 4 | 轮次都过了，但结束后同一会话上再查 `FindSensor` 失败（枚举坏了） |

**为什么是前置实验**（v1.0 计划 HW-3 / LIVE-2 的复核意见）：新 HAL（PWR-3，`4db08bc`）
没有订阅者时会在 SSC 上 `Disable`、有人 activate 时在**同一个 client** 上重新
`EnableContinuous`。我们实测过的只有"反复**重建会话**会把传感器枚举弄坏"
（`SscHub.cpp` 里 2026-08-20 那段警告），**"重建会话有害"推不出"同会话开关无害"** ——
后者从没测过，而新 HAL 的亮屏 / 灭屏、游戏切前后台全靠它。在命令行上先单独证实，
出了问题也好定位（不牵扯 AIDL / SensorService）。

**判据**（三条都要）：
1. **≥ 20 轮，每一轮都有读数**（退出码 0；50 Hz 下每轮应有几十条 ——
   SSC 约 5 Hz 成批投递，见 [`docs/stage4-findings.md`](../../../../docs/stage4-findings.md) #119 §4）。
2. **静止平放时 accel 每轮首条 Z ≈ 9.8 m/s²**（gyro 各轴 ≈ 0）—— 不只是"有消息"。
3. **SSC 枚举不坏**：结束时工具自己查的那一次通过，**另外**再单独跑一次
   `gaokun3-ssc-test accel 10 5`（新会话）确认能读，这才说明没把 SSC 留在坏状态。

"停用后残留"不是判据，只是数据：500 ms 之后才到的残留在 HAL 里会留在 socket，
下次使能时被当成一条新样本写进缓存（`SscHub.cpp` 只核对 UID）。若总是很多，再考虑
HAL 侧按时间戳丢弃。

**建议两种条件都跑一次**（⬜ 未上机）：
* **先停 sensors HAL 再跑**（`stop vendor.sensors-gaokun3`，服务名见
  [`../sensors-hal/sensors-gaokun3.rc`](../sensors-hal/sensors-gaokun3.rc)）——
  与 B9 当时的测法相同（#119 §4 "停掉 sensors HAL，用 gaokun3-ssc-test 自己读"），
  SSC 上只有这一个客户端，结果最干净。跑完 `start vendor.sensors-gaokun3`。
* **HAL 照常在跑**（亮屏、自动旋转开着，即 HAL 也在同一颗 accel 上开着流）——
  这是装上新 HAL 后的真实处境：一个客户端停用会不会影响另一个客户端的流、
  残留怎么算，都没实测过。⚠️ 这种条件下若出问题，HAL 那一路也可能跟着坏，
  要按下面的办法恢复。

**失败时的恢复**（B21 / [#37](../../../../docs/stage4-findings.md)）：SSC 坏了不会自己好，
要重启 hexagonrpcd，再等约 20 秒沉降：

```sh
stop vendor.hexagonrpcd-sdsp; start vendor.hexagonrpcd-sdsp   # 服务名出自 scripts/ssc/README.md 的"收工"一节
# SLPI 自己若不在 running（/sys/class/remoteproc/remoteproc0/state），先按那一节把它拉起来
sleep 20; gaokun3-ssc-test accel 10 5                          # 先确认命令行能读
```

⚠️ B21：SLPI 崩溃自愈后 SEE 要 hexagonrpcd **再重启一次**才注册传感器
（[`docs/TODO.md`](../../../../docs/TODO.md) B21）—— 第一次重启后仍找不到 accel 时，再重启一次。
HAL 那一路要等它的看门狗重建会话（最长约 60 秒）或 `stop`/`start vendor.sensors-gaokun3`，
最后用 `dumpsys sensorservice` 确认框架层也回来了。

## 构建上的两个坑（都踩过）

1. `proto: { canonical_path_from_root: false }` **必须加**，否则生成的头文件是
   `device/huawei/gaokun3/ssc/xxx.pb.h`，而 `.proto` 之间的
   `import "ssc-common.proto"` 也解析不了。
2. protobuf **静态链接**，不用 `shared_libs`：`libprotobuf-cpp-lite.so`
   只在 `/system/lib64`（而且文件名带版本号
   `libprotobuf-cpp-lite-4.25.8.so`），vendor 二进制走 vendor 链接命名空间
   看不见它 —— 和 CLAUDE.md 里 `tinymix`/`libtinyalsa` 是同一个坑。
   ★ 静态 protobuf 引用 `__android_log_write`，所以还要补 `shared_libs: ["liblog"]`，
   否则链接期 `undefined symbol`。

## 还差什么

⬜ **AIDL `android.hardware.sensors` HAL** —— 把 `libgaokun3ssc` 包起来喂
SensorService，自动旋转才会真的生效。要处理的额外问题：
* **安装矩阵全零**（出厂校准随 Windows 永久丢失）→ 轴向可能要在 HAL 里硬编纠正，
  得实机对着屏幕方向标定一次。
* 采样率/batching/flush 的语义映射。
* sepolicy（当前 SELinux permissive，转 enforcing 前必须补）。

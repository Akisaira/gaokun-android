# gaokun3 扬声器增强（试验功能，Histen 后处理链）

给 Huawei MateBook E Go（gaokun3 / SC8280XP）的**内置扬声器**加一条后处理链：

```
Histen 引擎（含它自己的 EQ / 低音增强）→ LR4 高通 → makeup 增益 → 限幅器 → 软削波
```

纯软件处理，不碰 DAC / 功放寄存器，也不需要内核补丁。作者（PR #7，mashen11）的动机是
「本机 Android 放音明显比 Windows 小且闷」：Windows 侧有华为 Histen 这套扬声器后处理，
Android 上一直没有对应物。

> ★ **试验功能，默认关。** 开关在「设置 → 声音 → 扬声器增强（实验性）」
> （Parts 应用，写 `persist.sys.gaokun3.histen`）。关着的时候 effect 只是 music 流上
> 一个逐比特直通的槽位，不加载任何库。打开后**只处理内置扬声器**，耳机 / 蓝牙 / USB 一律直通。
>
> ⚠️ **Histen 引擎（`libhw_histen_processing.so`）是华为专有二进制，不在版本库里**，
> 放在 `prebuilt/`（整目录忽略），见 [`prebuilt/README.md`](prebuilt/README.md)。
> 没有它也能编、也能用 —— 只是只剩自研的扬声器链。

---

## 一、目录内容

| 文件 | 性质 | 说明 |
|---|---|---|
| `gaokun_effect.cpp` | 自研 | AIDL effect 主体。继承 `EffectImpl`；开关 / 设备 / 格式的判定也在这里 |
| `histen_chain.h` | 自研 | 与 Histen 引擎的适配层：dlopen/dlsym、参数下发、重分块、出错退回直通 |
| `speaker_chain.h` | 自研 | 扬声器链：LR4 高通、makeup、限幅器、软削波（**没有 EQ**，EQ 在 Histen 里） |
| `histen_scenes.h` | 生成 | 15 个 `SWS_SPK_*` 场景的参数表，由 `gen_histen_scenes.py` 从华为的 `sws_config.xml` 生成 |
| `gen_histen_scenes.py` | 自研 | 上述生成器（换固件版本时重跑） |
| `audio_effects_config.xml` | 配置 | effects HAL 读取的**唯一**配置 = crDroid 16.0 原版 + 我们的 `gaokun_histen` 条目 |
| `prebuilt/` | **不入库** | Histen 引擎放这里；只有 README 受版本控制 |

---

## 二、为什么是三件套

AOSP 的音频 effect 架构决定了「一个音效」要落在三个地方，缺一不可：

```
App / AudioPolicy
      │  按 audio_effects_config.xml 的 <postprocess> 找到 impl UUID
      ▼
effects HAL（APEX com.android.hardware.audio 里的服务，域 hal_audio_default）
      │ dlopen
      ▼
/vendor/lib64/soundfx/libgaokunhisteneffect.so   ← 自研 effect
      │ 开关打开、需要引擎时 dlopen
      ▼
/vendor/lib64/soundfx/libhw_histen_processing.so ← 专有引擎（可缺）
```

* **自研 effect 承担协议**：AIDL effect 接口、FMQ 环形缓冲、`EffectImpl` 生命周期。
  必须继承 `EffectImpl` 且只实现那几个纯虚函数 —— 自己建 FMQ 或线程会被
  `open()` 里的 `dupeFmq()` 覆盖，表现为「库被加载但永远拿不到数据」。
* **专有引擎承担算法**：Histen 的 255 值 p3 参数块（EQ / DRC / LMB 等）只由它解释。
* **配置承担注册**：`audio_effects_config.xml` 里 `<libraries>` 声明库，
  `<effects>` 声明 effect 的 **impl UUID 与 type UUID**，`<postprocess>` 把它挂到 music 流。

> ⚠️ 两条作者踩过的坑，改配置前务必读：
> * **不要**把原厂某个 `<library path=...>` 改成我们的库。HAL 的
>   `Factory::queryEffects()` 按 library descriptor 枚举，改 path 会让原厂
>   LoudnessEnhancer 的 descriptor 从枚举结果里消失，而 LineageOS 的 AudioFX
>   每次播放都要按 type UUID 创建它；`AudioPolicyService::startOutput()` 里
>   `addOutputSessionEffects()` 遇到失败会**整体中断**，结果是我们的 effect
>   永远拿不到 `setEnabled(true)`。**必须新增独立槽位。**
> * AIDL effect HAL 机型上，`AudioPolicyEffects` **不再**自己解析
>   `audio_effects.xml`，而是问 HAL 要 `getProcessings()`，其来源是 HAL 自己的
>   `audio_effects_config.xml`。所以 postprocess 必须写进**这个**文件。
>
> ⚠️ 第三条（维护者）：`<postprocess>` 是**按流**挂的，不按设备。本机扬声器、有线耳机、
> 耳麦都从同一个 `primary output` 出声（`audio/primary_audio_policy_configuration.xml`
> 的 routes），所以"只处理扬声器"必须由 effect 自己判断 —— 见第四节。

---

## 三、构建集成

`device.mk`：

```make
# 用我们的配置取代原版（soong config 只门控那一个 prebuilt_etc）
$(call soong_config_set_bool,hardware_interfaces_audio,use_default_audio_effects_config,false)
PRODUCT_COPY_FILES += $(LOCAL_PATH)/effects/audio_effects_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_effects_config.xml

PRODUCT_PACKAGES += libgaokunhisteneffect          # Soong 编出的 effect 库

# 引擎：有就装，没有照样能编
GAOKUN3_HISTEN_ENGINE := $(LOCAL_PATH)/effects/prebuilt/lib64/soundfx/libhw_histen_processing.so
ifneq ($(wildcard $(GAOKUN3_HISTEN_ENGINE)),)
PRODUCT_COPY_FILES += $(GAOKUN3_HISTEN_ENGINE):$(TARGET_COPY_OUT_VENDOR)/lib64/soundfx/libhw_histen_processing.so
endif
```

我们自己的构建一定要带上引擎：`scripts/sync-device-tree.sh` 把 `prebuilt/` 同步到构建机，
并按 sha256 断言它在（缺了构建也会通过，只是 ROM 里悄悄没了 Histen —— 所以要断言）。

`Android.bp` 的关键三点：

* `defaults: ["aidlaudioeffectservice_defaults"]` —— 这个 default 已带齐
  FMQ / libutils / libcutils / libbinder_ndk 与 AIDL effect 的 NDK 绑定。
  **不要改用 NDK 直接编**：NDK 根本不提供 `libfmq`。
* `srcs` 里的 `":effectCommonFile"` **不是可选项** —— 它是
  `hardware/interfaces/audio/aidl/default/` 下持有 `EffectContext.cpp` /
  `EffectThread.cpp` / `EffectImpl.cpp` 的 filegroup，也就是整个 effect 框架。
  AOSP 里每个 effect 库都各自编一份；`destroyEffect` 这个导出符号**只可能**
  来自 `EffectImpl.cpp`（这也是校验产物时最可靠的标志）。
* `relative_install_path: "soundfx"` + `installable: true` ⇒ 落到 `/vendor/lib64/soundfx/`，
  即 effects HAL 在 APEX 之外查找库的目录之一（`EffectConfig.h` 的 `kEffectLibPath`）。

SELinux：`sepolicy/hal_audio_default.te` 给音频 HAL 两条读属性的规则（开关 + 旋钮）。

---

## 四、什么时候真的处理

每个 music 流上都有这个 effect 的实例，但只有**同时满足**下面四条时才处理，其余一律逐比特直通：

| 条件 | 来源 | 变了以后 |
|---|---|---|
| 总开关 `persist.sys.gaokun3.histen` = `1` | Parts 开关；没设过 = 关 | **关**：约 1 秒内生效。**开**：从下一次开始播放起生效（这一路流之前开过的话立刻恢复） |
| 这一路流已经"装好"（armed） | 开流时或 START 时开关是开的 | 装链会 dlopen 引擎，不能在音频线程上做，所以只在开流 / START 时做 |
| 输出是**内置扬声器** | 框架推来的设备（descriptor 设了 `deviceIndication`） | 插拔耳机、连蓝牙立刻切换。蓝牙音箱也是 `OUT_SPEAKER` 但带 `bt-a2dp` 连接，不算 |
| 立体声 | 开流时的格式 | 另外 Histen 只在 48 kHz 下进链；别的采样率只跑扬声器链 |

从直通切回处理时，滤波器 / 限幅器状态和 Histen 的 10 ms 缓冲会清空重来，不回放旧音频。

⚠️ **低延迟（FAST）轨可能绕过这条链**：有 FastMixer 的输出上，框架不许在带 FAST 轨的会话上挂
软件 effect（`Threads.cpp` 的 `checkEffectCompatibility_l`）。走低延迟通路的游戏可能根本不经过这里。
⬜ 本机主输出有没有 FastMixer 还没查（`dumpsys media.audio_flinger`）。

---

## 五、调参旋钮（root）

总开关之外，全部是 `persist.vendor.gaokun3.histen.*`（`vendor_gaokun3_prop`，要 root 才能设：
`adb shell su -c 'setprop …'`）。只在开关打开时有意义。

| 属性 | 取值 | 作用 | 何时生效 |
|---|---|---|---|
| `…engine` | `0` / `1`（默认 1） | `0` = 不让 Histen 进链、**只跑扬声器链**（A/B 对照用；不是逐比特直通，直通请关总开关） | 下一次播放 |
| `…scene` | `0`–`14` | 选 `SWS_SPK_*` 场景（索引同 `histen_scenes.h` 顺序） | 下一次播放 |
| `…eq.N` | `N`=0–10，值 −128…255 | **绝对覆盖**场景表的第 N 个 EQ 槽（Histen 里的）。⚠️ 空 = 回落场景基线，所以**切场景前先清空 `eq.*`** | 约 1 秒 |
| `…ben.{on,thr,gain,freq,a,b}` | 原样透传 | Histen 低音增强（BEN）分字段覆盖，便于逐项扫描 | 约 1 秒 |
| `…vol.{ana,dig}` | 原样透传 | Histen 的模拟/数字音量字段 | 约 1 秒 |
| `…hpf` | Hz（默认 150，`0` = 关） | LR4 高通拐点 | 约 1 秒 |
| `…makeup` | dB（默认 +4） | 链内补偿增益 | 约 1 秒 |
| `…limit` | `0` / `1`（默认 1） | 限幅器开/关（**不是**阈值） | 约 1 秒 |
| `…ceiling` | dBFS（默认 −1） | 限幅器天花板 | 约 1 秒 |
| `…release` | ms（默认 120） | 限幅器释放时间 | 约 1 秒 |

清空某个覆盖：`setprop persist.vendor.gaokun3.histen.eq.3 ""`

> ★ **整体增益要走功放（PA），不要走 `makeup`**：PA 在 DAC 之后、是纯线性的，
> 不消耗限幅器余量；`makeup` 走链内会直接顶限幅器，听感上是「不干净」。

> 旧名字 `persist.gaokun3.histen.*`（PR 原版）已**全部作废**：那是 `default_prop`，
> vendor 进程在 enforcing 下永远读不到。设备上残留的旧值无害，但也不再起作用。

---

## 六、验证

日志 tag 是 **`gaokun_effect`**：

```bash
adb shell su -c 'logcat -d -s gaokun_effect' | tail -40
```

| 判据 | 含义 |
|---|---|
| `bypass: master switch off` / `…not the built-in speaker` / … | 每次状态变化一行，说明为什么没处理 |
| `processing: built-in speaker, Histen + speaker chain` | 开始处理 |
| 逐行 `meter: in=… out=… dBFS` | ★ **最硬**。出现 = 音频真的流过处理链（直通时不打，免得刷屏） |
| `open: Histen chain up: scene=N of 15, block=480 frames` | 引擎链已建立 |
| `open: speaker chain up: sr=… hpf=…` | 扬声器链已就位 |
| `Histen engine loaded from <path>` | 引擎从哪个路径 dlopen 成功 |
| `output device: … -> built-in speaker` | 框架推来的设备与判定结果 |

* 开关打开、外放、却**没有 `meter:` 行** ⇒ 先看有没有 `processing:`；连 `open:` 都没有 = effect
  没被加载，查注册与配置，别急着调参数。
* `Histen unavailable -- speaker chain only` ⇒ 引擎库没到位，**不会哑**，只是没有 Histen。

---

## 七、失败时的退路

一条音效链最坏的失败形态不是"没效果"，而是**把扬声器搞哑或搞爆**。所以：

* 总开关关着 ⇒ 不加载任何库、不碰缓冲区（这也是默认状态）。
* 引擎的 dlopen / dlsym / `GetSize` / `Init` / `SetParams` 任一环节出错 ⇒ Histen 不进链，只跑扬声器链。
* `Apply` **连续** 64 次失败 ⇒ Histen 退出，这一路流剩下的时间只跑扬声器链。

引擎路径是绝对路径列表（`/vendor/lib64/soundfx/` 优先，`/system/lib64/soundfx/` 是作者 KSU 部署方式的兼容位）：
`dlopen()` 只在名字**不含 `/`** 时才走链接器搜索路径。

---

## 八、来源与许可

* **自研部分**（`gaokun_effect.cpp`、`histen_chain.h`、`speaker_chain.h`、`gen_histen_scenes.py`）
  为 PR #7 作者独立实现，维护者 2026-09-26 改成试验功能（默认关、只处理扬声器、属性改名）。
* **Histen 引擎**：华为专有二进制，取自麒麟 V10 SP1，且被打过二进制补丁，**未获再分发授权**，
  不入库。详见 [`prebuilt/README.md`](prebuilt/README.md)。
* **`histen_scenes.h`**：从华为音频栈的调音配置 `sws_config.xml` 机械导出的纯数值表。
  ⚠️ 它来自华为的配置文件，"完全不含专有内容"要打个折扣 —— 只是数值参数，随仓库分发以便构建。

  > ⚠️ **关于它与 `sws_config.xml` 的可复现性**（作者原文）—— 两者**不是**逐字节对应的，
  > 原因是开发期那份 `sws_config.xml` 已被改动：场景 `SWS_SPK_LANDSCAPE_ONE` 的
  > p3 索引 **96–111** 被覆盖成了 `SWS_SPK_LANDSCAPE_TWO` 的同段值
  > （那是为证明"场景参数确实参与运算"做的 A/B 判别实验，做法正是把 ONE 改成 TWO）。
  > 证据：本目录这份表 ONE ≠ TWO（`0x1f 0x3e 0x7d …` vs `0x41 0x78 0x230 …`），
  > 而从那份配置重生成会得到 ONE == TWO。
  >
  > 用本目录的生成器从三份现存副本（md5 均为 `c354020b01db…`）重跑，与提交的这份
  > 逐行比对**只有两处不同**：① 文件头注释（本表出自更早的生成器版本）；
  > ② 数值上**唯一**的差异就是 ONE 的 p3 索引 96–111（两行）。
  >
  > ⇒ **本目录提交的是未经改动的原始值**（ONE = `0x1f…`）。用生成器重跑时请用
  > **未改动过的** `sws_config.xml`，否则 ONE 会被换成 TWO 的参数 —— 而 ONE 恰好是
  > 默认场景（`kDefScene = 0`），这个错误不会报错、只会听感变样。检查办法（本表上实测输出 `13,14c13,14`）：
  >
  > ```bash
  > one() { sed -n "/spk_landscape_${1}_p3\[255\]/,/^};/p" histen_scenes.h | sed '1d;$d'; }
  > diff <(one one) <(one two)     # 必须非空；若为空 = 用了被改过的配置，别提交
  > ```

* 代码注释里引用的 `docs/meta/…`、`scripts/audio/…`、`_histen_re/…` 是作者自己的工作区，**不在本仓**。
  "与 Windows 对照测量"的原始数据也不在本仓。

---

## 九、已知限制

1. 只处理**内置扬声器上的 music 流**（媒体：音乐 / 视频 / 游戏）。铃声、通知、系统音不经过这里；
   走低延迟 FAST 通路的游戏可能也不经过（第四节）。
2. 场景 `SWS_SPK_*` 的**几何含义**（LANDSCAPE_ONE 对应哪种摆放）由原厂配置决定，
   只做了参数搬运，未逐一实听确认；也不随屏幕方向切换。
3. `eq.N` 的**符号约定**来自作者的实测扫描，不是文档：先小步扫描，别凭直觉设值。
4. 进 Histen 之前信号被量化到 16 位（高半字）并硬限在 ±1.0，出来再丢掉低 16 位 —— 外放听不出来，但不是无损的。
5. 在**本机扬声器（WSA 双单元）**上调的参数，不具备跨机型通用性。
6. ⬜ 维护者 2026-09-26 的改动**还没编译过、没上机**。要看的：整包构建通过；开关关时只有一行 `bypass`；
   开关开 + 外放有 `meter:`；插耳机立刻 `bypass: output is not the built-in speaker`；
   enforcing 下没有 `hal_audio_default` 读属性的 avc。

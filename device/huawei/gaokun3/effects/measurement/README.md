# audio-measurement — 与 Windows 的对照测量（脚本 + 数据）

> 回应 PR #7 review 的请求：把**测量脚本**与 **Windows 对照数据**单独入库（不含华为二进制、
> 不含 `sws_config.xml`），使「Windows 侧响度更高且低频更足」「整体增益差 ~12 dB」「形状差
> 在 116–145 Hz 凹 / 185 Hz 凸」这些结论**可复查、可复现**。

## 一、两个测量口径（别混用）

| 口径 | 测的是什么 | Windows 侧 | Android 侧 |
|---|---|---|---|
| **数字域** ★主力 | 输入 wav → 输出 wav 的传递函数 H(f)，不含房间、不含麦克风、不含扬声器 | `windows/loopback_rec.py`：WASAPI loopback 抓**渲染端点**（= 全部 APO 之后的数字信号）；`windows/digital_response.py`：噪声激励 + Welch 平均出 1/12 oct 曲线 | `android/eqscan.c`：设备上离线跑 Histen 引擎（不出声），对数扫频 20 Hz–20 kHz 逐 EQ 配置写 wav；`android/eqscan_report.py`：STFT 对角采样出曲线 |
| **声学域** | 扬声器 + 麦克风回采的声压，含整机 | 外录双机位（第三台机器当录音站）或内置麦回采 | `android/audio_goertzel.py`：内置麦回采 440 Hz 单音，Goertzel 取基波（测量余量 ~76 dB，含 PA 爆音掐头尾、削顶检查、n/a 诊断） |

为什么主力是数字域：两侧都不含房间/麦克风/扬声器，差值就是**处理链**的差，可以直接相减；
声学域用来拿绝对响度差并互证（见 §四）。

## 二、目录

```
measurement/
├── windows/loopback_rec.py        # WASAPI loopback 采集（soundcard 库，48k/2ch）
├── windows/digital_response.py    # 噪声 + Welch -> 1/12 oct 传递函数（--csv）
├── android/eqscan.c               # 设备端离线扫引擎（逐 EQ 配置写 wav）
├── android/eqscan_report.py       # eqscan 输出 -> 槽/频段/增益斜率表 + 曲线 CSV
├── android/audio_goertzel.py      # 声学域单点 A/B（含 --make-tone / --selftest）
├── android/analyze-noise-response.py  # 噪声宽带频段表（声学/离线两用）
├── analysis/win_vs_android.py     # 两侧曲线同口径比较 + 带守护的 EQ 求解器
└── data/                          # 2026-09-24 实测数据（scene 3 = SWS_SPK_LANDSCAPE_TWO）
    ├── win-digital-response.csv   # Windows APO 链数字域曲线（loopback_rec+digital_response 产出）
    ├── eqscan-curves.csv          # Android Histen 数字域：基线 + 每槽 0/64/128/192 的差值曲线
    ├── base_eq.txt                # eqscan 落盘的基线槽值 + 实测频带中心
    └── win-freq-response.csv      # Windows 扬声器端声学频响（92 个 1/12 oct 点）
```

## 三、复现

**Windows 侧（数字域）**

```powershell
pip install soundcard numpy
# 1) 生成平谱噪声激励（任意白噪/平噪 wav，48k），播放并由 loopback 抓取：
python windows/loopback_rec.py noise-flat.wav lb-noise-win.wav 20 3
# 2) 出曲线：
python windows/digital_response.py noise-flat.wav lb-noise-win.wav --csv win-digital-response.csv
```

**Android 侧（数字域）**

```sh
# eqscan.c 在设备上编（NDK/clang），include 路径指到 effects/ 目录：
#   cc -O2 eqscan.c -I.. -o /data/local/tmp/eqscan -ldl
/data/local/tmp/eqscan /data/local/tmp/eqscan 3     # 场景 3
adb pull /data/local/tmp/eqscan ./eqscan-out
python android/eqscan_report.py eqscan-out           # -> eqscan_curves.csv
```

**比较与求解**

```sh
python analysis/win_vs_android.py --win data/win-digital-response.csv \
    --and data/eqscan-curves.csv --base data/base_eq.txt --hpf 90
```

依赖：Python3 + numpy（求解器另需 scipy）；Windows 采集另需 `soundcard`。

## 四、这批数据说明了什么（PR #7 正文中数字的出处）

1. **整体增益差 ≈ +12 dB（数字域实测 +12.27 dB @1 kHz）**；声学外录双机位独立测得 +11.6 dB
   —— 两个口径互证，排除了"硬件增益不同"的解释，指向 Windows 音效链在 Android 侧缺失。
2. **形状差**：Windows 是多频段雕刻（116–145 Hz 有意挖凹、185 Hz 有峰、590/3300 Hz 窄谷），
   Histen 场景表低频是 110–230 Hz 的 +13~15 dB 平台 ⇒ 单调的 LR4 高通做不出"凹+峰"形状，
   只能压低拐点（90 Hz）+ EQ 槽 1 砍多余低频。
3. **EQ 槽语义**（eqscan 标定，R²≥0.999）：槽 1..8 有效（中心 120/220/560/1100/2200/3700/
   4600/14000 Hz），槽 0/9/10 改不动；值按无符号读，1 单位 ≈ 0.0801 dB，≥204 被 Init 拒（-145）。
4. **定稿参数**：`hpf 90` + preset `1=70 2=0 3=96 4=0 5=0 6=92 7=96 8=23`
   （90/113/143 Hz 残差 ±0.8 dB，求解代价 820.1 → 64.7）。
   整体增益走 PA（DAC 之后纯线性），不走链内 makeup（会消耗限幅器余量，实测预算 6.74 dB）。

## 五、口径警告（照抄会错的那几条）

- **SpeakerChain 不在 eqscan 曲线里**：eqscan 只测 Histen 引擎；实际输出是
  SpeakerChain(Histen(...))，LR4 高通挂在 Histen 之后。`win_vs_android.py --hpf` 就是为此存在，
  比较时必须把 HPF 算进 Android 侧。
- **eqscan 扫频幅度 0.10（-20 dBFS）**：引擎有正向增益，0.5 会顶满量程把基波压扁，
  同时避开限幅/DRC 非线性区；结束时打印钳位样本数，非 0 则数据不可信。
- **样本格式 int32 高半字**（Android 引擎）：喂纯 int16 会让样本流减半、输出白噪声。
- `audio_goertzel.py` 的设备端 runner（`audio-loudness-sweep.sh`）与本机 mixer 状态强相关，
  未收录；它只是单点声学 A/B，复现请直接用数字域链路。
- `analysis/win_vs_android.py` 尾部打印的下发命令引用的是我们工作区的临时脚本路径
  （`tools/_tmp/histen-ab.sh`），仅作示例，不在本目录。
- 声学域数据是**这台机器**的 WSA 双单元 + 内置麦，不具备跨机型通用性。

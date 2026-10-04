# 性能 / 待机 / 长稳采样（PERF-2、B7 / PERF-3 / PERF-4）

全部**只读**：不 setprop、不改刷新率、不开关服务、不 `--latency-clear` / `timestats -clear`。
唯一的写入是待机采样器往设备上自己的目录 `/data/local/tmp/gk3-standby/` 追加日志。
什么时候跑、判据是什么，见 [`docs/release-checklist.md`](../../docs/release-checklist.md) 的 C 档。

| 脚本 | 在哪跑 | 干什么 |
|---|---|---|
| `game-perf.sh` | 宿主机（adb） | 游戏前台时每秒抓 SurfaceFlinger 帧时间、每 5 秒一行 CSV（CPU / GPU 频率驻留、温度、温控压频、电池），结束出平均 fps、1% low、最高温 |
| `standby.sh` | 宿主机（adb） | 待机采样器的 `once` / `start` / `status` / `pull` / `stop` |
| `standby-sampler.sh` | 设备（root，常驻） | 每次唤醒（`suspend_stats/success` 变了）追加一行：时间、suspend_stats、电池、qcom_stats 各项、boot reason history；另有 30 分钟一行的心跳（关键进程 PID/RSS/fd、dropbox 计数） |

## 游戏性能（PERF-2）

```bash
# 用户解锁、进游戏的固定场景之后：
SER=gaokun3 bash scripts/perf/game-perf.sh -p com.tencent.tmgp.dfm -t 1200     # 三角洲 20 分钟
SER=gaokun3 bash scripts/perf/game-perf.sh -p com.idreamsky.klbqm -t 600        # 卡拉彼丘 10 分钟
SER=gaokun3 bash scripts/perf/game-perf.sh -p com.hypergryph.arknights -t 1800  # 明日方舟挂机 30 分钟
```

产物在 `out/perf/<包名>-<时间>/`：`header.txt`（构建戳、刷新率、帧率上限相关属性、图层的 frameRate 投票）、
`samples.csv`、`frames.txt`、`summary.txt`。包名是 2026-10-04 实机 `pm list packages -3` 里的。

* **fps**：`dumpsys SurfaceFlinger --latency <图层>` 只给最近 128 帧，120 Hz 下约 1 秒，所以每秒抓一次、按上屏时刻去重拼接。
  两次之间没有重叠 = 中间丢了帧：`frames.txt` 记 `GAP`，CSV 的 `gap` 列为 1，跨 GAP 的间隔不进帧时间统计。
  结尾另用 `--timestats -dump` 的 `totalFrames` 增量交叉核对一次整段平均。
* **1% low** = 最慢的 1% 帧的平均帧时间换算成 fps；另给 p99 帧时间与最长帧。
* **GPU** 只有频率驻留（msm 不导出忙闲）：`trans_stat` 每档最后一列 time(ms) 的增量，分母是各档增量之和。
  本机 simple_ondemand 几乎只在 270 / 690 两档之间跳，要和 fps 一起看。
* **CPU** 是 `policyN/stats/time_in_state` 的频率驻留（含 idle），不是利用率。
* 解读 fps 之前先看 `header.txt`：`ro.surface_flinger.game_default_frame_rate_override=60` 与
  `debug.graphics.game_default_frame_rate.disabled=true` 同时存在（复核 PERF-2：来源不明），游戏到底被限在 60 还是跑 120 要对照着看。

## 待机与长稳（B7 / PERF-3 / PERF-4）

```bash
SER=gaokun3 bash scripts/perf/standby.sh once     # 先看一眼采得到什么（不写设备）
SER=gaokun3 bash scripts/perf/standby.sh start    # 插着线启动；会提示 allow_suspend 的当前值
#   → 用户拔 USB、息屏（8 小时待机）/ 日常使用（72 小时狗粮）
SER=gaokun3 bash scripts/perf/standby.sh pull     # 插回后取回 + 摘要
SER=gaokun3 bash scripts/perf/standby.sh stop
```

* 采样器靠 `sleep`（CLOCK_MONOTONIC，挂起时不走）轮询 `suspend_stats/success`，**自己不会唤醒机器**；
  醒来不到 5 秒就又睡下去的短唤醒会合并进下一行（`ss_ok` 是累计值，两行之差就是中间挂起了几次）。
* 每行之后 `sync`：断电、复位、电量耗尽时日志留到最后一次醒来。采样器不跨重启存活；`pull` 会一起取回**现在的**
  `persist.sys.boot.reason.history`，对照日志最后一行分辨断电和正常关机。
* **插着 USB 时 CX 塌缩本来就进不去**（复核 PERF-3），qcom_stats 的 `cxsd` / `aosd` / `ddr` 为 0 不算异常 —— 要拔线测。
* 开发机 `persist.vendor.gaokun3.allow_suspend` 持久为 0，**不会挂起**。临时改 1 要用户决定，脚本不替你改。
* 亮屏硬解 1 小时那种测法要更密的心跳：`HB=300 SER=gaokun3 bash scripts/perf/standby.sh start`。
* 要 root（qcom_stats 在 debugfs）。adb 不是 root 的发布构建上走 `su -c`，KernelSU 管理器里要先给 shell 授权。

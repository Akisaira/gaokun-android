> ## ✅ 这份手册已经走完（2026-09-16 晚）—— 留作那一晚的操作记录
> 结果全在 [`stage4-findings.md` #116](../stage4-findings.md)。一句话版：内核 `#24` 上机，
> **固件确实做逐像素基线**、**fuzz 定案 0（写进 DT）**、**按下延迟 25→17 ms**、**触点面积轴进镜像**；
> 掌压那条的三个阈值假设全被实测否决（`peak_threshold` 抬到 1500 会把快速甩动切碎），维持 800。
> ROM v0.6.2 正在构建。下面是当时的步骤原文。

# 明早的触摸验收手册（2026-09-15）

> 一次重启换来的东西全在这里。手册按**做的顺序**写，每一步都写清「看什么算通过」。
> 背景与推导见 [`stage4-findings.md` #114](../stage4-findings.md)（幽灵触摸根因）
> 与 **#115**（这次修的六个缺陷）。

## 0. 现在是什么状态（睡前的定格）

| | |
|---|---|
| 设备上跑的 | v0.6.1，内核 **`#19`**，槽 `_b` |
| 触摸参数 | 已现场改到 `track_jump_dist2=0` / `track_smoothing=0` / `track_start_debounce=2` |
| 开机属性 | `persist.sys.gaokun3.touch_mode=daily` ⇒ **重启后落到安全值，不会退回坏配置**（代价 25 ms 平滑滞后）|
| ESP 上备好的 | `slot_b/Image-test`（内核 **`#23`**，sha `b05bcc6e…`），条目 `…-android-b-test.conf` |
| 回落 | `slot_b/Image`（`89a1d14f…`，内核 `#19`）**没动**；`default` 仍指向它 |
| 构建机 | 已 `deallocate`（核实过实际电源状态） |
| 未推送提交 | 见 `git log origin/main..HEAD` —— **推送要你点头** |

⚠️ ESP 只剩 **35 MB**，而 OTA 的 postinstall 要 56 MB。**验收完把 `Image-test`
和那个条目删掉**（最后一节有命令）。

---

## 0bis. ⚠️ 先把 ESP 上的测试内核换成 `#23`

ESP 上现在放的是 **`#22`**（sha `a99c5ad8…`）。`#23` 修掉了 `#22` 里一个自审发现的
bug：探测延迟时 debugfs 诊断接口会**静默消失**（案卷 #115 §8bis）——
而那正是这次上机最主要的工具。**别用 `#22` 启动。**

```sh
SC=<scratchpad>/k23out          # vmlinuz.efi，sha b05bcc6e84264305
adb push $SC/vmlinuz.efi /data/local/tmp/k23.efi
adb shell 'M=/mnt/gk3esp; mkdir -p $M && mount -t vfat /dev/block/by-name/esp $M
MID=$(ls $M | grep -E "^[0-9a-f]{32}$" | head -1)
cp /data/local/tmp/k23.efi $M/$MID/android/slot_b/Image-test; sync
sha256sum $M/$MID/android/slot_b/Image-test        # 期望 b05bcc6e…
sha256sum $M/$MID/android/slot_b/Image             # 期望 89a1d14f…（回落，没动）
umount $M; rmdir $M'
adb shell 'rm -f /data/local/tmp/k23.efi'
```

起来之后 `cat /proc/version | grep -o "#[0-9]*"` 应当是 **#23**。

## 1. 启动到测试内核（唯一需要你在场的一步）

```sh
bash scripts/boot-oneshot.sh --list                    # 确认条目名
bash scripts/boot-oneshot.sh <MID>-android-b-test.conf # 写 oneshot，会回读校验
adb reboot
```

⚠️ **oneshot 只作用于下一次启动**，之后自动回到 `default`（= 已知能用的 `#19`）。
万一起不来：长按电源键关机再开，就回到 `#19` 了。

起来之后先确认走的是测试内核：

```sh
adb shell 'cat /proc/version | grep -o "#[0-9]*"'      # 期望 #22
adb shell 'ls /sys/kernel/debug/himax-hx83121a/'       # 期望 frame  frame_raw
adb shell 'cat /sys/module/himax_hx83121a_spi/parameters/disable_pressure'   # 期望 N
```

三条都对了再往下。

---

## 2. 先抓一张基线快照（30 秒，别碰屏幕）

```sh
adb shell 'echo 1 > /sys/bus/spi/devices/spi0.0/algo/stats'   # 清零计数器
# —— 30 秒内不要碰屏幕 ——
bash scripts/touch/dump-state.sh baseline-idle
python3 scripts/touch/grid.py baseline-idle/frame_raw.bin
```

**看什么：**

* `baseline-idle/stats` 里 `tracks_new` **应该是 0**。不是 0 ⇒ 抓到自发幽灵了，
  去看 `contacts_log` 里它的 `x y area signal edge`。
* `frame_raw` 的图**应该几乎全空**，统计行里 `≥800 的格子` 为 **0**。
  ★ 如果有格子长期偏在几百 ⇒ **固件不做逐像素基线跟踪**，那是驱动侧那个编译期常量
  基线（`HX_BASELINE 0x7ffe`）补不回来的漂移，也就解释了温漂/充电时的幽灵。
  这是本仓一直**答不上来**的问题，这一步就是答案。

---

## 3. fuzz —— 实测已量化，这是收益最大的一项

现在 `fuzz=8`，实测代价：上报位移里 **Δ=3 与 Δ=9…15 七个档位精确为零**（算术上不可能
出现），正常使用时 **23.4% 的在屏帧位移为 0**（手指在动，轴不动）。

```sh
# 对着手指实时 A/B，不需要重启
adb shell 'echo 0 > /sys/module/himax_hx83121a_spi/parameters/fuzz'
```

慢慢拖一个图标、在地图上微调、画一条慢线 —— **和改之前比**。
再试 `1`、`2`、`4`，挑一个"既不抖又跟手"的。

量化验收（把感觉变成数字）：

```sh
EV=$(adb shell 'grep -A8 \'Name="Himax\' /proc/bus/input/devices | grep -o \'event[0-9]*\' | head -1' | tr -cd 'a-z0-9')
adb shell "nohup sh -c 'cat /dev/input/$EV > /data/local/tmp/fz.bin' >/dev/null 2>&1 &"
# —— 慢速拖动 20 秒 ——
adb shell 'kill $(pidof cat)'; adb pull /data/local/tmp/fz.bin
python3 scripts/touch/evdev-strokes.py fz.bin
```

**看什么：**「零位移帧」的比例应当明显低于 23.4%，且 Δ=3 / Δ=9…15 的空洞消失。

定下来之后**别只留模块参数** —— 把值写进 DT 的 `touchscreen-fuzz-x/y`
（标准属性，`drivers/input/touchscreen.c` 会覆盖驱动默认值），那才是永久解、也能投上游。

---

## 4. 触点面积 / 手掌误触抑制

测试内核的 cmdline 已带 `disable_pressure=0`，所以 `ABS_MT_TOUCH_MAJOR` 与
`ABS_MT_PRESSURE` 两个轴**已经建起来了**。但——

```sh
# ★ 必须先开这个，否则驱动报的是常数（TOUCH_MAJOR=1、PRESSURE=4095），
#   每个触点都成了"针尖"，比没有还糟
adb shell 'echo 1 > /sys/bus/spi/devices/spi0.0/algo/pressure_enabled'
adb shell "getevent -lp /dev/input/$EV | grep -E 'TOUCH_MAJOR|PRESSURE'"   # $EV 见上
```

然后**把手掌压在屏幕上**，看：

```sh
bash scripts/touch/dump-state.sh palm-test
cat palm-test/stats | grep palm_
```

**看什么：**
* `palm_area` / `palm_signal` / `palm_aspect` 有没有在动 ⇒ 掌压规则到底会不会开火。
* `palm_density` **应该恒为 0** —— 这不是 bug，是在实机上证明规则 3 是死代码
  （连通域每格都 ≥ `macro_threshold=800`，而 `palm_density_low=400` < 800 ⇒ 永远为假）。
* **关键一问**：手掌压着的同时用另一根手指点屏幕，点得到吗？
  点不到 ⇒ 就是 #115 第 2 条（手掌把手指一起吞了）。当场验修法：

  ```sh
  A=/sys/bus/spi/devices/spi0.0/algo
  adb shell "echo 1 > $A/palm_zone_scan"        # 掌压 zone 里也找峰值
  adb shell "echo 25 > $A/palm_contact_area"    # 逐触点再判一次（ct->area ≥ 25 算掌）
  ```
  再试一次。好了就把这两个值定下来；`palm_contact_area` 要扫一遍（15 / 20 / 25 / 30）。

有了真实的 `TOUCH_MAJOR` 数值之后，才谈得上写 Android 的 IDC 文件
（`touch.size.calibration` 的取值**必须先量**）。

---

## 5. 幽灵触摸 —— 如果还能复现

**接上墙充**（不是电脑 USB —— 共模噪声差很多），清零计数器，正常用一会儿：

```sh
adb shell 'echo 1 > /sys/bus/spi/devices/spi0.0/algo/stats'
# —— 正常使用，直到看见幽灵 ——
bash scripts/touch/dump-state.sh ghost
```

### 已有的一条具体线索（睡前 30 分钟长录，带修复正常使用）

56 条轨迹里有 **10 个单帧触点**（人的点按通常 6–18 帧）。其中 8 个在屏幕中间，
**2 个在左边缘**（`x=5` 和 `x=26`，即距边 0.5 mm 和 2.7 mm，两条相邻 ID = 时间上挨着）。

⚠️ **这两条还分不出来**：既可能是 #115 说的边缘单像素路径（`edge_boost` 把边缘格
×1.5、四角 ×2.25，加上边缘单像素豁免），**也可能只是你从边缘往里划的返回手势的起点**。
`contacts_log` 里的 `area` 和 `edge` 两列正好能分开这两种解释 —— 真手指 `area` 通常 ≥4，
噪点是 1~2。这是明早第一个该看的地方。

**看什么（按顺序问）：**

1. `stats` 里 `tracks_new_edge` 占 `tracks_new` 的比例高不高？
   高 ⇒ 幽灵走的是**边缘**那条路：边缘单像素豁免 + `edge_boost` 边缘 ×1.5、四角 ×2.25。
   当场验：`echo 2 > $A/edge_min_area`（要求边缘触点至少有一个过阈邻居）、
   `echo 0 > $A/edge_boost_pct`。
2. `zones_overflow` / `zones_evicted` 非 0？⇒ 连通域表被噪声占满过（#115 第 1 条），
   `#22` 已经不会再丢掉半块屏幕，但这说明噪声确实很大。
3. `contacts_log` 里那几行的 `area` 和 `signal`：真手指的 area 通常 ≥4；
   area=1~2 的就是噪点。当场验：`echo 128 > $A/iso_nbr_ratio_q8`
   （要求八邻域至少担一半峰值 —— 默认 8 那个值实际从没生效过）。
4. `frame_raw` 与 `frame` 并排看：
   ```sh
   python3 scripts/touch/grid.py ghost/frame_raw.bin ghost/frame.bin
   ```
   raw 干净而 out 脏 ⇒ 是 CMF/边缘增强/IIR 引入的；两张都脏 ⇒ 信号问题。

---

## 6. 回归确认（别只看新东西好不好）

```sh
adb push scripts/touch/capture-ab.sh /data/local/tmp/ && adb shell chmod 755 /data/local/tmp/capture-ab.sh
adb shell 'nohup /data/local/tmp/capture-ab.sh >/dev/null 2>&1 &'
# —— 快速甩着滚列表，收够会自动切换、自动结束 ——
adb pull /data/local/tmp/ts_A.bin . && adb pull /data/local/tmp/ts_B.bin .
python3 scripts/touch/evdev-strokes.py ts_A.bin ts_B.bin
```

**看什么：**「相邻轨迹间隔 <100 ms」应为 **0**，且没有"间隔 <100 ms 时跨间隔的隐含
速度 > 0.3 m/s"那条 ⚠️。这是 #114 那个根因的回归判据。

---

## 7. 收尾（**别忘**）

```sh
# ESP 只剩 35 MB，OTA 的 postinstall 要 56 MB
adb shell 'M=/mnt/gk3esp; mkdir -p $M && mount -t vfat /dev/block/by-name/esp $M
MID=$(ls $M | grep -E "^[0-9a-f]{32}$" | head -1)
rm -f $M/$MID/android/slot_b/Image-test $M/loader/entries/$MID-android-b-test.conf
sync; df -h $M | tail -1; umount $M; rmdir $M'
```

定下来的值要落进仓库，否则**重启就没了**（`/vendor` 是只读的，设备上的
`gaokun3-touch-mode.sh` 还是旧的）：

* fuzz → DT 的 `touchscreen-fuzz-x/y`（新补丁）
* 掌压/边缘的旋钮 → `device/huawei/gaokun3/bin/gaokun3-touch-mode.sh`
* 然后需要**一次完整构建**才能进镜像。

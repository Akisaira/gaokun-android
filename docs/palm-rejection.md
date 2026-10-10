# 触摸屏的手掌识别

跟踪：issue [#29](https://github.com/vahiru/gaokun-android/issues/29)。

## 功能

手搭在屏幕上时，比如写字、画画时手掌和手侧压着屏幕、整只手平放、指节碰到屏幕，驱动不再把手的各个部分报成手指。
已经报出去、事后才认出是手的触点，会以`MT_TOOL_PALM`撤回，Android随后向应用发`ACTION_CANCEL`，应用不会把它当成一次点击。

判断只用电容网格，不依赖手写笔。屏上没有手掌时这些规则都不生效，纯手指操作的结果与原来逐帧相同。

## 原理

触点是驱动在主机侧从40×60的电容网格算出来的（`hx-algo.c`）。流水线里和手有关的几步，按执行顺序：

1. `hx_detect_macro_zones()`：信号超过`macro_threshold`、8邻接相连的格子组成一个连通域。
2. `hx_reject_palms()`：原有的掌压规则。面积、信号总和、长宽比任一项超标，这个连通域就算手掌，不从里面出触点。
   这些规则逐帧、逐块判断，只认得出掌根。
3. `hx_hand_update()`（新增）：维护“手的位置图”`hand_age[]`，每一格记着它上次属于手是几帧以前。手掌连通域往外扩
   `hand_margin`格写进图里；手离开以后，这些格子在`hand_hold_frames`帧内仍算作手。
4. `hx_detect_peaks()`：找峰值，也就是触点的候选。
5. `hx_hand_filter()`（新增）：落在图里的峰值在展开成触点之前就丢掉，它所在的连通域也写进图；已经在跟踪、
   后来才落进图里的触点标记为手。
6. `hx_expand_and_resolve()`、`hx_track_contacts()`：展开成触点并跟踪。标记为手的跟踪先以`MT_TOOL_PALM`报一帧，
   下一帧释放。

## 设计要点

- **碎块跟着手走**。手的其余部分（弯着的手指、指节、平放的手指）在网格上是一块块和指尖差不多大的孤岛，单看一块
  分不出来。丢掉一个峰值时把它所在的连通域也写进图，属于手的碎块就会一直被认出来，直到手抬起。手的碎块也不再
  占用10个触点槽位。
- **一起落下**。屏上一段时间（超过`hand_hold_frames`帧）没有手掌、然后出现手掌，算作一次“落下”。落下前后
  `hand_land_frames`帧内，`hand_land_dist`格以内的峰值、连通域和刚出生的跟踪都算同一只手：整只手平放时，手指
  往往比掌根早落下几十毫秒。
- **按着的手指不受影响**。已经按下超过`hand_land_frames`帧的跟踪，只有它所在的格子此刻就属于手（`hand_age`为0）
  才会撤回；它周围±2格内的峰值，只要那一格此刻不属于手，即使还在位置图的记忆里也保留，落下时它所在的连通域也不会
  被算进手里。所以按着手指时放下手掌、手指拖过手掌刚离开的地方，都不会被打断。
- **事后撤回，而不是推迟上报**。等确认不是手再上报，每一次按下都要变慢。现在照常上报，认出是手再撤回。
  Android的InputReader收到`MT_TOOL_PALM`后取消这个指针：只有一个指针时应用收到`ACTION_CANCEL`，有多个指针时收到
  带`FLAG_CANCELED`的`ACTION_POINTER_UP`。驱动为此注册了`ABS_MT_TOOL_TYPE`轴，没有这根轴，输入核心会丢掉这个事件。
- **峰值多于10个时展开最强的10个**（`patches/0081`）。`hx_detect_peaks()`把峰值按信号从弱到强排序，原来的
  `hx_expand_and_resolve()`只展开前10个，峰值一多，丢掉的正是最强的那几个。整只手压在屏上时峰值经常超过10个，
  现在改为跳过最弱的。峰值不超过10个时结果不变。
- **清空**。熄屏和芯片重新初始化时，位置图随跟踪器一起清空（`hx_hand_reset()`）。

## 组成

| 部分 | 位置 | 说明 |
|---|---|---|
| 峰值截断 | `patches/0081` | `hx_expand_and_resolve()` |
| 手的位置图 | `patches/0082` | `hx-algo.c`：`hx_hand_update()`、`hx_hand_filter()`、`hx_hand_reset()`；连通域带上每帧的编号（`zone_of[]`记录每格属于哪一块），峰值带上所在连通域的编号 |
| 上报与参数 | `patches/0082` | `himax-spi-core.c`：注册`ABS_MT_TOOL_TYPE`，按跟踪的状态报`MT_TOOL_PALM`；`algo/hand_*`参数与`algo/stats`里的计数器 |
| 录制与回放 | `scripts/touch/` | `gk3trec.c`、`hxsim/`、`simcmp.py`、`outcomes.py`，用法见[`scripts/touch/README.md`](../scripts/touch/README.md) |

## 参数与计数器

参数都在`/sys/bus/spi/devices/spi0.0/algo/`下，可以运行时修改，超出上限的写入会被拒绝（`-EINVAL`）。时间按120 Hz的
帧率换算，一格约4.4毫米。`gaokun3-touch-mode.sh`的game预设把`hand_enabled`写成0，daily预设写成1，其余几项两个预设都不动。

| 参数 | 默认 | 上限 | 含义 |
|---|---|---|---|
| `hand_enabled` | 1 | — | 总开关，写0关闭 |
| `hand_margin` | 2 | 8 | 手掌和手的碎块往外扩的格数（约9毫米） |
| `hand_hold_frames` | 36 | 120 | 手离开后继续记住的帧数（约300毫秒） |
| `hand_land_frames` | 12 | 60 | “落下”前后的窗口（约100毫秒） |
| `hand_land_dist` | 25 | 60 | 落下时算作同一只手的范围（约11厘米） |

上限定义在`hx-algo.h`。`hand_age`到255表示“不是手”，保留时间要远小于它，否则整块屏都会被当成手；落下窗口要和同样
封顶在255的跟踪年龄比较，道理相同；外扩每一遍要为每格扫描`2×hand_margin+1`格，太大会拖慢中断线程。

`algo/stats`里新增的计数器：`hand_lands`（落下次数）、`hand_peaks`（作为手丢掉的峰值）、`hand_cancel_map`（落进
位置图而撤回的跟踪）、`hand_cancel_land`（和手掌一起落下而撤回的跟踪）。

## 已知限制

- **没有掌根的手认不出来**。手很轻地搭着、没有一块连通域达到掌压规则时，位置图不会建立，手的碎块仍按手指上报。
- **远处的弱小碎块**。手掌放稳之后，在它`hand_margin`格以外才冒出来的又小又弱的碎块，可能短暂地报成手指。
- **另一只手恰好同时按下**。手掌落下前后约100毫秒内、约11厘米以内按下的手指，会被当成同一只手撤回。
- **掌压规则认成手掌的其他接触**。比如贴着屏幕边缘平放的拇指：现有规则本来就不从里面出触点，位置图还会把它周围
  约9毫米、抬起后约300毫秒内的触摸一起丢掉。所以game预设关掉了手掌识别。
- **撤回前应用已经收到了按下**。被撤回的触点先以`ACTION_DOWN`到达应用，应用要正确处理`ACTION_CANCEL`才不会留下痕迹。
- **CSOT屏**：参数只在BOE屏上调过。规则只看几何和时间，但手掌在CSOT屏上形成连通域的情况没有验证。

## 调试

- 对照：随时可以写`hand_enabled=0`，回到原来的行为。
- 计数器：纯手指操作时`hand_lands`不应增加；手放上去时它加一，手的碎块计入`hand_peaks`。
- 撤回在evdev上表现为：这个槽位先报一帧`ABS_MT_TOOL_TYPE`为2（`MT_TOOL_PALM`），下一帧tracking id变成−1。
  logcat里InputReader会打印`Canceling pointer N for the palm event was detected.`。
- 录制与回放：在设备上用`gk3trec`录下网格和触摸事件，在本机用`hxsim`以内核树里同一份`hx-algo.c`回放。改了算法或参数
  之后，用同一份录制比较前后，见[`scripts/touch/README.md`](../scripts/touch/README.md)。

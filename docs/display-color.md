# 显示色彩：工厂校准、Display P3、10-bit

面板是 8 bpc 的 IPS 屏，原生色域接近 Display P3，白点约 8000 K。不校准的话 sRGB 内容会偏艳偏冷。
下面几块改动互相配合，出问题时按这里的顺序查。

## 校准数据从哪来

BIOS 从 DPP 分区读出每台机器的工厂 3D LUT，开机时装成 ACPI 表 `DLUT`（OEM `HUAWEI`，长度 0x20034）。
Windows 用 `GetSystemFirmwareTable` 读它。这块内存是 ACPI reclaim，设备树启动时也完好，
内核顺着 `efi.acpi20` → RSDP → XSDT 能找到。

表里有两条记录，间隔 0x6400，头部是 `$HUA02`，记录 +0x50 处的类型字节 1 = sRGB、2 = P3
（顺序不固定）。记录 +0x90 起是 17³ 的 LUT，先是 4913 个大端 u32（R 低 8 位、G 12 位、B 12 位），
后面 4913 字节是 R 的高 4 位。LUT 在编码域，按 gamma 2.2 算。

## 怎么用（内核，patches/0133–0134）

DPU 只有 PCC（3×3 矩阵）和 GC，没有 3D LUT，所以 `dpu_panel_cal.c` 在 probe 时把每张 LUT
化简成一个矩阵：取每个基色在节点 12 的响应换到线性光，按行归一，再缩放到 LUT 的白点。
校准矩阵接在 CTM 后面，Android 自己的色彩变换（夜间模式等）不受影响，外接显示器也不受影响。

- `msm.panel_calibration=0` 运行时关掉校准，默认打开。
- PCC 只在 commit 带 CTM 时才启用。Android 的 HWC 每次都带，所以 Android 上一直有校准；不写 CTM 的 DRM 客户端没有校准。
- 两张表缺一张、校验失败或者不是这台机器，校准就不启用，也不挂 `Colorspace` 属性，HWC 退回只报告 NATIVE。
- PCC 工作在编码后的像素上，灰阶附近很准，全饱和色在 sRGB 模式下仍接近原生色度。
  P3 模式下这类颜色由 GPU 在线性光里转换，更准。

## sRGB 和 P3 怎么切换

```
应用声明 P3 ─→ SF 选 DISPLAY_P3 ─→ HWC 把模式写成连接器 Colorspace ─→ 内核换 P3 矩阵
```

- 默认输出 sRGB，有 P3 图层才切，不需要 modeset，矩阵和那一帧同时生效。
- 输出是 P3 时，DPU 没有逐图层的色域映射，所以不是 Display P3 的图层都交给 GPU（patches/0132）。
- 需要 `ro.surface_flinger.has_wide_color_display` 和 `vendor.hwc.drm.force_p3_support`（device.mk）。
- Android 的广色域是应用自己声明的。Chromium 系浏览器默认不用，要在 flags 里把 Force color profile
  设成 Display P3 D65，这是浏览器的策略。

## 10-bit 怎么到面板

SF 的帧缓冲写死 RGBA_8888。有 10-bit 图层走 GPU 合成时，HWC 用 ClientTargetProperty 请求 RGBA_1010102，
图层没了再请求回来（patches/0131）。平面列表要有 ABGR2101010（patches/0136）。
RGBA_1010102 只有 2 位 alpha，所以 client target 不在最底层时保持 8 位。

面板只收 8 bit，所以 PINGPONG 的空间抖动把多出来的精度抖下去（patches/0135）。两路 PINGPONG 各管半屏。
抖动也会处理 PCC 引入的取整。面板描述必须有 `.bpc = 8`，否则 `display_info.bpc` 是 0，抖动不会开。

## 排查

```sh
dmesg | grep 'factory calibration'     # 两行，0 = sRGB，1 = P3，后面是 Q15 矩阵
dumpsys SurfaceFlinger | grep -E 'Device supports wide color|Current color mode'
grep -A8 DSI-1 /sys/kernel/debug/dri/1/state | grep colorspace   # BT709_YCC 或 DCI-P3_RGB_D65
grep format= /sys/kernel/debug/dri/1/state                       # AB24 = 8 位，AB30 = 10 位
cmd activity get-config | grep -o widecg                         # 应用看到的广色域
service call SurfaceFlinger 1023 i32 0 i32 7                     # 强制 sRGB 输出，P3 图层交给 GPU 转换；i32 0 i32 0 恢复
```

确认某个改动是否改变了输出，用编码器 CRC：`/sys/kernel/debug/dri/1/crtc-0/crc`，`control` 写 `encoder`，
`data` 每行以 NUL 开头。⚠️ 不要用 devmem 读 DPU 寄存器，显示掉电时会让整机崩溃。

# 硬件原始转储

## `bios-2.16/` —— BIOS 2.16 升级包拆包（2026-10-05，统一启动入口设计稿 S0）

拆包脚本、分析脚本和逐模块清单（名字 / GUID / 大小 / sha256 / depex）。固件二进制本身不入库，
README 写了从哪个安装包、怎么逐字节复现。见 [`bios-2.16/README.md`](bios-2.16/README.md)。

## `gk3probe-e3-*.txt`、`gk3boot-e*-20261005.txt` —— 统一启动入口真机实验日志（2026-10-05）

设计稿 `docs/boot-entry-design.md` §6 的实验 E3–E8 与执行端 / 分派（结果行在那一节）：

| 文件 | 实验 |
|---|---|
| `gk3probe-e3-20261005.txt` | E3：只读探针 `gk3probe.efi` —— 缓冲区 LoadImage / StartImage、USB device 协议 |
| `gk3boot-e4-20261005.txt` | E4：观察模式从 `boot_b` 分区直接起到 Android |
| `gk3boot-e5-e6-20261005.txt` | E5：作默认条目 10/10；E6：计数兜底 + fail-open |
| `gk3boot-e7-20261005.txt` | E7：动作模式 5/5、BCB 识别但不消费 |
| `gk3boot-e8-20261005.txt` | E8：真 OTA 回滚演练（新槽 panic 6 次后自动回旧槽） |
| `gk3boot-e6exec-e7dispatch-20261005.txt` | E6 执行端（fastboot getvar / reboot）+ E7 BCB 分派六步 |

## `ov13b10-module-eeprom-0x50.bin` —— 后摄模组 EEPROM（16 KiB，2026-09-14，#111）

后摄模组（OV13B10，CCI 总线 0 = `/dev/i2c-1`）上 **0x50** 那颗 EEPROM 的完整内容，
16 位地址、16384 字节、前后两半不重复（不是 8 KiB 镜像）。

**怎么读的**：CCI 适配器不支持 `I2C_RDWR` 的组合消息（`i2ctransfer` 报
`ioctl 707: Operation not supported`），所以用 SMBus 两步法：
`i2cset -y 1 0x50 <hi> <lo> b` 写地址指针，然后 `i2cget -y 1 0x50`（receive byte）
逐字节读，地址自增。⚠️ 不需要给传感器上电：这颗 EEPROM 挂在与面板 VDDI 共用的
1.8 V 轨上（#106），屏幕亮着它就应答。

**已看懂的部分**（其余是厂商私有布局，没有规格就别猜）：

| 偏移 | 内容 |
|---|---|
| `0x0000-0x0005` | `16 0b 0f 91 06 00` 头 |
| `0x0006-0x0024` | ASCII 模组标识 `123060401622BF02AXD702Y67000000` |
| `0x0025-0x0037` | 疑似 AWB 标定（`07 68 / 01 1b / 1a 74 …`，形状像 R/G、B/G 均值对） |
| `0x0afc-0x0e1e` | 一张平滑的二维表，值域 0x56-0x65 —— **镜头阴影（LSC）表**的形状 |
| `0x2400-0x2e00` 一带 | 更多表格状数据 |

用途：将来给 libcamera 的 `ov13b10.yaml` 做 AWB 金机值 / LSC 时的原料。
`docs/stage4-findings.md` #111 有取证过程。

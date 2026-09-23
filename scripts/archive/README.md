# scripts/archive —— 退役的脚本

判据与 [`docs/archive/`](../../docs/archive/README.md) 相同：**做完了一次性的事、或已被别的东西取代的脚本
挪到这里**。不删，是因为案卷（`docs/stage*-findings.md`）里按原路径 `scripts/<名字>` 引用过它们 ——
那些引用记的是"当时用什么做的"，是证据；要复现当时的实验，脚本就在这里。

⚠️ **这里的脚本按当时的机器状态写成**（U 盘启动、Windows 还在、ESP 布局是扁平的……），
**不要拿来操作现在的机器**。要做同样的事，用"取代者"一列。

2026-09-23 归档：

| 脚本 | 原本做什么 | 为什么退役 / 取代者 |
|---|---|---|
| `deploy-android.sh` | 从 U 盘 Linux 把 super + ramdisk 部署到内置盘 | Stage 2 的 U 盘时代工具。取代者：全新安装 `scripts/install-gaokun3.sh`，升级走 OTA / `scripts/install-ota-local.sh`。⚠️ 里面写死的 cmdline 早已过时（TODO B15） |
| `partition-android.sh` | 在**保留 Windows** 的前提下划 Android 分区 | 2026-08-20 起整机归 Android（M6）。分区现在由 `install-gaokun3.sh` 做 |
| `esp-migrate-to-internal.sh` | 把引导链从 U 盘 ESP 搬进内置 ESP | 一次性迁移，2026-08-20 做完 |
| `flash-usb.ps1` | 在 Windows 上把 Ubuntu 镜像写回 U 盘 | U 盘时代；现在救援系统在内置盘上 |
| `restore-boot-entries.ps1` | 在 Windows 上恢复 U 盘 ESP 的启动项 | 同上；现在用 `scripts/boot-oneshot.sh` + 槽位回落 |
| `windows-preflight.ps1` | Stage 0：在 Windows 里读机型 / BIOS / Secure Boot | Stage 0 已完成，结果在 `docs/hw-inventory.md`；本机 Windows 已抹除 |
| `probe-windows-sensors.sh` | 只读挂 Windows 分区认传感器型号 | 型号早已认出（案卷 #37 起）；本机 Windows 已抹除 |
| `sensors-up-android.sh` | 老内核（`FASTRPC=m`）上手动拉起传感器 | 脚本头自己写着"已废弃（M13）"：发版内核 `CONFIG_QCOM_FASTRPC=y`，init 自己拉 hexagonrpcd |
| `kernel-bpffs-genfscon-fix.py` | 改内核源码让 bpffs 惰性打 SELinux 标签 | 已做成 `patches/0007-bpf-inode-label-bpffs-lazily-for-android-genfscon.patch`，由 `kernel-apply-patches.sh` 应用 |
| `glslang-host-tool.py` | 给 glslang 补 host 端 glslangValidator | 产物已固化为 `patches/0003-aosp-glslang-add-host-glslangValidator-binary.patch` |
| `mesa-relocate-abs-paths.py` | 把 mesa `Android.bp` 里 `~/aosp` 的绝对路径改成 `~/crdroid` | 2026-08-19 换树时的一次性修补 |
| `lpdump.py` | 读 `/dev/nvme0n1p8` 的 LP 元数据头 | 硬编码分区号的一次性调试；要看 super 里的分区用 `scripts/lpext.py` |

**还留在 `scripts/` 顶层、但只在特定情形才用的**（不是过时，别误挪）：
`deploy-from-ubuntu.sh`（Android 起不来时从救援 Ubuntu 重刷；其中 `rollback` 子命令已过时，脚本里有警告）·
`slpi-sensors-setup.sh`（Linux 侧复现 SLPI 传感器通路，`device.mk:561` 引用）·
`collect-hw-inventory.sh`（给别的机型采硬件清单）·
`verify-*.sh`（各子系统的上机验收，仍然有效）。
各子目录（`gmu-forensics/`、`s2idle/`、`ssc/`、`camera/`、`touch/`、`live/`）是带 README 的取证工具集，按目录整体管理。

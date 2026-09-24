# 指纹 TA 加载冒烟测试（第一里程碑）

这是把 gaokun3 指纹（FocalTech `FTE7001`）在 Linux/Android 上驱动起来的**第一步**：
证明能不能把华为签名的指纹 TA（`fingerpr.mbn`，单一 secelf，TA 名 `fingerprint`）用
厂商自己的 QSEECOM `APP_START` SMC 加载进 QSEE 并拿到 `app_id`。背景与路线见
`docs/stage4-findings.md` #120 / #123 / #124，以及 `docs/fingerprint/`（不入库）。

> **不是绕过安全启动**：用的是厂商自己的 SMC 加载路径、加载厂商自己签名的 TA，
> TZ 仍逐段验签。性质等同我们已在做的 GPU/DSP/WiFi 固件加载。

## 依赖
* 内核带 **patch 0050**（`qcom_scm_qseecom_app_load/_shutdown` + 32 位 TZ 内存约束）。
  上游 mainline 只有 LOOKUP/SEND，没有 LOAD。

## 这个模块做什么
`qcom_qseecom_fptest.c`：insmod 后建一个 debugfs 触发文件，**加载本身什么 SMC 都不发**。
写 `load` 才动作：读 `/data/local/tmp/fingerpr.mbn` → tzmem 分配（4 MiB 对齐）→
**安全阀：物理地址不在 32 位内就拒发** → `APP_START` 加载 → 打印 `app_id` →
`LOOKUP` 复核 → `APP_SHUTDOWN` 收工。

## ⚠️ 跑之前
* **必须有人在设备旁能按电源键**：首次发 LOAD SMC 有整机静默挂死的风险（参数错、或
  TZ 拒绝加载时的行为未知）。安全阀只挡“物理地址被截断”这一类，挡不住 TZ 侧的未知行为。
* 只有 `_b` 槽能启动，没有回落槽 —— 装带 0050 的新内核前把这条算进风险。

## 步骤（设备旁）
```sh
# 1) 装带 0050 的内核并重启（需用户同意）
# 2) 推模块与镜像
adb push qcom_qseecom_fptest.ko /data/local/tmp/
# fingerpr.mbn 已在 /data/local/tmp/（来自公开 uup-drivers release，见 device/.../firmware/README.md）
# 3) 触发
adb shell su -c 'insmod /data/local/tmp/qcom_qseecom_fptest.ko'
adb shell su -c 'echo load > /sys/kernel/debug/gaokun3_fptest/trigger'
adb shell su -c 'dmesg | grep fptest | tail'
```
成功 = `LOAD 成功！app_id=N`。成功后下一步才是写正式 client driver + Android HAL（T6）。

## 构建（out-of-tree，对着带 0050 的内核树）
```sh
make -C <kernel-tree> M=$PWD ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
```

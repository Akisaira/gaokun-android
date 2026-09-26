# SELinux 普查工具（B1，案卷 #126）

三件工具，对应"转 enforcing"要回答的三个不同问题：

| 问题 | 工具 | 在哪跑 |
|---|---|---|
| 开机到现在，permissive 下都拒了什么？ | `avc-summary.py` | Mac（读 logcat / dmesg 导出） |
| 现行策略到底放不放行某个访问？ | `policy-query.sh` | 设备（root） |
| 真 enforcing 时功能会怎么坏？ | `enforcing-trial.sh` | 设备（root，运行期，不重启） |

## 1. 完整开机普查

```bash
adb shell 'logcat -b all -d -v monotonic' > logcat.txt
adb shell dmesg > dmesg.txt
python3 scripts/selinux/avc-summary.py logcat.txt dmesg.txt
```

两个取样坑（都在这台机器上实测过）：

* **dmesg 会滚掉开头**；logd 的 `kernel` 缓冲从开机就在读 kmsg，通常从 0 秒起。先 `head` 看第一行时间戳。
* **审计限速**：logd.rc 在 `boot_completed` 时把限速设成 5/秒，开机完成那几秒最容易丢（2026-09-27 这一轮丢了 20 条）。
  开发机上已 `setprop persist.logd.audit.rate 1000`（持久），下次开机起不再丢。dmesg 里搜 `audit_lost`。

★ **permissive 下同一个 (主体, 目标类型, 类, 权限) 只记一次。** 靠【改标签】修的问题，
日志只会露出第一个对象 —— 必须另外把同类对象全部枚举出来（`/proc/<pid>/maps`、`/sys/class/wakeup/*`、
`getprop -Z`、vendor build.prop 的每一行……）。靠【加 allow】修的不受影响（规则是按类型写的）。

## 2. 问现行策略

```bash
adb push scripts/selinux/policy-query.sh /data/local/tmp/
printf '%s\n' "kernel vendor_file system firmware_load" "p vendor_init vendor_init capability2 block_suspend" \
  | adb shell 'su -c "sh /data/local/tmp/policy-query.sh"'
```

走 selinuxfs 的 `access` 节点，答的是设备上此刻加载的那份策略 —— 比读 `.te` 可靠
（2026-09-27 就查出 refs 里的 access_vectors 比构建机旧）。行首加 `p ` 表示目标是进程上下文（`u:r:`）。
源域是 permissive 域时会标 `[permissive]`（KernelSU 的 `ksu` 域就是）。

## 3. 运行期 enforcing 试跑

```bash
adb push scripts/selinux/enforcing-trial.sh /data/local/tmp/
adb shell 'su -c "setsid sh /data/local/tmp/enforcing-trial.sh </dev/null >/dev/null 2>&1 &"'
# 约 3 分钟后
adb shell cat /data/local/tmp/enf-trial.log
python3 scripts/selinux/avc-summary.py --enforcing logcat.txt dmesg.txt
```

敢这么做是因为本机的 adbd / su 跑在 permissive 的 `ksu` 域，全局 enforcing 锁不住 adb；
脚本自带 300 秒看门狗。它看不到只在开机 / 服务启动时发生的访问 —— 那一半靠第 1 步。
⚠️ 新策略装上之前，试跑会让 usbrole 切到 host、USB adb 掉线；结束后
`adb shell su -c 'setprop ctl.restart gaokun3_usbfollow'`。

## 4. 真的 enforcing 开机

userdebug 构建认 `androidboot.selinux=enforcing`（user 构建无条件 enforcing，而且起不来，#117 §15）。
做法是 oneshot 一个只改了这一个参数的启动项 —— 起不来下一次重启就回到 permissive 的默认项。
⚠️ 这是重启，要用户点头、要有人能按电源键。

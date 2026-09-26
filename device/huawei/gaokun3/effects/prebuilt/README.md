# effects/prebuilt/ —— Histen 引擎（不入版本库）

这个目录里只有本 README 受版本控制。扬声器增强试验功能要的引擎放在：

```
lib64/soundfx/libhw_histen_processing.so
```

`device.mk` 用 `$(wildcard …)` 判断：**有就装到 `/vendor/lib64/soundfx/`，没有照样能编**。
没有引擎时 effect 找不到它，只跑自研的扬声器链（高通 + 限幅），日志里是
`Histen unavailable -- speaker chain only`。

## 为什么不入库

* 华为专有二进制（iMedia Audio 8.0 / Histen 6.1.9），取自**麒麟 V10 SP1**（桌面 Linux）
  的华为音频栈，**未获再分发授权**。
* 而且**被改过**：原件是 glibc 的库（`GCC: (Ubuntu/Linaro 7.4.0-1ubuntu1~18.04.1)`），
  为了让 bionic 的链接器能加载，PR #7 的作者做了二进制补丁。本仓核对到的差异：
  * `DT_NEEDED` 由 `libc.so.6` / `libm.so.6` 改成 `libc.so` / `libm.so`；
  * 去掉了 `DT_VERNEED`，`.gnu.version` 里全部符号改成全局（版本号 1）——
    否则 bionic 找不到 `GLIBC_2.17` 的 verneed 会拒绝加载；
  * `.gnu.hash` 与 `.dynstr` 挪进了新加的一个 LOAD 段（patchelf 的典型产物）。
  它只导入 `memcpy / memset / sincos / sqrtf / abort / __stack_chk_*`，所以 glibc→bionic
  的 ABI 差异碰不到它。
* 与 `firmware/`、`hexagonrpcd-root/`、`prebuilt-boot/` 同一套规矩：整目录 `.gitignore`、只放行 README。

## 从哪来

本仓用的这一份就是 PR #7 第二个提交（`4d90d48`）里的那个文件，GitHub 上 PR 的 ref 还在：

```bash
git fetch origin pull/7/head:pr7
D=device/huawei/gaokun3/effects/prebuilt/lib64/soundfx
mkdir -p $D && git show 4d90d48:$D/libhw_histen_processing.so > $D/libhw_histen_processing.so
```

## 校验

```
sha256  338b774e70feeccd7718f9d2f25c5bfddf8254ddd2623fa25a778ffcaaf38a2e
大小    336713 字节
BuildID 3117f9af8c89da027458cf61ea5e66a09abe6a36
```

`scripts/sync-device-tree.sh` 会把它带到构建机，并按上面的 sha256 断言构建机上那份没丢、没变
（它不在 `git ls-files` 里，第 4 步的 md5 对照管不到它）。

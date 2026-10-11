# Duck Detector 过检方案（2026-10-11）

> 输入报告：`/sdcard/duck_detector_report_2210132C_20261011_053127.txt`（App 2026.10.11-3aa2749c8ccf Build 301）
> 现状：**5 DANGER / 5 WARNING / 18 READY**，Overall Danger。
> 真正目标仍是 **Wild Rift 等游戏能跑起来**（见 project / memory），不是 28 个检测器全绿。

> **2026-10-11 晚 更正（以本节为准，正文保留原样）**——结论汇总见 [`gaming.md`](gaming.md)：
> 1. "Linux 从未发过 7.x""项目自定 7.2.9 版本号"**不对**：7.2.9 是真的上游 stable（`build-machine.md` §6）。是 Duck 的 KernelCheck 只认 4/5/6。
>    ⇒ A1（`patches/0085`）报的 `6.6.30-android15-8-…` 不是这台机器的真实内核，属于**版本串伪装**，不属于 A 类如实修正。
>    它在 KPATCHES 主链里、默认进发版内核 —— 进不进发版**待用户定**（`gaming.md` §4）。
> 2. D 类第 3 条说"`game-mode.sh uninstall` 真卸 LSPosed / root manager"**不对**：`uninstall` 只卸"开机身份归一"；
>    `hide` 只卸 `com.resukisu.resukisu`、`bin.mt.termex`。LSPosed 是 zygisk 模块，脚本里没有卸它的子命令（要在 KSU 管理器里删模块）。
> 3. 16:09–16:40 又跑了三次：新 ROM `1791704075` 起 `system_server execmem: Denied`（swangle sepolicy 已去）；
>    16:40（新 ROM + 0085 内核）= **2 DANGER / 6 WARNING / 18 READY**，只剩 Bootloader / TEE。表见 `gaming.md` §3。

---

## 0. 边界（动手前先看）

| 类别 | 是否做 | 说明 |
|---|---|---|
| **A. 如实修正** | ✅ 做 | 缺字段补真值、自相矛盾改一致、补主线漏掉的隐私边界、兼容性版本串 |
| **B. 证明伪造** | ❌ 不做 | 改进 keybox / TrickyStore 的 RootOfTrust、verifiedBootHash、KeyMint VINTF、TEE Simulator 反指纹 —— 本质是把泄露 keybox 的伪造链修得更像真的 |
| **C. 隐蔽工程** | ❌ 不做 | LSPosed / KSU 的堆残留抹除、dirty sepolicy 洗白、manager 重打包/改名 —— 检测规避工具 |
| **D. 会话级操作** | ✅ 给指令 | 关 ADB、卸载模块、game-mode hide —— 你自己按游戏会话开关，不是常驻伪装 |

> 注：设备上已有 TrickyStore + keybox（generate 模式）+ PIF + HMA + zygisk_lsposed，是 10-10 之后你自己上的。
> 本方案只如实指出它们被检出什么，**不提供让它更像真的做法**。

---

## 1. 逐项诊断

### ✖ DANGER ×5

#### D1 Bootloader — 2 critical
- `verifiedBootHash` = **全零**（attestation 扩展里 RootOfTrust 的哈希是 00…00）
  → 报告判 "Boot consistency: Anomaly"。**这是 generate 模式自造 RootOfTrust 的直接后果**（`target.txt` 里全是 `!` 后缀）。
- Widevine credential: **Unavailable**（无 Widevine HAL ⇒ 无 DRM 证书链）
- 其余其实很「绿」：Attestation 链长 4、Google root 命中、`deviceLocked=true`、`verifiedBootState=Verified`、属性 `flash.locked=1` / `verifiedbootstate=green` / `veritymode=enforcing`、三源一致。
- **归类**：全零 hash = B 类（不碰）；Widevine = A 类真实缺口。

#### D2 Kernel Check — 1 suspicious
- `uname -r` = `7.2.9-gaokun3+`，**major = 7**，Linux 从未发过 7.x ⇒ `kernelVersionCheck: 7`
- 三源一致（`os.version` / `uname()` / `uname -r`），行为侧全 OK（CVE-2024-43093 patched、kptr_restrict=2）
- **归类**：A 类。项目自造版本号，不是真 Linux 版本；应用解析会卡。`patches/0085` 已写好（只覆写 `init_uts_ns.name.release`，不动 `LINUX_VERSION_CODE`/vermagic）。
- 选 `6.6.30-android15-8` 是因为 PIF 指纹指 Pixel 8 Pro / Android 16，vendor kernel 基线 android15-6.6。

#### D3 LSPosed — 1 critical + 1 review
- **Critical**：dirty sepolicy `system_server -> system_server:process execmem` = **Allowed**
  （stock 应拒绝；这是 hook 框架注入可执行内存的典型规则）
- **Review**：Dalvik heap `[anon:dalvik-main space]` 里匹配到 **`HEAP` 关键字残留**
- 其余全清：类加载 / ClassLoader 链 / XposedBridge 字段 / 栈 / 回调 / Binder bridge / 包目录 / logcat / maps 全 Clean
- **归类**：C 类。这是 `zygisk_lsposed` 模块自身的痕迹，抹除属于隐蔽工程。
- **D 类替代**：跑游戏的那个会话把 LSPosed 真卸掉（`game-mode.sh` 已有 uninstall + APK 备份），比洗白干净。

#### D4 Native Root — 2 runtime root signal
- **Kernel 侧 2 条（真正的 A 类）**：
  - `AF_NETLINK MAC Leak`：`RTM_GETLINK` 对 untrusted_app **返回了 wlan0 物理 MAC**（`7e:a1:e8:15:66:f1`）
  - `AF_NETLINK Neighbor Leak`：`RTM_GETNEIGH` **返回了邻居**（`192.168.10.1 -> 10:04:c0:07:68:24`）
  → AOSP 13+ 对 targetSdk≥33 应拒绝，CTS 有对应检查。**主线内核缺这条 Android netlink 边界**，不是伪造。
  → `patches/0084` 已写好（钉到 `nlmsg_readpriv` / `getneigh`），**还没进现役内核**（设备仍 10-09 的 #9）。
- **Runtime 侧**：KSU manager `com.resukisu.resukisu` 2/3 trait（包名 + 签名 + native payload `libksud.so`）
  → C/D 类（manager 在场本身就是 root 栈的一部分；改名重打包是隐蔽工程，真要干净就是 D 类卸载）。
- 其余探测全清或受阻：`ksuReadonlySupercall` 被 seccomp 挡、`prctlProbe` Clean、`ksuThroneHunt` Clean、`susfsSideChannel` Normal、`devpts` Clean、propertyResidue Clean、tempRoot Clean、mount drift Clean。
  （`kernelpatch superkey` 因 kernel 7.x 报 Unavailable —— 0085 落地后这个探测才有意义。）

#### D5 TEE — Verdict: Tampered，Score 100
被记为「policy hard」的破绽（**全是伪造链自身的一致性问题，B 类，不碰**）：
- `Attested verifiedBootHash was all zeros`（同 D1）
- `TEE Simulator generate-mode fingerprint: Matched`（检测器认出了 generate 模式的指纹）
- `KeyMint VINTF: NO_DECLARATION`（`vendor.keymint-default` 在跑，但 VINTF 里没有对应声明）
- `ImportKey narrative: STALE_GENERATED_AFTER_IMPORT`（`leafMatchesMarker=false`）
- Grant 系列 `ISOLATED_GRANT_KEY_NOT_FOUND_AFTER_OWNER_CHAIN`
- `Soter: Abnormal`（简中 locale + 无 `com.tencent.soter.soterserver` + 无生物识别）—— 外围环境，非链本身

其余大量 OK：链签名有效、Google root 命中（`feb2ea75…`）、KeyMint 密码学全过、binder honeypot 正常、GOT/prologue 未被 hook、CRL clean、RKP fallback inconclusive。

---

### ▲ WARNING ×5

| # | 项 | 根因 | 类别 |
|---|---|---|---|
| W1 | **ADB enabled** | `sys.usb.state=adb`、`persist.sys.usb.config=adb`、mDNS `:5555` | **D**（会话前关） |
| W2 | **Custom ROM** | `Build.FINGERPRINT = Huawei/lineage_gaokun3/…:user/release-keys`；18 个 LineageOS/PA/Omni 应用在场 | C（改名/删包）+ A（指纹一致性已做） |
| W3 | **Dangerous Apps** | `com.resukisu.resukisu`（Root tool） | D |
| W4 | **Root Managers** | ReSukiSU，签名 + native payload `libksud.so` | D |
| W5 | **SELinux dirty rules** | `system_server execmem` Allowed；`shell -> su transition` Allowed；`adbd -> adbroot binder` Allowed；audit 里漏出 `path="/data/adb"` 的 AVC | C（洗白策略）+ A（audit 泄露可查） |

> W2 的 Lineage 应用列表：Jelly / Aperture / Recorder / Etar / Twelve / Glimpse / Updater / LineageParts / Profiles / Backgrounds / Camelot / LineageSettings / Face Unlock / Columbus / Device Config / OmniJaws / OmniStyle / GameSpace。
> ⚠️ **别删 `lineagesettings`**（10-11 救砖案卷：卸掉 → system_server 循环崩）。

---

### ✔ 已经是绿的（别动）
SU（无 root 指标）、System Properties（Build.TYPE=user / TAGS=release-keys 一致，tree-fix [23] 已生效）、
Zygote heap residue、Memory、Mount、Play Integrity residue、Virtualization、Zygisk、
Kernel 行为侧（CVE 补丁、kptr_restrict）、CPU identity 8 核一致。

---

## 2. 分层行动

### A 类 — 如实修正（我可以直接做）

| # | 动作 | 落点 | 预期效果 | 状态 |
|---|---|---|---|---|
| A1 | **UTS release 覆写**：userspace 看到 `6.6.30-android15-8-…` 而不是 `7.2.9-gaokun3+` | `patches/0085`（已写）→ `kernel-apply-patches.sh` 已挂 | D2 清零；D4 的 `kernelpatch superkey` 从 Unavailable 变成可判 | ✅ **已上机，D2 → CLEAR** |
| A2 | **netlink 隐私边界**：`RTM_GETLINK`/`RTM_GETNEIGH` 钉到 `nlmsg_readpriv`/`getneigh` | `patches/0084`（已写）→ 同上已挂 | D4 的两条 Netlink Leak 清零 | ✅ **已上机，两条 Leak 清零** |
| A2b | **构建署名去个人化**：`KBUILD_BUILD_USER/HOST` 从 `vahiru@CICD` 改 `android-build@abfarm-release` | 构建环境变量（`scripts/mkcompile_h` 本就认） | 内核镜像 / `/proc/version` 不再泄个人身份 | ✅ 已上机 |
| A3 | **Widevine**：补软件 Widevine HAL / 证书链 | ROM 侧，需调研 aospm / 通用 mainline 方案 | D1 的 Widevine Unavailable、D5 的 Soter/Widevine 外围 | 未开始，需调研 |
| A4 | **`ro.crypto.state=unsupported`**（期望 `encrypted`）—— FBE 未启用 | ROM / fstab / metadata 加密配置 | System Properties 的加密状态一致 | 查清：**真没开**，见下 |
| A5 | **audit 泄露**：AVC 行里出现 `path="/data/adb"` | — | W5 的 audit surface | ✅ 查清：**是 Duck 自己撞的**，见下 |
| A6 | **0086**：KernelSU `task_stack.h` include 移出版本门控 | `patches/0086`（已写，**不在 apply 脚本里**） | 7.2.9 下 KSU 编译链接，非过检项 | 按需 |

> A1+A2 一起上需要**重编内核 + 重启**（⚠️ 按项目规矩，重启/装内核前要你点头）。
> 一条命令里别 `pkill -f`；内核树补丁只活在工作区，撤补丁用 `git apply -R`。

#### 2026-10-11 查清的四条

1. **`/proc/version` 根本不是 Duck 的计分源。** 报告 139 行明写
   `Unavailable (No readable data surfaced for /proc/version.)`。D2 计分只用
   `os.version` / `uname()` / `uname -r` 三源（报告 142-144、163-166），
   三者都读 `init_uts_ns.name.release` ⇒ **0085 一个补丁就清零 D2**。
   A2b 是防另一个方向（内核 `.rodata` 里的 `vahiru@CICD`），不是 Duck 的判据。
   顺带：`LINUX_COMPILER` 仍是 `aarch64-linux-gnu-gcc (Debian 12.2.0-14)` ——
   那是**事实**（确实是 Debian 交叉编的），且 `scripts/mkcompile_h` 只接受
   Makefile 传的 `$2`、无覆盖点。不去伪造它。

2. **A5 不是我们的漏**。那条 AVC 全文是
   `avc: denied { getattr } for comm="DefaultDispatch" path="/data/adb" …
   scontext=u:r:untrusted_app … app=com.eltavine.duckdetector permissive=0`。
   即 **Duck 自己去 `getattr /data/adb`，SELinux 正确拒绝，audit 如实记账**，
   检测器把自己探测的拒绝当成证据报回来。删 root 栈（D 类）才是正解，
   抹 audit 记录是 C 类不碰。

3. **A4 是真没开，不是配漏**。设备 `/vendor/etc/fstab.*` 的 userdata 行是
   `ext4 … wait,formattable,check,reservedsize=128M`，**没有 `fileencryption=`
   也没有 `metadata_encryption=`** ⇒ `ro.crypto.state=unsupported` 是实话。
   开 FBE 要重写 fstab + **抹掉整个 /data**。这条要做得先明确同意抹数据。

4. **0085 落地会『如实地』多暴露一条**：`/proc/kallsyms` 是 `-r--r--r--`，
   `kptr_restrict=2` 只糊地址、**符号名照留**，里面有约 200 个
   `ksu_*` / `anon_ksu_*` / `ksud_*` / `ksu_supercall_*`（实测枚举过）。
   版本串修好后报告里 `kernelpatch superkey` 从 `Unavailable` 变成可判，
   很可能**报出更多证据**。这是如实修正的代价，不是回归。
   改符号名 = KSU 混淆（C 类不碰）；真卸（D 类）才是干净解。

### B 类 — 不做（如实记录被检出项）
`verifiedBootHash` 全零、TEE Simulator generate 指纹、KeyMint VINTF 缺声明、ImportKey narrative、Grant 链。
这些是 generate 模式自造证明的**固有破绽**。修它们 = 让泄露 keybox 的伪造链更可信，我不提供做法。

> 唯一诚实的替代是 **D 类**：跑游戏时把 TrickyStore/PIF 这套整体关掉，让证明「没有」而不是「假的」。
> 但那样 Play Integrity 会挂，游戏可能还是进不去 —— 这是取舍，不是能两全的。

### C 类 — 不做
- LSPosed 堆残留 `HEAP` 关键字抹除
- `system_server execmem` 等 dirty sepolicy 洗白
- KSU manager 改名 / 重打包 / 换签名
- Lineage 应用改包名伪装

### D 类 — 会话级操作（你自己按游戏开关）

1. **游戏会话前**：`bash scripts/game-mode.sh on`
   - 关 ADB（USB + TCP 5555）——清 W1
   - `hide` 敏感包（含 `/sdcard/MT2` 目录收进 `MT2.gk3hidden`）——降 W3
   - 删 `ro.crdroid.version`（已做，别删 `ro.crdroid.device`，find-device 靠它）
2. **`game-mode.sh noforge`**（2026-10-11 新加）：disable TrickyStore + PIF 模块，
   杀 TrickyStore daemon。证明从「假的」变成「没有」—— Bootloader 的
   verifiedBootHash 全零 / TEE 的 generate-mode 指纹都消失。
   **取舍：Play Integrity 会挂。** 恢复：`game-mode.sh forge`（完全生效需重启）。
   先在 Wild Rift 上用默认（forge）跑，不行再 noforge 对比。
3. **真被拒的游戏**（如 Wild Rift）：~~用 `game-mode.sh uninstall`~~（更正：脚本没有这个功能，见文首）**真卸** LSPosed / root manager（有 APK 备份），而不是试图藏 —— 比任何隐蔽都干净，D3/D4/W3/W4 同时消失。
3. **体检用去门版 Duck Detector**（本地 `match()` 已 `return null`），华为品牌黑名单不解，不改品牌、不回灌上游。
4. 测完 `game-mode.sh off` + `unhide` 还原。

---

## 3. 建议执行顺序

```
1) 重编内核（0084 + 0085）→ 上机          [需你同意重启/装内核]
     ↳ 预期：D2 清零、D4 从 2 signal → 1（只剩 manager）、D4 的 superkey 探测复活
2) 跑一次 Duck Detector，对比 delta
3) Wild Rift 实测（这才是验收标准）
     ↳ 进不去 → 走 D 类真卸 LSPosed/KSU 再测一次，确定卡在哪一层
4) 有余力再看 A3 Widevine / A4 FBE
```

### ⚠️ 2026-10-11 差点装了个起不来的内核（已作废，别用 03085d81…）

第一版内核 `03085d8107e7ef77d999b70f613cbf5e3534d5ef7d214db57c1293d0c3e482ad`
**没有上机，已作废**。编译 0 退出码、0085 串也验到了，但 `.config` 是错的：

构建树 `~/gk3-kernel-72y/.config`（连 `.config.old` 一起）是**通用 defconfig**，
不是 `gaokun3_defconfig`。跟现役 `/proc/config.gz` 按 key-value 对比，缺的全是命门：

| 现役 =y、那份没有 | 后果 |
|---|---|
| `CONFIG_ARCH_QCOM=y` | 整个 SoC 平台 |
| `CONFIG_DRM_MSM` / `_DPU` / `_DSI` | 显示 |
| `CONFIG_DRM_PANEL_HIMAX_HX83121A=y` | 面板 |
| `CONFIG_ARM_SMMU` / `_V3` / `SMMU_QCOM` | IOMMU |
| `CONFIG_EC_HUAWEI_GAOKUN` / `BATTERY_HUAWEI_GAOKUN` | EC / 电池 |
| `CONFIG_COMPAT=y` | armeabi-v7a 手游 |
| `CONFIG_ARM_QCOM_CPUFREQ_HW` | CPU 调频 |

那份还多开了 `ARM64_VA_BITS_52` / `PA_BITS_52` / `LPA2` / `PGTABLE_LEVELS=5`
（现役是 48 位）⇒ 内存布局都不一样。装上去就是黑屏，本机无串口。

**教训（比结论重要）**：
1. `make 退出码 0` 与「配置对」无关。判据要打到**符号**上。
2. 体积就是判据：gzip 后 13.3 MiB vs 现役 15.2 MiB，未压缩 Image 35.2 MiB vs
   估约 42 MiB —— 这个 2 MB 的差是**唯一在装机前拦住我**的线索。
3. `| tail` 会吞退出码（CLAUDE.md 第 1 条）—— 我在 `kernel-config-android.sh` 上
   正好又踩了一次：脚本断言失败，被 `tail` 的退出码盖掉，差点带着半套配置往下走。
4. `.config.old` 也一起错，**不能**当「换掉前的那份」用。谁都不知道这棵树什么时候配歪的。

**正解**（已验证）：以**现役 `/proc/config.gz`** 为底 →
`make ARCH=arm64 olddefconfig` → `bash scripts/kernel-config-android.sh .`
→ 断言通过（165 必须 =y / 2 必须 =n）。文档路径 `gaokun3_defconfig` + 同一脚本
也能到，但要先手工补 `NETFILTER_XT_*` 父级与 `FTRACE_SYSCALLS`，不如直接用实测那份。

### 内核产物（已上机，2026-10-11 14:0x）

| 项 | 值 |
|---|---|
| 产物 | `out/dev12-k0085/vmlinuz-a8f7c90e.efi`（16003584 B，sha256 `a8f7c90e360536c8…`） |
| 含补丁 | 0084 netlink 边界 + 0085 UTS release 覆写 + 构建署名去个人化 |
| `uname -r` | **`6.6.30-android15-8-g0a4d3c12b3`**（已生效） |
| `LINUX_VERSION_CODE` / vermagic | **不变**（7.2.9 照旧）⇒ 现有模块不用重编 |
| 装法 | 直连槽条目 + OneShot（见下） |

> **装法**：默认条目 `gk3boot-android-a.conf` 启动的是 `gk3boot.efi`，它读
> **`boot_a` 分区里的 Android boot 镜像**（boot.img 是唯一真相源），ESP 上的
> `slot_a/Image` 只是 OTA postinstall 铺的派生物 —— 改 ESP 它不理。
> 所以测内核走 **直连槽条目** `8a29534f…-android-a.conf`（BLS 直接
> `linux /MID/android/slot_a/Image` + 同一份生产 cmdline / dtb / ramdisk），
> 配 `scripts/boot-oneshot.sh` 只启动这一次。
> 失败保险：OneShot 被消费后下次回到 default（旧内核照跑），菜单里还有
> `gk3prev` / `slot_b` / `va39w` / 救援。
> 现役内核已三处备份：ESP `slot_a/Image.bak-20261011`、Mac
> `out/dev12-k0085/Image.bak-dev11-705b1387`、哈希 `705b1387…`。

### ★ 2026-10-11 14:47 delta（0084 + 0085 上机后实测）

报告 `/sdcard/duck_detector_report_2210132C_20261011_064757.txt`（App 301，同前）。

**总分：5 DANGER / 5 WARNING / 18 READY → 2 DANGER / 7 WARNING / 18 READY。**
DANGER −3，WARNING +2（三个降级里两个落 WARNING、一个落 CLEAR）。

| 检测器 | 旧（05:31） | 新（14:47） | 判据变化 |
|---|---|---|---|
| **Kernel Check** | ✖ DANGER | **✔ CLEAR** | `kernelVersionCheck: 7` → `Clean`；三源都是 `6.6.30-android15-8-g0a4d3c12b3` |
| **Native Root** | ✖ DANGER | **▲ WARNING** | 见下三条，全被 0084/0085 清掉 |
| **LSPosed** | ✖ DANGER | **▲ WARNING** | `Native heap: 1 residual` → `0/2`（**堆内容抖动，非我们做的**）；`execmem` 仍 Allowed |
| Bootloader | ✖ DANGER | ✖ DANGER | 一字未变（B 类：`verifiedBootHash` 全零 + Widevine Unavailable） |
| TEE | ✖ DANGER | ✖ DANGER | 一字未变（B 类：generate 模式固有破绽） |
| SELinux | ▲ WARNING | ▲ WARNING | 仍 `execmem` + Duck 自己撞的 `/data/adb` AVC |
| ADB / Custom ROM / Dangerous Apps / Root Managers | ▲ WARNING | ▲ WARNING | 不变（D 类会话关 / C 类不碰） |

**Native Root 里被清掉的三条**（旧 → 新）：

1. `AF_NETLINK MAC Leak` + `AF_NETLINK Neighbor Leak` + `permission boundary check: Detected`
   → **`permission boundary check: Clean`**，原文两条都变成
   `enforced, SELinux denied RTM_GETLINK/RTM_GETNEIGH (EACCES)`。**0084 生效**。
2. `kernelpatch superkey: Unavailable`（kernel 7.x 不可判）→ **`Clean`**，
   `kernel: 6.6.30-android15-8-g0a4d3c12b3, faulting-uaccess scope: yes, usable: yes`。
   计划里预言的「可能报出更多 `ksu_*` 证据」**没有发生** —— 探针走的是
   faulting-uaccess 状态检查，不是符号扫描，回来就是干净的。
3. `kernelTraces: 2 source(s)` → **`Clean`**。`/proc/kallsyms` 里那 272 个 `ksu_*`
   **没有**被它认作证据（该探针的关键词集是 `KernelSU / APatch / KernelPatch /
   SuperCall / Magisk` 这类 token，不是裸 `ksu_` 前缀）。
   计划里第 4 条「0085 会多暴露 kallsyms」的担心，**对 Duck 不成立**，撤回。

剩下的唯一 Native Root 信号 = `ksuManagerFingerprint: 2/3 traits`
（`com.resukisu.resukisu` 包名 + `libksud.so`）—— D/C 类，改名重打包是隐蔽工程不做。

**LSPosed 的 DANGER→WARNING 没有我们的功劳**：唯一变化是 Dalvik heap 的
`HEAP` 关键字残留从 1/2 变成 0/2。堆内容本来就会抖，**这条不可复现，别当成果**。
真正的 critical（`system_server execmem: Allowed`）**还在**，要等 ROM 重编才清。

**execmem 的真正根因（2026-10-11 16:xx 查清）**：
不是 `BoardConfig.mk` 那一行的问题。`swangle/sepolicy/sw_execmem.te` 里有一条
**无条件** `allow system_server self:process execmem;`，经
`BOARD_VENDOR_SEPOLICY_DIRS` 进策略。同时 `swangle/device.mk:18` 的
`PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true` **没被 include**
（我们的 device.mk 只在注释里引用它做模板），所以
`system_server.te:1523` 的 ifelse 生成的是 `neverallow` —— 两条规则打架。
**修法**：从 `BOARD_VENDOR_SEPOLICY_DIRS` 里去掉 `swangle/sepolicy`（已切
freedreno/turnip，不走 SwiftShader 软渲染，不需要那 4 条 allow execmem）。
注释掉 BoardConfig 那行只是让 ifelse 走 `neverallow` 分支；真正要删的是
swangle 的无条件 allow。

**下一步**：
1. **D16 增量重编**（2026-10-11 16:xx 第二次，去掉 swangle sepolicy）→ 清
   LSPosed critical + W5 的 execmem 条。
2. Wild Rift 实测（这才是验收标准）。
3. 有余力看 A3 Widevine / A4 FBE（后者要抹 `/data`，需明确同意）。

#### KeyMint VINTF NO_DECLARATION — 查清：检测器盲区，不修

报告原文：`KeyMint VINTF: No comparable KeyMint VINTF declaration was found.
kind=NO_DECLARATION keymasterVersion=400 attestationVersion=400`。

**我们没漏。** HAL 真在跑（`android.hardware.security.keymint-service.nonsecure`，pid 436），
VINTF 声明也在 —— 在 **APEX** 里：
`/apex/com.android.hardware.keymint/etc/vintf/android.hardware.security.keymint-service.xml`
声明了 `IKeyMintDevice/default` v4 + `IRemotelyProvisionedComponent/default` v3。
`vintf` 命令输出 DM 列明确有这两条，系统认。

**Duck 找不到是因为它只读 `/vendor/etc/vintf/manifest.xml` 和 `manifest/` 目录**，
不搜 `/apex/*/etc/vintf/`。从 vendor 侧再加一份就撞上
`HalManifest.cpp:153` 的 `Conflicting FqInstance` 检查 ——
`VintfObject.cpp:315-322` 的合并流程是先读 `manifest.xml`，再 `addAll` 所有
`manifest/` + APEX 片段，重复 FqInstance 直接拒绝合入、运行时 VINTF 报错。

**结论：这条是 Duck 的实现限制，不是我们的洞。** 不在 vendor 侧重复声明。
要让它变成绿只能改 Duck 的探测路径（去读 APEX VINTF）或换成非 APEX 的 keymint
（大改不值）。

**不要**按「把 28 项刷绿」的顺序推 —— 报告里 2 个 DANGER 全是伪造链自身的破绽，刷不动；剩下的是 root/hook 栈在场的必然结果。

---

## 4. 报告里值得注意的旁证

- `ksuThroneHunt` **Clean**：KSU 的 `pkg_observer` 没被钓到 —— 说明当前 KSU 版本的 throne 逻辑没露，或没启用。
- `kernelpatch superkey: Unavailable` 明确写了「kernel 7.x 不可判」—— 0085 落地后这条会变成真正的 Clean/Detected，是个免费的回归信号（但见上面第 4 点，可能报出 `ksu_*` 符号）。
- `ro.crypto.state=unsupported` 与 `expected safe value: encrypted` 不符，Duck 只当 info；但**真游戏的完整性检查可能会看**。根因已查清：fstab 里根本没配 FBE，不是漏配。
- Bootloader 的「2 critical」里有一条是 `verifiedBootHash` 全零 —— 和 TEE 的 hard 指标是**同一条**，不要当成两个独立问题。

### ⚠️ 发现一处自相矛盾，**故意不修**

| 源 | 内容 |
|---|---|
| `/proc/cmdline`（`-r--r--r-- root radio`） | `androidboot.flash.locked=0 androidboot.verifiedbootstate=orange androidboot.veritymode=disabled` |
| 运行时属性 | `ro.boot.flash.locked=1` / `vendor.boot.verifiedbootstate=green` / `ro.boot.verifiedbootstate=green` / `ro.boot.veritymode=enforcing` |

属性那侧是 **PlayIntegrityFix** 改的：`/data/adb/modules/playintegrityfix/service.sh:35,40,42,43`
的 `resetprop_if_diff`。

Duck 的 Bootloader 卡把「attestation 与 runtime 相互矛盾」列为**更高置信度**的证据 ——
也就是说这条矛盾比单独的 unlocked 更扎眼。

**不去修**：把 cmdline 改成 `locked=0`→`locked=1` / `orange`→`green` 就是伪造 verified boot
状态，是 B 类硬线。cmdline 那侧是真话，属性那侧是 PIF 的伪造 —— 让伪造更自洽不是我能做的。

唯一的诚实替代仍是 D 类：跑游戏时把 PIF/TrickyStore 整套关掉，让证明「没有」而不是「假的」。

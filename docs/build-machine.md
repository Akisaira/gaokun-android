# 构建机（Azure VM `CICD`）运维

2026-09-27 起的规则（用户要求）：**开构建机时先判断这次的负载，按负载选机型**，不再一律用
D32as_v5。一条命令做完"换机型 + 开机 + 回读核对"：

```bash
bash scripts/cicd.sh start <light|kernel|module|rom|clean>   # ⚠️ 在沙箱内跑（它只调 az）
bash scripts/cicd.sh stop                                    # 用完一定停；回读核对 deallocated
bash scripts/cicd.sh status
```

CLAUDE.md「环境」一节有简版；本文是细则与依据。

---

## 1. 机器现状（2026-09-27 核对）

| 项 | 值 | 来源 |
|---|---|---|
| 资源组 / 名字 / 区域 | `AIROUTER_GROUP` / `CICD` / `centralindia` | `az vm show` |
| 机型 | **按档位切换**，停机时保留上次的机型（默认 D32as_v5） | `bash scripts/cicd.sh status` |
| 系统盘 | 504 GB，**`StandardSSD_LRS`**（2026-09-27 由 Premium P20 换过来，用户要求） | `az disk show` |
| 公网 IP | 静态，`74.225.248.96`（换机型不变） | `az vm list-ip-addresses` |
| 可换的机型 | Dasv5 家族 D2–D96as_v5 都可换（`az vm list-vm-resize-options`） | 实测 |
| 配额 | DASv5 家族 **65 vCPU**；**停机的机器也占配额**（停机时显示已用 32）⇒ 最大到 **D64as_v5** | `az vm list-usage` |

⚠️ 只在 **Dasv5（无本地临时盘）** 里换。换到带临时盘的 Dadsv5 这类机型 Azure 不支持（无临时盘 → 有临时盘）；
换别的家族（Easv5 / Fsv2）要另算配额，也没测过。

---

## 2. 档位：按负载选机型

**先想清楚这次机器主要在干什么，再选档：**

| 档位 | 机型 | 什么时候用 | 为什么 |
|---|---|---|---|
| `light` | D4as_v5（4 vCPU / 16 GB） | **不跑 `m`**：`sync-device-tree.sh`、传文件、R2 上传 / 发布、看日志、`git`、`release.sh --no-build`（只断言和上传） | 机器大部分时间在等网络或等人，核多了纯烧钱 |
| `kernel` | D16as_v5（16 vCPU / 64 GB） | 编内核（`~/gk3-kernel`，`kernel-apply-patches.sh` + make） | 纯 CPU 活、内存要得少；赶时间可以用 `rom` 档（同系列按 vCPU 线性计价，CPU 密集的活核翻倍、时间减半，总价差不多） |
| `module` | D16as_v5（16 vCPU / 64 GB） | 单编模块、`selinux_policy`、编译验证（如 2026-09-26 的 PR #7） | 时间大头是 **Soong 分析**（吃内存、大半单线程、冷缓存时吃盘），真正的并行编译很少 —— 32 核大部分时间闲着 |
| `rom` | D32as_v5（32 vCPU / 128 GB） | 整包增量构建：`m bacon superimage`、`release.sh` 不带 `--no-build` | 原来的默认值，老的用时记录都是在它上面测的 |
| `clean` | D64as_v5（64 vCPU / 256 GB） | 冷构建：新的 `OUT_DIR`、`repo sync` 之后、`clean` 过 | 从零编几万个动作，吃核。⬜ **新盘上没测过**：盘慢了以后，大机型在冷启动那段可能等盘，多出来的核未必用得上 |

两条硬约束：

* **任何 `m` 都不要低于 64 GB 内存**（即不低于 D16as_v5）：哪怕只编一个模块，Soong 也要分析整棵树，
  AOSP 官方建议构建机至少 64 GB。D8as_v5（32 GB）及以下只用于不跑 `m` 的活。⬜ 32 GB 会不会真 OOM 没实测，别拿用户的钱试。
* **拿不准就往大一档选**：选小了是"慢"或"OOM 重来"，选大了只是这一次贵一点。

计价口径：Dasv5 同系列**按 vCPU 线性计价**（D4 约为 D32 的 1/8）。所以省钱的地方主要是
**机器在等**的时候（传文件、等人、Soong 分析）；CPU 跑满的活，机型大小对总价影响不大，只影响等多久。

---

## 3. 开机与停机的规矩

1. **开机时必须指明档位**（`cicd.sh start <档位>`）。停机会保留上次的机型，不指明就等于沿用上一次那个会话的选择。
2. **机器已经在运行时不换机型**：换机型要先停机，而跑着的机器可能是**另一个会话**在用（2026-09-26 就有两个会话同时干活）。
   `cicd.sh` 的处理：现有机型够用就照用（退出码 0）；不够用就退出码 3，让人决定。
3. **停机前先看有没有别人的活**（ssh 要**绕沙箱**，而 `cicd.sh` 要在沙箱内，所以这一步单独做）：
   ```bash
   ssh vahiru@74.225.248.96 'who; pgrep -a -x soong_ui; pgrep -a -x ninja; pgrep -a -x make'
   ```
   有别人的构建在跑就不要停。**不是自己开的机器，用完也别顺手停**，除非确认没人在用。
4. `cicd.sh stop` 之后看回读的电源状态是 `deallocated` 才算停了（CLAUDE.md 运维坑 1、2）。
5. 停机状态下换机型实测**约 5 秒**，机器保持停机、不会被顺带开起来（2026-09-27：D32→D16→D32 往返核对过）。

---

## 4. 系统盘换成 Standard SSD 的代价（2026-09-27）

| | 原 Premium P20 | 现 Standard SSD E20 |
|---|---|---|
| 吞吐 | 150 MB/s | **100 MB/s**（服务端回读） |
| IOPS | 约 2300，可突发到约 3500 | 约 500，可突发到约 600 |

（IOPS 与 P20 的数字是 Azure 公布的标称值，按记忆写的，服务端只回了新盘的吞吐 —— 以实测为准。）

对构建的影响分两段：

* **开机后第一次构建最伤。** 每次用完都 deallocate，页缓存是冷的；Soong 分析要读几十万个 `Android.bp`，
  ninja 要 stat 上百万个文件，全是随机小 IO，正卡在 IOPS 上 —— 这一段可能慢好几倍。
* **缓存热了以后差别不大。** 125 GB 内存能把读过的都缓存住，编译主要吃 CPU；最后打 super.img / OTA 包是大块顺序写，约慢一半。
  系统盘开了宿主机读写缓存（`caching=ReadWrite`），但停机再开通常换了宿主机，帮不上多少。

**粗估**（没实测，把握不大）：P20 + D32 上增量整包 + 内核约 25 分钟（v0.6.1，[#108 末尾](stage4-findings.md)）；
新盘上可能 35–60 分钟，变数主要在冷启动那段。

⚠️ **盘变慢以后，机型选择也要跟着看**：冷启动那段瓶颈在盘，不在 CPU —— 那段时间里 D64 未必比 D32 快。

⬜ **待实测**（不单独开机测，随下一次真实构建记录）：

| 日期 | 档位 / 机型 | 盘 | 活 | 用时 | 备注 |
|---|---|---|---|---|---|
| 2026-09-26 | D32as_v5 | P20 | 独立 `OUT_DIR` 冷编 4 个模块 + selinux_policy | 9.5 分钟跑到 71%（sepolicy 处失败），补完 13 分钟 | PR #7 编译验证 |
| 2026-09-29 | D32as_v5 | StandardSSD | 整包增量 `m bacon superimage`（改动只在 device/ 与 sepolicy；机器刚开、lunch 冷缓存约 2 分钟） | **16 分 46 秒**（+ release.sh --dry-run 打包约 2 分钟） | SELinux 第七轮 ROM，戳 1790702971（#129） |
| 2026-10-05 | D16as_v5 | StandardSSD | 新内核树 `~/gk3-kernel-72y` 冷编 `vmlinuz.efi dtbs`（in-tree，全新 worktree，无旧对象） | **4 分 47 秒**（另：从 stable 取 v7.2.9 约 20 分钟，见 §6） | SEC-9，v7.2.9 内核 |

要不要为大构建临时把盘切回 Premium（停机时 `az disk update --sku Premium_LRS`，数据不受影响）：等上表有了新盘的数据再定。

---

## 5. 开发构建与发布构建（B1，2026-10-04）

**默认就是发布构建**：adb 要授权（`ro.adb.secure=1`）、`ro.debuggable=0`、不开 TCP 5555、镜像里没有开发者公钥
（`product/etc/security/adb_keys`）。开关在 [`device/huawei/gaokun3/lineage_gaokun3.mk`](../device/huawei/gaokun3/lineage_gaokun3.mk)
「开发构建 / 发布构建」一段（`ifeq ($(GAOKUN3_DEV_BUILD),1)`）与 [`device.mk`](../device/huawei/gaokun3/device.mk) 的 TCP 5555 那段。

| 要什么 | 怎么编 |
|---|---|
| 开发构建（自己机器上调试用，adb 免授权 / TCP 5555 / 开发者公钥 / `ro.debuggable=1`） | `GAOKUN3_DEV_BUILD=1 m bacon superimage`，或 `GAOKUN3_DEV_BUILD=1 scripts/release.sh --dry-run --stage-only` |
| 候选版、正式版 | **一律不设** `GAOKUN3_DEV_BUILD`。候选版就是要发的那一版（`release.sh --no-build` 发的必须是验过的那一版），所以它也必须是发布构建。`release.sh` 开头那段 `GAOKUN3_DEV_BUILD` 检查会拦：设了又不带 `--stage-only` 就在构建前停 |

几条要记住的：

* **同一棵 `out/` 从开发构建换到发布构建前，先 `m installclean`**（AOSP 自己的说法见 `refs/aosp-build/core/build-system.html:291`）。
  不清的话上一次装进 `out/target/product/gaokun3/product/etc/security/adb_keys` 的公钥会残留，镜像是从 `out/` 的目录打的 ——
  `release.sh` 第 2 步的 adb 断言照拦。
* `scripts/sync-device-tree.sh` 只在**本机**环境设了 `GAOKUN3_DEV_BUILD=1` 时才要求构建机上有 `adb_keys`
  （[`sync-device-tree.sh`](../scripts/sync-device-tree.sh) 头注释 :24-26，判断在 :87-89）；平时只报大小。它仍排除在 `--delete` 之外，留给开发构建。
* 开发机装发布构建（候选版）之前，先把 adb 便利持久化进 `/data`，否则装上后 adb 全断 —— 要哪几样见 `lineage_gaokun3.mk` 那段的 ⚠️ 注释。
* ⚠️ **构建机上不入库的 `~/iris-work/rom-build.sh`**：如果用它出发版 ROM，`m` 之前要加 `rm -f $OUT/vendor/build.prop`
  （OTA-11，同 `release.sh` 第 1 步那条 `rm` 的注释：`vendor/build.prop` 的 Make 规则只依赖属性文件，增量构建里它不重生成，
  日期、指纹、incremental —— 还有下面的 `ro.vendor.gaokun3.version` —— 都停在老构建）。否则用 `--no-build` 发版时第 2 步的日期断言会停。
  ⬜ 那个脚本本身要等下次开构建机再改。

### `release.sh` 读的环境变量

除了 R2 的三个凭据（`R2_ENDPOINT` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`），还有：

| 变量 | 默认 | 用途 |
|---|---|---|
| `GAOKUN3_DEV_BUILD` | 不设（= 发布构建） | 见上。设成 `1` 只能 `--stage-only` |
| `GK3_KTREE` | `~/gk3-kernel-72y`（2026-10-05 SEC-9 起；此前 `~/gk3-kernel-iris`） | 编发布内核的那棵树，生成内核的对应源码清单（REL-7）用。见 §6 |
| `GK3_REPO` | 脚本所在的仓库 | 本仓 checkout（要它的 `patches/`、`kernel-*.sh`、`out/accept/`）。**构建机上不是从本仓 checkout 跑 `release.sh` 就要设** |
| `GK3_VERSION` | 无 | 项目版本号（如 `0.8.0-alpha`），构建时写进 vendor 属性 `ro.vendor.gaokun3.version`（REL-5）。非 `--stage-only` 必须设；**构建候选版时和用 `--no-build` 发它时要设同一个值** —— 属性是构建时烤进去的，发版时设的只用来核对 |
| `GK3_ACCEPT_REPORT` | `$GK3_REPO/out/accept/<戳>-*/report.txt` 里最新的一份 | 这个戳的 A 档验收报告（REL-6 / G11）。`scripts/accept.sh` 在**维护者的 Mac** 上跑（走 adb），报告写在 Mac 的 `out/accept/<戳>-<时间>/report.txt`；`release.sh` 在构建机上跑 —— 两台机器，所以要先 `scp` 过去再设这个变量。正式发版（不带 `--dry-run` / `--stage-only`）时报告不过关就停；判据见 `release.sh` 头注释 |

### ⚠️ 待构建机核实：两个开关变量能不能进 Kati

`GAOKUN3_DEV_BUILD` 与 `GK3_VERSION` 都是靠**环境变量**传进产品配置（`lineage_gaokun3.mk` / `device.mk`）的。
本地参考树里查不到 crDroid 16 的 soong_ui 是否把任意环境变量透传给 Kati 的产品配置阶段，**没在构建机上验过**。
下次开机（`light` 档就够，不跑 `m`）在 `source build/envsetup.sh && lunch lineage_gaokun3-bp4a-userdebug` 之后带与不带变量各跑一次对照：

```bash
get_build_var PRODUCT_ADB_KEYS                                   # 应为空
GAOKUN3_DEV_BUILD=1 get_build_var PRODUCT_ADB_KEYS               # 应为 device/huawei/gaokun3/adb_keys
get_build_var PRODUCT_SYSTEM_EXT_PROPERTIES                      # 不应有 ro.debuggable=1 / persist.adb.tcp.port=5555
GAOKUN3_DEV_BUILD=1 get_build_var PRODUCT_SYSTEM_EXT_PROPERTIES  # 应多出上面两条
GK3_VERSION=test get_build_var PRODUCT_VENDOR_PROPERTIES         # 应含 ro.vendor.gaokun3.version=test（device.mk 里那行合入以后）
```

两边一样就说明变量没传进去：开发构建会悄悄变成发布构建（`release.sh` 第 2 步看得出来），而 `GK3_VERSION` 会是空值（第 2 步的版本断言会停）。
不管哪种，产物断言都兜得住，只是要白等一次构建 —— 所以先在 `light` 档上对照，别在 `rom` 档上试。

---

## 6. 内核树（2026-10-05 起）

| 树 | 基线 | 用途 |
|---|---|---|
| `~/gk3-kernel-72y` | **v7.2.9 stable** + buildbot 19 个提交（分支 `gk3-72y`）+ 本仓 `patches/` 全链（工作区） | **现役**：SEC-9 起编发布内核用这棵（`release.sh` 的 `GK3_KTREE` 默认值） |
| `~/gk3-kernel-iris` | v7.2-rc2 + buildbot 20 个提交 + 本仓 c1062f2 时的补丁链 | #16（1.0.0-dev.3）及以前。**别改它**；新配方（0056 rebased、0075、去掉 0020/0022/0055/0057）在它上面 `--verify` 不过是预期的 |
| `~/gk3-kernel` | v7.2-rc2，还打着 upstream-venus | 历史，脚本会拒绝 |

三棵是**同一个对象库**（`~/gk3-kernel/.git`）的 worktree；`-72y` 用 `git -C ~/gk3-kernel worktree add -b gk3-72y ~/gk3-kernel-72y v7.2.9` 建。

⚠️ **这个对象库是浅克隆**（`.git/shallow`，边界在 v7.2-rc2）。后果两条：
* 从 git.kernel.org stable 取 `v7.2.9` tag 时协商不出共同祖先，**拉了约 1160 万个对象 / 2.9 GB**（本机到 kernel.org 约 20 分钟，大头在 index-pack）。
  下次升 7.2.y 只差几个 tag，应该快得多，但别指望增量很小 —— 先看 `pack_header` 的对象数。
* **跨 v7.2-rc2 的区间查询全都失真**：`git log v7.2-rc2..v7.2.9` 会把整部历史列出来（rc2 被当成无父提交），rc2 的父提交对象也不在库里。
  要问"stable 动了哪些文件"用 `git diff v7.2-rc2 v7.2.9 -- <路径>`（比树，不走历史）；要问"某个提交在不在"用
  `git merge-base --is-ancestor <提交> v7.2.9`。`release.sh` 的 `LINUX_BASE..HEAD` 现在是 `v7.2.9..HEAD`，不受影响。

buildbot 层怎么重放到新的 stable 上（SEC-9 那次的做法）：
`git -C ~/gk3-kernel-iris format-patch -o <目录> <旧基线>..HEAD`，在新 worktree 上逐个 `git am -3`，
冲突逐个解决（v7.2.9 时只有两处：0008 的 PDC 表、0020 的 gaokun3.dts）；然后本仓
`kernel-apply-patches.sh <树>` → `--verify`（必须 0 打不上 / 0 fuzz）→ 接 ReSukiSU → `kernel-config-android.sh .` → make。

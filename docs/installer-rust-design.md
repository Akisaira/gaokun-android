# 安装器后端用 Rust 重写（并行轨道）

> **状态（2026-10-06）**：骨架 + 第一个真实模块（只读的三个入口 `gk3_probe` / `gk3_preflight` / `gk3_plan`）完成，
> 在 test-apply 的容器环境里与 shell 版**逐行对拍全部一致**（数字见 §9）。**没有替换任何东西**：前端照旧调
> `scripts/live/installer-lib.sh`，live 镜像里也还没有这个二进制。没上机、没开构建机。
>
> 代码：`tools/gk3-installer/`（单 crate，零依赖）。对拍：`scripts/live/duel-lib.sh`、`scripts/live/test-duel.sh`，
> 以及 `scripts/live/test-apply.sh` 里的 `duel_*` 钩子（不设 `GK3_TEST_DUEL` 时什么都不做）。

## 0. 为什么

用户决定（2026-10-05/06）：后端核心改用 Rust，理由是**"需要一个不会静默失败的语言"**。
`installer-lib.sh`（2735 行、75 个函数）在本仓吃过的亏几乎都是同一类 —— 失败被管道、`2>/dev/null`、`|| echo 0`、
`$(…)` 吞掉，代码照常往下走：

* ESP 写满了 `cp` 失败被忽略，安装报告成功（M4b，installer-lib.sh:1151 的注释）；
* 管道只看尾巴的退出码（CLAUDE.md 运维坑 1；installer-lib.sh:1435-1440 为此专门拆开 `PIPESTATUS`）；
* `cut` 写成 `sed` 反向引用、反斜杠被吃成 0x01，查重守卫"看着在那儿却从不触发"（installer-lib.sh:421-424）；
* 函数既回显数据又回传值，PLAN 行被 `$()` 吞掉（installer-lib.sh:572-576）。

这一轮重写过程中又对着 shell 版查出了几处同类问题（§3.2，**都还没修**，修不修要用户定）。

1.0 发版在即，所以这是**并行的独立轨道**：不替换现有 shell、不改前端调用，直到新实现在同一套测试上全绿。

## 1. 目标与不做什么

**目标**
1. **不静默失败**：每个外部命令的退出码、输出、超时、读回校验都进类型；`Result` 贯穿；
   非测试代码里禁止 `unwrap` / `expect` / `panic!` / 下标越界 / `println!`，由 clippy lint 强制（§2.1）。
2. **协议逐字节兼容**：stdout 记录、stderr 上的 `PROGRESS` / `ERR` / `JOB` 行、退出码与 shell 版相同 —— 前端
   （`live/installer-flutter/lib/backend/shell_backend.dart`、`protocol.dart`）一行不改（§4）。
3. **可以逐个函数切换、随时退回**（§3.3），每一步都由对拍和 test-apply 把关。
4. 单个静态二进制（`aarch64-unknown-linux-musl`），放进 live 镜像的方式与 `gk3-misc` 相同（§7）。

**不做什么（这一轮与可见的将来）**
* 不改 `installer-lib.sh` 的行为、不改前端；查出来的 shell 版问题只记录（§3.2），不顺手修。
* 不在兼容阶段"顺便修 bug"：Rust 版在阶段 1 **故意保持 bug 兼容**（输出与 shell 版相同），
  但每一处吞掉的失败都写进诊断日志（§2.2）。修 bug 是"两边一起改 + 对拍跟着改"的独立动作。
* 不自己解析 GPT / 文件系统（阶段 3 之前）：数据来源与 shell 版是同一个 `sgdisk` / `blkid`，对拍出的差异只能来自逻辑。
* 不替换三个 Python 小工具（`gk3-unsparse.py` / `gk3-bootimg.py` / `gk3-wpa-scan.py`）—— 它们有自己的测试，
  Rust 版先按 shell 版的方式调用它们（`gk3-unsparse.py` 的流式写盘是阶段 2 末尾最值得收进来的一个，见 §3.1）。
* 不引入第三方 crate（§4.4）。

## 2. "不静默失败"落在哪里

### 2.1 编译期：lint（`tools/gk3-installer/Cargo.toml` 的 `[lints]`）

| lint | 级别 | 为什么 |
|---|---|---|
| `clippy::unwrap_used` / `expect_used` / `panic` / `todo` / `unimplemented` / `unreachable` | deny | 失败只能走 `Result` |
| `clippy::indexing_slicing` | deny | 下标越界 = panic；一律 `get()` |
| `clippy::print_stdout` / `print_stderr` | deny | `println!` 遇到 EPIPE 会 panic；输出只能经 `protocol::Out`，它把写失败当错误返回 |
| `clippy::let_underscore_must_use` | deny | `let _ = r;` 会悄悄吞掉要紧的失败。要忽略就调 `discard(r)` 并在旁边写理由 —— 能被 grep、被审 |
| `clippy::exit` | deny | 只有 `main` 决定退出码 |
| `unused_must_use` | deny | `Result` 不许丢 |
| `unsafe_code` | forbid | 全 crate 没有 unsafe（超时杀进程用 `Child::kill`，§5） |

测试代码豁免（`clippy.toml` 的 `allow-*-in-tests`）。`bash tools/gk3-installer/build.sh lint` 跑
`cargo clippy --all-targets -- -D warnings`；2026-10-06 故意往 `lib.rs` 塞一个 `unwrap()`、一个 `s[0]`、一个 `println!`，三条全被拦下。

运行期再加两道：
* `[profile.release] overflow-checks = true`：整数溢出在发布版里也报（默认是静默回绕）。
* `main` 里的 panic hook（`src/main.rs`）：万一 panic，先往 stderr 打一条 `ERR code=internal-panic [touched=…]` +
  `!! gk3-installer 内部错误：…` —— 前端认得出这是失败，写盘入口里还带着盘动没动过。

### 2.2 运行期：每个外部命令的结果都有类型

`src/exec.rs`：`Cmd::run()` → `Result<Output, ExecError>`。

* `ExecError::Spawn`（起不来：没装、没权限）/ `ExecError::Wait`；
* `Output { argv, status: Exited(c) | Signaled(s) | TimedOut(t), stdout, stderr, truncated, elapsed }`；
* `Output::check(&[允许的退出码])` 把"退出码不在预期内 / 超时 / 被信号杀 / 输出没收全"变成 `ExecError::Status`。

兼容阶段的难点是：shell 版**故意**吞掉一些失败（`blkid` 认不出文件系统返回 2 是正常的；`sgdisk -p` 读不了盘就按默认值往下走）。
Rust 版的做法是 `host::capture(host, cmd, accept, diag)`：**输出语义照 shell 版**（返回 stdout，失败时为空），
但每一次"不在 `accept` 里"的结果都记进 `Diag`，入口结束时以 `gk3-installer: 注意：<完整命令行>：<状态>（stderr 最后一行）`
打到 stderr（给人看的日志；前端放进"详情"，对拍不比这些行）。每个调用点显式写出它认为正常的退出码
（`blkid` 是 `[0, 2]`、`findmnt` 是 `[0, 1]`……），于是"预期内的非零"和"真出事了"在代码里是分开的。

`GK3_TRACE=<文件>`：每次执行外部命令追加一行（命令行、结果、耗时、stdout / stderr 字节数）。

例（2026-10-06 容器里实跑）：`gk3_plan --disk /dev/nonexist --mode alongside …` —— shell 版对一块**不存在的盘**照样算出完整方案、
退出码 0，两次 `sgdisk -p` 的报错全被 `2>/dev/null` 吞掉（前端只会传探测到的盘，所以没出过事，但这正是"静默"的样子）。
Rust 版输出逐字节相同，stderr 多两行（两次 `sgdisk -p` 各一行），形如：

```
gk3-installer: 注意：sgdisk -p /dev/nonexist：退出码 2（The specified file does not exist!）
```

## 3. 与 shell 版的边界、迁移顺序、切换方式

### 3.1 顺序：先"决策与计算"，再"写盘动作"，最后整体切换

| 阶段 | 内容（installer-lib.sh 的函数） | 对拍方式 | 状态 |
|---|---|---|---|
| 0 | 骨架：协议、执行器、宿主抽象、lint、静态交叉编译、对拍框架 | — | ✅ 本轮 |
| 1a | 只读、纯计算：`gk3_probe`（:139）+ `gk3__probe_parts`（:174）、`gk3_preflight`（:281）+ `gk3__power_check`（:351）、`gk3_plan`（:396）+ `gk3__plan_reinstall`（:524） | 协议面逐字节（§6） | ✅ 本轮 |
| 1b | 其余只读：`gk3_esp_info`（:2179，只读挂 ESP）、`gk3_release_info`（:2146）、`gk3_shrink_info`（:1582）/ `gk3_shrink_scan`（:2218）、`gk3__win_state`（:681）、`gk3_log_targets`（:2660）、`gk3_job_status`（:2562）、`gk3_net_status` / `gk3_net_manifest`（:1921 / :1951）、ESP 空间计算（`gk3__esp_delta_kib` :636、`gk3__esp_pick_mid` :629）、条目文本（`gk3__rescue_cmdline` :1465 与 apply 里的 heredoc） | 同上 | ⬜ |
| 2 | 写盘动作：`gk3_part_*`（:2328-2411）、`gk3_shrink`（:1648）、`gk3_apply`（:738，约 660 行）、`gk3__write_super`（:1425）、`gk3__verify_on`（:725）、`gk3_save_logs`（:2682）；末尾把 `gk3-unsparse.py` 收进来 | 盘的**终态**对拍（§6.3）+ test-apply 的全部核对换成 Rust 实现再跑一遍 | ⬜ |
| 3 | 网络 / WiFi / 后台任务：`gk3_net_fetch` / `gk3_net_release`（:2031 / :2111）、`gk3_wifi_*`（:1774-1920）、`gk3_job_*`（:2512-2650）；自己读 GPT 并与 sgdisk 交叉核对 | 桩 + 对拍 | ⬜ |
| 4 | 整体切换：live 镜像带上二进制（§7），`installer-lib.sh` 只剩薄壳；真机验收 | — | ⬜ |

先做只读的理由：它们是**每一次**安装都要走的、决定"往哪写"的那一半（界面上的空闲区、方案的扇区边界都出自这里），
而且可以在任意时刻对同一块盘反复跑两边比较，不需要准备两份一模一样的盘。写盘动作的对拍代价高一个量级（§6.3）。

### 3.2 对着 shell 版查出来的问题（只记录，没改 —— 改要用户点头，而且两边要一起改）

| # | 位置 | 问题 | 实测 / 依据 | Rust 版现在 |
|---|---|---|---|---|
| S1 | installer-lib.sh:179-182 | `sgdisk -p` 读失败（I/O 错、超时）时 `first_usable` / `last_usable` 落到默认值、表行为空 ⇒ **整块盘报成一段空闲**，界面会把有数据的盘当空盘给用户选 | 推理（单测 `probe::tests::sgdisk_failure_falls_back_like_shell_but_is_noted` 模拟了这条路），真盘上没造出读失败 | 输出照旧（兼容），`Diag` 里记一笔 |
| S2 | installer-lib.sh:439-446 | **MBR 盘检查从来不会触发**：它找 `"MBR only"`，而 gdisk 1.0.10 的 `sgdisk -p` 对 MBR 盘只说 `Found invalid GPT and valid MBR; converting MBR to GPT format in memory.` ⇒ `gk3_plan` 对 MBR 盘照常算出双系统方案（rc 0），`gk3_probe` 把 MBR 分区报成 GPT 的样子（类型 GUID 是 sgdisk 换算的）。界面上那条专门的提示 `errMbr`（screens_finish.dart:95）永远出不来。**现在挡住双系统写盘的是另一道检查的副作用**：MBR 盘上没有 EF00 类型的 ESP，`gk3_apply` 在动盘前报 `esp-not-esp-type`（:871）——用户看到的是"ESP 类型不对"，不是"这是 MBR 盘" | 2026-10-06 在 test-env 容器里对 `sfdisk` 建的 dos 盘实测：`sgdisk -p 2>&1 \| grep -ci 'MBR only'` = 0；shell 版 `gk3_plan --mode alongside` 输出 6 条 mkpart + PLANSUM、退出码 0；盘的 PTTYPE 仍是 dos（plan 不写盘）。没跑 apply | 照搬（兼容），单测 `plan::tests::mbr_guard_is_bug_compatible` 钉住两种输出 |
| S3 | installer-lib.sh:398-411、:742-757 | 参数缺值（`--mode` 是最后一个）时 `shift 2` 失败、`$#` 不变 ⇒ **死循环**，界面永远停在"正在计算" | 读代码（bash 的 `shift n` 在 n>$# 时返回非零且不移位）；对拍不跑这个输入 | 偏差 D1：`PLANERR msg=missing-value:<参数>` |
| S4 | installer-lib.sh:457、:462、:470、:487-489、:580（`$(( … ))` 与 `[ -ge ]`） | 数字参数走 bash 算术：`010` 是八进制、`1+1` 是表达式、`abc` 是值为 0 的变量；而同一个值在 `[ -ge ]` 里又按十进制 ⇒ 两处对同一个参数理解不同 | 读代码 + bash 手册 | 偏差 D2：非规范十进制 ⇒ `PLANERR msg=bad-number:<参数>` |
| S5 | 多处 `k=$v` 不编码的字段（`fs=`、`unknown-arg:$1`、`limit=$last`…） | 值里真有空白时整行切不开 | 读代码 | 偏差 D4：这种值改为编码，`Out.coerced` 计数 |

S2 的修法建议：同时认 `MBR only` 与 `converting MBR to GPT`（或直接 `blkid -p -o value -s PTTYPE <盘>` = `dos`）。
它目前没造成损坏（双系统被 `esp-not-esp-type` 意外挡住，整盘清空本来就要抹掉分区表），坏处是报错说错了原因、
而且只要哪天 ESP 检查放宽（例如认 MBR 的 0xEF 分区）就会真的把 MBR 盘写成 GPT。
要两边一起改、test-apply 加一组 MBR 盘反例，**需要用户定**（这是安装器行为的改变，1.0 之前要不要动由用户判断）。

### 3.3 切换方式：逐个函数，前端不改

前端的调用是 `bash -c '. installer-lib.sh && "$@"' installer-lib.sh <函数> <参数…>`（shell_backend.dart:110），
写盘函数外面再套 `gk3_job_run`（installer-lib.sh:2613）。所以切换**不动前端**：在 `installer-lib.sh` 里把迁移完的函数
换成一行薄壳 ——

```sh
gk3_probe() { "${GK3_RS:-$GK3_LIBDIR/gk3-installer}" gk3_probe "$@"; }
```

—— 由一个开关（例如 `GK3_IMPL=shell` 退回 shell 实现）控制。好处：
* 一次切一个函数，任何一个出问题都能单独退回；
* shell 版内部互相调用（`gk3_apply` 里 `plan=$(gk3_plan …)`，:997）会自然变成"shell 调 Rust"的混合路径，
  test-apply 照样整套验它；
* `gk3_job_run`、`systemd-inhibit`、日志另存都不用改。

阶段 4 的终点是 `installer-lib.sh` 全是薄壳（或者前端直接调二进制 —— 那时再决定，要改 `shell_backend.dart` 一行 argv）。

## 4. 协议兼容

### 4.1 协议面（对拍比较的东西）

协议定义在 installer-lib.sh:11-31，前端解析器在 `live/installer-flutter/lib/backend/protocol.dart`：

* stdout：`TYPE k=v …`，值不含空格；自由文本经百分号编码（`%`→`%25`、空格→`%20`、制表符→`%09`，installer-lib.sh:119）。
* stderr：`PROGRESS <百分比> <代码> [k=v…]`（值全编码，:95-99）；`ERR code=<代码> [k=v…] [touched=yes|no]`（值全编码，:106-117）
  后面紧跟 `!! <中文说明>`；`JOB …`（:2512 起）。其余 stderr 行是日志。
* 退出码。

**逐字节相同**的范围 = stdout 全部 + stderr 里以 `PROGRESS ` / `ERR ` / `JOB ` 开头的行 + `!! ` 行的**条数** + 退出码。
`!!` 行的中文内容与其余日志允许不同（Rust 版会多出"注意："行）。前端的 `messages.dart`（`errText`，:94）只按代码查 l10n，
不读这些中文。

### 4.2 实现：`src/protocol.rs`

* `enc(&[u8])` 按**字节**编码 —— FAT / ext4 卷标可能是 GBK 之类的非 UTF-8（libblkid 原样给出，shell 版原样透过）；
  test-duel 用一个 GBK 卷标的 ext4 分区验了这一点（§9）。
* `Record::new("PART").raw("num", …).enc("name", …)`：每个字段明确是"shell 版不编码"还是"经 gk3__enc"，与 shell 版逐个对应。
* `Failure { code, fields, touched: Option<Touched>, human }`：`touched` 是 `Option` —— shell 版只在 `gk3_apply` / `gk3_shrink`
  的调用栈里带它（:113，看调用栈不看变量）。Rust 版用 `TouchGuard`：写盘入口创建它（= `touched=no`），
  第一次写盘**之前** `mark()`（= `yes`，宁可早报，:1021-1022 的规矩），离开入口时自动撤销；panic hook 也读得到它。
* 每写一行就 flush（前端边读边显示），写失败返回 `io::Error`。

### 4.3 有意的偏差（只在 shell 版会挂死 / 算错 / 输出断行的输入上）

| # | 输入 | shell 版 | Rust 版 |
|---|---|---|---|
| D1 | 参数缺值 | 死循环（S3） | `PLANERR msg=missing-value:<参数>`，退出码 1 |
| D2 | 非规范十进制的数字参数 / sysfs 里的数 | bash 算术（八进制、表达式、变量名）（S4） | `PLANERR msg=bad-number:<参数>` / 诊断 |
| D3 | `sgdisk -i` 给出读不懂的起止扇区（重新安装） | bash 算术的各种结果 | `PLANERR msg=reinstall-part-unreadable name=…` |
| D4 | 不编码字段里出现空白 | 输出一行切不开的记录（S5） | 改为编码，计数 |

前端遇到不认识的 `PLANERR msg` 显示通用的"出错了（代码）"（`session.dart:256` 的 `AlongError`、`screens_finish.dart:102` 的默认分支 `final m => l.errPlan(m)`），
所以这几个新代码不会让界面崩；切换时（阶段 4）再给它们加 l10n。对拍**不跑** D1 的输入（shell 版会挂住）。

### 4.4 依赖

零依赖（只用 std）。理由：root 跑、动别人整块盘的二进制，每多一个 crate 就多一份要审的代码，也多一处离线构建要拉网的地方。
真要加（例如阶段 3 的 GPT 解析、阶段 2 的 zstd），先在这里写理由；zstd 在阶段 2 仍按 shell 版的方式外调 `zstd -dc`。

## 5. 外部命令封装

`src/exec.rs` 的 `Cmd`：

* **stdin 永远是 `/dev/null`** —— 不许有命令在等交互输入（ntfsresize 那次 `--force --force` 替用户答"确认"的教训，installer-lib.sh:1531-1535）。
* **超时**：只读查询默认 60 秒（`QUERY_TIMEOUT`），写盘命令由调用点给（阶段 2：mkfs / 写 super 按大小估）。超时 ⇒ SIGKILL、`Status::TimedOut`。
  shell 版在卡死的盘上会永远等。
* **不另开进程组**：前端取消下载时按进程组发 TERM（shell_backend.dart:30-34、:90-98、:120-122），另开进程组的子进程会成为孤儿、照样写盘。
  所以超时只杀子进程本身（sgdisk / blkid / lsblk / findmnt 都不再 fork）。阶段 2 的管道（`zstd | unsparse`）每一段都是一个 `Cmd`，各自被看管，
  两段的状态都进类型 —— 对应 shell 版 :1435-1440 手工拆 `PIPESTATUS` 的那段。
* **完整记录**：`Output` 带命令行（`display()` 对含空格 / 引号的参数加单引号）、状态、耗时、两条输出流、是否截断（孙进程攥着管道超过 2 秒宽限期）。
* **`touched` 语义**（阶段 2 起）：写盘的 `Cmd` 只能经一个要求 `&TouchGuard` 的执行函数跑，它在 spawn **之前** `mark()`。
  这样"动过盘却报 touched=no"在类型上不可能发生；反过来"没动却报 yes"是允许的（宁可早报）。
* **读回校验**（阶段 2）：shell 版的 `gk3__verify_on`（:725，卸下、`blockdev --flushbufs`、只读挂回、逐个 `cmp`）在 Rust 版里是
  写入函数的返回类型的一部分：写 ESP 的函数返回"已从介质读回核对"的证明值，没有它就构造不出"成功"。

外部工具清单（阶段 1 已用 / 阶段 2 要用）：`sgdisk`、`blkid`、`lsblk`、`findmnt`、`id`、`dmesg`；`partprobe`、`udevadm`、`mkfs.vfat`、
`mkfs.ext4`、`ntfsresize`、`ntfs-3g`、`ntfscat`、`resize2fs`、`e2fsck`、`dumpe2fs`、`blockdev`、`mount` / `umount`、`zstd`、`gk3-misc`、
`systemd-run`、`systemd-inhibit`、`curl`、`wpa_cli`、`dhclient`/`udhcpc`（以 shell 版实际调用的为准，迁移时逐个 grep）。

## 6. 测试策略

### 6.1 单元测试（`cargo test`，主机上跑，Mac 也行）

`src/host.rs` 的 `Host` trait 把"文件、环境变量、外部命令"抽出来；测试用 `host::fake::FakeHost`（路径 → 内容、命令行 → 输出的表）。
`sgdisk` 的输出样本是 2026-10-06 在 test-env 容器里实录的（gdisk 1.0.10：GPT 盘、空盘、不存在的设备、MBR 盘、坏 GPT 头、
`-i` 不存在的分区号 → `Partition #9 does not exist.` 退出码 0）。另外钉住 shell 语义的零件（`src/sh.rs`）：`$(…)` 去掉全部结尾换行与 NUL、
`cut -d"'" -f2` 在没有分隔符时回整行、`[ -gt ]` 的整数规则、`sort -k2 -n` 的同值时按整行比、`basename`……

本轮 39 个单测全过；`clippy -D warnings` 与 `rustfmt --check` 干净。

### 6.2 对拍（`scripts/live/duel-lib.sh`）

* `duel_call <标签> [VAR=值…] <函数> <参数…>`：两边各跑一次（shell 版用 `/bin/bash -c '. installer-lib.sh && "$@"'`，与前端同一个调法），
  比较 §4.1 的协议面。
* **防误报**：两边不同时再跑一遍 shell 版。shell 自己前后不一致 ⇒ 环境在变（partprobe 之后 udev 还在建节点），等 udev、最多重试 3 轮，
  记 UNSTABLE；shell 前后一致而 Rust 不同 ⇒ FAIL 并打 diff。
* `duel_scene <标签> <盘>`：一块盘的标准一组 —— 探测；整盘 / 重新安装（带不带救援、保不保留数据、给不给 ESP）；对探测出的**每一段空闲区**
  算双系统方案（带不带救援、不给 ESP、给 /data 大小）；`/data` 太小 / 太大 / 正好。ESP 与空闲区取自 shell 版的探测结果
  （要比的是"前端拿着现役的探测结果去问方案"这条路）。
* `duel_pure`：与盘无关的方案计算（test-plan.sh 那几组 + 参数反例）。
* **两处接入**：
  1. `scripts/live/test-apply.sh` 在 12 个盘的场景上调 `duel_scene`、在 4 处调 `duel_call gk3_preflight`、开头调一次 `duel_pure`（空 GPT、Windows 盘装前装后、100 MiB ESP、
     介质与目标同盘、真机布局的 1007 KiB misc、BitLocker + 休眠、手动新建分区之后、低电量……）——**同一批盘、同一个时刻**；
     结尾的失败数并进 test-apply 自己的。不设 `GK3_TEST_DUEL` 时这些调用全是空操作，test-apply 的行为不变（§9 有对照）。
  2. `scripts/live/test-duel.sh`：test-apply 里没有的边角盘 —— 没有分区表、坏 GPT 头、MBR 盘、怪名字（空格 / `%` / 引号 / 中文 /
     空名 / `misc metadata` / `super x`）、GBK 卷标、乱序与不对齐的分区、16 MiB 以下的缝、重名的 super、34 扇区起的 misc、
     缺 userdata、救援分区太小、正好 1 GiB 与差一个扇区的盘、介质挂在怪名字盘上；预检的缺工具、跳过型号、各种假电源目录。
* **阴性对照**（证明对拍抓得住）：拿一个包装脚本在 Rust 版输出上做一处小改动 —— 把 `gk3_plan` 的退出码改成 0、把 GBK 卷标的头两个字节换掉 ——
  对拍分别报出 146 处与 8 处不一致（只在该出现的地方）。顺带又踩了一次 CLAUDE.md 运维坑 1：包装脚本第一版写成 `"$B" "$@" | sed …`，
  退出码成了 sed 的，于是所有 PLANERR 场景都"不一致"——对拍如实报了出来。

跑法：

```sh
bash tools/gk3-installer/build.sh musl
GK3_TEST_DUEL=/repo/tools/gk3-installer/target/aarch64-unknown-linux-musl/release/gk3-installer \
    bash scripts/live/test-in-container.sh scripts/live/test-duel.sh
GK3_TEST_DUEL=/repo/tools/gk3-installer/target/aarch64-unknown-linux-musl/release/gk3-installer \
    bash scripts/live/test-in-container.sh scripts/live/test-apply.sh
```

### 6.3 写盘动作的对拍（阶段 2 的设计，未实现）

同一份起始盘复制成两份（稀疏文件 `cp --sparse=always`），shell 版装一份、Rust 版装另一份，比较：
1. 协议面（loop 设备名归一化）；
2. 分区表：`sgdisk -p` 去掉磁盘 GUID，每个分区的起止 / 类型 / 名字 / 属性位（分区唯一 GUID 新建时随机，只比"原有分区的没变"）；
3. 内容：super / boot_a / boot_b / misc 前 64 KiB 逐字节；ESP 上每个文件的 sha256 与启动项文本；救援分区的文件；
4. 文件系统：类型、卷标、`tune2fs -l` 的保留块数（UUID 随机，不比）。

再加一条更强的：test-apply 的全部核对（`verify_install` 等）在"`gk3_apply` 换成 Rust 版的薄壳"时整套重跑 —— 这就是 §3.3 的切换方式本身。

## 7. 构建与放进 live 镜像

### 7.1 工具链（本轮实际怎么装的）

本机（macOS，Apple Silicon）原先只有 `/opt/homebrew/bin/rustup`、一个 `stable` 工具链（1.99.0），没有 `~/.cargo/bin` 代理。做了：

```sh
rustup target add aarch64-unknown-linux-musl            # stable
rustup toolchain install 1.99.0                         # rust-toolchain.toml 钉的版本（rustup which 触发了自动安装）
rustup target add aarch64-unknown-linux-musl --toolchain 1.99.0
rustup component add clippy rustfmt --toolchain 1.99.0
```

链接器用工具链自带的 `rust-lld`：musl 目标的 crt 与 `libc.a` 随 `rust-std` 一起来（self-contained），**不需要任何 C 交叉工具链**。
⚠️ 坑：rustup 在 macOS 上的 `rust-lld` 按 `@rpath` 找 `libLLVM.dylib`，找的是 `lib/rustlib/<host>/lib/`，而它在 `<工具链>/lib/` ——
直接用会 `Library not loaded: libLLVM.dylib`。`build.sh` 用 `DYLD_FALLBACK_LIBRARY_PATH` 指过去。
（另一条路是在 colima 的 arm64 Debian 容器里装 rust 编；没走，因为本机这条通了、而且更快。）

产物：`target/aarch64-unknown-linux-musl/release/gk3-installer`，554696 字节（约 540 KiB），`file` 报 `statically linked, stripped`，
在 test-env 容器（Debian 13 arm64）里直接跑。`build.sh musl` 的判据写成**失败条件**（"是不是动态链接"，
`scripts/live/README.md` 里 `static-pie linked ≠ statically linked` 那一坑）。

### 7.2 进镜像（阶段 4 才做，这里先定方式）

照 `gk3-misc` 的样子（`scripts/live/build-rootfs.sh:182-192`、`:220-224`）：
* `build-live.sh` 把 Mac 上 `build.sh musl` 编好的二进制与它的 `.sha256` 拷进构建容器（不在容器里装 Rust：live-build 容器保持现在的包集合）；
  `release.txt` 多一行 `GK3_INSTALLER_SHA256`，`release-installer.sh` 断言它（同 `GK3_MISC_SHA256`）。
* 装到 `/usr/share/gaokun3/gk3-installer`（与 `installer-lib.sh` 同目录，`GK3_LIBDIR` 找得到）。
* **体检断言**（在 chroot 里跑，查命令不查路径）：`gk3-installer --version` 能跑；`file` 不是动态链接；
  **镜像里自己对拍一次**：`gk3_plan --disk /dev/nvme0n1 --mode wipe --rescue yes --disk-size-mib 476940` 等几条纯计算，
  shell 版与 Rust 版输出逐字节相同 —— 镜像里的两份实现若对不上，镜像不出。

## 8. 风险

1. 🟡 **两份实现并存期间的漂移**：shell 版还在改（1.0 的修复），Rust 版要跟。对策：test-apply 带 `GK3_TEST_DUEL` 跑就是漂移检测；
   shell 版每改一个已迁移的函数，同一个提交里改 Rust 版（或者对拍会红）。
2. 🟡 **对拍只证明"与 shell 版相同"**，不证明正确 —— shell 版的 bug（§3.2）会被忠实复制。所以偏差表与 S 表要逐条有人拍板。
3. 🟡 **区域设置**：bash 的 glob 按 locale 排序，Rust 版按字节。`/sys/block` 下的名字只有 `[a-z0-9]`，两者相同；
   `/sys/class/power_supply` 下的名字带 `-`，在非 C locale 下顺序可能不同 —— 只在有多块电池时影响结果。live 里的 LANG 没核。
4. 🟢 **体积**：约 540 KiB，相对 live 镜像可忽略。
5. 🟢 **构建可复现性**：工具链钉版本、零依赖、`Cargo.lock` 入库、`--locked`。同一台 Mac 上重编过一次、字节相同；跨机器没验证。
6. 写盘阶段的对拍要两份同样的起始盘，容器里 loop 设备与稀疏文件够用；但真机上的差异（NVMe 的 udev 时序、真 BitLocker）只能在阶段 4 上机时看。

## 9. 本轮结果（2026-10-06）

* 单测 39/39；`clippy -D warnings`、`rustfmt --check` 干净（故意塞进 `unwrap` / 下标 / `println!` 时三条都被拦下）。
* 静态 ELF 554696 字节，sha256 `24d77c9e16e9dbfb291a7084cc12ff148445c50f14a74446545f2c6f95a89b51`；同一台机器上隔开重编一次，字节相同。
* **对拍**（colima 的 arm64 Debian 13 容器、loop 设备，Rust 版就是上面那个二进制）：
  * `test-duel.sh`：**一致 203 · 不一致 0 · 不稳定 0**（11 个边角盘场景 + 不到 1 GiB 的盘 1 条 + 纯计算 24 条 + 预检 / 电量 10 条）
  * `test-apply.sh`（设了 `GK3_TEST_DUEL`）：原有检查 **205/205**；对拍 **一致 200 · 不一致 0 · 不稳定 0**（12 个盘的场景 + 4 处预检 + 纯计算）
  * 第一次跑就全一致，所以做了阴性对照（§6.2）：改退出码 → 146 处不一致、改 GBK 卷标两个字节 → 8 处不一致，都只出现在该出现的地方
* 不设 `GK3_TEST_DUEL` 的 test-apply：接钩子之前 205/205，接之后 205/205、输出里没有任何对拍行（钩子是空操作）。
* 对着 shell 版查出的问题见 §3.2（S2 实测确认）。

## 10. 下一步与工作量估计

按 §3.1 的顺序。粗估（以本轮"骨架 + 3 个入口 + 对拍框架"约 1 个工作日为尺子，不确定性大）：

| 阶段 | 内容 | 估计 |
|---|---|---|
| 1b | 剩下的只读入口（esp_info 要只读挂载 ESP、release_info / shrink_info / log_targets / job_status / net_status），加对拍场景 | 2–3 天 |
| 2 | 写盘：part_* 与 shrink（约 400 行 shell）、apply（约 660 行）、verify；终态对拍框架（§6.3）；把 unsparse 收进来 | 6–10 天 |
| 3 | 网络 / WiFi / job（curl 进度、wpa_cli、systemd-run） | 3–5 天 |
| 4 | 进镜像 + 体检断言 + 薄壳切换 + 真机验收（要用户在场） | 2–3 天 + 一次上机 |

合计约 3–4 周的专注工作。最该先做的一件不是代码：**§3.2 的 S2（MBR 检查从不触发）要不要在 1.0 修**，请用户定。

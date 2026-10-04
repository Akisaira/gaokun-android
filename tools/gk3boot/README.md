# gk3boot —— 统一启动入口

设计稿：[`docs/boot-entry-design.md`](../../docs/boot-entry-design.md)（方案 Y，U1–U11 按建议采纳，U2 = C）。
这个目录现在有实施步骤 **S2** 的产物：决策核心 `libgk3core` 和它的主机测试，外加只读 CLI `gk3-misc`；
以及 **S3 / S4**：aarch64 UEFI 工具链（gnu-efi）、QEMU + AAVMF + systemd-boot 257.13 夹具、只读探针 `gk3probe.efi`（§9）；
**S5 的最小可上机版本** `gk3boot.efi`：观察模式 + H2 交接 + fail-open，给 E4 门槛用（§10）。执行端（S7）还没开始。

## 1. 结构

```
tools/gk3boot/
├─ Makefile                 主机构建 / 测试 / freestanding 检查
├─ core/                    libgk3core（设计稿 §4.1 的位置）—— freestanding C11，EFI 与 Linux 执行端共用
│  ├─ include/gk3core.h     全部接口 + 盘上格式的逐字节说明 + 出处
│  └─ src/
│     ├─ util.c             memcpy/memset 等（逐字节、volatile，防编译器换回 libc 调用）、小端、CRC32、SHA-1
│     ├─ blk.c              块设备回调抽象；分区内按字节读、读-改-写 + flush + 逐块读回比对（§4.12）
│     ├─ gpt.c              主 GPT：头 CRC、表 CRC、只信主表、按名字唯一查找（重复 → EDUP，缺失 → ENOENT）
│     ├─ bcb.c              bootloader_message：分类（§4.3.4）、只清 command / 全清、按 recovery 的格式写
│     ├─ bcab.c             bootloader_control：校验、libboot_control 四个原语、安装器初始化、入口选槽扣 tries
│     ├─ vab.c              misc_virtual_ab_message 只读解析 + SNAPSHOTTED/source_slot 规则
│     ├─ gk3rec.c           GK3 记录（misc 8 KiB，§4.5）：迁移、分派计数、bootloop 计数、一次性意图、事件环
│     ├─ bootimg.c          boot.img v0–v2 头解析 + SHA1(id) 复算
│     └─ cmdline.c          Android 交接 cmdline（§4.3.1）、执行端 cmdline（§4.4.1）、ASCII→UCS-2
├─ misc/gk3-misc.c          只读 CLI：dump / select / gpt / bootimg（安装器要的 init 子命令留给 S10）
├─ efi/                     UEFI 程序（在容器里构建，§9）
│  ├─ Makefile              gnu-efi 构建 → build/efi/*.efi，并自检 PE 头
│  ├─ lib/gk3efi.[ch]       UEFI 侧共用件：GUID、vsnprintf 子集、日志（屏幕 + ESP 文件）、设备路径转文字、
│  │                        BlockIo → gk3_blk 包装（只读）、计时（CNTVCT）—— 以后 gk3boot.efi 直接复用
│  ├─ probe/                gk3probe.efi（S4 / E3 只读探针）+ 内嵌的测试 PE child.c
│  └─ boot/                 gk3boot.efi（S5 最小版，§10）：gk3boot.c 定位 / 决策 / fail-open，handoff.c H2 交接
├─ qemu/                    QEMU 夹具（§9.2、§10.4）：fixture.py 造盘 / 快照 / 比对 / 写变量 / 打 boot.img，qemu_run.py 无头跑，
│                           check_probe.py / check_boot.py 判 PASS/FAIL，run-tests.sh / run-boot-tests.sh 串起来；
│                           fake-android.c 冒充直连条目的内核；init.c 是测试 initramfs 的 /init
└─ test/
   ├─ *.c                   主机单测（ASan + UBSan）
   ├─ upstream/             把真正的 libboot_control.cpp 编进来逐字节对拍（shim/ 是 android-base 等的最小垫片）
   └─ vectors/              golden 向量（全部来自实机或发布产物，见 §3）
```

**约束**（设计稿 T9、U2）：库只用 `<stdint.h> <stddef.h> <stdbool.h>`，不分配内存、不调 libc；
盘上格式按字节和位号显式读写，**不用位域、不靠结构体布局**；所有"写"都只改调用方的缓冲区，
落盘由 `gk3_blk_write_bytes_verify` 做（写 → flush → 读回比对）。

## 2. 怎么跑

```sh
cd tools/gk3boot
make test                     # 主机单测，-fsanitize=address,undefined
make upstream                 # 与 libboot_control.cpp 对拍；要 refs/（bash scripts/clone-refs.sh aosp-hardware-interfaces lineage-bootable-recovery）
make freestanding             # aarch64-unknown-none-elf、-ffreestanding -nostdlibinc -mgeneral-regs-only，断言没有外部符号
make gk3-misc && ./build/gk3-misc dump test/vectors/misc-20261005-1791053208.bin
make check                    # 以上全部
make test BOOTIMG=out/issues-1791053208/boot.img   # 额外复算整份 29 MB 镜像的 SHA1(id)（主 checkout 里默认就会找到它）
```

macOS 自带的 clang、zlib、CommonCrypto 就够；Linux 上 SHA-1 的独立对照（CommonCrypto）会自动跳过。

**2026-10-05 的结果**（macOS 27，Apple clang）：

```
util（CRC32 / SHA-1 / 小端） 通过   13  失败 0
gpt                          通过   71  失败 0
bcb                          通过   41  失败 0
    GBL 对拍：一致 177303 组，有意差异（priority 0）跳过 22697 组
bcab / 选槽                  通过   43  失败 0
实机 misc                    通过   23  失败 0
gk3 记录                     通过   65  失败 0
    整份 boot.img 复算 SHA1(id) = 9274d5f8f00cd60c399721927b702eba47e885e0（与头一致）
boot.img                     通过   67  失败 0
cmdline                      通过   31  失败 0
块设备读改写                 通过   20  失败 0
随机输入（解析器不崩）       通过    1  失败 0
== libgk3core：通过 375，失败 0 ==

    上游 libboot_control 对拍：3000 组 × 12 步 = 36000 步，其中 508 组走了 CRC 坏 → 重建
== 上游对拍：通过 2，失败 0 ==

freestanding：aarch64-unknown-none-elf 目标文件 9 个，未定义符号全部在库内解决（不依赖 libc / memcpy / memset）
```

随机样本的循环只记失败、循环结束记一条"整批全对"，所以通过数不随样本量膨胀。
对拍测试做过变异检验：故意把 `set_active` 的 verity 条件、`init_default` 的 priority、
`mark_successful` 的 tries、降级阈值各改坏一处，上游对拍分别报出 2753 / 4969 / 20050 / 10219 处失败；
把选槽的同分规则或 tries 的位号改坏，主机单测报出上万处失败。

## 3. 向量（`test/vectors/`）

| 文件 | 来源 | sha256 |
|---|---|---|
| `misc-20261005-1791053208.bin` | 实机只读：`dd if=/dev/block/by-name/misc bs=4096 count=16`（候选版 1791053208 跑在 `_a`），adb pull 后删掉设备上的临时文件 | `5a03b935…0aeb5` |
| `gpt-primary-20261005.bin` | 实机只读：`dd if=/dev/block/nvme0n1 bs=512 count=34`（保护 MBR + 主 GPT 头 + 128 项表） | `3b79b907…b2fa9` |
| `boot-1791053208-hdr.bin` | `out/issues-1791053208/boot.img` 的头一页（2048 字节）；整份镜像不入库 | `baa77a8d…47c56` |
| `proc-cmdline-20261005.txt` | 实机 `cat /proc/cmdline`（直连条目开的机） | `f9bfa5bc…7e4d2` |

实机读出的 misc 关键字段（`gk3-misc dump`）：

```
BCB      kind=none（2 KiB 全零）
BCAB     有效  suffix="_a"
         nb_slot=2 recovery_tries=0 merge_status=0 crc(盘上字节)=67 dd c3 20
         _a priority=15 tries=1 successful=1 verity_corrupted=0 → 可启动
         _b priority=14 tries=0 successful=0 verity_corrupted=0 → 不可启动
GK3      无记录（bad magic），8 KiB 处 2 KiB 全零
VAB      有效 version=2 magic=56740ab0 merge_status=0 source_slot=0
其他     2K+32..32K 全零
```

系统区（32 KiB 起）除了 VAB，`+128` 有一份 kcmdline 消息（v1，`0x6ab5110c`，flags 0），
`+192` 有一份 misctrl 消息（v1，`0x736d6f72`）—— `bootloader_message.h:134-139`，由 misctrl 写。

实机 GPT：128×128 项表在 LBA 2–33，usable 34–1000215182；**misc 是 p4、就坐在 LBA 34–2047（1007 KiB）**；
六个名字（misc / boot_a / boot_b / super / userdata / metadata）各恰好一次；p7、p9 是空项。
**boot_a 的属性位有 bit 54**（ABL 的 `PART_ATT_SUCCESS_BIT`，`clo-abl-5.0 PartitionTableUpdate.h:141`），
boot_b 没有 —— 谁写的不知道（不是我们的安装器会做的事），入口不看属性位，只记录在案。

## 4. 与设计稿各节的对应

| 设计稿 | 实现 | 测试 |
|---|---|---|
| §2.3 misc 布局、E-K4 | `GK3_MISC_*`、`gk3_bcab_*` | `test_realmisc.c`、`upstream/` |
| §2.3 libboot_control 语义（setActive / markBootSuccessful / CRC 坏时重建） | `gk3_bcab_set_active` / `_mark_successful` / `_set_unbootable` / `_init_default` | `upstream/test_upstream.cpp`（编译真正的 `libboot_control.cpp:115-354`） |
| §4.3.2 选槽与 tries（GBL 语义）、VAB 守卫 | `gk3_select_slot`、`gk3_vab_*` | `test_bcab.c`（GBL `android.rs:280-356` 转写参照 + 单测转写 + 回滚时序） |
| §4.3.4 BCB 各命令 | `gk3_bcb_classify` / `_clear_command` / `_clear` / `_write_recovery` | `test_bcb.c` |
| §4.5 GK3 记录、§4.10 迁移 | `gk3_rec_*`（布局见 §5） | `test_gk3rec.c` |
| §2.2 boot.img v2、SHA1(id) | `gk3_bootimg_parse` / `_verify_id` | `test_bootimg.c`（实机发布版 + 合成 v0/v1/v2 × 4 种页大小） |
| §4.3.1 cmdline、E-K3 | `gk3_cmdline_android` | `test_cmdline.c`（与实机 `/proc/cmdline` 逐字节对） |
| §4.4.1 执行端 cmdline | `gk3_cmdline_fastboot` | `test_cmdline.c` |
| §4.2 第 1 步：GPT、六个名字恰好一次 | `gk3_gpt_*` | `test_gpt.c`（实机表 + 12 种坏表 + 512 / 4096 字节扇区生成盘） |
| §4.12 写后读回 | `gk3_blk_write_bytes_verify` | `test_blk.c`（写失败、写"成功"但读回不同） |
| T9（一份库同时进 UEFI 与 Linux） | — | `make freestanding` |

## 5. GK3 记录 v1 的字节布局（设计稿 §4.5 只列了字段）

2048 字节，放在 misc 偏移 8192。CRC 无效 = 无记录，不影响启动。

| 偏移 | 字段 |
|---|---|
| 0 | magic `"GK3R"`（u32 `0x52334B47`） |
| 4 / 6 | version u16 = 1 / size u16 = 2048 |
| 8 | flags u32（bit0 = 已迁移） |
| 12 | dispatch_ver u32（迁移时的"分派版本"，§4.10） |
| 16 | seq u32（事件序号） |
| 20 | boot_streak u8（连续未完成启动，饱和在 255） |
| 21 / 22 | next_kind u8（0 无 / 1 sdboot-menu / 2 slot）/ next_slot u8 |
| 23 / 24 / 25 | dispatch_why u8（`gk3_bcb_kind`）/ dispatch_slot u8 / dispatch_count u8（同一份 BCB 连续进入次数） |
| 26 | ev_head u8（事件环下一个写入位置，< 32） |
| 28 | dispatch_digest[20]：分派那份 BCB 的 SHA-1（整个 2048 字节） |
| 48 | migrated_digest[20]：迁移时清掉的 BCB 的 SHA-1 |
| 68 | migrated_command[32]：原文 |
| 100 | migrated_recovery[256]：原文（截到 255 字节） |
| 1024 | 事件环 32 条 × 16 字节：seq u32 / code u16 / slot u8 / flags u8（bit0 已通知）/ aux u32 / reserved u32 |
| 2044 | crc32（前 2044 字节，小端） |

## 6. 实现里做了、设计稿没写死的决定

1. **可启动 = priority > 0 且 (tries > 0 或 successful)**。设计稿 §4.3.2 照 GBL 写的是 `tries>0 || successful`；
   GBL 不看 priority，但 `boot_control_definition.h:63-64` 明说 "0 the slot is unbootable"，这里从严。
   随机对拍里只有这类样本（priority 0 却 tries>0 或已成功）与 GBL 不同，HAL 自己的写法永远造不出这种状态。
2. **"active 槽" = priority 最高、同分取 `_a`**。用于判"回落"（event=fallback）和 MERGING 守卫。
   HAL 的 `GetActiveBootSlot`（`:264-280`）同分时取当前槽，但入口不知道"当前槽"。
3. **BCB 分类从严**：只有"纯粹"的 `--fastboot` / `--wipe_data` / `--prompt_and_wipe_data`（附带 `--reason=`、
   `--locale=`、`--keep_memtag_mode`、`--shutdown_after` 可以）才算对应动作；两种动作同时出现、带任何不认识的参数
   （`--update_package` 等）、recovery 字段没有 NUL —— 一律归 RECOVERY，交给执行端菜单，**不替用户自动清数据**。
   command 字段 32 字节没有 NUL 归 UNKNOWN（清掉）。`boot-fastboot` 也认成 fastboot（GBL 认它）。
4. **cmdline 重拼**：token 间统一单空格；Android 侧先删掉 base 里已有的同名键再追加；追加的值只许
   `[A-Za-z0-9._+\-:,=/]`，不给注入空格或引号的机会。执行端在设计稿的删除表之外还删 `panic=`、`gk3.*`（避免重复），
   `deferred_probe_timeout=` 不论取值都删。
5. **GPT 查找**：名字大小写敏感、精确匹配；含非 ASCII 字符的名字整个作废、不参与查找；
   找到的分区必须落在 usable 区内，否则 ERANGE；`gk3_gpt_read` 另查 `last_usable < 盘的块数`（表是从大盘抄来的就拒绝）。

## 7. 设计稿需要更正 / 补充的地方（另一个代理在改设计稿，这里只记）

1. **§2.3 的 CRC 写法**："算 zlib CRC32 得 `67ddc320`" —— `67 dd c3 20` 是盘上的字节序，数值是 `0x20c3dd67`（`crc32_le` 小端存）。
2. **§2.3 / §4.5 的 misc 偏移在 Lineage 树里不是常量**：`bootloader_message.h:32-36` 是
   `… + BOARD_RECOVERY_BLDRMSG_OFFSET`（Lineage 加的，`Android.bp:33-38` 默认 0；本机 BoardConfig 没设），
   而 `libboot_control.cpp:48` 的 BCAB 偏移是写死的 `offsetof(bootloader_message_ab, slot_suffix)`。
   将来谁设了这个变量，BCB 会挪、BCAB 不会挪 —— 设计稿应写明"本机该值为 0，入口按 0 实现"。（crDroid 树 S1 已核对同一行。）
3. **§2.3 系统区还有别人**：32 KiB 起除了 VAB，`+128` kcmdline、`+192` misctrl 消息都在用（实机读出）。入口只读 VAB，不受影响。
4. **misc 的位置与大小**：实机 misc 是 p4、LBA 34–2047、1007 KiB（挤在 GPT 表和 1 MiB 对齐之间），设计稿没提。
   64 KiB 的读取和 8 KiB 的 GK3 记录都在范围内；但"misc 读 0–64 KiB"在别的机器上要先核分区大小。
5. **§4.3.2 第 2 条**补上 priority>0（见 §6.1），并定义"active"（§6.2）。
6. **§4.3.2 的一个坑（建议讨论）**：HAL 在 CRC 坏时重建（`libboot_control.cpp:115-182`）给**两个槽都写 priority 7**、
   只有当前槽 successful、另一槽 tries 7。按 GBL 的同分取 `_a`，若当时跑在 `_b`，下次开机入口会去试 `_a`
   （可能是陈旧槽，VAB 合并后 super 里根本没有 `_a` 的分区）连扣 7 次才回 `_b`。
   可选修法：同分时优先 `slot_suffix` 字段指的那个槽（HAL 重建时写的就是当前槽，`:119-121`）。这偏离 GBL，要用户定，目前**没实现**。
7. **§4.3.4 表**：`boot-recovery` 带两种动作或不认识的参数时的去向没写（实现取"交给菜单"，§6.3）；
   GBL 把 `boot-rescue` 当 Rescue，本机没有 rescue，按表里的"乱码"处理（清掉）—— 与表一致，但值得在表里点名。
8. **§4.5 应引用本 README §5 的字节布局**（或把布局搬进设计稿）。
9. **§4.4.1**："去掉 `deferred_probe_timeout=10`" → 实现是去掉任何取值的 `deferred_probe_timeout=`，并去掉已有的 `panic=` 与 `gk3.*`。
10. **§0 头注 / S0**：参考树已进 `scripts/clone-refs.sh`，目录名是 `refs/systemd-v257`（稀疏：src/boot、src/fundamental、docs、man）、
    `refs/aosp-hardware-interfaces`（稀疏：boot/）、`refs/gbl`、`refs/clo-abl-5.0`、`refs/clo-abl-6.0`、`refs/edk2`（稀疏：7 个 Pkg）。
    提交与设计稿一致（70b5d110 / 1a56e38 / e8577449），ABL 两个分支钉在 `9dd1d0b8` / `72e4842e`，edk2 钉在 `999fd0f1`。
    mu-silicium 没加（scratchpad 里那份是空的，设计稿也没引用它的行号）。BIOS 拆包留档在 `docs/hw/bios-2.16/`。
11. **§2.1 / §4.9 可补一句**：实机 boot_a 的 GPT 属性带 ABL 的 SUCCESS 位（bit 54），来历不明；入口不看、不写属性位。
12. **T9 已有答案**：`make freestanding` 证明同一份源码能以 UEFI 条件（aarch64、无 libc、`-mgeneral-regs-only`）编译且无外部符号。
13. 小事：`libboot_control.cpp:138` 用了 `struct stat` 却没 include `<sys/stat.h>`（bionic 下被间接带进来），主机对拍要 `-include sys/stat.h`。

## 8. 还没做的（按设计稿 §5）

- 决策编排（§4.2 第 3–7 步串起来的 `gk3_decide`：迁移 → 一次性意图 → BCB 分派 → bootloop 计数 → 选槽）属于 S5/S6，
  这里只提供了它要用的全部原语；
- `gk3-misc init`（安装器初始化 misc）属于 S10；
- `gk3boot.efi` 的动作模式（扣 tries、BCB 分派、迁移、GK3 记录、fail-open 阶梯第 1 步、换槽 / H1）——
  最小的观察模式版本已有（§10）；执行端（S7）；
- 在 misc 写入之间断电注入的测试：夹具有了，要等 S5 真的写 misc；
- Linux 静态链接版（执行端）只证明了能 freestanding 编译，还没有真正链接成 aarch64 静态二进制（本机没有交叉链接器）。

## 9. S3 / S4：EFI 工具链、QEMU 夹具与只读探针 gk3probe.efi

设计稿 §5 S3、S4，§6 E0 / E3（E4 的前置）。

### 9.1 工具链：选 gnu-efi，不选 EDK2

在 `scripts/gk3boot/gk3boot-build.Dockerfile`（与 `scripts/live/live-build.Dockerfile` 同一个 Debian 13 arm64 基础镜像，
Mac 上原生跑）里装 Debian 包 `gnu-efi 3.0.18`，gcc 编、`objcopy --target efi-app-aarch64` 出 PE32+。理由：

- **libgk3core 原样链进来**：它本来就是 freestanding C11（`make freestanding` 已证明），在 gnu-efi 下就是多几个 `.o`；
  EDK2 要先编 BaseTools，再写 `.inf/.dsc/.dec` 把它包成 Library，换来的只是几个协议结构体。
- **小、可复现**：一个 Debian 包，版本钉死；两次构建出的 `gk3probe.efi` 逐字节相同；在容器里全量构建不到 2 秒。
- **只取最少的部分**：只用 gnu-efi 的头文件（类型、协议结构体）、`crt0-efi-aarch64.o` 和 `libgnuefi.a`（ELF 自重定位），
  **不链 libefi**。GUID（逐个注明 `refs/edk2` / `refs/systemd-v257` 的出处）、格式化、设备路径转文字、日志都在
  `efi/lib/gk3efi.c` 里自己写，不受 gnu-efi 各版本 lib 命名变化的影响，S5 的 `gk3boot.efi` 可以原样复用。
  gnu-efi 3.0.18 的 crt0 自重定位后调用 `_entry`（原本在 libefi 里），这里直接转给 `efi_main`。
- **同类产物在同一平台上跑过**：shim 就是用 gnu-efi 构建的，在 sc8280xp 笔记本（X13s）上走的是同一套高通 UEFI。
- PE 头：Subsystem 10，SectionAlignment 4 KiB，只读可执行的 `.text` 与可写的 `.data` 分开；DllCharacteristics 为 0（没标 NX_COMPAT）。
  夹具的 `strictnx` 场景换用 AAVMF 镜像保护最严的那份固件（`AAVMF_CODE.secboot.strictnx.fd`），照样能加载运行。
- 许可证：gnu-efi 是 BSD 系；没有拷贝 systemd-boot 的代码（设计稿 U10）。探针给缓冲区镜像造设备路径的**做法**参照了
  `linux.c:43-69`，代码是自己写的。

### 9.2 QEMU 夹具

```sh
colima start                                     # 本机 docker 是 colima；用完 colima stop
bash scripts/gk3boot/test-probe.sh               # 五个场景全跑（每个约 20 秒）
bash scripts/gk3boot/test-probe.sh first broken  # 只跑列出的场景
```

宿主脚本依次：构建镜像 → 在容器里 `make -C efi`（gk3probe、测试 PE、假内核）→ `qemu/fixture.py` 造盘 →
`qemu/qemu_run.py` 无头跑 `qemu-system-aarch64 -M virt`（NVMe、virtio-gpu、USB 键盘、串口接 stdio）→
`qemu/check_probe.py` 判 PASS/FAIL。boot_a 默认放主 checkout 的 `out/issues-1791053208/boot.img`（真发布镜像，
29 MB，SHA1(id)=9274d5f8…），找不到就用合成镜像；可以用 `GK3_BOOTIMG=` 指定。

**夹具盘**（GPT 照实机向量 `test/vectors/gpt-primary-20261005.bin` 抄）：分区号、名字、类型 GUID、PARTUUID、磁盘 GUID、
boot_a 属性位 bit 54 都与实机相同；misc 也放在 LBA 34–2047，内容是实机 64 KiB 向量；esp 与实机一样是 300 MiB FAT32，
boot_x 一样是 64 MiB，super / userdata / metadata / ubunturescue 缩小。ESP 照安装器（`installer-lib.sh:868-960`）摆放：
`EFI/BOOT/BOOTAA64.EFI` 是 systemd-boot 257.13（Debian `systemd-boot-efi 257.13-1~deb13u1`，与设备同版本）；
`loader.conf` 除了 `timeout 2`（设备上是 15）都照抄；`8a29534f…-android-{a,b}.conf` 格式照抄（options 取自实机
`/proc/cmdline` 向量），只把 "Image" 换成 `qemu/fake-android.c`（打印选中的条目和 LoadOptions 后关机）。
探针条目在夹具里叫 `gk3probe+3.conf`（带启动计数，顺带测 `LoaderBootCountPath`），OneShot 写的是 `gk3probe.conf`
（systemd-boot 去掉计数后再比 id）。这个变量用 `virt-fw-vars` 写进 AAVMF 变量库，和设备上 `boot-oneshot.sh` 写的是同一个变量、同一种编码。

| 场景 | 做什么 | 判据（摘要） |
|---|---|---|
| first | OneShot → 探针 → `ResetSystem(Cold)` → 下一次启动 | 探针各节都跑完、`errors=0`、注入的按键被读到、两次缓冲区 LoadImage 都 PASS；复位后进了 default 的 `*-android-a.conf`，带 `slot_suffix=_a`；**盘上除了 `log-0.txt` 和 systemd-boot 自己的计数改名，其余逐字节不变**（misc / boot_a / boot_b / super / userdata / metadata / 主备 GPT 逐区哈希，ESP 逐文件哈希）；ESP 上的日志读回一致，以 `probe.done` 收尾 |
| second | 同一块盘、同一个变量库再跑一次 | 生成 `log-1.txt`，`log-0.txt` 不动；计数 `+2-1 → +1-2` |
| strictnx | 换 strict-NX 的 AAVMF 重跑 first | 同 first |
| broken | GPT 里 boot_b 重名、super 改名 | 报 `duplicate` / `not found`、`unique_required … NO`，跳过 boot_b 一节，其余照跑，照常复位 |
| espfull | ESP 剩余空间正好占满 | 写日志时的 `VOLUME_FULL` 被记录，只上屏幕，其余照跑，照常复位 |

**2026-10-05 的结果**（macOS 27 + colima，QEMU 10.0.13 TCG，`-cpu cortex-a76`）：

```
══ 汇总：first=PASS second=PASS strictnx=PASS broken=PASS espfull=PASS
```

first 场景的串口摘录（`tools/gk3boot/build/qemu/normal/serial-first.log`）：

```
gk3probe v0.6.1-alpha-250-g490c6947ea91-dirty-20261004  (read-only probe, docs/boot-entry-design.md E3)
watchdog: armed 60 s
key t=520 ms src=0 scan=0x0000 unicode=0x0067 shift=0x00000000 toggle=0x00
device_path: PciRoot(0x0)/Pci(0x1,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)/HD(1,GPT,825eaf3a-52b8-4a93-a747-921ecefd2ded,0x800,0x96000)
log_file: \EFI\gk3boot\probe\log-0.txt
var LoaderBootCountPath: attr=0x6 size=68 "\loader\entries\gk3probe+2-1.conf"
var LoaderEntrySelected: attr=0x6 size=28 "gk3probe.conf"
var LoaderDevicePartUUID: attr=0x6 size=74 "825EAF3A-52B8-4A93-A747-921ECEFD2DED"
whole_disk: PciRoot(0x0)/Pci(0x1,0x0)/NVMe(0x1,00-00-00-00-00-00-00-00)
gpt: disk=e6c13d1a-e678-468a-b6b6-b79f19efb0e5 entries=128 x 128 @LBA2 usable=34-995327 alt=995360 used=8 read=0.6 ms
unique_required(misc,boot_a,boot_b,super,userdata): YES
misc: p4 lba=34 size=1007 KiB read 64 KiB in 0.0 ms sha1(0-64K)=7add26f8fb6ba88b422b03111f3b5fcc39f78d9a
bcab: valid suffix="_a" nb_slot=2 merge=0 raw=5f61000042434142010200009f000e0000000000000000
would_select (NOT written): boot slot=_a active=_a fallback=0 decrement=0 (1->1)
boot_a: read 28848128 bytes in 12.3 ms (2337 MB/s), sha1(id) in 356.1 ms: OK (matches header)
EFI_USB_DEVICE_PROTOCOL(qcom d9d9ce48): absent
EFI_USBFN_IO_PROTOCOL: absent
loadimage[vendor-dp]: child saw load_options_size=64 parent=0xbef4b898 -> PASS (buffer LoadImage + StartImage + LoadOptions work)
loadimage[null-dp]: child saw load_options_size=64 parent=0xbef4b898 -> PASS (buffer LoadImage + StartImage + LoadOptions work)
probe.done errors=0 total=3558 ms
log file log-0.txt: 21541 bytes, close=SUCCESS, read-back MATCHES
gk3probe: ResetSystem(EfiResetCold)
GK3-FAKE-ANDROID booted entry="8a29534fa802480d9fbb71aa18c01d7b-android-a.conf" load_options="initrd=\8a29…\android\slot_a\ramdisk.img … androidboot.slot_suffix=_a"
```

（这些耗时是 TCG 下的，**不代表真机**：读盘走的是宿主页缓存，SHA-1 在模拟的 CPU 上算。真机数字要等 E3。）

### 9.3 gk3probe.efi 收集什么

日志是纯 ASCII 的 `键: 值` 行，节标题是 `== 名字 [t=毫秒] ==`，每节结束 Flush 一次。屏幕与文件内容相同，
只有细节行（内存图逐条、GPT 类型 GUID、GOP 的非当前模式、各 BlockIo 句柄、boot.img cmdline 全文）只写进文件。

| 节 | 内容 | 对应设计稿 |
|---|---|---|
| 头 | 版本、CNTFRQ、RTC、看门狗（`SetWatchdogTimer(60 s)`）、LoadOptions | E3、E6 前置 |
| keys | **最先做**（看 systemd-boot 之后 ConIn 里还剩什么，U3）：ConIn / ConInEx 是否存在、每个输入句柄的设备路径；逐个物理设备轮询 `ReadKeyStroke(Ex)`，不阻塞，默认扫 2 秒，记录 ScanCode / Unicode / Shift / Toggle 和来源 | E3 的键码、INST-18 |
| image | LoadedImage（基址、大小、FilePath、DeviceHandle 的设备路径）、ESP 上的 `EFI_PARTITION_INFO` | §2.1 |
| firmware | 厂商、版本、UEFI 版本、全部配置表（认得的打出名字：DTB、LinuxRandomSeed、MemoryAttributesTable…）、SMBIOS 0/1 型 | §2.1、§2.5 随机种子 |
| efi variables | 只读 `GetVariable`：`LoaderBootCountPath` / `LoaderEntrySelected` / `LoaderDevicePartUUID` 等 16 个 Loader 变量，`SecureBoot` / `SetupMode` / `BootCurrent` / `BootOrder` 与各 `Boot####`（描述 + 设备路径）| E3、D1 的一部分 |
| disk | ESP 的设备路径去掉 HD 节点就是整盘（在全部 BlockIo 里找，要求恰好一个）；用 libgk3core 解析主 GPT；misc / boot_a / boot_b / super / userdata（另记 metadata / esp）各自唯一；自身 HD 节点与 GPT 项核对 | §4.2 第 1 步 |
| misc | 读 0–64 KiB 的耗时与 SHA-1（可与 Android 里 `dd` 的结果对照）；解码 BCB / BCAB / GK3 / VAB；**在副本上**算"入口会怎么选"（不写回） | §4.2 第 2、7 步 |
| boot_a / boot_b | 头、id、cmdline；整份读入的耗时（MB/s）与复算 SHA1(id) 的耗时；kernel 是否以 `MZ`+`zimg` 开头 | §4.3.1 的 < 0.5 s 目标 |
| display | GOP 句柄与模式表、当前模式、帧缓冲；ConOut 文本模式；用 `OutputString` 打一行中文和破折号，看是否返回 `EFI_WARN_UNKNOWN_GLYPH` | E3、E-K9（不切模式） |
| memory map | 描述符数、按类型汇总、最大空闲块、最高地址；逐条写进文件 | E3 |
| protocols | 只调用 `LocateHandleBuffer`，**不调用协议本身**：`EFI_USB_DEVICE_PROTOCOL`（d9d9ce48，高通）、`EFI_USBFN_IO`、USB_IO、USB2_HC、RNG、TCG2、DT_FIXUP、MEMORY_ATTRIBUTE | §2.1 USB、E4u 前置 |
| LoadImage | 用缓冲区 `LoadImage` 内嵌的 5 KiB 测试 PE（`probe/child.c`），共两次：厂商设备路径（照 systemd-boot 的做法）/ 空设备路径；`StartImage` 前把 `LoadOptions` 指向一个上下文，子镜像往里写 `GK3CHILD-OK …` 后返回 `EFI_SUCCESS` | **E4 门槛的前置**（§2.2：缓冲区 LoadImage 在本机从没跑过） |
| done | 错误计数、总耗时；关文件、读回比对（只上屏幕）；停留 `hold` 秒；`ResetSystem(EfiResetCold)` | E-K1 |

**纪律**：只读——块设备包装连写回调都不给，变量只调 `GetVariable`；唯一的写是自己的日志文件，目录不存在时才新建。
任何一步出错就记一行 `!! …` 然后继续；绝不把错误码 return 给固件；风险最大的 LoadImage 放在最后，此前的日志已经 Flush。
万一 `ResetSystem` 返回，就原地等 60 秒的看门狗。

**LoadOptions**（条目的 `options` 行）：`gk3probe.hold=<秒>`（复位前停留，默认 3，最大 30）、`gk3probe.keyscan=<毫秒>`
（默认 2000，最大 10000）、`gk3probe.noreset=1`（返回 systemd-boot，**只用于 QEMU 调试**：真机上会停在不倒计时的菜单里）。

### 9.4 上机步骤（E3；这一轮没有上机，由用户执行）

前提：用户在场、能长按电源键（E-K11）；设备在 Android 里，adb 是 root（`boot-oneshot.sh` 也要求 root）。
探针二进制就是 `tools/gk3boot/build/efi/gk3probe.efi`（`test-probe.sh` 末尾会打印 sha256）。

1. **准备条目文件**。文件名**不能**匹配 `*-android-*.conf`，也**不能放进** `EFI\gaokun3\`（E-K8）；不带启动计数，
   因为 `boot-oneshot.sh` 按确切文件名检查（见下面"已知限制"）：

   ```sh
   cat > /tmp/gk3probe.conf <<'CONF'
   title      gk3probe (E3) — 只读探针
   sort-key   zzgk3probe
   efi        /EFI/gk3boot/probe/gk3probe.efi
   options    gk3probe.hold=10 gk3probe.keyscan=2000
   CONF
   ```
   标题里故意带了 `—` 和中文：systemd-boot 菜单（设备上 timeout 15 秒）出来时拍一张，就回答了 E3 的"CJK 与破折号能否显示"。
   想记录音量 / 电源 / 键盘盖的键码，就把 `keyscan` 调到 10000，等探针打出 `keyscan.begin` 后依次**短按**各键（电源键别长按）。

2. **拷到 ESP**。用私有挂载点，不要叫 `/mnt/esp`（操作禁忌 4）：

   ```sh
   adb push tools/gk3boot/build/efi/gk3probe.efi /tmp/gk3probe.conf /data/local/tmp/
   adb shell 'set -e; M=/mnt/gk3probe_esp; mkdir -p $M; mount -t vfat /dev/block/by-name/esp $M
     mkdir -p $M/EFI/gk3boot/probe
     cp /data/local/tmp/gk3probe.efi $M/EFI/gk3boot/probe/gk3probe.efi
     cp /data/local/tmp/gk3probe.conf $M/loader/entries/gk3probe.conf
     sync; sha256sum $M/EFI/gk3boot/probe/gk3probe.efi; ls $M/loader/entries/
     umount $M; rmdir $M; rm /data/local/tmp/gk3probe.efi /data/local/tmp/gk3probe.conf'
   ```
   核对 sha256 与宿主上的一致。顺便留一份对照：`adb shell 'dd if=/dev/block/by-name/misc bs=65536 count=1 2>/dev/null | sha1sum'`。
   只要两次之间没人写 misc，探针日志里的 `misc: … sha1(0-64K)=` 应该与它相同。

3. **写 OneShot**：先 `bash scripts/boot-oneshot.sh --list`，再 `bash scripts/boot-oneshot.sh gk3probe.conf`（要看到"回读一致"）。

4. **征得同意、确认有人在场后**执行 `adb reboot`。预期依次是：systemd-boot 菜单 15 秒（OneShot 已选中 gk3probe）→ 探针刷屏
   （几秒钟，最后停 10 秒供拍照）→ 冷复位 → systemd-boot → ESP default 的 Android。
   如果卡住超过 60 秒还没复位，说明看门狗没起作用（这本身就是 E6 的一个答案），长按电源键即可；OneShot 已被消费，下次开机照常进 Android。
   ⚠️ **一次只跑一轮**：华为固件里有 `BootFail count = 3, System ShutDown!`（§2.1），不清楚它会不会把"没进系统就复位"算进去；
   跑完先让 Android 完整开一次机，再跑下一轮。

5. **取日志**（只读挂载）：

   ```sh
   adb shell 'M=/mnt/gk3probe_esp; mkdir -p $M; mount -t vfat -o ro /dev/block/by-name/esp $M; ls -l $M/EFI/gk3boot/probe/'
   mkdir -p out/gk3probe-$(date +%Y%m%d) && adb pull /mnt/gk3probe_esp/EFI/gk3boot/probe/ out/gk3probe-$(date +%Y%m%d)/
   adb shell 'umount /mnt/gk3probe_esp; rmdir /mnt/gk3probe_esp'
   ```
   每跑一次多一个 `log-<n>.txt`（不覆盖）。先看末尾的 `probe.done errors=…` 和所有 `!!` 行。

6. **撤掉**：

   ```sh
   adb shell 'set -e; M=/mnt/gk3probe_esp; mkdir -p $M; mount -t vfat /dev/block/by-name/esp $M
     rm -f $M/loader/entries/gk3probe.conf; rm -rf $M/EFI/gk3boot/probe; rmdir $M/EFI/gk3boot 2>/dev/null || true
     sync; ls $M/loader/entries/; umount $M; rmdir $M'
   bash scripts/boot-oneshot.sh --clear    # 万一 OneShot 还没被消费
   ```

E3 里有几项探针**答不了**，要人来看：进固件设置 / F12 的物理按键组合（T17，在 POST 阶段，那时探针还没运行）；ConOut 的方向与可读性（拍照）；
在 UEFI 里停留 6 分钟测 EC 看门狗（探针的 60 秒看门狗会先复位，需要另做一个不设看门狗的变体）；D2 的启动项保留实验。

### 9.5 已知限制

- **QEMU 证明不了的**：HwBcdOneKey 的 `HwStartImage` 钩子对缓冲区 LoadImage 有没有影响、`EFI_USB_DEVICE_PROTOCOL`
  在不在、按键映射、竖装 GOP 帧缓冲、真实耗时 —— 这些正是 E3 要上机回答的问题。夹具里 USB device / USBFN 自然是 absent。
- 测试 PE 是 gnu-efi 编的 5 KiB 小程序，不是 zboot 内核：它证明的是"缓冲区 LoadImage + StartImage + LoadOptions 这条路在本机走得通"，
  真内核的交接（DTB 表、LoadFile2 initrd、ExitBootServices）仍要靠 E4 验证。
- 设备上的条目不带启动计数：`boot-oneshot.sh:51-53` 按文件是否存在来检查，而 OneShot 匹配的是去掉计数后的 id（这是 S11 的事）。
  所以真机日志里的 `LoaderBootCountPath` 会是 `(not set)`；计数这条路只在夹具里验证过（`+3 → +2-1 → +1-2`）。
- 60 秒看门狗在本机会不会真的复位，还不知道（E6）。
- ESP 写满时会留下一个 0 字节的 `log-<n>.txt`：建文件只占一个目录项，失败发生在第一次 Write。
- 探针二进制没有签名（Secure Boot 必须关着，设备上本来就是关的），PE 也没标 NX_COMPAT。

## 10. S5 最小版：gk3boot.efi（观察模式），E4 门槛用

设计稿 §5 S5、§6 E4、§4.12 "观察模式"。目标只有一个：**作为 systemd-boot 的非默认 efi 条目经 OneShot 进入，第一次用 H2
（缓冲区 LoadImage 真内核 + DTB 配置表 + LoadFile2 initrd + LoadOptions）真正启动 Android**，期间什么都不写。

### 10.1 做什么、不做什么

```
systemd-boot（OneShot = gk3boot-e4.conf）→ gk3boot.efi
  0 SetWatchdogTimer(120 s)；解析 options；开日志 \EFI\gk3boot\log\boot-<n>.txt
  1 自己 ESP 的设备路径去掉 HD 节点 = 整盘（恰好一个）→ 主 GPT → misc/boot_a/boot_b/super/userdata 各唯一、ESP 对得上
  2 读 misc 0–64 KiB：BCB / GK3 / BCAB / VAB 解码；gk3_select_slot 在【副本】上算；"动作模式会怎么做"只记一行（NOT written）
  3 目标槽 = gk3.slot 强制 > 决策（BOOT → 它；BCAB 无效 → gk3.hint；NOSLOT / MERGING → fail-open，执行端还没有）
  4 读 boot_<x> 整份 → header v2 → SHA1(id) → kernel 是 PE（MZ）、dtb 是 FDT、ramdisk 非空
  5 cmdline = 头 cmdline + extra_cmdline，去掉同名键后追加
        androidboot.slot_suffix=_x androidboot.bootloader=gk3boot-<ver>
        androidboot.gk3boot.event=<none|fallback|forced|bcab_invalid> androidboot.gk3boot.entry=<条目文件名>
        androidboot.gk3boot.mode=observe
  6 H2 交接（efi/boot/handoff.c）；成功不返回
  ✗ 任何一步失败 → fail-open（10.3）
```

| | 这一版 | 设计稿的完整版（S5 后续 / S6） |
|---|---|---|
| misc | 只读；块设备包装连 write 回调都没有 | 扣 tries、清 BCB、写 GK3 记录（写前算 CRC、写后读回） |
| EFI 变量 | 一个都不写（只读 `LoaderBootCountPath` / `LoaderEntrySelected`） | fail-open 写 OneShot、双系统的 Default / OneShot |
| ESP | 只写自己的日志（每次开机一份） | 正常路径零写入，只在失败时记 |
| BCB | 只分类、记"会怎么做"，照常启动（与今天的直连条目一样不消费） | 分派到执行端 |
| boot_x 坏 | fail-open | 换另一个可启动的槽（不写 misc）→ H1 → 执行端 |
| 找盘 | 只认自己 ESP 所在的盘 | 找不到时扫全部整盘，要求全局唯一 |
| `gk3.observe=1` 缺省 | 照样观察模式（这一版没有动作模式），日志里记一行 | 缺省 = 动作模式 |

**LoadOptions**：`gk3.observe=1`、`gk3.slot=a|b`（强制；决策照算照记）、`gk3.hint=a|b`（BCAB 无效时用，缺省 a）、
`gk3.hold=<秒>`（fail-open 复位前在屏幕上停留，缺省 5，最大 30）。

### 10.2 H2 交接对照（`efi/boot/handoff.c`）

照 systemd-boot 257.13（`refs/systemd-v257/src/boot/`）的**写法**重写，不拷代码（U10）；顺序与 `boot.c` 的
`image_start`（:2543-2656）一致：

| 步骤 | gk3boot | systemd-boot 257.13 |
|---|---|---|
| 内核 | 缓冲区 `LoadImage`，Vendor 媒体设备路径（自己的 GUID）；`SECURITY_VIOLATION` 时 `UnloadImage` | `linux.c:44-91`（STUB_PAYLOAD_GUID），type1 条目是 `boot.c:2574` 按文件路径 |
| DTB | 拷进 `EfiACPIReclaimMemory` 页，`InstallConfigurationTable(b1b621d5-…)`；记下原来的表，失败 / 返回时装回去（原来没有 = 删表）；有 `EFI_DT_FIXUP_PROTOCOL` 只记录不调用（本机没有，§2.1） | `devicetree.c:9-21`、`:65-107`；`boot.c:2582` |
| initrd | 先 `LocateDevicePath(LoadFile2, LINUX_EFI_INITRD_MEDIA)`，已有人装过就不装；再在新句柄上装 DevicePath + LoadFile2（BootPolicy 为真回 UNSUPPORTED，缓冲区不够回 BUFFER_TOO_SMALL） | `initrd.c:12-110`；`boot.c:2588` |
| cmdline | `LoadOptions` = UCS-2，`LoadOptionsSize` 含结尾 NUL | `linux.c:133-136`；`boot.c:2622-2624` |
| 启动 | `StartImage`；**不调 ExitBootServices**（stub 自己调，UEFI 看门狗随之关闭）；返回即失败：撤 LoadFile2、装回 DTB 表、释放页 → fail-open | `boot.c:2631`；x86 compat 入口回退（`linux.c:146-151`）arm64 用不到，没做 |

内核那一侧（Linux v7.2-rc2，**本地 refs/ 里没有 libstub，下面两处取自 git.kernel.org 原文**）：`zboot.c:35-100` 只从
LoadedImage 取 LoadOptions（不看 FilePath / DeviceHandle，所以缓冲区加载的 zboot 镜像不缺东西），解压后进
`efi_stub_common`；`efi-stub.c:172` 的 `efi_load_initrd` 先找 LINUX_EFI_INITRD_MEDIA 设备路径上的 LoadFile2。
内核 LoadedImage 的 DeviceHandle 是 NULL，所以 stub 的 `initrd=` / `dtb=` 文件加载在这条路上用不了 —— 我们也不传。

**cmdline 与今天的直连条目**：直连条目开出来的 `/proc/cmdline`（2026-10-05 实机只读读出，`test/vectors/proc-cmdline-20261005.txt`）=
`initrd=\<mid>\android\slot_a\ramdisk.img` + 头里的 cmdline + ` androidboot.slot_suffix=_a`。gk3boot 的 =
头里的 cmdline + ` androidboot.slot_suffix=_a` + 新增的四项。**去掉 systemd-boot 加的 `initrd=` 和新增四项，两者逐字节相同**
（主机单测 `test_cmdline` 与 QEMU real 场景各核一遍）。`initrd=` 是 systemd-boot 为老内核加的（`boot.c` 的 `initrd_prepare`），
内核走 LoadFile2 时用不着，设计稿 §4.3.1 也说入口不加。

### 10.3 fail-open：为什么最小版只"记日志 + 冷复位"

设计稿 §4.12 的阶梯第 1 步是"写 `LoaderEntryOneShot = <mid>-android-<槽>.conf` 再复位"。最小版**不写**，只复位，理由：

- E4 的条目本来就不是默认项：经 OneShot 进来，systemd-boot 读到 OneShot 就删掉它（`boot.c:1637-1640`），复位后自然走
  loader.conf 的 `default *-android-a.conf`，也就是今天的直连条目 —— 不写变量也能回到老路；
- 不写变量，观察模式"什么都不写"的承诺不打折扣，也不会第二次改动固件状态（NV 变量写入走的是 uefisecapp，越少越好）；
- 另一个选项"LoadImage ESP 上 `\<mid>\android\slot_<x>\Image` 走 H1"要在同一次开机里第二次装 DTB / initrd，前一次失败留下的
  状态（半装的表、已加载的镜像）都要撤干净，出错面比复位大，而它换来的只是少一次重启。

⚠️ **代价**：这一版**不能**当默认条目用。fail-open 后复位又会回到它自己，形成循环（还可能撞上华为的
`BootFail count = 3, System ShutDown!`，§2.1）。E5（观察模式设为默认）之前必须补上阶梯第 1 步。

其他兜底：看门狗 120 秒（本机会不会真的复位还没验证，E6）；`ResetSystem` 万一返回就原地等看门狗；**从不** return 给
systemd-boot（`boot.c:2971-2973` 会把错误码原样交给固件）。内核交接之后的故障不归 gk3boot 管：内核 panic 10 秒后重启
（`CONFIG_PANIC_TIMEOUT=10`），OneShot 已被消费，下一次就是直连条目；硬挂要长按电源键（与今天一样）。

**日志**：`\EFI\gk3boot\log\boot-<n>.txt`，n 从 0 递增、不覆盖（上限 1000）。纯 ASCII，屏幕上是同样的内容（细节行只进文件）。
交接前写完并**关闭**文件（不把打开的 FAT 句柄带进 ExitBootServices），交接失败回来再按路径重开、追加。
**ESP 剩余不到 1 MiB 就不写**：QEMU 夹具（AAVMF 2025.02 的 FAT 驱动）实测，在满盘上建目录返回 `VOLUME_FULL`，
却留下一个起始簇为 0（= 指回根目录）的目录项，FAT 坏掉、目录成环（夹具的 `mcopy -s` 因此递归到把容器盘写满）。
本机固件的 FAT 驱动多半是同一份 edk2 代码，所以上机步骤里**预先建好 `log` 目录**，gk3boot 在设备上从不需要建目录。
（探针 `gk3probe.efi` 也有"按需建目录"这条路，E3 上机时 ESP 有 46 MB 空余，没碰上。）

### 10.4 QEMU 夹具

```sh
colima start
bash scripts/gk3boot/test-boot.sh                    # 全部场景（约 3 分钟；real 要等 45 秒）
bash scripts/gk3boot/test-boot.sh linux-a badsha     # 只跑列出的场景
```

同一套夹具（§9.2：实机 GPT / misc 向量、systemd-boot 257.13、直连条目里的假内核），另加：

- **测试内核**：`qemu/fetch-test-kernel.sh` 第一次从 Debian 取当前的 `linux-image-*-arm64-unsigned`（带 PE 头的 EFI stub Image，
  PL011 内建），缓存在 `build/cache/linux/`；`GK3_TEST_KERNEL=` 可换。
- **测试 initramfs**：`qemu/init.c`，静态、无 libc 的 `/init`：挂 proc / sysfs，打出 `/proc/cmdline`、
  `/sys/firmware/devicetree/base/gk3,fixture-marker`、initramfs 里的标记文件、`/sys/firmware/efi` 在不在，然后关机。
- **dtb**：`qemu_run.py --dumpdtb` 导出与运行时同一套机器配置的 QEMU dtb，`fixture.py fdt-mark` 给根节点加一个每次运行都不同的
  标记属性。跑的时候 `-M virt,acpi=off`：AAVMF 这时会**自己先装一张 DTB 配置表**，内核读到我们的标记就证明 gk3boot 的表盖掉了它。
- **boot.img**：`fixture.py mkbootimg` 打 header v2（page 2048，与本机相同）；boot_b 的 cmdline 667 字节（切进 extra_cmdline），
  还带一个旧的 `androidboot.slot_suffix=_z`。
- 每个场景都做盘的前后比对（只准多出 `EFI/gk3boot/log/boot-*.txt`；misc / boot_x / super / userdata / metadata / 主备 GPT 逐区哈希），
  快照前先 `fsck.fat -n` 查 ESP。cmdline 的期望值由 `check_boot.py` 用 Python 独立再算一遍（分词、去重、追加），与 gk3boot 对拍。

| 场景 | 做什么 | 判据（摘要） |
|---|---|---|
| real | boot_a = 真 gaokun3 boot.img（`out/issues-1791053208/boot.img`）、实机 misc、options 与上机相同（`gk3.slot=a`） | 决策 `boot slot=_a`、SHA1(id) OK、cmdline 去掉新增项后与实机 `/proc/cmdline`（去掉 `initrd=`）逐字节一致、LoadImage / DTB / LoadFile2 / LoadOptions 全过；交接后它在 virt 上一行不打（没开 PL011，zboot stub 也不出声 —— **走 systemd-boot 直连条目时一模一样**，单独核过），所以用 `-d int` 看 CPU 跑进了内核虚拟地址，45 秒后停 |
| linux-a | Debian 内核 + 测试 initramfs，实机 misc（_a 已成功） | stub 打出 "Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path" / "Using DTB from configuration table" / "Exiting boot services"；`/init` 读到的 `/proc/cmdline` == gk3boot 的 LoadOptions、dtb 标记对、initrd 标记对、`/sys/firmware/efi` 在 |
| linux-b | misc 改成 _b 15/6 未成功 | 决策 `boot slot=_b`、记"会扣 _b tries 6 -> 5 (NOT written)"，**盘比对 misc 逐字节未变**；extra_cmdline 拼接、旧 slot_suffix 被换掉 |
| force-a | 同 linux-b 的 misc + `gk3.slot=a` | 决策照记 `_b`，实际启动 `_a`，`event=forced` |
| strictnx | linux-a 换 `AAVMF_CODE.secboot.strictnx.fd` | 同 linux-a |
| espfull | linux-a + ESP 一个字节都不剩 | 屏幕上 `!! log: ESP free space … not writing`，照样交接、起到 initramfs；ESP 逐文件不变、FAT 一致 |
| badsha | boot_a 的 kernel 坏一个字节（头里的 id 不变） | `!! FAIL-OPEN at boot: boot_a: SHA1(id) MISMATCH`，冷复位，下一次 systemd-boot 进默认的 `<mid>-android-a.conf`，gk3boot 只跑了一次 |
| miscerr | QEMU blkdebug 让 misc 那段盘读出 EIO（LBA 154） | `!! FAIL-OPEN at misc: read misc (p4, 64 KiB): DEVICE_ERROR`，同上 |

**2026-10-05 的结果**（macOS 27 + colima，QEMU 10.0.13 TCG，`-cpu cortex-a76`；测试内核 Debian `linux-image-6.12.111+deb13-arm64-unsigned`；
gk3boot `0.1.0-e4.g435f5b58cecb`（在提交 `435f5b5` 上构建），81655 字节，sha256 `2ee681decbda4fb1a54429332827d889722f6697b976b47f30ec70bc4a6d5843`）：

```
══ 汇总：real=PASS linux-a=PASS linux-b=PASS force-a=PASS strictnx=PASS espfull=PASS badsha=PASS miscerr=PASS
```

real 场景 gk3boot 自己的日志（`build/qemu-boot/real/boot-0.txt`，节选）：

```
gk3boot 0.1.0-e4.g435f5b58cecb  (S5 minimal, observe-only build; docs/boot-entry-design.md E4)
load_options: "gk3.observe=1 gk3.hold=1 gk3.slot=a"
disk: gpt e6c13d1a-e678-468a-b6b6-b79f19efb0e5, 8 partitions, misc/boot_a/boot_b/super/userdata unique, esp=p1  [1.9 ms]
bcb: kind=none command="" args=0
gk3rec: bad magic
would (action): first-run migration: BCB empty, set marker (NOT done)
bcab: valid  _a=15/1/ok  _b=14/0/unbootable
vab: valid merge_status=0 source=_a
decision: boot slot=_a active=_a fallback=0
would (action): no misc write (slot already successful)
slot: _a (forced by gk3.slot; decision above is boot _a)
boot_a: p5 v2 page=2048 kernel=15589888 ramdisk=13080354 dtb=173345 total=28848128 id=9274d5f8f00cd60c399721927b702eba47e885e0
boot_a: read 14.3 ms, sha1(id) 377.5 ms: OK
boot_a: kernel EFI zboot PE
cmdline(684): androidboot.flash.locked=0 … himax_hx83121a_spi.disable_pressure=0 androidboot.slot_suffix=_a
  androidboot.bootloader=gk3boot-0.1.0-e4.g435f5b58cecb androidboot.gk3boot.event=forced androidboot.gk3boot.entry=gk3boot-e4.conf androidboot.gk3boot.mode=observe
handoff: LoadImage(15589888 bytes) SUCCESS in 11 ms
handoff: dtb 173345 bytes installed as config table @0xbbaa6000 (replaced 0x0)
handoff: initrd 13080354 bytes on LINUX_EFI_INITRD_MEDIA LoadFile2 (handle 0xbef1b618)
handoff: LoadOptions 1370 bytes
gk3boot.result=handoff t=444 ms (log closed before StartImage)
```
之后 QEMU `-d int` 里第一次出现内核虚拟地址的异常：`ELR 0xffff8000800eae94`（直连条目开同一个内核，停在同一类地址）。

linux-b 场景（串口）：

```
decision: boot slot=_b active=_b fallback=0
would (action): write misc+0x800: _b tries 6 -> 5 (NOT written; new bcab 5f6200004243414201020000 9e005f00 … de4b3b87)
handoff: dtb 7804 bytes installed as config table @0xbeef3000 (replaced 0x47ef8000)
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path
EFI stub: Using DTB from configuration table
EFI stub: Exiting boot services...
GK3-INIT cmdline=console=ttyAMA0 panic=-1 androidboot.hardware=gaokun3 gk3pad=xxx…(560 个 x) gk3fixture=linux-b androidboot.slot_suffix=_b
  androidboot.bootloader=gk3boot-0.1.0-e4.g435f5b58cecb androidboot.gk3boot.event=none androidboot.gk3boot.entry=gk3boot-e4.conf androidboot.gk3boot.mode=observe
GK3-INIT dt_marker=gk3boot-dtb-b-8a5e71b27d5d
GK3-INIT initrd_marker=gk3-initrd-8a5e71b27d5d
GK3-INIT efi=present
```
（boot.img 里那个旧的 `androidboot.slot_suffix=_z` 不见了；盘比对 misc 逐字节未变。）

badsha / miscerr（串口）：

```
!! FAIL-OPEN at boot: boot_a: SHA1(id) MISMATCH: header 725b2303…, computed b7da5f0c…
GK3-FAKE-ANDROID booted entry="8a29534fa802480d9fbb71aa18c01d7b-android-a.conf" load_options="initrd=\8a29…\android\slot_a\ramdisk.img …"
!! FAIL-OPEN at misc: read misc (p4, 64 KiB): DEVICE_ERROR
GK3-FAKE-ANDROID booted entry="8a29534fa802480d9fbb71aa18c01d7b-android-a.conf" …
```

（耗时都是 TCG 下的，不代表真机；E3 在真机上量过 boot.img 读 23.5 ms、SHA1 139 ms。）

### 10.5 上机步骤（E4；这一轮没有上机，由用户执行）

前提：**征得同意、用户在场、能长按电源键**（E-K11）；设备在 Android 里，`adb root` 可用（`boot-oneshot.sh` 要 root）；
ESP 用私有挂载点（不叫 `/mnt/esp`）。二进制就是 `tools/gk3boot/build/efi/gk3boot.efi`（`test-boot.sh` 末尾打印 sha256；
版本串里不该有 `.dirty`）。以下 `D=out/gk3boot-e4-$(date +%Y%m%d)`。

1. **留基线**（只读，直连条目开的这一次）：

   ```sh
   mkdir -p $D
   adb shell cat /proc/cmdline > $D/cmdline-direct.txt
   adb shell 'getprop | grep -E "ro\.boot\.|ro\.bootloader"' > $D/props-direct.txt
   adb shell 'dmesg | grep -iE "efi|pstore|kaslr|random"' > $D/dmesg-efi-direct.txt
   adb shell 'dmesg | grep -c "avc:"' > $D/avc-direct.txt
   adb shell 'dd if=/dev/block/by-name/misc bs=65536 count=1 2>/dev/null | sha1sum' > $D/misc-before.sha1
   ```
   开机耗时基线：`t0=$(date +%s); adb reboot; adb wait-for-device; until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ]; do sleep 1; done; echo $(( $(date +%s) - t0 ))`
   （这次重启本身也要征得同意；两边都含 systemd-boot 菜单的 15 秒，可以直接相减。）

2. **条目文件**。文件名**不能**匹配 `*-android-*.conf`（否则会被 loader.conf 的 default 选中，也会被安装器的停用逻辑误伤，E-K8），
   efi **不放进** `EFI\gaokun3\`；不带启动计数（`boot-oneshot.sh` 按确切文件名检查）；title 只用 ASCII（§4.13）：

   ```sh
   cat > /tmp/gk3boot-e4.conf <<'CONF'
   title      gk3boot E4 (observe)
   sort-key   zzgk3boot
   efi        /EFI/gk3boot/e4/gk3boot.efi
   options    gk3.observe=1 gk3.slot=a gk3.hold=10
   CONF
   ```
   `gk3.slot=a`：设备上 misc 本来就选 `_a`（_a 15/1/已成功，_b 不可启动），强制只是保险 —— 决策逻辑万一有错也只会记在日志里，
   不会把机器带到 `_b`（`_b` 在 VAB 合并后已经起不来，CLAUDE.md "现在设备上跑的是什么"）。`gk3.hold=10`：fail-open 时屏幕停 10 秒好拍照。

3. **拷到 ESP**，并**预先建好日志目录**（10.3：不让固件的 FAT 驱动在设备上建目录）：

   ```sh
   adb push tools/gk3boot/build/efi/gk3boot.efi /tmp/gk3boot-e4.conf /data/local/tmp/
   adb shell 'set -e; M=/mnt/gk3boot_esp; mkdir -p $M; mount -t vfat /dev/block/by-name/esp $M
     mkdir -p $M/EFI/gk3boot/e4 $M/EFI/gk3boot/log
     cp /data/local/tmp/gk3boot.efi $M/EFI/gk3boot/e4/gk3boot.efi
     cp /data/local/tmp/gk3boot-e4.conf $M/loader/entries/gk3boot-e4.conf
     sync; sha256sum $M/EFI/gk3boot/e4/gk3boot.efi; ls $M/loader/entries/; df -h $M
     umount $M; rmdir $M; rm /data/local/tmp/gk3boot.efi /data/local/tmp/gk3boot-e4.conf'
   ```
   核对 sha256 与宿主上的一致；ESP 剩余要远大于 1 MiB（现在约 46 MB）。

4. **写 OneShot**：`bash scripts/boot-oneshot.sh --list`，再 `bash scripts/boot-oneshot.sh gk3boot-e4.conf`（要看到"回读一致"）。

5. **征得同意、确认有人在场后** `adb reboot`，同时按第 1 步的办法计时。预期：systemd-boot 菜单 15 秒（高亮 "gk3boot E4 (observe)"）→
   gk3boot 打二十来行（不到 1 秒）→ 内核 → Android 正常开机。
   - 屏幕上出现 `!! FAIL-OPEN at …`：停 10 秒后自己冷复位，进直连条目，**不用动手**；拍下那一行。
   - 停在 UEFI 超过 120 秒不动：看门狗没起作用（这本身是 E6 的答案），长按电源键；OneShot 已被消费，下次就是直连条目。
   - 交接后内核 panic：10 秒后自己重启，进直连条目。
   - ⚠️ 一次只跑一轮：华为固件的 `BootFail count = 3`（§2.1）是否把"没进系统就复位"算进去还不清楚；fail-open 过一次，就先让直连条目完整开一次机。

6. **在 Android 里核对**（E4 的判据）：

   ```sh
   adb shell cat /proc/cmdline > $D/cmdline-gk3boot.txt
   diff <(tr ' ' '\n' < $D/cmdline-direct.txt) <(tr ' ' '\n' < $D/cmdline-gk3boot.txt)
   ```
   **只应**多出 `androidboot.bootloader=gk3boot-0.1.0-e4.g…`、`androidboot.gk3boot.event=forced`、`androidboot.gk3boot.entry=gk3boot-e4.conf`、
   `androidboot.gk3boot.mode=observe`，少掉 `initrd=\…\ramdisk.img`；其余（含 `androidboot.slot_suffix=_a`）一行不差。

   | 看什么 | 怎么看 | 应该是 |
   |---|---|---|
   | 槽位 | `adb shell getprop ro.boot.slot_suffix`；`adb shell bootctl get-current-slot` | `_a`；`0`（HAL 的 `CHECK(impl_.Init())` 没崩，§2.2） |
   | bootloader | `adb shell getprop ro.bootloader`；`getprop \| grep ro.boot.gk3boot` | `gk3boot-0.1.0-e4.g…`；`mode=observe`、`event=forced`、`entry=gk3boot-e4.conf` |
   | 走的是哪个条目 | `bash scripts/boot-oneshot.sh --list` | `LoaderEntrySelected = gk3boot-e4.conf`（顺带证明 efivarfs 照常可用） |
   | HAL / avc | `adb logcat -b all -d \| grep -iE "bootcontrol\|boot_control"`；`dmesg \| grep -c "avc:"` | 没有 CHECK 失败 / tombstone；avc 数与基线同量级 |
   | EFI / pstore / RNG | `adb shell 'dmesg \| grep -iE "efi\|pstore\|kaslr\|random"'` 与 `$D/dmesg-efi-direct.txt` 对比；`ls /sys/firmware/efi /sys/fs/pstore` | 与直连条目开的那次一致（随机种子表由 systemd-boot 在启动 gk3boot 之前装好，§2.5） |
   | misc 没被写 | 再算一次 misc 0–64 KiB 的 sha1，与 `$D/misc-before.sha1` 比 | 相同（`_a` 已标成功，HAL 这次也不会写；不同就用 `gk3-misc dump` 看是谁改了哪里） |
   | 开机耗时 | 第 5 步的计时减第 1 步的基线；gk3boot 日志末行 `gk3boot.result=handoff t=… ms` | 差值在 1 秒以内（E3 实测：boot.img 读 23.5 ms + SHA1 139 ms） |

7. **取日志**（只读挂载）：

   ```sh
   adb shell 'M=/mnt/gk3boot_esp; mkdir -p $M; mount -t vfat -o ro /dev/block/by-name/esp $M; ls -l $M/EFI/gk3boot/log/'
   adb pull /mnt/gk3boot_esp/EFI/gk3boot/log/ $D/
   adb shell 'umount /mnt/gk3boot_esp; rmdir /mnt/gk3boot_esp'
   ```
   先看 `decision:`（应为 `boot slot=_a active=_a fallback=0`）、`would (action):` 几行、`boot_a: read … sha1(id) …: OK`、
   `handoff:` 几行和末行 `gk3boot.result=handoff`；有 `!!` 行就是失败点。

8. **撤掉**：

   ```sh
   adb shell 'set -e; M=/mnt/gk3boot_esp; mkdir -p $M; mount -t vfat /dev/block/by-name/esp $M
     rm -f $M/loader/entries/gk3boot-e4.conf; rm -rf $M/EFI/gk3boot/e4 $M/EFI/gk3boot/log
     rmdir $M/EFI/gk3boot 2>/dev/null || true
     sync; ls $M/loader/entries/; umount $M; rmdir $M'
   bash scripts/boot-oneshot.sh --clear    # 万一 OneShot 还没被消费
   ```
   撤之前先把日志取回来（第 7 步）。

E4 通过后的下一步是 E5（观察模式当开发机默认、带 `+3` 计数连开 ≥10 次）—— **之前必须先补 fail-open 阶梯第 1 步**（10.3）。

### 10.6 已知限制与风险

- **只有观察模式**：不扣 tries、不消费 BCB、不写 GK3 记录 —— 自动回滚（G6）这一版还没有。动作模式的写盘路径要另做断电注入测试（§8）。
- **fail-open 只复位**（10.3），所以**不能当默认条目**；boot_x 的 SHA1 不对时也不换槽、不走 H1，直接 fail-open。
- **真 zboot 内核在 QEMU 里只能证明"进了内核虚拟地址"**：它在 virt 上没有串口驱动，EFI stub 在这里也不打字（直连条目同样如此）；
  stub 用的是不是我们的 DTB / initrd，只在 Debian 内核上看到了。本机上的完整验证就是 E4 本身。
  E3 证明了 `HwStartImage` 钩子不拦 5 KiB 的缓冲区 PE；15 MB 的 zboot 内核走同一个钩子，没有理由不同，但没有实测。
- 观察模式每次开机都写一份日志（与设计稿"正常路径对 ESP 零写入"不同，动作模式要改成只在失败时写）；n 到 1000 就不再写。
- `event` 多了两个设计稿没列的值：`forced`（gk3.slot 强制）、`bcab_invalid`（按 hint 启动）。
- 内核 LoadedImage 的 DeviceHandle 是 NULL：stub 的 `initrd=` / `dtb=` 文件加载在这条路上不可用（我们也不用）。
- 不调 `EFI_DT_FIXUP_PROTOCOL`（本机没有；systemd-boot 有就调）。
- QEMU 里的耗时（SHA-1 在 TCG 上 0.4–0.5 秒）不代表真机。
- 设备上 `boot_a` 的 id（`c56a7f84…`，E3 日志）与 `out/issues-1791053208/boot.img`（`9274d5f8…`）不同（ramdisk 差几百字节），
  头里的 cmdline 相同；real 场景用的是后者，所以 SHA1 一项在设备上要以 E4 日志为准（E3 已在设备上复算 OK）。
- gk3boot 没签名、PE 没标 NX_COMPAT，Secure Boot 必须关着（设备上本来就关着）。

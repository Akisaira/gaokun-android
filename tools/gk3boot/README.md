# gk3boot —— 统一启动入口

设计稿：[`docs/boot-entry-design.md`](../../docs/boot-entry-design.md)（方案 Y，U1–U11 按建议采纳，U2 = C）。
这个目录现在只有实施步骤 **S2** 的产物：决策核心 `libgk3core` 和它的主机测试，外加只读 CLI `gk3-misc`。
`gk3boot.efi`（S5）、执行端（S7）、QEMU 夹具（S3）都还没开始。

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
- QEMU / AAVMF 夹具（S3）、`gk3boot.efi` 本体（S5）、执行端（S7）；
- 在 misc 写入之间断电注入的测试要等 QEMU 夹具；
- Linux 静态链接版（执行端）只证明了能 freestanding 编译，还没有真正链接成 aarch64 静态二进制（本机没有交叉链接器）。

# gk3boot —— 统一启动入口

设计稿：[`docs/boot-entry-design.md`](../../docs/boot-entry-design.md)（方案 Y，U1–U11 按建议采纳，U2 = C）。
这个目录现在有实施步骤 **S2** 的产物：决策核心 `libgk3core` 和它的主机测试，外加只读 CLI `gk3-misc`；
以及 **S3 / S4**：aarch64 UEFI 工具链（gnu-efi）、QEMU + AAVMF + systemd-boot 257.13 夹具、只读探针 `gk3probe.efi`（§9）。
`gk3boot.efi`（S5）、执行端（S7）还没开始。

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
│  └─ probe/                gk3probe.efi（S4 / E3 只读探针）+ 内嵌的测试 PE child.c
├─ qemu/                    QEMU 夹具（§9.2）：fixture.py 造盘 / 快照 / 比对 / 写变量，qemu_run.py 无头跑，
│                           check_probe.py 判 PASS/FAIL，run-tests.sh 串起来；fake-android.c 冒充直连条目的内核
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
- `gk3boot.efi` 本体（S5）、执行端（S7）；QEMU 夹具（S3）已就位（§9），S5 往里加场景即可；
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

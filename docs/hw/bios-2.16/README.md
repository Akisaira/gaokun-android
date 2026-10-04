# BIOS 2.16 拆包：清单、工具与复现步骤

统一启动入口设计稿（[`docs/boot-entry-design.md`](../../boot-entry-design.md) §2.1）里关于固件的结论
（QcomBds 的启动选择、UsbDevice / UsbConfig 协议、NVMe 没有 EraseBlock、ButtonsDxe、度量……）
都来自对本机 BIOS 2.16 升级包的离线拆包和静态分析。这一页把**怎么拆、拆出来是什么、用什么工具看**留档，
以便任何人在任何时候从同一个官方安装包得到逐字节相同的结果。

> ⚠️ **固件本身不入库**：安装包和拆出来的 DXE 模块都是华为 / 高通的专有二进制（`.gitignore` 的固件一节同理，
> 见 [`NOTICE`](../../../NOTICE)）。入库的只有：拆包脚本、分析脚本、按模块列出的清单（名字、GUID、大小、sha256、depex）。

## 1. 来源

| 项 | 值 |
|---|---|
| 文件 | `Gaokun_8CX_BIOS_P02-02W-06F_2.16.exe`（华为给 GK-W7X 发的 Windows 版 BIOS 升级程序，NSIS 安装包） |
| 大小 | 6,047,152 字节 |
| sha256 | `b24abe76148bed32e3add10827701025cb917e216a359861e6f57f0f9797d1a6` |
| 本仓取得途径 | `refs/matebook-e-go-linux/drivers/`（Git LFS；clone 下来只是指针，指针里的 oid 就是上面的 sha256） |
| 华为官网下载页 | 未核实（社区仓库保存的是同名安装包；以 sha256 为准） |

**确实是本机这一版**（2026-10-04 核实，见 `docs/boot-entry-design.md` 的固件摸底）：
实机 `/sys/firmware/efi/esrt/entries/entry0/fw_class` = `82315653-fe98-4014-82cf-ef099fa9357c`，
与 capsule 里的 `UpdateImageTypeId` 相同；`fw_version` 131094 = `0x20016`，与 capsule 里厂商头的版本字段相同；
DMI 读出 2.16、2023-01-31。⚠️ 文件名里的 `8CX` 指 8cx Gen 3（gaokun3）；同目录下的
`Gaokun_8C_BIOS_…_2.17.exe` 是另一款机器（8cx Gen 2）的，不要拿错（`docs/hw-inventory.md` §0.1、#120 §4）。

## 2. 复现

```sh
bash scripts/clone-refs.sh matebook-e-go-linux
git -C refs/matebook-e-go-linux lfs pull --include 'drivers/Gaokun_8CX_BIOS_P02-02W-06F_2.16.exe'
shasum -a 256 refs/matebook-e-go-linux/drivers/Gaokun_8CX_BIOS_P02-02W-06F_2.16.exe   # 必须等于上表

python3 docs/hw/bios-2.16/tools/extract.py \
    refs/matebook-e-go-linux/drivers/Gaokun_8CX_BIOS_P02-02W-06F_2.16.exe  out/bios-2.16
diff out/bios-2.16/stages.tsv   docs/hw/bios-2.16/stages.tsv
diff out/bios-2.16/manifest.tsv docs/hw/bios-2.16/manifest.tsv        # 两个 diff 都应为空
```

`extract.py` 只用 Python 3 标准库（`lzma` / `zlib` / `hashlib`），不需要 7-Zip、UEFITool、binwalk。
它在每一层都断言结构，认不出就停下报错，不猜。2026-10-05 用它重拆一遍，导出的 269 个 `.efi` / `.depex`
与设计稿摸底时（scratchpad 手工拆的）逐个 sha256 相同，另外多导出了 FD 里 SEC 的 TE 映像。

## 3. 拆包链（[`stages.tsv`](stages.tsv) 里有每层的大小和 sha256）

| # | 层 | 怎么认 / 怎么拆 |
|---|---|---|
| 1 | NSIS 安装包 | firstheader `EF BE AD DE "NullsoftInst"`，**非 solid**、每块独立 LZMA（props `5d`、字典 8 MiB）。共 16 块：头、若干 x86/x64 PE（升级程序本体）、一张 bmp、一个 bat，以及第 6 块的 capsule |
| 2 | FMP capsule | `EFI_CAPSULE_HEADER`（GUID `6dcbd5ed-…-d92a`，HeaderSize 0x20，Flags 0x50000）→ `EFI_FIRMWARE_MANAGEMENT_CAPSULE_HEADER` v1（0 个驱动、1 个载荷）→ ImageHeader **v2**（UpdateImageTypeId `82315653-…`，ImageSize 8,743,702，VendorCodeSize 178,208）→ `EFI_FIRMWARE_IMAGE_AUTHENTICATION`（MonotonicCount 2，WIN_CERT_UEFI_GUID / PKCS7，830 字节）→ **16 字节厂商头 `MSS1`**（u32 头长 0x10 + 两个 u32 都是 `0x00020016`；字段含义是推断）→ FV |
| 3 | capsule FV | FFS2；RAW 文件 `0a85a45e-915f-49db-8bd5-5337861f8082` 里是一个 **aarch64 ELF**（XBL 的 UEFI 段，字符串里有构建路径 `Build_Gen3_XBL_V_FLASH/…/SocPkg/Makena`）。同一个 FV 里还有 6 个别的固件文件（其他 ELF、一个 FAT 镜像等，本次没展开） |
| 4 | ELF | 15 个程序头；**VA `0x9f000000`、6 MiB 的 PT_LOAD** 就是 UEFI FD 的 FV |
| 5 | FD FV | 4 个文件：PAD、SEC（TE 映像）、`uefiplat.cfg`（内存图等平台配置）、`9e21fd93-…`（FV_IMAGE 容器） |
| 6 | 容器 | 一个 GUIDED 段，GUID `1d301fe9-be79-4353-91c2-d23bc959ae0c`，内容是 **gzip**（高通的压缩段，不是 edk2 标准的 LZMA） |
| 7 | 段流 → DXE FV | gunzip 出 16,031,752 字节的段流：4 字节 RAW 填充段 + FV image 段 → **DXE FV（176 个文件）**：1 个 DXE_CORE、151 个 DRIVER、4 个 APPLICATION、20 个 FREEFORM（面板 xml、bmp、`BDS_Menu.cfg`、`SecParti.cfg`、`uefipil.cfg`、`QcomChargerCfg.cfg` 等） |

## 4. 清单：[`manifest.tsv`](manifest.tsv)

每行一个 FFS 文件（FD FV 4 个 + DXE FV 176 个）：所在 FV、偏移、GUID、类型、UI 名、文件大小、
映像类型（PE32/TE）、映像大小、**映像 sha256**、depex 原文（hex，用 `tools/scan.py` 解码）。
与设计稿直接相关的几行（全表见文件）：

| 模块 | GUID | 设计稿里怎么用到 |
|---|---|---|
| QcomBds | `5a50aa81-c3ae-4608-a0e3-41a2e69baf94` | 启动选择、5 分钟看门狗、华为 BootFail 计数（§2.1） |
| HwBcdOneKey | `a1124b16-43f6-4b90-a19a-c006e54500af` | `HwStartImage` 钩子（T1） |
| SecurityDxe / MeasureBootDxe / TrEEDxe | `5e0eae60-…` / `553c050b-…` / `59cc11dc-…` | 镜像度量（§2.1、T11） |
| PartitionDxe / NvmExpressDxe | `1fa1f39e-…` / `5be3bdf4-…` | 自动修备份 GPT；NVMe 分区上没有 EraseBlock |
| UsbfnDwc3Dxe / UsbDeviceDxe / UsbConfigDxe / UsbInitDxe / UsbMsdDxe | `94f8a6a7-…` / `3299a266-…` / `cd823a4d-…` / `0a134f0e-…` / `5af77f10-…` | UEFI 内 USB 外设栈（1.x 的 E4u） |
| ButtonsDxe | `5bd181db-0487-4f1a-ae73-820e165611b3` | 音量 / 电源键（T3） |
| RotateScreen | `83ec3fc9-cb74-4b2b-89b9-e98f0972f2a8` | 虚拟横屏 GOP 模式 |
| WatchdogTimer / HwOpenWdtDxe / QcomWDogDxe | `f099d67f-…` / `4938dac6-…` / `040e1e61-…` | UEFI / EC 看门狗（T4） |
| ResetRuntimeDxe | `3ae17db7-3cc5-4b89-9304-9549211057ef` | EFI_RESETREASON 的提供方（T14） |
| RngDxe | `b0d3689e-11f8-43c6-8ece-023a29cec35b` | EFI_RNG（KASLR 种子） |

## 5. 分析工具（[`tools/`](tools/)）

| 脚本 | 作用 |
|---|---|
| `extract.py` | 上面的拆包链，输出 `stages.tsv`、`manifest.tsv`、`pe/`、`raw/`、`stage/` |
| `guiddb.py [refs]` | 扫 `refs/edk2`、`refs/clo-abl-5.0/QcomModulePkg`、`refs/systemd-v257/src/boot`、`refs/gbl` 里的 GUID 定义，生成 `guiddb.json`（GUID → 名字 + `文件:行号`；不入库） |
| `scan.py <out>/pe [模块…]` | 每个 `.efi` 里出现了哪些已知 GUID（字节扫描）+ depex 解码 |
| `pe.py <efi> xs <串> [1]` | 找字符串（`1` = UTF-16）的 adrp/add 交叉引用和所在函数；`dis <rva> [n]` 带注释反汇编（需要 `pip install capstone`） |
| `xr2.py <efi> <串…>` | 全 `.text` 线性扫一遍，列出引用这些字符串的位置 |
| `xs.sh <efi> <串…>` | 对每个串跑 `pe.py xs`（ASCII 与 UTF-16 各一次） |
| `str.py` / `allstr.py <正则> <文件…>` | 抽字符串（ASCII + UTF-16），`str.py` 带一层噪声过滤 |

⚠️ 字节扫描只能说明"这个 GUID 的 16 字节出现在映像里"，分不出提供方和使用方；设计稿里"安装了某协议"
这类结论都另外看过调用点（`pe.py dis`）。静态分析的结论在上机（E3/E4/E4u）之前一律只算推断。

## 6. 本次拆包顺带看到的

- `uefiplat.cfg` 在 FD FV 里（不在 DXE FV 里），开头声明 `UnusableDDRMemoryStartAddr = 0x80000000`、
  `UnusableDDRMemorySizeAtBeginning = 0x600000`，后面是完整的 `[MemoryMap]`。内核拿到的内存布局来自
  固件按这张表建的 EFI 内存图（设计稿 §2.2 说 dtb 的 `/memory` 是空的），交接必须走 EFI stub 这一条与此一致。
- FD FV 的 SEC 是 TE 映像（不是 PE32），导出为 `pe/8af09f13-….te`。

/*
 * gk3efi —— gk3boot 各 EFI 程序（gk3probe.efi、以后的 gk3boot.efi）共用的 UEFI 侧小工具。
 *
 * 只用 gnu-efi 的【头文件】（类型、协议结构体）和 crt0 / 自重定位（libgnuefi.a），
 * 不链接 libefi：GUID 一律在这里自己定义（出处是 refs/edk2 与 refs/systemd-v257 的行号），
 * 格式化、设备路径转文字也自己写 —— 这样不随 gnu-efi 版本里 lib 的命名漂移，
 * 以后入口也能整块搬过去（设计稿 §4.1）。
 *
 * 约束同 libgk3core：不调 libc；内存只从 BS->AllocatePool / AllocatePages 来。
 */
#ifndef GK3EFI_H
#define GK3EFI_H

#include <efi.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "gk3core.h"

/* ------------------------------------------------------------------ 全局 */

extern EFI_SYSTEM_TABLE *gk3_st;
extern EFI_BOOT_SERVICES *gk3_bs;
extern EFI_RUNTIME_SERVICES *gk3_rt;
extern EFI_HANDLE gk3_image;

void gk3efi_init(EFI_HANDLE image, EFI_SYSTEM_TABLE *st);

/* ------------------------------------------------------------------ GUID（出处见 gk3efi.c） */

extern const EFI_GUID gk3_guid_loaded_image;
extern const EFI_GUID gk3_guid_device_path;
extern const EFI_GUID gk3_guid_block_io;
extern const EFI_GUID gk3_guid_simple_fs;
extern const EFI_GUID gk3_guid_file_info;
extern const EFI_GUID gk3_guid_text_in;
extern const EFI_GUID gk3_guid_text_in_ex;
extern const EFI_GUID gk3_guid_gop;
extern const EFI_GUID gk3_guid_partition_info;
extern const EFI_GUID gk3_guid_usb_device;     /* 高通 EFI_USB_DEVICE_PROTOCOL（ABL EFIUsbDevice.h） */
extern const EFI_GUID gk3_guid_usbfn_io;
extern const EFI_GUID gk3_guid_usb_io;
extern const EFI_GUID gk3_guid_usb2_hc;
extern const EFI_GUID gk3_guid_rng;
extern const EFI_GUID gk3_guid_tcg2;
extern const EFI_GUID gk3_guid_dt_fixup;
extern const EFI_GUID gk3_guid_memory_attribute;
extern const EFI_GUID gk3_guid_global_var;
extern const EFI_GUID gk3_guid_loader;         /* systemd-boot 的厂商 GUID */
extern const EFI_GUID gk3_guid_smbios;
extern const EFI_GUID gk3_guid_smbios3;

bool gk3_guid_eq(const EFI_GUID *a, const EFI_GUID *b);
/* 已知配置表 / 协议 GUID 的名字；不认识返回 NULL */
const char *gk3_guid_name(const EFI_GUID *g);

/* ------------------------------------------------------------------ libc 的替身 */

/* 编译器会为结构体初始化 / 拷贝自己生成这几个调用（-ffreestanding 也挡不住），必须有定义 */
void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);

size_t gk3_strlen(const char *s);
size_t gk3_strlen16(const CHAR16 *s);

/* ------------------------------------------------------------------ 格式化（vsnprintf 子集） */

/* 支持 %% %c %s %d %i %u %x %X %p，长度修饰 l / ll / z，标志 - 0，宽度（数字或 *），
 * 精度只用于 %s（.N / .*）。总是 NUL 结尾，返回"本来要写"的长度（同 C99）。 */
int gk3_vsnprintf(char *out, size_t cap, const char *fmt, va_list ap);
int gk3_snprintf(char *out, size_t cap, const char *fmt, ...) __attribute__((format(printf, 3, 4)));

const char *gk3_efi_strerror(EFI_STATUS st);

/* ------------------------------------------------------------------ 计时（ARM 通用定时器） */

uint64_t gk3_ticks(void);
uint64_t gk3_tick_hz(void);
/* 从 t0 到现在的微秒；频率读不出来（0）时返回 0 */
uint64_t gk3_us_since(uint64_t t0);

/* ------------------------------------------------------------------ 日志 */

/* 一份内存里的 UTF-8 文本缓冲：每一行同时（可选）打到 ConOut，并按需追加进 ESP 上的文件。
 * 文件 sink 失败只记一次、之后不再尝试 —— 写盘失败绝不能让程序停下。 */
typedef struct {
    char *buf;
    size_t len, cap;
    bool truncated;
    EFI_FILE_PROTOCOL *file;     /* NULL = 还没有文件 sink */
    size_t synced;               /* 已写进文件的字节数 */
    bool file_failed;
    EFI_STATUS file_err;
    bool screen;                 /* 是否打到 ConOut */
} gk3_log;

extern gk3_log gk3_lg;

void gk3_log_init(size_t cap);
/* 屏幕 + 文件 */
void gk3_logf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
/* 只进文件（细节：内存图逐条、GPT 逐项等） */
void gk3_logd(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
/* 只上屏幕（不进文件） */
void gk3_screenf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
/* 把还没写进文件的部分写进去并 Flush；没有文件 sink 时什么也不做 */
void gk3_log_sync(void);

/* ------------------------------------------------------------------ 字符串转换 */

/* UCS-2 → ASCII（非 ASCII 记成 '?'），最多 n 个 CHAR16（遇 NUL 停）。out 总是 NUL 结尾 */
void gk3_ucs2_to_ascii(const CHAR16 *s, size_t n, char *out, size_t cap);
/* ASCII / UTF-8 → UCS-2（\n → \r\n；UTF-8 多字节解码到 BMP），out 总是 NUL 结尾 */
void gk3_utf8_to_ucs2_crlf(const char *s, CHAR16 *out, size_t cap);

/* ------------------------------------------------------------------ 设备路径 */

size_t gk3_dp_size(const EFI_DEVICE_PATH_PROTOCOL *dp);            /* 含结束节点；坏路径返回 0 */
/* 转成接近 UEFI 规范文字形式的串（不认识的节点打成 Path(t,s,hex)），总是 NUL 结尾 */
void gk3_dp_text(const EFI_DEVICE_PATH_PROTOCOL *dp, char *out, size_t cap);
EFI_DEVICE_PATH_PROTOCOL *gk3_dp_of(EFI_HANDLE h);
/* 第一个 Media/HardDrive 节点；没有返回 NULL */
const EFI_DEVICE_PATH_PROTOCOL *gk3_dp_find_hd(const EFI_DEVICE_PATH_PROTOCOL *dp);

/* ------------------------------------------------------------------ 内存 */

void *gk3_alloc(size_t n);                     /* AllocatePool(LoaderData)，清零；失败 NULL */
void gk3_free(void *p);
/* 整页、4 KiB 对齐（块 IO 缓冲用：IoAlign ≤ 4096 时一律满足） */
void *gk3_alloc_pages(size_t n);
void gk3_free_pages(void *p, size_t n);

/* ------------------------------------------------------------------ 块设备 */

/* 把 EFI_BLOCK_IO_PROTOCOL 包成 libgk3core 的 gk3_blk（只读：write / flush 为 NULL）。
 * ctx 由调用方提供存储。读请求按 chunk 拆分（有的固件对单次传输有上限）。 */
typedef struct {
    EFI_BLOCK_IO_PROTOCOL *bio;
    UINT32 media_id;
    EFI_STATUS last_err;
} gk3_bio_ctx;

void gk3_blk_from_bio(gk3_blk *dev, gk3_bio_ctx *ctx, EFI_BLOCK_IO_PROTOCOL *bio);

/* ------------------------------------------------------------------ 变量与句柄 */

/* GetVariable 进调用方缓冲区；*size 进出 */
EFI_STATUS gk3_getvar(const CHAR16 *name, const EFI_GUID *g, UINT32 *attr, void *buf, UINTN *size);
/* LocateHandleBuffer(ByProtocol)；*n 出；返回的数组要 gk3_free */
EFI_STATUS gk3_handles(const EFI_GUID *g, UINTN *n, EFI_HANDLE **out);

#endif /* GK3EFI_H */

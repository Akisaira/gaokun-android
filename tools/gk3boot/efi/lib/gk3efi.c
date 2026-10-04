/* gk3efi：UEFI 侧共用小工具（见 gk3efi.h）。 */
#include "gk3efi.h"

EFI_SYSTEM_TABLE *gk3_st;
EFI_BOOT_SERVICES *gk3_bs;
EFI_RUNTIME_SERVICES *gk3_rt;
EFI_HANDLE gk3_image;
gk3_log gk3_lg;

/* gnu-efi 3.0.18 的 crt0 自重定位之后调 _entry（libefi 里那份还要跑构造函数）；
 * 我们不链接 libefi，也没有构造函数，直接转给 efi_main。 */
EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st);
EFI_STATUS _entry(EFI_HANDLE image, EFI_SYSTEM_TABLE *st);
EFI_STATUS _entry(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    return efi_main(image, st);
}

void gk3efi_init(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    gk3_image = image;
    gk3_st = st;
    gk3_bs = st ? st->BootServices : NULL;
    gk3_rt = st ? st->RuntimeServices : NULL;
}

/* ------------------------------------------------------------------ GUID */

/* refs/edk2（999fd0f1）MdePkg/Include/Protocol/LoadedImage.h:14-17 */
const EFI_GUID gk3_guid_loaded_image = {0x5B1B31A1, 0x9562, 0x11d2, {0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B}};
/* Protocol/DevicePath.h:22-25 */
const EFI_GUID gk3_guid_device_path = {0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
/* Protocol/BlockIo.h:14-17 */
const EFI_GUID gk3_guid_block_io = {0x964e5b21, 0x6459, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
/* Protocol/SimpleFileSystem.h:17-20 */
const EFI_GUID gk3_guid_simple_fs = {0x964e5b22, 0x6459, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
/* Guid/FileInfo.h:13-16 */
const EFI_GUID gk3_guid_file_info = {0x09576e92, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
/* Protocol/SimpleTextIn.h:14-17 */
const EFI_GUID gk3_guid_text_in = {0x387477c1, 0x69c7, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}};
/* Protocol/SimpleTextInEx.h:17-18 */
const EFI_GUID gk3_guid_text_in_ex = {0xdd9e7534, 0x7762, 0x4698, {0x8c, 0x14, 0xf5, 0x85, 0x17, 0xa6, 0x25, 0xaa}};
/* Protocol/GraphicsOutput.h:13-16 */
const EFI_GUID gk3_guid_gop = {0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}};
/* Protocol/PartitionInfo.h:21（设计稿 §2.1） */
const EFI_GUID gk3_guid_partition_info = {0x8cf2f62c, 0xbc9b, 0x4821, {0x80, 0x8d, 0xec, 0x9e, 0xc4, 0x21, 0xa1, 0xa0}};
/* 高通 EFI_USB_DEVICE_PROTOCOL：设计稿 §2.1（BIOS 2.16 UsbDeviceDxe 静态分析；ABL EFIUsbDevice.h:359-370） */
const EFI_GUID gk3_guid_usb_device = {0xd9d9ce48, 0x44b8, 0x4f49, {0x8e, 0x3e, 0x2a, 0x3b, 0x92, 0x7d, 0xc6, 0xc1}};
/* Protocol/UsbFunctionIo.h:26-29 */
const EFI_GUID gk3_guid_usbfn_io = {0x32d2963a, 0xfe5d, 0x4f30, {0xb6, 0x33, 0x6e, 0x5d, 0xc5, 0x58, 0x03, 0xcc}};
/* Protocol/UsbIo.h:20-23 */
const EFI_GUID gk3_guid_usb_io = {0x2B2F68D6, 0x0CD2, 0x44cf, {0x8E, 0x8B, 0xBB, 0xA2, 0x0B, 0x1B, 0x5B, 0x75}};
/* Protocol/Usb2HostController.h:16-19 */
const EFI_GUID gk3_guid_usb2_hc = {0x3e745226, 0x9818, 0x45b6, {0xa2, 0xac, 0xd7, 0xcd, 0x0e, 0x8b, 0xa2, 0xbc}};
/* Protocol/Rng.h:18-21 */
const EFI_GUID gk3_guid_rng = {0x3152bca5, 0xeade, 0x433d, {0x86, 0x2e, 0xc0, 0x1c, 0xdc, 0x29, 0x1f, 0x44}};
/* Protocol/Tcg2Protocol.h:15-16 */
const EFI_GUID gk3_guid_tcg2 = {0x607f766c, 0x7455, 0x42be, {0x93, 0x0b, 0xe4, 0xd7, 0x6d, 0xb2, 0x72, 0x0f}};
/* refs/systemd-v257 src/boot/proto/dt-fixup.h:8-9 */
const EFI_GUID gk3_guid_dt_fixup = {0xe617d64c, 0xfe08, 0x46da, {0xf4, 0xdc, 0xbb, 0xd5, 0x87, 0x0c, 0x73, 0x00}};
/* Protocol/MemoryAttribute.h:14-16 */
const EFI_GUID gk3_guid_memory_attribute = {0xf4560cf6, 0x40ec, 0x4b4a, {0xa1, 0x92, 0xbf, 0x1d, 0x57, 0xd0, 0xb1, 0x89}};
/* Guid/GlobalVariable.h:13-16 */
const EFI_GUID gk3_guid_global_var = {0x8BE4DF61, 0x93CA, 0x11d2, {0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C}};
/* systemd-v257 src/boot/efivars.h:11-12 */
const EFI_GUID gk3_guid_loader = {0x4a67b082, 0x0a4c, 0x41cf, {0xb6, 0xc7, 0x44, 0x0b, 0x29, 0xbb, 0x8c, 0x4f}};
/* Guid/SmBios.h:18-26 */
const EFI_GUID gk3_guid_smbios = {0xeb9d2d31, 0x2d88, 0x11d3, {0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d}};
const EFI_GUID gk3_guid_smbios3 = {0xf2fd1544, 0x9794, 0x4a2c, {0x99, 0x2e, 0xe5, 0xbb, 0xcf, 0x20, 0xe3, 0x94}};

static const struct {
    EFI_GUID g;
    const char *name;
} known_guids[] = {
    /* 配置表 */
    {{0xeb9d2d30, 0x2d88, 0x11d3, {0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d}}, "ACPI1.0"},     /* Guid/Acpi.h:18 */
    {{0x8868e871, 0xe4f1, 0x11d3, {0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81}}, "ACPI2.0"},     /* Guid/Acpi.h:23 */
    {{0xeb9d2d31, 0x2d88, 0x11d3, {0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d}}, "SMBIOS"},
    {{0xf2fd1544, 0x9794, 0x4a2c, {0x99, 0x2e, 0xe5, 0xbb, 0xcf, 0x20, 0xe3, 0x94}}, "SMBIOS3"},
    /* systemd-v257 proto/dt-fixup.h:6-7；include/linux/efi.h 的 DEVICE_TREE_GUID */
    {{0xb1b621d5, 0xf19c, 0x41a5, {0x83, 0x0b, 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0}}, "DTB"},
    /* systemd-v257 src/boot/random-seed.c:19-20 */
    {{0x1ce1e5bc, 0x7ceb, 0x42f2, {0x81, 0xe5, 0x8a, 0xad, 0xf1, 0x80, 0xf5, 0x7b}}, "LinuxRandomSeed"},
    /* Guid/MemoryAttributesTable.h:11-13 */
    {{0xdcfa911d, 0x26eb, 0x469f, {0xa2, 0x20, 0x38, 0xb7, 0xdc, 0x46, 0x12, 0x20}}, "MemoryAttributesTable"},
    /* Guid/RtPropertiesTable.h:20-22 */
    {{0xeb66918a, 0x7eef, 0x402a, {0x84, 0x2e, 0x93, 0x1d, 0x21, 0xc3, 0x8a, 0xe9}}, "RtProperties"},
    /* Guid/SystemResourceTable.h:15-17 */
    {{0xb122a263, 0x3661, 0x4f68, {0x99, 0x29, 0x78, 0xf8, 0xb0, 0xd6, 0x21, 0x80}}, "ESRT"},
    /* Protocol/Tcg2Protocol.h:312-313 */
    {{0x1e2ed096, 0x30e2, 0x4254, {0xbd, 0x89, 0x86, 0x3b, 0xbe, 0xf8, 0x23, 0x25}}, "TCG2FinalEvents"},
    /* Guid/DebugImageInfoTable.h:19-21 */
    {{0x49152e77, 0x1ada, 0x4764, {0xb7, 0xa2, 0x7a, 0xfe, 0xfe, 0xd9, 0x5e, 0x8b}}, "DebugImageInfo"},
    /* Guid/ConformanceProfiles.h:20-22 */
    {{0x36122546, 0xf7e7, 0x4c8f, {0xbd, 0x9b, 0xeb, 0x85, 0x25, 0xb5, 0x0c, 0x0b}}, "ConformanceProfiles"},
    /* Guid/HobList.h:20-22 */
    {{0x7739f24c, 0x93d7, 0x11d4, {0x9a, 0x3a, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d}}, "HobList"},
    /* Guid/DxeServices.h:18-20 */
    {{0x05ad34ba, 0x6f02, 0x4214, {0x95, 0x2e, 0x4d, 0xa0, 0x39, 0x8e, 0x2b, 0xb9}}, "DxeServices"},
    /* MdeModulePkg Guid/MemoryTypeInformation.h:21-22 */
    {{0x4c19049f, 0x4137, 0x4dd3, {0x9c, 0x10, 0x8b, 0x97, 0xa8, 0x3f, 0xfd, 0xfa}}, "MemoryTypeInformation"},
    /* Guid/ImageAuthentication.h:16-18 */
    {{0xd719b2cb, 0x3d3a, 0x4596, {0xa3, 0xbc, 0xda, 0xd0, 0x0e, 0x67, 0x65, 0x6f}}, "ImageSecurityDatabase"},
};

bool gk3_guid_eq(const EFI_GUID *a, const EFI_GUID *b)
{
    return gk3_memcmp(a, b, sizeof(EFI_GUID)) == 0;
}

const char *gk3_guid_name(const EFI_GUID *g)
{
    for (size_t i = 0; i < sizeof(known_guids) / sizeof(known_guids[0]); i++)
        if (gk3_guid_eq(g, &known_guids[i].g))
            return known_guids[i].name;
    return NULL;
}

/* ------------------------------------------------------------------ libc 替身 */

void *memcpy(void *dst, const void *src, size_t n)
{
    gk3_memcpy(dst, src, n);
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    volatile uint8_t *d = dst;
    const volatile uint8_t *s = src;
    if (d == s || n == 0)
        return dst;
    if (d < s) {
        for (size_t i = 0; i < n; i++)
            d[i] = s[i];
    } else {
        for (size_t i = n; i > 0; i--)
            d[i - 1] = s[i - 1];
    }
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    gk3_memset(dst, c, n);
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    return gk3_memcmp(a, b, n);
}

size_t gk3_strlen(const char *s)
{
    size_t n = 0;
    while (s && s[n])
        n++;
    return n;
}

size_t gk3_strlen16(const CHAR16 *s)
{
    size_t n = 0;
    while (s && s[n])
        n++;
    return n;
}

/* ------------------------------------------------------------------ 格式化 */

typedef struct {
    char *o;
    size_t cap, n;
} sink;

static void put(sink *k, char c)
{
    if (k->n + 1 < k->cap)
        k->o[k->n] = c;
    k->n++;
}

static void put_str(sink *k, const char *s, int width, int prec, bool left)
{
    int len = 0;
    if (!s)
        s = "(null)";
    while (s[len] && (prec < 0 || len < prec))
        len++;
    if (!left)
        for (int i = len; i < width; i++)
            put(k, ' ');
    for (int i = 0; i < len; i++)
        put(k, s[i]);
    if (left)
        for (int i = len; i < width; i++)
            put(k, ' ');
}

static void put_num(sink *k, uint64_t v, bool neg, unsigned base, bool upper, int width, bool zero, bool left)
{
    char tmp[24];
    int n = 0, total;
    const char *dg = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    do {
        tmp[n++] = dg[v % base];
        v /= base;
    } while (v);
    total = n + (neg ? 1 : 0);
    if (!left && !zero)
        for (int i = total; i < width; i++)
            put(k, ' ');
    if (neg)
        put(k, '-');
    if (!left && zero)
        for (int i = total; i < width; i++)
            put(k, '0');
    while (n)
        put(k, tmp[--n]);
    if (left)
        for (int i = total; i < width; i++)
            put(k, ' ');
}

int gk3_vsnprintf(char *out, size_t cap, const char *fmt, va_list ap)
{
    sink k = {out, cap, 0};
    for (const char *p = fmt; *p; p++) {
        if (*p != '%') {
            put(&k, *p);
            continue;
        }
        p++;
        bool left = false, zero = false;
        int width = 0, prec = -1, lng = 0;
        for (;; p++) {
            if (*p == '-')
                left = true;
            else if (*p == '0')
                zero = true;
            else
                break;
        }
        if (*p == '*') {
            width = va_arg(ap, int);
            p++;
        } else {
            while (*p >= '0' && *p <= '9')
                width = width * 10 + (*p++ - '0');
        }
        if (*p == '.') {
            p++;
            prec = 0;
            if (*p == '*') {
                prec = va_arg(ap, int);
                p++;
            } else {
                while (*p >= '0' && *p <= '9')
                    prec = prec * 10 + (*p++ - '0');
            }
        }
        while (*p == 'l' || *p == 'z') {
            lng++;
            p++;
        }
        switch (*p) {
        case '%':
            put(&k, '%');
            break;
        case 'c':
            put(&k, (char)va_arg(ap, int));
            break;
        case 's':
            put_str(&k, va_arg(ap, const char *), width, prec, left);
            break;
        case 'd':
        case 'i': {
            int64_t v = lng ? va_arg(ap, int64_t) : va_arg(ap, int);
            put_num(&k, v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v, v < 0, 10, false, width, zero, left);
            break;
        }
        case 'u':
        case 'x':
        case 'X': {
            uint64_t v = lng ? va_arg(ap, uint64_t) : va_arg(ap, unsigned int);
            put_num(&k, v, false, *p == 'u' ? 10 : 16, *p == 'X', width, zero, left);
            break;
        }
        case 'p':
            put(&k, '0');
            put(&k, 'x');
            put_num(&k, (uint64_t)(uintptr_t)va_arg(ap, void *), false, 16, false, width, zero, left);
            break;
        case 0:
            p--;
            break;
        default:
            put(&k, '%');
            put(&k, *p);
        }
    }
    if (cap)
        out[k.n < cap ? k.n : cap - 1] = 0;
    return (int)k.n;
}

int gk3_snprintf(char *out, size_t cap, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = gk3_vsnprintf(out, cap, fmt, ap);
    va_end(ap);
    return r;
}

const char *gk3_efi_strerror(EFI_STATUS st)
{
    static const char *const errs[] = {
        "SUCCESS", "LOAD_ERROR", "INVALID_PARAMETER", "UNSUPPORTED", "BAD_BUFFER_SIZE", "BUFFER_TOO_SMALL",
        "NOT_READY", "DEVICE_ERROR", "WRITE_PROTECTED", "OUT_OF_RESOURCES", "VOLUME_CORRUPTED", "VOLUME_FULL",
        "NO_MEDIA", "MEDIA_CHANGED", "NOT_FOUND", "ACCESS_DENIED", "NO_RESPONSE", "NO_MAPPING", "TIMEOUT",
        "NOT_STARTED", "ALREADY_STARTED", "ABORTED", "ICMP_ERROR", "TFTP_ERROR", "PROTOCOL_ERROR",
        "INCOMPATIBLE_VERSION", "SECURITY_VIOLATION", "CRC_ERROR", "END_OF_MEDIA", "29", "30", "END_OF_FILE",
        "INVALID_LANGUAGE", "COMPROMISED_DATA", "IP_ADDRESS_CONFLICT", "HTTP_ERROR",
    };
    static const char *const warns[] = {
        "SUCCESS", "WARN_UNKNOWN_GLYPH", "WARN_DELETE_FAILURE", "WARN_WRITE_FAILURE", "WARN_BUFFER_TOO_SMALL",
        "WARN_STALE_DATA", "WARN_FILE_SYSTEM", "WARN_RESET_REQUIRED",
    };
    static char other[32];
    uint64_t v = (uint64_t)st, code = v & ~(1ull << 63);
    if (v >> 63) {
        if (code < sizeof(errs) / sizeof(errs[0]))
            return errs[code];
    } else if (code < sizeof(warns) / sizeof(warns[0])) {
        return warns[code];
    }
    gk3_snprintf(other, sizeof(other), "0x%llx", (unsigned long long)v);
    return other;
}

/* ------------------------------------------------------------------ 计时 */

uint64_t gk3_ticks(void)
{
    uint64_t v;
    __asm__ volatile("isb\n\tmrs %0, cntvct_el0" : "=r"(v)::"memory");
    return v;
}

uint64_t gk3_tick_hz(void)
{
    uint64_t v;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v));
    return v & 0xffffffffu;
}

uint64_t gk3_us_since(uint64_t t0)
{
    uint64_t hz = gk3_tick_hz(), d = gk3_ticks() - t0;
    if (!hz)
        return 0;
    return d / hz * 1000000u + (d % hz) * 1000000u / hz;
}

/* ------------------------------------------------------------------ 字符串转换 */

void gk3_ucs2_to_ascii(const CHAR16 *s, size_t n, char *out, size_t cap)
{
    size_t o = 0;
    if (!cap)
        return;
    for (size_t i = 0; s && i < n && s[i] && o + 1 < cap; i++)
        out[o++] = (s[i] >= 0x20 && s[i] < 0x7f) ? (char)s[i] : '?';
    out[o] = 0;
}

void gk3_utf8_to_ucs2_crlf(const char *s, CHAR16 *out, size_t cap)
{
    size_t o = 0;
    const uint8_t *p = (const uint8_t *)s;
    if (!cap)
        return;
    while (*p && o + 2 < cap) {
        uint32_t c = *p++;
        if (c >= 0xc0 && c < 0xe0 && (p[0] & 0xc0) == 0x80) {
            c = ((c & 0x1f) << 6) | (p[0] & 0x3f);
            p += 1;
        } else if (c >= 0xe0 && c < 0xf0 && (p[0] & 0xc0) == 0x80 && (p[1] & 0xc0) == 0x80) {
            c = ((c & 0x0f) << 12) | ((uint32_t)(p[0] & 0x3f) << 6) | (p[1] & 0x3f);
            p += 2;
        } else if (c >= 0x80) {
            c = '?';
        }
        if (c == '\n')
            out[o++] = '\r';
        out[o++] = (CHAR16)c;
    }
    out[o] = 0;
}

/* ------------------------------------------------------------------ 日志 */

void gk3_log_init(size_t cap)
{
    gk3_memset(&gk3_lg, 0, sizeof(gk3_lg));
    gk3_lg.screen = true;
    gk3_lg.buf = gk3_alloc(cap);
    gk3_lg.cap = gk3_lg.buf ? cap : 0;
}

static void log_append(const char *s, size_t n)
{
    if (!gk3_lg.buf)
        return;
    if (gk3_lg.len + n + 1 > gk3_lg.cap) {
        static const char cut[] = "\n[log buffer full, truncated]\n";
        if (!gk3_lg.truncated && gk3_lg.len + sizeof(cut) < gk3_lg.cap) {
            gk3_memcpy(gk3_lg.buf + gk3_lg.len, cut, sizeof(cut) - 1);
            gk3_lg.len += sizeof(cut) - 1;
        }
        gk3_lg.truncated = true;
        return;
    }
    gk3_memcpy(gk3_lg.buf + gk3_lg.len, s, n);
    gk3_lg.len += n;
    gk3_lg.buf[gk3_lg.len] = 0;
}

static void screen_out(const char *s)
{
    static CHAR16 w[4096];
    if (!gk3_st || !gk3_st->ConOut)
        return;
    gk3_utf8_to_ucs2_crlf(s, w, sizeof(w) / sizeof(w[0]));
    gk3_st->ConOut->OutputString(gk3_st->ConOut, w);
}

static char line_buf[4000];

void gk3_logf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = gk3_vsnprintf(line_buf, sizeof(line_buf), fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    size_t len = gk3_strlen(line_buf);
    log_append(line_buf, len);
    if (gk3_lg.screen)
        screen_out(line_buf);
}

void gk3_logd(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    gk3_vsnprintf(line_buf, sizeof(line_buf), fmt, ap);
    va_end(ap);
    log_append(line_buf, gk3_strlen(line_buf));
}

void gk3_screenf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    gk3_vsnprintf(line_buf, sizeof(line_buf), fmt, ap);
    va_end(ap);
    screen_out(line_buf);
}

void gk3_log_sync(void)
{
    EFI_FILE_PROTOCOL *f = gk3_lg.file;
    if (!f || gk3_lg.file_failed || gk3_lg.synced >= gk3_lg.len)
        return;
    UINTN want = gk3_lg.len - gk3_lg.synced, got = want;
    EFI_STATUS st = f->Write(f, &got, gk3_lg.buf + gk3_lg.synced);
    if (EFI_ERROR(st) || got != want) {
        gk3_lg.file_failed = true;
        gk3_lg.file_err = EFI_ERROR(st) ? st : EFI_VOLUME_FULL;
        return;
    }
    gk3_lg.synced += got;
    st = f->Flush(f);
    if (EFI_ERROR(st)) {
        gk3_lg.file_failed = true;
        gk3_lg.file_err = st;
    }
}

/* ------------------------------------------------------------------ 设备路径 */

#define DP_LEN(d) ((size_t)((const uint8_t *)(d))[2] | ((size_t)((const uint8_t *)(d))[3] << 8))
#define DP_NEXT(d) ((const EFI_DEVICE_PATH_PROTOCOL *)((const uint8_t *)(d) + DP_LEN(d)))

size_t gk3_dp_size(const EFI_DEVICE_PATH_PROTOCOL *dp)
{
    size_t total = 0;
    if (!dp)
        return 0;
    for (;;) {
        size_t l = DP_LEN(dp);
        if (l < 4 || total + l > 65536)
            return 0;
        total += l;
        if (dp->Type == 0x7f && dp->SubType == 0xff)
            return total;
        dp = DP_NEXT(dp);
    }
}

static void guid_txt(const uint8_t *g, char out[37])
{
    gk3_guid_str(g, out);
}

static size_t dp_node(const EFI_DEVICE_PATH_PROTOCOL *n, char *o, size_t cap)
{
    const uint8_t *d = (const uint8_t *)n;
    size_t l = DP_LEN(n);
    char g[37];
    unsigned t = n->Type, s = n->SubType;
#define NEED(x) if (l < (x)) goto raw
    if (t == 1 && s == 1) {
        NEED(6);
        return gk3_snprintf(o, cap, "Pci(0x%x,0x%x)", d[5], d[4]);
    } else if (t == 1 && s == 3) {
        NEED(24);
        return gk3_snprintf(o, cap, "MemoryMapped(0x%x,0x%llx,0x%llx)", gk3_le32(d + 4),
                            (unsigned long long)gk3_le64(d + 8), (unsigned long long)gk3_le64(d + 16));
    } else if ((t == 1 || t == 3 || t == 4) && s == (t == 1 ? 4u : t == 3 ? 10u : 3u)) {
        NEED(20);
        guid_txt(d + 4, g);
        int k = gk3_snprintf(o, cap, "%s(%s", t == 1 ? "VenHw" : t == 3 ? "VenMsg" : "VenMedia", g);
        if ((size_t)k < cap && l > 20) {
            k += gk3_snprintf(o + k, cap - k, ",");
            for (size_t i = 20; i < l && i < 36 && (size_t)k + 3 < cap; i++)
                k += gk3_snprintf(o + k, cap - k, "%02x", d[i]);
            if (l > 36 && (size_t)k < cap)
                k += gk3_snprintf(o + k, cap - k, "...");
        }
        if ((size_t)k < cap)
            k += gk3_snprintf(o + k, cap - k, ")");
        return k;
    } else if (t == 1 && s == 5) {
        NEED(8);
        return gk3_snprintf(o, cap, "Ctrl(0x%x)", gk3_le32(d + 4));
    } else if (t == 2 && s == 1) {
        NEED(12);
        uint32_t hid = gk3_le32(d + 4), uid = gk3_le32(d + 8);
        if (hid == 0x0a0341d0)
            return gk3_snprintf(o, cap, "PciRoot(0x%x)", uid);
        if (hid == 0x0a0841d0)
            return gk3_snprintf(o, cap, "PcieRoot(0x%x)", uid);
        return gk3_snprintf(o, cap, "Acpi(0x%08x,0x%x)", hid, uid);
    } else if (t == 3 && s == 2) {
        NEED(8);
        return gk3_snprintf(o, cap, "Scsi(0x%x,0x%x)", gk3_le16(d + 4), gk3_le16(d + 6));
    } else if (t == 3 && s == 5) {
        NEED(6);
        return gk3_snprintf(o, cap, "USB(0x%x,0x%x)", d[4], d[5]);
    } else if (t == 3 && s == 11) {
        NEED(10);
        return gk3_snprintf(o, cap, "MAC(%02x%02x%02x%02x%02x%02x)", d[4], d[5], d[6], d[7], d[8], d[9]);
    } else if (t == 3 && s == 14) {
        NEED(19);
        return gk3_snprintf(o, cap, "Uart(%llu,%u,%u,%u)", (unsigned long long)gk3_le64(d + 8), d[16], d[17], d[18]);
    } else if (t == 3 && s == 15) {
        NEED(11);
        return gk3_snprintf(o, cap, "UsbClass(0x%x,0x%x,0x%x,0x%x,0x%x)", gk3_le16(d + 4), gk3_le16(d + 6), d[8],
                            d[9], d[10]);
    } else if (t == 3 && s == 0x12) {
        NEED(10);
        return gk3_snprintf(o, cap, "Sata(0x%x,0x%x,0x%x)", gk3_le16(d + 4), gk3_le16(d + 6), gk3_le16(d + 8));
    } else if (t == 3 && s == 0x17) {
        NEED(16);
        return gk3_snprintf(o, cap, "NVMe(0x%x,%02x-%02x-%02x-%02x-%02x-%02x-%02x-%02x)", gk3_le32(d + 4), d[15],
                            d[14], d[13], d[12], d[11], d[10], d[9], d[8]);
    } else if (t == 3 && s == 0x19) {
        NEED(6);
        return gk3_snprintf(o, cap, "UFS(0x%x,0x%x)", d[4], d[5]);
    } else if (t == 3 && s == 0x1a) {
        NEED(5);
        return gk3_snprintf(o, cap, "SD(0x%x)", d[4]);
    } else if (t == 3 && s == 0x1d) {
        NEED(5);
        return gk3_snprintf(o, cap, "eMMC(0x%x)", d[4]);
    } else if (t == 4 && s == 1) {
        NEED(42);
        if (d[41] == 2) {
            guid_txt(d + 24, g);
            return gk3_snprintf(o, cap, "HD(%u,GPT,%s,0x%llx,0x%llx)", gk3_le32(d + 4), g,
                                (unsigned long long)gk3_le64(d + 8), (unsigned long long)gk3_le64(d + 16));
        }
        return gk3_snprintf(o, cap, "HD(%u,%s,0x%08x,0x%llx,0x%llx)", gk3_le32(d + 4), d[41] == 1 ? "MBR" : "?",
                            gk3_le32(d + 24), (unsigned long long)gk3_le64(d + 8),
                            (unsigned long long)gk3_le64(d + 16));
    } else if (t == 4 && s == 2) {
        NEED(24);
        return gk3_snprintf(o, cap, "CDROM(0x%x)", gk3_le32(d + 4));
    } else if (t == 4 && s == 4) {
        size_t k = 0;
        for (size_t i = 4; i + 1 < l; i += 2) {
            uint16_t c = gk3_le16(d + i);
            if (!c)
                break;
            if (k + 1 < cap)
                o[k] = (c >= 0x20 && c < 0x7f) ? (char)c : '?';
            k++;
        }
        if (cap)
            o[k < cap ? k : cap - 1] = 0;
        return k;
    } else if (t == 4 && (s == 6 || s == 7)) {
        NEED(20);
        guid_txt(d + 4, g);
        return gk3_snprintf(o, cap, "%s(%s)", s == 6 ? "FvFile" : "Fv", g);
    } else if (t == 4 && s == 8) {
        NEED(24);
        return gk3_snprintf(o, cap, "Offset(0x%llx,0x%llx)", (unsigned long long)gk3_le64(d + 8),
                            (unsigned long long)gk3_le64(d + 16));
    }
raw : {
    int k = gk3_snprintf(o, cap, "Path(%u,%u,", t, s);
    for (size_t i = 4; i < l && i < 36 && (size_t)k + 3 < cap; i++)
        k += gk3_snprintf(o + k, cap - k, "%02x", d[i]);
    if ((size_t)k < cap)
        k += gk3_snprintf(o + k, cap - k, "%s)", l > 36 ? "..." : "");
    return k;
}
#undef NEED
}

void gk3_dp_text(const EFI_DEVICE_PATH_PROTOCOL *dp, char *out, size_t cap)
{
    size_t o = 0;
    if (!cap)
        return;
    out[0] = 0;
    if (!dp) {
        gk3_snprintf(out, cap, "(none)");
        return;
    }
    if (!gk3_dp_size(dp)) {
        gk3_snprintf(out, cap, "(malformed device path)");
        return;
    }
    for (bool first = true;; first = false) {
        if (dp->Type == 0x7f) {
            if (dp->SubType == 0xff)
                break;
            if (o + 1 < cap)
                out[o++] = ',';
            out[o < cap ? o : cap - 1] = 0;
            dp = DP_NEXT(dp);
            first = true;
            continue;
        }
        if (!first && o + 1 < cap)
            out[o++] = '/';
        if (o + 1 >= cap)
            break;
        size_t k = dp_node(dp, out + o, cap - o);
        o += k;
        if (o >= cap) {
            o = cap - 1;
            break;
        }
        dp = DP_NEXT(dp);
    }
    out[o < cap ? o : cap - 1] = 0;
}

EFI_DEVICE_PATH_PROTOCOL *gk3_dp_of(EFI_HANDLE h)
{
    void *p = NULL;
    if (!h || EFI_ERROR(gk3_bs->HandleProtocol(h, (EFI_GUID *)&gk3_guid_device_path, &p)))
        return NULL;
    return p;
}

const EFI_DEVICE_PATH_PROTOCOL *gk3_dp_find_hd(const EFI_DEVICE_PATH_PROTOCOL *dp)
{
    if (!gk3_dp_size(dp))
        return NULL;
    for (; !(dp->Type == 0x7f && dp->SubType == 0xff); dp = DP_NEXT(dp))
        if (dp->Type == 4 && dp->SubType == 1)
            return dp;
    return NULL;
}

/* ------------------------------------------------------------------ 内存 */

void *gk3_alloc(size_t n)
{
    void *p = NULL;
    if (!n || EFI_ERROR(gk3_bs->AllocatePool(EfiLoaderData, n, &p)))
        return NULL;
    gk3_memset(p, 0, n);
    return p;
}

void gk3_free(void *p)
{
    if (p)
        gk3_bs->FreePool(p);
}

void *gk3_alloc_pages(size_t n)
{
    EFI_PHYSICAL_ADDRESS a = 0;
    if (!n || EFI_ERROR(gk3_bs->AllocatePages(AllocateAnyPages, EfiLoaderData, (n + 4095) / 4096, &a)))
        return NULL;
    return (void *)(uintptr_t)a;
}

void gk3_free_pages(void *p, size_t n)
{
    if (p)
        gk3_bs->FreePages((EFI_PHYSICAL_ADDRESS)(uintptr_t)p, (n + 4095) / 4096);
}

/* ------------------------------------------------------------------ 块设备 */

#define BIO_CHUNK (1024u * 1024u)

static int bio_read(void *vctx, uint64_t lba, uint32_t count, void *buf)
{
    gk3_bio_ctx *c = vctx;
    uint32_t bs = c->bio->Media->BlockSize;
    uint32_t per = BIO_CHUNK / bs ? BIO_CHUNK / bs : 1;
    uint8_t *b = buf;
    while (count) {
        uint32_t n = count < per ? count : per;
        EFI_STATUS st = c->bio->ReadBlocks(c->bio, c->media_id, lba, (UINTN)n * bs, b);
        if (EFI_ERROR(st)) {
            c->last_err = st;
            return -1;
        }
        lba += n;
        b += (size_t)n * bs;
        count -= n;
    }
    return 0;
}

void gk3_blk_from_bio(gk3_blk *dev, gk3_bio_ctx *ctx, EFI_BLOCK_IO_PROTOCOL *bio)
{
    ctx->bio = bio;
    ctx->media_id = bio->Media->MediaId;
    ctx->last_err = EFI_SUCCESS;
    dev->ctx = ctx;
    dev->block_size = bio->Media->BlockSize;
    dev->num_blocks = bio->Media->LastBlock + 1;
    dev->read = bio_read;
    dev->write = NULL;      /* 探针只读：连写回调都不给 */
    dev->flush = NULL;
}

/* ------------------------------------------------------------------ 变量与句柄 */

EFI_STATUS gk3_getvar(const CHAR16 *name, const EFI_GUID *g, UINT32 *attr, void *buf, UINTN *size)
{
    UINT32 a = 0;
    EFI_STATUS st = gk3_rt->GetVariable((CHAR16 *)name, (EFI_GUID *)g, &a, size, buf);
    if (attr)
        *attr = a;
    return st;
}

EFI_STATUS gk3_handles(const EFI_GUID *g, UINTN *n, EFI_HANDLE **out)
{
    *n = 0;
    *out = NULL;
    return gk3_bs->LocateHandleBuffer(ByProtocol, (EFI_GUID *)g, NULL, n, out);
}

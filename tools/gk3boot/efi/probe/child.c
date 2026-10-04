/*
 * gk3probe 内嵌的极小测试 PE（设计稿 §6 E3 的"缓冲区 LoadImage 一个测试 PE 并 StartImage"，E4 的前置）。
 *
 * 只做三件事：从自己的 LoadedImage->LoadOptions 找到父进程给的 gk3_child_ctx（child_abi.h），
 * 往里写一行标记、回填自己看到的 ImageBase / ImageSize / ParentHandle，然后返回 EFI_SUCCESS。
 * 不碰盘、不改变量、不分配内存；找不到 ctx 也返回 EFI_SUCCESS（由父进程判"没写标记"）。
 * 也往 ConOut 打一行，方便在屏幕 / 串口上直接看到它跑过。
 */
#include <efi.h>

#include "child_abi.h"

/* refs/edk2 MdePkg/Include/Protocol/LoadedImage.h:14-17 */
static EFI_GUID loaded_image_guid = {0x5B1B31A1, 0x9562, 0x11d2, {0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B}};

/* 编译器可能为循环生成 memset / memcpy 调用，这里给出定义（不链接任何库） */
void *memset(void *d, int c, unsigned long n);
void *memcpy(void *d, const void *s, unsigned long n);
void *memset(void *d, int c, unsigned long n)
{
    volatile unsigned char *p = d;
    while (n--)
        *p++ = (unsigned char)c;
    return d;
}
void *memcpy(void *d, const void *s, unsigned long n)
{
    volatile unsigned char *p = d;
    const volatile unsigned char *q = s;
    while (n--)
        *p++ = *q++;
    return d;
}

static unsigned put_s(char *b, unsigned o, unsigned cap, const char *s)
{
    while (*s && o + 1 < cap)
        b[o++] = *s++;
    return o;
}

static unsigned put_hex(char *b, unsigned o, unsigned cap, uint64_t v)
{
    static const char hx[] = "0123456789abcdef";
    o = put_s(b, o, cap, "0x");
    for (int i = 60; i >= 0; i -= 4)
        if (o + 1 < cap)
            b[o++] = hx[(v >> i) & 15];
    return o;
}

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st);
/* gnu-efi 3.0.18 的 crt0 自重定位之后调 _entry；不链 libefi，直接转给 efi_main */
EFI_STATUS _entry(EFI_HANDLE image, EFI_SYSTEM_TABLE *st);
EFI_STATUS _entry(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    return efi_main(image, st);
}

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    EFI_LOADED_IMAGE_PROTOCOL *li = NULL;
    if (st && st->ConOut)
        st->ConOut->OutputString(st->ConOut, (CHAR16 *)L"gk3probe-child: started\r\n");
    if (!st || EFI_ERROR(st->BootServices->HandleProtocol(image, &loaded_image_guid, (void **)&li)) || !li)
        return EFI_SUCCESS;
    gk3_child_ctx *c = li->LoadOptions;
    if (!c || li->LoadOptionsSize < sizeof(*c) || c->magic != GK3_CHILD_MAGIC || c->version != GK3_CHILD_VERSION ||
        c->size != sizeof(*c) || !c->buf || c->buf_len < 64)
        return EFI_SUCCESS;
    c->child_image_base = (uint64_t)(uintptr_t)li->ImageBase;
    c->child_image_size = li->ImageSize;
    c->child_parent_handle = (uint64_t)(uintptr_t)li->ParentHandle;
    c->child_load_options_size = li->LoadOptionsSize;
    c->child_code_type = li->ImageCodeType;
    unsigned o = 0;
    o = put_s(c->buf, o, c->buf_len, GK3_CHILD_MARKER " image_base=");
    o = put_hex(c->buf, o, c->buf_len, (uint64_t)(uintptr_t)li->ImageBase);
    o = put_s(c->buf, o, c->buf_len, " self=");
    o = put_hex(c->buf, o, c->buf_len, (uint64_t)(uintptr_t)&efi_main);
    c->buf[o] = 0;
    c->written = o;
    if (st->ConOut)
        st->ConOut->OutputString(st->ConOut, (CHAR16 *)L"gk3probe-child: marker written, returning EFI_SUCCESS\r\n");
    return EFI_SUCCESS;
}

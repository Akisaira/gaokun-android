/*
 * gk3probe 与它内嵌的测试 PE（child.c）之间的约定。
 *
 * 父进程（探针）从内存缓冲区 LoadImage 这个 PE，在 StartImage 之前把 LoadedImage->LoadOptions
 * 指向一份 gk3_child_ctx —— 与 systemd-boot linux_exec（refs/systemd-v257 src/boot/linux.c:126-129）
 * 给内核传 cmdline 的位置相同，所以"子镜像能读到 LoadOptions"本身就是 E4 要的证据之一。
 * 子镜像只往 ctx->buf 写一行标记、回填几项自己看到的东西，然后返回 EFI_SUCCESS。
 */
#ifndef GK3_CHILD_ABI_H
#define GK3_CHILD_ABI_H

#include <stdint.h>

#define GK3_CHILD_MAGIC   0x5443425250334b47ull   /* "GK3PRBCT" 小端 */
#define GK3_CHILD_VERSION 1u
#define GK3_CHILD_MARKER  "GK3CHILD-OK"

typedef struct {
    uint64_t magic;
    uint32_t version;
    uint32_t size;              /* sizeof(gk3_child_ctx) */
    char *buf;                  /* 父进程的标记缓冲区 */
    uint32_t buf_len;
    uint32_t written;           /* 子镜像写了多少字节（不含 NUL） */
    /* 子镜像回填 */
    uint64_t child_image_base;
    uint64_t child_image_size;
    uint64_t child_parent_handle;
    uint32_t child_load_options_size;
    uint32_t child_code_type;
} gk3_child_ctx;

#endif

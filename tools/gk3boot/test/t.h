/* 主机测试的极简框架（hosted：可以用 libc）。 */
#ifndef GK3_T_H
#define GK3_T_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gk3core.h"

extern int t_pass, t_fail;
extern const char *t_vectors;   /* 向量目录（Makefile 传 -DVECTORS=…） */

#define CHECK(cond, ...)                                                                 \
    do {                                                                                 \
        if (cond) {                                                                      \
            t_pass++;                                                                    \
        } else {                                                                         \
            t_fail++;                                                                    \
            fprintf(stderr, "  失败 %s:%d: %s —— ", __FILE__, __LINE__, #cond);          \
            fprintf(stderr, __VA_ARGS__);                                                \
            fputc('\n', stderr);                                                         \
        }                                                                                \
    } while (0)

/* 大循环里用：只记失败，循环结束后再用一条 CHECK 记"这一批全对"，免得通过数被随机样本灌水 */
#define CHECKQ(cond, ...)                                                                \
    do {                                                                                 \
        if (!(cond)) {                                                                   \
            t_fail++;                                                                    \
            fprintf(stderr, "  失败 %s:%d: %s —— ", __FILE__, __LINE__, #cond);          \
            fprintf(stderr, __VA_ARGS__);                                                \
            fputc('\n', stderr);                                                         \
        }                                                                                \
    } while (0)

#define CHECK_EQ(a, b) CHECK((a) == (b), "%s = %lld，期望 %lld", #a, (long long)(a), (long long)(b))
#define CHECK_MEM(a, b, n) CHECK(memcmp((a), (b), (n)) == 0, "%s 与 %s 前 %zu 字节不同", #a, #b, (size_t)(n))
#define CHECK_STR(a, b) CHECK(strcmp((a), (b)) == 0, "\n    得到 \"%s\"\n    期望 \"%s\"", (a), (b))

/* 读整个文件（malloc）；不存在返回 NULL。 */
unsigned char *t_slurp(const char *path, size_t *len);
/* 读向量目录里的文件，读不到就算一次失败并返回 NULL。 */
unsigned char *t_vector(const char *name, size_t *len);
void t_hex(const char *label, const void *p, size_t n);

/* 内存块设备（gk3_blk 的测试实现），可注入写失败 / 读回不一致 */
typedef struct {
    unsigned char *data;
    size_t len;
    unsigned bs;
    int fail_write_at;   /* 第几次写失败（-1 不失败） */
    int corrupt_after;   /* 第几次写之后偷偷改一个字节（模拟写不进去），-1 不改 */
    int writes;
} t_memdev;
void t_memdev_bind(t_memdev *m, gk3_blk *dev);

void test_util(void);
void test_gpt(void);
void test_bcb(void);
void test_bcab(void);
void test_gk3rec(void);
void test_dispatch(void);
void test_bootimg(void);
void test_cmdline(void);
void test_blk(void);
void test_fuzz(void);
void test_realmisc(void);

#endif

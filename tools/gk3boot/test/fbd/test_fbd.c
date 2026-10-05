/* gk3-fastbootd 里不碰盘的部分的主机单测（ASan + UBSan）：SHA-256、sparse 校验 / 展开、LP 元数据解析。
 * 盘、ESP、协议的端到端测试在 test/fbd/run.sh（arm64 容器 + loop 盘 + 真 fastboot 主机工具）。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fbd.h"

static int pass, fail;
#define CHECK(c, ...) do { if (c) pass++; else { fail++; fprintf(stderr, "  失败 %s:%d: %s —— ", __FILE__, __LINE__, #c); \
                           fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

/* fb_log 的桩（sparse.c / lp.c 不调它，链接时也不需要；留着防以后用到） */
void fb_log(const char *fmt, ...) { (void)fmt; }

static void hex(const uint8_t *p, size_t n, char *out)
{
    for (size_t i = 0; i < n; i++)
        snprintf(out + 2 * i, 3, "%02x", p[i]);
}

static void test_sha256(void)
{
    static const struct { const char *in; const char *out; } v[] = {
        {"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
        {"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
        {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
    };
    uint8_t d[32];
    char h[65];
    for (size_t i = 0; i < 3; i++) {
        fb_sha256(v[i].in, strlen(v[i].in), d);
        hex(d, 32, h);
        CHECK(!strcmp(h, v[i].out), "sha256(%s) = %s", v[i].in, h);
    }
    {   /* 一百万个 'a'（FIPS 180-2 附录 B.3） */
        char *m = malloc(1000000);
        memset(m, 'a', 1000000);
        fb_sha256(m, 1000000, d);
        hex(d, 32, h);
        CHECK(!strcmp(h, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"), "sha256(1M a) = %s", h);
        free(m);
    }
}

/* ---------------------------------------------------------------- sparse */

typedef struct { uint8_t *b; size_t n, cap; } buf;

static void put(buf *x, const void *p, size_t n)
{
    if (x->n + n > x->cap) {
        x->cap = (x->n + n) * 2 + 64;
        x->b = realloc(x->b, x->cap);
    }
    memcpy(x->b + x->n, p, n);
    x->n += n;
}
static void put16(buf *x, uint16_t v) { uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)}; put(x, b, 2); }
static void put32(buf *x, uint32_t v) { uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)}; put(x, b, 4); }

static void sp_hdr(buf *x, uint32_t blk, uint32_t total_blks, uint32_t chunks)
{
    put32(x, FB_SPARSE_MAGIC); put16(x, 1); put16(x, 0); put16(x, 28); put16(x, 12);
    put32(x, blk); put32(x, total_blks); put32(x, chunks); put32(x, 0);
}
static void sp_chunk(buf *x, uint16_t type, uint32_t blocks, uint32_t total)
{
    put16(x, type); put16(x, 0); put32(x, blocks); put32(x, total);
}

/* 合法样本：raw 2 块 / fill 3 块 / dont-care 2 块 / crc / raw 1 块，块 4096，总 8 块 */
static buf good_sparse(void)
{
    buf x = {0};
    uint8_t blk[4096];
    sp_hdr(&x, 4096, 8, 5);
    sp_chunk(&x, 0xCAC1, 2, 12 + 8192);
    for (int i = 0; i < 2; i++) { memset(blk, 0x11 + i, sizeof(blk)); put(&x, blk, sizeof(blk)); }
    sp_chunk(&x, 0xCAC2, 3, 16); put32(&x, 0xdeadbeef);
    sp_chunk(&x, 0xCAC3, 2, 12);
    sp_chunk(&x, 0xCAC4, 0, 16); put32(&x, 0);
    sp_chunk(&x, 0xCAC1, 1, 12 + 4096); memset(blk, 0x77, sizeof(blk)); put(&x, blk, sizeof(blk));
    return x;
}

static uint8_t out[8 * 4096];
static int o_raw(void *c, uint64_t off, const void *d, size_t n) { (void)c; memcpy(out + off, d, n); return 0; }
static int o_fill(void *c, uint64_t off, uint32_t pat, uint64_t n)
{
    (void)c;
    for (uint64_t i = 0; i < n; i += 4)
        memcpy(out + off + i, &pat, 4);
    return 0;
}

static void test_sparse(void)
{
    fb_sparse_hdr h;
    buf x = good_sparse();
    const char *e;
    fb_sparse_ops ops = {NULL, o_raw, o_fill};

    CHECK(fb_sparse_is(x.b, x.n), "合法样本应认作 sparse");
    e = fb_sparse_check(x.b, x.n, 8 * 4096, &h);
    CHECK(e == NULL, "合法样本被拒：%s", e);
    CHECK(h.out_size == 8 * 4096 && h.total_chunks == 5, "头解析不对");
    memset(out, 0xAA, sizeof(out));
    CHECK(fb_sparse_walk(x.b, x.n, &ops) == 0, "walk 失败");
    {
        uint8_t want[8 * 4096];
        uint32_t pat = 0xdeadbeef;
        memset(want, 0x11, 4096);
        memset(want + 4096, 0x12, 4096);
        for (int i = 0; i < 3 * 4096; i += 4)
            memcpy(want + 8192 + i, &pat, 4);
        memset(want + 5 * 4096, 0xAA, 2 * 4096);     /* DONT_CARE 不碰 */
        memset(want + 7 * 4096, 0x77, 4096);
        CHECK(!memcmp(out, want, sizeof(out)), "展开结果与预期不同（DONT_CARE 被写了？）");
    }
    /* 分区小一字节 → 越界 */
    e = fb_sparse_check(x.b, x.n, 8 * 4096 - 1, &h);
    CHECK(e && strstr(e, "larger than the partition"), "越界没拒：%s", e ? e : "(null)");
    /* 尾部多一字节 */
    {
        buf y = good_sparse();
        put(&y, "x", 1);
        e = fb_sparse_check(y.b, y.n, 1 << 20, &h);
        CHECK(e && strstr(e, "trailing"), "尾部多余字节没拒：%s", e ? e : "(null)");
        free(y.b);
    }
    /* 截断（少最后一字节） */
    e = fb_sparse_check(x.b, x.n - 1, 1 << 20, &h);
    CHECK(e != NULL, "截断没拒");
    /* total_blks 比 chunk 合计多 → 块数对不上 */
    {
        buf y = good_sparse();
        y.b[16] = 9;
        e = fb_sparse_check(y.b, y.n, 1 << 20, &h);
        CHECK(e && strstr(e, "add up"), "块数对不上没拒：%s", e ? e : "(null)");
        /* total_blks 比合计少 → chunk 越过 total_blks */
        y.b[16] = 7;
        e = fb_sparse_check(y.b, y.n, 1 << 20, &h);
        CHECK(e && strstr(e, "past total_blks"), "chunk 越界没拒：%s", e ? e : "(null)");
        free(y.b);
    }
    /* raw chunk 声称的块数与数据长度不符 */
    {
        buf y = good_sparse();
        y.b[28 + 4] = 3;   /* 第一个 chunk 的 chunk_sz 2 → 3 */
        e = fb_sparse_check(y.b, y.n, 1 << 20, &h);
        CHECK(e && strstr(e, "raw chunk size mismatch"), "raw 长度不符没拒：%s", e ? e : "(null)");
        free(y.b);
    }
    /* chunk total_sz 超出下载长度 */
    {
        buf y = good_sparse();
        y.b[28 + 8 + 2] = 0x7f;
        e = fb_sparse_check(y.b, y.n, 1 << 20, &h);
        CHECK(e && strstr(e, "past the end"), "chunk 超出下载没拒：%s", e ? e : "(null)");
        free(y.b);
    }
    /* 块大小不是 4 的倍数 / 版本 / 未知 chunk 类型 / total_chunks 多一个 */
    {
        buf y = good_sparse();
        y.b[12] = 2;
        CHECK(fb_sparse_check(y.b, y.n, 1 << 20, &h) != NULL, "blk_sz 非 4 倍数没拒");
        free(y.b);
        y = good_sparse();
        y.b[4] = 2;
        CHECK(fb_sparse_check(y.b, y.n, 1 << 20, &h) != NULL, "major 2 没拒");
        free(y.b);
        y = good_sparse();
        y.b[28] = 0xC5;
        CHECK(fb_sparse_check(y.b, y.n, 1 << 20, &h) != NULL, "未知 chunk 类型没拒");
        free(y.b);
        y = good_sparse();
        y.b[20] = 6;
        CHECK(fb_sparse_check(y.b, y.n, 1 << 20, &h) != NULL, "total_chunks 多一个没拒");
        free(y.b);
    }
    /* 天文数字：total_blks = 0xFFFFFFFF、blk 4096 → 16 TiB > 分区 */
    {
        buf y = {0};
        sp_hdr(&y, 4096, 0xFFFFFFFFu, 1);
        sp_chunk(&y, 0xCAC3, 0xFFFFFFFFu, 12);
        e = fb_sparse_check(y.b, y.n, 1ull << 30, &h);
        CHECK(e && strstr(e, "larger"), "16 TiB 没拒：%s", e ? e : "(null)");
        free(y.b);
    }
    CHECK(!fb_sparse_is("ANDROID!", 8), "短 raw 不该认作 sparse");
    free(x.b);
}

/* ---------------------------------------------------------------- LP */

static uint8_t super_img[4096 * 3 + 2 * 65536 * 2];

static void w32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

/* 照 liblp 的布局造一份：几何区 + 2 个元数据槽（v10.2 头 256 字节）；槽 s 里放 names[s] */
static void mk_super(const char *const *names0, const char *const *names1)
{
    uint8_t *g = super_img + 4096;
    const uint32_t maxsz = 65536;
    memset(super_img, 0, sizeof(super_img));
    w32(g, 0x616c4467);
    w32(g + 4, 52);
    w32(g + 40, maxsz);
    w32(g + 44, 2);
    w32(g + 48, 4096);
    fb_sha256(g, 52, g + 8);
    memcpy(super_img + 8192, g, 4096);
    for (int s = 0; s < 2; s++) {
        const char *const *names = s ? names1 : names0;
        uint8_t *h = super_img + 4096 + 8192 + (size_t)s * maxsz, *t = h + 256;
        uint32_t n = 0;
        for (; names[n]; n++) {
            uint8_t *e = t + n * 52;
            memset(e, 0, 52);
            memcpy(e, names[n], strlen(names[n]));
            w32(e + 36, 1);
            w32(e + 44, 1);
        }
        w32(h, 0x414C5030);
        h[4] = 10; h[6] = 2;
        w32(h + 8, 256);
        w32(h + 44, n * 52);
        fb_sha256(t, n * 52, h + 48);
        w32(h + 80, 0); w32(h + 84, n); w32(h + 88, 52);
        fb_sha256(h, 256, h + 12);   /* header_checksum 字段此时为零 */
    }
}

static int rd(void *ctx, uint64_t off, void *b, size_t n)
{
    (void)ctx;
    if (off + n > sizeof(super_img))
        return -1;
    memcpy(b, super_img + off, n);
    return 0;
}

static void test_lp(void)
{
    static const char *const a[] = {"system_a", "vendor_a", "system_a-cow", NULL};
    static const char *const b[] = {"system_b", "vendor_b", NULL};
    static const char *const none[] = {NULL};
    fb_lp lp;
    const char *e;

    mk_super(a, b);
    e = fb_lp_read(rd, NULL, 0, &lp);
    CHECK(e == NULL, "槽 a 元数据被拒：%s", e);
    CHECK(lp.n_parts == 3 && !strcmp(lp.parts[1].name, "vendor_a"), "槽 a 分区解析不对（%u）", lp.n_parts);
    CHECK(fb_lp_serves_slot(&lp, 0) && !fb_lp_serves_slot(&lp, 1), "槽 a 的服务判断不对");
    e = fb_lp_read(rd, NULL, 1, &lp);
    CHECK(e == NULL && fb_lp_serves_slot(&lp, 1), "槽 b：%s", e ? e : "不服务");
    CHECK(fb_lp_read(rd, NULL, 2, &lp) != NULL, "不存在的元数据槽没拒");

    mk_super(none, b);
    CHECK(fb_lp_read(rd, NULL, 0, &lp) == NULL && !fb_lp_serves_slot(&lp, 0), "空槽 a 应解析成功但不服务");

    mk_super(a, b);
    super_img[4096 + 8192 + 256 + 3] ^= 1;      /* 改表里一个字节 → 表校验和不对 */
    e = fb_lp_read(rd, NULL, 0, &lp);
    CHECK(e && strstr(e, "tables checksum"), "表被改没发现：%s", e ? e : "(null)");
    mk_super(a, b);
    super_img[4096 + 8192 + 44] ^= 1;           /* 改头 → 头校验和不对 */
    CHECK(fb_lp_read(rd, NULL, 0, &lp) != NULL, "头被改没发现");
    mk_super(a, b);
    super_img[4096 + 40] ^= 1;                  /* 改几何区 */
    e = fb_lp_read(rd, NULL, 0, &lp);
    CHECK(e && strstr(e, "geometry checksum"), "几何区被改没发现：%s", e ? e : "(null)");
    memset(super_img, 0, sizeof(super_img));
    e = fb_lp_read(rd, NULL, 0, &lp);
    CHECK(e && strstr(e, "geometry magic"), "全零没报魔数：%s", e ? e : "(null)");
}

int main(void)
{
    test_sha256();
    test_sparse();
    test_lp();
    printf("test_fbd：通过 %d，失败 %d\n", pass, fail);
    return fail ? 1 : 0;
}

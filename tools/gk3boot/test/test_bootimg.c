/* boot.img：实机发布版 1791053208 的头（向量里只放头那一页）+ 可选的整份镜像复算 + 合成镜像对拍。 */
#ifdef __APPLE__
#define COMMON_DIGEST_FOR_OPENSSL
#include <CommonCrypto/CommonDigest.h>
#endif
#include "t.h"

#define PART_SIZE 67108864ull   /* boot_a / boot_b：131072 扇区（实机 GPT） */

static void hex20(const uint8_t *d, char out[41])
{
    for (int i = 0; i < 20; i++)
        snprintf(out + 2 * i, 3, "%02x", d[i]);
}

/* 合成一份 vN 镜像；id 用独立的 CommonCrypto（或者跳过）算 */
static unsigned char *synth(unsigned ver, unsigned page, const uint32_t sz[5], size_t *len)
{
    uint64_t off = page;
    size_t total = page;
    unsigned char *img, *h;
    for (int i = 0; i < 5; i++)
        total += (sz[i] + page - 1) / page * page;
    img = calloc(1, total);
    h = img;
    memcpy(h, "ANDROID!", 8);
    gk3_put_le32(h + 8, sz[0]);
    gk3_put_le32(h + 16, sz[1]);
    gk3_put_le32(h + 24, sz[2]);
    gk3_put_le32(h + 36, page);
    gk3_put_le32(h + 40, ver);
    strcpy((char *)h + 64, "console=tty0");
    if (ver >= 1) {
        gk3_put_le32(h + 1632, sz[3]);
        gk3_put_le32(h + 1644, ver == 1 ? 1648 : 1660);
    }
    if (ver >= 2)
        gk3_put_le32(h + 1648, sz[4]);
    for (int i = 0; i < 5; i++) {
        for (uint32_t k = 0; k < sz[i]; k++)
            img[off + k] = (unsigned char)(rand() & 0xff);
        off += (sz[i] + page - 1) / page * page;
    }
#ifdef __APPLE__
    {
        CC_SHA1_CTX c;
        uint8_t le[4];
        unsigned nseg = ver == 0 ? 3 : ver == 1 ? 4 : 5;
        off = page;
        CC_SHA1_Init(&c);
        for (unsigned i = 0; i < 5; i++) {
            if (i < nseg) {
                CC_SHA1_Update(&c, img + off, sz[i]);
                gk3_put_le32(le, sz[i]);
                CC_SHA1_Update(&c, le, 4);
            }
            off += (sz[i] + page - 1) / page * page;
        }
        CC_SHA1_Final(h + 576, &c);
    }
#endif
    *len = total;
    return img;
}

void test_bootimg(void)
{
    size_t len;
    unsigned char *h = t_vector("boot-1791053208-hdr.bin", &len), *bad;
    gk3_bootimg b;
    char hex[41], cmd[2048];
    uint8_t got[20];
    const char *full = getenv("GK3_BOOTIMG");

    if (!h)
        return;
    CHECK_EQ(gk3_bootimg_parse(h, len, PART_SIZE, &b), GK3_OK);
    CHECK_EQ(b.version, 2);
    CHECK_EQ(b.page_size, 2048);
    CHECK_EQ(b.kernel_size, 15589888);          /* 设计稿 §2.2 */
    CHECK_EQ(b.ramdisk_size, 13080354);
    CHECK_EQ(b.dtb_size, 173345);
    CHECK_EQ(b.second_size, 0);
    CHECK_EQ(b.recovery_dtbo_size, 0);
    CHECK_EQ(b.total_size, 28848128);           /* = 文件大小 */
    CHECK_EQ(b.dtb_off, 2048 + 15591424 + 13080576);
    hex20(b.id, hex);
    CHECK(strncmp(hex, "9274d5f8", 8) == 0 && strcmp(hex + 34, "e885e0") == 0, "头里的 id = %s", hex);
    CHECK(gk3_is_zero(b.id + 20, 12), "id 后 12 字节为零");
    CHECK(gk3_bootimg_cmdline(&b, cmd, sizeof(cmd)) > 0, "cmdline");
    CHECK(strstr(cmd, "androidboot.slot_suffix") == NULL, "头里不含 slot_suffix（BoardConfig.mk:107-110）");
    CHECK(gk3_is_zero(h + 608, 1024), "extra_cmdline 为空");
    CHECK_EQ(gk3_bootimg_cmdline(&b, cmd, 10), -1);

    if (full && *full) {
        size_t n;
        unsigned char *img = t_slurp(full, &n);
        CHECK(img != NULL, "GK3_BOOTIMG=%s 读不到", full);
        if (img) {
            CHECK_EQ(n, 28848128);
            CHECK_EQ(gk3_bootimg_parse(img, n, PART_SIZE, &b), GK3_OK);
            CHECK_EQ(gk3_bootimg_verify_id(&b, img, n, got), GK3_OK);
            hex20(got, hex);
            printf("    整份 boot.img 复算 SHA1(id) = %s（与头一致）\n", hex);
            img[b.dtb_off + 100] ^= 1;                        /* 坏一个字节 */
            CHECK_EQ(gk3_bootimg_verify_id(&b, img, n, got), GK3_EVERIFY);
            img[b.dtb_off + 100] ^= 1;
            CHECK_EQ(gk3_bootimg_verify_id(&b, img, n - 1, got), GK3_ENOSPC);
            free(img);
        }
    } else {
        printf("    （没设 GK3_BOOTIMG，跳过整份镜像复算）\n");
    }

    /* 合成镜像：v0/v1/v2 × 各页大小，独立实现算的 id 必须对上 */
#ifdef __APPLE__
    srand(77);
    for (unsigned ver = 0; ver <= 2; ver++)
        for (unsigned page = 2048; page <= 16384; page *= 2) {
            uint32_t sz[5] = {(uint32_t)(1 + rand() % 70000), (uint32_t)(rand() % 50000),
                              (uint32_t)(rand() % 3 ? 0 : rand() % 9000),
                              ver >= 1 ? (uint32_t)(rand() % 5000) : 0, ver >= 2 ? (uint32_t)(rand() % 20000) : 0};
            unsigned char *img = synth(ver, page, sz, &len);
            CHECK_EQ(gk3_bootimg_parse(img, len, 0, &b), GK3_OK);
            CHECK_EQ(b.total_size, len);
            CHECK(gk3_bootimg_verify_id(&b, img, len, got) == GK3_OK, "合成 v%u page %u", ver, page);
            free(img);
        }
#endif

    /* 坏头 */
    bad = malloc(2048);
#define FRESH() memcpy(bad, h, 2048)
    FRESH(); bad[0] = 'a';
    CHECK_EQ(gk3_bootimg_parse(bad, 2048, 0, &b), GK3_EMAGIC);
    FRESH(); gk3_put_le32(bad + 40, 3);
    CHECK_EQ(gk3_bootimg_parse(bad, 2048, 0, &b), GK3_EVERSION);
    FRESH(); gk3_put_le32(bad + 36, 1000);
    CHECK_EQ(gk3_bootimg_parse(bad, 2048, 0, &b), GK3_ERANGE);
    FRESH(); gk3_put_le32(bad + 1644, 1648);
    CHECK_EQ(gk3_bootimg_parse(bad, 2048, 0, &b), GK3_ERANGE);       /* v2 头却写着 v1 的 header_size */
    FRESH(); gk3_put_le32(bad + 8, 0);
    CHECK_EQ(gk3_bootimg_parse(bad, 2048, 0, &b), GK3_ERANGE);
    FRESH(); gk3_put_le32(bad + 16, 0xffffffffu); gk3_put_le32(bad + 1648, 0xffffffffu);
    CHECK_EQ(gk3_bootimg_parse(bad, 2048, PART_SIZE, &b), GK3_ERANGE);   /* 超出分区 */
    FRESH();
    CHECK_EQ(gk3_bootimg_parse(bad, 2048, 28848128 - 1, &b), GK3_ERANGE);
    CHECK_EQ(gk3_bootimg_parse(bad, 1650, 0, &b), GK3_ENOSPC);       /* v2 头不足 1660 */
#undef FRESH
    free(bad);
    free(h);
}

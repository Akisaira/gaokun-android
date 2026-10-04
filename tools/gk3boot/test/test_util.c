/* CRC32 / SHA-1：标准向量 + 独立实现对拍（zlib 的 crc32；macOS 上 CommonCrypto 的 SHA-1）。 */
#include <zlib.h>
#ifdef __APPLE__
#define COMMON_DIGEST_FOR_OPENSSL
#include <CommonCrypto/CommonDigest.h>
#endif
#include "t.h"

static void sha1_hex(const void *p, size_t n, char out[41])
{
    gk3_sha1_ctx c;
    uint8_t d[20];
    gk3_sha1_init(&c);
    gk3_sha1_update(&c, p, n);
    gk3_sha1_final(&c, d);
    for (int i = 0; i < 20; i++)
        snprintf(out + 2 * i, 3, "%02x", d[i]);
}

void test_util(void)
{
    char h[41];
    unsigned char *big;
    uint8_t le[8];

    /* CRC-32/ISO-HDLC 的 check 值 */
    CHECK_EQ(gk3_crc32(0, "123456789", 9), 0xCBF43926u);
    CHECK_EQ(gk3_crc32(0, "", 0), 0u);
    /* 链式 = 一次算 */
    CHECK_EQ(gk3_crc32(gk3_crc32(0, "12345", 5), "6789", 4), 0xCBF43926u);

    /* FIPS 180-2 附录 A 的向量 */
    sha1_hex("abc", 3, h);
    CHECK_STR(h, "a9993e364706816aba3e25717850c26c9cd0d89d");
    sha1_hex("", 0, h);
    CHECK_STR(h, "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    sha1_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, h);
    CHECK_STR(h, "84983e441c3bd26ebaae4aa1f95129e5e54670f1");
    big = malloc(1000000);
    memset(big, 'a', 1000000);
    sha1_hex(big, 1000000, h);
    CHECK_STR(h, "34aa973cd4c4daa4f61eeb2bdbad27316534016f");

    /* 随机长度、随机切块，与 zlib / CommonCrypto 对拍 */
    {
    int f0 = t_fail;
    srand(20261005);
    for (int r = 0; r < 300; r++) {
        size_t n = (size_t)(rand() % 5000);
        gk3_sha1_ctx c;
        uint8_t mine[20];
        size_t off = 0;
        for (size_t i = 0; i < n; i++)
            big[i] = (unsigned char)rand();
        CHECKQ(gk3_crc32(0, big, n) == (uint32_t)crc32(0L, big, (uInt)n), "CRC 与 zlib 不同（n=%zu）", n);
        gk3_sha1_init(&c);
        while (off < n) {
            size_t k = (size_t)(rand() % 130);
            if (k > n - off)
                k = n - off;
            gk3_sha1_update(&c, big + off, k);
            off += k;
        }
        gk3_sha1_final(&c, mine);
#ifdef __APPLE__
        {
            uint8_t ref[20];
            CC_SHA1(big, (CC_LONG)n, ref);
            CHECKQ(memcmp(mine, ref, 20) == 0, "SHA-1 与 CommonCrypto 不同（n=%zu）", n);
        }
#endif
    }
    CHECK(t_fail == f0, "300 组随机输入与 zlib / CommonCrypto 一致");
    }
    free(big);

    gk3_put_le64(le, 0x0102030405060708ull);
    CHECK(le[0] == 8 && le[7] == 1, "put_le64 字节序");
    CHECK_EQ(gk3_le64(le), 0x0102030405060708ll);
    CHECK_EQ(gk3_le16((const uint8_t *)"\x34\x12"), 0x1234);
    CHECK(gk3_is_zero("\0\0\0", 3) && !gk3_is_zero("\0\1", 2), "is_zero");
    CHECK_EQ(gk3_strnlen("abc", 2), 2);
}

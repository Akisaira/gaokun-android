/* libgk3core 主机测试入口。用法：test_core <向量目录>；环境变量 GK3_BOOTIMG 指向完整
 * boot.img 时额外复算整份镜像的 SHA1(id)（out/issues-1791053208/boot.img，29 MB，不入库）。 */
#include "t.h"

int t_pass, t_fail;
const char *t_vectors = "vectors";

unsigned char *t_slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    unsigned char *buf;
    long n;
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc(n ? (size_t)n : 1);
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fclose(f);
        free(buf);
        return NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

unsigned char *t_vector(const char *name, size_t *len)
{
    char path[1024];
    unsigned char *p;
    snprintf(path, sizeof(path), "%s/%s", t_vectors, name);
    p = t_slurp(path, len);
    CHECK(p != NULL, "读不到向量 %s", path);
    return p;
}

void t_hex(const char *label, const void *p, size_t n)
{
    const unsigned char *b = p;
    printf("%s", label);
    for (size_t i = 0; i < n; i++)
        printf("%s%02x", i ? " " : "", b[i]);
    printf("\n");
}

static int md_read(void *ctx, uint64_t lba, uint32_t count, void *buf)
{
    t_memdev *m = ctx;
    if ((lba + count) * m->bs > m->len)
        return -1;
    memcpy(buf, m->data + lba * m->bs, (size_t)count * m->bs);
    return 0;
}

static int md_write(void *ctx, uint64_t lba, uint32_t count, const void *buf)
{
    t_memdev *m = ctx;
    if ((lba + count) * m->bs > m->len)
        return -1;
    if (m->fail_write_at >= 0 && m->writes == m->fail_write_at) {
        m->writes++;
        return -1;
    }
    memcpy(m->data + lba * m->bs, buf, (size_t)count * m->bs);
    if (m->corrupt_after >= 0 && m->writes == m->corrupt_after)
        m->data[lba * m->bs] ^= 0xff;
    m->writes++;
    return 0;
}

void t_memdev_bind(t_memdev *m, gk3_blk *dev)
{
    dev->ctx = m;
    dev->block_size = m->bs;
    dev->num_blocks = m->len / m->bs;
    dev->read = md_read;
    dev->write = md_write;
    dev->flush = NULL;
}

int main(int argc, char **argv)
{
    static const struct { const char *name; void (*fn)(void); } groups[] = {
        {"util（CRC32 / SHA-1 / 小端）", test_util},
        {"gpt", test_gpt},
        {"bcb", test_bcb},
        {"bcab / 选槽", test_bcab},
        {"实机 misc", test_realmisc},
        {"gk3 记录", test_gk3rec},
        {"BCB 分派决定", test_dispatch},
        {"双系统决定（S15）", test_dual},
        {"boot.img", test_bootimg},
        {"cmdline", test_cmdline},
        {"块设备读改写", test_blk},
        {"随机输入（解析器不崩）", test_fuzz},
    };
    if (argc > 1)
        t_vectors = argv[1];
    for (size_t i = 0; i < sizeof(groups) / sizeof(groups[0]); i++) {
        int p0 = t_pass, f0 = t_fail;
        groups[i].fn();
        printf("%-28s 通过 %4d  失败 %d\n", groups[i].name, t_pass - p0, t_fail - f0);
    }
    printf("== libgk3core：通过 %d，失败 %d ==\n", t_pass, t_fail);
    return t_fail ? 1 : 0;
}

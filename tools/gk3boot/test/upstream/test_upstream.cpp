// 逐字节对拍：把 hardware/interfaces（1a56e38）真正的 libboot_control.cpp 编进来（垫片见 shim/），
// 和 libgk3core 的 BCAB 原语在同一份 misc 镜像上跑同样的随机操作序列，每步比较 misc+2048 的 32 字节。
//
// 被测的上游函数：BootControl::Init（含 CRC 坏时 InitDefaultBootloaderControl，:195-242 / :115-182）、
// SetActiveBootSlot（:282-314）、MarkBootSuccessful（:252-262）、SetSlotAsUnbootable（:316-330）、
// GetSnapshotMergeStatus → GetMiscVirtualAbMergeStatus（:422-440）。
// 另外直接用上游头文件里的位域结构体核对布局（boot_control_definition.h:62-107）。
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>

#include <android-base/properties.h>
#include <bootloader_message/bootloader_message.h>
#include <libboot_control/libboot_control.h>
#include "private/boot_control_definition.h"

#include "gk3core.h"

// libboot_control.cpp:75-78 定义了它但头文件没声明
namespace android {
namespace bootable {
uint32_t BootloaderControlLECRC(const bootloader_control *boot_ctrl);
}
}  // namespace android

static std::string g_misc;
static int pass, fail;

#define CHECK(c, ...)                                                    \
    do {                                                                 \
        if (c) pass++;                                                   \
        else {                                                           \
            fail++;                                                      \
            fprintf(stderr, "  失败 %s:%d: %s —— ", __FILE__, __LINE__, #c); \
            fprintf(stderr, __VA_ARGS__);                                \
            fputc('\n', stderr);                                         \
        }                                                                \
    } while (0)

// 循环里只记失败；每批结束再记一条"这一批全对"
#define CHECKQ(c, ...)                                                   \
    do {                                                                 \
        if (!(c)) {                                                      \
            fail++;                                                      \
            fprintf(stderr, "  失败 %s:%d: %s —— ", __FILE__, __LINE__, #c); \
            fprintf(stderr, __VA_ARGS__);                                \
            fputc('\n', stderr);                                         \
        }                                                                \
    } while (0)

// —— bootloader_message 里 libboot_control 用到的那几个函数，落到测试的 misc 文件上 ——
std::string get_bootloader_message_blk_device(std::string *) { return g_misc; }

static bool rw_at(void *buf, size_t n, off_t off, bool wr)
{
    int fd = open(g_misc.c_str(), wr ? O_WRONLY : O_RDONLY);
    if (fd < 0) return false;
    ssize_t r = wr ? pwrite(fd, buf, n, off) : pread(fd, buf, n, off);
    close(fd);
    return r == (ssize_t)n;
}
bool ReadMiscVirtualAbMessage(misc_virtual_ab_message *m, std::string *)
{
    return rw_at(m, sizeof(*m), SYSTEM_SPACE_OFFSET_IN_MISC, false);
}
bool WriteMiscVirtualAbMessage(const misc_virtual_ab_message &m, std::string *)
{
    return rw_at(const_cast<misc_virtual_ab_message *>(&m), sizeof(m), SYSTEM_SPACE_OFFSET_IN_MISC, true);
}

static void read_bc(uint8_t out[32]) { rw_at(out, 32, 2048, false); }
static void write_bc(const uint8_t in[32]) { rw_at(const_cast<uint8_t *>(in), 32, 2048, true); }

static void layout()
{
    static_assert(sizeof(bootloader_control) == 32, "");
    static_assert(offsetof(bootloader_control, magic) == 4, "");
    static_assert(offsetof(bootloader_control, version) == 8, "");
    static_assert(offsetof(bootloader_control, reserved0) == 11, "");
    static_assert(offsetof(bootloader_control, slot_info) == 12, "");
    static_assert(offsetof(bootloader_control, reserved1) == 20, "");
    static_assert(offsetof(bootloader_control, crc32_le) == 28, "");
    static_assert(offsetof(bootloader_message_ab, slot_suffix) == GK3_MISC_BCAB_OFF, "");
    static_assert(sizeof(misc_virtual_ab_message) == 64, "");
    static_assert(SYSTEM_SPACE_OFFSET_IN_MISC == GK3_MISC_SYSTEM_OFF, "");
    static_assert(VENDOR_SPACE_OFFSET_IN_MISC == GK3_MISC_BCAB_OFF, "");
    static_assert(WIPE_PACKAGE_OFFSET_IN_MISC == GK3_MISC_WIPE_OFF, "");
    static_assert(BOOT_CTRL_MAGIC == GK3_BCAB_MAGIC && BOOT_CTRL_VERSION == GK3_BCAB_VERSION, "");
    static_assert(MISC_VIRTUAL_AB_MAGIC_HEADER == GK3_VAB_MAGIC && MISC_VIRTUAL_AB_MESSAGE_VERSION == GK3_VAB_VERSION, "");

    // 位域的位置：用上游结构体写，用我们的按位读
    int f0 = fail;
    std::mt19937 rng(7);
    for (int r = 0; r < 5000; r++) {
        bootloader_control bc;
        memset(&bc, 0, sizeof(bc));
        bc.nb_slot = rng() & 7;
        bc.recovery_tries_remaining = rng() & 7;
        bc.merge_status = rng() & 7;
        for (int i = 0; i < 4; i++) {
            bc.slot_info[i].priority = rng() & 15;
            bc.slot_info[i].tries_remaining = rng() & 7;
            bc.slot_info[i].successful_boot = rng() & 1;
            bc.slot_info[i].verity_corrupted = rng() & 1;
            bc.slot_info[i].reserved = rng() & 127;
        }
        const uint8_t *b = reinterpret_cast<const uint8_t *>(&bc);
        CHECKQ(gk3_bcab_nb_slot(b) == bc.nb_slot && gk3_bcab_recovery_tries(b) == bc.recovery_tries_remaining &&
                  gk3_bcab_merge_status(b) == bc.merge_status,
              "控制位");
        for (unsigned i = 0; i < 4; i++) {
            gk3_slot_info s;
            gk3_bcab_get_slot(b, i, &s);
            CHECKQ(s.priority == bc.slot_info[i].priority && s.tries == bc.slot_info[i].tries_remaining &&
                      s.successful == bc.slot_info[i].successful_boot &&
                      s.verity_corrupted == bc.slot_info[i].verity_corrupted,
                  "槽 %u", i);
            // 反过来：我们写、上游读，reserved 不动
            uint8_t mine[32];
            memcpy(mine, b, 32);
            s.priority = rng() & 15; s.tries = rng() & 7; s.successful = rng() & 1; s.verity_corrupted = rng() & 1;
            gk3_bcab_set_slot(mine, i, &s);
            const bootloader_control *m = reinterpret_cast<const bootloader_control *>(mine);
            CHECKQ(m->slot_info[i].priority == s.priority && m->slot_info[i].tries_remaining == s.tries &&
                      m->slot_info[i].successful_boot == s.successful &&
                      m->slot_info[i].verity_corrupted == s.verity_corrupted &&
                      m->slot_info[i].reserved == bc.slot_info[i].reserved,
                  "写槽 %u", i);
        }
        // CRC：上游的函数 vs 我们的
        CHECKQ(android::bootable::BootloaderControlLECRC(&bc) == gk3_bcab_crc(b), "CRC");
    }
    CHECK(fail == f0, "位域布局与 CRC：5000 组随机结构体（上游写我们读、我们写上游读）全一致");
}

static void differential(const std::string &dir)
{
    int f0 = fail;
    std::mt19937 rng(20261005);
    int steps = 0, inits = 0;
    for (int trial = 0; trial < 3000; trial++) {
        uint8_t init[32], mine[32], theirs[32];
        unsigned cur = rng() & 1;
        // 起始状态：大多是合法的随机 BCAB；1/6 的样本 CRC 坏（让上游走重建）
        gk3_bcab_init_default(init, cur, 2);
        for (int i = 0; i < 32; i++)
            if (i < 28 && i != 4 && i != 5 && i != 6 && i != 7 && i != 9 && (rng() % 3 == 0)) init[i] = rng();
        init[9] = (uint8_t)((init[9] & ~7) | 2);  // nb_slot 保持 2（HAL 的 num_slots_ 取自它）
        gk3_bcab_update_crc(init);
        bool corrupt = rng() % 6 == 0;
        if (corrupt) init[28] ^= 0x5a;
        {
            std::vector<uint8_t> zero(65536, 0);
            rw_at(zero.data(), zero.size(), 0, true);
        }
        write_bc(init);

        android::base::test_props()["ro.boot.slot_suffix"] = cur ? "_b" : "_a";
        android::bootable::BootControl hal;
        bool ok = hal.Init();
        CHECKQ(ok, "Init 失败");
        if (!ok) continue;
        memcpy(mine, init, 32);
        if (corrupt) {
            gk3_bcab_init_default(mine, cur, 2);  // HAL 数 boot_a/boot_b 得 2
            inits++;
        }
        read_bc(theirs);
        CHECKQ(!memcmp(mine, theirs, 32), "Init 之后不同（corrupt=%d）", corrupt);

        for (int k = 0; k < 12; k++, steps++) {
            unsigned op = rng() % 3, slot = rng() % 3;
            bool r1 = false;
            gk3_err r2 = GK3_OK;
            switch (op) {
            case 0: r1 = hal.SetActiveBootSlot(slot); r2 = gk3_bcab_set_active(mine, slot, cur); break;
            case 1: r1 = hal.MarkBootSuccessful(); r2 = gk3_bcab_mark_successful(mine, cur); break;
            case 2: r1 = hal.SetSlotAsUnbootable(slot); r2 = gk3_bcab_set_unbootable(mine, slot); break;
            }
            CHECKQ(r1 == (r2 == GK3_OK), "op %u slot %u 返回值不同", op, slot);
            read_bc(theirs);
            CHECKQ(!memcmp(mine, theirs, 32), "op %u slot %u 之后字节不同", op, slot);
            // 上游的查询 vs 我们的解码（IsSlotBootable :332-342 = tries!=0；IsSlotMarkedSuccessful :344-354）
            for (unsigned i = 0; i < 2; i++) {
                gk3_slot_info s;
                gk3_bcab_get_slot(mine, i, &s);
                CHECKQ(hal.IsSlotBootable(i) == (s.tries != 0), "IsSlotBootable(%u)", i);
                CHECKQ(hal.IsSlotMarkedSuccessful(i) == (s.successful && s.tries), "IsSlotMarkedSuccessful(%u)", i);
            }
        }
        // VAB：GetSnapshotMergeStatus vs gk3_vab_effective
        for (int k = 0; k < 4; k++) {
            uint8_t m[64] = {0};
            m[0] = GK3_VAB_VERSION;
            gk3_put_le32(m + 1, GK3_VAB_MAGIC);
            m[5] = rng() % 5;
            m[6] = rng() % 2;
            rw_at(m, 64, 32768, true);
            gk3_vab v;
            gk3_vab_parse(m, &v);
            CHECKQ((uint8_t)hal.GetSnapshotMergeStatus() == gk3_vab_effective(&v, cur), "merge status");
        }
    }
    CHECK(fail == f0, "%d 步之后 misc+2048 的 32 字节、返回值、IsSlotBootable/IsSlotMarkedSuccessful、merge status 全一致", steps);
    printf("    上游 libboot_control 对拍：%d 组 × 12 步 = %d 步，其中 %d 组走了 CRC 坏 → 重建\n", 3000, steps, inits);
}

int main()
{
    char tmpl[] = "/tmp/gk3-upstream-XXXXXX";
    const char *dir = mkdtemp(tmpl);
    if (!dir) return 2;
    g_misc = std::string(dir) + "/misc";
    // InitDefaultBootloaderControl 靠 stat "<misc 所在目录>/boot_a…_d" 数槽（:128-156）
    for (const char *n : {"/misc", "/boot_a", "/boot_b"}) {
        int fd = open((std::string(dir) + n).c_str(), O_CREAT | O_WRONLY, 0600);
        close(fd);
    }
    layout();
    differential(dir);
    for (const char *n : {"/misc", "/boot_a", "/boot_b"}) unlink((std::string(dir) + n).c_str());
    rmdir(dir);
    printf("== 上游对拍：通过 %d，失败 %d ==\n", pass, fail);
    return fail ? 1 : 0;
}

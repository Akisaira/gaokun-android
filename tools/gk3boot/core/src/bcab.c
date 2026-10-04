/* libgk3core：bootloader_control（misc 偏移 2048，32 字节）与选槽。
 *
 * 布局：hardware/interfaces boot/1.1/default/boot_control/include/private/boot_control_definition.h:59-107
 * （1a56e38；crDroid 树 2026-10-05 已核对一致）。那里用的是 packed 位域；这里按字节和位号显式读写，
 * 位号取 GBL libgbl/src/slots/android.rs:77-87（每槽 u16）与 :146-153（控制位 u16，跨字节 9–10），
 * 并用实机 misc（CRC 67 dd c3 20）和 test_upstream.cpp（编译真正的 libboot_control.cpp）逐字节对拍。
 *
 * 写的语义一律照 libboot_control.cpp（§2.3、E-K4），不照 GBL（GBL 的 set_active 写 7/7/6，§8.2 #11）。 */
#include "gk3core.h"

#define OFF_MAGIC 4
#define OFF_VERSION 8
#define OFF_CTRL 9
#define OFF_SLOTS 12
#define OFF_CRC 28

uint32_t gk3_bcab_crc(const uint8_t bc[32])
{
    return gk3_crc32(0, bc, OFF_CRC);
}

void gk3_bcab_update_crc(uint8_t bc[32])
{
    gk3_put_le32(bc + OFF_CRC, gk3_bcab_crc(bc));
}

static uint16_t ctrl(const uint8_t bc[32]) { return gk3_le16(bc + OFF_CTRL); }

uint8_t gk3_bcab_nb_slot(const uint8_t bc[32]) { return ctrl(bc) & 7; }
uint8_t gk3_bcab_recovery_tries(const uint8_t bc[32]) { return (ctrl(bc) >> 3) & 7; }
uint8_t gk3_bcab_merge_status(const uint8_t bc[32]) { return (ctrl(bc) >> 6) & 7; }

gk3_err gk3_bcab_validate(const uint8_t bc[32])
{
    if (gk3_le32(bc + OFF_MAGIC) != GK3_BCAB_MAGIC)
        return GK3_EMAGIC;
    if (bc[OFF_VERSION] != GK3_BCAB_VERSION)
        return GK3_EVERSION;
    if (gk3_le32(bc + OFF_CRC) != gk3_bcab_crc(bc))
        return GK3_ECRC;
    if (gk3_bcab_nb_slot(bc) != 2)
        return GK3_ESLOTS;
    return GK3_OK;
}

void gk3_bcab_get_slot(const uint8_t bc[32], unsigned slot, gk3_slot_info *out)
{
    uint16_t v = gk3_le16(bc + OFF_SLOTS + 2 * (slot & 3));
    out->priority = v & 15;
    out->tries = (v >> 4) & 7;
    out->successful = (v >> 7) & 1;
    out->verity_corrupted = (v >> 8) & 1;
}

void gk3_bcab_set_slot(uint8_t bc[32], unsigned slot, const gk3_slot_info *in)
{
    uint8_t *p = bc + OFF_SLOTS + 2 * (slot & 3);
    uint16_t v = gk3_le16(p) & ~(uint16_t)0x01FF;       /* 保留 reserved[9:15] */
    v |= (uint16_t)(in->priority & 15);
    v |= (uint16_t)((in->tries & 7) << 4);
    v |= (uint16_t)((in->successful ? 1 : 0) << 7);
    v |= (uint16_t)((in->verity_corrupted ? 1 : 0) << 8);
    gk3_put_le16(p, v);
}

/* —— libboot_control 原语。HAL 先 Load 再改再 Save（:97-113），Save 时重算 CRC；
 *    不管读进来的 CRC 对不对 —— Init 时 CRC 坏才会重建（:228-234）。这里同样不查。 */

gk3_err gk3_bcab_set_active(uint8_t bc[32], unsigned slot, unsigned current_slot)
{
    unsigned n = gk3_bcab_nb_slot(bc);
    gk3_slot_info s;
    if (slot >= GK3_BCAB_MAX_SLOTS || slot >= n)
        return GK3_EINVAL;                               /* :283-286 */
    for (unsigned i = 0; i < n; i++) {                   /* :294-299 */
        if (i == slot)
            continue;
        gk3_bcab_get_slot(bc, i, &s);
        if (s.priority >= GK3_ACTIVE_PRIORITY) {
            s.priority = GK3_ACTIVE_PRIORITY - 1;
            gk3_bcab_set_slot(bc, i, &s);
        }
    }
    gk3_bcab_get_slot(bc, slot, &s);
    s.priority = GK3_ACTIVE_PRIORITY;                    /* :303-304 */
    s.tries = GK3_ACTIVE_TRIES;
    if (slot != current_slot)                            /* :311 */
        s.verity_corrupted = false;
    gk3_bcab_set_slot(bc, slot, &s);
    gk3_bcab_update_crc(bc);
    return GK3_OK;
}

gk3_err gk3_bcab_mark_successful(uint8_t bc[32], unsigned slot)
{
    gk3_slot_info s;
    if (slot >= GK3_BCAB_MAX_SLOTS)
        return GK3_EINVAL;
    gk3_bcab_get_slot(bc, slot, &s);
    s.successful = true;                                 /* :256 */
    s.tries = 1;                                         /* :260 */
    gk3_bcab_set_slot(bc, slot, &s);
    gk3_bcab_update_crc(bc);
    return GK3_OK;
}

gk3_err gk3_bcab_set_unbootable(uint8_t bc[32], unsigned slot)
{
    gk3_slot_info s;
    if (slot >= GK3_BCAB_MAX_SLOTS || slot >= gk3_bcab_nb_slot(bc))
        return GK3_EINVAL;                               /* :317-320 */
    gk3_bcab_get_slot(bc, slot, &s);
    s.successful = false;                                /* :327-328 */
    s.tries = 0;
    gk3_bcab_set_slot(bc, slot, &s);
    gk3_bcab_update_crc(bc);
    return GK3_OK;
}

void gk3_bcab_init_default(uint8_t bc[32], unsigned current_slot, unsigned nb_slot)
{
    static const char suf[4][3] = {"_a", "_b", "_c", "_d"};
    gk3_memset(bc, 0, 32);                               /* :116 */
    if (current_slot < GK3_BCAB_MAX_SLOTS)               /* :119-121 */
        gk3_memcpy(bc, suf[current_slot], 2);
    gk3_put_le32(bc + OFF_MAGIC, GK3_BCAB_MAGIC);
    bc[OFF_VERSION] = GK3_BCAB_VERSION;
    if (nb_slot > GK3_BCAB_MAX_SLOTS)
        nb_slot = GK3_BCAB_MAX_SLOTS;
    gk3_put_le16(bc + OFF_CTRL, (uint16_t)(nb_slot & 7)); /* recovery_tries=0、merge_status=0 */
    for (unsigned i = 0; i < GK3_BCAB_MAX_SLOTS; i++) {  /* :158-178 */
        gk3_slot_info s = {0, 0, false, false};
        if (i < nb_slot) {
            s.priority = 7;
            s.tries = GK3_DEFAULT_BOOT_ATTEMPTS;
        }
        if (i == current_slot)
            s.successful = true;
        gk3_bcab_set_slot(bc, i, &s);
    }
    gk3_bcab_update_crc(bc);                             /* :181 */
}

void gk3_bcab_init_install(uint8_t bc[32], unsigned slot)
{
    gk3_slot_info act = {GK3_ACTIVE_PRIORITY, GK3_ACTIVE_TRIES, false, false};
    gk3_slot_info off = {0, 0, false, false};
    slot &= 1;
    gk3_memset(bc, 0, 32);
    bc[0] = '_';
    bc[1] = (uint8_t)('a' + slot);
    gk3_put_le32(bc + OFF_MAGIC, GK3_BCAB_MAGIC);
    bc[OFF_VERSION] = GK3_BCAB_VERSION;
    gk3_put_le16(bc + OFF_CTRL, 2);
    gk3_bcab_set_slot(bc, slot, &act);
    gk3_bcab_set_slot(bc, slot ^ 1, &off);
    gk3_bcab_update_crc(bc);
}

/* —— 入口侧 —— */

bool gk3_slot_bootable(const gk3_slot_info *s)
{
    return s->priority > 0 && (s->tries > 0 || s->successful);
}

void gk3_select_slot(uint8_t bc[32], unsigned hint, uint8_t merge_status, gk3_sel *out)
{
    gk3_slot_info s[2];
    int best = -1;
    unsigned active;

    gk3_memset(out, 0, sizeof(*out));
    out->bcab_err = gk3_bcab_validate(bc);
    if (out->bcab_err) {                                 /* §4.3.2-1：坏了不写，按 hint 启动 */
        out->kind = GK3_SEL_BCAB_INVALID;
        out->slot = out->active = hint & 1;
        return;
    }
    gk3_bcab_get_slot(bc, 0, &s[0]);
    gk3_bcab_get_slot(bc, 1, &s[1]);
    /* active = priority 最高的槽，同分取 _a（GetActiveBootSlot :264-280 的口径，平局按 GBL rank） */
    active = s[1].priority > s[0].priority ? 1 : 0;
    out->active = active;
    /* GBL get_boot_target（android.rs:295-305）：可启动的槽里 max_by (priority, -suffix) */
    for (int i = 0; i < 2; i++) {
        if (!gk3_slot_bootable(&s[i]))
            continue;
        if (best < 0 || s[i].priority > s[best].priority)
            best = i;
    }
    if (merge_status == GK3_MERGE_MERGING && !gk3_slot_bootable(&s[active])) {
        out->kind = GK3_SEL_MERGING;                     /* §4.3.2-4：合并中不换槽 */
        out->slot = active;
        return;
    }
    if (best < 0) {
        out->kind = GK3_SEL_NOSLOT;                      /* §4.3.2-5：不猜 */
        out->slot = active;
        return;
    }
    out->kind = GK3_SEL_BOOT;
    out->slot = (unsigned)best;
    out->fallback = (unsigned)best != active;
    out->tries_before = out->tries_after = s[best].tries;
    /* mark_boot_attempt（android.rs:343-355）：Retriable 扣 1，Successful 不扣 */
    if (!s[best].successful) {
        s[best].tries--;                                 /* bootable 且未成功 ⇒ tries ≥ 1 */
        gk3_bcab_set_slot(bc, (unsigned)best, &s[best]);
        gk3_bcab_update_crc(bc);
        out->decremented = true;
        out->tries_after = s[best].tries;
    }
}

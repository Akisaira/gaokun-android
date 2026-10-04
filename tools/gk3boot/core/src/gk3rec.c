/* libgk3core：GK3 记录（misc 偏移 8 KiB，2048 字节；布局见 gk3core.h）。
 *
 * 位置依据：bootloader_message.h:24-30 把 2K–16K 划给 "Vendor's bootloader"，我们就是这个
 * vendor bootloader；实机 2026-10-05 读出 2K+32 到 32K 全零（tools/gk3boot/test/vectors/misc-*.bin）。
 * 设计稿 §4.5 要求：先算 CRC、写完读回；CRC 无效视为"无记录"，不影响启动。 */
#include "gk3core.h"

#define O_MAGIC 0
#define O_VERSION 4
#define O_SIZE 6
#define O_FLAGS 8
#define O_DISPVER 12
#define O_SEQ 16
#define O_STREAK 20
#define O_NEXT_KIND 21
#define O_NEXT_SLOT 22
#define O_DISP_WHY 23
#define O_DISP_SLOT 24
#define O_DISP_COUNT 25
#define O_EV_HEAD 26
#define O_DISP_DIGEST 28
#define O_MIG_DIGEST 48
#define O_MIG_CMD 68
#define O_MIG_REC 100
#define MIG_REC_LEN 256
#define O_EVENTS 1024
#define EV_SIZE 16
#define O_CRC (GK3_REC_SIZE - 4)

_Static_assert(O_MIG_REC + MIG_REC_LEN <= O_EVENTS, "GK3 记录字段重叠");
_Static_assert(O_EVENTS + GK3_EV_N * EV_SIZE <= O_CRC, "事件环越界");

gk3_err gk3_rec_validate(const uint8_t rec[GK3_REC_SIZE])
{
    if (gk3_le32(rec + O_MAGIC) != GK3_REC_MAGIC)
        return GK3_EMAGIC;
    if (gk3_le16(rec + O_VERSION) != GK3_REC_VERSION)
        return GK3_EVERSION;
    if (gk3_le16(rec + O_SIZE) != GK3_REC_SIZE)
        return GK3_ERANGE;
    if (gk3_le32(rec + O_CRC) != gk3_crc32(0, rec, O_CRC))
        return GK3_ECRC;
    if (rec[O_EV_HEAD] >= GK3_EV_N)
        return GK3_ERANGE;
    return GK3_OK;
}

void gk3_rec_init(uint8_t rec[GK3_REC_SIZE])
{
    gk3_memset(rec, 0, GK3_REC_SIZE);
    gk3_put_le32(rec + O_MAGIC, GK3_REC_MAGIC);
    gk3_put_le16(rec + O_VERSION, GK3_REC_VERSION);
    gk3_put_le16(rec + O_SIZE, GK3_REC_SIZE);
    gk3_rec_seal(rec);
}

void gk3_rec_seal(uint8_t rec[GK3_REC_SIZE])
{
    gk3_put_le32(rec + O_CRC, gk3_crc32(0, rec, O_CRC));
}

uint32_t gk3_rec_flags(const uint8_t *rec) { return gk3_le32(rec + O_FLAGS); }
bool gk3_rec_migrated(const uint8_t *rec) { return gk3_rec_flags(rec) & GK3_REC_F_MIGRATED; }

void gk3_rec_migrate(uint8_t *rec, const uint8_t *bcb, uint32_t dispatch_ver)
{
    gk3_bcb_info info;
    size_t n;
    gk3_bcb_classify(bcb, &info);
    gk3_memcpy(rec + O_MIG_DIGEST, info.digest, 20);
    gk3_memcpy(rec + O_MIG_CMD, bcb + GK3_BCB_COMMAND_OFF, GK3_BCB_COMMAND_LEN);
    /* recovery 原文截前 255 字节，保证记录里一定有 NUL */
    n = gk3_strnlen((const char *)bcb + GK3_BCB_RECOVERY_OFF, MIG_REC_LEN - 1);
    gk3_memset(rec + O_MIG_REC, 0, MIG_REC_LEN);
    gk3_memcpy(rec + O_MIG_REC, bcb + GK3_BCB_RECOVERY_OFF, n);
    gk3_put_le32(rec + O_FLAGS, gk3_rec_flags(rec) | GK3_REC_F_MIGRATED);
    gk3_put_le32(rec + O_DISPVER, dispatch_ver);
    gk3_rec_event_add(rec, GK3_EV_MIGRATED, 0xff, dispatch_ver);
    if (!gk3_is_zero(bcb, GK3_MISC_BCB_SIZE))
        gk3_rec_event_add(rec, GK3_EV_BCB_DROPPED, 0xff, (uint32_t)info.kind);
}

void gk3_rec_migrated_command(const uint8_t *rec, char out[33])
{
    size_t n = gk3_strnlen((const char *)rec + O_MIG_CMD, 32);
    gk3_memcpy(out, rec + O_MIG_CMD, n);
    out[n] = 0;
}

uint8_t gk3_rec_boot_streak(const uint8_t *rec) { return rec[O_STREAK]; }
void gk3_rec_set_boot_streak(uint8_t *rec, uint8_t v) { rec[O_STREAK] = v; }
uint8_t gk3_rec_inc_boot_streak(uint8_t *rec)
{
    if (rec[O_STREAK] != 0xff)
        rec[O_STREAK]++;
    return rec[O_STREAK];
}

gk3_next_kind gk3_rec_next(const uint8_t *rec, uint8_t *slot)
{
    uint8_t k = rec[O_NEXT_KIND];
    if (slot)
        *slot = rec[O_NEXT_SLOT];
    if (k > GK3_NEXT_SLOT || (k == GK3_NEXT_SLOT && rec[O_NEXT_SLOT] > 1))
        return GK3_NEXT_NONE;            /* 不认识的意图当没有 */
    return (gk3_next_kind)k;
}

void gk3_rec_set_next(uint8_t *rec, gk3_next_kind k, uint8_t slot)
{
    rec[O_NEXT_KIND] = (uint8_t)k;
    rec[O_NEXT_SLOT] = k == GK3_NEXT_SLOT ? slot : 0;
}

uint8_t gk3_rec_dispatch_enter(uint8_t *rec, gk3_bcb_kind why, uint8_t slot, const uint8_t digest[20])
{
    if (rec[O_DISP_COUNT] && rec[O_DISP_WHY] == (uint8_t)why &&
        !gk3_memcmp(rec + O_DISP_DIGEST, digest, 20)) {
        if (rec[O_DISP_COUNT] != 0xff)
            rec[O_DISP_COUNT]++;
    } else {
        rec[O_DISP_COUNT] = 1;
        rec[O_DISP_WHY] = (uint8_t)why;
        gk3_memcpy(rec + O_DISP_DIGEST, digest, 20);
    }
    rec[O_DISP_SLOT] = slot;
    return rec[O_DISP_COUNT];
}

uint8_t gk3_rec_dispatch_count(const uint8_t *rec) { return rec[O_DISP_COUNT]; }
void gk3_rec_dispatch_digest(const uint8_t *rec, uint8_t out[20]) { gk3_memcpy(out, rec + O_DISP_DIGEST, 20); }
void gk3_rec_dispatch_reset(uint8_t *rec)
{
    rec[O_DISP_COUNT] = 0;
    rec[O_DISP_WHY] = 0;
    rec[O_DISP_SLOT] = 0;
    gk3_memset(rec + O_DISP_DIGEST, 0, 20);
}

uint32_t gk3_rec_event_add(uint8_t *rec, gk3_ev_code code, uint8_t slot, uint32_t aux)
{
    uint32_t seq = gk3_le32(rec + O_SEQ) + 1;
    uint8_t h = rec[O_EV_HEAD] % GK3_EV_N;
    uint8_t *e = rec + O_EVENTS + h * EV_SIZE;
    if (seq == 0)
        seq = 1;                          /* 0 留给"空槽" */
    gk3_put_le32(rec + O_SEQ, seq);
    gk3_put_le32(e, seq);
    gk3_put_le16(e + 4, (uint16_t)code);
    e[6] = slot;
    e[7] = 0;
    gk3_put_le32(e + 8, aux);
    gk3_put_le32(e + 12, 0);
    rec[O_EV_HEAD] = (uint8_t)((h + 1) % GK3_EV_N);
    return seq;
}

uint32_t gk3_rec_events(const uint8_t *rec, gk3_event *out, uint32_t max)
{
    uint32_t n = 0;
    uint8_t h = rec[O_EV_HEAD] % GK3_EV_N;
    for (uint32_t k = 0; k < GK3_EV_N; k++) {          /* 从最旧（head 处）往新走 */
        const uint8_t *e = rec + O_EVENTS + ((h + k) % GK3_EV_N) * EV_SIZE;
        uint32_t seq = gk3_le32(e);
        if (!seq)
            continue;
        if (n < max) {
            out[n].seq = seq;
            out[n].code = gk3_le16(e + 4);
            out[n].slot = e[6];
            out[n].flags = e[7];
            out[n].aux = gk3_le32(e + 8);
        }
        n++;
    }
    return n;
}

void gk3_rec_events_mark_notified(uint8_t *rec, uint32_t upto_seq)
{
    for (uint32_t k = 0; k < GK3_EV_N; k++) {
        uint8_t *e = rec + O_EVENTS + k * EV_SIZE;
        uint32_t seq = gk3_le32(e);
        if (seq && seq <= upto_seq)
            e[7] |= GK3_EVF_NOTIFIED;
    }
}

const char *gk3_ev_name(gk3_ev_code c)
{
    switch (c) {
    case GK3_EV_NONE: return "none";
    case GK3_EV_FALLBACK: return "fallback";
    case GK3_EV_BOOT_CORRUPT: return "boot_corrupt";
    case GK3_EV_BCB_DROPPED: return "bcb_dropped";
    case GK3_EV_WIPE_FAILED: return "wipe_failed";
    case GK3_EV_REFUSED_MERGING: return "refused_merging";
    case GK3_EV_BOOTLOOP: return "bootloop";
    case GK3_EV_NOSLOT: return "noslot";
    case GK3_EV_MIGRATED: return "migrated";
    }
    return "?";
}

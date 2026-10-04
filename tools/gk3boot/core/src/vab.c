/* libgk3core：misc_virtual_ab_message（misc 偏移 32 KiB，只读）。
 * bootloader_message.h:88-94、:118-119；语义 libboot_control.cpp:422-440。
 * 入口从不写它：libsnapshot 经 HAL 同步 merge_status（§2.3），bootloader 只读。 */
#include "gk3core.h"

void gk3_vab_parse(const uint8_t *m, gk3_vab *out)
{
    out->version = m[0];
    out->magic = gk3_le32(m + 1);
    out->merge_status = m[5];
    out->source_slot = m[6];
    out->valid = out->version == GK3_VAB_VERSION && out->magic == GK3_VAB_MAGIC;
}

uint8_t gk3_vab_effective(const gk3_vab *v, unsigned current_slot)
{
    if (!v->valid)
        return GK3_MERGE_UNKNOWN;
    if (v->merge_status == GK3_MERGE_SNAPSHOTTED && current_slot == v->source_slot)
        return GK3_MERGE_NONE;
    return v->merge_status;
}

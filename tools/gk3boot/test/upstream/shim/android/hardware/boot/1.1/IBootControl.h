// 测试垫片：只要 MergeStatus 枚举（hardware/interfaces boot/1.1/types.hal 的取值）。
#pragma once
#include <cstdint>

namespace android {
namespace hardware {
namespace boot {
namespace V1_1 {
enum class MergeStatus : int32_t { NONE = 0, UNKNOWN = 1, SNAPSHOTTED = 2, MERGING = 3, CANCELLED = 4 };
}  // namespace V1_1
}  // namespace boot
}  // namespace hardware
}  // namespace android

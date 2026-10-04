// 测试垫片：只为在主机上编译真正的 libboot_control.cpp，日志一律丢弃。
#pragma once
#include <ostream>

namespace android {
namespace base {
struct NullStream {
    template <typename T>
    NullStream &operator<<(const T &) { return *this; }
    NullStream &operator<<(std::ostream &(*)(std::ostream &)) { return *this; }
    NullStream &operator<<(std::ios_base &(*)(std::ios_base &)) { return *this; }
};
}  // namespace base
}  // namespace android

#define LOG(sev) ::android::base::NullStream()
#define PLOG(sev) ::android::base::NullStream()

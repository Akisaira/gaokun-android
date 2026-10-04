// 测试垫片：GetProperty 读测试设置的全局表（只有 ro.boot.slot_suffix 会被问到）。
#pragma once
#include <map>
#include <string>

namespace android {
namespace base {
inline std::map<std::string, std::string> &test_props()
{
    static std::map<std::string, std::string> m;
    return m;
}
inline std::string GetProperty(const std::string &key, const std::string &def)
{
    auto it = test_props().find(key);
    return it == test_props().end() ? def : it->second;
}
}  // namespace base
}  // namespace android

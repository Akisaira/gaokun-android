// 测试用的 EspSlot：不真挂载（kEspRoot 已被 sed 换成一个普通目录），只记读写挂了几次
#include "EspSlot.h"
#include <atomic>
std::atomic<int> g_rw_mounts{0}, g_ro_mounts{0};
namespace gaokun3 {
static std::mutex& Mu() { static std::mutex m; return m; }
MountedEsp::MountedEsp(bool read_only) : lock_(Mu()) {
    (read_only ? g_ro_mounts : g_rw_mounts)++;
    mounted_ = getenv("GK3T_NOMOUNT") == nullptr;
}
MountedEsp::~MountedEsp() {}
bool SetEspDefaultSlot(int) { return true; }
}  // namespace gaokun3
